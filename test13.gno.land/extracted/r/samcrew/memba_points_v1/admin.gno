package memba_points_v1

import "chain"

// Admin surface — owner-gated. The owner is the samcrew multisig at launch and can be handed to
// the memba_dao executor via the 2-step TransferOwnership/AcceptOwnership (never a 1-step transfer
// to a mistyped/dead address).

// AddAwarder whitelists a realm pkgpath as an authorized points source (it may call Award/Revoke).
// Owner only. An awarder is another realm whose OWN verified flow decides who earns; this realm
// only trusts that the source is on the list.
func AddAwarder(cur realm, pkgpath string) {
	assertOwner(cur)
	if pkgpath == "" {
		panic("awarder pkgpath must be non-empty")
	}
	awarders.Set(pkgpath, true)
	chain.Emit("AwarderAdded", "pkgpath", pkgpath)
}

// RemoveAwarder revokes an awarder realm's authority. Owner only.
func RemoveAwarder(cur realm, pkgpath string) {
	assertOwner(cur)
	awarders.Remove(pkgpath)
	chain.Emit("AwarderRemoved", "pkgpath", pkgpath)
}

// Pause freezes Award/Revoke (reads stay available). Owner only.
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

func boolStr(b bool) string {
	if b {
		return "true"
	}
	return "false"
}
