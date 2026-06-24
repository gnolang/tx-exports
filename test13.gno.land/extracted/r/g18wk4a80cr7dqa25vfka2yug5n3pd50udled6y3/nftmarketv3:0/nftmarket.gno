// Package nftmarket is a multi-collection NFT marketplace realm for gno.land,
// in the spirit of OpenSea but built for GnoVM.
//
// It bundles three capabilities in a single realm:
//
//  1. Collection factory — any user can create their own NFT collection with
//     CreateCollection and becomes its creator (royalty + mint-proceeds
//     recipient).
//  2. Open minting — any user can mint a token from any collection with Mint,
//     paying the collection's mint price (which goes to the creator).
//  3. Marketplace — a token owner lists an NFT for a fixed price with List,
//     and anyone buys it with Buy. The sale price is split between the seller,
//     the collection creator (royalty) and the platform (fee).
//
// Why one realm instead of separate "nft" and "market" realms?
// In gno.land's GRC721 design, only the realm that holds the concrete
// *grc721.BasicNFT may move its tokens — across a realm boundary it exposes a
// read-only view (see p/demo/tokens/grc721/igrc721.gno). Keeping minting and
// the market in the same realm lets the market escrow and transfer sold NFTs
// internally, without fragile cross-realm approvals.
//
// Payments use the native coin (ugnot). Buyers and minters attach coins to the
// call (gnokey ... -send "<amount>ugnot"); the realm escrows them and pays the
// recipients out via the banker. All amounts are in ugnot (1 GNOT = 1_000_000
// ugnot).
package nftmarket

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"

	"gno.land/p/g18wk4a80cr7dqa25vfka2yug5n3pd50udled6y3/grc721"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
)

const (
	ugnot = "ugnot"

	// bpsDenominator is the basis-points denominator (10000 bps = 100%).
	bpsDenominator = 10000

	// maxRoyaltyBps caps a collection's secondary-sale royalty at 50%.
	maxRoyaltyBps = 5000

	// maxFeeBps caps the platform fee at 10%.
	maxFeeBps = 1000

	// maxSlugLen bounds a collection id.
	maxSlugLen = 40
)

var zeroAddr address // the empty/invalid address

// Collection is one NFT collection created by a user.
type Collection struct {
	id         string  // unique slug, e.g. "cryptopunks"
	name       string  // human-readable name
	symbol     string  // ticker, <= 11 chars of [A-Za-z0-9_-]
	creator    address // receives mint proceeds and royalties
	baseURI    string  // metadata base; tokenURI = baseURI + tokenID
	mintPrice  int64   // ugnot charged per mint (0 = free), paid to creator
	maxSupply  int64   // hard cap (0 = unlimited)
	royaltyBps int64   // creator royalty on secondary sales, in bps
	minted     int64   // number minted so far; the next token id is minted+1
	burned     int64   // number of tokens burned
	sealed     bool    // when true, no further minting (supply capped at minted)
	createdAt  int64   // block height at creation
	nft        *grc721.BasicNFT
}

// Listing is an active fixed-price sale. While listed, the NFT is escrowed in
// the realm's own account (its on-chain owner is the realm address).
type Listing struct {
	collID    string
	tokenID   string
	seller    address
	price     int64 // ugnot
	createdAt int64 // block height
}

var (
	collections avl.Tree // collID -> *Collection
	listings    avl.Tree // "collID/tokenID" -> *Listing
	collOrder   []string // collection ids in creation order, for rendering

	admin  address       // platform admin; empty until ClaimAdmin is called
	feeBps int64   = 250 // platform fee on secondary sales (2.5%)
	feePot int64         // ugnot collected as fees, withdrawable by admin
)

// --- collection factory -----------------------------------------------------

