package impl

import (
	"chain/runtime"
	"time"

	"gno.land/p/gnoswap/gnsmath/v1"
	pdca "gno.land/p/gnoswap/order/dca/v0"
	ufmt "gno.land/p/nt/ufmt/v0"

	"gno.land/r/gnoswap/access/v1"
	"gno.land/r/gnoswap/common"
	"gno.land/r/gnoswap/order/halt"
	"gno.land/r/gnoswap/order/keeper"
	"gno.land/r/gnoswap/order/whitelist"
)

// CreateOrder escrows the order input
// and adds the order's per-round amount to its group.
// The group runs at the slotOffset of each interval, see pdca.Group.
// The order takes part in the group's next executionCount rounds only;
// the caller pays for the order's execution logs, one per three rounds.
// The order snapshots the execution fee rate in effect, charged on its
// output when it is paid out; later rate changes leave it unchanged.
func (d *dcaOrderImpl) CreateOrder(
	_ int,
	rlm realm,
	inputToken string,
	outputToken string,
	interval int64,
	slotOffset int64,
	amountPerExecution int64,
	executionCount int64,
) uint64 {
	access.AssertIsRlmCurrent(0, rlm)
	common.AssertIsNotHandleNativeCoin()
	// A new order only joins rounds, so it is rejected while rounds are halted.
	assertIsNotHalted(halt.OperationExecute)
	d.assertIsNotExecuting()

	prev := rlm.Previous()
	caller := prev.Address()
	access.AssertIsValidAddress(caller)

	config := d.store.GetConfig()

	assertIsValidPair(inputToken, outputToken)
	assertHasPairPriceLimit(d.store.GetPairPriceLimits(), inputToken, outputToken)
	assertIsAllowedInterval(config, interval)
	assertIsAllowedSlot(config, interval, slotOffset)
	assertIsValidOrderSize(config, d.minAmountPerExecution(inputToken), amountPerExecution, executionCount)

	order, group, isNewGroup, depositAmount, err := d.createOrder(
		0, rlm, caller, inputToken, outputToken, interval, slotOffset, amountPerExecution, executionCount,
	)
	if err != nil {
		panic(err.Error())
	}

	if isNewGroup {
		emitGroupCreated(caller, prev.PkgPath(), group)
	}

	// The escrow transfer does not touch the pools, so this quotes the state
	// the order was placed in.
	// The order's execution fee is deducted up front, as its payouts deduct
	// it, so the reference is comparable with the output the owner receives.
	referenceSwapAmountOut := quoteReferenceAmountOut(
		whitelist.GetWhitelistedPools(whitelist.TargetDCA),
		getPairPriceLimit(d.store.GetPairPriceLimits(), inputToken, outputToken),
		config.MaxPoolPriceDeviationRate(),
		config.MaxPairPriceLimitAge(),
		inputToken,
		outputToken,
		depositAmount,
	)

	referenceExecutionFeeAmount, err := pdca.CalculateExecutionFeeAmount(referenceSwapAmountOut, order.ExecutionFeeRate())
	if err != nil {
		panic(err.Error())
	}

	referenceAmountOut := gnsmath.SafeSubInt64(referenceSwapAmountOut, referenceExecutionFeeAmount)

	emitOrderCreated(caller, prev.PkgPath(), order, group, depositAmount, referenceAmountOut)

	return order.ID()
}

