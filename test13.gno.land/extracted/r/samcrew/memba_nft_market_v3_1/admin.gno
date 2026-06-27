package memba_nft_market_v3_1

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
	if unsafe.PreviousRealm().Address() != address(AdminAddress) {
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

// SetFeeRecipient updates the address that receives platform fees.
func SetFeeRecipient(cur realm, addr address) {
	assertAdmin()
	feeRecipient = addr
	chain.Emit("FeeRecipientChanged", "newRecipient", addr.String())
}
