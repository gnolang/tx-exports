package impl

import (
	pdca "gno.land/p/gnoswap/order/dca/v0"
	ufmt "gno.land/p/nt/ufmt/v0"
)

// SetOrderLimits sets the minimum input per execution
// and the maximum executions per order.
// Existing orders are unaffected. Admin or governance only.
func (d *dcaOrderImpl) SetOrderLimits(_ int, rlm realm, minAmountPerExecution int64, maxExecutionCount int64) {
	prev := d.assertIsAdminCall(0, rlm)

	if minAmountPerExecution <= 0 {
		panic(makeErrorWithDetails(
			errInvalidConfig,
			ufmt.Sprintf("minAmountPerExecution(%d) must be positive", minAmountPerExecution),
		).Error())
	}

	if maxExecutionCount <= 0 || maxExecutionCount > maxExecutionCountLimit {
		panic(makeErrorWithDetails(
			errInvalidConfig,
			ufmt.Sprintf("maxExecutionCount(%d) must be in [1, %d]", maxExecutionCount, maxExecutionCountLimit),
		).Error())
	}

	config := d.store.GetConfig()
	previousMinAmountPerExecution := config.MinAmountPerExecution()
	previousMaxExecutionCount := config.MaxExecutionCount()
	config.SetMinAmountPerExecution(minAmountPerExecution)
	config.SetMaxExecutionCount(maxExecutionCount)

	emitConfigUpdated(prev.Address(), prev.PkgPath(), "minAmountPerExecution", previousMinAmountPerExecution, minAmountPerExecution)
	emitConfigUpdated(prev.Address(), prev.PkgPath(), "maxExecutionCount", previousMaxExecutionCount, maxExecutionCount)
}

// AddAllowedInterval allows new orders to use interval.
// Admin or governance only.
func (d *dcaOrderImpl) AddAllowedInterval(_ int, rlm realm, interval int64) {
	prev := d.assertIsAdminCall(0, rlm)

	if interval < minAllowedInterval || interval > maxAllowedInterval {
		panic(makeErrorWithDetails(
			errInvalidInterval,
			ufmt.Sprintf("interval(%d) must be in [%d, %d]", interval, minAllowedInterval, maxAllowedInterval),
		).Error())
	}

	if err := d.store.GetConfig().AddAllowedInterval(interval); err != nil {
		panic(makeErrorWithDetails(errInvalidInterval, ufmt.Sprintf("interval(%d): %s", interval, err.Error())).Error())
	}

	emitAllowedIntervalUpdated(prev.Address(), prev.PkgPath(), interval, true)
}

// RemoveAllowedInterval stops new orders from using interval.
// Existing orders and groups of that interval keep running.
// At least one interval must stay allowed. Admin or governance only.
func (d *dcaOrderImpl) RemoveAllowedInterval(_ int, rlm realm, interval int64) {
	prev := d.assertIsAdminCall(0, rlm)

	config := d.store.GetConfig()
	if len(config.AllowedIntervals()) == 1 && config.IsAllowedInterval(interval) {
		panic(makeErrorWithDetails(errInvalidConfig, "at least one interval must stay allowed").Error())
	}

	if err := config.RemoveAllowedInterval(interval); err != nil {
		panic(makeErrorWithDetails(errInvalidInterval, ufmt.Sprintf("interval(%d): %s", interval, err.Error())).Error())
	}

	emitAllowedIntervalUpdated(prev.Address(), prev.PkgPath(), interval, false)
}

// SetMinExecutionGapRate sets the minimum gap between a group's executions,
// in basis points of its interval. Admin or governance only.
func (d *dcaOrderImpl) SetMinExecutionGapRate(_ int, rlm realm, minExecutionGapRate int64) {
	prev := d.assertIsAdminCall(0, rlm)

	if minExecutionGapRate < 0 || minExecutionGapRate > pdca.BasisPointDenominator {
		panic(makeErrorWithDetails(
			errInvalidConfig,
			ufmt.Sprintf("minExecutionGapRate(%d) must be in [0, %d]", minExecutionGapRate, pdca.BasisPointDenominator),
		).Error())
	}

	config := d.store.GetConfig()
	previousMinExecutionGapRate := config.MinExecutionGapRate()
	config.SetMinExecutionGapRate(minExecutionGapRate)

	emitConfigUpdated(prev.Address(), prev.PkgPath(), "minExecutionGapRate", previousMinExecutionGapRate, minExecutionGapRate)
}

