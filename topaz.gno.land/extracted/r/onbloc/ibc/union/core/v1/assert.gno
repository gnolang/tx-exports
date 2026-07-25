package core

import (
	core "gno.land/r/onbloc/ibc/union/core"
)

func assertIsRlmCurrent(_ int, rlm realm) {
	if !rlm.IsCurrent() {
		panic(errSpoofedRealm)
	}
}

func assertPacketDataSize(data []byte) {
	if !core.IsValidPacketDataSize(data) {
		panic(makeError(core.ErrPacketCombinedDataTooLarge))
	}
}
