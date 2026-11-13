package impl

import (
	"gno.land/p/gnoswap/gnsmath/v1"
	pdca "gno.land/p/gnoswap/order/dca/v0"
	u256 "gno.land/p/gnoswap/uint256/v1"
	ufmt "gno.land/p/nt/ufmt/v0"
)

// calculatePayout wraps pdca.CalculatePayout,
// reporting a backwards accumulator as invalid state.
func calculatePayout(amountPerExecution int64, endAccumulatedX128 *u256.Uint, debtX128 *u256.Uint) (int64, error) {
	payoutAmount, err := pdca.CalculatePayout(amountPerExecution, endAccumulatedX128, debtX128)
	if err != nil {
		return 0, makeErrorWithDetails(errInvalidState, err.Error())
	}

	return payoutAmount, nil
}

// orderPayout is one payout of an order's accrued output.
type orderPayout struct {
	grossAmount        int64 // accrued output paid out
	executionFeeAmount int64 // the order's execution fee on grossAmount
	claimedAmount      int64 // grossAmount - executionFeeAmount, sent to the owner
}

// calculateOrderPayout returns the payout of the output the order accrued up
// to endAccumulatedX128, with the order's execution fee deducted on its
// cumulative gross output (see pdca.CalculatePayoutExecutionFeeAmount).
func calculateOrderPayout(order *pdca.Order, endAccumulatedX128 *u256.Uint) (orderPayout, error) {
	grossAmount, err := calculatePayout(order.AmountPerExecution(), endAccumulatedX128, order.DebtX128())
	if err != nil {
		return orderPayout{}, err
	}

	executionFeeAmount, err := pdca.CalculatePayoutExecutionFeeAmount(order.PaidGrossAmount(), grossAmount, order.ExecutionFeeRate())
	if err != nil {
		return orderPayout{}, makeErrorWithDetails(errInvalidState, err.Error())
	}

	return orderPayout{
		grossAmount:        grossAmount,
		executionFeeAmount: executionFeeAmount,
		claimedAmount:      gnsmath.SafeSubInt64(grossAmount, executionFeeAmount),
	}, nil
}

// recordOrderPayout adds a payout to the order's lifetime
// claimed amount and execution fee.
func recordOrderPayout(order *pdca.Order, payout orderPayout) {
	order.SetClaimedAmount(u256.Zero().Add(order.ClaimedAmount(), u256.NewUint(uint64(payout.claimedAmount))))
	order.SetExecutionFeeAmount(u256.Zero().Add(order.ExecutionFeeAmount(), u256.NewUint(uint64(payout.executionFeeAmount))))
}

// calculateDebtX128AfterPayout wraps pdca.CalculateDebtX128AfterPayout,
// reporting an invalid payout as invalid state.
func calculateDebtX128AfterPayout(amountPerExecution int64, debtX128 *u256.Uint, payoutAmount int64) (*u256.Uint, error) {
	nextDebtX128, err := pdca.CalculateDebtX128AfterPayout(amountPerExecution, debtX128, payoutAmount)
	if err != nil {
		return nil, makeErrorWithDetails(errInvalidState, err.Error())
	}

	return nextDebtX128, nil
}

// getOrderEndAccumulatedOutputPerAmountX128 returns the accumulator an order
// is paid against, and whether all of its rounds have executed.
func getOrderEndAccumulatedOutputPerAmountX128(order *pdca.Order, group *pdca.Group) (*u256.Uint, bool, error) {
	if group.Round() < order.EndRound() {
		return group.AccumulatedOutputPerAmountX128(), false, nil
	}

	roundMark := group.GetRoundMark(order.EndRound())
	if roundMark == nil {
		return nil, false, makeErrorWithDetails(errInvalidState, ufmt.Sprintf("missing snapshot for round %d", order.EndRound()))
	}

	return roundMark.AccumulatedOutputPerAmountX128(), true, nil
}

