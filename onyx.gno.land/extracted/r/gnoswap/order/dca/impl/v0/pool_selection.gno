package impl

import (
	"errors"
	"sort"
	"strconv"

	pdca "gno.land/p/gnoswap/order/dca/v0"
	ufmt "gno.land/p/nt/ufmt/v0"

	"gno.land/r/gnoswap/pool"
)

// Pool selection.
//
// A round trades on one direct pool of the pair, chosen at execution time:
//
//  1. candidates: whitelisted pools of the pair, one per fee tier, by fee
//  2. price limit: each pool sells only down to the pair price limit
//     (see price_limit.gno); a pair direction without a limit, a pool
//     already past it, or a pool displaced far on its favorable side
//     (Config.MaxPoolPriceDeviationRate) is ineligible without a quote, and
//     so is every pool while the limit is older than
//     Config.MaxPairPriceLimitAge
//  3. ranking: the pool whose DrySwap of the full round amount, within its
//     price limit, returns the most output, consuming all input;
//     ties keep the lower fee
//
// The price limit bounds the ticks a quote or a swap may cross, so a pool
// without liquidity near its price costs bounded gas and is simply ineligible
// when it cannot fill the round within the limit. Liquidity outside the
// current tick still counts.
//
// To save gas, a round quotes only when the pair has two or more pools.
// A single pool is used directly; the round reverts
// if that pool cannot absorb the full input within the limit.

// poolCandidate is one pool of the pair and its evaluation for a round.
type poolCandidate struct {
	poolPath          string
	fee               uint32
	sqrtPriceLimitX96 string // swap price limit under the pair price limit
	ineligibleCode    string // why the pool is ineligible, as a code; "" when eligible
	ineligibleReason  string // ineligibleCode in words, with details
	isQuoted          bool
	quotedAmountOut   int64 // pool output for the full round
	partialAmountOut  int64 // pool output of the consumed input of a partial fill; 0 otherwise
}

func (c *poolCandidate) isEligible() bool { return c.ineligibleCode == "" }

// poolWhitelist is the read-only membership contract used by pool selection.
// Production passes the common whitelist realm's read-only view; focused
// selection tests use an in-memory tree.
type poolWhitelist interface {
	Has(key string) bool
}

// getCandidatePools returns the whitelisted pools of the pair,
// ordered by fee tier.
func getCandidatePools(whitelistedPools poolWhitelist, inputToken string, outputToken string) []*poolCandidate {
	tickSpacings := pool.GetFeeAmountTickSpacings()

	fees := make([]int, 0, len(tickSpacings))
	for fee := range tickSpacings {
		fees = append(fees, int(fee))
	}

	sort.Ints(fees)

	candidates := []*poolCandidate{}

	for _, fee := range fees {
		poolPath := pool.GetPoolPath(inputToken, outputToken, uint32(fee))
		if whitelistedPools.Has(poolPath) && pool.ExistsPoolPath(poolPath) {
			candidates = append(candidates, &poolCandidate{poolPath: poolPath, fee: uint32(fee)})
		}
	}

	return candidates
}

// selectPool evaluates the pair's whitelisted pools for a round of amountIn
// under limit, the pair price limit (nil if none is set), and
// maxDeviationRate (Config.MaxPoolPriceDeviationRate), and maxLimitAge
// (Config.MaxPairPriceLimitAge), and returns the chosen
// pool (nil if none can fill it) with all candidates.
// quoteAll quotes every pool, even when the pair has only one.
func selectPool(
	whitelistedPools poolWhitelist,
	limit *pdca.PairPriceLimit,
	maxDeviationRate int64,
	maxLimitAge int64,
	inputToken string,
	outputToken string,
	amountIn int64,
	quoteAll bool,
) (*poolCandidate, []*poolCandidate) {
	candidates := getCandidatePools(whitelistedPools, inputToken, outputToken)
	if len(candidates) == 0 {
		return nil, candidates
	}

	zeroForOne, _, _ := swapDirection(inputToken, outputToken)
	for _, candidate := range candidates {
		candidate.sqrtPriceLimitX96, candidate.ineligibleCode, candidate.ineligibleReason = poolSqrtPriceLimit(
			candidate.poolPath, candidate.fee, zeroForOne, limit, maxDeviationRate, maxLimitAge,
		)
	}

	if len(candidates) == 1 && !quoteAll {
		if !candidates[0].isEligible() {
			return nil, candidates
		}

		return candidates[0], candidates
	}

	var bestCandidate *poolCandidate

	for _, candidate := range candidates {
		if !candidate.isEligible() {
			continue
		}

		quotedAmountOut, code, err := quoteExactIn(inputToken, outputToken, candidate.fee, candidate.sqrtPriceLimitX96, amountIn)
		if err != nil {
			candidate.ineligibleCode = code
			candidate.ineligibleReason = err.Error()

			if code == codePartialFill {
				candidate.partialAmountOut = quotedAmountOut
			}

			continue
		}

		candidate.isQuoted = true
		candidate.quotedAmountOut = quotedAmountOut

		if bestCandidate == nil || quotedAmountOut > bestCandidate.quotedAmountOut {
			bestCandidate = candidate
		}
	}

	return bestCandidate, candidates
}

