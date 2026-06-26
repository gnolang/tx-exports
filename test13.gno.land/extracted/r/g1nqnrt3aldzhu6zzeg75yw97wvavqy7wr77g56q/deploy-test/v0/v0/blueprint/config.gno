package blueprint

import (
	"chain"
	"strconv"

	"gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/accesscontrol"
	"gno.land/r/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/admin"
)

const SetCreationCostEvent = "SetCreationCost"

var (
	creationCost int64 = 0
	listLimit    int   = 100
	batchLimit   int   = 1000
)

func SetCreationCost(cur realm, nextCreationCost int64) {
	assertNotFrozen()
	accesscontrol.AssertIsAdmin(0, cur, admin.IsAdmin)
	assertCreationCost(nextCreationCost)

	oldCreationCost := creationCost
	creationCost = nextCreationCost

	chain.Emit(
		SetCreationCostEvent,
		"oldCreationCost", strconv.FormatInt(oldCreationCost, 10),
		"newCreationCost", strconv.FormatInt(creationCost, 10),
	)
}

func GetCreationCost() int64 {
	assertMigrationStateAvailable()
	return creationCost
}

func GetListLimit() int {
	assertMigrationStateAvailable()
	return listLimit
}

func GetBatchLimit() int {
	assertMigrationStateAvailable()
	return batchLimit
}
