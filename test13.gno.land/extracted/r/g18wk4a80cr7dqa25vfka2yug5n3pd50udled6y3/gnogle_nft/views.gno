package gnogle_nft

import (
	"strconv"
	"strings"

	"gno.land/p/g18wk4a80cr7dqa25vfka2yug5n3pd50udled6y3/grc721"
	"gno.land/p/nt/ufmt/v0"
)

// OwnerOf returns the owner of a token, or the zero address if it does not exist.
func OwnerOf(collID, tokenID string) address {
	coll, ok := getCollection(collID)
	if !ok {
		return zeroAddr
	}
	o, err := coll.nft.OwnerOf(grc721.TokenID(tokenID))
	if err != nil {
		return zeroAddr
	}
	return o
}

// TokenURI returns baseURI + tokenID.
func TokenURI(collID, tokenID string) string {
	coll, ok := getCollection(collID)
	if !ok {
		return ""
	}
	return coll.baseURI + tokenID
}

// CollectionRoyalty returns (creator, royaltyBps) — used by the market realm to
// split secondary-sale proceeds.
func CollectionRoyalty(collID string) (address, int64) {
	coll := mustGetCollection(collID)
	return coll.creator, coll.royaltyBps
}

// CollectionMinted returns how many tokens have been minted (token ids 1..N).
func CollectionMinted(collID string) int64 {
	coll := mustGetCollection(collID)
	return coll.minted
}

// Exists reports whether a token currently exists (not burned).
func Exists(collID, tokenID string) bool {
	return OwnerOf(collID, tokenID) != zeroAddr
}

// CollectionsJSON returns every collection as JSON (for front-ends).
func CollectionsJSON() string {
	var b strings.Builder
	b.WriteString("[")
	for i, id := range collOrder {
		v, ok := collections.Get(id)
		if !ok {
			continue
		}
		c := v.(*Collection)
		if i > 0 {
			b.WriteString(",")
		}
		b.WriteString(ufmt.Sprintf(
			`{"id":%s,"name":%s,"symbol":%s,"creator":%s,"baseURI":%s,"mintPrice":%d,"maxSupply":%d,"minted":%d,"burned":%d,"royaltyBps":%d,"sealed":%s,"verified":%s}`,
			js(c.id), js(c.name), js(c.symbol), js(c.creator.String()), js(c.baseURI),
			c.mintPrice, c.maxSupply, c.minted, c.burned, c.royaltyBps, jb(c.sealed), jb(c.verified)))
	}
	b.WriteString("]")
	return b.String()
}

// TokensJSON returns each minted token's id + owner. Market state (listings,
// auctions) lives in the market realm; the front-end joins the two.
func TokensJSON(collID string) string {
	coll := mustGetCollection(collID)
	var b strings.Builder
	b.WriteString("[")
	first := true
	for i := int64(1); i <= coll.minted; i++ {
		tokenID := strconv.FormatInt(i, 10)
		owner, err := coll.nft.OwnerOf(grc721.TokenID(tokenID))
		if err != nil {
			continue
		}
		if !first {
			b.WriteString(",")
		}
		first = false
		b.WriteString(ufmt.Sprintf(`{"id":%s,"owner":%s}`, js(tokenID), js(owner.String())))
	}
	b.WriteString("]")
	return b.String()
}

func js(s string) string {
	var b strings.Builder
	b.WriteString(`"`)
	for _, r := range s {
		switch r {
		case '"':
			b.WriteString(`\"`)
		case '\\':
			b.WriteString(`\\`)
		case '\n':
			b.WriteString(`\n`)
		case '\r':
			b.WriteString(`\r`)
		case '\t':
			b.WriteString(`\t`)
		default:
			b.WriteString(string(r))
		}
	}
	b.WriteString(`"`)
	return b.String()
}

func jb(v bool) string {
	if v {
		return "true"
	}
	return "false"
}
