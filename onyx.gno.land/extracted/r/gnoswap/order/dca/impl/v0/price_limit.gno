package impl

import (
	"time"

	pdca "gno.land/p/gnoswap/order/dca/v0"
	u256 "gno.land/p/gnoswap/uint256/v1"
	bptree "gno.land/p/nt/bptree/v0"
	ufmt "gno.land/p/nt/ufmt/v0"

	"gno.land/r/gnoswap/pool"
)

// Pair price limits.
//
// A pair direction (inputToken -> outputToken) trades only with a price limit
// set by the pool manager from an oracle price: minOutputPerInputX128,
// the least pool output, in raw outputToken units before the execution fee,
// per raw inputToken unit, in Q128.
//
// Every quote and swap of the pair passes it to the pool as sqrtPriceLimitX96,
// after removing the pool's fee tier, so that:
//   - each unit of input is filled at a marginal rate of at least the limit,
//     which bounds what a round can lose to a moved pool price,
//     even when the keeper passes a loose amountOutMin;
//   - the pool walks ticks only between its current price and the limit,
//     which bounds the gas of a quote or a round on a pool without enough
//     liquidity near its price.
//
// A pool whose price is already past the limit is ineligible: it would have
// to sell at a worse rate than the limit from the first unit.
//
// A pool whose price sits far on the favorable side of the limit is
// ineligible too (Config.MaxPoolPriceDeviationRate): the limit derives from an
// oracle price, not from each pool's price, so a pool displaced far from the
// oracle price, such as an empty pool or one pushed past its liquidity, would
// make its quote or swap walk every tick between its price and the limit.
//
// A limit set more than Config.MaxPairPriceLimitAge seconds ago leaves every
// pool ineligible: the oracle price behind it may be gone, so rounds wait for
// the pool manager to refresh it instead of trading at a stale price.

// Sqrt price bounds a swap price limit is clamped to; the pool requires
// a limit strictly inside (MIN_SQRT_RATIO, MAX_SQRT_RATIO).
const (
	minSqrtRatioPlusOne  = "4295128740"
	maxSqrtRatioMinusOne = "1461446703485210103287273052203988822378723970341"
)

// poolFeeDenominator is the denominator of pool fee tiers (3000 is 0.3%).
const poolFeeDenominator uint64 = 1_000_000

const q96Shift uint = 96

// Ineligibility codes of a candidate pool, reported by GetExecutionQuote as
// ineligibleCode next to the human-readable ineligibleReason. Keepers classify
// a blocked round by code, never by reason text; "" means eligible.
const (
	codeNoPriceLimit     = "no_price_limit"    // the pair direction has no limit
	codePriceLimitStale  = "price_limit_stale" // the limit is older than its maximum age
	codePricePastLimit   = "price_past_limit"  // the pool price is already past the limit
	codePriceDisplaced   = "price_displaced"   // the pool price is too far on the favorable side
	codePriceUnavailable = "price_unavailable" // the pool price could not be read
	codePartialFill      = "partial_fill"      // the quote fills only part of the input
	codeNoOutput         = "no_output"         // the quote returns no output
	codeQuoteFailed      = "quote_failed"      // the pool rejected the quote
)

const (
	reasonNoPriceLimit     = "no price limit for the pair"
	reasonPriceLimitStale  = "pair price limit is older than its maximum age"
	reasonInvalidLimitAge  = "invalid max pair price limit age"
	reasonPricePastLimit   = "pool price is past the pair price limit"
	reasonPriceDisplaced   = "pool price deviates too far from the pair price limit"
	reasonPoolPriceAbsent  = "pool price unavailable"
	reasonInvalidDeviation = "invalid max pool price deviation rate"
)

// getPairPriceLimit returns the price limit of selling inputToken for
// outputToken, or nil if none is set.
func getPairPriceLimit(pairPriceLimits *bptree.BPTree, inputToken string, outputToken string) *pdca.PairPriceLimit {
	value := pairPriceLimits.Get(pdca.PairKey(inputToken, outputToken))
	if value == nil {
		return nil
	}

	return value.(*pdca.PairPriceLimit)
}

