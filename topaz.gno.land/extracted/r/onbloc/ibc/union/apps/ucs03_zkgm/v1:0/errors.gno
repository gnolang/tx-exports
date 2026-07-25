package ucs03_zkgm

import (
	"errors"
	"strings"
)

// Error messages for the zkgm v1 impl, collected in one place so the wording
// stays consistent. They are string constants rather than package-level error

// values; build them with makeError at the call site (see above).
const (
	// opcode routing
	errUnsupportedOpcode = "unsupported opcode"

	// instruction decoding
	errUnsupportedTokenOrderVersion = "unsupported token order version"
	errUnsupportedCallVersion       = "unsupported call version"
	errUnsupportedBatchVersion      = "unsupported batch version"
	errUnsupportedForwardVersion    = "unsupported forward version"

	// token order
	errInvalidUnescrow                    = "invalid token order unescrow"
	errTokenOrderFeeUnderflow             = "token order fee underflow: quote amount exceeds base amount"
	errUnknownTokenOrderKind              = "unknown token order kind"
	errUnknownFillType                    = "unknown fill type"
	errUnsupportedTokenOrderKindForAck    = "unsupported token order kind for ack"
	errUnsupportedTokenOrderKindForRefund = "unsupported token order kind for refund"
	errSolveNotImplemented                = "solve token order not implemented"
	errInvalidTokenOrderDestChannel       = "invalid token order destination channel"
	errInvalidTokenOrderTransferAmount    = "invalid token order transfer amount"

	// errMetadataDecimalsMismatch guards an INITIALIZE order's declared
	// metadata decimals against the locally-known ground truth for its base
	// denom (a registered grc20's real decimals, or a held voucher's recorded
	// OriginDecimals when forwarding it onward). Left unchecked, the
	// counterparty (or next hop) would deploy/interpret the wrapped copy at
	// the wrong precision even though the raw amount moved correctly here.
	errMetadataDecimalsMismatch = "token order: metadata decimals do not match the local token"

	// call
	errEurekaUnsupported     = "eureka mode not supported"
	errInvalidCallSender     = "invalid call sender"
	errReceiverNotRegistered = "receiver not registered"
	errIsOnlyMakerAck        = "is only maker ack"

	// forward
	errInvalidForwardInstruction = "invalid forward instruction"
	errForwardMissingPrevDest    = "forward missing previous destination channel"
	errForwardMissingNextSource  = "forward missing next source channel"
	errForwardPrevDestMismatch   = "forward previous-destination mismatch"
	errForwardZeroTimeout        = "forward timeout timestamp must be non-zero"

	// batch
	errInvalidBatchInstruction = "invalid batch instruction"
	errBatchAckCountMismatch   = "batch ack count mismatch"

	// voucher
	errAmountOverflow                 = "amount overflows int64"
	errVoucherNotFound                = "voucher not found"
	errVoucherSymbolAlreadyRegistered = "voucher symbol already registered under a different denom"

	// rate limit
	errTokenBucketAbsent = "token bucket is absent"

	// coins / channel balance
	errCoinMismatch            = "zkgm/coins: sent coin mismatch"
	errChannelBalanceUnderflow = "zkgm/channel_balance: underflow"
	errChannelBalanceOverflow  = "zkgm/channel_balance: overflow"

	// ErrSpoofedRealm guards non-crossing (_ int, rlm realm, ...) entrypoints: the
	// passed rlm must be the current crossing frame, not a forged or stale token.
	errSpoofedRealm = "rlm does not match the current crossing frame"
)

func makeError(msgs ...string) error {
	return errors.New(strings.Join(msgs, ", "))
}
