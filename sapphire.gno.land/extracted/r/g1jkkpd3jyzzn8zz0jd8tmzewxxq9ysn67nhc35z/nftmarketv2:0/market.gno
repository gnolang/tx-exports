// Package nftmarket is a fixed-price, non-custodial marketplace for any
// GRC721 collection whose owning realm registers a market.NFT adapter (see
// gno.land/p/gnomarket/market). It never imports a specific collection's
// package — collections come to it at runtime as registered interface
// values, so it can list and trade any compliant collection deployed by
// anyone, not just ones it was compiled against.
//
// Trade flow:
//  1. The collection realm calls RegisterCollection once, handing over an
//     adapter that satisfies market.NFT.
//  2. A seller approves this realm's own address on the collection (via the
//     collection's normal Approve or SetApprovalForAll) — no marketplace
//     involvement needed for that step, it's a plain GRC721 approval call.
//  3. The seller calls List, which verifies current ownership and approval
//     before accepting the listing. The token stays in the seller's wallet.
//  4. A buyer calls Buy with the exact price attached as ugnot. The realm
//     re-verifies ownership/approval are still valid (either could have
//     changed since List, since nothing was escrowed), moves the token
//     directly from seller to buyer in one call, then splits payment
//     between the seller and the platform fee recipient — effects before
//     interactions throughout, and the token or funds are never held by
//     this realm across more than one transaction.
package nftmarketv2

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"

	"gno.land/p/g1jkkpd3jyzzn8zz0jd8tmzewxxq9ysn67nhc35z/market"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ownable/v0"
	"gno.land/p/nt/ufmt/v0"
)

var (
	collections  = avl.NewTree() // collectionID (registrant's own PkgPath) -> market.NFT
	listings     = avl.NewTree() // listingKey -> *market.Listing
	listingOrder []string        // insertion order, for pagination/render

	admin *ownable.Ownable
)

// Fee is charged only on a completed Buy, taken out of the sale price
// (never added on top of it) and forwarded to whoever currently holds
// admin rights. FeeModePercent uses basis points (1/100 of a percent, e.g.
// 250 = 2.5%) — the same convention used elsewhere in the gno.land
// ecosystem for exactly this. maxFeeBps sanity-caps percent mode so a
// fat-fingered admin call can't accidentally set a predatory rate; flat
// mode is separately clamped to never exceed the sale price itself (see
// computeFee).
const (
	FeeModeFlat    = "flat"
	FeeModePercent = "percent"

	maxFeeBps = 5000 // 50% ceiling for FeeModePercent
)

var (
	feeMode        = FeeModeFlat
	feeValue int64 = 1_000_000 // 1 GNOT flat — testing default, see SetFee
)

func init() {
	// Deliberately left unset (empty owner) rather than derived from
	// cur.Previous() here: init() runs during package loading, before any
	// realistic MsgAddPackage-origin call frame exists to derive "who
	// deployed this" from — confirmed empty in practice, not just assumed.
	// ClaimAdmin below is the explicit, two-step way to establish it,
	// matching the ecosystem's own convention of treating the initial
	// admin as something set deliberately rather than inferred at init
	// time (e.g. memba_nft_v2's AdminAddress is a plain deploy-time
	// constant, not derived dynamically either).
	admin = ownable.NewWithAddress("")
}

// ClaimAdmin lets the caller become fee-governance admin — but only once,
// while no admin has been claimed yet. Call this yourself immediately
// after deploying this realm.
func ClaimAdmin(cur realm) {
	if admin.Owner() != "" {
		panic("admin already claimed")
	}
	admin = ownable.NewWithAddress(cur.Previous().Address())
}

func listingKey(collectionID, tid string) string {
	return collectionID + ":" + tid
}

func removeFromOrder(key string) {
	for i, k := range listingOrder {
		if k == key {
			listingOrder = append(listingOrder[:i], listingOrder[i+1:]...)
			return
		}
	}
}

