package ucs03_zkgm

import (
	"time"

	tb "gno.land/p/onbloc/ibc/union/zkgm/tokenbucket"
	u256 "gno.land/p/onbloc/math/uint256"
	"gno.land/r/onbloc/ibc/union/access"
)

// SetBucketConfig creates or updates the per-denom send-side rate-limit bucket.
// The bucket is anchored to block time, so RefillRate is tokens per second.
func SetBucketConfig(cur realm, denom string, capacity *u256.Uint, refillRate *u256.Uint) {
	access.AssertCanCall(0, cur, SelectorSetBucketConfig)

	bucket, ok := store.GetTokenBucket(denom)
	if !ok {
		newBucket, err := tb.New(capacity, refillRate, u256.NewUint(uint64(time.Now().Unix())))
		if err != nil {
			panic(err)
		}

		store.SetTokenBucket(0, cur, denom, newBucket)
		emitZkgmRateLimitBucketConfiguredEvent(cur.Previous().Address(), denom, capacity, refillRate)

		return
	}

	err := bucket.Update(capacity, refillRate, false)
	if err != nil {
		panic(err)
	}

	emitZkgmRateLimitBucketConfiguredEvent(cur.Previous().Address(), denom, capacity, refillRate)
}

// SetRateLimitDisabled toggles the global rate-limit kill switch.
func SetRateLimitDisabled(cur realm, disabled bool) {
	access.AssertCanCall(0, cur, SelectorSetRateLimitDisabled)
	store.SetRateLimitDisabled(0, cur, disabled)
	emitZkgmRateLimitDisabledSetEvent(cur.Previous().Address(), disabled)
}

// Pausable toggles the global pause gate checked by every App receiver.
func Pausable(cur realm, p bool) {
	access.AssertCanCall(0, cur, SelectorPausable)
	paused = p
	if p {
		emitZkgmPausedEvent(cur.Previous().Address())
	} else {
		emitZkgmUnpausedEvent(cur.Previous().Address())
	}
}
