package memba_appstore_v1

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
// is called BY that address (2-step, so a typo can't brick admin).
func TransferOwnership(cur realm, newOwner address) {
	assertOwner()
	if newOwner == "" {
		panic("newOwner must be non-empty")
	}
	pendingOwner = newOwner
	chain.Emit("OwnershipTransferStarted", "pending", newOwner.String())
}

// AcceptOwnership completes the handoff. Only the staged pendingOwner may call it.
func AcceptOwnership(cur realm) {
	if pendingOwner == "" {
		panic("no pending ownership transfer")
	}
	if caller() != pendingOwner {
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
