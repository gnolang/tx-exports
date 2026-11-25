// Package dice holds the pure math behind Tavern Dice: deriving a dice
// roll from seed bytes and computing payouts. It keeps no state, so it is
// a package (p/), not a realm. All functions are deterministic and safe
// to unit test without any chain context.
package dice

import (
	"crypto/sha256"
	"encoding/binary"
	"math/overflow"
)

// RollFromSeed derives a dice roll in [1, 6] from arbitrary seed bytes.
// The seed is hashed with SHA-256 and the first 8 bytes are taken modulo 6.
// Uniformity: 2^64 mod 6 leaves a negligible bias (~1e-19), fine for a game.
func RollFromSeed(seed []byte) int {
	h := sha256.Sum256(seed)
	v := binary.BigEndian.Uint64(h[:8])
	return int(v%6) + 1
}

// NumberPayout returns the total payout (stake included) for a winning
// single-number bet: 5x the stake. Fair odds for a 1-in-6 guess would be
// 6x, so the house edge is 1/6 (~16.7%).
func NumberPayout(bet int64) int64 {
	p, ok := overflow.Mul64(bet, 5)
	if !ok {
		panic("payout overflow")
	}
	return p
}

// ParityPayout returns the total payout (stake included) for a winning
// odd/even bet: 1.9x the stake (bet*19/10). Fair odds would be 2x, so
// the house edge is 5%.
func ParityPayout(bet int64) int64 {
	p, ok := overflow.Mul64(bet, 19)
	if !ok {
		panic("payout overflow")
	}
	return p / 10
}

// MaxNumberBet caps a single-number bet so that the worst-case payout
// (5x the stake) never exceeds a quarter of the bankroll.
func MaxNumberBet(bankroll int64) int64 {
	if bankroll <= 0 {
		return 0
	}
	return bankroll / 20
}

// MaxParityBet caps an odd/even bet so that the worst-case payout
// (1.9x the stake) never exceeds a quarter of the bankroll.
func MaxParityBet(bankroll int64) int64 {
	if bankroll <= 0 {
		return 0
	}
	return bankroll / 8
}
