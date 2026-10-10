package arena

import (
	"chain"
	"math/overflow"
	"strconv"
)

// QuoteBuy is the exact ugnot a buyer must attach to mint amount tickets.
// due = curve + creator fee + protocol fee + referral fee.
// curve is what stays in the reserve. Fees are paid on top and forwarded.
func QuoteBuy(handle string, amount int) (due, curve, creatorFee, protocolFee, referralFee int64) {
	p := lookup(handle)
	if p == nil {
		panic("unknown handle")
	}
	curve = curveCost(bookOf(p.Addr).Supply, amount)
	creatorFee, protocolFee, referralFee = splitFees(curve, p.Referrer.IsValid())
	due = overflow.Add64p(curve, overflow.Add64p(creatorFee, overflow.Add64p(protocolFee, referralFee)))
	return
}

// QuoteSell is what a seller receives, and the fees taken out of the curve refund.
// The reserve drops by the full curve amount, so later sells stay solvent.
func QuoteSell(handle string, amount int) (proceeds, curve, creatorFee, protocolFee, referralFee int64) {
	p := lookup(handle)
	if p == nil {
		panic("unknown handle")
	}
	b := bookOf(p.Addr)
	if amount < 1 || amount > MaxTrade {
		panic("amount")
	}
	if amount > b.Supply {
		panic("not enough tickets")
	}
	curve = curveCost(b.Supply-amount, amount)
	creatorFee, protocolFee, referralFee = splitFees(curve, p.Referrer.IsValid())
	proceeds = curve - creatorFee - protocolFee - referralFee
	if proceeds <= 0 {
		panic("proceeds")
	}
	return
}

// Buy mints amount tickets of handle. Attach exactly QuoteBuy's due in ugnot.
func Buy(cur realm, handle string, amount int) {
	who := caller(cur)
	if state.paused {
		panic("paused")
	}
	mustMember(who)
	due, curve, creatorFee, protocolFee, referralFee := QuoteBuy(handle, amount)
	sent := takeUgnot(cur)
	if sent != due {
		panic("send exactly " + strconv.FormatInt(due, 10) + "ugnot")
	}
	p := lookup(handle)
	b := bookOf(p.Addr)
	b.Supply += amount
	b.Reserve = overflow.Add64p(b.Reserve, curve)
	state.totalReserve = overflow.Add64p(state.totalReserve, curve)
	addShares(who, p.Addr, amount)
	forwardFees(cur, p, creatorFee, protocolFee, referralFee)
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
	proceeds, curve, creatorFee, protocolFee, referralFee := QuoteSell(handle, amount)
	if getShares(who, lookup(handle).Addr) < amount {
		panic("not enough tickets")
	}
	p := lookup(handle)
	b := bookOf(p.Addr)
	if b.Reserve < curve || state.totalReserve < curve {
		panic("insolvent")
	}
	b.Supply -= amount
	b.Reserve = overflow.Sub64p(b.Reserve, curve)
	state.totalReserve = overflow.Sub64p(state.totalReserve, curve)
	subShares(who, p.Addr, amount)
	payout(cur, who, proceeds, "seller")
	forwardFees(cur, p, creatorFee, protocolFee, referralFee)
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

func forwardFees(cur realm, creator *Profile, creatorFee, protocolFee, referralFee int64) {
	if protocolFee > 0 && !state.treasury.IsValid() {
		panic("treasury not set")
	}
	payout(cur, creator.Addr, creatorFee, "creator")
	payout(cur, state.treasury, protocolFee, "treasury")
	if referralFee > 0 {
		payout(cur, creator.Referrer, referralFee, "referrer")
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

func splitFees(curve int64, referred bool) (creator, protocol, referral int64) {
	creator = bps(curve, CreatorFeeBps)
	protocol = bps(curve, ProtocolFeeBps)
	if referred {
		referral = bps(curve, ReferralFeeBps)
	}
	return
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
