package fish

import (
	"chain/runtime"
	"crypto/sha256"
	"strconv"
	"time"

	"gno.land/r/g1n4pl5uc4yt5r96m9w6fmdznx3x0jyg8l6arhmt/shoal/shoaltoken"
)

func Register(cur realm, id int, stake int64) {
	caller := requireUser(cur)
	body := must(id)
	if body.owner != caller {
		panic("fish: owner")
	}
	if body.inMatch {
		panic("fish: match")
	}
	if body.mustHeal {
		panic("fish: heal")
	}
	guardMovable(body)
	if tooHurt(body) {
		panic("fish: hp")
	}
	if walletInSea(caller) {
		panic("fish: one")
	}
	if !arenaStake(stake) {
		panic("fish: stake")
	}
	takeExact(stake)
	now := time.Now().Unix()
	body.pool = stake
	body.inMatch = true
	body.boutPaid = false
	body.startUnix = now
	body.endUnix = 0
	body.lastCombatMilli = -1
	body.nextMoveMilli = 0
	body.burstUntil = 0
	body.nextBurstAt = 0
	body.springBorn = -1
	placeSwimmer(body)
	clearDamage(id)
}

func Leave(cur realm, id int) {
	caller := requireUser(cur)
	takeExact(0)
	body := must(id)
	if body.owner != caller {
		panic("fish: owner")
	}
	if !body.inMatch {
		panic("fish: match")
	}
	nowMs := time.Now().UnixMilli()
	if body.lastCombatMilli >= 0 && nowMs < body.lastCombatMilli+combatLockMs {
		panic("fish: stay")
	}
	returnCheers(body, cur)
	stake := body.pool
	body.pool = 0
	body.inMatch = false
	body.boutPaid = false
	clearDamage(id)
	send(caller, stake, cur)
}

func SettleMatch(cur realm, id int) {
	requireUser(cur)
	takeExact(0)
	body := must(id)
	if !body.inMatch {
		panic("fish: match")
	}
	_ = body
	panic("fish: sea")
}

func CommitLay(cur realm, id int) {
	caller := requireUser(cur)
	body := must(id)
	if body.owner != caller {
		panic("fish: owner")
	}
	guardMovable(body)
	left := body.bouts - body.layBoutsUsed
	if left < 3 {
		panic("fish: bouts")
	}
	takeExact(layFee)
	payMint(layFee, cur)
	body.layBoutsUsed = body.bouts
	body.layOpen = true
	body.layHeight = runtime.ChainHeight()
}

func SettleLay(cur realm, id int) int {
	requireUser(cur)
	takeExact(0)
	body := must(id)
	if !body.layOpen {
		panic("fish: lay")
	}
	height := runtime.ChainHeight()
	if height < body.layHeight+layBlocks {
		panic("fish: early")
	}
	trait := traitFrom(body.id, body.layHeight, height, time.Now().Unix())
	body.layOpen = false
	return issue(body.owner, body.name+" fry", body.rarity, body.size, trait)
}

// Upgrade spends 15 FISH to step two played Common fish to Uncommon.
// The FISH fee burns. The team takes none of it. No GNOT moves.
// Higher tiers stay closed until a commit-reveal roll exists.
func Upgrade(cur realm, keep, food int) int {
	caller := requireUser(cur)
	if keep == food {
		panic("fish: upgrade")
	}
	a := must(keep)
	b := must(food)
	if a.owner != caller || b.owner != caller {
		panic("fish: owner")
	}
	guardMovable(a)
	guardMovable(b)
	if a.rarity != b.rarity || a.size != b.size || a.trait != b.trait {
		panic("fish: pair")
	}
	if a.bouts < 1 || b.bouts < 1 {
		panic("fish: bouts")
	}
	if a.rarity != "common" {
		panic("fish: roll")
	}
	takeExact(0)
	if !fishTokenReady() {
		panic("fish: fish")
	}
	got := shoaltoken.Draw(cross(cur), caller, burnSink, upgradeFishFee)
	if got != upgradeFishFee {
		panic("fish: fish")
	}
	name := a.name
	size := a.size
	trait := a.trait
	burnBody(a)
	burnBody(b)
	return issue(caller, name, "uncommon", size, trait)
}

func burnBody(body *fishBody) {
	burnGRC(body.id)
	body.burned = true
	body.owner = address("")
	body.seller = address("")
	body.price = 0
	body.listed = false
	body.pool = 0
	body.inMatch = false
	body.layOpen = false
}

func traitFrom(id int, commitHeight, settleHeight, unix int64) string {
	raw := strconv.Itoa(id) + ":" + strconv.FormatInt(commitHeight, 10) + ":" + strconv.FormatInt(settleHeight, 10) + ":" + strconv.FormatInt(unix, 10)
	sum := sha256.Sum256([]byte(raw))
	var n int64
	for i := 0; i < len(sum); i++ {
		n = (n*256 + int64(sum[i])) % 3
	}
	switch n {
	case 0:
		return "swift"
	case 1:
		return "fang"
	default:
		return "hide"
	}
}
