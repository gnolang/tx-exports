package admin

import (
	"chain"
	"chain/runtime/unsafe"

	"gno.land/p/akkadia/v0/accesscontrol"
)

const (
	SetProtocolEvent = "SetProtocol"
)

var (
	protocolAddr address
)

func init() {
	caller := unsafe.OriginCaller()
	protocolAddr = caller
}

func GetProtocol() address {
	return protocolAddr
}

func SetProtocol(cur realm, addr address) {
	assertNotFrozen()
	accesscontrol.AssertIsAdmin(0, cur, IsAdmin)

	assertValidAddress(addr)
	oldAddr := protocolAddr
	protocolAddr = addr

	chain.Emit(
		SetProtocolEvent,
		"oldAddr", oldAddr.String(),
		"newAddr", addr.String(),
	)
}

func IsProtocol(address address) bool {
	return address == protocolAddr
}