// createOrder stores the order, joins or creates its group,
// and pulls the deposit from the owner.
func (d *dcaOrderImpl) createOrder(
	_ int,
	rlm realm,
	owner address,
	inputToken string,
	outputToken string,
	interval int64,
	slotOffset int64,
	amountPerExecution int64,
	executionCount int64,
) (*pdca.Order, *pdca.Group, bool, int64, error) {
	depositAmount := gnsmath.SafeMulInt64(amountPerExecution, executionCount)

	currentTimestamp := time.Now().Unix()
	groups := d.store.GetGroups()
	groupID := pdca.MakeGroupID(inputToken, outputToken, interval, slotOffset)

	// A new or idle group runs its next round at the first slot from now,
	// instead of at a stale slot that would run at once.
	firstSlotTimestamp, err := pdca.CalculateFirstSlotTimestamp(currentTimestamp, interval, slotOffset)
	if err != nil {
		return nil, nil, false, 0, makeErrorWithDetails(errInvalidSlotOffset, err.Error())
	}

	var group *pdca.Group

	isNewGroup := false

	if value := groups.Get(groupID); value != nil {
		group = value.(*pdca.Group)
	} else {
		group = pdca.NewGroup(groupID, inputToken, outputToken, interval, slotOffset, firstSlotTimestamp)
		groups.Set(groupID, group)

		isNewGroup = true
	}

	nextExecutionTimestamp := group.NextExecutionTimestamp()
	if group.OrderAmount() == 0 {
		nextExecutionTimestamp = firstSlotTimestamp
	}

	orderID := d.store.GetNextOrderID()
	if err := d.store.SetNextOrderID(0, rlm, gnsmath.SafeAddUint64(orderID, 1)); err != nil {
		return nil, nil, false, 0, err
	}

	executionFeeRate := d.store.GetConfig().ExecutionFeeRate()

	order, err := pdca.NewOrder(orderID, owner, group, amountPerExecution, executionCount, executionFeeRate, currentTimestamp, runtime.ChainHeight())
	if err != nil {
		return nil, nil, false, 0, makeErrorWithDetails(errInvalidExecutionCount, err.Error())
	}

	// Store the order's execution logs now,
	// so the owner pays their storage deposit up front.
	pdca.AllocateExecutionLogs(d.store.GetExecutionLogs(), order)

	roundMark := group.GetOrCreateRoundMark(order.EndRound())
	roundMark.SetOrderAmount(gnsmath.SafeAddInt64(roundMark.OrderAmount(), amountPerExecution))
	roundMark.SetOrderCount(gnsmath.SafeAddInt64(roundMark.OrderCount(), 1))

	groupOrderAmount := gnsmath.SafeAddInt64(group.OrderAmount(), amountPerExecution)
	if err := d.rescheduleGroup(group, groupOrderAmount, nextExecutionTimestamp); err != nil {
		return nil, nil, false, 0, err
	}

	group.SetActiveOrderCount(gnsmath.SafeAddInt64(group.ActiveOrderCount(), 1))

	d.store.GetOrders().Set(pdca.OrderKey(orderID), order)
	d.store.GetOrdersByOwner().Set(pdca.OwnerOrderKey(owner, orderID), orderID)
	d.store.GetOrdersByGroup().Set(pdca.GroupOrderKey(groupID, orderID), orderID)
	d.store.GetOrderAmountsByGroup().Set(pdca.GroupOrderAmountKey(groupID, executionFeeRate, amountPerExecution, orderID), order.EndRound())

	// Pull funds last; a failure reverts every write above.
	common.SafeGRC20TransferFrom(0, rlm, inputToken, owner, rlm.Address(), depositAmount)

	return order, group, isNewGroup, depositAmount, nil
}

// CancelOrder pays accrued output, refunds the input of unexecuted rounds,
// and closes the order, releasing all of its execution logs.
// If every round already executed, the order completes instead,
// with nothing to refund.
func (d *dcaOrderImpl) CancelOrder(_ int, rlm realm, orderID uint64) (int64, int64) {
	access.AssertIsRlmCurrent(0, rlm)
	common.AssertIsNotHandleNativeCoin()
	assertIsNotHalted(halt.OperationWithdraw)
	d.assertIsNotExecuting()

	prev := rlm.Previous()
	caller := prev.Address()

	order, group, err := d.getOrderWithGroup(orderID)
	if err != nil {
		panic(err.Error())
	}

	assertIsOrderOwner(order, caller)

	result, err := d.cancelOrder(0, rlm, caller, prev.PkgPath(), order, group)
	if err != nil {
		panic(err.Error())
	}

	if result.isCompleted {
		// Every round already executed: a completion, not a cancellation.
		emitOrderClaimed(caller, prev.PkgPath(), order, group, result.payout, pdca.OrderStatusCompleted)
	} else {
		emitOrderCancelled(caller, prev.PkgPath(), order, group, result.payout, result.refundedAmount)
	}

	emitPayoutExecutionFee(caller, prev.PkgPath(), group, result.payout.executionFeeAmount, d.pendingExecutionFeeAmount(group.OutputToken()))

	return result.refundedAmount, result.payout.claimedAmount
}

