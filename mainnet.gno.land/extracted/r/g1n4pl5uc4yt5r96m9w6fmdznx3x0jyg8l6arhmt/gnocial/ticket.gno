package gnocial

import (
	"chain"
	"math/overflow"
	"strconv"
	"strings"
)

// QuoteBuy is the exact ugnot a buyer must attach to mint amount tickets.
// The total fee is always FeeCapBps of the curve. An anonymous quote pays
// no trader-referrer slice, so that slice stays in the protocol fee.
// The amount due does not change when the buyer is known.
func QuoteBuy(handle string, amount int) (due, curve, creatorFee, protocolFee, referralFee int64) {
	return QuoteBuyFor(handle, "", amount)
}

// QuoteBuyFor is QuoteBuy with the buyer's address. Empty or a member with
// no referrer adds no trader-referrer slice. A bad address panics.
func QuoteBuyFor(handle, buyer string, amount int) (due, curve, creatorFee, protocolFee, referralFee int64) {
	curve, creatorFee, protocolFee, referralFee = quoteTotals(handle, buyer, amount, false)
	due = overflow.Add64p(curve, overflow.Add64p(creatorFee, overflow.Add64p(protocolFee, referralFee)))
	return
}

// QuoteSell is what a seller receives. The reserve drops by the full curve.
// Proceeds are the curve minus FeeCapBps, whoever the seller is.
func QuoteSell(handle string, amount int) (proceeds, curve, creatorFee, protocolFee, referralFee int64) {
	return QuoteSellFor(handle, "", amount)
}

// QuoteSellFor is QuoteSell with the seller's address.
func QuoteSellFor(handle, seller string, amount int) (proceeds, curve, creatorFee, protocolFee, referralFee int64) {
	curve, creatorFee, protocolFee, referralFee = quoteTotals(handle, seller, amount, true)
	proceeds = curve - creatorFee - protocolFee - referralFee
	if proceeds <= 0 {
		panic("proceeds")
	}
	return
}

// Buy mints amount tickets of handle. Attach exactly QuoteBuy's due in ugnot.
// The caller's own referrer receives the trader slice. The due matches QuoteBuy.
func Buy(cur realm, handle string, amount int) {
	who := caller(cur)
	if state.paused {
		panic("paused")
	}
	mustMember(who)
	curve, creatorFee, protocolFee, creatorRefAmt, traderRefAmt, p, creatorRef, traderRef := tradeQuote(handle, who.String(), amount, false)
	due := overflow.Add64p(curve, bps(curve, FeeCapBps))
	sent := takeUgnot(cur)
	if sent != due {
		panic("send exactly " + strconv.FormatInt(due, 10) + "ugnot")
	}
	b := bookOf(p.Addr)
	b.Supply += amount
	b.Reserve = overflow.Add64p(b.Reserve, curve)
	state.totalReserve = overflow.Add64p(state.totalReserve, curve)
	addShares(who, p.Addr, amount)
	forwardFees(cur, p, creatorFee, protocolFee, creatorRef, creatorRefAmt, traderRef, traderRefAmt)
	chain.Emit(
		"ArenaBuy",
		"buyer", who.String(),
		"creator", p.Addr.String(),
		"handle", p.Handle,
		"amount", strconv.Itoa(amount),
		"curve", strconv.FormatInt(curve, 10),
		"due", strconv.FormatInt(due, 10),
	)
}

// Sell burns amount tickets and pays the caller from the reserve, minus fees.
// Sells stay available while the realm is paused.
func Sell(cur realm, handle string, amount int) {
	who := caller(cur)
	mustNoPay()
	mustMember(who)
	curve, creatorFee, protocolFee, creatorRefAmt, traderRefAmt, p, creatorRef, traderRef := tradeQuote(handle, who.String(), amount, true)
	if getShares(who, p.Addr) < amount {
		panic("not enough tickets")
	}
	proceeds := curve - bps(curve, FeeCapBps)
	if proceeds <= 0 {
		panic("proceeds")
	}
	b := bookOf(p.Addr)
	if b.Reserve < curve || state.totalReserve < curve {
		panic("insolvent")
	}
	b.Supply -= amount
	b.Reserve = overflow.Sub64p(b.Reserve, curve)
	state.totalReserve = overflow.Sub64p(state.totalReserve, curve)
	subShares(who, p.Addr, amount)
	payout(cur, who, proceeds, "seller")
	forwardFees(cur, p, creatorFee, protocolFee, creatorRef, creatorRefAmt, traderRef, traderRefAmt)
	chain.Emit(
		"ArenaSell",
		"seller", who.String(),
		"creator", p.Addr.String(),
		"handle", p.Handle,
		"amount", strconv.Itoa(amount),
		"curve", strconv.FormatInt(curve, 10),
		"proceeds", strconv.FormatInt(proceeds, 10),
	)
}

