package market

import (
	"chain"
	"strconv"
	"strings"
	"time"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/seqid/v0"
	"gno.land/p/samcrew/launchpad/merkle/v1"
	sm "gno.land/p/samcrew/launchpad/safemath/v1"
	"gno.land/r/samcrew/launchpad/nft/v1"
)

const (
	OfferToken      = "token"      // one named token
	OfferCollection = "collection" // any token of the collection
	OfferTrait      = "trait"      // any token proven to carry a trait
	StatusAccepted  = "accepted"
	// The token's own listing, closed because the token was sold to an offer.
	StatusSuperseded = "superseded"
	maxTraitBytes    = 100
)

// Offer is a bid whose full price sits in this realm until it is accepted,
// cancelled by its buyer or returned after expiry. An offer exists while it
// is open and no longer.
type Offer struct {
	ID         string // "O<n>"
	Kind       string
	Collection string
	Number     int64  // token offers only
	Trait      string // trait offers only: "<type>=<value>"
	Buyer      address
	Price      int64
	Currency   string
	CreatedAt  int64
	ExpiresAt  int64
	FeeBPS     int64 // protocol fee, pinned when the buyer funded the offer
}

var (
	lastOffer seqid.ID
	offers    avl.Tree // offer key -> *Offer, in creation order
	open      avl.Tree // "<collection>/<offer key>" -> *Offer
	byBuyer   avl.Tree // "<buyer>/<offer key>" -> *Offer
)

// findOffer returns an open offer and its key, or nil: a closed one is gone.
func findOffer(id string) (*Offer, string) {
	if key, ok := orderKey('O', id); ok {
		if o := offers.Get(key); o != nil {
			return o.(*Offer), key
		}
	}
	return nil, ""
}

func mustOffer(id string) (*Offer, string) {
	o, key := findOffer(id)
	if o == nil {
		panic("launchpad/market: unknown offer")
	}
	return o, key
}

// TraitLeaf is the Merkle leaf that proves a token carries a trait, as
// committed by the collection's creator in the NFT ledger.
func TraitLeaf(collection string, number int64, trait string) merkle.Hash {
	return merkle.Leaf([]byte("launchpad-trait-v1|" + collection + "|" +
		strconv.FormatInt(number, 10) + "|" + trait))
}

// MakeOffer escrows price and returns the offer ID. kind selects what the
// offer is for: number is set for a token offer, trait for a trait offer, and
// both are zero and empty otherwise. A trait offer needs a collection whose
// creator committed its traits. The protocol fee in force is pinned on the
// offer; it comes out of what the seller receives, never on top of the price,
// and maxFeeBPS is the highest the buyer lets a seller be charged.
func MakeOffer(cur realm, kind, collection string, number int64, trait string,
	price, expiresAt int64, currencyKey string, maxFeeBPS int64) string {
	buyer := directCaller(cur)
	fee := pinned(collection, price, expiresAt, currencyKey, maxFeeBPS)
	ok := false
	switch kind {
	case OfferToken:
		ok = trait == "" && nft.StatusOf(collection, number) == nft.StatusActive &&
			nft.OwnerOf(collection, number) != buyer
	case OfferCollection:
		ok = trait == "" && number == 0
	case OfferTrait:
		ok = number == 0 && len(trait) <= maxTraitBytes && strings.Count(trait, "=") == 1 &&
			!strings.HasPrefix(trait, "=") && !strings.HasSuffix(trait, "=") &&
			!strings.Contains(trait, "|") && nft.TraitsRoot(collection) != ""
	}
	if !ok {
		panic("launchpad/market: invalid offer")
	}
	before := take(cur, currencyKey, price)
	escrow[currencyKey] = sm.Add(escrow[currencyKey], price)
	id, key := nextOrder(&lastOffer, "O")
	o := &Offer{ID: id, Kind: kind, Collection: collection, Number: number,
		Trait: trait, Buyer: buyer, Price: price, Currency: currencyKey,
		CreatedAt: time.Now().Unix(), ExpiresAt: expiresAt, FeeBPS: fee}
	offers.Set(key, o)
	open.Set(collection+"/"+key, o)
	byBuyer.Set(buyer.String()+"/"+key, o)
	settled(cur, currencyKey, before)
	chain.Emit("OfferMade", "offer", id, "kind", kind, "collection", collection,
		"number", strconv.FormatInt(number, 10), "trait", trait,
		"buyer", buyer.String(), "currency", currencyKey,
		"price", strconv.FormatInt(price, 10), "fee_bps", strconv.FormatInt(fee, 10),
		"expires_at", strconv.FormatInt(expiresAt, 10))
	return id
}

