package sealed

import (
	"math/bits"
	"math/overflow"
	"sort"
	"strconv"
)

// bidsByPrice sorts highest price first. Equal prices are ordered by
// address only so the iteration is deterministic: equal prices are always
// treated as one group and split pro-rata, so this order never decides who
// gets tokens.
type bidsByPrice []*Bid

func (l bidsByPrice) Len() int { return len(l) }
func (l bidsByPrice) Less(i, j int) bool {
	if l[i].Price != l[j].Price {
		return l[i].Price > l[j].Price
	}
	return l[i].Bidder.String() < l[j].Bidder.String()
}
func (l bidsByPrice) Swap(i, j int) { l[i], l[j] = l[j], l[i] }

// settle fixes the auction's results. It reads every bid but writes only to
// the auction: a bid's fill is derived later from the stored cut-off.
func (a *Auction) settle(now int64) {
	if a.settled {
		panic("sealed: auction already settled")
	}
	if now < a.RevealEnd {
		panic("sealed: too early to settle, the reveal window closes at " + formatTime(a.RevealEnd))
	}

	var valid bidsByPrice
	var forfeits int64
	a.bids.Iterate("", "", func(_ string, v any) bool {
		b := v.(*Bid)
		switch {
		case !b.Revealed:
			forfeits += forfeitOf(b.Deposit)
		case b.Price >= a.ReservePrice:
			valid = append(valid, b)
		}
		return false
	})
	sort.Sort(valid)

	remaining := a.Supply
	var sold, clearing int64
	for i := 0; i < len(valid) && remaining > 0; {
		// One price level: every bid at this exact price.
		price := valid[i].Price
		j := i
		var demand int64
		for j < len(valid) && valid[j].Price == price {
			demand = mustAdd(demand, valid[j].Amount)
			j++
		}

		if demand <= remaining {
			// The whole level fits.
			remaining -= demand
			sold += demand
			a.hasFullFill = true
			a.fullFillMin = price
			clearing = price
		} else {
			// Supply runs out inside this level: split it pro-rata to the
			// amounts asked. Rounding dust (< one token unit per bidder)
			// stays unsold and returns to the seller.
			a.partialPrice = price
			a.partialSupply = remaining
			a.partialDemand = demand
			var levelSold int64
			for k := i; k < j; k++ {
				levelSold += proRata(valid[k].Amount, remaining, demand)
			}
			if levelSold > 0 {
				clearing = price
			}
			sold += levelSold
			remaining = 0
		}
		i = j
	}

	raised, ok := overflow.Mul64(clearing, sold)
	if !ok {
		panic("sealed: proceeds overflow")
	}
	a.clearingPrice = clearing
	a.sold = sold
	a.raised = raised
	a.forfeits = forfeits
	a.settled = true

	// No-show forfeits go to the winners, in proportion to tokens won, never
	// to the seller. Whatever is not shared (everything when nobody won,
	// otherwise rounding dust) is burned: it stays in the realm for good.
	var shared int64
	for _, b := range valid {
		shared += a.forfeitShareOf(b)
	}
	a.burned = forfeits - shared
}

// forfeitShareOf is a winning bid's cut of the no-show forfeits:
// forfeits * tokensWon / tokensSold, rounded down.
func (a *Auction) forfeitShareOf(b *Bid) int64 {
	if !a.settled || a.forfeits == 0 || a.sold == 0 {
		return 0
	}
	filled := a.fillOf(b)
	if filled == 0 {
		return 0
	}
	return proRata(filled, a.forfeits, a.sold)
}

// fillOf is how many token units a bid receives.
func (a *Auction) fillOf(b *Bid) int64 {
	if !a.settled || !b.Revealed || b.Price < a.ReservePrice {
		return 0
	}
	if a.hasFullFill && b.Price >= a.fullFillMin {
		return b.Amount
	}
	if a.partialDemand > 0 && b.Price == a.partialPrice {
		return proRata(b.Amount, a.partialSupply, a.partialDemand)
	}
	return 0
}

// Outcome is what one bid ends up with after settlement.
type Outcome struct {
	Filled       int64  // token units won
	Cost         int64  // ugnot paid: Filled * clearing price
	Refund       int64  // ugnot of the deposit returned
	ForfeitShare int64  // ugnot bonus: this winner's share of no-show forfeits
	Forfeit      int64  // ugnot lost for not revealing
	Status       string // human-readable result
}

// Payout is everything the bidder receives in ugnot at Claim.
func (o Outcome) Payout() int64 { return o.Refund + o.ForfeitShare }

func (a *Auction) outcomeOf(b *Bid) Outcome {
	if !b.Revealed {
		f := forfeitOf(b.Deposit)
		return Outcome{Refund: b.Deposit - f, Forfeit: f, Status: "No reveal (-" + strconv.Itoa(ForfeitPercent) + "%)"}
	}
	if !a.settled {
		return Outcome{Refund: b.Deposit, Status: "Revealed"}
	}
	filled := a.fillOf(b)
	// Safe: filled <= amount and clearing <= price, and price*amount <= deposit.
	cost := filled * a.clearingPrice
	o := Outcome{Filled: filled, Cost: cost, Refund: b.Deposit - cost, ForfeitShare: a.forfeitShareOf(b)}
	switch {
	case b.Price < a.ReservePrice:
		o.Status = "Below reserve"
	case filled == 0:
		o.Status = "Outbid"
	case filled < b.Amount:
		o.Status = "Partial fill"
	default:
		o.Status = "Won"
	}
	return o
}

// forfeitOf is ForfeitPercent of a deposit, rounded down, without overflow.
func forfeitOf(deposit int64) int64 {
	return deposit/100*ForfeitPercent + (deposit%100)*ForfeitPercent/100
}

// proRata returns floor(amount * supply / demand) using 128-bit math, so it
// cannot overflow. Requires 0 <= amount <= demand and demand > 0.
func proRata(amount, supply, demand int64) int64 {
	hi, lo := bits.Mul64(uint64(amount), uint64(supply))
	q, _ := bits.Div64(hi, lo, uint64(demand))
	return int64(q)
}

func mustAdd(a, b int64) int64 {
	c, ok := overflow.Add64(a, b)
	if !ok {
		panic("sealed: amount overflow")
	}
	return c
}
