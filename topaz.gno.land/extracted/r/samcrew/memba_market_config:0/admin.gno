// Admin operations — DAO-gated, with a 2-step admin handoff and a hard fee ceiling.
// There is intentionally NO Pause() here (see config.gno SAFETY note): pausing the
// fee spine would brick every engine at once. Per-engine Pause() is the kill switch.
package memba_market_config

import (
	"strconv"

	"chain"
)

func itoa(n int64) string { return strconv.FormatInt(n, 10) }

func assertAdmin() {
	if caller() != admin {
		panic("admin only")
	}
}

// SetFeeBPS sets a lane's protocol fee in basis points, clamped to [0, MaxFeeBPS].
// A value above the 5% ceiling is rejected so a misconfiguration can never overcharge.
func SetFeeBPS(cur realm, lane string, bps int64) {
	assertAdmin()
	if lane == "" {
		panic("empty lane")
	}
	if bps < 0 || bps > MaxFeeBPS {
		panic("feeBPS out of range")
	}
	feeByLane.Set(lane, bps)
	chain.Emit("FeeBPSChanged", "lane", lane, "bps", itoa(bps))
}

// SetTreasury repoints where every lane's protocol fee flows.
func SetTreasury(cur realm, addr address) {
	assertAdmin()
	if addr == "" {
		panic("empty treasury")
	}
	treasury = addr
	chain.Emit("TreasuryChanged", "treasury", addr.String())
}

// TransferAdmin proposes a new admin (the memba_dao executor). The 2-step handoff
// requires the new admin to AcceptAdmin, so a transfer to a wrong or uncontrolled
// address cannot lock the realm.
func TransferAdmin(cur realm, newAdmin address) {
	assertAdmin()
	if newAdmin == "" {
		panic("empty admin")
	}
	pendingAdmin = newAdmin
	chain.Emit("AdminTransferProposed", "pending", newAdmin.String())
}

// AcceptAdmin completes the handoff. Only the pending admin can call it.
func AcceptAdmin(cur realm) {
	if caller() != pendingAdmin {
		panic("not pending admin")
	}
	admin = pendingAdmin
	pendingAdmin = ""
	chain.Emit("AdminAccepted", "admin", admin.String())
}
