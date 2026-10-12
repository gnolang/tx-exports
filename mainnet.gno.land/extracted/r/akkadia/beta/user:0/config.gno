package user

import (
	"chain"
	"strconv"

	"gno.land/p/akkadia/beta/accesscontrol"
	"gno.land/r/akkadia/beta/admin"
)

const (
	SetListLimitEvent = "SetListLimit"
	SetFrozenEvent    = "SetFrozen"
)

var (
	listLimit int = 100 // Max items per list query
	isFrozen      = true
)

func SetListLimit(cur realm, limit int) {
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

func GetListLimit() int {
	return listLimit
}

// SetFrozen controls direct user creation and deletion only.
func SetFrozen(cur realm, frozen bool) {
	accesscontrol.AssertIsAdmin(0, cur, admin.IsAdmin)
	oldFrozen := isFrozen
	isFrozen = frozen
	chain.Emit(
		SetFrozenEvent,
		"oldFrozen", strconv.FormatBool(oldFrozen),
		"newFrozen", strconv.FormatBool(frozen),
	)
}
