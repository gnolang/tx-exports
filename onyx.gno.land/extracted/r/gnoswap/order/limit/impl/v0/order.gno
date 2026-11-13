package impl

import (
	"strconv"
	"strings"
	"time"

	plimit "gno.land/p/gnoswap/order/limit/v0"
	ufmt "gno.land/p/nt/ufmt/v0"
	"gno.land/r/gnoswap/common"
	"gno.land/r/gnoswap/order/halt"
	lo "gno.land/r/gnoswap/order/limit"
)

func (l *limitOrderImpl) CreateOrder(_ int, rlm realm, tokenIn, tokenOut string, makingAmount, takingAmount, slippageBps, expiresAt int64, baseToken string) uint64 {
	prev := l.assertIsCall(0, rlm)

	assertIsNotHalted(halt.OperationExecute)

	if baseToken == "" || (baseToken != tokenIn && baseToken != tokenOut) {
		panic(errInvalidBaseToken)
	}

	order, err := l.createOrder(0, rlm, prev.Address(), tokenIn, tokenOut, makingAmount, takingAmount, slippageBps, expiresAt)
	if err != nil {
		panic(realmError(err).Error())
	}

	emitOrderCreated(prev.Address(), prev.PkgPath(), order, baseToken)

	return order.ID()
}

func (l *limitOrderImpl) createOrder(_ int, rlm realm, owner address, tokenIn, tokenOut string, makingAmount, takingAmount, slippageBps, expiresAt int64) (*plimit.Order, error) {
	now := time.Now().Unix()

	orderID := l.store.GetNextOrderID()
	if orderID == ^uint64(0) {
		return nil, plimit.ErrAmountOverflow
	}

	config := l.store.GetConfig()

	max := config.MaxSlippageBps()
	if slippageBps < 0 || slippageBps > max {
		return nil, makeErrorWithDetails(errInvalidSlippage, ufmt.Sprintf("max %d bps, got %d bps", max, slippageBps))
	}

	order, err := plimit.NewOrder(orderID, owner, tokenIn, tokenOut, makingAmount, takingAmount, slippageBps, config.ExecutionFeeRate(), now, expiresAt)
	if err != nil {
		return nil, err
	}

	if err := l.validateCreateOrder(tokenIn, tokenOut, makingAmount, expiresAt, now); err != nil {
		return nil, err
	}

	if err := l.store.SetNextOrderID(0, rlm, orderID+1); err != nil {
		return nil, err
	}

	l.store.GetOrders().Set(plimit.OrderKey(orderID), order)
	l.store.GetOrdersByOwner().Set(plimit.OwnerOrderKey(owner, orderID), orderID)

	common.SafeGRC20TransferFrom(0, rlm, tokenIn, owner, lo.Address(), makingAmount)

	return order, nil
}

func (l *limitOrderImpl) removeOrder(order *plimit.Order) {
	l.store.GetOrders().Remove(plimit.OrderKey(order.ID()))
	l.store.GetOrdersByOwner().Remove(plimit.OwnerOrderKey(order.Owner(), order.ID()))
}

// CancelOrder returns the unsold input in the same transaction.
func (l *limitOrderImpl) CancelOrder(_ int, rlm realm, orderID uint64) int64 {
	prev := l.assertIsCall(0, rlm)

	assertIsNotHalted(halt.OperationWithdraw)

	order, err := l.getOrder(orderID)
	if err != nil {
		panic(err.Error())
	}

	assertIsOrderOwner(order, prev.Address())

	if order.RemainingInput() <= 0 {
		panic(makeErrorWithDetails(errOrderNotActive, "order has no remaining input").Error())
	}

	expired := order.IsExpired(time.Now().Unix())
	refund := order.RefundInput()
	l.removeOrder(order)

	if refund > 0 {
		common.SafeGRC20Transfer(0, rlm, order.TokenIn(), order.Owner(), refund)
	}

	emitOrderRefunded(prev.Address(), prev.PkgPath(), order, refund, expired)

	return refund
}

