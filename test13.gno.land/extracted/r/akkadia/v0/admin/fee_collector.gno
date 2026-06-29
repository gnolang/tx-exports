package admin

import (
	"chain"

	"gno.land/p/akkadia/v0/accesscontrol"
)

const (
	SetFeeCollectorEvent = "SetFeeCollector"
)

var (
	feeCollectorAddr address
)

func init() {
	feeCollectorAddr = chain.PackageAddress("gno.land/r/akkadia/v0/admin")
}

func GetFeeCollector() address {
	return feeCollectorAddr
}

func SetFeeCollector(cur realm, addr address) {
	assertNotFrozen()
	accesscontrol.AssertIsAdmin(0, cur, IsAdmin)

	assertValidAddress(addr)
	oldAddr := feeCollectorAddr
	feeCollectorAddr = addr

	chain.Emit(
		SetFeeCollectorEvent,
		"oldAddr", oldAddr.String(),
		"newAddr", addr.String(),
	)
}

func IsFeeCollector(address address) bool {
	return address == feeCollectorAddr
}
