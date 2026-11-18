package dca

import (
	u256 "gno.land/p/gnoswap/uint256/v1"
)

// PairPriceLimit is the minimum pool output a round of one pair direction
// accepts per unit of input, set by the pool manager from an oracle price.
//
// minOutputPerInputX128 is raw outputToken units, before the execution fee,
// per raw inputToken unit, in Q128 fixed point.
// Rounds use it as the pool swap price limit, so it bounds both the price
// and the ticks a quote or swap may cross.
// updatedAt is the unix time it was set; a limit older than
// Config.MaxPairPriceLimitAge leaves no pool eligible.
type PairPriceLimit struct {
	minOutputPerInputX128 *u256.Uint
	updatedAt             int64
}

// NewPairPriceLimit returns a limit of minOutputPerInputX128, set at updatedAt.
func NewPairPriceLimit(minOutputPerInputX128 *u256.Uint, updatedAt int64) *PairPriceLimit {
	return &PairPriceLimit{
		minOutputPerInputX128: minOutputPerInputX128.Clone(),
		updatedAt:             updatedAt,
	}
}

// MinOutputPerInputX128 returns a copy of the limit.
func (l *PairPriceLimit) MinOutputPerInputX128() *u256.Uint {
	return l.minOutputPerInputX128.Clone()
}

// UpdatedAt returns the unix time the limit was set.
func (l *PairPriceLimit) UpdatedAt() int64 { return l.updatedAt }

// Update replaces the limit and its update time in place.
func (l *PairPriceLimit) Update(minOutputPerInputX128 *u256.Uint, updatedAt int64) {
	l.minOutputPerInputX128 = minOutputPerInputX128.Clone()
	l.updatedAt = updatedAt
}

// Clone returns a copy of the limit.
func (l *PairPriceLimit) Clone() *PairPriceLimit {
	return NewPairPriceLimit(l.minOutputPerInputX128, l.updatedAt)
}
