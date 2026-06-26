package personal_world

import (
	"chain"
	"strconv"

	"gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/accesscontrol"
	"gno.land/r/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/admin"
)

const (
	SetFeeCollectorBPSEvent = "SetFeeCollectorBPS"
	SetListLimitEvent       = "SetListLimit"
	SetBatchLimitEvent      = "SetBatchLimit"

	maxFeeCollectorBPS    = int(10000)
	minPriceMultiplierBPS = int64(1000)
)

var (
	feeCollectorBPS          int = 500  // 5% (500 BPS)
	listLimit                int = 100  // Max items per list query
	batchLimit               int = 1000 // Max keys per batch query
	migrationMigratorPkgPath string
	migrationCompleted       bool
	migrationStateCleaned    bool
)

// SetFeeCollectorBPS sets the feeCollector basis points (admin only)
func SetFeeCollectorBPS(cur realm, bps int) {
	assertNotFrozen()
	accesscontrol.AssertIsAdmin(0, cur, admin.IsAdmin)
	if bps < 0 || bps > maxFeeCollectorBPS {
		panic("fee collector BPS must be between 0 and 10000")
	}

	oldBPS := feeCollectorBPS
	feeCollectorBPS = bps

	// Emit event
	chain.Emit(
		SetFeeCollectorBPSEvent,
		"oldBPS", strconv.Itoa(oldBPS),
		"newBPS", strconv.Itoa(bps),
	)
}

// GetFeeCollectorBPS returns the feeCollector BPS
func GetFeeCollectorBPS() int {
	return feeCollectorBPS
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

// SetBatchLimit sets the max keys per batch query (admin only)
func SetBatchLimit(cur realm, limit int) {
	assertNotFrozen()
	accesscontrol.AssertIsAdmin(0, cur, admin.IsAdmin)
	if limit < 1 {
		panic("limit must be at least 1")
	}

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
	return batchLimit
}
