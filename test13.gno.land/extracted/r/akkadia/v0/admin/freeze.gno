package admin

import "gno.land/p/akkadia/v0/accesscontrol"

var frozen bool

func Freeze(cur realm) {
	accesscontrol.AssertIsAdmin(0, cur, IsAdmin)
	assertMigrationStateAvailable()
	frozen = true
}

func Unfreeze(cur realm) {
	accesscontrol.AssertIsAdmin(0, cur, IsAdmin)
	assertMigrationStateAvailable()
	frozen = false
}

func IsFrozen() bool {
	return frozen
}

func assertNotFrozen() {
	assertMigrationStateAvailable()
	if frozen {
		panic("contract is frozen")
	}
}
