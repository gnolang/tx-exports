// Package fishbay is a small onyx trial sea.
// It keeps Mint, Register, Leave, and Bite.
// Damage is floor(bite * 100 / (hpMax + 100)), at least 1.
// A kill pays GNOT and FISH from the smaller stake.
// FISH is drawn from fishmark. This realm does not mint FISH.
// Lay, the market, cheer, and party are not in this bay.
// shoal/fish stays the live NFT collection. This package is not that collection.
// The trial mint is 1 GNOT and the stake floor is 1 GNOT.
package fishbay

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"strconv"

	fishmark "gno.land/r/g10ragdr3cjqkael8rslpw4y6rlelhev4h0fswcx/fishmark"
)

const (
	denom    = "ugnot"
	unit     int64 = 1_000_000
	mintFee  int64 = 1_000_000
	stakeMin int64 = 1_000_000
	biteStat       = 69
	hpStat         = 88
	seatMax        = 16
)

type swimmer struct {
	owner    address
	name     string
	pool     int64
	hp       int
	hpMax    int
	bite     int
	inSea    bool
	mustHeal bool
}

var (
	inited  bool
	self    address
	reserve address
	upgrade address
	lpSink  address
	team    address
	burn    address
	minted  int
	roster  [seatMax + 1]swimmer
)

// Init records the FISH reserve and the four GNOT sinks. The reserve must not also be a sink.
// Upgrade and burn may be the same address. Call this once, from an EOA, with no coins.
func Init(cur realm, who, up, lp, crew, ash address) {
	if !cur.IsCurrent() {
		panic("fishbay: realm")
	}
	if !cur.Previous().IsUserCall() {
		panic("fishbay: eoa")
	}
	takeExact(0)
	if inited {
		panic("fishbay: init")
	}
	if !who.IsValid() || !up.IsValid() || !lp.IsValid() || !crew.IsValid() || !ash.IsValid() {
		panic("fishbay: addr")
	}
	if who == up || who == lp || who == crew || who == ash || lp == crew {
		panic("fishbay: addr")
	}
	inited = true
	self = cur.Address()
	reserve = who
	upgrade = up
	lpSink = lp
	team = crew
	burn = ash
	chain.Emit("Init", "self", self.String(), "reserve", who.String())
}

// Mint sells one trial fish for 1 GNOT. The fee leaves this realm in the same call.
func Mint(cur realm, name string) int {
	if !cur.IsCurrent() {
		panic("fishbay: realm")
	}
	caller := cur.Previous()
	if !caller.IsUserCall() {
		panic("fishbay: eoa")
	}
	requireInit()
	takeExact(mintFee)
	if minted >= seatMax || !validName(name) {
		panic("fishbay: mint")
	}
	minted++
	roster[minted] = swimmer{
		owner: caller.Address(),
		name:  name,
		hp:    hpStat,
		hpMax: hpStat,
		bite:  biteStat,
	}
	payMint(mintFee, cur)
	chain.Emit("Mint", "id", strconv.Itoa(minted), "owner", caller.Address().String())
	return minted
}

// Register seats a fish. The attached coins are the stake and must be at least 1 GNOT.
func Register(cur realm, id int, stake int64) {
	if !cur.IsCurrent() {
		panic("fishbay: realm")
	}
	caller := cur.Previous()
	if !caller.IsUserCall() {
		panic("fishbay: eoa")
	}
	requireInit()
	if stake < stakeMin {
		panic("fishbay: stake")
	}
	takeExact(stake)
	fish := mustFish(id)
	if fish.owner != caller.Address() || fish.inSea || fish.mustHeal || fish.hp*100 < fish.hpMax*30 {
		panic("fishbay: register")
	}
	if ownerSeated(caller.Address()) {
		panic("fishbay: seat")
	}
	fish.pool = stake
	fish.inSea = true
	chain.Emit("Register", "id", strconv.Itoa(id), "stake", strconv.FormatInt(stake, 10))
}

// Leave returns the seated stake to the owner. A fish that is already out of the bay cannot leave.
func Leave(cur realm, id int) {
	if !cur.IsCurrent() {
		panic("fishbay: realm")
	}
	caller := cur.Previous()
	if !caller.IsUserCall() {
		panic("fishbay: eoa")
	}
	requireInit()
	takeExact(0)
	fish := mustFish(id)
	if fish.owner != caller.Address() || !fish.inSea {
		panic("fishbay: leave")
	}
	stake := fish.pool
	fish.pool = 0
	fish.inSea = false
	send(fish.owner, stake, cur)
	chain.Emit("Leave", "id", strconv.Itoa(id), "stake", strconv.FormatInt(stake, 10))
}

