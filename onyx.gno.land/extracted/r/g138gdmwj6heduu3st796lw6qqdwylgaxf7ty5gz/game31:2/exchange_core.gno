package game31

// ── P2P exchange: core (docs/P2P_EXCHANGE_PLAN.md, docs/EXCHANGE_SECURITY_REVIEW.md)
//
// Open economy (Simion, 2026-10-11): no price-impact cap, no price bands, no
// reference-price checks on deposits. Every value-moving call takes the
// trader's own protection instead: a minimum output (minOut / minShares /
// minGet) and a deadline.
//
// Security rules this file enforces for the whole exchange:
//   - The exchange only moves coins that already exist in `balances`
//     (debitBal → reserves/escrow → creditBal). It never mints.
//   - The admin has NO path to pool reserves, LP positions, escrowed orders,
//     accrued casino fees or player balances. Admin powers are listed in
//     docs/EXCHANGE_SECURITY_REVIEW.md §2.
//   - Pause stops only NEW swaps / orders / deposits. Exits — RemoveLiquidity,
//     CancelOrder, SweepExpiredOrders, WithdrawProtocolFees — always work,
//     also while paused and for banned addresses.
//   - All amounts are uint64; every add/mul is checked (panics, never wraps);
//     products use 128-bit intermediates; rounding favors the pool / maker.
//   - No exchange path calls another realm or sends coins: no reentrancy.
//   - Loops are bounded by constants (≤ maxFillsPerTx fills, ≤ maxScanPerTx
//     scanned entries, ≤ maxViewLimit view rows, ≤ maxOpenOrders per maker).
//   - Block time is used only for deadlines, order expiry and the LP warm-up.

import (
	"math/bits"
	"strconv"
	"time"

	"chain"

	"gno.land/p/nt/avl/v0"
)

const (
	hubCoin = "grin"

	// Pools: 0.50% of the input; 0.35% stays in the pool (LPs), 0.15% is the
	// protocol fee, split 50/50 between the admin and the casino pool.
	poolFeeBps  = uint64(50)
	protoFeeBps = uint64(15)

	minLiquidity     = uint64(1000) // first-deposit shares burned forever
	minOpenDepthGrin = uint64(2000) // a pool takes swaps only once rGrin ≥ this
	warmupSecs       = int64(600)   // LP fee warm-up (principal always instant)
	rootKScale       = uint64(1000000000)

	// Order book: takers 0.50% of what they pay; makers 0.90% of what they
	// receive (deducted from the maker's proceeds at fill time, never upfront).
	// No flat posting fee — any amount meeting the size floor can be listed.
	takerFeeBps     = uint64(50)
	makerFeeBps     = uint64(90)
	minOrderGrinX1k = uint64(50000) // 50 grin of value (reference table) — size floor only
	maxOpenOrders   = uint64(20)
	defaultExpiry   = int64(72 * 3600)
	maxExpiry       = int64(7 * 24 * 3600)
	maxFillsPerTx   = 10
	maxScanPerTx    = 20
	maxViewLimit    = 50

	// Upper bound for any single amount argument. Keeps every intermediate far
	// from uint64 limits (balances are uint64 too) and rejects absurd inputs.
	maxAmount = uint64(1000000000000000) // 1e15

)

// Reference value per rarity in milli-grin (RARITY_VALUE ×1000). Used ONLY
// for the 50-grin minimum order size — never for prices.
var prefMilli = [7]uint64{1000, 3200, 11000, 40000, 160000, 720000, 3600000}

var (
	pools       avl.Tree // coin → *pool
	lpPositions avl.Tree // coin+":"+addr → *lpPos
	adminFees   avl.Tree // coin → admin's accrued protocol fees (pull)
	casinoPool  avl.Tree // coin → casino pool balance (fees in, capped jackpots out)
	makerBooks     avl.Tree // maker → ";"-joined compact order records (≤ maxOpenOrders)
	sides          avl.Tree // want+">"+give → sorted fixed-width entries (≤ maxSideOrders)
	openOrderTotal uint64
	nextOrderId    uint64
	exPaused    bool

	// Lifetime accounting (Render + audits).
	adminFeesWithdrawn avl.Tree // coin → lifetime withdrawn by the admin
	adminGnotWithdrawn int64    // ugnot withdrawn by WithdrawFunds (≤ passRevenueUgnot)
)

