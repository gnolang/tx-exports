package memba_arcade_leaderboard_v1

import "chain"

// Admin surface — owner-gated. The owner is the samcrew multisig at launch and can be handed to
// the memba_dao executor via the 2-step TransferOwnership/AcceptOwnership (never a 1-step transfer
// to a mistyped/dead address).

// AddAttester allowlists an ADDRESS (the backend verifier's dedicated low-privilege key — never the
// deploy multisig itself) as an authorized result source. Owner only.
func AddAttester(cur realm, addr address) {
	assertOwner(cur)
	if addr == "" {
		panic("attester address must be non-empty")
	}
	attesters.Set(addr.String(), true)
	chain.Emit("AttesterAdded", "addr", addr.String())
}

// RemoveAttester revokes an attester key. Owner only.
func RemoveAttester(cur realm, addr address) {
	assertOwner(cur)
	attesters.Remove(addr.String())
	chain.Emit("AttesterRemoved", "addr", addr.String())
}

// Pause freezes all attestation + receipt requests (reads stay available). Owner only.
func Pause(cur realm, state bool) {
	assertOwner(cur)
	paused = state
	chain.Emit("PauseSet", "paused", boolStr(state))
}

// TransferOwnership stages a new owner; it takes effect only after AcceptOwnership is called BY
// that address (2-step, so a typo can't brick admin).
func TransferOwnership(cur realm, newOwner address) {
	assertOwner(cur)
	if newOwner == "" {
		panic("newOwner must be non-empty")
	}
	pendingOwner = newOwner
	chain.Emit("OwnershipTransferStarted", "pending", newOwner.String())
}

// AcceptOwnership completes the handoff. Only the staged pendingOwner may call it.
func AcceptOwnership(cur realm) {
	if !cur.IsCurrent() {
		panic("spoofed realm")
	}
	if pendingOwner == "" {
		panic("no pending ownership transfer")
	}
	if cur.Previous().Address() != pendingOwner {
		panic("unauthorized: only the pending owner may accept")
	}
	owner = pendingOwner
	pendingOwner = ""
	chain.Emit("OwnershipTransferAccepted", "owner", owner.String())
}
