package user

import (
	"chain"
	"strconv"

	"gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/accesscontrol"
	"gno.land/r/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/admin"
)

const (
	SetListLimitEvent = "SetListLimit"
)

var (
	listLimit                int = 100 // Max items per list query
	migrationMigratorPkgPath string
	migrationCompleted       bool
	migrationStateCleaned    bool
)

// SetListLimit sets the max items per list query (admin only)
func SetListLimit(cur realm, limit int) {
	assertNotFrozen()
	accesscontrol.AssertIsAdmin(0, cur, admin.IsAdmin)
	if limit < 1 {
		panic("limit must be at least 1")
	}

	oldLimit := listLimit
	listLimit = limit

	chain.Emit(
		SetListLimitEvent,
		"oldLimit", strconv.Itoa(oldLimit),
		"newLimit", strconv.Itoa(limit),
	)
}

// GetListLimit returns the max items per list query
func GetListLimit() int {
	return listLimit
}
