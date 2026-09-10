// Package nftoffers51 is the v5 escrowed offer (bid) book for collections
// minted through gno.land/r/g1hx4z2.../nft51.
//
// An offer locks the buyer's GNOT in this realm until the offer is
// accepted, cancelled, rejected, or swept after expiry. Money never sits
// anywhere a human has to be trusted.
//
// WHAT CHANGED VS V4 (gno.land/r/g1hx4z2.../nftoffers4)
//
//  1. RejectOffer - the seller side of the book finally exists. In v4 an
//     owner who disliked a lowball bid could do nothing: only the buyer
//     could cancel, so the bid sat on the token's page until it expired.
//     Now the current owner of the token can reject it, which refunds the
//     buyer immediately. Only token-specific offers are rejectable;
//     collection-wide offers have no single owner with standing to reject
//     them, and letting any holder kill them would be a griefing vector.
//
//  2. SweepExpired - expired escrow is no longer stuck. v4 checked expiry
//     when accepting, but nothing ever refunded an expired offer, so the
//     buyer's coins stayed locked until they remembered to cancel. Sweeping
//     is permissionless (anyone may pay the gas; funds only ever go back to
//     the original buyer) and driven by a byExpiry index, so it costs one
//     ordered walk instead of a full scan.
//
//  3. Records are roughly half the size, same change as nftmarket51:
//     ids/amounts/heights are int64 internally and the index trees hold
//     int64 values instead of duplicated strings. OfferInfo still exports
//     strings, so the frontend decoder only needs a new pkgpath.
//
// Kept from v4 deliberately: authorization via cur.Previous().Address(),
// assertDirectPayment on the funding path, deactivate-before-payout
// ordering, and active-only pagination indexes.
package nftoffers51

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"

	"gno.land/p/nt/avl/v0"
	"gno.land/r/g1hx4z2kwrnzd9up3g0gd4hspc6v78e4r90jkke3/nft51"
)

// MaxExpiryBlocks caps how long escrow can be locked (~30 days at 1s
// blocks), so a forgotten offer cannot hold coins hostage forever.
const MaxExpiryBlocks = 2_592_000

// MaxSweepLimit bounds one SweepExpired call so it can never run past the
// block gas limit no matter how many offers expired at once.
const MaxSweepLimit = 50

// Offer is one escrowed bid. tokenID == 0 means a collection-wide offer:
// it can be accepted by the owner of any token in that collection.
type Offer struct {
	id              int64
	collectionID    int64
	tokenID         int64
	buyer           address
	amountUgnot     int64
	active          bool
	expiresAtHeight int64
	createdAt       int64
}

// OfferInfo is the exported, read-only view of an Offer. IDs stay strings
// so existing frontend decoders keep working untouched; a collection-wide
// offer reports TokenID "".
type OfferInfo struct {
	ID              string
	CollectionID    string
	TokenID         string
	Buyer           address
	AmountUgnot     int64
	Active          bool
	ExpiresAtHeight int64
	CreatedAt       int64
}

var (
	offers       = avl.NewTree() // paddedOfferID -> *Offer
	byToken      = avl.NewTree() // "collectionId:tokenId:paddedOfferID" -> int64 offer id (active only)
	byBuyer      = avl.NewTree() // "buyer:paddedOfferID" -> int64 offer id (active only)
	byCollection = avl.NewTree() // "collectionId:paddedOfferID" -> int64 offer id (active only)
	byExpiry     = avl.NewTree() // "paddedHeight:paddedOfferID" -> int64 offer id (active only) - drives SweepExpired
	nextID       int64
	activeCount  int64
)

// assertDirectPayment rejects any call path where the tx's coin envelope
// cannot be trusted to have actually landed in this realm.
//
// IsUserCall() is true only when the previous frame is an EOA calling this
// function directly ("gnokey maketx call" / a wallet): its pkgPath is empty.
// Every code realm has a non-empty pkgPath, and MsgRun executes inside the
// ephemeral /e/<addr>/run realm, so both paths are rejected here.
//
// runtime.AssertOriginCall() is deliberately NOT used: under the crossing
// model it can never pass for a "cur realm" function, not even for a
// legitimate direct wallet call.
func assertDirectPayment(cur realm) {
	if !cur.Previous().IsUserCall() {
		panic("this function must be called directly by a wallet, not through another realm")
	}
}

