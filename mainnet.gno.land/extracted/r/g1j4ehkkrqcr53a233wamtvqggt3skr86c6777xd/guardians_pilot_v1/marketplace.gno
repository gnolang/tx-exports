package guardians_pilot_v1

import (
	"chain"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/grc721/v0"
	"gno.land/p/nt/ufmt/v0"
)

var (
	authorizedMarketplace address
	settledMarketNonces  avl.Tree
)

func AuthorizedMarketplace() address { return authorizedMarketplace }

// SetAuthorizedMarketplace is a one-time binding made before minting. Keeping
// the PrivateLedger and Token handle private prevents other approved operators
// from bypassing the official royalty settlement path.
func SetAuthorizedMarketplace(cur realm, marketplace address) {
	assertAdmin(cur.Previous().Address())
	if authorizedMarketplace.IsValid() {
		panic("guardians: authorized marketplace is locked")
	}
	if !marketplace.IsValid() {
		panic("guardians: invalid marketplace address")
	}
	if token.TotalSupply() != 0 || !salePaused {
		panic("guardians: configure marketplace before minting and sale activation")
	}
	authorizedMarketplace = marketplace
	chain.Emit("MarketplaceAuthorized", "marketplace", marketplace.String())
}

// MarketplaceTransfer is the only operator-transfer route. The authorized
// market supplies its consumed listing nonce and gross price for audit events.
func MarketplaceTransfer(cur realm, seller, buyer address, tokenID string, grossPrice, nonce int64) {
	marketplace := cur.Previous().Address()
	if marketplace != authorizedMarketplace || !authorizedMarketplace.IsValid() {
		panic("guardians: caller is not authorized marketplace")
	}
	if grossPrice < 1 || nonce < 1 {
		panic("guardians: invalid marketplace settlement")
	}
	nonceKey := marketplace.String() + ":" + ufmt.Sprintf("%d", nonce)
	if settledMarketNonces.Has(nonceKey) {
		panic("guardians: marketplace nonce already settled")
	}
	if OwnerOf(tokenID) != seller {
		panic("guardians: marketplace seller is not token owner")
	}
	if !token.IsApprovedForAll(seller, marketplace) {
		panic("guardians: marketplace operator approval required")
	}

	settledMarketNonces.Set(nonceKey, true)
	if err := ledger.TransferFrom(marketplace, seller, buyer, grc721.TokenID(tokenID)); err != nil {
		panic(err)
	}
	chain.Emit(
		"MarketplaceSettlementTransfer",
		"marketplace", marketplace.String(),
		"tokenId", tokenID,
		"seller", seller.String(),
		"buyer", buyer.String(),
		"grossPrice", ufmt.Sprintf("%d", grossPrice),
		"nonce", ufmt.Sprintf("%d", nonce),
	)
}
