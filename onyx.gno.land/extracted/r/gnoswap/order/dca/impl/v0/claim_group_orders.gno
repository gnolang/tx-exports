package impl

import (
	"gno.land/p/gnoswap/gnsmath/v1"
	pdca "gno.land/p/gnoswap/order/dca/v0"
	ufmt "gno.land/p/nt/ufmt/v0"

	"gno.land/r/gnoswap/access/v1"
	"gno.land/r/gnoswap/common"
	"gno.land/r/gnoswap/order/halt"
)

// ClaimGroupOrders pays accrued output to the owners of a group's active
// orders, like Claim, so owners receive output without claiming.
// Anyone may call it; output always goes to the order owner.
//
// The call releases each examined order's execution logs whose rounds all executed
// and deletes finished orders. The freed storage deposit is refunded to the
// caller, a fixed reward per log of three executed rounds.
//
// One call examines at most min(maxOrderCount, maxClaimBatchSize) orders
// after startAfterOrderID, in ID order, so its gas stays bounded.
// The returned cursor is the last examined order ID; pass it back until it
// is 0. New orders get higher IDs and finished orders leave the index,
// so changes between calls neither skip nor repeat an order.
func (d *dcaOrderImpl) ClaimGroupOrders(_ int, rlm realm, groupID string, startAfterOrderID uint64, maxOrderCount int) (int, uint64) {
	access.AssertIsRlmCurrent(0, rlm)
	common.AssertIsNotHandleNativeCoin()
	assertIsNotHalted(halt.OperationWithdraw)
	d.assertIsNotExecuting()

	if maxOrderCount <= 0 {
		panic(makeErrorWithDetails(errInvalidAmount, ufmt.Sprintf("maxOrderCount(%d) must be positive", maxOrderCount)).Error())
	}

	group, err := d.getGroup(groupID)
	if err != nil {
		panic(err.Error())
	}

	prev := rlm.Previous()

	result, err := d.claimGroupOrders(0, rlm, prev.Address(), prev.PkgPath(), group, startAfterOrderID, maxOrderCount)
	if err != nil {
		panic(err.Error())
	}

	emitGroupOrdersClaimed(
		prev.Address(),
		prev.PkgPath(),
		groupID,
		result.examinedOrderCount,
		result.claimedOrderCount,
		result.releasedExecutionLogCount,
		result.nextCursor,
	)

	emitPayoutExecutionFee(prev.Address(), prev.PkgPath(), group, result.executionFeeAmount, d.pendingExecutionFeeAmount(group.OutputToken()))

	return result.claimedOrderCount, result.nextCursor
}

// groupOrdersClaimResult describes one page of claimGroupOrders.
type groupOrdersClaimResult struct {
	examinedOrderCount        int
	claimedOrderCount         int    // orders paid or completed
	releasedExecutionLogCount int64  // order logs freed for the caller
	executionFeeAmount        int64  // execution fee the payouts kept as pending
	nextCursor                uint64 // last examined order ID, 0 when the group is done
}

// claimGroupOrders claims one page of the group's orders.
func (d *dcaOrderImpl) claimGroupOrders(
	_ int,
	rlm realm,
	prevAddr address,
	prevRealm string,
	group *pdca.Group,
	startAfterOrderID uint64,
	maxOrderCount int,
) (groupOrdersClaimResult, error) {
	limit := int64(maxOrderCount)
	if maxClaimBatchSize := d.store.GetConfig().MaxClaimBatchSize(); limit > maxClaimBatchSize {
		limit = maxClaimBatchSize
	}

	orderIDs, hasMore := d.getGroupOrderIDs(group.ID(), startAfterOrderID, int(limit))

	result := groupOrdersClaimResult{examinedOrderCount: len(orderIDs)}
	for _, orderID := range orderIDs {
		order, err := d.getOrder(orderID)
		if err != nil {
			return groupOrdersClaimResult{}, err
		}

		payout, releasedCount, isUpdated, err := d.claimOrder(0, rlm, prevAddr, prevRealm, order, group)
		if err != nil {
			return groupOrdersClaimResult{}, err
		}

		result.executionFeeAmount = gnsmath.SafeAddInt64(result.executionFeeAmount, payout.executionFeeAmount)

		result.releasedExecutionLogCount = gnsmath.SafeAddInt64(result.releasedExecutionLogCount, releasedCount)

		if isUpdated {
			result.claimedOrderCount++
		}
	}

	if hasMore {
		result.nextCursor = orderIDs[len(orderIDs)-1]
	}

	return result, nil
}

// getGroupOrderIDs returns up to count active order IDs of a group after
// startAfterID, and whether more remain. IDs are collected before any
// order is claimed, since a claim may remove entries from the index.
func (d *dcaOrderImpl) getGroupOrderIDs(groupID string, startAfterID uint64, count int) ([]uint64, bool) {
	if startAfterID == ^uint64(0) {
		return nil, false
	}

	prefix := pdca.GroupOrderPrefix(groupID)
	start := pdca.GroupOrderKey(groupID, gnsmath.SafeAddUint64(startAfterID, 1))

	orderIDs := []uint64{}
	hasMore := false

	d.store.GetOrdersByGroup().Iterate(start, pdca.PrefixEnd(prefix), func(_ string, value any) bool {
		if len(orderIDs) == count {
			hasMore = true
			return true
		}

		orderIDs = append(orderIDs, value.(uint64))

		return false
	})

	return orderIDs, hasMore
}