// MakeOffer escrows the sent GNOT as a bid. Pass an empty tokenID to bid
// on any token of the collection. expiresInBlocks must be positive and at
// most MaxExpiryBlocks.
func MakeOffer(cur realm, collectionID, tokenID string, expiresInBlocks int64) string {
	assertDirectPayment(cur)
	caller := cur.Previous().Address()

	amount := unsafe.OriginSend().AmountOf("ugnot")
	if amount <= 0 {
		panic("an offer must be funded: send ugnot with this call")
	}
	if expiresInBlocks <= 0 || expiresInBlocks > MaxExpiryBlocks {
		panic("expiresInBlocks must be between 1 and " + strconv.FormatInt(MaxExpiryBlocks, 10))
	}

	cid := parseID(collectionID, "collection id")
	var tid int64
	if tokenID != "" {
		tid = parseID(tokenID, "token id")
		owner, err := nft51.OwnerOf(collectionID, tokenID)
		if err != nil {
			panic(err)
		}
		if owner == caller {
			panic("cannot bid on a token you already own")
		}
	}

	nextID++
	o := &Offer{
		id:              nextID,
		collectionID:    cid,
		tokenID:         tid,
		buyer:           caller,
		amountUgnot:     amount,
		active:          true,
		expiresAtHeight: runtime.ChainHeight() + expiresInBlocks,
		createdAt:       runtime.ChainHeight(),
	}
	offers.Set(padID(o.id), o)
	indexActive(o)

	id := strconv.FormatInt(o.id, 10)
	chain.Emit(
		"OfferMade",
		"offerId", id,
		"collection", collectionID,
		"tokenId", tokenID,
		"buyer", caller.String(),
		"amount", strconv.FormatInt(amount, 10),
		"expiresAt", strconv.FormatInt(o.expiresAtHeight, 10),
	)

	return id
}

// CancelOffer withdraws an active offer and refunds its escrow. Buyer only.
func CancelOffer(cur realm, offerID string) {
	caller := cur.Previous().Address()
	o := mustGetOffer(offerID)
	if !o.active {
		panic("offer is not active")
	}
	if o.buyer != caller {
		panic("only the buyer can cancel this offer")
	}

	deactivate(o)
	refund(cur, o)
	chain.Emit("OfferCancelled", "offerId", offerID, "refunded", strconv.FormatInt(o.amountUgnot, 10))
}

// RejectOffer lets the CURRENT OWNER of a token turn down a bid on it,
// refunding the buyer immediately instead of leaving the bid parked on
// the token's page until it expires. New in v5.
//
// Only token-specific offers can be rejected: a collection-wide offer is
// addressed to every holder at once, so no single holder has standing to
// kill it for everyone else.
func RejectOffer(cur realm, offerID string) {
	caller := cur.Previous().Address()
	o := mustGetOffer(offerID)
	if !o.active {
		panic("offer is not active")
	}
	if o.tokenID == 0 {
		panic("collection-wide offers cannot be rejected; they are not addressed to a single owner")
	}

	collectionID := strconv.FormatInt(o.collectionID, 10)
	tokenID := strconv.FormatInt(o.tokenID, 10)
	owner, err := nft51.OwnerOf(collectionID, tokenID)
	if err != nil {
		panic(err)
	}
	if owner != caller {
		panic("only the current owner of the token can reject this offer")
	}

	deactivate(o)
	refund(cur, o)

	chain.Emit(
		"OfferRejected",
		"offerId", offerID,
		"collection", collectionID,
		"tokenId", tokenID,
		"by", caller.String(),
		"refunded", strconv.FormatInt(o.amountUgnot, 10),
	)
}

