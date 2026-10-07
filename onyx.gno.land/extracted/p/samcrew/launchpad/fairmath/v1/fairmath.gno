// Package fairmath prices whole-lot fair-sale commitments without holding
// funds. No sale is active until a separate realm accounts for custody and
// exit rights. All amounts are token or quote base units.
package fairmath

import sm "gno.land/p/samcrew/launchpad/safemath/v1"

const MaxWindowSeconds int64 = 365 * 24 * 60 * 60

// Schedule defines quote atoms per lot. A zero decrement is a fixed-price
// sale; otherwise the price falls by Decrement every IntervalSeconds, never
// below FloorPrice. End is the scheduled close instant. An inventory or hard-
// cap close must pass its recorded transaction time to PriceAt instead.
type Schedule struct {
	Start           int64
	End             int64
	StartPrice      int64
	FloorPrice      int64
	Decrement       int64
	IntervalSeconds int64
}

func (s Schedule) Validate() {
	if s.Start < 0 || s.End <= s.Start || s.End-s.Start > MaxWindowSeconds ||
		s.StartPrice <= 0 || s.FloorPrice <= 0 || s.FloorPrice > s.StartPrice ||
		s.Decrement < 0 || s.IntervalSeconds <= 0 ||
		(s.Decrement == 0 && s.FloorPrice != s.StartPrice) {
		panic("launchpad/fairmath: invalid schedule")
	}
}

func (s Schedule) PriceAt(at int64) int64 {
	s.Validate()
	if at < s.Start || at > s.End {
		panic("launchpad/fairmath: time outside sale")
	}
	if s.Decrement == 0 {
		return s.StartPrice
	}
	steps := (at - s.Start) / s.IntervalSeconds
	gap := sm.Sub(s.StartPrice, s.FloorPrice)
	stepsToFloor := sm.MulDivUp(gap, 1, s.Decrement)
	if steps >= stepsToFloor {
		return s.FloorPrice
	}
	return sm.Sub(s.StartPrice, sm.Mul(steps, s.Decrement))
}

// MaxLots requires the escrowed sale allocation to consist of whole lots.
// No token dust is created by dividing the allocation between buyers.
func MaxLots(allocation, lotSize int64) int64 {
	if allocation <= 0 || lotSize <= 0 || allocation%lotSize != 0 {
		panic("launchpad/fairmath: invalid lot allocation")
	}
	return allocation / lotSize
}

type Order struct {
	Lots    int64
	Tokens  int64
	Deposit int64
}

// Caps snapshots the sale's hard cap in whole lots and soft cap in quote
// atoms actually spent at the final clearing price. Entry deposits and later
// refunds do not count toward the soft cap.
type Caps struct {
	HardLots  int64
	SoftQuote int64
}

func (c Caps) Validate(allocation, lotSize, highestPrice int64) {
	maxLots := MaxLots(allocation, lotSize)
	if c.HardLots <= 0 || c.HardLots > maxLots || c.SoftQuote <= 0 ||
		highestPrice <= 0 {
		panic("launchpad/fairmath: invalid caps")
	}
	if c.SoftQuote > sm.Mul(c.HardLots, highestPrice) {
		panic("launchpad/fairmath: unreachable soft cap")
	}
}

// AddLots rejects an order that would exceed the hard cap. Equality signals
// an early close at the contribution transaction's block time.
func (c Caps) AddLots(current, order int64) (int64, bool) {
	if c.HardLots <= 0 || current < 0 || current > c.HardLots || order <= 0 {
		panic("launchpad/fairmath: invalid cap state")
	}
	next := sm.Add(current, order)
	if next > c.HardLots {
		panic("launchpad/fairmath: hard cap exceeded")
	}
	return next, next == c.HardLots
}

// QuoteOrder gives the exact token and quote amounts for a whole-lot order.
func QuoteOrder(lots, lotSize, entryPrice int64) Order {
	if lots <= 0 || lotSize <= 0 || entryPrice <= 0 {
		panic("launchpad/fairmath: invalid order")
	}
	return Order{
		Lots: lots, Tokens: sm.Mul(lots, lotSize),
		Deposit: sm.Mul(lots, entryPrice),
	}
}

type Settlement struct {
	Succeeded     bool
	SoldTokens    int64
	GrossQuote    int64
	RefundQuote   int64
	UnsoldTokens  int64
}

// Clear partitions all whole-lot commitments at one pinned clearing price.
// A missed soft cap returns all deposits and all tokens. On success,
// deposits above the clearing-price gross remain buyer refund liabilities.
func Clear(c Caps, allocation, lotSize, totalLots, totalDeposits, closePrice int64) Settlement {
	maxLots := MaxLots(allocation, lotSize)
	if c.HardLots <= 0 || c.HardLots > maxLots || c.SoftQuote <= 0 ||
		totalLots < 0 || totalLots > c.HardLots || totalDeposits < 0 || closePrice <= 0 {
		panic("launchpad/fairmath: invalid settlement")
	}
	sold := sm.Mul(totalLots, lotSize)
	gross := sm.Mul(totalLots, closePrice)
	if totalDeposits < gross {
		panic("launchpad/fairmath: unfunded settlement")
	}
	if gross < c.SoftQuote {
		return Settlement{RefundQuote: totalDeposits, UnsoldTokens: allocation}
	}
	return Settlement{
		Succeeded: true,
		SoldTokens: sold, GrossQuote: gross,
		RefundQuote: sm.Sub(totalDeposits, gross),
		UnsoldTokens: sm.Sub(allocation, sold),
	}
}

type BuyerClaim struct {
	Tokens      int64
	SpentQuote  int64
	RefundQuote int64
}

// Claim computes one buyer's exact rights after Clear. Claims over the same
// orders telescope to its aggregate settlement, regardless of claim order.
func Claim(success bool, lots, deposit, lotSize, closePrice int64) BuyerClaim {
	if lots <= 0 || deposit <= 0 || lotSize <= 0 || closePrice <= 0 {
		panic("launchpad/fairmath: invalid claim")
	}
	if !success {
		return BuyerClaim{RefundQuote: deposit}
	}
	spent := sm.Mul(lots, closePrice)
	if deposit < spent {
		panic("launchpad/fairmath: unfunded claim")
	}
	return BuyerClaim{
		Tokens: sm.Mul(lots, lotSize), SpentQuote: spent,
		RefundQuote: sm.Sub(deposit, spent),
	}
}