// quoteReferenceAmountOut quotes selling amountIn at once, now, on the pair's
// best whitelisted pool within the pair price limit: what a one-off swap of
// the whole order would return. Order fills are measured against it. It is 0
// when no pool can absorb the whole amount within the limit.
func quoteReferenceAmountOut(
	whitelistedPools poolWhitelist,
	limit *pdca.PairPriceLimit,
	maxDeviationRate int64,
	maxLimitAge int64,
	inputToken string,
	outputToken string,
	amountIn int64,
) int64 {
	selectedPool, _ := selectPool(whitelistedPools, limit, maxDeviationRate, maxLimitAge, inputToken, outputToken, amountIn, true)
	if selectedPool == nil {
		return 0
	}

	return selectedPool.quotedAmountOut
}

// selectRoundPool is selectPool for execution. When no pool can fill the
// round, it returns an error listing each candidate's reason.
// A pair without a whitelisted pool has no candidates.
func selectRoundPool(
	whitelistedPools poolWhitelist,
	limit *pdca.PairPriceLimit,
	maxDeviationRate int64,
	maxLimitAge int64,
	group *pdca.Group,
	amountIn int64,
) (*poolCandidate, error) {
	selectedPool, candidates := selectPool(whitelistedPools, limit, maxDeviationRate, maxLimitAge, group.InputToken(), group.OutputToken(), amountIn, false)
	if selectedPool != nil {
		return selectedPool, nil
	}

	details := ufmt.Sprintf("groupId(%s)", group.ID())
	for _, candidate := range candidates {
		details += ufmt.Sprintf("; %s: %s", candidate.poolPath, candidate.ineligibleReason)
	}

	return nil, makeErrorWithDetails(errNoEligiblePool, details)
}

// quoteExactIn simulates selling amountIn on the pair's pool of fee tier fee,
// down to sqrtPriceLimitX96, and returns the pool output.
// It fails unless the whole input is consumed within the limit, and then
// also returns the ineligibility code of the failure. A partial fill
// (codePartialFill) returns the output of the input it consumed, 0 when the
// pool swapped nothing, such as one without liquidity; every other failure
// returns 0.
func quoteExactIn(inputToken string, outputToken string, fee uint32, sqrtPriceLimitX96 string, amountIn int64) (int64, string, error) {
	zeroForOne, token0, token1 := swapDirection(inputToken, outputToken)

	amount0, amount1, err := pool.DrySwap(token0, token1, fee, zeroForOne, strconv.FormatInt(amountIn, 10), sqrtPriceLimitX96)
	if err != nil {
		return 0, codeQuoteFailed, err
	}

	consumedAmount, outputAmount := amount0, amount1
	if !zeroForOne {
		consumedAmount, outputAmount = amount1, amount0
	}

	consumedAmountIn, err := strconv.ParseInt(consumedAmount, 10, 64)
	if err != nil {
		return 0, codeQuoteFailed, err
	}

	amountOut, err := strconv.ParseInt(outputAmount, 10, 64)
	if err != nil {
		return 0, codeQuoteFailed, err
	}

	if consumedAmountIn != amountIn {
		partialAmountOut := int64(0)
		if consumedAmountIn > 0 && amountOut < 0 {
			partialAmountOut = -amountOut
		}

		return partialAmountOut, codePartialFill, ufmt.Errorf("quote consumed %d of %d input", consumedAmountIn, amountIn)
	}

	if amountOut >= 0 {
		return 0, codeNoOutput, errors.New("quote returned no output")
	}

	return -amountOut, "", nil
}
