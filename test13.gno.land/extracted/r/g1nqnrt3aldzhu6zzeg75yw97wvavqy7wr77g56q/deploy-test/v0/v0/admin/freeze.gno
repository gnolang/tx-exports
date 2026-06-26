package admin

import "gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/accesscontrol"

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
