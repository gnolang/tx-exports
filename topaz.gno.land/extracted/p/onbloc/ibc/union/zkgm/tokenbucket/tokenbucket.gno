package tokenbucket

import (
	"errors"

	u256 "gno.land/p/onbloc/math/uint256"
)

var (
	ErrZeroCapacity         = errors.New("tokenbucket: capacity must not be zero")
	ErrZeroRefillRate       = errors.New("tokenbucket: refill rate must not be zero")
	ErrRateLimitExceeded    = errors.New("tokenbucket: rate limit exceeded")
	ErrTokenBucketUnderflow = errors.New("tokenbucket: token bucket underflow")
)

type TokenBucket struct {
	Capacity   *u256.Uint
	Available  *u256.Uint
	RefillRate *u256.Uint
	LastRefill *u256.Uint
}

func New(capacity *u256.Uint, refillRate *u256.Uint, now *u256.Uint) (*TokenBucket, error) {
	if capacity.IsZero() {
		return nil, ErrZeroCapacity
	}

	if refillRate.IsZero() {
		return nil, ErrZeroRefillRate
	}

	return &TokenBucket{
		Capacity:   capacity.Clone(),
		Available:  capacity.Clone(),
		RefillRate: refillRate.Clone(),
		LastRefill: now.Clone(),
	}, nil
}

func (tb *TokenBucket) Refill(now *u256.Uint) {
	if now.Lte(tb.LastRefill) {
		return
	}

	if tb.Available.Gte(tb.Capacity) {
		tb.LastRefill.Set(now)
		return
	}

	elapsed, underflow := u256.Zero().SubOverflow(now, tb.LastRefill)
	if underflow {
		panic(ErrTokenBucketUnderflow)
	}

	toRefill := saturatingMul(tb.RefillRate, elapsed)
	tb.Available = min(tb.Capacity, saturatingAdd(tb.Available, toRefill))
	tb.LastRefill.Set(now)
}

func (tb *TokenBucket) RateLimit(amount *u256.Uint, now *u256.Uint) error {
	if amount.IsZero() {
		return nil
	}

	tb.Refill(now)

	if tb.Available.Lt(amount) {
		return ErrRateLimitExceeded
	}

	tb.Available = u256.Zero().Sub(tb.Available, amount)

	return nil
}

func (tb *TokenBucket) Update(capacity *u256.Uint, refillRate *u256.Uint, reset bool) error {
	if capacity.IsZero() {
		return ErrZeroCapacity
	}

	if refillRate.IsZero() {
		return ErrZeroRefillRate
	}

	tb.Capacity = capacity.Clone()
	tb.RefillRate = refillRate.Clone()

	// Mirror union's token_bucket update (token_bucket.rs L84-88): only reset
	// available on first init or explicit reset. Do NOT clamp available down when
	// capacity shrinks — union lets a now-excess available drain naturally.
	if tb.LastRefill.IsZero() || reset {
		tb.Available = tb.Capacity.Clone()
	}

	return nil
}

func saturatingAdd(x *u256.Uint, y *u256.Uint) *u256.Uint {
	z, overflow := u256.Zero().AddOverflow(x, y)
	if overflow {
		return u256.Zero().SetAllOne()
	}

	return z
}

func saturatingMul(x *u256.Uint, y *u256.Uint) *u256.Uint {
	z, overflow := u256.Zero().MulOverflow(x, y)
	if overflow {
		return u256.Zero().SetAllOne()
	}

	return z
}

func min(x *u256.Uint, y *u256.Uint) *u256.Uint {
	if x.Lte(y) {
		return x.Clone()
	}

	return y.Clone()
}
