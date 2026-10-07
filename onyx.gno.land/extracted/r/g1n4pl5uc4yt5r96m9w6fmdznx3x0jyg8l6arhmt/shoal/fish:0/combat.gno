package fish

import (
	"chain"
	"strconv"
	"time"

	"gno.land/r/g1n4pl5uc4yt5r96m9w6fmdznx3x0jyg8l6arhmt/shoal/party"
	"gno.land/r/g1n4pl5uc4yt5r96m9w6fmdznx3x0jyg8l6arhmt/shoal/shoaltoken"
)

type damageRow struct {
	owner address
	dmg   int
}

// blows[victimID] sums HP actually removed, keyed by the attacker's owner.
var blows [][]damageRow

// Bite is one user call and takes no payment. The hit test is sector-center
// reach plus a 42 degree mouth cone. A miss does not start cooldown. Members
// of the same party cannot bite each other. A killing blow pays the smaller
// Pool X and leaves the NFT at 30% HP. The killer share is split by HP removed.
// Empty cheer pays the team sink. A new kill does not drop watch shards.
// Buyback GNOT that cannot buy one FISH from the reserve burns. Spent GNOT joins liquidity.
func Bite(cur realm, id, target int) {
	caller := requireUser(cur)
	takeExact(0)
	if id == target {
		panic("fish: bite")
	}
	atk := must(id)
	vic := must(target)
	if atk.owner != caller {
		panic("fish: owner")
	}
	if atk.mustHeal || vic.mustHeal {
		panic("fish: heal")
	}
	now := time.Now().Unix()
	if !liveFish(atk, now) || !liveFish(vic, now) {
		panic("fish: match")
	}
	if atk.owner == vic.owner {
		panic("fish: bite")
	}
	if party.SameParty(cross(cur), atk.owner, vic.owner) {
		panic("fish: party")
	}
	nowMs := time.Now().UnixMilli()
	// A cave or reef does not dodge. The cone still has to face the fish inside.
	if !mouthHit(atk, vic) && !shelterMouth(atk, vic, nowMs) {
		panic("fish: range")
	}
	if nowMs < atk.nextBiteMilli {
		panic("fish: cool")
	}
	if atk.bittenBy == vic.id && nowMs < atk.bittenUntil {
		panic("fish: cool")
	}
	cool := nowMs + cooldownMs(atk.rarity)
	atk.nextBiteMilli = cool
	atk.lastCombatMilli = nowMs
	if redirectShelter(atk, vic, nowMs) {
		chain.Emit("Bite", "id", strconv.Itoa(id), "target", strconv.Itoa(target), "damage", "shelter")
		return
	}
	vic.lastCombatMilli = nowMs
	vic.bittenBy = atk.id
	vic.bittenUntil = cool
	dmg := strikeFought(biteNow(atk), vic.hp, atk.size, vic.size, atk.rarity, vic.rarity)
	landed := dmg
	if landed > vic.hpNow {
		landed = vic.hpNow
	}
	addDamage(vic.id, atk.owner, landed)
	if vic.hpNow > dmg {
		vic.hpNow -= dmg
		chain.Emit("Bite", "id", strconv.Itoa(id), "target", strconv.Itoa(target), "damage", strconv.Itoa(dmg))
		return
	}
	payKill(atk, vic, cur)
}

func payKill(atk, vic *fishBody, rlm realm) {
	if !rlm.IsCurrent() {
		panic("fish: realm")
	}
	covered := coveredStake(atk.pool, vic.pool)
	excess := vic.pool - covered
	killer, lp, team, buyback, cheer := splitParts(covered)
	stake := atk.pool
	nowMs := time.Now().UnixMilli()
	creditBout(atk)
	creditBout(vic)
	growFromKill(atk, vic)
	returnCheers(vic, rlm)
	vic.pool = 0
	vic.inMatch = false
	vic.boutPaid = false
	vic.mustHeal = true
	vic.hpNow = downHP(vic.hp)
	cheerHeld := bookCheerClaims(atk, vic, cheer, nowMs)
	team += cheer - cheerHeld
	send(vic.owner, excess, rlm)
	payKiller(atk.owner, vic.id, killer, rlm)
	send(lpSink, lp, rlm)
	send(teamSink, team, rlm)
	spent := settleBuyback(buyback, rlm)
	send(lpSink, spent, rlm)
	send(burnSink, buyback-spent, rlm)
	payWinFish(atk.owner, stake, rlm)
	clearDamage(vic.id)
	chain.Emit(
		"Kill",
		"id", strconv.Itoa(atk.id),
		"target", strconv.Itoa(vic.id),
		"covered", strconv.FormatInt(covered, 10),
		"killer", strconv.FormatInt(killer, 10),
	)
}

