package ucs03_zkgm

import (
	"errors"
	"strings"
)

// Error messages, built via makeError at the call site.
const (
	errChannelBalanceUnderflow = "zkgm/channel_balance: underflow"

	errRecoveryUnsupportedTokenType = "zkgm/recovery: only native coin or ibc voucher escrow is supported"
	errRecoveryUnrecognizedKind     = "zkgm/recovery: only ESCROW-kind orders are supported"
	errInvalidRecipient             = "zkgm/recovery: recipient is not a valid address"
	errRecoveryZeroAmount           = "zkgm/recovery: amount must be positive"
	errBaseTokenRequired            = "zkgm/recovery: base token is required"
	errQuoteTokenRequired           = "zkgm/recovery: quote token is required"
	errVoucherNotFound              = "voucher not found"

	// errSpoofedRealm: rlm must be the current crossing frame, not a forged/stale token.
	errSpoofedRealm = "rlm does not match the current crossing frame"
)

func makeError(msgs ...string) error {
	return errors.New(strings.Join(msgs, ", "))
}