// SweepExpired refunds up to limit expired offers and closes them. New in
// v5, and deliberately permissionless: escrow only ever goes back to the
// original buyer, so the worst a caller can do is pay gas on someone
// else's behalf. limit is clamped to MaxSweepLimit; pass 0 for the max.
//
// It walks byExpiry, which is ordered by expiry height, so it stops at the
// first offer that is still alive instead of scanning the whole book.
func SweepExpired(cur realm, limit int64) int64 {
	if limit <= 0 || limit > MaxSweepLimit {
		limit = MaxSweepLimit
	}
	height := runtime.ChainHeight()

	// Collect first: mutating the tree while iterating it is not safe.
	expired := make([]*Offer, 0, limit)
	byExpiry.Iterate("", "", func(key string, value any) bool {
		if int64(len(expired)) >= limit {
			return true
		}
		o := getOffer(value.(int64))
		if o == nil || !o.active {
			return false
		}
		if o.expiresAtHeight > height {
			// Ordered by expiry: everything after this is still alive.
			return true
		}
		expired = append(expired, o)
		return false
	})

	var swept int64
	for _, o := range expired {
		deactivate(o)
		refund(cur, o)
		swept++
		chain.Emit(
			"OfferExpired",
			"offerId", strconv.FormatInt(o.id, 10),
			"buyer", o.buyer.String(),
			"refunded", strconv.FormatInt(o.amountUgnot, 10),
		)
	}
	if swept > 0 {
		chain.Emit("OffersSwept", "count", strconv.FormatInt(swept, 10))
	}
	return swept
}

// ExpiredOfferCount reports how many active offers are already past their
// expiry height, so a UI (or a cron) knows whether sweeping is worth it.
func ExpiredOfferCount() int64 {
	height := runtime.ChainHeight()
	var n int64
	byExpiry.Iterate("", "", func(key string, value any) bool {
		o := getOffer(value.(int64))
		if o == nil || !o.active {
			return false
		}
		if o.expiresAtHeight > height {
			return true
		}
		n++
		return false
	})
	return n
}

// AcceptOffer sells a token to the bidder. The caller must own the token
// and must have approved this realm on nft51. For a collection-wide offer,
// tokenID selects which token is being sold; for a token-specific offer it
// must match (or be left empty).
func AcceptOffer(cur realm, offerID, tokenID string) {
	caller := cur.Previous().Address()
	o := mustGetOffer(offerID)
	if !o.active {
		panic("offer is not active")
	}
	if runtime.ChainHeight() > o.expiresAtHeight {
		panic("offer has expired")
	}
	if o.buyer == caller {
		panic("cannot accept your own offer")
	}

	collectionID := strconv.FormatInt(o.collectionID, 10)
	tid := resolveToken(o, tokenID)

	owner, err := nft51.OwnerOf(collectionID, tid)
	if err != nil {
		panic(err)
	}
	if owner != caller {
		panic("only the token owner can accept an offer on it")
	}
	offerAddr := cur.Address()
	approved, _ := nft51.GetApproved(collectionID, tid)
	if approved != offerAddr && !nft51.IsApprovedForAll(collectionID, owner, offerAddr) {
		panic("offers realm is not approved to transfer this token yet; call nft51.Approve or nft51.SetApprovalForAll first")
	}

	// Deactivate first, then move money.
	deactivate(o)

	royaltyAddr, rawRoyalty, err := nft51.RoyaltyInfo(collectionID, tid, o.amountUgnot)
	if err != nil {
		rawRoyalty = 0
	}
	royaltyAmt, sellerAmt := splitPayment(o.amountUgnot, rawRoyalty, royaltyAddr == caller)

	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	if royaltyAmt > 0 {
		bk.SendCoins(offerAddr, royaltyAddr, chain.NewCoins(chain.NewCoin("ugnot", royaltyAmt)))
	}
	bk.SendCoins(offerAddr, caller, chain.NewCoins(chain.NewCoin("ugnot", sellerAmt)))

	// Cross into nft51 to move ownership. Reverts the whole tx, transfers
	// included, if approval no longer stands.
	nft51.TransferFrom(cross(cur), collectionID, tid, caller, o.buyer)

	chain.Emit(
		"OfferAccepted",
		"offerId", offerID,
		"collection", collectionID,
		"tokenId", tid,
		"seller", caller.String(),
		"buyer", o.buyer.String(),
		"amount", strconv.FormatInt(o.amountUgnot, 10),
		"royalty", strconv.FormatInt(royaltyAmt, 10),
	)
}