// ── checked math ─────────────────────────────────────────────────────────────

func addChk(a, b uint64) uint64 {
	s, carry := bits.Add64(a, b, 0)
	if carry != 0 {
		panic("math overflow")
	}
	return s
}

func subChk(a, b uint64) uint64 {
	if b > a {
		panic("math underflow")
	}
	return a - b
}

// mulDiv = floor(a*b/c) with a 128-bit product; panics if c == 0 or the
// quotient does not fit in 64 bits.
func mulDiv(a, b, c uint64) uint64 {
	if c == 0 {
		panic("division by zero")
	}
	hi, lo := bits.Mul64(a, b)
	if hi >= c {
		panic("math overflow")
	}
	q, _ := bits.Div64(hi, lo, c)
	return q
}

// mulDivUp = ceil(a*b/c).
func mulDivUp(a, b, c uint64) uint64 {
	if c == 0 {
		panic("division by zero")
	}
	hi, lo := bits.Mul64(a, b)
	if hi >= c {
		panic("math overflow")
	}
	q, r := bits.Div64(hi, lo, c)
	if r > 0 {
		q = addChk(q, 1)
	}
	return q
}

// isqrt128 = floor(sqrt(a*b)) for the 128-bit product (Newton, bounded).
func isqrt128(a, b uint64) uint64 {
	hi, lo := bits.Mul64(a, b)
	if hi == 0 {
		return isqrt(lo)
	}
	// sqrt of a 128-bit number < 2^64. Start above the root and descend.
	x := ^uint64(0)
	for i := 0; i < 200; i++ {
		if hi >= x { // product/x overflows ⇒ x below the root; cannot happen when descending from max
			panic("isqrt: bad state")
		}
		q, _ := bits.Div64(hi, lo, x)
		nx := (x >> 1) + (q >> 1) + (x & q & 1)
		if nx >= x {
			return x
		}
		x = nx
	}
	panic("isqrt: no convergence")
}

func isqrt(n uint64) uint64 {
	if n < 2 {
		return n
	}
	x := n
	y := x/2 + 1
	for i := 0; i < 200 && y < x; i++ {
		x = y
		y = (x + n/x) / 2
	}
	return x
}

// mulLess reports a*b < c*d using 128-bit products.
func mulLess(a, b, c, d uint64) bool {
	h1, l1 := bits.Mul64(a, b)
	h2, l2 := bits.Mul64(c, d)
	return h1 < h2 || (h1 == h2 && l1 < l2)
}

// requireBalance checks a balance before any write, so a failing call
// changes nothing (validate-then-write).
func requireBalance(addr, coin string, amt uint64) {
	if have := balOf(addr, coin); have < amt {
		panic("insufficient " + coin + ": need " + u(amt) + " have " + u(have))
	}
}

func requireAmount(name string, v uint64) {
	if v == 0 || v > maxAmount {
		panic(name + " must be between 1 and " + strconv.FormatUint(maxAmount, 10))
	}
}

func u(n uint64) string { return strconv.FormatUint(n, 10) }

// ── gates ────────────────────────────────────────────────────────────────────

// exchangeCaller returns the caller for exchange writes. Only end users (an
// EOA MsgCall or the user's own MsgRun) may trade: other realms can't act
// through the exchange, so there is no cross-realm call surface at all.
func exchangeCaller(cur realm) string {
	prev := cur.Previous()
	if prev.PkgPath() != "" {
		panic("exchange calls must come directly from a user")
	}
	return prev.Address().String()
}

// requireMarketOpen gates NEW activity (swaps, deposits, orders, fills).
// Trading opens only after FinalizeMigration: MigrateBatch SETs balances, so
// trading before that could duplicate or lose escrowed coins.
func requireMarketOpen(caller string) {
	if !migrationFinalized {
		panic("exchange opens after FinalizeMigration")
	}
	if exPaused {
		panic("exchange paused: new trades are off; unstake and cancel still work")
	}
	if isBlacklisted(caller) {
		panic("address banned")
	}
}

func requireDeadline(deadline int64) {
	if deadline <= 0 {
		panic("deadline required (unix seconds)")
	}
	if time.Now().Unix() > deadline {
		panic("deadline passed")
	}
}

