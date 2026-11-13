package impl

import (
	"gno.land/p/gnoswap/order/access/manager/v0"
	pdca "gno.land/p/gnoswap/order/dca/v0"
	prbac "gno.land/p/gnoswap/rbac/v1"
	bptree "gno.land/p/nt/bptree/v0"
	ufmt "gno.land/p/nt/ufmt/v0"

	"gno.land/r/gnoswap/access/v1"
	"gno.land/r/gnoswap/common"
	"gno.land/r/gnoswap/order/halt"
	"gno.land/r/gnoswap/order/keeper"
	"gno.land/r/gnoswap/order/whitelist"
)

// assertIsAdminCall runs the checks shared by admin entry points
// and returns the calling realm.
func (d *dcaOrderImpl) assertIsAdminCall(_ int, rlm realm) realm {
	access.AssertIsRlmCurrent(0, rlm)
	common.AssertIsNotHandleNativeCoin()
	d.assertIsNotExecuting()

	prev := rlm.Previous()
	access.AssertIsAdminOrGovernance(prev.Address())

	return prev
}

// assertIsNotExecuting rejects re-entry from the swap
// into any state-changing entry point.
func (d *dcaOrderImpl) assertIsNotExecuting() {
	if d.store.IsExecuting() {
		panic(makeErrorWithDetails(errReentrant, "group execution in progress").Error())
	}
}

// assertIsNotHalted rejects the call while any of operations is halted
// for DCA orders in gno.land/r/gnoswap/order/halt.
func assertIsNotHalted(operations ...string) {
	if operation, halted := haltedOperation(operations...); halted {
		panic(makeErrorWithDetails(errHalted, ufmt.Sprintf("operation(%s)", operation)).Error())
	}
}

// haltedOperation returns the first of operations halted for DCA orders.
func haltedOperation(operations ...string) (string, bool) {
	for _, operation := range operations {
		if halt.IsHalted(halt.TargetDCA, operation) {
			return operation, true
		}
	}

	return "", false
}

// assertIsAuthorizedKeeper rejects callers that gno.land/r/gnoswap/order/keeper
// does not allow to run rounds on target, the DCA proxy package path.
// ExecuteGroup is assigned to DCAKeeperRole at deployment; admin or
// governance grants it to keepers or reassigns the selector.
func assertIsAuthorizedKeeper(target string, caller address) {
	if !keeper.IsAuthorized(target, keeper.SelectorExecuteGroup, caller) {
		panic(makeErrorWithDetails(errNotKeeper, ufmt.Sprintf("caller(%s)", caller.String())).Error())
	}
}

// assertIsManagerCall runs the checks shared by the manager entry points
// (token minimums and pair price limits) and returns the calling realm.
// Admin and governance may always call them; other callers need the
// PoolManagerRole that gno.land/r/gnoswap/order/keeper assigns on the DCA
// proxy package path.
func (d *dcaOrderImpl) assertIsManagerCall(_ int, rlm realm, selector manager.Selector) realm {
	access.AssertIsRlmCurrent(0, rlm)
	common.AssertIsNotHandleNativeCoin()
	d.assertIsNotExecuting()

	prev := rlm.Previous()
	caller := prev.Address()

	if isAdminOrGovernance(caller) || keeper.IsAuthorized(rlm.PkgPath(), selector, caller) {
		return prev
	}

	panic(makeErrorWithDetails(errNotKeeper, ufmt.Sprintf("caller(%s) selector(%s)", caller.String(), string(selector))).Error())
}

// isAdminOrGovernance reports whether caller is the GnoSwap admin or governance.
func isAdminOrGovernance(caller address) bool {
	return access.IsAuthorized(prbac.ROLE_ADMIN.String(), caller) || access.IsAuthorized(prbac.ROLE_GOVERNANCE.String(), caller)
}

// assertIsValidPair checks that inputToken and outputToken differ
// and that at least one whitelisted direct pool connects them.
func assertIsValidPair(inputToken string, outputToken string) {
	if inputToken == outputToken {
		panic(makeErrorWithDetails(errInvalidToken, ufmt.Sprintf("inputToken and outputToken are both %s", inputToken)).Error())
	}

	if !whitelist.HasWhitelistedPool(whitelist.TargetDCA, inputToken, outputToken) {
		panic(makeErrorWithDetails(errInvalidPool, ufmt.Sprintf("no whitelisted pool for %s -> %s", inputToken, outputToken)).Error())
	}
}

// assertHasPairPriceLimit checks that the pair direction has a price limit,
// without which its rounds cannot trade.
func assertHasPairPriceLimit(pairPriceLimits *bptree.BPTree, inputToken string, outputToken string) {
	if getPairPriceLimit(pairPriceLimits, inputToken, outputToken) == nil {
		panic(makeErrorWithDetails(errMissingPriceLimit, ufmt.Sprintf("no price limit for %s -> %s", inputToken, outputToken)).Error())
	}
}

// assertIsAllowedInterval checks that new orders may use interval.
func assertIsAllowedInterval(config *pdca.Config, interval int64) {
	if !config.IsAllowedInterval(interval) {
		panic(makeErrorWithDetails(errInvalidInterval, ufmt.Sprintf("interval(%d)", interval)).Error())
	}
}

// assertIsAllowedSlot checks that new orders may use slotOffset at interval.
func assertIsAllowedSlot(config *pdca.Config, interval int64, slotOffset int64) {
	if !config.IsAllowedSlot(interval, slotOffset) {
		panic(makeErrorWithDetails(
			errInvalidSlotOffset,
			ufmt.Sprintf("slotOffset(%d) must be a multiple of %d in [0, %d)", slotOffset, config.SlotStep(interval), interval),
		).Error())
	}
}

// assertIsValidOrderSize checks the order against the configured limits;
// minAmountPerExecution is the effective minimum of the input token
// (see minAmountPerExecution).
func assertIsValidOrderSize(config *pdca.Config, minAmountPerExecution int64, amountPerExecution int64, executionCount int64) {
	if amountPerExecution < minAmountPerExecution {
		panic(makeErrorWithDetails(
			errInvalidAmount,
			ufmt.Sprintf("amountPerExecution(%d) must be >= %d", amountPerExecution, minAmountPerExecution),
		).Error())
	}

	if executionCount <= 0 || executionCount > config.MaxExecutionCount() {
		panic(makeErrorWithDetails(
			errInvalidExecutionCount,
			ufmt.Sprintf("executionCount(%d) must be in [1, %d]", executionCount, config.MaxExecutionCount()),
		).Error())
	}
}

// assertIsOrderOwner checks that caller owns the order.
func assertIsOrderOwner(order *pdca.Order, caller address) {
	if order.Owner() != caller {
		panic(makeErrorWithDetails(errNotOrderOwner, ufmt.Sprintf("orderId(%d)", order.ID())).Error())
	}
}

// assertIsQuotedAmountIn checks that the round sells the input
// amountOutMin was quoted for.
// A floor quoted for a larger input would keep that trade's price impact,
// which is looser than the smaller round needs, so a changed orderAmount
// needs a new quote instead of a rescaled floor.
// Passing 0 for both skips the check.
func assertIsQuotedAmountIn(group *pdca.Group, expectedAmountIn int64, amountOutMin int64) {
	if expectedAmountIn == 0 && amountOutMin == 0 {
		return
	}

	if expectedAmountIn != group.OrderAmount() {
		panic(makeErrorWithDetails(
			errAmountInMismatch,
			ufmt.Sprintf("groupId(%s) expectedAmountIn(%d) orderAmount(%d)", group.ID(), expectedAmountIn, group.OrderAmount()),
		).Error())
	}
}