func forwardFees(cur realm, creator *Profile, creatorFee, protocolFee int64, creatorRef address, creatorRefAmt int64, traderRef address, traderRefAmt int64) {
	if protocolFee > 0 && !state.treasury.IsValid() {
		panic("treasury not set")
	}
	payout(cur, creator.Addr, creatorFee, "creator")
	payout(cur, state.treasury, protocolFee, "treasury")
	if creatorRefAmt > 0 {
		payout(cur, creatorRef, creatorRefAmt, "creator-referrer")
	}
	if traderRefAmt > 0 {
		payout(cur, traderRef, traderRefAmt, "trader-referrer")
	}
}

func addShares(holder, creator address, n int) {
	if n < 1 {
		panic("amount")
	}
	had := getShares(holder, creator)
	setShares(holder, creator, had+n)
	if had == 0 {
		bookOf(creator).Holders++
	}
}

func subShares(holder, creator address, n int) {
	had := getShares(holder, creator)
	if n < 1 || had < n {
		panic("not enough tickets")
	}
	setShares(holder, creator, had-n)
	if had == n {
		b := bookOf(creator)
		if b.Holders > 0 {
			b.Holders--
		}
	}
}

func quoteTotals(handle, trader string, amount int, sell bool) (curve, creatorFee, protocolFee, referralFee int64) {
	var creatorRefAmt, traderRefAmt int64
	curve, creatorFee, protocolFee, creatorRefAmt, traderRefAmt, _, _, _ = tradeQuote(handle, trader, amount, sell)
	referralFee = overflow.Add64p(creatorRefAmt, traderRefAmt)
	return
}

// tradeQuote splits FeeCapBps of the curve. trader is the buyer or seller.
// Empty means an anonymous quote: no trader-referrer slice.
// protocolFee is the cap minus the floored slices, so it cannot go negative
// while the configured slices fit inside the cap.
func tradeQuote(handle, trader string, amount int, sell bool) (curve, creatorFee, protocolFee, creatorRefAmt, traderRefAmt int64, creator *Profile, creatorRef, traderRef address) {
	creator = lookup(handle)
	if creator == nil {
		panic("unknown handle")
	}
	b := bookOf(creator.Addr)
	start := b.Supply
	if sell {
		if amount < 1 || amount > MaxTrade {
			panic("amount")
		}
		if amount > b.Supply {
			panic("not enough tickets")
		}
		start = b.Supply - amount
	}
	curve = curveCost(start, amount)
	points := creator.CreatorFee
	if points < CreatorFeeMinBps || points > CreatorFeeMaxBps {
		panic("fee")
	}
	creatorRef = creator.Referrer
	traderRef = traderReferrer(trader)
	total := bps(curve, FeeCapBps)
	creatorFee = bps(curve, points)
	if creatorRef.IsValid() {
		creatorRefAmt = bps(curve, CreatorReferralBps)
	}
	if traderRef.IsValid() {
		traderRefAmt = bps(curve, TraderReferralBps)
	}
	used := overflow.Add64p(creatorFee, overflow.Add64p(creatorRefAmt, traderRefAmt))
	if used > total {
		panic("fee")
	}
	protocolFee = total - used
	return
}

func traderReferrer(raw string) address {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return address("")
	}
	if len(raw) > 60 {
		panic("bad address")
	}
	who := address(raw)
	if !who.IsValid() {
		panic("bad address")
	}
	p := profileByAddr(who)
	if p == nil || !p.Referrer.IsValid() {
		return address("")
	}
	return p.Referrer
}

func bps(amount, points int64) int64 {
	if amount == 0 || points == 0 {
		return 0
	}
	if amount < 0 || points < 0 {
		panic("fee")
	}
	return overflow.Mul64p(amount, points) / 10_000
}

// curveCost is the ugnot reserve needed to move `amount` tickets starting at supply.
// Ticket i (1-based) is priced i² * TicketUnit. The sum of squares is exact.
func curveCost(supply, amount int) int64 {
	if amount < 1 || amount > MaxTrade {
		panic("amount")
	}
	if supply < 0 {
		panic("supply")
	}
	from := int64(supply)
	to := from + int64(amount)
	if to > int64(MaxSupply) {
		panic("supply cap")
	}
	return overflow.Mul64p(sumSq(to)-sumSq(from), TicketUnit)
}

func sumSq(n int64) int64 {
	if n <= 0 {
		return 0
	}
	if n > int64(MaxSupply) {
		panic("supply cap")
	}
	// n*(n+1)*(2n+1)/6, dividing 2 and 3 out before multiplying.
	a := n
	b := n + 1
	if a%2 == 0 {
		a /= 2
	} else {
		b /= 2
	}
	c := 2*n + 1
	if a%3 == 0 {
		a /= 3
	} else if b%3 == 0 {
		b /= 3
	} else if c%3 == 0 {
		c /= 3
	} else {
		panic("sumSq")
	}
	return overflow.Mul64p(overflow.Mul64p(a, b), c)
}