// payKiller splits the killer share by HP removed among current members.
// The party realm holds no coins. A solo owner, or a party with no recorded
// damage, receives the whole share. Dust goes to the highest damage, and a
// tie prefers the owner who landed the blow.
func payKiller(owner address, victim int, amount int64, rlm realm) {
	if amount <= 0 {
		return
	}
	pid := party.PartyOf(cross(rlm), owner)
	if pid == 0 {
		send(owner, amount, rlm)
		return
	}
	n := party.MemberCount(cross(rlm), pid)
	if n <= 0 {
		send(owner, amount, rlm)
		return
	}
	owners := make([]address, n)
	weights := make([]int, n)
	total := 0
	for i := 0; i < n; i++ {
		who := party.MemberAt(cross(rlm), pid, i)
		owners[i] = who
		w := damageOf(victim, who)
		if w < 0 {
			w = 0
		}
		weights[i] = w
		total += w
	}
	if total <= 0 {
		send(owner, amount, rlm)
		return
	}
	shares := splitWeights(amount, weights, owner, owners)
	for i := range owners {
		send(owners[i], shares[i], rlm)
	}
}

func splitWeights(amount int64, weights []int, prefer address, owners []address) []int64 {
	total := 0
	for _, w := range weights {
		if w > 0 {
			total += w
		}
	}
	out := make([]int64, len(weights))
	if amount <= 0 || total <= 0 {
		return out
	}
	var used int64
	best := -1
	bestW := 0
	for i, w := range weights {
		if w <= 0 {
			continue
		}
		share := amount * int64(w) / int64(total)
		out[i] = share
		used += share
		if best < 0 || w > bestW || (w == bestW && i < len(owners) && owners[i] == prefer) {
			best = i
			bestW = w
		}
	}
	if used < amount && best >= 0 {
		out[best] += amount - used
	}
	return out
}

func addDamage(id int, owner address, n int) {
	if n <= 0 || id < 1 || !owner.IsValid() {
		return
	}
	for len(blows) <= id {
		blows = append(blows, nil)
	}
	rows := blows[id]
	for i := 0; i < len(rows); i++ {
		if rows[i].owner == owner {
			rows[i].dmg += n
			blows[id] = rows
			return
		}
	}
	blows[id] = append(rows, damageRow{owner: owner, dmg: n})
}

func damageOf(id int, owner address) int {
	if id < 0 || id >= len(blows) {
		return 0
	}
	for i := 0; i < len(blows[id]); i++ {
		if blows[id][i].owner == owner && blows[id][i].dmg > 0 {
			return blows[id][i].dmg
		}
	}
	return 0
}

// clearDamage drops incoming blows so the next entry starts clean.
func clearDamage(id int) {
	if id < 0 || id >= len(blows) {
		return
	}
	blows[id] = nil
}

// creditBout counts one finished entry. Leave does not call it.
// SettleMatch does not count the entry again.
func creditBout(body *fishBody) {
	if body.boutPaid {
		return
	}
	body.boutPaid = true
	body.bouts++
}

func liveFish(body *fishBody, now int64) bool {
	if now < 0 {
		return false
	}
	return body.inMatch && body.pool > 0
}

func downHP(max int) int {
	hp := max * 30 / 100
	if hp < 1 {
		return 1
	}
	return hp
}

func coveredStake(killerPool, victimPool int64) int64 {
	if killerPool < 0 {
		killerPool = 0
	}
	if victimPool < 0 {
		victimPool = 0
	}
	if killerPool < victimPool {
		return killerPool
	}
	return victimPool
}

// splitParts is 80/10/3/3/4. Killer, liquidity, team, FISH buyback, cheer.
// Dust joins the buyback.
func splitParts(amount int64) (killer, lp, team, buyback, cheer int64) {
	if amount < 0 {
		amount = 0
	}
	killer = amount * 8000 / 10000
	lp = amount * 1000 / 10000
	team = amount * 300 / 10000
	buyback = amount * 300 / 10000
	cheer = amount * 400 / 10000
	dust := amount - killer - lp - team - buyback - cheer
	buyback += dust
	return
}

// settleBuyback spends whole FISH from the reserve at 0.02 GNOT each.
// GNOT that cannot buy one FISH stays with the caller to burn. This does not mint.
func settleBuyback(budget int64, rlm realm) int64 {
	if !rlm.IsCurrent() {
		panic("fish: realm")
	}
	units := reserveUnits(budget / twapUgnot)
	if units <= 0 {
		return 0
	}
	got := shoaltoken.Draw(cross(rlm), fishReserve, burnSink, units)
	if got != units {
		panic("fish: fish")
	}
	return (units / fishUnit) * twapUgnot
}

