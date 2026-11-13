package impl

import (
	"time"

	pdca "gno.land/p/gnoswap/order/dca/v0"
	u256 "gno.land/p/gnoswap/uint256/v1"
	ufmt "gno.land/p/nt/ufmt/v0"

	"gno.land/r/gnoswap/common"
	"gno.land/r/gnoswap/order/keeper"
)

// Manager settings.
//
// The pool manager (PoolManagerRole at deployment, admin and governance too)
// sets, from an off-chain oracle price:
//   - the minimum input per execution of each token, so a new order is worth
//     at least a set value per round whatever the token's decimals; it applies
//     on top of the global minimum (Config.MinAmountPerExecution) and only to
//     new orders
//   - the price limit of each pair direction (see price_limit.gno)

// SetTokenMinAmountPerExecution sets the minimum input per execution of new
// orders selling tokenPath; 0 removes it, leaving the global minimum.
func (d *dcaOrderImpl) SetTokenMinAmountPerExecution(_ int, rlm realm, tokenPath string, minAmountPerExecution int64) {
	prev := d.assertIsManagerCall(0, rlm, keeper.SelectorSetTokenMinAmountPerExecution)

	if minAmountPerExecution < 0 {
		panic(makeErrorWithDetails(
			errInvalidConfig,
			ufmt.Sprintf("minAmountPerExecution(%d) must not be negative", minAmountPerExecution),
		).Error())
	}

	tokenMinAmounts := d.store.GetTokenMinAmountsPerExecution()
	previousMinAmountPerExecution := getTokenMinAmountPerExecution(d.store, tokenPath)

	if minAmountPerExecution == 0 {
		tokenMinAmounts.Remove(tokenPath)
	} else {
		if err := common.IsRegistered(tokenPath); err != nil {
			panic(makeErrorWithDetails(errInvalidToken, ufmt.Sprintf("tokenPath(%s): %s", tokenPath, err.Error())).Error())
		}

		tokenMinAmounts.Set(tokenPath, minAmountPerExecution)
	}

	emitTokenMinAmountPerExecutionUpdated(prev.Address(), prev.PkgPath(), tokenPath, previousMinAmountPerExecution, minAmountPerExecution)
}

// SetPairPriceLimit sets the minimum pool output per unit of input, in Q128,
// of rounds selling inputToken for outputToken; "0" removes it, which stops
// the pair direction from trading and from receiving new orders.
// It takes effect from the next quote or round, for existing orders too.
func (d *dcaOrderImpl) SetPairPriceLimit(_ int, rlm realm, inputToken string, outputToken string, minOutputPerInputX128 string) {
	prev := d.assertIsManagerCall(0, rlm, keeper.SelectorSetPairPriceLimit)

	if inputToken == outputToken {
		panic(makeErrorWithDetails(errInvalidToken, ufmt.Sprintf("inputToken and outputToken are both %s", inputToken)).Error())
	}

	limitX128, err := parseMinOutputPerInputX128(minOutputPerInputX128)
	if err != nil {
		panic(err.Error())
	}

	pairPriceLimits := d.store.GetPairPriceLimits()
	pairKey := pdca.PairKey(inputToken, outputToken)

	previous := getPairPriceLimit(pairPriceLimits, inputToken, outputToken)

	previousLimitX128 := u256.Zero()
	if previous != nil {
		previousLimitX128 = previous.MinOutputPerInputX128()
	}

	updatedAt := time.Now().Unix()

	switch {
	case limitX128.IsZero():
		pairPriceLimits.Remove(pairKey)

		updatedAt = 0
	case previous != nil:
		// Stored limits are updated in place, like other stored entries.
		previous.Update(limitX128, updatedAt)
	default:
		if err := common.ValidateRegistered(inputToken, outputToken); err != nil {
			panic(makeErrorWithDetails(errInvalidToken, err.Error()).Error())
		}

		pairPriceLimits.Set(pairKey, pdca.NewPairPriceLimit(limitX128, updatedAt))
	}

	emitPairPriceLimitUpdated(
		prev.Address(),
		prev.PkgPath(),
		inputToken,
		outputToken,
		previousLimitX128.ToString(),
		limitX128.ToString(),
		updatedAt,
	)
}

// getTokenMinAmountPerExecution returns the minimum input per execution set
// for tokenPath, or 0 if none is set.
func getTokenMinAmountPerExecution(s pdca.IDCAOrderStore, tokenPath string) int64 {
	value := s.GetTokenMinAmountsPerExecution().Get(tokenPath)
	if value == nil {
		return 0
	}

	return value.(int64)
}

// minAmountPerExecution returns the minimum input per execution of a new order
// selling tokenPath: the larger of the global and the token minimum.
func (d *dcaOrderImpl) minAmountPerExecution(tokenPath string) int64 {
	minAmount := d.store.GetConfig().MinAmountPerExecution()

	if tokenMinAmount := getTokenMinAmountPerExecution(d.store, tokenPath); tokenMinAmount > minAmount {
		return tokenMinAmount
	}

	return minAmount
}