// splitPayment is the pure payout arithmetic, kept separate so it can be
// unit-tested without a funded chain: a royalty is only honoured when it
// is positive, strictly smaller than the bid, and not payable to the
// seller themselves.
func splitPayment(amount, royalty int64, royaltyGoesToSeller bool) (royaltyAmt, sellerAmt int64) {
	if royalty <= 0 || royalty >= amount || royaltyGoesToSeller {
		royalty = 0
	}
	return royalty, amount - royalty
}

// Read-only views.

// GetOffer returns one offer by ID.
func GetOffer(offerID string) OfferInfo { return toInfo(mustGetOffer(offerID)) }

// OffersForToken returns every active offer addressed to one token.
func OffersForToken(collectionID, tokenID string) []OfferInfo {
	prefix := collectionID + ":" + tokenID + ":"
	return collect(byToken, prefix, prefix+";", 0, 0)
}

// OffersByBuyer returns a page of one buyer's active offers.
func OffersByBuyer(buyer address, offset, limit int64) []OfferInfo {
	return collect(byBuyer, buyer.String()+":", buyer.String()+";", offset, limit)
}

// CollectionOffers returns a page of a collection's active offers,
// including the collection-wide ones.
func CollectionOffers(collectionID string, offset, limit int64) []OfferInfo {
	return collect(byCollection, collectionID+":", collectionID+";", offset, limit)
}

// BestOfferForToken returns the highest live bid a token's owner could
// accept right now - token-specific and collection-wide offers together -
// or an empty OfferInfo when there is none.
func BestOfferForToken(collectionID, tokenID string) OfferInfo {
	height := runtime.ChainHeight()
	var best *Offer
	byCollection.Iterate(collectionID+":", collectionID+";", func(key string, value any) bool {
		o := getOffer(value.(int64))
		if o == nil || !o.active || o.expiresAtHeight < height {
			return false
		}
		if o.tokenID != 0 && strconv.FormatInt(o.tokenID, 10) != tokenID {
			return false
		}
		if best == nil || o.amountUgnot > best.amountUgnot {
			best = o
		}
		return false
	})
	if best == nil {
		return OfferInfo{}
	}
	return toInfo(best)
}

// OfferCount returns the total number of offers ever made.
func OfferCount() int64 { return nextID }

// ActiveOfferCount returns how many offers are currently active.
func ActiveOfferCount() int64 { return activeCount }

// Render implements the gno.land realm home-page convention.
func Render(path string) string {
	if path != "" {
		o := getOfferByString(path)
		if o == nil {
			return "# 404\n\noffer not found: " + path
		}
		return renderOffer(o)
	}

	out := "# gnoNFT Offers v5\n\n"
	if activeCount == 0 {
		return out + "No active offers.\n"
	}
	out += strconv.FormatInt(activeCount, 10) + " active offer(s), " +
		strconv.FormatInt(ExpiredOfferCount(), 10) + " awaiting sweep\n\n"
	byBuyer.Iterate("", "", func(key string, value any) bool {
		if o := getOffer(value.(int64)); o != nil {
			out += renderOffer(o) + "\n"
		}
		return false
	})
	return out
}

func renderOffer(o *Offer) string {
	target := strconv.FormatInt(o.collectionID, 10) + ":*"
	if o.tokenID != 0 {
		target = strconv.FormatInt(o.collectionID, 10) + ":" + strconv.FormatInt(o.tokenID, 10)
	}
	status := "active"
	if !o.active {
		status = "closed"
	} else if o.expiresAtHeight < runtime.ChainHeight() {
		status = "expired (sweepable)"
	}
	return "- #" + strconv.FormatInt(o.id, 10) + " " + target + " - " +
		strconv.FormatInt(o.amountUgnot, 10) + "ugnot by " + o.buyer.String() +
		" (" + status + ")"
}

// Internal helpers.

