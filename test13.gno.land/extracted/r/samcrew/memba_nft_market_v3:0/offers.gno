package memba_nft_market_v3

// Offer management — escrowed buyer offers on any listed NFT.
//
// Lifecycle:
//   MakeOffer      — buyer sends ugnot, funds held in escrow by this realm
//   CancelOffer    — buyer cancels (pause-exempt; must wait MinOfferLifetimeBlk)
//   AcceptOffer    — listing seller accepts; settles atomically via MarketTransfer + payouts
//   ClaimExpiredOffer — anyone claims refund after OfferTimeoutBlk (safety valve)
//
// Pause policy: MakeOffer + AcceptOffer are blocked while paused (new escrow /
// new settlement). CancelOffer + ClaimExpiredOffer are pause-exempt (value-exit).
//
// PHASE 3+ (deferred): collection-wide offers (an offer that matches ANY token in a
// collection rather than a specific token id) are NOT built here — see the deferred
// list in market.gno. This engine only supports per-token offers.

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"

	"gno.land/p/samcrew/grc721"
	"gno.land/p/nt/ufmt/v0"

	nft "gno.land/r/samcrew/memba_collections" // v3 change #4: canonical registry (was memba_nft_v2)
)

// Offer is an escrowed buy proposal on a specific (collection, token) pair.
type Offer struct {
	CollectionID string
	TokenID      string
	Buyer        address
	Amount       int64 // ugnot held in escrow
	CreatedBlk   int64
}

// MakeOffer places an offer with escrowed funds.
// Caller must send ugnot with the transaction; funds are held by this realm.
func MakeOffer(cur realm, collectionID string, tid grc721.TokenID) {
	if paused {
		panic("market paused")
	}
	if !unsafe.PreviousRealm().IsUserCall() {
		panic("must be a direct user call")
	}
	buyer := unsafe.PreviousRealm().Address()
	amt := sumUgnot(unsafe.OriginSend())
	if amt < MinPrice {
		panic("offer below minimum")
	}

	if offers.Size() >= MaxOffers {
		panic("offer limit reached")
	}
	if countOffersByBuyer(buyer) >= MaxOffersPerAddr {
		panic("buyer offer limit reached")
	}

	key := offerKey(collectionID, string(tid), buyer)
	if _, exists := offers.Get(key); exists {
		panic("offer already exists, cancel first")
	}

	// Effects
	offers.Set(key, &Offer{
		CollectionID: collectionID,
		TokenID:      string(tid),
		Buyer:        buyer,
		Amount:       amt,
		CreatedBlk:   runtime.ChainHeight(),
	})

	chain.Emit("OfferMade",
		"collection", collectionID,
		"tokenId", string(tid),
		"buyer", buyer.String(),
		"amount", itoa(amt),
	)
}

// CancelOffer allows the offerer to reclaim escrowed funds.
// Pause-exempt (value-exit). Must wait MinOfferLifetimeBlk to prevent front-run.
func CancelOffer(cur realm, collectionID string, tid grc721.TokenID) {
	caller := unsafe.PreviousRealm().Address()
	key := offerKey(collectionID, string(tid), caller)

	val, exists := offers.Get(key)
	if !exists {
		panic("offer not found")
	}
	o := val.(*Offer)

	age := runtime.ChainHeight() - o.CreatedBlk
	if age < MinOfferLifetimeBlk {
		panic(ufmt.Sprintf("offer too new to cancel: %d blocks remaining", MinOfferLifetimeBlk-age))
	}

	// Effects
	amt := o.Amount
	offers.Remove(key)

	// Interactions
	refund(cur, caller, amt)

	chain.Emit("OfferCancelled",
		"collection", collectionID,
		"tokenId", string(tid),
		"buyer", caller.String(),
		"amount", itoa(amt),
	)
}

// ClaimExpiredOffer returns escrowed funds when an offer has exceeded OfferTimeoutBlk.
// Pause-exempt (safety-valve: prevents permanent escrow lock).
// Anyone can call on behalf of the buyer, but funds always go to the buyer.
func ClaimExpiredOffer(cur realm, collectionID string, tid grc721.TokenID, buyer address) {
	key := offerKey(collectionID, string(tid), buyer)

	val, exists := offers.Get(key)
	if !exists {
		panic("offer not found")
	}
	o := val.(*Offer)

	age := runtime.ChainHeight() - o.CreatedBlk
	if age < OfferTimeoutBlk {
		panic(ufmt.Sprintf("offer not yet expired: %d blocks remaining", OfferTimeoutBlk-age))
	}

	// Effects
	amt := o.Amount
	offers.Remove(key)

	// Interactions
	refund(cur, buyer, amt)

	chain.Emit("OfferExpiredClaimed",
		"collection", collectionID,
		"tokenId", string(tid),
		"buyer", buyer.String(),
		"amount", itoa(amt),
	)
}

// AcceptOffer allows the listing seller to accept a buyer's escrowed offer.
// Requires an active listing (seller must have listed first).
// Settles atomically: cross-call MarketTransfer then pay royalty, fee, seller (seller last).
func AcceptOffer(cur realm, collectionID string, tid grc721.TokenID, buyer address) {
	if paused {
		panic("market paused")
	}
	seller := unsafe.PreviousRealm().Address()

	listKey := listingKey(collectionID, string(tid))
	lv, listed := listings.Get(listKey)
	if !listed {
		panic("AcceptOffer requires an active listing — list the NFT first")
	}
	l := lv.(*Listing)
	if l.Seller != seller {
		panic("only the listing seller can accept offers")
	}

	if buyer == seller {
		panic("cannot accept own offer")
	}

	oKey := offerKey(collectionID, string(tid), buyer)
	ov, exists := offers.Get(oKey)
	if !exists {
		panic("offer not found")
	}
	o := ov.(*Offer)

	royRecip, royAmt := nft.RoyaltyInfo(collectionID, tid, o.Amount)
	fee, royalty, sellerAmt := splitProceeds(o.Amount, royAmt)

	// Effects (before cross-call + sends)
	amt := o.Amount
	offers.Remove(oKey)
	listings.Remove(listKey)
	removeFromOrder(listKey)
	recordSale(collectionID, string(tid), seller, buyer, amt, fee, royalty)
	totalVolume += amt

	// Interactions
	nft.MarketTransfer(cross(cur), collectionID, seller, buyer, tid)
	bnk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	self := unsafe.CurrentRealm().Address()
	if royalty > 0 {
		bnk.SendCoins(self, royRecip, chain.Coins{chain.NewCoin("ugnot", royalty)})
	}
	if fee > 0 {
		bnk.SendCoins(self, feeRecipient, chain.Coins{chain.NewCoin("ugnot", fee)})
	}
	bnk.SendCoins(self, seller, chain.Coins{chain.NewCoin("ugnot", sellerAmt)}) // seller last

	// v3 change #3: ONE canonical settlement event (via="offer"). v2 emitted BOTH
	// OfferAccepted AND TokenSold here, double-counting the sale in indexers.
	emitSale("offer", collectionID, string(tid), seller, buyer, amt, fee, royalty, royRecip, sellerAmt)
}

// refund sends escrowed ugnot back to a recipient from this realm's balance.
func refund(cur realm, to address, amt int64) {
	bnk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	bnk.SendCoins(unsafe.CurrentRealm().Address(), to, chain.Coins{chain.NewCoin("ugnot", amt)})
}
