package core

import (
	"errors"
	"strings"
)

// Error messages are defined as constants rather than package-level error
// values; build them with makeError at the call site (see above).
const (
	ErrClientNotActive               = "client is not active"
	ErrInvalidConnectionState        = "invalid connection state"
	ErrInvalidCounterpartyConnection = "invalid counterparty connection id"
	ErrInvalidChannelState           = "invalid channel state"
	ErrInvalidCounterpartyChannelId  = "invalid counterparty channel id"
	ErrSyncAckEmpty                  = "sync ack cannot be empty"
	ErrUnknownPacketStatus           = "unknown packet status"
	ErrUnauthorizedAckWriter         = "caller not authorized to write ack"
	ErrAcknowledgementAlreadyWritten = "acknowledgement already written"
	ErrAcknowledgementEmpty          = "acknowledgement cannot be empty"
	ErrAcknowledgementMismatch       = "acknowledgement mismatch"
	ErrUnauthorizedPacketSender      = "caller not authorized to send packet"
	ErrTimeoutMustBeSet              = "timeout must be set"
	ErrPacketCommitmentAlreadyExists = "packet commitment already exists"
	ErrPacketCommitmentNotFound      = "packet commitment not found"
	ErrPacketCombinedDataTooLarge    = "packet combined data too large"
	ErrPacketAlreadyAcknowledged     = "packet already acknowledged"
	ErrPacketReceiptNotFound         = "packet receipt not found"
	ErrNotEnoughPackets              = "not enough packets"
	ErrBatchSameChannelOnly          = "batch must use the same channel"
	ErrAcknowledgementCountMismatch  = "acknowledgement count mismatch"
	ErrTimeoutProofTimestampNotFound = "packet timeout proof timestamp not found"
	ErrPortAlreadyRegistered         = "port already registered"
	ErrBatchPacketsNotFound          = "batch packets not found"
	ErrBatchReceiptsNotFound         = "batch receipts not found"
	ErrPacketAlreadyReceived         = "packet already received"
	ErrPacketTimeoutExpired          = "packet timeout expired"
	ErrPacketTimeoutNotReached       = "packet timeout not reached"
	ErrIntentNotSupported            = "intent receive not supported"

	// Value-carrying "not found" base messages. The missing id/port is appended
	// as a second makeError argument at the call site, e.g.
	// makeError(ErrChannelNotFound, id.String()).
	ErrPortNotFound = "port not found"

	// Query getters return these when the requested state is missing. Getters
	// return an error rather than panicking so callers can decide how to handle
	// a missing lookup.
	ErrClientNotFound          = "client not found"
	ErrClientStateNotFound     = "client state not found"
	ErrConsensusStateNotFound  = "consensus state not found"
	ErrConnectionNotFound      = "connection not found"
	ErrChannelNotFound         = "channel not found"
	ErrMembershipProofNotFound = "membership proof not found"

	// ErrSpoofedRealm guards non-crossing (_ int, rlm realm, ...) entrypoints:
	// the passed rlm must be the current crossing frame, not a forged or stale
	// token replayed by a caller.
	ErrSpoofedRealm  = "rlm does not match the current crossing frame"
	ErrNotProxyRealm = "rlm is not proxy realm"
)

func makeError(msgs ...string) error {
	return errors.New(strings.Join(msgs, ", "))
}
