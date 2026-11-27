// Package parimutuel is a reusable, coin-agnostic accounting engine for
// binary (YES/NO) pari-mutuel pools.
//
// Everyone who backs a side shares the whole pool, pro rata to their stake,
// if their side wins. There is no order book and no counterparty matching:
// a single bettor can always place a bet, which makes it a good fit for
// young markets with thin liquidity.
//
// The package never moves coins. It only keeps the ledger. The realm that
// owns a Pool is responsible for receiving stakes and sending payouts, which
// lets any realm (prediction markets, sports pools, tournament brackets,
// "will this ship by Friday" office pools) reuse the same audited math.
//
// Lifecycle:
//
//	pool := parimutuel.New(100)          // 1% fee, in basis points
//	pool.Place(alice, parimutuel.Yes, 5_000_000)
//	pool.Place(bob, parimutuel.No, 3_000_000)
//	pool.Resolve(parimutuel.Yes)         // or parimutuel.Void
//	amount, _ := pool.Claim(alice)       // realm then sends `amount`
//
// Rules:
//   - If the winning side has no stake, the pool is voided automatically and
//     everyone is refunded in full (no fee).
//   - A voided pool refunds every stake in full (no fee).
//   - The fee is taken once, from the total pool, only when there is a winner.
//   - Payouts round down; any dust stays with the owning realm.
package parimutuel

import (
	"errors"
	"math/bits"

	"gno.land/p/nt/avl/v0"
)

// Outcome is the state of a pool, and also identifies a side when placing.
type Outcome int

const (
	Pending Outcome = iota
	Yes
	No
	Void
)

// MaxFeeBps caps the fee a pool can charge (5%).
const MaxFeeBps int64 = 500

var (
	ErrInvalidSide     = errors.New("parimutuel: side must be Yes or No")
	ErrInvalidAmount   = errors.New("parimutuel: amount must be positive")
	ErrAlreadyResolved = errors.New("parimutuel: pool already resolved")
	ErrNotResolved     = errors.New("parimutuel: pool not resolved yet")
	ErrInvalidOutcome  = errors.New("parimutuel: outcome must be Yes, No or Void")
	ErrNoPosition      = errors.New("parimutuel: no position in this pool")
	ErrAlreadyClaimed  = errors.New("parimutuel: already claimed")
	ErrNothingToClaim  = errors.New("parimutuel: nothing to claim")
	ErrOverflow        = errors.New("parimutuel: pool too large")
)

// String returns a lowercase label for the outcome.
func (o Outcome) String() string {
	switch o {
	case Pending:
		return "pending"
	case Yes:
		return "yes"
	case No:
		return "no"
	case Void:
		return "void"
	}
	return "unknown"
}

// ParseSide converts "yes"/"no" (any case) into an Outcome.
func ParseSide(s string) (Outcome, error) {
	switch s {
	case "yes", "YES", "Yes", "y", "Y":
		return Yes, nil
	case "no", "NO", "No", "n", "N":
		return No, nil
	}
	return Pending, ErrInvalidSide
}

// Position is one address's stake in a pool.
type Position struct {
	Yes     int64
	No      int64
	Claimed bool
}

// Total returns the address's combined stake on both sides.
func (p *Position) Total() int64 { return p.Yes + p.No }

// Pool is a binary pari-mutuel pool.
type Pool struct {
	yes       int64
	no        int64
	feeBps    int64
	fee       int64 // fee actually taken, set on resolution
	outcome   Outcome
	positions avl.Tree // address.String() -> *Position
}

// New creates an empty pool charging feeBps basis points on resolution.
// feeBps is clamped to [0, MaxFeeBps].
func New(feeBps int64) *Pool {
	if feeBps < 0 {
		feeBps = 0
	}
	if feeBps > MaxFeeBps {
		feeBps = MaxFeeBps
	}
	return &Pool{feeBps: feeBps}
}

// Place records a stake of amount on side for who.
func (p *Pool) Place(who address, side Outcome, amount int64) error {
	if p.outcome != Pending {
		return ErrAlreadyResolved
	}
	if side != Yes && side != No {
		return ErrInvalidSide
	}
	if amount <= 0 {
		return ErrInvalidAmount
	}
	if p.yes+p.no+amount < p.yes+p.no { // int64 overflow guard
		return ErrOverflow
	}

	pos := p.position(who)
	if pos == nil {
		pos = &Position{}
		p.positions.Set(who.String(), pos)
	}
	if side == Yes {
		pos.Yes += amount
		p.yes += amount
	} else {
		pos.No += amount
		p.no += amount
	}
	return nil
}