func requireCoin(coin string) int {
	r, ok := coinRarity[coin]
	if !ok {
		panic("unknown coin id: " + coin)
	}
	return r
}

// Trading is open to every account (Simion, 2026-10-11): no tool requirement
// to swap, post, fill or stake. Anti-spam comes from the 50-grin order
// minimum, the 2-grin post fee, the 0.5% taker/pool fees, the 20-open-orders
// limit per maker and the 2,000-grin minimum pool depth.

// No receive cap (Simion, 2026-10-11): every coin is freely transferable and
// tradable, whatever tools the receiver owns.

// ── protocol fees ────────────────────────────────────────────────────────────

// accrueProtocolFee splits amt of coin 50/50: the floor half to the admin's
// fee ledger, the rest to the casino pool. Both stay inside the realm.
func accrueProtocolFee(coin string, amt uint64) {
	if amt == 0 {
		return
	}
	half := amt / 2
	if half > 0 {
		setU(&adminFees, coin, addChk(getU(&adminFees, coin), half))
	}
	setU(&casinoPool, coin, addChk(getU(&casinoPool, coin), amt-half))
	casStat(coin, "", "fees", amt-half)
	chain.Emit("ProtocolFeesAccrued", "coin", coin, "admin", u(half), "casino", u(amt-half))
}

// WithdrawProtocolFees moves the admin's OWN accrued fees for `coin` into the
// admin's balance. It reads only adminFees (never reserves, escrow, the
// casino pool or anyone's balance) and works while paused.
func WithdrawProtocolFees(cur realm, coin string) uint64 {
	requireAdmin(cur)
	requireCoin(coin)
	amt := getU(&adminFees, coin)
	if amt == 0 {
		panic("no fees to withdraw for " + coin)
	}
	adminFees.Remove(coin)
	setU(&adminFeesWithdrawn, coin, addChk(getU(&adminFeesWithdrawn, coin), amt))
	to := admin.String()
	creditBal(to, coin, amt)
	chain.Emit("ProtocolFeesWithdrawn", "coin", coin, "to", to, "amount", u(amt))
	return amt
}

// ── casino pool (fee share + losing stakes in, wins out; never minted) ─────
//
// casinoPool[coin]     total pool, including the reserved part
// casinoReserved[coin] sum of potential net payouts of unsettled bets
// casinoDay[coin]      "day:snapshot:paid:received" for the current UTC day
//
// A bet is accepted only if the pool can pay it in full: its potential net
// payout (= the stake, since a win pays 2×) is reserved at placement, so a
// reveal never pays partially and the pool can't go below zero.









// ── admin controls (launch only; none touch user funds) ──────────────────────

// SetExchangePaused stops NEW swaps, deposits, orders and fills. It can't
// stop RemoveLiquidity, CancelOrder, SweepExpiredOrders or fee withdrawals.
func SetExchangePaused(cur realm, p bool) {
	requireAdmin(cur)
	exPaused = p
	chain.Emit("ExchangePaused", "paused", strconv.FormatBool(p))
}

func ExchangeStatus() string {
	return `{"open":` + strconv.FormatBool(migrationFinalized && !exPaused) +
		`,"paused":` + strconv.FormatBool(exPaused) +
		`,"finalized":` + strconv.FormatBool(migrationFinalized) +
		`,"pools":` + strconv.Itoa(pools.Size()) +
		`,"openOrders":` + strconv.FormatUint(openOrderTotal, 10) +
		`,"nextOrderId":"` + u(nextOrderId) + `"` +
		`,"poolFeeBps":` + u(poolFeeBps) + `,"protoFeeBps":` + u(protoFeeBps) +
		`,"takerFeeBps":` + u(takerFeeBps) + `,"makerFeeBps":` + u(makerFeeBps) +
		`,"postFeeGrin":0` +
		`,"minOpenDepthGrin":` + u(minOpenDepthGrin) + `,"warmupSecs":` + strconv.FormatInt(warmupSecs, 10) + `}`
}

func ProtocolFees(coin string) string {
	return `{"coin":` + jsonStr(coin) + `,"admin":"` + u(getU(&adminFees, coin)) +
		`","adminWithdrawn":"` + u(getU(&adminFeesWithdrawn, coin)) +
		`","casino":"` + u(getU(&casinoPool, coin)) + `"}`
}