// ForceCancelOrder closes an order that blocks its group's rounds exactly as
// CancelOrder would for its owner: accrued output and unsold input go to the
// owner, never to the caller. The freed storage deposit of its execution logs
// goes to the transaction signer, as for any release.
//
// The order must have rounds left and meet one of the conditions checked
// on-chain by forceCancelReason, reported as the event's reason:
//   - below_min_amount: its amountPerExecution is below the minimum a new
//     order selling its token needs now
//   - no_order_output: the next round is due and, as quoted now, would credit
//     it less than minOrderAmountOutFloor after its execution fee
//   - exceeds_pool_capacity: the next round is due, no pool can fill it
//     as quoted now, a pool fills part of it within the price limit, and no
//     order of the round sells more per execution than this one
//
// Any other order is rejected, so a keeper cannot close healthy orders.
//
// Only keepers allowed by gno.land/r/gnoswap/order/keeper may call it
// (DCAKeeperRole at deployment).
func (d *dcaOrderImpl) ForceCancelOrder(_ int, rlm realm, orderID uint64) (int64, int64) {
	access.AssertIsRlmCurrent(0, rlm)
	common.AssertIsNotHandleNativeCoin()
	assertIsNotHalted(halt.OperationWithdraw)
	d.assertIsNotExecuting()

	prev := rlm.Previous()
	caller := prev.Address()

	if !keeper.IsAuthorized(rlm.PkgPath(), keeper.SelectorForceCancelOrder, caller) {
		panic(makeErrorWithDetails(errNotKeeper, ufmt.Sprintf("caller(%s) selector(%s)", caller.String(), string(keeper.SelectorForceCancelOrder))).Error())
	}

	order, group, err := d.getOrderWithGroup(orderID)
	if err != nil {
		panic(err.Error())
	}

	// Check before the order leaves its group, against the state it blocks.
	reason, err := d.forceCancelReason(order, group, time.Now().Unix())
	if err != nil {
		panic(err.Error())
	}

	result, err := d.cancelOrder(0, rlm, caller, prev.PkgPath(), order, group)
	if err != nil {
		panic(err.Error())
	}

	emitOrderForceCancelled(caller, prev.PkgPath(), order, group, result.payout, result.refundedAmount, reason)

	emitPayoutExecutionFee(caller, prev.PkgPath(), group, result.payout.executionFeeAmount, d.pendingExecutionFeeAmount(group.OutputToken()))

	return result.refundedAmount, result.payout.claimedAmount
}

// Reasons ForceCancelOrder accepts, reported by DCAOrderForceCancelled.
const (
	forceCancelBelowMinAmount      = "below_min_amount"
	forceCancelNoOrderOutput       = "no_order_output"
	forceCancelExceedsPoolCapacity = "exceeds_pool_capacity"
)

