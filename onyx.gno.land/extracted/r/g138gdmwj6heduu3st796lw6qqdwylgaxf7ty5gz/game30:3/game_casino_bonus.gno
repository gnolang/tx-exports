package game30

import (
	"strconv"
	"time"

	"chain"

	"gno.land/p/nt/avl/v0"
)

// ── Slots bonus features, all settled by the realm ──────────────────────────
//
// Free spins: 3/4/5 scatters on a paid spin grant 10/12/15 free spins at that
// spin's bet. The grant is a realm record (one open grant per player). The
// triggering spin keeps its 500× reservation for the whole feature, minus what
// it already paid, so every free spin can always be paid in full. A free spin is
// its own two-sided round (PlaceCasinoFreeSpin takes no stake); its wins are
// doubled, it pays from that reservation, scatters don't retrigger and vaults
// don't start Hold & Spin. The grant never expires for the player.
//
// Hold & Spin: 3+ vaults on a paid spin. Resolved inside that spin's settlement
// from the same seed stream (game_slots.gno). Coin tiles pay 1/2/3/5× the bet,
// MINI 20×, MINOR 75× (all under the 500× cap). The first MAJOR / GRAND tile
// pays that jackpot pool (extra ones pay as MINOR); a full board (20 tiles) also
// awards GRAND.
//
// MAJOR / GRAND jackpots: real pools per coin, fed with 1.0% / 0.5% of every
// paid slots stake (fractions carried exactly). A hit pays
// pool × min(1, bet / refBet); the rest stays. A pool can never pay more than
// it holds. After a hit the pool is topped back up to its reset seed from the
// house pool, only while the free house pool is ≥ 20× that top-up. The admin
// can add its own coins to a jackpot but nobody can withdraw one.

var (
	casinoGrants  avl.Tree // addr → *freeSpinGrant
	casinoJackpot avl.Tree // coin:tier → pool (string)
	casinoJpDust  avl.Tree // coin:tier → contribution remainder in bet×bps units (string)
	casinoJpSeed  avl.Tree // coin:tier → reset seed (string)
	casinoJpRef   avl.Tree // coin → reference bet (string)
)

const (
	freeSpinMult        = uint64(2)
	jpMajorBps          = uint64(100) // 1.0% of each paid slots stake
	jpGrandBps          = uint64(50)  // 0.5%
	jpDefaultRefBet     = uint64(100)
	jpResetFreeMultiple = uint64(20)
	hsMiniMult          = uint64(20)
	hsMinorMult         = uint64(75)
)

type freeSpinGrant struct {
	addr, coin string
	bet        uint64
	left       uint64
	total      uint64
	capLeft    uint64 // still reserved in casinoReserved for this feature
	won        uint64
	inRound    string
	fromRound  string
	grantedAt  int64
}

func getGrant(addr string) *freeSpinGrant {
	if !casinoGrants.Has(addr) {
		return nil
	}
	return casinoGrants.Get(addr).(*freeSpinGrant)
}

func jpKey(coin, tier string) string { return coin + ":" + tier }

func jpRefBet(coin string) uint64 {
	if v := casGet(&casinoJpRef, coin); v > 0 {
		return v
	}
	return jpDefaultRefBet
}

// casinoJackpotContribute moves 1.0% / 0.5% of a paid slots stake from the house
// pool into the MAJOR / GRAND pools (remainders carried, nothing rounded away).
func casinoJackpotContribute(coin string, amt uint64) {
	for _, t := range [2]struct {
		tier string
		bps  uint64
	}{{"major", jpMajorBps}, {"grand", jpGrandBps}} {
		k := jpKey(coin, t.tier)
		dust := casAdd(casGet(&casinoJpDust, k), casMul(amt, t.bps))
		units := dust / 10000
		if units == 0 {
			casSet(&casinoJpDust, k, dust)
			continue
		}
		pool := casGet(&casinoPool, coin)
		if pool < casAdd(casGet(&casinoReserved, coin), units) {
			casSet(&casinoJpDust, k, dust) // house can't spare it right now: keep it owed
			continue
		}
		casSet(&casinoJpDust, k, dust%10000)
		casSet(&casinoPool, coin, pool-units)
		casSet(&casinoJackpot, k, casAdd(casGet(&casinoJackpot, k), units))
		day, snap, paid, recv := casinoDayState(coin)
		setCasinoDay(coin, day, snap, casAdd(paid, units), recv)
	}
}

