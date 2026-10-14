package memba_notes_rc1

import (
	"chain"
	keys "gno.land/r/samcrew/enckeys_v1"
)

func administrator(who address) {
	if who != admin {
		panic("notes: admin required")
	}
}
func SetCreateFee(cur realm, fee int64) {
	who := enter(cur, false)
	defer leave()
	administrator(who)
	if fee < 0 || fee > 1000000 {
		panic("notes: fee out of range")
	}
	createFee = fee
}
func SetTreasury(cur realm, to address) {
	who := enter(cur, false)
	defer leave()
	administrator(who)
	to = keys.CanonicalAddress(to)
	if to == cur.Address() || to == chain.DeriveStorageDepositAddr(RealmPath) {
		panic("notes: locked treasury")
	}
	treasury = to
}
func Pause(cur realm, on bool) {
	who := enter(cur, false)
	defer leave()
	administrator(who)
	paused = on
}
func TransferAdmin(cur realm, to address) {
	who := enter(cur, false)
	defer leave()
	administrator(who)
	to = keys.CanonicalAddress(to)
	if to == govAddress {
		panic("notes: governance cannot accept realm administration")
	}
	pendingAdmin = to
}
func AcceptAdmin(cur realm) {
	who := enter(cur, false)
	defer leave()
	if who != pendingAdmin || pendingAdmin == "" {
		panic("notes: pending admin required")
	}
	admin = who
	pendingAdmin = ""
}

// GetAdmin supplies the closed authority readback used by deployment rehearsal.
func GetAdmin() address { return admin }
