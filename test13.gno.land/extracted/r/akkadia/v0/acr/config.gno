package acr

import (
	"chain"
	"strconv"

	"gno.land/p/akkadia/v0/accesscontrol"
	"gno.land/r/akkadia/v0/admin"
)

const (
	SetListLimitEvent = "SetListLimit"
)

var (
	listLimit int = 100 // Max items per list query
)

// SetListLimit sets the max items per list query (admin only)
func SetListLimit(cur realm, limit int) {
	assertNotFrozen()
	caller := accesscontrol.MustGetAdminCaller(0, cur, admin.IsAdmin)
	if limit < 1 {
		panic("limit must be at least 1")
	}

	oldLimit := listLimit
	listLimit = limit

	chain.Emit(
		SetListLimitEvent,
		"admin", caller.String(),
		"oldLimit", strconv.Itoa(oldLimit),
		"newLimit", strconv.Itoa(limit),
	)
}

// GetListLimit returns the max items per list query
func GetListLimit() int {
	return listLimit
}

func pageOffset(page int, count int) int {
	return (page - 1) * count
}
