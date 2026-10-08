package memba_quest_attestation_v1

// Owner authority and its rotation path.
//
// No owner is compiled in: `owner` is seeded at package load from the
// publishing transaction's signer (on gnoland-1 the samcrew namespace multisig,
// the stamped creator at enable time), and SetSigner reads the mutable `owner`,
// so the address holding ownership can be changed after deployment.
//
// WHY THIS MATTERS ON MAINNET, specifically here. SetSigner is the ONLY
// owner-gated entrypoint, and it installs/rotates the backend's offline signer
// public key — the key every voucher is verified against. Realms are immutable,
// there is no faucet, and mainnet genesis locks ugnot transfers under
// Constitution §126, so a compile-time owner cannot be corrected later, and a
// compile-time testnet owner would freeze the signer at whatever value it last
// held: a compromised backend signer could never be rotated out, and quest
// attestation would have to be abandoned rather than repaired.
//
// TWO-STEP BY DESIGN: the successor must claim the role with its own
// transaction, so ownership can never be handed to an address that cannot
// transact (a typo, or an unfunded address under §126) with no way back.
//
// All owner mutations require a current realm frame and authenticate the
// immediate caller through cur.Previous(), including signer rotation.

import "chain"

var (
	// owner is the LIVE authority, seeded with the publisher at package load.
	// Initialized at declaration so there is no init-ordering question about
	// gates that read it.
	owner address = publisherAtLoad()

	// pendingOwner is the staged successor; "" when none is in flight.
	pendingOwner address
)

// TransferOwnership stages a handoff. Owner only; it takes effect only once
// newOwner calls AcceptOwnership. Calling it again before acceptance replaces
// the staged address, which is how a mistyped proposal is corrected.
func TransferOwnership(cur realm, newOwner address) {
	assertOwner(cur)
	if newOwner == "" {
		panic("newOwner must be non-empty")
	}
	pendingOwner = newOwner
	chain.Emit("OwnershipTransferStarted", "pending", newOwner.String())
}

// AcceptOwnership completes the handoff. Only the staged pendingOwner may call
// it — including against the outgoing owner, so the two steps cannot be
// collapsed into one by the party giving up the role.
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

// CancelOwnershipTransfer clears a staged handoff. Owner only, so a proposal
// can be aborted without the proposed address cooperating.
func CancelOwnershipTransfer(cur realm) {
	assertOwner(cur)
	if pendingOwner == "" {
		panic("no pending ownership transfer")
	}
	cancelled := pendingOwner
	pendingOwner = ""
	chain.Emit("OwnershipTransferCancelled", "cancelled", cancelled.String())
}

// GetOwner returns the address that currently holds ownership.
func GetOwner() string { return owner.String() }

// GetPendingOwner returns the staged successor ("" when none).
func GetPendingOwner() string { return pendingOwner.String() }

// assertOwner is the gate for this file's entrypoints. It rejects a
// stale/sibling `cur` first, then takes the caller from cur.Previous().
func assertOwner(cur realm) {
	if !cur.IsCurrent() {
		panic("spoofed realm")
	}
	if cur.Previous().Address() != owner {
		panic("unauthorized: owner multisig only")
	}
}
