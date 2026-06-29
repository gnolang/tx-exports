package admin

import (
	"chain"

	"gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v2/accesscontrol"
)

const (
	SetFeeCollectorEvent = "SetFeeCollector"
)

var (
	feeCollectorAddr address
)

func init() {
	feeCollectorAddr = chain.PackageAddress("gno.land/r/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v2/admin")
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
