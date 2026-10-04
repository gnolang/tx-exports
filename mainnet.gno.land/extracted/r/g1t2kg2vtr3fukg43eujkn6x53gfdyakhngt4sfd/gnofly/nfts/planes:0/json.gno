package planes

import (
	"strings"

	"gno.land/p/onbloc/json/v0"
)

// The JSON documents are built with gno.land/p/onbloc/json/v0, which quotes
// every string. Keys come out in the order they are written: a gno map
// iterates in insertion order, and the library keeps an object's members in
// one. Numbers are float64 in the library and printed without exponent or
// decimal point when whole, which every number here is, far under 2^53.

// PlaneJSON returns one plane as a JSON object, minted or not:
//
//	{ "id": 42, "name": "Storm Saint", "model": "delta", "pilot": "gnome",
//	  "body": "#1e1b4b", "wing": "#1e293b", "accent": "#00f5ff", "tier": "epic",
//	  "laser": "#39ff14", "image": "https://gnofly.xyz/nft/collections/planes/042.png", "owner": "g1..." }
//
// The output has no whitespace. "owner" is "" for a plane not minted, or
// burned. An id outside 1 to 777 returns "". Which plane a pilot flies is
// not on-chain: the game server checks the owner when a pilot picks one.
func PlaneJSON(id int64) string {
	p, ok := getPlane(id)
	if !ok {
		return ""
	}
	b := json.Builder()
	writePlane(b, p)
	b.WriteString("image", imageURL(id))
	b.WriteString("owner", ownerOf(id).String())
	return encode(b.Node())
}

// PlanesOf returns the ids of the planes addr owns as a JSON array, in
// ascending order: [3,42,700]. It is [] for an address without planes.
func PlanesOf(addr address) string {
	ids := []*json.Node{}
	if n, err := Token.BalanceOf(addr); err == nil && n > 0 {
		// Ids are dense, 1 to 777: a scan that stops at the last plane of
		// addr is cheaper than keeping a list per owner up to date at every
		// mint and transfer.
		for id := int64(1); id <= supply && int64(len(ids)) < n; id++ {
			if ownerOf(id) == addr {
				ids = append(ids, json.NumberNode("", float64(id)))
			}
		}
	}
	return encode(json.ArrayNode("", ids))
}

// maxMintedPage is the most ids MintedJSON looks at in one call.
const maxMintedPage = int64(200)

// MintedJSON returns who owns the minted planes among the ids offset+1 to
// offset+limit, as a JSON array in id order:
//
//	[{"id":3,"owner":"g1..."},{"id":42,"owner":""},...]
//
// Ids not minted are left out; "owner" is "" for a burned plane. limit is
// capped at 200, so four calls (offsets 0, 200, 400, 600) cover the 777,
// whatever was minted: planes are drawn at random, minted ids are not a
// prefix. It is what the website's grid reads. An empty range is [].
func MintedJSON(offset, limit int64) string {
	if limit > maxMintedPage {
		limit = maxMintedPage
	}
	entries := []*json.Node{}
	if offset >= 0 && limit > 0 {
		last := offset + limit
		if last > supply {
			last = supply
		}
		for id := offset + 1; id <= last; id++ {
			if !wasMinted(id) {
				continue
			}
			entry := json.Builder().
				WriteNumber("id", float64(id)).
				WriteString("owner", ownerOf(id).String())
			entries = append(entries, entry.Node())
		}
	}
	return encode(json.ArrayNode("", entries))
}

// CollectionJSON returns the state of the collection as one JSON object:
//
//	{ "name": "gnofly planes", "symbol": "PLANE",
//	  "supply": 777, "minted": 12, "burned": 0,
//	  "price": 77000000, "open": true, "cap": 7,
//	  "royaltyBps": 500, "treasury": "g1...",
//	  "imageBase": "https://gnofly.xyz/nft/collections/planes/",
//	  "tiers": { "common": { "supply": 500, "minted": 8 },
//	             "rare": { "supply": 200, "minted": 3 },
//	             "epic": { "supply": 70, "minted": 1 },
//	             "legendary": { "supply": 7, "minted": 0 } } }
//
// The output has no whitespace. "minted" counts every mint so far, burned
// planes included; "minted" minus "burned" is what exists.
func CollectionJSON() string {
	b := json.Builder().
		WriteString("name", tokenName).
		WriteString("symbol", tokenSymbol).
		WriteNumber("supply", float64(supply)).
		WriteNumber("minted", float64(Minted())).
		WriteNumber("burned", float64(Minted()-Token.TotalSupply())).
		WriteNumber("price", float64(price)).
		WriteBool("open", mintOpen).
		WriteNumber("cap", float64(mintCap)).
		WriteNumber("royaltyBps", float64(RoyaltyBps())).
		WriteString("treasury", roles.Treasury().String()).
		WriteString("imageBase", imageBase).
		WriteObject("tiers", func(tb *json.NodeBuilder) {
			for i, tier := range strings.Split(tiers, ",") {
				tb.WriteObject(tier, func(t *json.NodeBuilder) {
					t.WriteNumber("supply", float64(tierSupply[i]))
					t.WriteNumber("minted", float64(tierMinted[i]))
				})
			}
		})
	return encode(b.Node())
}

// writePlane writes the nine fields of a plane, in the order of a row, so
// that a caller can add fields after them.
func writePlane(b *json.NodeBuilder, p plane) {
	b.WriteNumber("id", float64(p.id)).
		WriteString("name", p.name).
		WriteString("model", p.model).
		WriteString("pilot", p.pilot).
		WriteString("body", p.body).
		WriteString("wing", p.wing).
		WriteString("accent", p.accent).
		WriteString("tier", p.tier).
		WriteString("laser", p.laser)
}

// encode marshals a document built above. It cannot fail on a document
// built from the builder, so a failure is a bug and panics.
func encode(n *json.Node) string {
	out, err := json.Marshal(n)
	if err != nil {
		panic(err)
	}
	return string(out)
}
