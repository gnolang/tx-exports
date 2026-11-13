package impl

import (
	plimit "gno.land/p/gnoswap/order/limit/v0"

	lo "gno.land/r/gnoswap/order/limit"
)

func init(cur realm) {
	lo.RegisterInitializer(cross(cur), func(_ int, rlm realm, orderStore plimit.ILimitOrderStore) plimit.ILimitOrder {
		if err := initStoreData(0, rlm, orderStore); err != nil {
			panic(err.Error())
		}

		return NewLimitOrderImpl(orderStore)
	})
}

func initStoreData(_ int, rlm realm, s plimit.ILimitOrderStore) error {
	if !s.HasOrders() {
		if err := s.SetOrders(0, rlm, lo.NewBPTreeN(plimit.DefaultBPTreeFanout)); err != nil {
			return err
		}
	}

	if !s.HasOrdersByOwner() {
		if err := s.SetOrdersByOwner(0, rlm, lo.NewBPTreeN(plimit.DefaultBPTreeFanout)); err != nil {
			return err
		}
	}

	if !s.HasPendingExecutionFees() {
		if err := s.SetPendingExecutionFees(0, rlm, lo.NewBPTreeN(plimit.DefaultBPTreeFanout)); err != nil {
			return err
		}
	}

	if !s.HasNextOrderID() {
		if err := s.SetNextOrderID(0, rlm, 1); err != nil {
			return err
		}
	}

	if !s.HasConfig() {
		config := plimit.NewConfig(
			defaultExecutionFeeRate,
			defaultMinMakingAmount,
			defaultMinOrderDuration,
			defaultMaxOrderDuration,
			defaultMaxCleanupBatchSize,
		)
		if err := s.SetConfig(0, rlm, config); err != nil {
			return err
		}
	}

	return nil
}
