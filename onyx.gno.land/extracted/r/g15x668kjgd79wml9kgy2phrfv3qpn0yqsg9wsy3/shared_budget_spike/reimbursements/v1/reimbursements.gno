package reimbursements

import (
	"chain/runtime"
	"chain/runtime/unsafe"

	"gno.land/r/g15x668kjgd79wml9kgy2phrfv3qpn0yqsg9wsy3/shared_budget_spike/treasury/v1"
)

func Reserve(cur realm, sponsor address, itemID int, amount int64) int64 {
	runtime.AssertOriginCall()
	if !cur.IsCurrent() || !cur.Previous().IsUserCall() {
		panic("direct reimbursements operator call required")
	}
	if len(unsafe.OriginSend()) != 0 {
		panic("unexpected attached coins")
	}
	return treasury.Reserve(cross(cur), sponsor, cur.Previous().Address(), itemID, amount)
}
