package impl

import (
	"gno.land/p/gnoswap/gnsmath/v1"
	pdca "gno.land/p/gnoswap/order/dca/v0"
	prbac "gno.land/p/gnoswap/rbac/v1"
	bptree "gno.land/p/nt/bptree/v0"
	ufmt "gno.land/p/nt/ufmt/v0"

	"gno.land/r/gnoswap/access/v1"
	"gno.land/r/gnoswap/common"
	"gno.land/r/gnoswap/order/halt"

	pf "gno.land/r/gnoswap/protocol_fee"
	_ "gno.land/r/gnoswap/protocol_fee/v1"
)

// SetExecutionFeeRate sets the execution fee rate, in basis points,
// snapshotted by orders created afterwards.
// Existing orders keep the rate they were created with.
// Admin or governance only.
func (d *dcaOrderImpl) SetExecutionFeeRate(_ int, rlm realm, executionFeeRate int64) {
	access.AssertIsRlmCurrent(0, rlm)
	common.AssertIsNotHandleNativeCoin()
	d.assertIsNotExecuting()

	prev := rlm.Previous()
	access.AssertIsAdminOrGovernance(prev.Address())

	config := d.store.GetConfig()
	previousExecutionFeeRate := config.ExecutionFeeRate()

	if err := config.SetExecutionFeeRate(executionFeeRate); err != nil {
		panic(makeErrorWithDetails(
			errInvalidExecutionFeeRate,
			ufmt.Sprintf("executionFeeRate(%d) must be in [0, %d]", executionFeeRate, pdca.MaxExecutionFeeRate),
		).Error())
	}

	emitExecutionFeeRateChanged(prev.Address(), prev.PkgPath(), previousExecutionFeeRate, executionFeeRate)
}

// CollectPendingExecutionFee forwards the execution fee pending for
// tokenPath to the protocol fee realm. Payouts keep their execution fee as
// pending and rounds forward the pending fee of their output token; this
// forwards it when no round of that output token runs.
// Anyone may call it: the fee only moves to the protocol fee realm.
// It returns the amount forwarded and the amount left pending.
func (d *dcaOrderImpl) CollectPendingExecutionFee(_ int, rlm realm, tokenPath string) (int64, int64) {
	access.AssertIsRlmCurrent(0, rlm)
	common.AssertIsNotHandleNativeCoin()
	assertIsNotHalted(halt.OperationWithdraw)
	d.assertIsNotExecuting()

	prev := rlm.Previous()

	// The execution lock blocks re-entry while the protocol fee realm pulls
	// the fee, as it does during a round.
	if err := d.store.SetExecuting(0, rlm, true); err != nil {
		panic(err.Error())
	}

	forwardedAmount, pendingAmount := d.collectExecutionFee(0, rlm, tokenPath, 0)

	if err := d.store.SetExecuting(0, rlm, false); err != nil {
		panic(err.Error())
	}

	if forwardedAmount > 0 || pendingAmount > 0 {
		emitExecutionFeeCollected(prev.Address(), prev.PkgPath(), "", tokenPath, 0, 0, forwardedAmount, pendingAmount)
	}

	return forwardedAmount, pendingAmount
}

// addPendingExecutionFee holds a payout's execution fee for tokenPath
// until a round or CollectPendingExecutionFee forwards it.
// A payout never calls the protocol fee realm,
// so that realm cannot block withdrawals.
func (d *dcaOrderImpl) addPendingExecutionFee(tokenPath string, executionFeeAmount int64) {
	if executionFeeAmount <= 0 {
		return
	}

	pendingExecutionFees := d.store.GetPendingExecutionFees()
	pendingAmount := getPendingExecutionFeeAmount(pendingExecutionFees, tokenPath)

	pendingExecutionFees.Set(tokenPath, gnsmath.SafeAddInt64(pendingAmount, executionFeeAmount))
}

// pendingExecutionFeeAmount returns the execution fee of tokenPath
// held by this realm, 0 if none.
func (d *dcaOrderImpl) pendingExecutionFeeAmount(tokenPath string) int64 {
	return getPendingExecutionFeeAmount(d.store.GetPendingExecutionFees(), tokenPath)
}

// collectExecutionFee forwards executionFeeAmount, plus anything already
// pending for tokenPath, to the protocol fee realm.
// When collection is halted or the protocol fee realm rejects it,
// the total is held as pending and forwarded by a later collection
// of the same token, so a halt never blocks execution.
// It returns the amount forwarded and the amount left pending.
func (d *dcaOrderImpl) collectExecutionFee(_ int, rlm realm, tokenPath string, executionFeeAmount int64) (int64, int64) {
	pendingExecutionFees := d.store.GetPendingExecutionFees()

	pendingAmount := getPendingExecutionFeeAmount(pendingExecutionFees, tokenPath)

	totalAmount := gnsmath.SafeAddInt64(pendingAmount, executionFeeAmount)
	if totalAmount <= 0 {
		return 0, 0
	}

	protocolFeeAddress := access.MustGetAddress(prbac.ROLE_PROTOCOL_FEE.String())
	common.SafeGRC20Approve(0, rlm, tokenPath, protocolFeeAddress, totalAmount)

	// AddToProtocolFee pulls the approved amount from this realm. It returns
	// an error while its collection is halted; nothing was pulled then:
	// withdraw the approval and keep it pending.
	if err := pf.AddToProtocolFee(cross(rlm), tokenPath, totalAmount); err != nil {
		common.SafeGRC20Approve(0, rlm, tokenPath, protocolFeeAddress, 0)
		pendingExecutionFees.Set(tokenPath, totalAmount)

		return 0, totalAmount
	}

	// Keep the token's entry at zero rather than removing it: payouts add to
	// it again, and recreating it would charge the next payout its storage.
	if pendingAmount > 0 {
		pendingExecutionFees.Set(tokenPath, int64(0))
	}

	return totalAmount, 0
}

// getPendingExecutionFeeAmount returns the execution fee of tokenPath
// held by this realm, 0 if none.
func getPendingExecutionFeeAmount(pendingExecutionFees *bptree.BPTree, tokenPath string) int64 {
	value := pendingExecutionFees.Get(tokenPath)
	if value == nil {
		return 0
	}

	return value.(int64)
}
