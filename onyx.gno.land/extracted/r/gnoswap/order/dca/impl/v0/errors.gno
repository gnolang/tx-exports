package impl

import (
	ufmt "gno.land/p/nt/ufmt/v0"
)

const (
	errInvalidPool             = "[GNOSWAP-ORDER-DCA-001] invalid pool"
	errInvalidToken            = "[GNOSWAP-ORDER-DCA-002] invalid token"
	errInvalidInterval         = "[GNOSWAP-ORDER-DCA-003] invalid interval"
	errInvalidAmount           = "[GNOSWAP-ORDER-DCA-004] invalid amount"
	errInvalidExecutionCount   = "[GNOSWAP-ORDER-DCA-005] invalid number of executions"
	errOrderNotFound           = "[GNOSWAP-ORDER-DCA-006] order not found"
	errNotOrderOwner           = "[GNOSWAP-ORDER-DCA-007] caller is not the order owner"
	errGroupNotFound           = "[GNOSWAP-ORDER-DCA-008] group not found"
	errGroupNotExecutable      = "[GNOSWAP-ORDER-DCA-009] group is not executable"
	errSwapMismatch            = "[GNOSWAP-ORDER-DCA-010] swap result mismatch"
	errInvalidConfig           = "[GNOSWAP-ORDER-DCA-011] invalid config"
	errInvalidState            = "[GNOSWAP-ORDER-DCA-012] invalid accounting state"
	errOverflow                = "[GNOSWAP-ORDER-DCA-013] overflow"
	errReentrant               = "[GNOSWAP-ORDER-DCA-014] reentrant call during group execution"
	errInvalidCursor           = "[GNOSWAP-ORDER-DCA-015] invalid cursor"
	errNotKeeper               = "[GNOSWAP-ORDER-DCA-016] caller is not an authorized keeper"
	errNoEligiblePool          = "[GNOSWAP-ORDER-DCA-017] no eligible pool"
	errInvalidExecutionFeeRate = "[GNOSWAP-ORDER-DCA-018] invalid execution fee rate"
	errInvalidSlotOffset       = "[GNOSWAP-ORDER-DCA-019] invalid slot offset"
	errInvalidSlotStep         = "[GNOSWAP-ORDER-DCA-020] invalid slot step"
	errHalted                  = "[GNOSWAP-ORDER-DCA-021] operation halted"
	errAmountInMismatch        = "[GNOSWAP-ORDER-DCA-022] round input does not match the quote"
	errInsufficientOrderOutput = "[GNOSWAP-ORDER-DCA-024] insufficient output per order"
	errInsufficientSwapOutput  = "[GNOSWAP-ORDER-DCA-025] swap output below amountOutMin"
	errInvalidPriceLimit       = "[GNOSWAP-ORDER-DCA-026] invalid price limit"
	errMissingPriceLimit       = "[GNOSWAP-ORDER-DCA-027] missing price limit"
	errOrderNotBlocking        = "[GNOSWAP-ORDER-DCA-028] order does not block its group"
)

func makeErrorWithDetails(message string, details string) error {
	return ufmt.Errorf("%s || %s", message, details)
}
