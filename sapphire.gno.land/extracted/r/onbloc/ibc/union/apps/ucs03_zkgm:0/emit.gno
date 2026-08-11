package ucs03_zkgm

import (
	"gno.land/p/onbloc/ibc/union/types"
)

func EmitRecvError(_ int, rlm realm, sourceChannel types.ChannelId, destinationChannel types.ChannelId, reason string) {
	assertIsRlmCurrent(0, rlm)
	assertIsProxyRealm(0, rlm)
	emitRecvError(sourceChannel, destinationChannel, reason)
}

func EmitNativeReleased(_ int, rlm realm, denom string, recipient address, amount int64) {
	assertIsRlmCurrent(0, rlm)
	if rlm.PkgPath() != proxyPkgPath {
		return
	}
	emitZkgmNativeReleasedEvent(rlm.Previous().PkgPath(), denom, recipient, amount)
}

func EmitForwardInFlightSet(_ int, rlm realm, packetHash types.H256, parentPacketHash types.H256) {
	assertIsRlmCurrent(0, rlm)
	if rlm.PkgPath() != proxyPkgPath {
		return
	}
	emitZkgmForwardInFlightSetEvent(packetHash, parentPacketHash)
}

func EmitForwardInFlightPopped(_ int, rlm realm, packetHash types.H256, found bool) {
	assertIsRlmCurrent(0, rlm)
	if rlm.PkgPath() != proxyPkgPath {
		return
	}
	emitZkgmForwardInFlightPoppedEvent(packetHash, found)
}