func computeFee(price int64) int64 {
	if admin.Owner() == "" {
		return 0 // no one to receive a fee until ClaimAdmin is called
	}
	var fee int64
	switch feeMode {
	case FeeModePercent:
		fee = price * feeValue / 10_000
	default: // FeeModeFlat
		fee = feeValue
	}
	if fee > price {
		fee = price // never charge more than the sale itself
	}
	if fee < 0 {
		fee = 0
	}
	return fee
}

// Admin returns the current fee-governance admin address.
func Admin() address {
	return admin.Owner()
}

// GetFee returns the current fee mode ("flat" or "percent") and value
// (ugnot for flat, basis points for percent).
func GetFee() (mode string, value int64) {
	return feeMode, feeValue
}

// EstimateFee returns the fee that would be charged on a sale at price
// under the current fee configuration — for frontends to display before
// a Buy.
func EstimateFee(price int64) int64 {
	return computeFee(price)
}

// SetFee changes the fee mode/value. Admin-only.
func SetFee(cur realm, mode string, value int64) {
	admin.AssertOwnedBy(cur.Previous().Address())
	if mode != FeeModeFlat && mode != FeeModePercent {
		panic(`fee mode must be "flat" or "percent"`)
	}
	if value < 0 {
		panic("fee value must not be negative")
	}
	if mode == FeeModePercent && value > maxFeeBps {
		panic(ufmt.Sprintf("percent fee capped at %d bps (%d%%)", maxFeeBps, maxFeeBps/100))
	}
	feeMode = mode
	feeValue = value
}

// TransferAdmin hands fee governance to a new address. Admin-only.
func TransferAdmin(cur realm, newAdmin address) {
	if err := admin.TransferOwnership(0, cur, newAdmin); err != nil {
		panic(err.Error())
	}
}

// RegisterCollection lets a collection realm register its market.NFT adapter.
// Must be called by the collection realm itself, crossing (cross(cur) from the
// collection's own registration function) — collectionID is derived from the
// caller's own PkgPath so no other realm can register under, or overwrite, a
// collection identity that isn't its own.
func RegisterCollection(cur realm, nft market.NFT) string {
	collectionID := cur.Previous().PkgPath()
	if collectionID == "" {
		panic("RegisterCollection must be called by a realm, not a direct user transaction")
	}
	collections.Set(collectionID, nft)
	return collectionID
}

func mustCollection(collectionID string) market.NFT {
	nft, ok := collections.Get(collectionID).(market.NFT)
	if !ok {
		panic("unregistered collection: " + collectionID)
	}
	return nft
}

func getListing(key string) (*market.Listing, bool) {
	l, ok := listings.Get(key).(*market.Listing)
	return l, ok
}

func isApproved(nft market.NFT, owner, marketAddr address, tid string) bool {
	approved, err := nft.GetApproved(tid)
	if err != nil {
		panic(err.Error())
	}
	return approved == marketAddr || nft.IsApprovedForAll(owner, marketAddr)
}

// IsRegistered reports whether collectionID has a registered adapter.
func IsRegistered(collectionID string) bool {
	return collections.Has(collectionID)
}

// RegisteredCollectionsCount returns the number of registered collections.
func RegisteredCollectionsCount() int {
	return collections.Size()
}

// GetRegisteredCollectionsPage returns a page of registered collections, one
// per line: collectionID|displayName. These are the only collections a
// seller can actually list here — for a frontend's sell-collection picker.
// Ordered by collectionID (the tree's natural key order); limit is clamped
// to [1, 100].
func GetRegisteredCollectionsPage(offset, limit int) string {
	if limit <= 0 || limit > 100 {
		limit = 100
	}
	out := ""
	collections.IterateByOffset(offset, limit, func(key string, value any) bool {
		nft, ok := value.(market.NFT)
		if !ok {
			return false
		}
		out += key + "|" + nft.Name() + "\n"
		return false
	})
	return out
}

