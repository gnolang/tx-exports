// Package market defines the minimal, vendor-neutral interface a GRC721
// collection must expose to become tradeable on the gnomarket marketplace
// realm (gno.land/r/gnomarket/nftmarket).
//
// There is no canonical GRC721 import path on gno.land — every collection
// vendors its own copy (gno.land/p/gnoswap/deps/grc721, gno.land/p/samcrew/grc721,
// hand-rolled implementations, etc.), each with its own nominally-typed
// TokenID. To stay usable by any of them without the marketplace importing a
// specific vendor's package, this interface is expressed entirely in plain
// `string`/`address` types rather than a shared TokenID type. A collection
// wires itself up with a small adapter (a handful of lines) translating its
// own TokenID type to/from string — see the package doc on NFT below for the
// expected shape.
package market

// NFT is the write surface a collection registers with the marketplace via
// RegisterCollection. It is safe to hand a value of this type to an
// untrusted realm (the marketplace) because TransferFrom is `cur realm`-typed:
// the implementation must derive its caller from cur.Previous() itself, never
// from a trusted-blindly argument. The gno VM enforces that a stashed/foreign
// `cur` cannot be replayed through interface dispatch (IsCurrent-strict on
// cross), so the marketplace holding this value can only ever move a token
// while it is genuinely the calling realm.
//
// This marketplace is non-custodial: a listed token never leaves the
// seller's wallet until the moment of sale. Instead, the seller grants the
// marketplace's own address approval (via the collection's normal
// Approve/SetApprovalForAll), and List/Buy only ever call TransferFrom —
// which succeeds because the collection's OWN authorization check (not
// marketplace-side trust) recognizes the marketplace as an approved
// operator, the same way it would recognize any other approved third party.
//
// A typical adapter, written once by a collection author on top of any
// vendored grc721 package (nft below is that package's concrete type, kept in
// an unexported var by the owning realm):
//
//	type marketAdapter struct{}
//
//	func (marketAdapter) Name() string { return "MyCollection" }
//	func (marketAdapter) OwnerOf(tid string) (address, error) {
//		return nft.OwnerOf(grc721.TokenID(tid))
//	}
//	func (marketAdapter) TokenURI(tid string) (string, error) {
//		return nft.TokenURI(grc721.TokenID(tid))
//	}
//	func (marketAdapter) GetApproved(tid string) (address, error) {
//		return nft.GetApproved(grc721.TokenID(tid))
//	}
//	func (marketAdapter) IsApprovedForAll(owner, operator address) bool {
//		return nft.IsApprovedForAll(owner, operator)
//	}
//	func (marketAdapter) TransferFrom(cur realm, from, to address, tid string) error {
//		caller := cur.Previous().Address()
//		return nft.TransferFrom(caller, from, to, grc721.TokenID(tid))
//	}
//
//	func RegisterWithMarketplace(cur realm) {
//		nftmarket.RegisterCollection(cross(cur), marketAdapter{})
//	}
//
// (nftmarket here refers to the stateful realm gno.land/r/gnomarket/nftmarket,
// which re-exports this package's NFT/Listing types — a collection adapter
// only needs to satisfy the method set below, not import this package at all.)
type NFT interface {
	// Name returns the collection's display name, for render purposes only.
	Name() string
	// OwnerOf returns the current owner of tid in the collection's own ledger.
	OwnerOf(tid string) (address, error)
	// TokenURI returns the token's metadata URI, for render purposes only.
	TokenURI(tid string) (string, error)
	// GetApproved returns the address explicitly approved to move tid, or
	// "" if none. The marketplace reads this (and IsApprovedForAll) before
	// accepting a listing, to verify the seller has actually granted it
	// permission — List does not itself grant or request anything.
	GetApproved(tid string) (address, error)
	// IsApprovedForAll reports whether operator holds blanket approval over
	// all of owner's tokens in this collection.
	IsApprovedForAll(owner, operator address) bool
	// TransferFrom moves tid from `from` to `to`. Implementations MUST derive
	// the effective caller from cur.Previous().Address() themselves and
	// apply their own collection's normal transfer authorization against it
	// — caller must be from's current owner, or an address from has
	// approved via Approve/SetApprovalForAll — never trust a caller
	// identity passed in some other way. This check, performed by the
	// collection itself rather than trusted from the marketplace, is what
	// makes it safe for the marketplace to move a seller's token without
	// ever holding it.
	TransferFrom(cur realm, from, to address, tid string) error
}

// Listing is a fixed-price sale order held by the marketplace. The token
// itself stays with Seller (approved to the marketplace, not escrowed)
// until Buy succeeds.
type Listing struct {
	CollectionID string // the registering realm's own PkgPath; spoof-proof
	TokenID      string
	Seller       address
	Price        int64 // ugnot
	CreatedAt    int64 // block height
}