// SetMaxPoolPriceDeviationRate sets how far, in basis points of price, a pool's
// price may sit on the favorable side of its swap price limit and still be
// quoted (0 to 10000; 0 disables the check). Admin or governance only.
func (d *dcaOrderImpl) SetMaxPoolPriceDeviationRate(_ int, rlm realm, maxPoolPriceDeviationRate int64) {
	prev := d.assertIsAdminCall(0, rlm)

	if maxPoolPriceDeviationRate < 0 || maxPoolPriceDeviationRate > pdca.BasisPointDenominator {
		panic(makeErrorWithDetails(
			errInvalidConfig,
			ufmt.Sprintf("maxPoolPriceDeviationRate(%d) must be in [0, %d]", maxPoolPriceDeviationRate, pdca.BasisPointDenominator),
		).Error())
	}

	config := d.store.GetConfig()
	previousMaxPoolPriceDeviationRate := config.MaxPoolPriceDeviationRate()
	config.SetMaxPoolPriceDeviationRate(maxPoolPriceDeviationRate)

	emitConfigUpdated(
		prev.Address(),
		prev.PkgPath(),
		"maxPoolPriceDeviationRate",
		previousMaxPoolPriceDeviationRate,
		maxPoolPriceDeviationRate,
	)
}

// SetMaxPairPriceLimitAge sets how long, in seconds, a pair price limit stays
// usable after the pool manager set it (60 to 604800). A quote or round under
// an older limit finds no eligible pool, so rounds stop when the manager stops
// refreshing limits instead of trading at a stale price. Admin or governance only.
func (d *dcaOrderImpl) SetMaxPairPriceLimitAge(_ int, rlm realm, maxPairPriceLimitAge int64) {
	prev := d.assertIsAdminCall(0, rlm)

	if maxPairPriceLimitAge < minMaxPairPriceLimitAge || maxPairPriceLimitAge > maxMaxPairPriceLimitAge {
		panic(makeErrorWithDetails(
			errInvalidConfig,
			ufmt.Sprintf("maxPairPriceLimitAge(%d) must be in [%d, %d]", maxPairPriceLimitAge, minMaxPairPriceLimitAge, maxMaxPairPriceLimitAge),
		).Error())
	}

	config := d.store.GetConfig()
	previousMaxPairPriceLimitAge := config.MaxPairPriceLimitAge()
	config.SetMaxPairPriceLimitAge(maxPairPriceLimitAge)

	emitConfigUpdated(prev.Address(), prev.PkgPath(), "maxPairPriceLimitAge", previousMaxPairPriceLimitAge, maxPairPriceLimitAge)
}

// SetMaxClaimBatchSize caps the orders one ClaimGroupOrders call examines.
// Admin or governance only.
func (d *dcaOrderImpl) SetMaxClaimBatchSize(_ int, rlm realm, maxClaimBatchSize int64) {
	prev := d.assertIsAdminCall(0, rlm)

	if maxClaimBatchSize <= 0 || maxClaimBatchSize > maxClaimBatchSizeLimit {
		panic(makeErrorWithDetails(
			errInvalidConfig,
			ufmt.Sprintf("maxClaimBatchSize(%d) must be in [1, %d]", maxClaimBatchSize, maxClaimBatchSizeLimit),
		).Error())
	}

	config := d.store.GetConfig()
	previousMaxClaimBatchSize := config.MaxClaimBatchSize()
	config.SetMaxClaimBatchSize(maxClaimBatchSize)

	emitConfigUpdated(prev.Address(), prev.PkgPath(), "maxClaimBatchSize", previousMaxClaimBatchSize, maxClaimBatchSize)
}

// SetSlotStep sets the spacing of the slot offsets new orders may use
// at interval. Existing groups keep their slot.
// Admin or governance only.
func (d *dcaOrderImpl) SetSlotStep(_ int, rlm realm, interval int64, slotStep int64) {
	prev := d.assertIsAdminCall(0, rlm)

	config := d.store.GetConfig()
	assertIsAllowedInterval(config, interval)
	previousSlotStep := config.SlotStep(interval)

	if err := config.SetSlotStep(interval, slotStep); err != nil {
		panic(makeErrorWithDetails(
			errInvalidSlotStep,
			ufmt.Sprintf("slotStep(%d) must be a positive divisor of interval(%d)", slotStep, interval),
		).Error())
	}

	emitSlotStepChanged(prev.Address(), prev.PkgPath(), interval, previousSlotStep, slotStep)
}