// MarketAddress returns this realm's own address — the address a seller
// must approve (via the collection's Approve or SetApprovalForAll) before
// calling List. The token itself never moves here.
func MarketAddress() address {
	return unsafe.CurrentRealm().Address()
}

// List creates a fixed-price listing for tid. PREREQUISITE: the caller must
// currently own tid AND have approved this marketplace's address on the
// collection (Approve or SetApprovalForAll) — List only verifies and
// records the sale terms, it never moves the token.
func List(cur realm, collectionID, tid string, price int64) {
	if price <= 0 {
		panic("price must be positive")
	}
	nft := mustCollection(collectionID)
	seller := cur.Previous().Address()

	owner, err := nft.OwnerOf(tid)
	if err != nil {
		panic(err.Error())
	}
	if owner != seller {
		panic("caller does not own this token")
	}

	marketAddr := cur.Address()
	if !isApproved(nft, seller, marketAddr, tid) {
		panic("marketplace is not approved to transfer this token — call Approve or SetApprovalForAll on the collection first")
	}

	key := listingKey(collectionID, tid)
	if listings.Has(key) {
		panic("already listed")
	}
	listings.Set(key, &market.Listing{
		CollectionID: collectionID,
		TokenID:      tid,
		Seller:       seller,
		Price:        price,
		CreatedAt:    runtime.ChainHeight(),
	})
	listingOrder = append(listingOrder, key)
}

// Cancel removes a listing. Only the original seller may cancel. Since the
// token was never escrowed, there's nothing to transfer back — this is
// pure bookkeeping. (A seller can equivalently just revoke the collection
// approval directly; Cancel exists so the marketplace's own listing state
// stays accurate without requiring that.)
func Cancel(cur realm, collectionID, tid string) {
	key := listingKey(collectionID, tid)
	l, ok := getListing(key)
	if !ok {
		panic("not listed")
	}
	if cur.Previous().Address() != l.Seller {
		panic("only the seller can cancel this listing")
	}
	listings.Remove(key)
	removeFromOrder(key)
}

// PruneStale removes a listing whose seller no longer passes the exact
// same check List/Buy themselves require — no longer owns the token, or
// has revoked the marketplace's approval. Unlike Cancel, ANYONE may call
// this, not just the seller: it can only ever succeed against a listing
// that a real Buy would already refuse (see Buy's own "listing is stale"
// panics), so there's no discretion to abuse and nothing a legitimate
// seller stands to lose. This exists because Cancel is deliberately
// seller-only — nobody else should be able to remove a listing that's
// still genuinely valid — which otherwise leaves a stale listing (sold or
// transferred elsewhere, off this marketplace) sitting in GetListingsPage
// forever unless that specific seller happens to notice and clean it up
// themselves. Letting anyone prune an OBJECTIVELY stale one means the
// listing set can self-clean as people browse, without weakening Cancel's
// own guarantee at all.
func PruneStale(cur realm, collectionID, tid string) {
	key := listingKey(collectionID, tid)
	l, ok := getListing(key)
	if !ok {
		panic("not listed")
	}
	nft := mustCollection(collectionID)
	owner, err := nft.OwnerOf(tid)
	if err != nil {
		panic(err.Error())
	}
	marketAddr := cur.Address()
	if owner == l.Seller && isApproved(nft, l.Seller, marketAddr, tid) {
		panic("listing is not stale")
	}
	listings.Remove(key)
	removeFromOrder(key)
}

// UpdatePrice changes the price of an existing listing. Only the seller may
// update it.
func UpdatePrice(cur realm, collectionID, tid string, newPrice int64) {
	if newPrice <= 0 {
		panic("price must be positive")
	}
	key := listingKey(collectionID, tid)
	l, ok := getListing(key)
	if !ok {
		panic("not listed")
	}
	if cur.Previous().Address() != l.Seller {
		panic("only the seller can update this listing")
	}
	l.Price = newPrice
}

