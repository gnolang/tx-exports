// Package ratelimit provides a token-bucket rate limiter for use inside
// gno.land realms. It holds no chain state itself -- the importing realm
// owns a *TokenBucket (typically as a struct field or inside an avl.Tree
// keyed by caller address) and passes in the current block height on
// every check, since a pure package can't call chain/runtime itself.
package ratelimit

import (
	"math/overflow"
)

// TokenBucket implements the classic token-bucket algorithm. Tokens
// refill linearly with block height and are capped at Capacity.
type TokenBucket struct {
	Capacity        int64
	RefillPerBlock  int64
	Tokens          int64
	LastRefillBlock int64
}

// NewTokenBucket creates a bucket starting full (Tokens == capacity).
// capacity and refillPerBlock must both be positive.
func NewTokenBucket(capacity, refillPerBlock, nowBlock int64) *TokenBucket {
	if capacity <= 0 {
		panic("ratelimit: capacity must be positive")
	}
	if refillPerBlock <= 0 {
		panic("ratelimit: refillPerBlock must be positive")
	}

	return &TokenBucket{
		Capacity:        capacity,
		RefillPerBlock:  refillPerBlock,
		Tokens:          capacity,
		LastRefillBlock: nowBlock,
	}
}

// refill tops up tokens based on elapsed blocks since the last refill,
// capped at Capacity. If elapsed*rate would overflow int64 (e.g. the
// bucket sat unused for a very long time with a high refill rate), that
// is treated as "more than enough to fill it" and capped directly --
// a long idle gap is normal behavior for a rate limiter, not a bug, so
// this never panics on that account.
func (b *TokenBucket) refill(nowBlock int64) {
	if nowBlock <= b.LastRefillBlock {
		return
	}

	elapsed := nowBlock - b.LastRefillBlock
	added, ok := overflow.Mul64(elapsed, b.RefillPerBlock)
	if !ok {
		b.Tokens = b.Capacity
		b.LastRefillBlock = nowBlock
		return
	}

	newTokens, ok := overflow.Add64(b.Tokens, added)
	if !ok || newTokens > b.Capacity {
		newTokens = b.Capacity
	}

	b.Tokens = newTokens
	b.LastRefillBlock = nowBlock
}

// Allow refills the bucket up to nowBlock, then attempts to spend cost
// tokens. Returns true and deducts cost if there were enough tokens,
// false (no deduction) otherwise.
func (b *TokenBucket) Allow(nowBlock int64, cost int64) bool {
	if cost <= 0 {
		panic("ratelimit: cost must be positive")
	}

	b.refill(nowBlock)

	if b.Tokens < cost {
		return false
	}

	b.Tokens -= cost
	return true
}

// Peek refills the bucket up to nowBlock (mutating LastRefillBlock and
// Tokens, same as Allow would) and returns the resulting token count,
// without spending anything. Useful for a read-only "how many do I have
// right now" view function.
func (b *TokenBucket) Peek(nowBlock int64) int64 {
	b.refill(nowBlock)
	return b.Tokens
}
