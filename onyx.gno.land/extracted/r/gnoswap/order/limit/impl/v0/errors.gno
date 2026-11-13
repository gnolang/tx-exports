package impl

import (
	plimit "gno.land/p/gnoswap/order/limit/v0"
	ufmt "gno.land/p/nt/ufmt/v0"
)

const (
	errInvalidTokenIn          = "[GNOSWAP-ORDER-LIMIT-001] invalid token in"
	errInvalidTokenOut         = "[GNOSWAP-ORDER-LIMIT-002] invalid token out"
	errSameToken               = "[GNOSWAP-ORDER-LIMIT-003] token in and token out must be different"
	errInvalidMakingAmount     = "[GNOSWAP-ORDER-LIMIT-004] invalid making amount (must be > 0)"
	errInvalidTakingAmount     = "[GNOSWAP-ORDER-LIMIT-005] invalid taking amount (must be > 0)"
	errInvalidSlippage         = "[GNOSWAP-ORDER-LIMIT-006] invalid slippage"
	errInvalidExpiresAt        = "[GNOSWAP-ORDER-LIMIT-007] invalid expiresAt (must be > 0)"
	errDeadlineTooShort        = "[GNOSWAP-ORDER-LIMIT-008] deadline too short"
	errDeadlineTooLong         = "[GNOSWAP-ORDER-LIMIT-009] deadline too long"
	errOrderNotFound           = "[GNOSWAP-ORDER-LIMIT-010] order not found"
	errOrderNotActive          = "[GNOSWAP-ORDER-LIMIT-011] order is not active"
	errOrderExpired            = "[GNOSWAP-ORDER-LIMIT-012] order has expired"
	errInsufficientOutput      = "[GNOSWAP-ORDER-LIMIT-013] insufficient output amount"
	errInvalidFillAmount       = "[GNOSWAP-ORDER-LIMIT-014] invalid fill amount"
	errAmountOverflow          = "[GNOSWAP-ORDER-LIMIT-015] amount exceeds int64"
	errSlippageExceeded        = "[GNOSWAP-ORDER-LIMIT-016] slippage exceeded, output less than minimum"
	errNotOrderOwner           = "[GNOSWAP-ORDER-LIMIT-017] unauthorized caller"
	errInvalidConfig           = "[GNOSWAP-ORDER-LIMIT-018] invalid config"
	errInvalidState            = "[GNOSWAP-ORDER-LIMIT-019] invalid accounting state"
	errInvalidExecutionFeeRate = "[GNOSWAP-ORDER-LIMIT-020] invalid execution fee rate"
	errNotKeeper               = "[GNOSWAP-ORDER-LIMIT-021] caller is not an authorized keeper"
	errHalted                  = "[GNOSWAP-ORDER-LIMIT-022] operation halted"
	errInvalidPriceLimit       = "[GNOSWAP-ORDER-LIMIT-023] invalid sqrt price limit"
	errInvalidCleanupOrderIDs  = "[GNOSWAP-ORDER-LIMIT-024] invalid cleanup order IDs"
	errPoolNotWhitelisted      = "[GNOSWAP-ORDER-LIMIT-025] pool is not whitelisted"
	errInvalidBaseToken        = "[GNOSWAP-ORDER-LIMIT-026] invalid base token"
)

func makeErrorWithDetails(message string, details string) error {
	return ufmt.Errorf("%s || %s", message, details)
}

// Pure-package errors have no realm codes. Translate them at the public boundary.
func realmError(err error) error {
	message := ""

	switch err {
	case plimit.ErrInvalidMakingAmount:
		message = errInvalidMakingAmount
	case plimit.ErrInvalidTakingAmount:
		message = errInvalidTakingAmount
	case plimit.ErrInvalidSlippage:
		message = errInvalidSlippage
	case plimit.ErrInvalidExpiresAt:
		message = errInvalidExpiresAt
	case plimit.ErrOrderNotActive:
		message = errOrderNotActive
	case plimit.ErrOrderExpired:
		message = errOrderExpired
	case plimit.ErrInsufficientOutput:
		message = errInsufficientOutput
	case plimit.ErrInvalidFillAmount:
		message = errInvalidFillAmount
	case plimit.ErrAmountOverflow:
		message = errAmountOverflow
	case plimit.ErrSlippageExceeded:
		message = errSlippageExceeded
	case plimit.ErrInvalidExecutionFeeRate:
		message = errInvalidExecutionFeeRate
	default:
		return err
	}

	return makeErrorWithDetails(message, err.Error())
}