// Bite deals flat damage. A kill pays the smaller stake and draws 1 FISH per 1 GNOT of that stake.
func Bite(cur realm, id, target int) int {
	if !cur.IsCurrent() {
		panic("fishbay: realm")
	}
	caller := cur.Previous()
	if !caller.IsUserCall() {
		panic("fishbay: eoa")
	}
	requireInit()
	takeExact(0)
	if id == target {
		panic("fishbay: bite")
	}
	atk := mustFish(id)
	vic := mustFish(target)
	if atk.owner != caller.Address() || !atk.inSea || !vic.inSea || atk.owner == vic.owner || atk.pool < stakeMin || vic.pool < stakeMin {
		panic("fishbay: bite")
	}
	dmg := Strike(atk.bite, vic.hpMax)
	if vic.hp > dmg {
		vic.hp -= dmg
		chain.Emit("Bite", "id", strconv.Itoa(id), "target", strconv.Itoa(target), "dmg", strconv.Itoa(dmg))
		return dmg
	}
	covered := atk.pool
	if vic.pool < covered {
		covered = vic.pool
	}
	excess := vic.pool - covered
	owner := vic.owner
	vic.hp = downHP(vic.hpMax)
	vic.pool = 0
	vic.inSea = false
	vic.mustHeal = true
	killer, lp, crew, buyback := splitKill(covered)
	send(atk.owner, killer, cur)
	send(lpSink, lp, cur)
	send(team, crew, cur)
	send(burn, buyback, cur)
	send(owner, excess, cur)
	got := payFish(cur, atk.owner, covered)
	chain.Emit(
		"Kill",
		"id", strconv.Itoa(id),
		"target", strconv.Itoa(target),
		"covered", strconv.FormatInt(covered, 10),
		"fish", strconv.FormatInt(got, 10),
	)
	return dmg
}

// Strike is the damage formula. Size and rarity are not inputs.
func Strike(bite, hpMax int) int {
	if bite < 1 {
		bite = 1
	}
	if hpMax < 0 {
		hpMax = 0
	}
	dmg := bite * 100 / (hpMax + 100)
	if dmg < 1 {
		return 1
	}
	return dmg
}

func Realm() address { return self }
func Reserve() address { return reserve }
func Version() string { return "fishbay-1" }
func MintPrice() int64 { return mintFee }
func StakeMin() int64 { return stakeMin }
func Minted() int { return minted }

func OwnerOf(id int) address { return mustFish(id).owner }
func PoolOf(id int) int64    { return mustFish(id).pool }
func HpOf(id int) int        { return mustFish(id).hp }
func InSea(id int) bool      { return mustFish(id).inSea }
func MustHeal(id int) bool   { return mustFish(id).mustHeal }

func Render(path string) string {
	if path != "" {
		return "# Fishbay\n\nUnknown path.\n"
	}
	return "# Fishbay\n\nTrial bay. Mint, Register, Leave, and Bite. This is not the shoal/fish collection.\n"
}

func payFish(cur realm, to address, covered int64) int64 {
	whole := covered / unit
	if whole <= 0 {
		return 0
	}
	return fishmark.Draw(cross(cur), reserve, to, whole*unit)
}

func splitKill(covered int64) (killer, lp, crew, buyback int64) {
	killer = covered * 80 / 100
	lp = covered * 10 / 100
	teamPart := covered * 3 / 100
	buyback = covered * 3 / 100
	cheer := covered * 4 / 100
	buyback += covered - killer - lp - teamPart - buyback - cheer
	crew = teamPart + cheer
	return
}

func payMint(fee int64, rlm realm) {
	up := fee * 6000 / 10000
	lp := fee * 2000 / 10000
	crew := fee * 1000 / 10000
	ash := fee - up - lp - crew
	send(upgrade, up, rlm)
	send(lpSink, lp, rlm)
	send(team, crew, rlm)
	send(burn, ash, rlm)
}

func send(to address, amt int64, rlm realm) {
	if !rlm.IsCurrent() {
		panic("fishbay: realm")
	}
	if amt == 0 {
		return
	}
	if !to.IsValid() {
		panic("fishbay: sink")
	}
	bk := banker.NewBanker(banker.BankerTypeRealmSend, rlm)
	bk.SendCoins(rlm.Address(), to, chain.Coins{{Denom: denom, Amount: amt}})
}

func mustFish(id int) *swimmer {
	requireInit()
	if id < 1 || id > minted {
		panic("fishbay: fish")
	}
	return &roster[id]
}

func ownerSeated(who address) bool {
	for i := 1; i <= minted; i++ {
		if roster[i].owner == who && roster[i].inSea {
			return true
		}
	}
	return false
}

func downHP(hpMax int) int {
	hp := hpMax * 30 / 100
	if hp < 1 {
		return 1
	}
	return hp
}

func validName(name string) bool {
	if len(name) < 1 || len(name) > 16 {
		return false
	}
	for _, c := range name {
		if (c < 'a' || c > 'z') && (c < '0' || c > '9') {
			return false
		}
	}
	return true
}

func requireInit() {
	if !inited || self == address("") {
		panic("fishbay: init")
	}
}

func takeExact(n int64) {
	sent := unsafe.OriginSend()
	if n == 0 {
		if len(sent) != 0 {
			panic("fishbay: payment")
		}
		return
	}
	if len(sent) != 1 || sent[0].Denom != denom || sent[0].Amount != n {
		panic("fishbay: payment")
	}
}