// forceCancelReason returns why the order blocks its group, or
// errOrderNotBlocking if it does not (see ForceCancelOrder).
// The round conditions quote the group's next round as ExecuteGroup would
// run it at currentTimestamp, so they hold only while that round is due.
func (d *dcaOrderImpl) forceCancelReason(order *pdca.Order, group *pdca.Group, currentTimestamp int64) (string, error) {
	nextRound := group.Round() + 1
	if nextRound > order.EndRound() {
		// Every round executed: Claim completes it.
		return "", makeErrorWithDetails(errOrderNotBlocking, ufmt.Sprintf("orderId(%d) has no round left", order.ID()))
	}

	if order.AmountPerExecution() < d.minAmountPerExecution(group.InputToken()) {
		return forceCancelBelowMinAmount, nil
	}

	// An active order sells in every round up to its last, so it sells in
	// the next one; it blocks rounds only while that round is due.
	if !isGroupExecutable(group, currentTimestamp) {
		return "", makeErrorWithDetails(
			errOrderNotBlocking,
			ufmt.Sprintf("orderId(%d): groupId(%s) has no due round", order.ID(), group.ID()),
		)
	}

	config := d.store.GetConfig()
	whitelistedPools := whitelist.GetWhitelistedPools(whitelist.TargetDCA)
	priceLimit := getPairPriceLimit(d.store.GetPairPriceLimits(), group.InputToken(), group.OutputToken())
	amountIn := group.OrderAmount()

	selectedPool, candidates := selectPool(whitelistedPools, priceLimit, config.MaxPoolPriceDeviationRate(), config.MaxPairPriceLimitAge(), group.InputToken(), group.OutputToken(), amountIn, true)

	if selectedPool == nil {
		// The round is too large only when a pool fills part of it within
		// the price limit, with some output; a missing or stale price limit, a pool
		// past its limit or without a price or liquidity, or a failed quote
		// blocks every order alike.
		if !hasPartialFill(candidates) {
			return "", makeErrorWithDetails(
				errOrderNotBlocking,
				ufmt.Sprintf("orderId(%d): no pool of groupId(%s) fills part of the round", order.ID(), group.ID()),
			)
		}

		// Shrink the round from its largest orders, one per call: a round that
		// needs several orders gone gets them one after the other, while a
		// keeper cannot pick a smaller order instead.
		if d.sellsLargerOrder(group, nextRound, order.AmountPerExecution()) {
			return "", makeErrorWithDetails(
				errOrderNotBlocking,
				ufmt.Sprintf("orderId(%d): a larger order sells in round %d of groupId(%s)", order.ID(), nextRound, group.ID()),
			)
		}

		return forceCancelExceedsPoolCapacity, nil
	}

	outputPerAmountX128, err := pdca.CalculateOutputPerAmountX128(selectedPool.quotedAmountOut, amountIn)
	if err != nil {
		return "", err
	}

	orderAmountOut, err := calculateMinOrderAmountOut(
		feeRateMinAmount{executionFeeRate: order.ExecutionFeeRate(), minAmountPerExecution: order.AmountPerExecution()},
		outputPerAmountX128,
	)
	if err != nil {
		return "", err
	}

	if orderAmountOut < minOrderAmountOutFloor {
		return forceCancelNoOrderOutput, nil
	}

	return "", makeErrorWithDetails(
		errOrderNotBlocking,
		ufmt.Sprintf("orderId(%d) would be credited %d in the next round", order.ID(), orderAmountOut),
	)
}

// hasPartialFill reports whether a candidate pool fills only part of the
// round within the price limit, with some output, so that a smaller round
// may fill. A pool that swaps nothing, such as one without liquidity, also
// reports codePartialFill but cannot fill any smaller round.
func hasPartialFill(candidates []*poolCandidate) bool {
	for _, candidate := range candidates {
		if candidate.ineligibleCode == codePartialFill && candidate.partialAmountOut > 0 {
			return true
		}
	}

	return false
}

// sellsLargerOrder reports whether an order of the group selling in round
// has a larger amountPerExecution than amountPerExecution.
// The amount index sorts a group's orders by fee rate, then amount, so each
// fee rate costs one reverse seek past its finished orders, as in
// getFeeRateMinAmounts.
func (d *dcaOrderImpl) sellsLargerOrder(group *pdca.Group, round uint64, amountPerExecution int64) bool {
	orderAmountsByGroup := d.store.GetOrderAmountsByGroup()
	prefix := pdca.GroupOrderPrefix(group.ID())
	end := pdca.PrefixEnd(prefix)
	start := prefix

	for {
		found := false
		executionFeeRate := int64(0)

		orderAmountsByGroup.Iterate(start, end, func(key string, _ any) bool {
			executionFeeRate = pdca.GroupOrderAmountKeyFeeRate(group.ID(), key)
			found = true

			return true
		})

		if !found {
			return false
		}

		ratePrefix := pdca.GroupOrderFeeRatePrefix(group.ID(), executionFeeRate)
		rateEnd := pdca.PrefixEnd(ratePrefix)
		larger := false

		// The largest selling order of the rate; finished orders, whose last
		// round is before round, are skipped.
		orderAmountsByGroup.ReverseIterate(ratePrefix, rateEnd, func(key string, value any) bool {
			if key >= rateEnd || value.(uint64) < round {
				return false
			}

			larger = pdca.GroupOrderAmountKeyAmount(group.ID(), key) > amountPerExecution

			return true
		})

		if larger {
			return true
		}

		start = rateEnd
	}
}