// release deletes an offer, takes its price out of escrow and says why in its
// closing event; the caller then pays the price out. Every exit goes through
// here, and an offer leaves escrow once, by its own key: with `settled`, an
// exit pays out exactly the price of the one offer it closed, so a fault in
// one offer's exit can never spend another offer's escrow.
func release(o *Offer, key, status string) {
	if v := offers.Get(key); v == nil || v.(*Offer) != o {
		panic("launchpad/market: offer already closed")
	}
	offers.Remove(key)
	open.Remove(o.Collection + "/" + key)
	byBuyer.Remove(o.Buyer.String() + "/" + key)
	escrow[o.Currency] = sm.Sub(escrow[o.Currency], o.Price)
	chain.Emit("OfferClosed", "offer", o.ID, "status", status)
}

// refund returns an open offer's escrow to its buyer. Refunds never consult
// the config realm: no pause or policy change can hold a buyer's funds.
func refund(cur realm, o *Offer, key, status string) {
	before := untouched(cur, o.Currency)
	release(o, key, status)
	pay(cur, o.Currency, o.Buyer, o.Price)
	settled(cur, o.Currency, before)
}

// CancelOffer takes back the caller's own open offer, expired or not.
func CancelOffer(cur realm, id string) {
	who := directCaller(cur)
	o, key := mustOffer(id)
	if who != o.Buyer {
		panic("launchpad/market: buyer only")
	}
	refund(cur, o, key, StatusCancelled)
}

// ExpireOffer returns to its buyer the escrow of an offer that expired more
// than graceToClose ago. Anyone may call it: the price goes to the buyer, and
// the chain pays the caller the storage deposit of the bytes the offer
// occupied, so for a week after expiry only the buyer, with CancelOffer,
// takes its own offer back.
func ExpireOffer(cur realm, id string) {
	directCaller(cur)
	o, key := mustOffer(id)
	if time.Now().Unix() < o.ExpiresAt+graceToClose {
		panic("launchpad/market: only its buyer closes this offer yet")
	}
	refund(cur, o, key, StatusExpired)
}

// AcceptOffer sells the caller's token number to an open offer. proof is the
// comma-separated Merkle path of the token's trait for a trait offer, and
// empty otherwise. currencyKey and price are the terms the seller read: an
// offer on other terms, such as an ID the seller never saw, buys nothing. The
// caller must first approve this realm in the NFT ledger.
func AcceptOffer(cur realm, id string, number int64, proof, currencyKey string, price int64) {
	seller := directCaller(cur)
	o, key := mustOffer(id)
	if o.Currency != currencyKey || o.Price != price {
		panic("launchpad/market: order terms differ from those signed")
	}
	before := untouched(cur, o.Currency)
	p := policy(o.Currency)
	ok := time.Now().Unix() < o.ExpiresAt && seller != o.Buyer &&
		sellable(o.Collection, number, seller)
	switch {
	case !ok:
	case o.Kind == OfferToken:
		ok = number == o.Number && proof == ""
	case o.Kind == OfferCollection:
		ok = proof == ""
	default:
		root, _ := merkle.ParseHash(nft.TraitsRoot(o.Collection))
		path, err := merkle.ParseProof(proof)
		ok = err == nil && merkle.Verify(root, TraitLeaf(o.Collection, number, o.Trait), path)
	}
	if !ok {
		panic("launchpad/market: offer unavailable for this token")
	}
	release(o, key, StatusAccepted)
	if l := listingOf(o.Collection, number); l != nil {
		closeListing(l, StatusSuperseded)
	}
	nft.TransferFrom(cross(cur), o.Collection, seller, o.Buyer, number)
	settle(cur, o.Currency, o.Collection, o.Price, o.FeeBPS, seller, p.treasury)
	settled(cur, o.Currency, before)
	chain.Emit("OfferAccepted", "offer", id, "collection", o.Collection,
		"number", strconv.FormatInt(number, 10), "buyer", o.Buyer.String(),
		"seller", seller.String(), "currency", o.Currency,
		"price", strconv.FormatInt(o.Price, 10))
}

// GetOffer returns an open offer; a closed or unknown ID aborts.
func GetOffer(id string) Offer {
	o, _ := mustOffer(id)
	return *o
}

// EscrowOf is the total of open offers in a currency.
func EscrowOf(currencyKey string) int64 { return escrow[currencyKey] }