// Buy purchases a listed token. The caller must send exactly the listing's
// price in ugnot with the transaction. Re-verifies the seller still owns
// the token and the marketplace is still approved (either could have
// changed since List, since nothing was ever escrowed) before moving
// anything — then moves the token straight from seller to buyer and
// splits payment between the seller and the fee recipient, atomically.
func Buy(cur realm, collectionID, tid string) {
	// Without this, an intermediary realm could call Buy on a user's behalf
	// and receive the token itself while funneling that user's ugnot as the
	// payment — AssertOriginCall keeps buyer identity and payment sender the
	// same account.
	runtime.AssertOriginCall()

	key := listingKey(collectionID, tid)
	l, ok := getListing(key)
	if !ok {
		panic("not listed")
	}
	buyer := cur.Previous().Address()
	if buyer == l.Seller {
		panic("cannot buy your own listing")
	}

	sent := unsafe.OriginSend()
	if len(sent) != 1 || sent[0].Denom != "ugnot" || sent[0].Amount != l.Price {
		panic(ufmt.Sprintf("payment must be exactly %d ugnot", l.Price))
	}

	nft := mustCollection(collectionID)
	owner, err := nft.OwnerOf(tid)
	if err != nil {
		panic(err.Error())
	}
	if owner != l.Seller {
		panic("seller no longer owns this token — listing is stale")
	}
	marketAddr := cur.Address()
	if !isApproved(nft, l.Seller, marketAddr, tid) {
		panic("seller has revoked the marketplace's approval — listing is stale")
	}

	// Effects before interactions.
	listings.Remove(key)
	removeFromOrder(key)

	if err := nft.TransferFrom(cross(cur), l.Seller, buyer, tid); err != nil {
		panic(err.Error())
	}

	fee := computeFee(l.Price)
	sellerProceeds := l.Price - fee
	stdBanker := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	if sellerProceeds > 0 {
		stdBanker.SendCoins(marketAddr, l.Seller, chain.Coins{{"ugnot", sellerProceeds}})
	}
	if fee > 0 {
		stdBanker.SendCoins(marketAddr, admin.Owner(), chain.Coins{{"ugnot", fee}})
	}
}

// GetListing returns a listing by collection and token ID.
func GetListing(collectionID, tid string) (market.Listing, bool) {
	l, ok := getListing(listingKey(collectionID, tid))
	if !ok {
		return market.Listing{}, false
	}
	return *l, true
}

// ListingsCount returns the number of active listings.
func ListingsCount() int {
	return len(listingOrder)
}

// GetListingsPage returns a page of active listings, one per line, oldest
// first: collectionID|tokenID|seller|price. Intended for frontends — plain
// pipe-delimited text is trivial to parse client-side without a JSON
// encoder. limit is clamped to [1, 100].
func GetListingsPage(offset, limit int) string {
	if limit <= 0 || limit > 100 {
		limit = 100
	}
	if offset < 0 || offset >= len(listingOrder) {
		return ""
	}
	end := offset + limit
	if end > len(listingOrder) {
		end = len(listingOrder)
	}
	out := ""
	for _, key := range listingOrder[offset:end] {
		l, ok := getListing(key)
		if !ok {
			continue
		}
		out += l.CollectionID + "|" + l.TokenID + "|" + l.Seller.String() + "|" + strconv.Itoa(int(l.Price)) + "\n"
	}
	return out
}

// TokenInfo queries a registered collection's own adapter for display info
// about one of its tokens — for render/frontend use, not part of the trade
// flow itself.
func TokenInfo(collectionID, tid string) (name string, tokenURI string, owner address) {
	nft := mustCollection(collectionID)
	name = nft.Name()
	tokenURI, _ = nft.TokenURI(tid)
	owner, _ = nft.OwnerOf(tid)
	return
}