// orderCancelResult describes a closed order.
type orderCancelResult struct {
	payout         orderPayout
	refundedAmount int64 // unsold input returned to the owner
	isCompleted    bool  // every round had already executed
}

// cancelOrder closes an active order and transfers its output and refund.
// The order's execution fee on its output is kept as pending.
func (d *dcaOrderImpl) cancelOrder(
	_ int,
	rlm realm,
	prevAddr address,
	prevRealm string,
	order *pdca.Order,
	group *pdca.Group,
) (orderCancelResult, error) {
	endAccumulatedX128, isLastRoundExecuted, err := getOrderEndAccumulatedOutputPerAmountX128(order, group)
	if err != nil {
		return orderCancelResult{}, err
	}

	payout, err := calculateOrderPayout(order, endAccumulatedX128)
	if err != nil {
		return orderCancelResult{}, err
	}

	refundedAmount := int64(0)

	if !isLastRoundExecuted {
		remainingRoundCount := order.EndRound() - group.Round()
		refundedAmount = gnsmath.SafeMulInt64(order.AmountPerExecution(), int64(remainingRoundCount))

		groupOrderAmount := gnsmath.SafeSubInt64(group.OrderAmount(), order.AmountPerExecution())
		if err := d.rescheduleGroup(group, groupOrderAmount, group.NextExecutionTimestamp()); err != nil {
			return orderCancelResult{}, err
		}

		roundMark := group.GetRoundMark(order.EndRound())
		if roundMark == nil {
			return orderCancelResult{}, makeErrorWithDetails(errInvalidState, ufmt.Sprintf("missing mark for round %d", order.EndRound()))
		}

		roundMark.SetOrderAmount(gnsmath.SafeSubInt64(roundMark.OrderAmount(), order.AmountPerExecution()))
	}

	order.SetDebtX128(endAccumulatedX128)
	recordOrderPayout(order, payout)
	d.addPendingExecutionFee(group.OutputToken(), payout.executionFeeAmount)

	d.releaseExecutionLogs(prevAddr, prevRealm, order, group, true)

	if err := d.finalizeOrder(order, group); err != nil {
		return orderCancelResult{}, err
	}

	if payout.claimedAmount > 0 {
		common.SafeGRC20Transfer(0, rlm, group.OutputToken(), order.Owner(), payout.claimedAmount)
	}

	if refundedAmount > 0 {
		common.SafeGRC20Transfer(0, rlm, group.InputToken(), order.Owner(), refundedAmount)
	}

	return orderCancelResult{payout: payout, refundedAmount: refundedAmount, isCompleted: isLastRoundExecuted}, nil
}

// Claim pays the order's accrued output to its owner,
// and releases the order's execution logs whose rounds all executed.
// Anyone may call it; the freed storage deposit goes to the caller.
// The order completes once every round executed.
func (d *dcaOrderImpl) Claim(_ int, rlm realm, orderID uint64) int64 {
	access.AssertIsRlmCurrent(0, rlm)
	common.AssertIsNotHandleNativeCoin()
	assertIsNotHalted(halt.OperationWithdraw)
	d.assertIsNotExecuting()

	prev := rlm.Previous()

	order, group, err := d.getOrderWithGroup(orderID)
	if err != nil {
		panic(err.Error())
	}

	payout, _, _, err := d.claimOrder(0, rlm, prev.Address(), prev.PkgPath(), order, group)
	if err != nil {
		panic(err.Error())
	}

	emitPayoutExecutionFee(prev.Address(), prev.PkgPath(), group, payout.executionFeeAmount, d.pendingExecutionFeeAmount(group.OutputToken()))

	return payout.claimedAmount
}

