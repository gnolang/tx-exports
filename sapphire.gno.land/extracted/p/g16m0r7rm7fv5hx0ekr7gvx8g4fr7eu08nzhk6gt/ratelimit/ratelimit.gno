package ratelimit

// TokenBucket implements a simple token-bucket rate limiter.
type TokenBucket struct {
	Capacity        int64
	RefillPerBlock  int64
	Tokens          int64
	LastRefillBlock int64
}

// NewTokenBucket creates a new bucket, starting full.
func NewTokenBucket(capacity int64, refillPerBlock int64, nowBlock int64) *TokenBucket {
	if capacity <= 0 {
		panic("ratelimit: capacity must be positive")
	}
	if refillPerBlock < 0 {
		panic("ratelimit: refillPerBlock must be non-negative")
	}
	return &TokenBucket{
		Capacity:        capacity,
		RefillPerBlock:  refillPerBlock,
		Tokens:          capacity,
		LastRefillBlock: nowBlock,
	}
}

func (tb *TokenBucket) refill(nowBlock int64) {
	if nowBlock <= tb.LastRefillBlock {
		return
	}
	elapsed := nowBlock - tb.LastRefillBlock
	refill := elapsed * tb.RefillPerBlock
	tb.Tokens += refill
	if tb.Tokens > tb.Capacity {
		tb.Tokens = tb.Capacity
	}
	tb.LastRefillBlock = nowBlock
}

// Allow attempts to consume `cost` tokens at block `nowBlock`.
// Returns true and deducts tokens if allowed, false otherwise.
func (tb *TokenBucket) Allow(nowBlock int64, cost int64) bool {
	if cost <= 0 {
		panic("ratelimit: cost must be positive")
	}
	tb.refill(nowBlock)
	if tb.Tokens < cost {
		return false
	}
	tb.Tokens -= cost
	return true
}

// Peek returns the number of tokens available at nowBlock without consuming.
func (tb *TokenBucket) Peek(nowBlock int64) int64 {
	tb.refill(nowBlock)
	return tb.Tokens
}
