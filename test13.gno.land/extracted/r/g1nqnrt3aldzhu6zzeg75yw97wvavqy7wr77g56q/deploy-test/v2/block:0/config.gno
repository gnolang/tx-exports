package block

import (
	"chain"
	"strconv"

	"gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v2/accesscontrol"
	"gno.land/r/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v2/admin"
)

const (
	SetCreatorBPSEvent = "SetCreatorBPS"
	SetListLimitEvent  = "SetListLimit"
)

var (
	// creatorBPS is the basis points (1/10000) that goes to block creator on mint
	// Default: 4000 = 40%
	creatorBPS int = 4000
	listLimit  int = 100 // Max items per list query
)

// SetCreatorBPS sets the creator revenue share in basis points (admin only)
// BPS must be between 0 and 10000 (0% to 100%)
func SetCreatorBPS(cur realm, bps int) {
	assertNotFrozen()
	accesscontrol.AssertIsAdmin(0, cur, admin.IsAdmin)

	if bps < 0 || bps > 10000 {
		panic("creator bps must be between 0 and 10000")
	}

	oldBPS := creatorBPS
	creatorBPS = bps

	chain.Emit(
		SetCreatorBPSEvent,
		"oldBPS", strconv.Itoa(oldBPS),
		"newBPS", strconv.Itoa(bps),
	)
}

// GetCreatorBPS returns the current creator revenue share in basis points
func GetCreatorBPS() int {
	return creatorBPS
}

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