// calculateSqrtPriceLimitX96 converts minOutputPerInputX128 into the sqrt
// price limit of a swap on a pool of fee tier fee in the given direction,
// clamped to the range the pool accepts.
//
// The pool takes its fee from the input, so the marginal rate of a unit of
// input is P*(1-fee) selling token0 (P = token1 per token0) and (1-fee)/P
// selling token1. Requiring that rate to stay at or above L gives:
//
//	zeroForOne: P >= L/(1-fee), a lower bound, rounded up
//	oneForZero: P <= (1-fee)/L, an upper bound, rounded down
//
// so the rounding never loosens the limit.
func calculateSqrtPriceLimitX96(minOutputPerInputX128 *u256.Uint, fee uint32, zeroForOne bool) *u256.Uint {
	minSqrtPrice := u256.MustFromDecimal(minSqrtRatioPlusOne)
	maxSqrtPrice := u256.MustFromDecimal(maxSqrtRatioMinusOne)

	if minOutputPerInputX128.IsZero() {
		// No output floor: the bound the pool never reaches.
		if zeroForOne {
			return minSqrtPrice
		}

		return maxSqrtPrice
	}

	feeDenominator := u256.NewUint(poolFeeDenominator)
	feeComplement := u256.NewUint(poolFeeDenominator - uint64(fee))

	var priceX128 *u256.Uint

	if zeroForOne {
		// priceX128 = L_X128 / (1-fee), rounded up.
		if minOutputPerInputX128.BitLen() > 250 {
			return maxSqrtPrice
		}

		priceX128 = u256.MulDivRoundingUp(minOutputPerInputX128, feeDenominator, feeComplement)
	} else {
		// priceX128 = (2^256 / L_X128) * (1-fee), rounded down.
		if minOutputPerInputX128.Lt(u256.NewUint(2)) {
			return maxSqrtPrice
		}

		q128 := u256.One().Lsh(u256.One(), 128)
		inverseX128 := u256.MulDiv(q128, q128, minOutputPerInputX128)
		priceX128 = u256.MulDiv(inverseX128, feeComplement, feeDenominator)
	}

	sqrtPriceX96 := sqrtX128ToSqrtX96(priceX128, zeroForOne)

	if sqrtPriceX96.Lt(minSqrtPrice) {
		return minSqrtPrice
	}

	if sqrtPriceX96.Gt(maxSqrtPrice) {
		return maxSqrtPrice
	}

	return sqrtPriceX96
}

// sqrtX128ToSqrtX96 returns sqrt(priceX128 / 2^128) * 2^96,
// that is sqrt(priceX128 * 2^64), rounded up when roundUp is set.
// A priceX128 too large to shift by 64 bits is shifted by 64-2k bits and the
// root by k bits instead, which keeps the result within one part in 2^96.
func sqrtX128ToSqrtX96(priceX128 *u256.Uint, roundUp bool) *u256.Uint {
	k := uint(0)
	if bitLen := priceX128.BitLen() + 64; bitLen > 255 {
		k = uint(bitLen-255+1) / 2
	}

	var value *u256.Uint
	if 2*k <= 64 {
		value = u256.Zero().Lsh(priceX128, 64-2*k)
	} else {
		value = u256.Zero().Rsh(priceX128, 2*k-64)
	}

	root := sqrtUint256(value)

	if roundUp && !u256.Zero().Mul(root, root).Eq(value) {
		root = u256.Zero().Add(root, u256.One())
	}

	return u256.Zero().Lsh(root, k)
}

// sqrtUint256 returns floor(sqrt(x)) by Newton's method.
func sqrtUint256(x *u256.Uint) *u256.Uint {
	if x.IsZero() {
		return u256.Zero()
	}

	// Start above the root: 2^ceil(bitLen/2).
	z := u256.Zero().Lsh(u256.One(), uint((x.BitLen()+1)/2))

	for {
		// next = (z + x/z) / 2
		next := u256.Zero().Add(z, u256.Zero().Div(x, z))
		next = next.Rsh(next, 1)

		if next.Gte(z) {
			return z
		}

		z = next
	}
}

