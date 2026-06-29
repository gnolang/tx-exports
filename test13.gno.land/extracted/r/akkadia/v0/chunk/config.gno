package chunk

import (
	"chain"
	"strconv"

	"gno.land/p/akkadia/v0/accesscontrol"
	"gno.land/r/akkadia/v0/admin"
)

const (
	SetListLimitEvent  = "SetListLimit"
	SetBatchLimitEvent = "SetBatchLimit"

	// Coord keys only use digits, '-', and '_', so '~' is a stable high bound.
	coordKeyUpperBound = "~"
)

var (
	listLimit  int = 100  // Max items per list query
	batchLimit int = 1000 // Max keys per batch query
	frozen     bool
)

// SetListLimit sets the max items per list query (admin only)
func SetListLimit(cur realm, limit int) {
	assertNotFrozen()
	accesscontrol.AssertIsAdmin(0, cur, admin.IsAdmin)
	assertPositiveLimit(limit)

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
	assertMigrationStateAvailable()
	return listLimit
}

// SetBatchLimit sets the max keys per batch query (admin only)
func SetBatchLimit(cur realm, limit int) {
	assertNotFrozen()
	accesscontrol.AssertIsAdmin(0, cur, admin.IsAdmin)
	assertPositiveLimit(limit)

	oldLimit := batchLimit
	batchLimit = limit

	chain.Emit(
		SetBatchLimitEvent,
		"oldLimit", strconv.Itoa(oldLimit),
		"newLimit", strconv.Itoa(limit),
	)
}

// GetBatchLimit returns the max keys per batch query
func GetBatchLimit() int {
	assertMigrationStateAvailable()
	return batchLimit
}
