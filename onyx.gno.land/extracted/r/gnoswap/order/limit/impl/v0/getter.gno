package impl

import (
	plimit "gno.land/p/gnoswap/order/limit/v0"
	rotree "gno.land/p/nt/bptree/rotree/v0"
)

func (l *limitOrderImpl) GetConfig() *plimit.Config {
	return l.store.GetConfig().Clone()
}

func (l *limitOrderImpl) GetNextOrderID() uint64 {
	return l.store.GetNextOrderID()
}

func (l *limitOrderImpl) ExistsOrder(orderID uint64) bool {
	return l.store.GetOrders().Has(plimit.OrderKey(orderID))
}

func (l *limitOrderImpl) GetOrder(orderID uint64) *plimit.Order {
	value := l.store.GetOrders().Get(plimit.OrderKey(orderID))
	if value == nil {
		return nil
	}

	return value.(*plimit.Order).Clone()
}

func (l *limitOrderImpl) GetOrders() *rotree.ReadOnlyTree {
	return rotree.Wrap(l.store.GetOrders(), cloneOrderEntry)
}

func (l *limitOrderImpl) GetOrdersByOwner() *rotree.ReadOnlyTree {
	return rotree.Wrap(l.store.GetOrdersByOwner(), nil)
}

func (l *limitOrderImpl) GetPendingExecutionFeeAmount(tokenPath string) int64 {
	return getPendingExecutionFeeAmount(l.store.GetPendingExecutionFees(), tokenPath)
}

func (l *limitOrderImpl) GetPendingExecutionFees() *rotree.ReadOnlyTree {
	return rotree.Wrap(l.store.GetPendingExecutionFees(), nil)
}

func cloneOrderEntry(value any) any {
	if value == nil {
		return nil
	}

	return value.(*plimit.Order).Clone()
}
