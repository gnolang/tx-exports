package rooms

import "chain"

// The admin can pause new activity, set the fee for rooms opened later (at
// most MaxFeeBps), move the treasury, and verify assets, each verification
// counting only VerifyDelay later. A pause stops Open, Join, deposits, Lock,
// Offer and Fill; it never stops Withdraw, Unlock or Cancel, so deposits
// can always leave. The admin has no way to move anyone's assets.

var (
	admin        address // set to the deployer in init
	pendingAdmin address
	paused       bool
)

// SetPaused stops or resumes new activity.
func SetPaused(cur realm, value bool) {
	assertAdmin(cur)
	paused = value
	state := "resumed"
	if value {
		state = "paused"
	}
	chain.Emit("Paused", "state", state)
}

// ProposeAdmin names the next admin; the change happens when that address
// calls AcceptAdmin. Pass "" to withdraw a proposal.
func ProposeAdmin(cur realm, next string) {
	assertAdmin(cur)
	if next == "" {
		pendingAdmin = ""
		return
	}
	addr := address(next)
	if !addr.IsValid() {
		panic("next admin is not a valid address")
	}
	pendingAdmin = addr
	chain.Emit("AdminProposed", "next", addr.String())
}

// AcceptAdmin completes a handover started with ProposeAdmin.
func AcceptAdmin(cur realm) {
	who := callerOf(cur)
	if pendingAdmin == "" || who != pendingAdmin {
		panic("you are not the proposed admin")
	}
	admin = who
	pendingAdmin = ""
	chain.Emit("AdminChanged", "admin", who.String())
}

// IsPaused reports whether new activity is stopped.
func IsPaused() bool {
	return paused
}

// Admin returns the current admin address, or "" when there is none.
func Admin() string {
	return admin.String()
}

func assertAdmin(cur realm) {
	who := callerOf(cur)
	refuseCoins(cur)
	if admin == "" || who != admin {
		panic("admin only")
	}
}

func assertNotPaused() {
	if paused {
		panic("trade rooms are paused: you can still withdraw, unlock and cancel")
	}
}
