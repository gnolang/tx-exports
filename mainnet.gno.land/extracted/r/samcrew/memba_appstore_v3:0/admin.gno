package memba_appstore_v3

import "chain"

// Admin surface — owner-gated. The owner is the samcrew multisig at launch and can
// be handed to the memba_dao executor via the 2-step TransferOwnership/AcceptOwnership
// (never a 1-step transfer to a mistyped/dead address).

// SetRegistrationFee sets the flat listing fee in ugnot (0..MaxRegistrationFee).
// Zero is allowed (a fee waiver). Owner only.
func SetRegistrationFee(cur realm, fee int64) {
	assertOwner()
	if fee < 0 || fee > MaxRegistrationFee {
		panic("fee out of range [0, MaxRegistrationFee]")
	}
	registrationFee = fee
	chain.Emit("RegistrationFeeSet", "fee", itoa64(uint64(fee)))
}

// SetTreasury repoints the fee recipient. Must be non-empty (an empty treasury would
// fail-close RegisterApp). Owner only. Keep this in sync with
// memba_market_config.GetTreasury().
func SetTreasury(cur realm, addr address) {
	assertOwner()
	if addr == "" {
		panic("treasury must be non-empty")
	}
	treasury = addr
	chain.Emit("TreasurySet", "treasury", addr.String())
}

// AddCurator grants the curate role (approve pending listings). Owner only.
func AddCurator(cur realm, addr address) {
	assertOwner()
	if addr == "" {
		panic("curator must be non-empty")
	}
	curators.Set(addr.String(), true)
	chain.Emit("CuratorAdded", "curator", addr.String())
}

// RemoveCurator revokes the curate role. Owner only.
func RemoveCurator(cur realm, addr address) {
	assertOwner()
	curators.Remove(addr.String())
	chain.Emit("CuratorRemoved", "curator", addr.String())
}

// Pause is the kill switch: while paused, RegisterApp aborts (reads stay available).
// Owner only.
func Pause(cur realm, state bool) {
	assertOwner()
	paused = state
	chain.Emit("PauseSet", "paused", boolStr(state))
}

// TransferOwnership stages a new owner; it takes effect only after AcceptOwnership
// is called BY that address (2-step, so a typo can't brick admin). A later call
// replaces the staged address; CancelOwnershipTransfer withdraws it.
func TransferOwnership(cur realm, newOwner address) {
	assertOwner()
	if newOwner == "" {
		panic("newOwner must be non-empty")
	}
	if !newOwner.IsValid() {
		panic("invalid address: " + newOwner.String())
	}
	if newOwner == owner {
		panic("newOwner is the current owner")
	}
	pendingOwner = newOwner
	chain.Emit("OwnershipTransferStarted", "pending", newOwner.String())
}

// CancelOwnershipTransfer withdraws a staged handoff. Owner only.
func CancelOwnershipTransfer(cur realm) {
	assertOwner()
	if pendingOwner == "" {
		panic("no pending ownership transfer")
	}
	cancelled := pendingOwner
	pendingOwner = ""
	chain.Emit("OwnershipTransferCancelled", "pending", cancelled.String())
}

// GetPendingOwner returns the staged successor, or the empty address.
func GetPendingOwner() address { return pendingOwner }

// AcceptOwnership completes the handoff. Only the staged pendingOwner may call it.
// The former owner's curator grant is revoked atomically; the successor can
// curate immediately and may explicitly re-appoint the former owner later.
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
	previous := owner
	curators.Set(pendingOwner.String(), true)
	curators.Remove(previous.String())
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