// casinoJackpotPay pays a jackpot tier to addr: pool × min(1, bet/refBet).
func casinoJackpotPay(addr, coin, tier string, bet uint64) uint64 {
	k := jpKey(coin, tier)
	pool := casGet(&casinoJackpot, k)
	ref := jpRefBet(coin)
	pay := pool
	if bet < ref {
		pay = casMulDiv(pool, bet, ref)
	}
	casSet(&casinoJackpot, k, pool-pay)
	casCredit(addr, coin, pay)
	chain.Emit("CasinoJackpotWon", "player", addr, "coin", coin, "tier", tier, "amount", casU(pay))
	// Top back up to the reset seed from the house pool, only if the house can easily afford it.
	seed := casGet(&casinoJpSeed, k)
	left := pool - pay
	if seed > left {
		need := seed - left
		house := casGet(&casinoPool, coin)
		reserved := casGet(&casinoReserved, coin)
		if house > reserved && house-reserved >= casMul(need, jpResetFreeMultiple) {
			casSet(&casinoPool, coin, house-need)
			casSet(&casinoJackpot, k, seed)
			day, snap, paid, recv := casinoDayState(coin)
			setCasinoDay(coin, day, snap, casAdd(paid, need), recv)
		}
	}
	return pay
}

// slotsHSPayout turns Hold & Spin tiles into bet multiples (under the cap) and
// the jackpot tiers won (paid from their pools).
func slotsHSPayout(tiles *[slotsCells]uint16, full bool) (uint64, bool, bool) {
	mult := uint64(0)
	major, grand := false, false
	for i := 0; i < slotsCells; i++ {
		v := tiles[i]
		switch {
		case v == 0:
		case v < 100:
			mult += uint64(v)
		case v == hsMini:
			mult += hsMiniMult
		case v == hsMinor:
			mult += hsMinorMult
		case v == hsMajor && !major:
			major = true
		case v == hsGrand && !grand:
			grand = true
		default: // a second MAJOR / GRAND in the same bonus pays as MINOR
			mult += hsMinorMult
		}
	}
	if full && !grand {
		grand = true
	}
	return mult, major, grand
}

// PlaceCasinoFreeSpin uses one free spin of the caller's grant in a committed
// round (no stake). One free spin in flight at a time.
func PlaceCasinoFreeSpin(cur realm, roundId string, clientHash string) {
	requireNotPaused()
	caller := cur.Previous().Address().String()
	if isBlacklisted(caller) {
		panic("address banned")
	}
	r := mustCasinoRound(roundId)
	if r.player != caller {
		panic("this round belongs to another player")
	}
	if r.status != "committed" {
		panic("betting is closed for this round")
	}
	if time.Now().Unix()-r.committedAt >= casinoBetWindowSec {
		panic("round expired")
	}
	g := getGrant(caller)
	if g == nil || g.left == 0 {
		panic("no free spins left")
	}
	if g.inRound != "" {
		panic("a free spin is already in progress (round " + g.inRound + ")")
	}
	if !casIsHex64(clientHash) {
		panic("client hash must be sha256 hex")
	}
	g.inRound = roundId
	casinoBets.Set(roundId+":"+caller, &casinoBet{addr: caller, game: "slots", coin: g.coin, choice: "free", clientHash: clientHash, amount: g.bet, freeSpin: true})
	r.status = "bet"
	r.betAt = time.Now().Unix()
	r.bets = 1
}

// settleFreeSpin pays a free spin's win out of its grant's reservation.
func settleFreeSpin(b *casinoBet, win uint64) uint64 {
	g := getGrant(b.addr)
	if g == nil {
		panic("free spin grant missing")
	}
	if win > g.capLeft {
		win = g.capLeft
		b.capped = true
	}
	if win > 0 {
		casSet(&casinoReserved, b.coin, casSub(casGet(&casinoReserved, b.coin), win))
		casSet(&casinoPool, b.coin, casSub(casGet(&casinoPool, b.coin), win))
		day, snap, paid, recv := casinoDayState(b.coin)
		setCasinoDay(b.coin, day, snap, casAdd(paid, win), recv)
		casCredit(b.addr, b.coin, win)
	}
	g.capLeft -= win
	g.won += win
	g.left--
	g.inRound = ""
	if g.left == 0 {
		casSet(&casinoReserved, b.coin, casSub(casGet(&casinoReserved, b.coin), g.capLeft))
		casinoGrants.Remove(b.addr)
		chain.Emit("CasinoFreeSpinsDone", "player", b.addr, "coin", b.coin, "won", casU(g.won))
	}
	return win
}