// poolSqrtPriceLimit returns the sqrt price limit of selling on poolPath under
// limit, or why the pool cannot trade under it. maxDeviationRate, in basis
// points of price, bounds how far the pool's price may sit on the favorable
// side of the limit (see isDisplacedPool); 0 disables that check.
// maxLimitAge, in seconds, is how old the limit may be (see isStalePriceLimit).
//
// It returns the limit, or the ineligibility code and reason.
func poolSqrtPriceLimit(poolPath string, fee uint32, zeroForOne bool, limit *pdca.PairPriceLimit, maxDeviationRate int64, maxLimitAge int64) (string, string, string) {
	if limit == nil {
		return "", codeNoPriceLimit, reasonNoPriceLimit
	}

	stale, err := isStalePriceLimit(limit, maxLimitAge, time.Now().Unix())
	if err != nil {
		// The age is validated when set; an invalid one excludes the pool.
		return "", codePriceLimitStale, reasonInvalidLimitAge
	}

	if stale {
		return "", codePriceLimitStale, reasonPriceLimitStale
	}

	currentSqrtPrice, err := pool.GetSlot0SqrtPriceX96(poolPath)
	if err != nil {
		return "", codePriceUnavailable, reasonPoolPriceAbsent
	}

	current, err := u256.FromDecimal(currentSqrtPrice)
	if err != nil {
		return "", codePriceUnavailable, reasonPoolPriceAbsent
	}

	sqrtPriceLimit := calculateSqrtPriceLimitX96(limit.MinOutputPerInputX128(), fee, zeroForOne)

	// The pool requires the limit strictly on the side the price moves to.
	if zeroForOne && !sqrtPriceLimit.Lt(current) {
		return "", codePricePastLimit, reasonPricePastLimit
	}

	if !zeroForOne && !sqrtPriceLimit.Gt(current) {
		return "", codePricePastLimit, reasonPricePastLimit
	}

	displaced, err := isDisplacedPool(current, sqrtPriceLimit, zeroForOne, maxDeviationRate)
	if err != nil {
		// The rate is validated when set; an invalid one excludes the pool.
		return "", codePriceDisplaced, reasonInvalidDeviation
	}

	if displaced {
		return "", codePriceDisplaced, reasonPriceDisplaced
	}

	return sqrtPriceLimit.ToString(), "", ""
}

// isStalePriceLimit reports whether limit was set more than maxLimitAge
// seconds before currentTimestamp. A non-positive maxLimitAge is invalid:
// a stored config without the age fails closed instead of disabling the check.
func isStalePriceLimit(limit *pdca.PairPriceLimit, maxLimitAge int64, currentTimestamp int64) (bool, error) {
	if maxLimitAge <= 0 {
		return false, makeErrorWithDetails(errInvalidConfig, ufmt.Sprintf("maxPairPriceLimitAge(%d)", maxLimitAge))
	}

	return currentTimestamp-limit.UpdatedAt() > maxLimitAge, nil
}

// isDisplacedPool reports whether the pool price sits more than
// maxDeviationRate, in basis points of price, on the favorable side of the
// swap price limit; 0 disables the check.
//
// Prices are compared through their square roots:
// P_current / P_limit > 1 + rate  <=>  sqrtCurrent > sqrtLimit * sqrt(1 + rate)
// when selling token0, and the reciprocal when selling token1.
func isDisplacedPool(currentSqrtPriceX96 *u256.Uint, sqrtPriceLimitX96 *u256.Uint, zeroForOne bool, maxDeviationRate int64) (bool, error) {
	if maxDeviationRate == 0 {
		return false, nil
	}

	if maxDeviationRate < 0 || maxDeviationRate > pdca.BasisPointDenominator {
		return false, makeErrorWithDetails(errInvalidConfig, ufmt.Sprintf("maxPoolPriceDeviationRate(%d)", maxDeviationRate))
	}

	// factorX96 = sqrt(1 + rate) * 2^96, rounded down.
	ratioX192 := u256.MulDiv(
		u256.NewUint(uint64(pdca.BasisPointDenominator+maxDeviationRate)),
		u256.Zero().Lsh(u256.One(), 2*q96Shift),
		u256.NewUint(uint64(pdca.BasisPointDenominator)),
	)
	factorX96 := sqrtUint256(ratioX192)
	q96 := u256.Zero().Lsh(u256.One(), q96Shift)

	if zeroForOne {
		// The price falls toward the limit: displaced when the pool price is
		// above limit * (1 + rate).
		threshold := u256.MulDiv(sqrtPriceLimitX96, factorX96, q96)
		return currentSqrtPriceX96.Gt(threshold), nil
	}

	// The price rises toward the limit: displaced when the pool price is
	// below limit / (1 + rate).
	scaledCurrent := u256.MulDiv(currentSqrtPriceX96, factorX96, q96)

	return scaledCurrent.Lt(sqrtPriceLimitX96), nil
}

// parseMinOutputPerInputX128 parses a decimal Q128 price limit.
func parseMinOutputPerInputX128(value string) (*u256.Uint, error) {
	parsed, err := u256.FromDecimal(value)
	if err != nil {
		return nil, makeErrorWithDetails(errInvalidPriceLimit, ufmt.Sprintf("minOutputPerInputX128(%s): %s", value, err.Error()))
	}

	return parsed, nil
}