func indexActive(o *Offer) {
	p := padID(o.id)
	cid := strconv.FormatInt(o.collectionID, 10)
	if o.tokenID != 0 {
		byToken.Set(cid+":"+strconv.FormatInt(o.tokenID, 10)+":"+p, o.id)
	}
	byBuyer.Set(o.buyer.String()+":"+p, o.id)
	byCollection.Set(cid+":"+p, o.id)
	byExpiry.Set(padID(o.expiresAtHeight)+":"+p, o.id)
	activeCount++
}

func deactivate(o *Offer) {
	o.active = false
	p := padID(o.id)
	cid := strconv.FormatInt(o.collectionID, 10)
	if o.tokenID != 0 {
		byToken.Remove(cid + ":" + strconv.FormatInt(o.tokenID, 10) + ":" + p)
	}
	byBuyer.Remove(o.buyer.String() + ":" + p)
	byCollection.Remove(cid + ":" + p)
	byExpiry.Remove(padID(o.expiresAtHeight) + ":" + p)
	if activeCount > 0 {
		activeCount--
	}
}

// refund returns an offer's escrow to its buyer. Always call deactivate
// before this so a re-entrant path can never be paid twice.
func refund(cur realm, o *Offer) {
	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	bk.SendCoins(cur.Address(), o.buyer, chain.NewCoins(chain.NewCoin("ugnot", o.amountUgnot)))
}

func collect(tree *avl.Tree, start, end string, offset, limit int64) []OfferInfo {
	out := []OfferInfo{}
	var seen int64
	tree.Iterate(start, end, func(key string, value any) bool {
		if seen < offset {
			seen++
			return false
		}
		if limit > 0 && int64(len(out)) >= limit {
			return true
		}
		if o := getOffer(value.(int64)); o != nil && o.active {
			out = append(out, toInfo(o))
		}
		seen++
		return false
	})
	return out
}

// resolveToken decides which token an AcceptOffer call is about: for a
// token-specific offer the argument must match or be empty; for a
// collection-wide offer it is required.
func resolveToken(o *Offer, tokenID string) string {
	if o.tokenID != 0 {
		own := strconv.FormatInt(o.tokenID, 10)
		if tokenID != "" && tokenID != own {
			panic("this offer is for token " + own + ", not " + tokenID)
		}
		return own
	}
	if tokenID == "" {
		panic("this is a collection-wide offer: pass the tokenID you want to sell")
	}
	parseID(tokenID, "token id")
	return tokenID
}

// padID zero-pads a number so index trees sort numerically rather than
// lexicographically ("10" must come after "2"). Also used for expiry
// heights, which is what makes the byExpiry walk ordered.
func padID(id int64) string {
	const width = 12
	s := strconv.FormatInt(id, 10)
	if len(s) >= width {
		return s
	}
	return "000000000000"[:width-len(s)] + s
}

// parseID rejects anything that is not a positive decimal integer, so a
// malformed id can never be written into a record or an index key.
func parseID(s, what string) int64 {
	v, err := strconv.ParseInt(s, 10, 64)
	if err != nil || v <= 0 {
		panic("invalid " + what + ": " + s)
	}
	return v
}

func toInfo(o *Offer) OfferInfo {
	tokenID := ""
	if o.tokenID != 0 {
		tokenID = strconv.FormatInt(o.tokenID, 10)
	}
	return OfferInfo{
		ID:              strconv.FormatInt(o.id, 10),
		CollectionID:    strconv.FormatInt(o.collectionID, 10),
		TokenID:         tokenID,
		Buyer:           o.buyer,
		AmountUgnot:     o.amountUgnot,
		Active:          o.active,
		ExpiresAtHeight: o.expiresAtHeight,
		CreatedAt:       o.createdAt,
	}
}

func getOffer(id int64) *Offer {
	v := offers.Get(padID(id))
	if v == nil {
		return nil
	}
	return v.(*Offer)
}

func getOfferByString(id string) *Offer {
	v, err := strconv.ParseInt(id, 10, 64)
	if err != nil {
		return nil
	}
	return getOffer(v)
}

func mustGetOffer(id string) *Offer {
	o := getOfferByString(id)
	if o == nil {
		panic("offer not found: " + id)
	}
	return o
}
