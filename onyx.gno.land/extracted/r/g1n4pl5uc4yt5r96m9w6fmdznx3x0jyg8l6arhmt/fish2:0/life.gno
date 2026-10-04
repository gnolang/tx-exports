package fish2

import (
	"chain/runtime"
	"crypto/sha256"
	"strconv"
	"time"
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
	if a.rarity != "common" {
		panic("fish: roll")
	}
	if a.bouts < 1 || b.bouts < 1 {
		panic("fish: bouts")
	}
	takeExact(upgradeFee)
	send(upgradeSink, upgradeFee, cur)
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
