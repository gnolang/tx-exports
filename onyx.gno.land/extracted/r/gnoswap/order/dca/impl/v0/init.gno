package impl

import (
	pdca "gno.land/p/gnoswap/order/dca/v0"

	dca "gno.land/r/gnoswap/order/dca"
)

func init(cur realm) {
	registerDCAOrderImpl(cur)
}

func registerDCAOrderImpl(cur realm) {
	dca.RegisterInitializer(cross(cur), func(_ int, rlm realm, dcaStore pdca.IDCAOrderStore) pdca.IDCAOrder {
		err := initStoreData(0, rlm, dcaStore)
		if err != nil {
			panic(err.Error())
		}

		return NewDCAOrderImpl(dcaStore)
	})
}

func initStoreData(_ int, rlm realm, s pdca.IDCAOrderStore) error {
	if !s.HasOrders() {
		if err := s.SetOrders(0, rlm, dca.NewBPTreeN(dcaBPTreeFanOut)); err != nil {
			return err
		}
	}

	if !s.HasOrdersByOwner() {
		if err := s.SetOrdersByOwner(0, rlm, dca.NewBPTreeN(dcaBPTreeFanOut)); err != nil {
			return err
		}
	}

	if !s.HasGroups() {
		if err := s.SetGroups(0, rlm, dca.NewBPTreeN(dcaBPTreeFanOut)); err != nil {
			return err
		}
	}

	if !s.HasScheduledGroups() {
		if err := s.SetScheduledGroups(0, rlm, dca.NewBPTreeN(dcaBPTreeFanOut)); err != nil {
			return err
		}
	}

	if !s.HasOrdersByGroup() {
		if err := s.SetOrdersByGroup(0, rlm, dca.NewBPTreeN(dcaBPTreeFanOut)); err != nil {
			return err
		}
	}

	if !s.HasPendingExecutionFees() {
		if err := s.SetPendingExecutionFees(0, rlm, dca.NewBPTreeN(dcaBPTreeFanOut)); err != nil {
			return err
		}
	}

	if !s.HasExecutionLogs() {
		if err := s.SetExecutionLogs(0, rlm, dca.NewBPTreeN(dcaBPTreeFanOut)); err != nil {
			return err
		}
	}

	if !s.HasOrderAmountsByGroup() {
		if err := s.SetOrderAmountsByGroup(0, rlm, dca.NewBPTreeN(dcaBPTreeFanOut)); err != nil {
			return err
		}
	}

	if !s.HasTokenMinAmountsPerExecution() {
		if err := s.SetTokenMinAmountsPerExecution(0, rlm, dca.NewBPTreeN(dcaBPTreeFanOut)); err != nil {
			return err
		}
	}

	if !s.HasPairPriceLimits() {
		if err := s.SetPairPriceLimits(0, rlm, dca.NewBPTreeN(dcaBPTreeFanOut)); err != nil {
			return err
		}
	}

	if !s.HasNextOrderID() {
		if err := s.SetNextOrderID(0, rlm, 1); err != nil {
			return err
		}
	}

	if !s.HasConfig() {
		config := pdca.NewConfig(defaultMinAmountPerExecution, defaultMaxExecutionCount, defaultAllowedIntervals())
		config.SetMinExecutionGapRate(defaultMinExecutionGapRate)
		config.SetMaxPoolPriceDeviationRate(defaultMaxPoolPriceDeviationRate)
		config.SetMaxPairPriceLimitAge(defaultMaxPairPriceLimitAge)
		config.SetMaxClaimBatchSize(defaultMaxClaimBatchSize)

		for interval, step := range defaultSlotSteps() {
			if err := config.SetSlotStep(interval, step); err != nil {
				return err
			}
		}

		if err := config.SetExecutionFeeRate(defaultExecutionFeeRate); err != nil {
			return err
		}

		if err := s.SetConfig(0, rlm, config); err != nil {
			return err
		}
	}

	return nil
}
