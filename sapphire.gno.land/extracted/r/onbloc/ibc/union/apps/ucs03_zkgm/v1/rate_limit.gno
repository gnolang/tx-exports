package ucs03_zkgm

import (
	"time"

	u256 "gno.land/p/onbloc/math/uint256"
)

// errTokenBucketAbsent rejects a rate-limited denom that has no configured bucket,
// matching union's ContractError::TokenBucketIsAbsent.

// rateLimit charges `amount` from denom's token bucket when rate limiting is
// enabled. The bucket is anchored to block time, so its RefillRate is tokens per
// second. When rate limiting is enabled, a denom with no configured bucket is
// rejected (union TokenBucketIsAbsent) rather than passing unlimited.
// reference: https://github.com/unionlabs/union/blob/d91c5e94354e15801bd5f82dc658eae3b79f2dad/cosmwasm/app/ucs03-zkgm/src/contract.rs#L3218-L3237
func (v *ucs03ZkgmV1) rateLimit(_ int, rlm realm, denom string, amount *u256.Uint) error {
	if v.store.RateLimitDisabled() || amount == nil {
		return nil
	}

	bucket, ok := v.store.GetTokenBucket(denom)
	if !ok || bucket == nil {
		return makeError(errTokenBucketAbsent, denom)
	}

	now := time.Now().Unix()

	return bucket.RateLimit(amount, u256.NewUint(uint64(now)))
}