// claimOrder pays an active order's accrued output, net of its execution
// fee, to its owner, completing the order once its last round ran,
// and releases its execution logs whose rounds all executed.
// The execution fee is kept as pending for the protocol fee realm.
// It returns the payout, the number of logs released,
// and whether anything was paid or completed.
func (d *dcaOrderImpl) claimOrder(
	_ int,
	rlm realm,
	prevAddr address,
	prevRealm string,
	order *pdca.Order,
	group *pdca.Group,
) (orderPayout, int64, bool, error) {
	endAccumulatedX128, isLastRoundExecuted, err := getOrderEndAccumulatedOutputPerAmountX128(order, group)
	if err != nil {
		return orderPayout{}, 0, false, err
	}

	payout, err := calculateOrderPayout(order, endAccumulatedX128)
	if err != nil {
		return orderPayout{}, 0, false, err
	}

	// Nothing accrued or to finalize: skip the payout writes and events,
	// so anyone calling Claim cannot spam the owner's event history.
	if payout.grossAmount == 0 && !isLastRoundExecuted {
		releasedCount := d.releaseExecutionLogs(prevAddr, prevRealm, order, group, false)
		return orderPayout{}, releasedCount, false, nil
	}

	// An active order's debt moves only by the gross output paid,
	// so the remainder below one unit stays owed until later rounds
	// add it up to a whole unit; a completed order settles at its end.
	nextDebtX128 := endAccumulatedX128
	if !isLastRoundExecuted {
		nextDebtX128, err = calculateDebtX128AfterPayout(order.AmountPerExecution(), order.DebtX128(), payout.grossAmount)
		if err != nil {
			return orderPayout{}, 0, false, err
		}
	}

	order.SetDebtX128(nextDebtX128)
	recordOrderPayout(order, payout)
	d.addPendingExecutionFee(group.OutputToken(), payout.executionFeeAmount)

	releasedCount := d.releaseExecutionLogs(prevAddr, prevRealm, order, group, isLastRoundExecuted)

	status := pdca.OrderStatusActive
	if isLastRoundExecuted {
		status = pdca.OrderStatusCompleted

		if err := d.finalizeOrder(order, group); err != nil {
			return orderPayout{}, 0, false, err
		}
	}

	if payout.claimedAmount > 0 {
		common.SafeGRC20Transfer(0, rlm, group.OutputToken(), order.Owner(), payout.claimedAmount)
	}

	emitOrderClaimed(prevAddr, prevRealm, order, group, payout, status)

	return payout, releasedCount, true, nil
}

// releaseExecutionLogs releases the order's logs whose rounds all executed,
// or every log of an order being finalized,
// so the freed storage deposit is refunded to the caller.
// Call it before finalizeOrder deletes the order.
func (d *dcaOrderImpl) releaseExecutionLogs(prevAddr address, prevRealm string, order *pdca.Order, group *pdca.Group, isFinalized bool) int64 {
	executionLogs := d.store.GetExecutionLogs()

	releasedCount := int64(0)
	if isFinalized {
		releasedCount = pdca.ReleaseAllExecutionLogs(executionLogs, order)
	} else {
		releasedCount = pdca.ReleaseExecutionLogs(executionLogs, order, group.Round())
	}

	if releasedCount > 0 {
		emitExecutionLogsReleased(prevAddr, prevRealm, order, group, releasedCount)
	}

	return releasedCount
}

// finalizeOrder releases a completed or cancelled order from its group
// and deletes all of its stored data: the order record, its owner and
// group index entries, and its end-round mark once no order references it.
// A finished order's amount index entry may already be pruned by a round.
//
// Freeing the storage refunds its deposit to the transaction signer,
// which pays keepers that finalize orders through ClaimGroupOrders.
// The order's final state is kept in the emitted event, not in state.
func (d *dcaOrderImpl) finalizeOrder(order *pdca.Order, group *pdca.Group) error {
	if err := releaseRoundMark(group, order.EndRound()); err != nil {
		return err
	}

	group.SetActiveOrderCount(group.ActiveOrderCount() - 1)

	d.store.GetOrders().Remove(pdca.OrderKey(order.ID()))
	d.store.GetOrdersByOwner().Remove(pdca.OwnerOrderKey(order.Owner(), order.ID()))
	d.store.GetOrdersByGroup().Remove(pdca.GroupOrderKey(group.ID(), order.ID()))
	d.store.GetOrderAmountsByGroup().Remove(pdca.GroupOrderAmountKey(group.ID(), order.ExecutionFeeRate(), order.AmountPerExecution(), order.ID()))

	return nil
}