// CreateCollection registers a new NFT collection owned by the caller and
// returns its id. mintPrice and maxSupply may be 0 (free / unlimited).
// royaltyBps is the creator's cut of every future secondary sale (0..5000).
func CreateCollection(cur realm, id, name, symbol, baseURI string, mintPrice, maxSupply, royaltyBps int64) string {
	assertUserCall(cur)
	creator := cur.Previous().Address()

	if !validSlug(id) {
		panic("collection id must be 1-40 chars of [a-z0-9-]")
	}
	if _, exists := collections.Get(id); exists {
		panic("collection id already taken: " + id)
	}
	if mintPrice < 0 {
		panic("mintPrice cannot be negative")
	}
	if maxSupply < 0 {
		panic("maxSupply cannot be negative")
	}
	if royaltyBps < 0 || royaltyBps > maxRoyaltyBps {
		panic(ufmt.Sprintf("royaltyBps must be between 0 and %d", maxRoyaltyBps))
	}

	// NewBasicNFT validates name/symbol and panics on invalid input.
	nft := grc721.NewBasicNFT(0, cur, name, symbol)

	collections.Set(id, &Collection{
		id:         id,
		name:       name,
		symbol:     symbol,
		creator:    creator,
		baseURI:    baseURI,
		mintPrice:  mintPrice,
		maxSupply:  maxSupply,
		royaltyBps: royaltyBps,
		minted:     0,
		createdAt:  runtime.ChainHeight(),
		nft:        nft,
	})
	collOrder = append(collOrder, id)

	chain.Emit("CreateCollection", "id", id, "creator", creator.String(), "symbol", symbol)
	return id
}

// Mint mints the next token of a collection to the caller, who must attach
// exactly the collection's mint price in ugnot. The proceeds go to the
// collection creator. Returns the newly minted token id.
func Mint(cur realm, collID string) string {
	assertUserCall(cur)
	coll := mustGetCollection(collID)
	minter := cur.Previous().Address()

	if coll.maxSupply > 0 && coll.minted >= coll.maxSupply {
		panic("collection is sold out")
	}

	paid := receivedUgnot()
	if paid != coll.mintPrice {
		panic(ufmt.Sprintf("must send exactly %d ugnot to mint (sent %d)", coll.mintPrice, paid))
	}

	tokenID := strconv.FormatInt(coll.minted+1, 10)
	if err := coll.nft.Mint(minter, grc721.TokenID(tokenID)); err != nil {
		panic(err)
	}
	coll.minted++

	// Primary sale: the creator receives the full mint price.
	payout(cur, coll.creator, paid)

	chain.Emit("Mint", "collection", collID, "tokenId", tokenID, "minter", minter.String())
	return tokenID
}

// --- shared helpers ---------------------------------------------------------

// assertUserCall rejects non-EOA callers. unsafe.OriginSend() only describes a
// real receipt at this realm when the caller is a pure user (maketx call);
// an intermediate code realm or `maketx run` envelope could otherwise make the
// realm pay out its own pre-existing balance. See r/demo/disperse.
func assertUserCall(cur realm) {
	if !cur.Previous().IsUserCall() {
		panic("only direct user calls (gnokey maketx call) are accepted")
	}
}

// receivedUgnot returns the amount of ugnot attached to the current call and
// rejects any other denomination.
func receivedUgnot() int64 {
	sent := unsafe.OriginSend()
	for _, c := range sent {
		if c.Denom != ugnot {
			panic("only ugnot is accepted as payment")
		}
	}
	return sent.AmountOf(ugnot)
}

// payout sends amount ugnot from the realm's escrow to addr. No-op for amount<=0.
func payout(cur realm, addr address, amount int64) {
	if amount <= 0 {
		return
	}
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	b.SendCoins(cur.Address(), addr, chain.Coins{chain.NewCoin(ugnot, amount)})
}

func mustGetCollection(id string) *Collection {
	v, ok := collections.Get(id)
	if !ok {
		panic("collection not found: " + id)
	}
	return v.(*Collection)
}

func listingKey(collID, tokenID string) string { return collID + "/" + tokenID }

func getListing(collID, tokenID string) (*Listing, bool) {
	v, ok := listings.Get(listingKey(collID, tokenID))
	if !ok {
		return nil, false
	}
	return v.(*Listing), true
}

// now returns the current block height, used to timestamp records.
func now() int64 { return runtime.ChainHeight() }

// validSlug reports whether s is a valid collection id: 1..maxSlugLen chars of
// lowercase letters, digits and hyphens.
func validSlug(s string) bool {
	if len(s) == 0 || len(s) > maxSlugLen {
		return false
	}
	for _, c := range s {
		if !((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-') {
			return false
		}
	}
	return true
}
