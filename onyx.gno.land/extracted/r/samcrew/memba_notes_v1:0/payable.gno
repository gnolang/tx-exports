package memba_notes_v1

import "chain/runtime/unsafe"

// Inert activation uses the original package creator as OriginCaller, not the
// enabling approver. Runtime e75fef82c keeper_inert.go pins this behavior.
func init() { admin = unsafe.OriginCaller() }
func assertNoCoins() {
	if !unsafe.OriginSend().IsZero() {
		panic("notes: no coins")
	}
}
func assertCreatePayment(cur realm, maxFee int64) {
	if !cur.Previous().IsUserCall() {
		panic("notes: create directly from your account")
	}
	if maxFee < 0 || createFee > maxFee {
		panic("notes: fee exceeds maximum")
	}
	coins := unsafe.OriginSend()
	if createFee == 0 {
		if !coins.IsZero() {
			panic("notes: exact fee required")
		}
		return
	}
	if len(coins) != 1 || coins[0].Denom != "ugnot" || coins[0].Amount != createFee {
		panic("notes: exact fee required")
	}
}
