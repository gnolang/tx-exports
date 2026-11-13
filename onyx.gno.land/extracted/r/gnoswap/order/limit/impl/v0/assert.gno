package impl

import (
	plimit "gno.land/p/gnoswap/order/limit/v0"
	ufmt "gno.land/p/nt/ufmt/v0"
	"gno.land/r/gnoswap/access/v1"
	"gno.land/r/gnoswap/common"
	"gno.land/r/gnoswap/order/halt"
	"gno.land/r/gnoswap/order/keeper"
)

func (l *limitOrderImpl) assertIsCall(_ int, rlm realm) realm {
	access.AssertIsRlmCurrent(0, rlm)
	common.AssertIsNotHandleNativeCoin()

	return rlm.Previous()
}

func (l *limitOrderImpl) assertIsAdminCall(_ int, rlm realm) realm {
	prev := l.assertIsCall(0, rlm)
	access.AssertIsAdminOrGovernance(prev.Address())

	return prev
}

func assertIsOrderOwner(order *plimit.Order, caller address) {
	if order.Owner() != caller {
		panic(makeErrorWithDetails(errNotOrderOwner, "order belongs to another caller").Error())
	}
}

// Authorization belongs to the proxy target and its immediate caller, not to
// the implementation or the transaction's origin signer.
func assertIsAuthorizedKeeper(target string, caller address) {
	if !keeper.IsAuthorized(target, keeper.SelectorExecuteOrder, caller) {
		panic(makeErrorWithDetails(errNotKeeper, ufmt.Sprintf("caller(%s)", caller.String())).Error())
	}
}

// validateNotHalted reports the first operation halted for Limit orders.
func validateNotHalted(operations ...string) error {
	for _, operation := range operations {
		if halt.IsHalted(halt.TargetLimit, operation) {
			return makeErrorWithDetails(errHalted, ufmt.Sprintf("operation(%s)", operation))
		}
	}

	return nil
}

func assertIsNotHalted(operations ...string) {
	if err := validateNotHalted(operations...); err != nil {
		panic(err.Error())
	}
}