// CleanupExpiredOrders bounds the number of pending records examined per scan.
// The cursor is the last examined ID and remains usable after that order is removed.
func (l *limitOrderImpl) CleanupExpiredOrders(_ int, rlm realm, startAfterOrderID uint64, maxOrders int) (int, uint64) {
	prev := l.assertIsCall(0, rlm)

	assertIsNotHalted(halt.OperationWithdraw)

	if maxOrders <= 0 {
		return 0, 0
	}

	limit := int(l.store.GetConfig().MaxCleanupBatchSize())
	if maxOrders < limit {
		limit = maxOrders
	}

	ids := make([]uint64, 0, limit)
	more := false

	l.store.GetOrders().Iterate(plimit.OrderKey(startAfterOrderID), "", func(_ string, value any) bool {
		order := value.(*plimit.Order)
		if order.ID() <= startAfterOrderID {
			return false
		}

		if len(ids) == limit {
			more = true
			return true
		}

		ids = append(ids, order.ID())

		return false
	})

	now := time.Now().Unix()
	expired := 0

	for _, orderID := range ids {
		order, err := l.getOrder(orderID)
		if err != nil {
			panic(err.Error())
		}

		isExpired := order.IsExpired(now)
		if !isExpired {
			continue
		}

		remaining := order.RemainingInput()
		if remaining > 0 {
			balance := common.BalanceOf(order.TokenIn(), lo.Address())
			if balance < remaining {
				emitOrderCleanupInsufficientBalance(prev.Address(), prev.PkgPath(), order, remaining, balance)
				continue
			}
		}

		refund := order.RefundInput()
		l.removeOrder(order)

		if refund > 0 {
			common.SafeGRC20Transfer(0, rlm, order.TokenIn(), order.Owner(), refund)
		}

		emitOrderRefunded(prev.Address(), prev.PkgPath(), order, refund, isExpired)

		expired++
	}

	if more {
		return expired, ids[len(ids)-1]
	}

	return expired, 0
}

// CleanupExpiredOrdersByIDs examines only the validated IDs supplied by the caller.
func (l *limitOrderImpl) CleanupExpiredOrdersByIDs(_ int, rlm realm, orderIDs string) (int, string) {
	prev := l.assertIsCall(0, rlm)

	assertIsNotHalted(halt.OperationWithdraw)

	if orderIDs == "" {
		return 0, ""
	}

	ids := parseCleanupOrderIDsCSV(orderIDs, l.store.GetConfig().MaxCleanupBatchSize())
	now := time.Now().Unix()
	expired := 0
	retryOrderIDs := make([]string, 0, len(ids))

	for _, orderID := range ids {
		value := l.store.GetOrders().Get(plimit.OrderKey(orderID))
		if value == nil {
			continue
		}

		order, ok := value.(*plimit.Order)
		if !ok || order == nil {
			panic(makeErrorWithDetails(errInvalidState, "invalid stored order").Error())
		}

		isExpired := order.IsExpired(now)
		if !isExpired {
			retryOrderIDs = append(retryOrderIDs, strconv.FormatUint(orderID, 10))
			continue
		}

		remaining := order.RemainingInput()
		if remaining > 0 {
			balance := common.BalanceOf(order.TokenIn(), lo.Address())
			if balance < remaining {
				emitOrderCleanupInsufficientBalance(prev.Address(), prev.PkgPath(), order, remaining, balance)

				retryOrderIDs = append(retryOrderIDs, strconv.FormatUint(orderID, 10))

				continue
			}
		}

		refund := order.RefundInput()
		l.removeOrder(order)

		if refund > 0 {
			common.SafeGRC20Transfer(0, rlm, order.TokenIn(), order.Owner(), refund)
		}

		emitOrderRefunded(prev.Address(), prev.PkgPath(), order, refund, isExpired)

		expired++
	}

	return expired, strings.Join(retryOrderIDs, ",")
}

// parseCleanupOrderIDsCSV validates the complete bounded input before cleanup
// can change any order or refund any escrow.
func parseCleanupOrderIDsCSV(orderIDs string, maxBatchSize int64) []uint64 {
	if len(orderIDs) > maxCleanupOrderIDsCSVLength {
		panic(errInvalidCleanupOrderIDs)
	}

	itemCount := 1

	for i := 0; i < len(orderIDs); i++ {
		if orderIDs[i] == ',' {
			itemCount++
			if itemCount > int(maxCleanupBatchSizeLimit) || int64(itemCount) > maxBatchSize {
				panic(errInvalidCleanupOrderIDs)
			}
		}
	}

	if itemCount > int(maxCleanupBatchSizeLimit) || int64(itemCount) > maxBatchSize {
		panic(errInvalidCleanupOrderIDs)
	}

	values := strings.Split(orderIDs, ",")
	ids := make([]uint64, len(values))

	var previous uint64

	for i, value := range values {
		id, err := strconv.ParseUint(value, 10, 64)
		if err != nil || id == 0 || strconv.FormatUint(id, 10) != value || (i > 0 && id <= previous) {
			panic(errInvalidCleanupOrderIDs)
		}

		ids[i] = id
		previous = id
	}

	return ids
}