// FreeSpinGrant reports a player's open free spins (null when none).
func FreeSpinGrant(addr string) string {
	g := getGrant(addr)
	if g == nil {
		return "null"
	}
	return `{"coin":"` + g.coin + `","bet":` + casU(g.bet) + `,"left":` + casU(g.left) + `,"total":` + casU(g.total) +
		`,"mult":` + casU(freeSpinMult) + `,"capLeft":` + casU(g.capLeft) + `,"won":` + casU(g.won) +
		`,"inRound":"` + g.inRound + `","fromRound":"` + g.fromRound + `"}`
}

// CasinoJackpots reports the real MAJOR / GRAND pools and how they pay.
func CasinoJackpots(coinId string) string {
	return `{"coin":"` + coinId + `","major":"` + casU(casGet(&casinoJackpot, jpKey(coinId, "major"))) +
		`","grand":"` + casU(casGet(&casinoJackpot, jpKey(coinId, "grand"))) +
		`","majorSeed":"` + casU(casGet(&casinoJpSeed, jpKey(coinId, "major"))) +
		`","grandSeed":"` + casU(casGet(&casinoJpSeed, jpKey(coinId, "grand"))) +
		`","refBet":"` + casU(jpRefBet(coinId)) + `","miniMult":` + casU(hsMiniMult) + `,"minorMult":` + casU(hsMinorMult) +
		`,"majorBps":` + casU(jpMajorBps) + `,"grandBps":` + casU(jpGrandBps) + `}`
}

func validJpTier(tier string) bool { return tier == "major" || tier == "grand" }

// SeedCasinoJackpot adds the ADMIN'S OWN coins to a jackpot pool (never withdrawable).
func SeedCasinoJackpot(cur realm, coinId, tier, amount string) {
	if cur.Previous().Address() != admin {
		panic("unauthorized: admin only")
	}
	if _, ok := coinRarity[coinId]; !ok {
		panic("unknown coin id: " + coinId)
	}
	if !validJpTier(tier) {
		panic("tier must be major or grand")
	}
	amt, err := strconv.ParseUint(amount, 10, 64)
	if err != nil || amt == 0 || amt > casinoMaxAmount {
		panic("invalid amount")
	}
	casDebit(admin.String(), coinId, amt)
	k := jpKey(coinId, tier)
	casSet(&casinoJackpot, k, casAdd(casGet(&casinoJackpot, k), amt))
	casStat(coinId, "", "seeded", amt)
	chain.Emit("CasinoJackpotSeeded", "coin", coinId, "tier", tier, "amount", amount)
}

// SetCasinoJackpotSeed sets the level a jackpot is topped back up to after a hit.
func SetCasinoJackpotSeed(cur realm, coinId, tier, amount string) {
	if cur.Previous().Address() != admin {
		panic("unauthorized: admin only")
	}
	if !validJpTier(tier) {
		panic("tier must be major or grand")
	}
	amt, err := strconv.ParseUint(amount, 10, 64)
	if err != nil || amt > casinoMaxAmount {
		panic("invalid amount")
	}
	casSet(&casinoJpSeed, jpKey(coinId, tier), amt)
}

// SetCasinoJackpotRefBet sets the bet that wins a full jackpot (smaller bets win
// the same share of the pool as their share of this bet).
func SetCasinoJackpotRefBet(cur realm, coinId, amount string) {
	if cur.Previous().Address() != admin {
		panic("unauthorized: admin only")
	}
	amt, err := strconv.ParseUint(amount, 10, 64)
	if err != nil || amt == 0 || amt > casinoMaxAmount {
		panic("invalid amount")
	}
	casSet(&casinoJpRef, coinId, amt)
}
