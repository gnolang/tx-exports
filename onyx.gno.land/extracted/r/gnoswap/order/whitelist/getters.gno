package whitelist

import (
	rotree "gno.land/p/nt/bptree/rotree/v0"

	"gno.land/r/gnoswap/pool"
)

func IsWhitelistedPool(target, poolPath string) bool {
	return getState(target).HasPool(poolPath)
}

// GetWhitelistedPools returns only target's read-only poolPath -> true tree.
func GetWhitelistedPools(target string) *rotree.ReadOnlyTree {
	return getState(target).Pools()
}

// HasWhitelistedPool reports whether target allows an existing direct pool of the pair.
func HasWhitelistedPool(target, tokenIn, tokenOut string) bool {
	state := getState(target)

	if tokenIn == tokenOut {
		return false
	}

	for fee := range pool.GetFeeAmountTickSpacings() {
		poolPath := pool.GetPoolPath(tokenIn, tokenOut, uint32(fee))
		if state.HasPool(poolPath) && pool.ExistsPoolPath(poolPath) {
			return true
		}
	}

	return false
}
