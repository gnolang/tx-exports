package impl

import (
	"gno.land/p/gnoswap/gnsmath/v1"
	prbac "gno.land/p/gnoswap/rbac/v1"
	bptree "gno.land/p/nt/bptree/v0"

	"gno.land/r/gnoswap/access/v1"
	"gno.land/r/gnoswap/common"
	"gno.land/r/gnoswap/halt/v1"
	orderhalt "gno.land/r/gnoswap/order/halt"
	pf "gno.land/r/gnoswap/protocol_fee"
	_ "gno.land/r/gnoswap/protocol_fee/v1"
)

// SetExecutionFeeRate changes the rate snapshotted by future orders only.
// Admin or governance only.
func (l *limitOrderImpl) SetExecutionFeeRate(_ int, rlm realm, executionFeeRate int64) {
	prev := l.assertIsAdminCall(0, rlm)

	config := l.store.GetConfig()

	previousExecutionFeeRate := config.ExecutionFeeRate()
	if err := config.SetExecutionFeeRate(executionFeeRate); err != nil {
		panic(makeErrorWithDetails(errInvalidExecutionFeeRate, err.Error()).Error())
	}

	emitExecutionFeeRateChanged(prev.Address(), prev.PkgPath(), previousExecutionFeeRate, executionFeeRate)
}

// CollectPendingExecutionFee forwards pending fees without executing an order.
// Anyone may call it; funds only move to the protocol fee realm.
func (l *limitOrderImpl) CollectPendingExecutionFee(_ int, rlm realm, tokenPath string) (int64, int64) {
	prev := l.assertIsCall(0, rlm)

	assertIsNotHalted(orderhalt.OperationWithdraw)

	forwardedAmount, pendingAmount := l.collectExecutionFee(0, rlm, tokenPath, 0)
	if forwardedAmount > 0 {
		emitExecutionFeeCollected(prev.Address(), prev.PkgPath(), 0, tokenPath, 0, forwardedAmount, pendingAmount)
	}

	return forwardedAmount, pendingAmount
}

// collectExecutionFee keeps execution fees pending while collection is halted
// or rejected, and retries on the next fill or explicit collection.
// It also runs for zero execution-fee fills so they can forward earlier pending fees.
// It returns the amount forwarded and the amount left pending.
func (l *limitOrderImpl) collectExecutionFee(_ int, rlm realm, tokenPath string, executionFeeAmount int64) (int64, int64) {
	pendingExecutionFees := l.store.GetPendingExecutionFees()
	pendingAmount := getPendingExecutionFeeAmount(pendingExecutionFees, tokenPath)

	totalAmount := gnsmath.SafeAddInt64(pendingAmount, executionFeeAmount)
	if totalAmount <= 0 {
		return 0, 0
	}

	if halt.IsHaltedProtocolFee() {
		pendingExecutionFees.Set(tokenPath, totalAmount)
		return 0, totalAmount
	}

	// Remove the pending debit before external calls so re-entry cannot collect
	// it twice. A rejected collection restores it; an abort rolls back the call.
	if pendingAmount > 0 {
		pendingExecutionFees.Remove(tokenPath)
	}

	protocolFeeAddress := access.MustGetAddress(prbac.ROLE_PROTOCOL_FEE.String())
	common.SafeGRC20Approve(0, rlm, tokenPath, protocolFeeAddress, totalAmount)
	err := pf.AddToProtocolFee(cross(rlm), tokenPath, totalAmount)
	common.SafeGRC20Approve(0, rlm, tokenPath, protocolFeeAddress, 0)

	if err != nil {
		pendingExecutionFees.Set(tokenPath, totalAmount)
		return 0, totalAmount
	}

	return totalAmount, 0
}

func getPendingExecutionFeeAmount(pendingExecutionFees *bptree.BPTree, tokenPath string) int64 {
	value := pendingExecutionFees.Get(tokenPath)
	if value == nil {
		return 0
	}

	return value.(int64)
}