// Resolve settles the pool. If the winning side is empty the pool is voided.
// It returns the final outcome actually applied.
func (p *Pool) Resolve(o Outcome) (Outcome, error) {
	if p.outcome != Pending {
		return p.outcome, ErrAlreadyResolved
	}
	if o != Yes && o != No && o != Void {
		return Pending, ErrInvalidOutcome
	}
	if (o == Yes && p.yes == 0) || (o == No && p.no == 0) {
		o = Void
	}
	p.outcome = o
	if o != Void {
		// Only charge a fee when someone actually lost money to winners.
		if p.loserPool() > 0 {
			p.fee = mulDiv(p.Total(), p.feeBps, 10_000)
		}
	}
	return o, nil
}

// Payout returns what who can claim, without claiming. Zero while pending.
func (p *Pool) Payout(who address) int64 {
	pos := p.position(who)
	if pos == nil || pos.Claimed {
		return 0
	}
	return p.payoutFor(pos)
}

// Claim marks who's position as claimed and returns the amount the owning
// realm must now send to who.
func (p *Pool) Claim(who address) (int64, error) {
	if p.outcome == Pending {
		return 0, ErrNotResolved
	}
	pos := p.position(who)
	if pos == nil {
		return 0, ErrNoPosition
	}
	if pos.Claimed {
		return 0, ErrAlreadyClaimed
	}
	amount := p.payoutFor(pos)
	pos.Claimed = true
	if amount == 0 {
		return 0, ErrNothingToClaim
	}
	return amount, nil
}

func (p *Pool) payoutFor(pos *Position) int64 {
	switch p.outcome {
	case Void:
		return pos.Total()
	case Yes:
		if pos.Yes == 0 {
			return 0
		}
		return mulDiv(pos.Yes, p.Total()-p.fee, p.yes)
	case No:
		if pos.No == 0 {
			return 0
		}
		return mulDiv(pos.No, p.Total()-p.fee, p.no)
	}
	return 0
}

func (p *Pool) loserPool() int64 {
	if p.outcome == Yes {
		return p.no
	}
	if p.outcome == No {
		return p.yes
	}
	return 0
}

func (p *Pool) position(who address) *Position {
	v := p.positions.Get(who.String())
	if v == nil {
		return nil
	}
	return v.(*Position)
}

// Position returns a copy of who's position (zero value if none).
func (p *Pool) Position(who address) Position {
	pos := p.position(who)
	if pos == nil {
		return Position{}
	}
	return *pos
}

// Outcome returns the pool's current state.
func (p *Pool) Outcome() Outcome { return p.outcome }

// YesStake returns the total staked on YES.
func (p *Pool) YesStake() int64 { return p.yes }

// NoStake returns the total staked on NO.
func (p *Pool) NoStake() int64 { return p.no }

// Total returns the whole pool.
func (p *Pool) Total() int64 { return p.yes + p.no }

// FeeBps returns the configured fee in basis points.
func (p *Pool) FeeBps() int64 { return p.feeBps }

// Fee returns the fee actually taken (0 until resolved, 0 if void).
func (p *Pool) Fee() int64 { return p.fee }

// Bettors returns how many distinct addresses hold a position.
func (p *Pool) Bettors() int { return p.positions.Size() }

// YesBps returns YES's share of the pool in basis points (0..10000).
// An empty pool reports 5000 (even).
func (p *Pool) YesBps() int64 {
	t := p.Total()
	if t == 0 {
		return 5000
	}
	return mulDiv(p.yes, 10_000, t)
}

// Multiplier returns, in basis points, the gross return per unit staked on
// side if that side won right now (e.g. 25000 = 2.5x). Zero if side is empty.
func (p *Pool) Multiplier(side Outcome) int64 {
	var s int64
	if side == Yes {
		s = p.yes
	} else if side == No {
		s = p.no
	}
	if s == 0 {
		return 0
	}
	if s == p.Total() {
		// Nobody on the other side: a win is a full refund, and no fee is taken.
		return 10_000
	}
	net := p.Total() - mulDiv(p.Total(), p.feeBps, 10_000)
	return mulDiv(net, 10_000, s)
}

// IterPositions calls fn for each position until fn returns true.
func (p *Pool) IterPositions(fn func(who string, pos Position) bool) {
	p.positions.Iterate("", "", func(key string, value any) bool {
		return fn(key, *(value.(*Position)))
	})
}

// mulDiv returns a*b/c using a 128-bit intermediate, for non-negative inputs.
// It panics on a zero divisor or if the result does not fit in int64.
func mulDiv(a, b, c int64) int64 {
	if a < 0 || b < 0 || c <= 0 {
		panic("parimutuel: mulDiv invalid input")
	}
	hi, lo := bits.Mul64(uint64(a), uint64(b))
	if hi >= uint64(c) {
		panic(ErrOverflow.Error())
	}
	q, _ := bits.Div64(hi, lo, uint64(c))
	if q > uint64(1<<63-1) {
		panic(ErrOverflow.Error())
	}
	return int64(q)
}
