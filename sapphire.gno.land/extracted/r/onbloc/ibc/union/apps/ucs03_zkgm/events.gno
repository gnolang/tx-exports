package ucs03_zkgm

import (
	"chain"
	"strconv"
	"strings"

	types "gno.land/p/onbloc/ibc/union/types"

	u256 "gno.land/p/onbloc/math/uint256"
)

const (
	ZkgmImplUpdatedEvent               = "ZkgmImplUpdated"
	ZkgmPausedEvent                    = "ZkgmPaused"
	ZkgmUnpausedEvent                  = "ZkgmUnpaused"
	ZkgmRateLimitBucketConfiguredEvent = "ZkgmRateLimitBucketConfigured"
	ZkgmRateLimitDisabledSetEvent      = "ZkgmRateLimitDisabledSet"
	ZkgmReceiverRegisteredEvent        = "ZkgmReceiverRegistered"
	ZkgmNativeReleasedEvent            = "ZkgmNativeReleased"
	ZkgmForwardInFlightSetEvent        = "ZkgmForwardInFlightSet"
	ZkgmForwardInFlightPoppedEvent     = "ZkgmForwardInFlightPopped"
	ZkgmRecvErrorEvent                 = "ZkgmRecvError"
)

func emitZkgmImplUpdatedEvent(callerPkgPath string, oldImplPath string, newImplPath string, allowed []string) {
	chain.Emit(
		ZkgmImplUpdatedEvent,
		"caller_pkg_path", callerPkgPath,
		"old_impl_path", oldImplPath,
		"new_impl_path", newImplPath,
		"allowed_impls", strings.Join(allowed, ","),
	)
}

func emitZkgmPausedEvent(admin address) {
	chain.Emit(
		ZkgmPausedEvent,
		"admin", admin.String(),
	)
}

func emitZkgmUnpausedEvent(admin address) {
	chain.Emit(
		ZkgmUnpausedEvent,
		"admin", admin.String(),
	)
}

func emitZkgmRateLimitBucketConfiguredEvent(admin address, denom string, capacity *u256.Uint, refillRate *u256.Uint) {
	chain.Emit(
		ZkgmRateLimitBucketConfiguredEvent,
		"admin", admin.String(),
		"denom", denom,
		"capacity", capacity.ToString(),
		"refill_rate", refillRate.ToString(),
	)
}

func emitZkgmRateLimitDisabledSetEvent(admin address, disabled bool) {
	chain.Emit(
		ZkgmRateLimitDisabledSetEvent,
		"admin", admin.String(),
		"disabled", strconv.FormatBool(disabled),
	)
}

func emitZkgmReceiverRegisteredEvent(receiverPkgPath string) {
	chain.Emit(
		ZkgmReceiverRegisteredEvent,
		"receiver_pkg_path", receiverPkgPath,
	)
}

func emitZkgmNativeReleasedEvent(callerPkgPath string, denom string, recipient address, amount int64) {
	chain.Emit(
		ZkgmNativeReleasedEvent,
		"caller_pkg_path", callerPkgPath,
		"denom", denom,
		"recipient", recipient.String(),
		"amount", strconv.FormatInt(amount, 10),
	)
}

func emitZkgmForwardInFlightSetEvent(packetHash types.H256, parentPacketHash types.H256) {
	chain.Emit(
		ZkgmForwardInFlightSetEvent,
		"packet_hash", packetHash.String(),
		"parent_packet_hash", parentPacketHash.String(),
	)
}

func emitZkgmForwardInFlightPoppedEvent(packetHash types.H256, found bool) {
	chain.Emit(
		ZkgmForwardInFlightPoppedEvent,
		"packet_hash", packetHash.String(),
		"found", strconv.FormatBool(found),
	)
}

func emitRecvError(sourceChannel types.ChannelId, destinationChannel types.ChannelId, reason string) {
	chain.Emit(
		ZkgmRecvErrorEvent,
		"source_channel", sourceChannel.String(),
		"destination_channel", destinationChannel.String(),
		"reason", reason,
	)
}
