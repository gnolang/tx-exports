package memba_nft_market_v3_2

// Admin operations — multisig-gated controls.
//
// assertAdmin() is the single authorization gate; caller = unsafe.PreviousRealm().Address().
// AdminDelist is pause-exempt (moderation can always remove content).
// SetFeeRecipient changes where platform fees flow (default = AdminAddress).

import (
	"chain"
	"chain/runtime/unsafe"

	"gno.land/p/samcrew/grc721"
)

func assertAdmin() {
	if unsafe.PreviousRealm().Address() != owner {
		panic("admin only")
	}
}

// Pause halts new trade operations (ListNFT, BuyNFT, MakeOffer, AcceptOffer).
// Value-exit paths (DelistNFT, CancelOffer, ClaimExpiredOffer) remain available.
func Pause(cur realm) {
	assertAdmin()
	paused = true
	chain.Emit("MarketPaused", "by", unsafe.PreviousRealm().Address().String())
}

// Unpause resumes normal operations.
func Unpause(cur realm) {
	assertAdmin()
	paused = false
	chain.Emit("MarketUnpaused", "by", unsafe.PreviousRealm().Address().String())
}

// AdminDelist force-removes any listing. Pause-exempt (moderation).
func AdminDelist(cur realm, collectionID string, tid grc721.TokenID) {
	assertAdmin()
	key := listingKey(collectionID, string(tid))
	if _, exists := listings.Get(key); !exists {
		panic("not listed: " + key)
	}
	listings.Remove(key)
	removeFromOrder(key)
	chain.Emit("AdminDelisted",
		"collection", collectionID,
		"tokenId", string(tid),
		"admin", unsafe.PreviousRealm().Address().String(),
	)
}

// SetFeeRecipient updates the address that receives platform fees. Rejects the
// empty address: resolveFee falls back to feeRecipient when the DAO config
// treasury is unset, and a fee send to "" panics — with both unset, every
// trade with a nonzero fee would revert (fat-finger brick, pre-deploy review).
func SetFeeRecipient(cur realm, addr address) {
	assertAdmin()
	if addr == "" {
		panic("fee recipient must be non-empty")
	}
	feeRecipient = addr
	chain.Emit("FeeRecipientChanged", "newRecipient", addr.String())
}

// ── Ownership (2-step, pre-deploy review) ─────────────────────────────────────
//
// The admin used to be a hard-coded constant — on an immutable realm that means
// the engine could never be handed to a DAO executor without a full redeploy.
// 2-step transfer (stage + accept) so a typo can't brick admin.

// TransferOwnership stages a new owner; it takes effect only after AcceptOwnership
// is called BY that address.
func TransferOwnership(cur realm, newOwner address) {
	assertAdmin()
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
	if unsafe.PreviousRealm().Address() != pendingOwner {
		panic("unauthorized: only the pending owner may accept")
	}
	owner = pendingOwner
	pendingOwner = ""
	chain.Emit("OwnershipTransferAccepted", "owner", owner.String())
}

// GetOwner returns the current admin address.
func GetOwner() string { return owner.String() }

// GetPendingOwner returns the staged owner ("" when no transfer is pending).
func GetPendingOwner() string { return pendingOwner.String() }
