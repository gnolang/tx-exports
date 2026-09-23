package escrow_v3

// Admin authority and its rotation path.
//
// No admin is compiled in: `admin` below is seeded at package load from the
// publishing transaction's signer (on gnoland-1 the samcrew namespace
// multisig, the stamped creator at enable time). Every gate in this realm
// reads the mutable `admin`, so the address that holds admin can be changed
// after deployment.
//
// WHY THIS IS NOT OPTIONAL ON MAINNET. Realms are immutable once published and
// there is no faucet; mainnet genesis additionally locks ugnot transfers under
// Constitution §126. A compile-time admin therefore cannot be corrected after
// the fact. A compile-time testnet key would permanently disable Pause/Unpause
// and ResolveDispute, the only path that settles a disputed milestone,
// stranding custodied funds with nobody able to move them. Redeploying at a
// new path is not a recovery: it abandons the funds already held at this one.
//
// TWO-STEP BY DESIGN. The handoff stages a pending address that must claim it
// with its own transaction. A one-step setter would let admin be handed to an
// address that cannot act — a typo, or an unfunded address under §126 — with no
// way back, which is precisely the failure this file exists to prevent.
//
// CALLER AUTH: `cur.IsCurrent()` then `cur.Previous().Address()`, matching
// memba_arcade_leaderboard_v1 / memba_points_v1 and the project's contract-review
// checklist #9. This file deliberately imports none of the frame-unverified
// caller package that checklist flags — a new path should not inherit it.
//
// escrow.gno's older gates still read the frame-unverified caller and stay
// grandfathered in antipattern-prevrealm-baseline.txt. That is not a dangerous
// mix: for the direct multisig calls these entrypoints are for, both forms
// resolve to the same address, and `IsCurrent()` rejects the sibling/stale-`cur`
// cases where they could differ at all — so this file is strictly the tighter
// of the two.

import "chain"

var (
	// admin is the LIVE authority, seeded with the publisher at package load.
	// Initialized at declaration rather than in init() so there is no
	// init-ordering question about gates that read it.
	admin address = publisherAtLoad()

	// feeFallback receives the protocol fee only when memba_market_config
	// reports no treasury (see resolveFee). It is the publisher too, so a config
	// misread routes fees to the namespace multisig rather than to a testnet
	// key or to nobody.
	feeFallback address = publisherAtLoad()

	// pendingAdmin is the staged successor; "" when no handoff is in flight.
	pendingAdmin address
)

// TransferOwnership stages a handoff to newAdmin. Admin only. The transfer does
// not take effect until newAdmin calls AcceptOwnership, so admin is never moved
// to an address that has not demonstrated it can transact.
//
// Calling it again before acceptance replaces the staged address, which is how
// a mistyped proposal is corrected.
func TransferOwnership(cur realm, newAdmin address) {
	assertAdmin(cur)
	if newAdmin == "" {
		panic("newAdmin must be non-empty")
	}
	pendingAdmin = newAdmin
	chain.Emit("OwnershipTransferStarted", "pending", newAdmin.String())
}

// AcceptOwnership completes the handoff. Only the staged pendingAdmin may call
// it — including against the outgoing admin, so the two steps cannot be
// collapsed into one by the party giving up the role.
func AcceptOwnership(cur realm) {
	if !cur.IsCurrent() {
		panic("spoofed realm")
	}
	if pendingAdmin == "" {
		panic("no pending ownership transfer")
	}
	if cur.Previous().Address() != pendingAdmin {
		panic("unauthorized: only the pending admin may accept")
	}
	admin = pendingAdmin
	pendingAdmin = ""
	chain.Emit("OwnershipTransferAccepted", "admin", admin.String())
}

// CancelOwnershipTransfer clears a staged handoff. Admin only — the outgoing
// admin must be able to abort a proposal it no longer wants, without needing
// the proposed address to cooperate.
func CancelOwnershipTransfer(cur realm) {
	assertAdmin(cur)
	if pendingAdmin == "" {
		panic("no pending ownership transfer")
	}
	cancelled := pendingAdmin
	pendingAdmin = ""
	chain.Emit("OwnershipTransferCancelled", "cancelled", cancelled.String())
}

// GetAdmin returns the address that currently holds admin.
func GetAdmin() string { return admin.String() }

// GetPendingAdmin returns the staged successor ("" when none is in flight).
func GetPendingAdmin() string { return pendingAdmin.String() }

// assertAdmin is the authorization gate for this file's entrypoints. It rejects
// a stale/sibling `cur` first, then takes the caller from cur.Previous().
func assertAdmin(cur realm) {
	if !cur.IsCurrent() {
		panic("spoofed realm")
	}
	if cur.Previous().Address() != admin {
		panic("unauthorized: only admin may perform this action")
	}
}