// releaseRoundMark drops one order reference from its end-round mark,
// removing the mark once no order references it.
func releaseRoundMark(group *pdca.Group, round uint64) error {
	roundMark := group.GetRoundMark(round)
	if roundMark == nil {
		return makeErrorWithDetails(errInvalidState, ufmt.Sprintf("missing mark for round %d", round))
	}

	orderCount := roundMark.OrderCount() - 1
	if orderCount < 0 {
		return makeErrorWithDetails(errInvalidState, ufmt.Sprintf("negative order count for round %d", round))
	}

	if orderCount > 0 {
		roundMark.SetOrderCount(orderCount)
		return nil
	}

	if round > group.Round() && roundMark.OrderAmount() != 0 {
		return makeErrorWithDetails(errInvalidState, ufmt.Sprintf("unexecuted mark %d still has order amount", round))
	}

	group.RemoveRoundMark(round)

	return nil
}

// feeRateMinAmount is the smallest amountPerExecution of the orders with
// one execution fee rate that sell in a round.
type feeRateMinAmount struct {
	executionFeeRate      int64
	minAmountPerExecution int64
}

// getFeeRateMinAmounts returns, by ascending execution fee rate, the
// smallest amountPerExecution of the group's orders of each fee rate that
// sell in round; it is empty when no order does.
// The amount index sorts a group's orders by fee rate, then amount,
// so each rate costs one seek past the finished orders before its first
// selling one, and the number of seeks is the number of fee rates indexed.
// The amount index keeps finished orders until they are paid out;
// with prune, the entries of orders whose last round is before round
// are removed on the way, as no later round sells them.
func (d *dcaOrderImpl) getFeeRateMinAmounts(group *pdca.Group, round uint64, prune bool) []feeRateMinAmount {
	orderAmountsByGroup := d.store.GetOrderAmountsByGroup()
	prefix := pdca.GroupOrderPrefix(group.ID())
	end := pdca.PrefixEnd(prefix)

	minAmounts := []feeRateMinAmount{}
	finishedKeys := []string{}
	start := prefix

	for {
		found := false
		executionFeeRate := int64(0)
		minAmountPerExecution := int64(0)

		orderAmountsByGroup.Iterate(start, end, func(key string, value any) bool {
			if value.(uint64) < round {
				if prune {
					finishedKeys = append(finishedKeys, key)
				}

				return false
			}

			executionFeeRate = pdca.GroupOrderAmountKeyFeeRate(group.ID(), key)
			minAmountPerExecution = pdca.GroupOrderAmountKeyAmount(group.ID(), key)
			found = true

			return true
		})

		if !found {
			break
		}

		minAmounts = append(minAmounts, feeRateMinAmount{
			executionFeeRate:      executionFeeRate,
			minAmountPerExecution: minAmountPerExecution,
		})

		// Skip the larger orders of this rate.
		start = pdca.PrefixEnd(pdca.GroupOrderFeeRatePrefix(group.ID(), executionFeeRate))
	}

	for _, key := range finishedKeys {
		orderAmountsByGroup.Remove(key)
	}

	return minAmounts
}

// minAmountPerExecutionOf returns the smallest amountPerExecution of
// minAmounts, or 0 when it is empty.
func minAmountPerExecutionOf(minAmounts []feeRateMinAmount) int64 {
	minAmountPerExecution := int64(0)

	for i, minAmount := range minAmounts {
		if i == 0 || minAmount.minAmountPerExecution < minAmountPerExecution {
			minAmountPerExecution = minAmount.minAmountPerExecution
		}
	}

	return minAmountPerExecution
}

// maxExecutionFeeRateOf returns the highest execution fee rate of
// minAmounts, or 0 when it is empty.
func maxExecutionFeeRateOf(minAmounts []feeRateMinAmount) int64 {
	maxExecutionFeeRate := int64(0)

	for _, minAmount := range minAmounts {
		if minAmount.executionFeeRate > maxExecutionFeeRate {
			maxExecutionFeeRate = minAmount.executionFeeRate
		}
	}

	return maxExecutionFeeRate
}

