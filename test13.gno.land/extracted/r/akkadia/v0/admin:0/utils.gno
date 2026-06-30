package admin

import (
	"strconv"

	"gno.land/p/akkadia/v0/accesscontrol"
)

func int64ToString(value int64) string {
	return strconv.FormatInt(value, 10)
}

func mustGetPendingAdminUserCaller(_ int, rlm realm) address {
	caller := accesscontrol.MustGetUserCaller(0, rlm)
	if caller != pendingAdmin {
		panic("pending admin access required")
	}
	return caller
}