// payWinFish pays 1 whole FISH per 1 whole GNOT of the winner stake, then the party bonus.
// Both come from the reserve after buyback. A short reserve pays less. This does not mint.
func payWinFish(owner address, stake int64, rlm realm) {
	if !rlm.IsCurrent() {
		panic("fish: realm")
	}
	whole := stake / ugnot
	if whole < 0 {
		whole = 0
	}
	baseUnits := reserveUnits(whole)
	if baseUnits > 0 {
		got := shoaltoken.Draw(cross(rlm), fishReserve, owner, baseUnits)
		if got != baseUnits {
			panic("fish: fish")
		}
	}
	baseFish := baseUnits / fishUnit
	owners := partyMembers(owner, rlm)
	members := len(owners)
	if members == 0 {
		members = 1
	}
	bonusFish := baseFish * int64(partyFishBonusBps(members)) / 10000
	bonusUnits := reserveUnits(bonusFish)
	if bonusUnits <= 0 {
		return
	}
	shares := splitPartyFish(bonusUnits/fishUnit, owners, owner)
	for i := range owners {
		part := shares[i] * fishUnit
		if part <= 0 {
			continue
		}
		got := shoaltoken.Draw(cross(rlm), fishReserve, owners[i], part)
		if got != part {
			panic("fish: fish")
		}
	}
}

func reserveUnits(whole int64) int64 {
	if whole <= 0 || !fishTokenReady() || !fishReserve.IsValid() {
		return 0
	}
	units := whole * fishUnit
	room := shoaltoken.BalanceOf(fishReserve)
	allow := shoaltoken.Allowance(fishReserve, self)
	if allow < room {
		room = allow
	}
	room = room / fishUnit * fishUnit
	if units > room {
		return room
	}
	return units
}

func partyMembers(owner address, rlm realm) []address {
	pid := party.PartyOf(cross(rlm), owner)
	if pid == 0 {
		return nil
	}
	n := party.MemberCount(cross(rlm), pid)
	out := make([]address, n)
	for i := 0; i < n; i++ {
		out[i] = party.MemberAt(cross(rlm), pid, i)
	}
	return out
}

func partyFishBonusBps(members int) int {
	if members <= 1 {
		return 0
	}
	n := members
	if n > 8 {
		n = 8
	}
	return (n - 1) * 1000 / 7
}

func splitPartyFish(bonus int64, owners []address, killer address) []int64 {
	out := make([]int64, len(owners))
	if bonus <= 0 || len(owners) == 0 {
		return out
	}
	each := bonus / int64(len(owners))
	dustAt := 0
	for i, who := range owners {
		out[i] = each
		if who == killer {
			dustAt = i
		}
	}
	out[dustAt] += bonus - each*int64(len(owners))
	return out
}

func strikeDamage(bite, hpMax int, atkSize, defSize string) int {
	dmg := bite * 100 / (hpMax + 100)
	if dmg < 1 {
		dmg = 1
	}
	if sizeIndex(atkSize)-sizeIndex(defSize) >= 2 {
		dmg = dmg * 5000 / 10000
		if dmg < 1 {
			dmg = 1
		}
	}
	return dmg
}

func sizeIndex(size string) int {
	switch size {
	case "small":
		return 0
	case "medium":
		return 1
	case "large":
		return 2
	default:
		panic("fish: size")
	}
}

func biteOf(rarity, size, trait string) int {
	var base int64
	switch rarity {
	case "common":
		base = 22
	case "uncommon":
		base = 26
	case "rare":
		base = 31
	case "epic":
		base = 37
	case "legendary":
		base = 44
	case "mythic":
		base = 52
	default:
		panic("fish: rarity")
	}
	traitBps := int64(10000)
	if trait == "fang" {
		traitBps = 11200
	}
	sizeBps := int64(10000)
	if size == "small" {
		sizeBps = 8600
	} else if size == "large" {
		sizeBps = 11800
	}
	v := (base*traitBps*sizeBps + 50_000_000) / 100_000_000
	if v < 1 {
		v = 1
	}
	return int(v)
}

func cooldownMs(rarity string) int64 {
	switch rarity {
	case "common":
		return 2400
	case "uncommon":
		return 2550
	case "rare":
		return 2700
	case "epic":
		return 2850
	case "legendary":
		return 3000
	case "mythic":
		return 3200
	default:
		panic("fish: rarity")
	}
}

// reachUnits is the dodged bite reach in 1/10000 of a world unit.
// A sector is 8 world units, so the next center is 80000 units away.
func reachUnits(rarity, size string, dodgeTenths int) int64 {
	var spec int64
	switch rarity {
	case "common":
		spec = 10000
	case "uncommon":
		spec = 10600
	case "rare":
		spec = 11200
	case "epic":
		spec = 11800
	case "legendary":
		spec = 12400
	case "mythic":
		spec = 13200
	default:
		panic("fish: rarity")
	}
	sizeMod := int64(10000)
	if size == "small" {
		sizeMod = 8600
	} else if size == "large" {
		sizeMod = 12200
	}
	reach := spec * sizeMod * 8 / 10000
	reach -= int64(dodgeTenths) * 1000
	if reach < 10_000 {
		return 10_000
	}
	return reach
}

func inReach(atk, def *fishBody) bool {
	return inReachDodge(atk, def, def.dodge)
}

func inReachDodge(atk, def *fishBody, dodge int) bool {
	dx := int64(atk.sx - def.sx)
	dz := int64(atk.sz - def.sz)
	span := dx*dx + dz*dz
	reach := reachUnits(atk.rarity, atk.size, dodge)
	dist2 := span * 80_000 * 80_000
	return dist2 <= reach*reach
}
