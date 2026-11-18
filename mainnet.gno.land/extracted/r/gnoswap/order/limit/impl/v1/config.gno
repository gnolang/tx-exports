package impl

import (
	"gno.land/p/gnoswap/utils/v1"
)

// SetMinMakingAmount sets the minimum input amount accepted for new orders.
func (l *limitOrderImpl) SetMinMakingAmount(_ int, rlm realm, minMakingAmount int64) {
	prev := l.assertIsAdminCall(0, rlm)

	if minMakingAmount <= 0 {
		panic(makeErrorWithDetails(errInvalidConfig, "minMakingAmount must be positive").Error())
	}

	config := l.store.GetConfig()
	old := config.MinMakingAmount()
	config.SetMinMakingAmount(minMakingAmount)

	emitConfigUpdated(prev.Address(), prev.PkgPath(), "minMakingAmount", utils.FormatInt(old), utils.FormatInt(minMakingAmount))
}

// SetOrderDeadlines sets the positive duration range accepted for new orders.
func (l *limitOrderImpl) SetOrderDeadlines(_ int, rlm realm, minDuration, maxDuration int64) {
	prev := l.assertIsAdminCall(0, rlm)

	if minDuration <= 0 || maxDuration < minDuration {
		panic(makeErrorWithDetails(errInvalidConfig, "invalid order duration range").Error())
	}

	config := l.store.GetConfig()
	oldMin, oldMax := config.MinOrderDuration(), config.MaxOrderDuration()
	config.SetMinOrderDuration(minDuration)
	config.SetMaxOrderDuration(maxDuration)

	emitConfigUpdated(prev.Address(), prev.PkgPath(), "minOrderDuration", utils.FormatInt(oldMin), utils.FormatInt(minDuration))
	emitConfigUpdated(prev.Address(), prev.PkgPath(), "maxOrderDuration", utils.FormatInt(oldMax), utils.FormatInt(maxDuration))
}

// SetMaxCleanupBatchSize bounds examined records, not just successful refunds.
func (l *limitOrderImpl) SetMaxCleanupBatchSize(_ int, rlm realm, maxCleanupBatchSize int64) {
	prev := l.assertIsAdminCall(0, rlm)

	if maxCleanupBatchSize < 1 || maxCleanupBatchSize > maxCleanupBatchSizeLimit {
		panic(makeErrorWithDetails(errInvalidConfig, "maxCleanupBatchSize must be in [1, "+utils.FormatInt(maxCleanupBatchSizeLimit)+"]").Error())
	}

	config := l.store.GetConfig()
	old := config.MaxCleanupBatchSize()
	config.SetMaxCleanupBatchSize(maxCleanupBatchSize)

	emitConfigUpdated(prev.Address(), prev.PkgPath(), "maxCleanupBatchSize", utils.FormatInt(old), utils.FormatInt(maxCleanupBatchSize))
}

// SetMaxSlippageBps sets the slippage cap for new orders.
func (l *limitOrderImpl) SetMaxSlippageBps(_ int, rlm realm, maxSlippageBps int64) {
	prev := l.assertIsAdminCall(0, rlm)

	config := l.store.GetConfig()

	old := config.MaxSlippageBps()
	if err := config.SetMaxSlippageBps(maxSlippageBps); err != nil {
		panic(makeErrorWithDetails(errInvalidConfig, "maxSlippageBps must be in [0, 10000]").Error())
	}

	emitConfigUpdated(prev.Address(), prev.PkgPath(), "maxSlippageBps", utils.FormatInt(old), utils.FormatInt(maxSlippageBps))
}
