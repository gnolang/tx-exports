package memba_reviews_v2

// Moderator authority and its rotation path.
//
// No moderator is compiled in: `moderator` below is seeded at package load from
// the publishing transaction's signer (on gnoland-1 the samcrew namespace
// multisig, the stamped creator at enable time), and assertModerator reads the
// mutable `moderator`, so the address holding moderation can be changed after
// deployment.
//
// WHY THIS MATTERS ON MAINNET. Realms are immutable once published, there is no
// faucet, and mainnet genesis locks ugnot transfers under Constitution §126 — so
// a compile-time moderator cannot be corrected after the fact: a testnet key
// compiled in would permanently disable HideTarget/UnhideTarget/ClearFlags,
// leaving this realm with no way to act on a flagged review ever again.
//
// TWO-STEP BY DESIGN: the successor must claim the role with its own transaction,
// so moderation can never be handed to an address that cannot transact (a typo,
// or an unfunded address under §126) with no way back.
//
// CALLER AUTH here uses `cur.IsCurrent()` + `cur.Previous().Address()`, per
// contract-review checklist #9, matching memba_arcade_leaderboard_v1 /
// memba_points_v1. The realm's existing assertModerator keeps its older
// frame-unverified caller read (grandfathered in
// antipattern-prevrealm-baseline.txt); only the value it compares against
// changed, which is the smallest edit that removes the immutability.

import "chain"

var (
	// moderator is the LIVE authority, seeded with the publisher at package load.
	// Initialized at declaration so there is no init-ordering question about
	// gates that read it.
	moderator address = publisherAtLoad()

	// pendingModerator is the staged successor; "" when none is in flight.
	pendingModerator address
)

// TransferOwnership stages a handoff of the moderator role. Moderator only; it
// takes effect only once newModerator calls AcceptOwnership. Calling it again
// before acceptance replaces the staged address, which is how a mistyped
// proposal is corrected.
func TransferOwnership(cur realm, newModerator address) {
	assertModeratorCur(cur)
	if newModerator == "" {
		panic("newModerator must be non-empty")
	}
	if !newModerator.IsValid() {
		panic("invalid address: " + newModerator.String())
	}
	if newModerator == moderator {
		panic("newModerator is the current moderator")
	}
	pendingModerator = newModerator
	chain.Emit("OwnershipTransferStarted", "pending", newModerator.String())
}

// AcceptOwnership completes the handoff. Only the staged pendingModerator may
// call it — including against the outgoing moderator, so the two steps cannot be
// collapsed into one by the party giving up the role.
func AcceptOwnership(cur realm) {
	if !cur.IsCurrent() {
		panic("spoofed realm")
	}
	if pendingModerator == "" {
		panic("no pending ownership transfer")
	}
	if cur.Previous().Address() != pendingModerator {
		panic("unauthorized: only the pending moderator may accept")
	}
	moderator = pendingModerator
	pendingModerator = ""
	chain.Emit("OwnershipTransferAccepted", "moderator", moderator.String())
}

// CancelOwnershipTransfer clears a staged handoff. Moderator only, so a
// proposal can be aborted without the proposed address cooperating.
func CancelOwnershipTransfer(cur realm) {
	assertModeratorCur(cur)
	if pendingModerator == "" {
		panic("no pending ownership transfer")
	}
	cancelled := pendingModerator
	pendingModerator = ""
	chain.Emit("OwnershipTransferCancelled", "cancelled", cancelled.String())
}

// GetModerator returns the address that currently holds moderation.
func GetModerator() string { return moderator.String() }

// GetPendingModerator returns the staged successor ("" when none).
func GetPendingModerator() string { return pendingModerator.String() }

// assertModeratorCur is the gate for this file's entrypoints. Named apart from
// the realm's existing assertModerator so the older call sites keep their
// signature and semantics untouched.
func assertModeratorCur(cur realm) {
	if !cur.IsCurrent() {
		panic("spoofed realm")
	}
	if cur.Previous().Address() != moderator {
		panic("unauthorized: moderator multisig only")
	}
}
