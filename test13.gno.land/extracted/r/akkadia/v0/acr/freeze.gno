package acr

import (
	"gno.land/p/akkadia/v0/accesscontrol"
	"gno.land/r/akkadia/v0/admin"
)

var frozen bool

func Freeze(cur realm) {
	accesscontrol.AssertIsAdmin(0, cur, admin.IsAdmin)
	assertMigrationStateAvailable()
	frozen = true
}

func Unfreeze(cur realm) {
	accesscontrol.AssertIsAdmin(0, cur, admin.IsAdmin)
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
