// Package gnogle_nft is the NFT layer of the GNOGLE marketplace: a stable,
// upgrade-independent realm that stores every collection and token (GRC721).
//
// The marketplace LOGIC lives in a SEPARATE realm (gnogle_market). It never
// holds tokens — instead an owner grants it operator approval (SetApprovalForAll)
// and the market moves tokens by calling TransferFrom here. Because the tokens
// live in THIS realm, the market can be redeployed/upgraded any number of times
// without affecting a single NFT.
package gnogle_nft2

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
	ugnot          = "ugnot"
	bpsDenominator = 10000
	maxRoyaltyBps  = 5000
	maxSlugLen     = 40
)

var zeroAddr address

// Collection is one NFT collection. The concrete *grc721.BasicNFT is held in an
// unexported field, so only this realm can mutate token ownership.
type Collection struct {
	id         string
	name       string
	symbol     string
	creator    address
	baseURI    string
	mintPrice  int64
	maxSupply  int64
	royaltyBps int64
	minted     int64
	burned     int64
	sealed     bool
	verified   bool
	createdAt  int64
	nft        *grc721.BasicNFT
}

var (
	collections avl.Tree // id -> *Collection
	collOrder   []string
	admin       address
)

// CreateCollection registers a new collection owned by the caller.
func CreateCollection(cur realm, id, name, symbol, baseURI string, mintPrice, maxSupply, royaltyBps int64) string {
	assertUserCall(cur)
	creator := cur.Previous().Address()
	if !validSlug(id) {
		panic("collection id must be 1-40 chars of [a-z0-9-]")
	}
	if _, ok := collections.Get(id); ok {
		panic("collection id already taken: " + id)
	}
	if mintPrice < 0 || maxSupply < 0 {
		panic("mintPrice/maxSupply cannot be negative")
	}
	if royaltyBps < 0 || royaltyBps > maxRoyaltyBps {
		panic(ufmt.Sprintf("royaltyBps must be 0..%d", maxRoyaltyBps))
	}
	nft := grc721.NewBasicNFT(0, cur, name, symbol)
	collections.Set(id, &Collection{
		id: id, name: name, symbol: symbol, creator: creator, baseURI: baseURI,
		mintPrice: mintPrice, maxSupply: maxSupply, royaltyBps: royaltyBps,
		createdAt: runtime.ChainHeight(), nft: nft,
	})
	collOrder = append(collOrder, id)
	chain.Emit("CreateCollection", "id", id, "creator", creator.String())
	return id
}

// Mint mints the next token of a collection to the caller, who must attach the
// mint price in ugnot (paid to the creator).
func Mint(cur realm, collID string) string {
	assertUserCall(cur)
	coll := mustGetCollection(collID)
	minter := cur.Previous().Address()
	paid := receivedUgnot()
	if paid != coll.mintPrice {
		panic(ufmt.Sprintf("must send exactly %d ugnot to mint (sent %d)", coll.mintPrice, paid))
	}
	tokenID := mintOne(coll, minter)
	payCreator(cur, coll.creator, paid)
	chain.Emit("Mint", "collection", collID, "tokenId", tokenID, "minter", minter.String())
	return tokenID
}

// MintBatch mints count (1..20) tokens to the caller, charging count × mint price.
func MintBatch(cur realm, collID string, count int64) string {
	assertUserCall(cur)
	if count <= 0 || count > 20 {
		panic("count must be between 1 and 20")
	}
	coll := mustGetCollection(collID)
	minter := cur.Previous().Address()
	paid := receivedUgnot()
	if paid != coll.mintPrice*count {
		panic(ufmt.Sprintf("must send exactly %d ugnot for %d mints", coll.mintPrice*count, count))
	}
	first := ""
	for i := int64(0); i < count; i++ {
		if tid := mintOne(coll, minter); first == "" {
			first = tid
		}
	}
	payCreator(cur, coll.creator, paid)
	chain.Emit("MintBatch", "collection", collID, "count", strconv.FormatInt(count, 10), "minter", minter.String())
	return first
}

func mintOne(coll *Collection, minter address) string {
	if coll.maxSupply > 0 && coll.minted >= coll.maxSupply {
		panic("collection is sold out")
	}
	tokenID := strconv.FormatInt(coll.minted+1, 10)
	if err := coll.nft.Mint(minter, grc721.TokenID(tokenID)); err != nil {
		panic(err)
	}
	coll.minted++
	return tokenID
}

// --- admin (verified badge only) -------------------------------------------

// ClaimAdmin assigns the admin (one-time). Admin can only flag collections verified.
func ClaimAdmin(cur realm) {
	if admin != zeroAddr {
		panic("admin already claimed")
	}
	admin = cur.Previous().Address()
	chain.Emit("ClaimAdmin", "admin", admin.String())
}

func assertAdmin(cur realm) {
	if admin == zeroAddr {
		panic("admin not set; call ClaimAdmin first")
	}
	if cur.Previous().Address() != admin {
		panic("unauthorized: admin only")
	}
}

// --- helpers ---------------------------------------------------------------

func assertUserCall(cur realm) {
	if !cur.Previous().IsUserCall() {
		panic("only direct user calls are accepted")
	}
}

func receivedUgnot() int64 {
	sent := unsafe.OriginSend()
	for _, c := range sent {
		if c.Denom != ugnot {
			panic("only ugnot is accepted")
		}
	}
	return sent.AmountOf(ugnot)
}

func payCreator(cur realm, to address, amount int64) {
	if amount <= 0 {
		return
	}
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	b.SendCoins(cur.Address(), to, chain.Coins{chain.NewCoin(ugnot, amount)})
}

func mustGetCollection(id string) *Collection {
	v, ok := collections.Get(id)
	if !ok {
		panic("collection not found: " + id)
	}
	return v.(*Collection)
}

func getCollection(id string) (*Collection, bool) {
	v, ok := collections.Get(id)
	if !ok {
		return nil, false
	}
	return v.(*Collection), true
}

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