// calculateMinOrderAmountOut returns the output, net of its own execution
// fee rate, the order of minAmount is credited at outputPerAmountX128.
func calculateMinOrderAmountOut(minAmount feeRateMinAmount, outputPerAmountX128 *u256.Uint) (int64, error) {
	grossAmountOut, err := pdca.CalculatePayout(minAmount.minAmountPerExecution, outputPerAmountX128, u256.Zero())
	if err != nil {
		return 0, err
	}

	return pdca.CalculateMinNetAmountOut(grossAmountOut, minAmount.executionFeeRate)
}

func getScheduleKey(group *pdca.Group) string {
	return pdca.ScheduleKey(group.NextExecutionTimestamp(), group.ID())
}

// rescheduleGroup sets a group's order amount and next execution timestamp,
// keeping the schedule index in sync.
// Only groups with a positive order amount are indexed.
func (d *dcaOrderImpl) rescheduleGroup(group *pdca.Group, orderAmount int64, nextExecutionTimestamp int64) error {
	if orderAmount < 0 {
		return makeErrorWithDetails(errInvalidState, ufmt.Sprintf("negative order amount for group %s", group.ID()))
	}

	scheduledGroups := d.store.GetScheduledGroups()
	if group.OrderAmount() > 0 {
		scheduledGroups.Remove(getScheduleKey(group))
	}

	group.SetOrderAmount(orderAmount)
	group.SetNextExecutionTimestamp(nextExecutionTimestamp)

	if orderAmount > 0 {
		scheduledGroups.Set(getScheduleKey(group), group.ID())
	}

	return nil
}

func (d *dcaOrderImpl) getOrder(orderID uint64) (*pdca.Order, error) {
	value := d.store.GetOrders().Get(pdca.OrderKey(orderID))
	if value == nil {
		return nil, makeErrorWithDetails(errOrderNotFound, ufmt.Sprintf("orderId(%d)", orderID))
	}

	return value.(*pdca.Order), nil
}

func (d *dcaOrderImpl) getGroup(groupID string) (*pdca.Group, error) {
	value := d.store.GetGroups().Get(groupID)
	if value == nil {
		return nil, makeErrorWithDetails(errGroupNotFound, ufmt.Sprintf("groupId(%s)", groupID))
	}

	return value.(*pdca.Group), nil
}

// getOrderWithGroup returns an order and the group it belongs to.
func (d *dcaOrderImpl) getOrderWithGroup(orderID uint64) (*pdca.Order, *pdca.Group, error) {
	order, err := d.getOrder(orderID)
	if err != nil {
		return nil, nil, err
	}

	group, err := d.getGroup(order.GroupID())
	if err != nil {
		return nil, nil, err
	}

	return order, group, nil
}

// validateOrderOutput checks that the round credits the smallest order of
// each execution fee rate at least minOrderAmountOut of output net of that
// rate, computed as its payout is. Within one rate an order's net payout
// only grows with amountPerExecution, so every order of the round then
// receives at least that much net of its own fee.
func validateOrderOutput(
	group *pdca.Group,
	minAmounts []feeRateMinAmount,
	minOrderAmountOut int64,
	outputPerAmountX128 *u256.Uint,
	executedAmountOut int64,
	orderAmount int64,
) error {
	for _, minAmount := range minAmounts {
		orderAmountOut, err := calculateMinOrderAmountOut(minAmount, outputPerAmountX128)
		if err != nil {
			return makeErrorWithDetails(errInvalidState, err.Error())
		}

		if orderAmountOut < minOrderAmountOut {
			return makeErrorWithDetails(
				errInsufficientOrderOutput,
				ufmt.Sprintf(
					"groupId(%s) amountPerExecution(%d) receives %d after executionFeeRate(%d), below minOrderAmountOut(%d), of executedAmountOut(%d) for orderAmount(%d)",
					group.ID(), minAmount.minAmountPerExecution, orderAmountOut, minAmount.executionFeeRate, minOrderAmountOut, executedAmountOut, orderAmount,
				),
			)
		}
	}

	return nil
}
