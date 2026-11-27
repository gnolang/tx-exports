// Package reader is the batch JSON read API for the frontend and the
// aggregator (design §2.5.6). It is private (re-deployable in place, no
// other realm may import it) and holds no state or money: everything comes
// from core, market and r/sys/users.
//
// sinopia4 (mainnet plan M-30): art, traits and metadata are read through
// core only — core serves media engines' files and per-collection trait
// names — so the reader imports no engine or upload realm and ships in the
// first package wave. Upload-only views (drop table, readiness, storage
// badge) are read by the frontend from the upload adapter itself.
//
// Every string goes out through safe.JSONWriter, so stored text can never
// forge a record (RA H-1: the old TSV reader split on tabs and newlines).
// Art is never batched: one token per Art call, because SVG rendering is
// what exhausted the query gas in nftread1 (RA L-9).
package reader

import (
	"strings"

	"gno.land/r/sys/users"

	"gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia4/engine/v2"
	"gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia4/safe/v2"
	"gno.land/r/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia4/core"
	market "gno.land/r/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia4/market/v1"
)

// Batch limits. Hypothesis (S-4): sized for the genesis engine under the
// public qeval gas cap; measure on Onyx and lower if a full page runs out.
const (
	MaxCards       = 50
	MaxTraitCounts = 500
	MaxStudio      = 200
	// Collections of media engines (uploads: the creator's real trait names,
	// up to 8 types of 20 bytes and values of 32, read per token through
	// core since sinopia4, M-30) get smaller pages. assets/v1 refuses
	// < > & " \ in stored text (WP-Z), so core's JSON escaping of upload
	// traits stays cheap; what remains is the per-token fetch through core
	// (adapter Traits + ValidateTraitsFor, ~11M per token on the worst
	// store). Worst store (zz_worst_gas_test.gno, run wpz-1): Cards(20)
	// 629M, TraitCounts(50) 658M (100: 1.18B, 200: 2.26B). The site counts
	// rarity from Cards pages of 20 (frontend realms.live traitCounts). The
	// reader is re-deployable in place.
	MaxUploadCards       = 20
	MaxUploadTraitCounts = 50
	// Studio rarity over a Katman store kit: each sample's traits read up
	// to 8 SlotArtwork + ArtworkMeta from the store (~17.3M on the largest
	// kit, docs/engines/katman.md), so 200 samples would be ~4B.
	MaxKitStudio = 50
)

// kitEngine is the Katman adapter (engines/katman next to this reader,
// derived from this realm's own path so staging needs no rewrite). Its
// collections read their traits from an assets/v1 store per token
// (~17.3M per token on the largest kit, ~1-2M for generative engines):
// TraitCounts(500) would be ~8.7B, over the 3B query cap, so they get the
// media page sizes (Cards 20, TraitCounts 50: <= ~0.9B). It is an svg
// engine, so isMedia alone does not catch it.
var kitEngine string

func init(cur realm) {
	kitEngine = strings.TrimSuffix(cur.PkgPath(), "/reader") + "/engines/katman"
}

// Cards is one gallery page: [{tid, owner, ownerName, traits, listing}] for
// tokens offset+1 … offset+limit (limit <= 50; <= 20 for collections of
// media engines and of the Katman kit engine). Burned tokens are skipped; listing is {id, price} or
// null. Traits are core.TokenTraitList: checked against the collection's own
// trait list (an upload's real trait names, sinopia4 M-6).
func Cards(cid string, offset, limit int64) string {
	info := core.Info(cid)
	max := int64(MaxCards)
	if smallPages(info.EngineID) {
		max = MaxUploadCards
	}
	w := &safe.JSONWriter{}
	w.BeginArray()
	for _, tid := range tokenRange(info.Minted, offset, limit, max) {
		owner, err := core.OwnerOf(cid, tid)
		if err != nil {
			continue // burned
		}
		w.BeginObject()
		w.StrField("tid", tid)
		w.StrField("owner", owner.String())
		w.StrField("ownerName", nameOf(owner))
		w.Key("traits")
		writeTraits(w, core.TokenTraitList(cid, tid))
		w.Key("listing")
		if id, price, ok := market.ActiveListing(cid, tid); ok {
			w.BeginObject()
			w.StrField("id", id)
			w.IntField("price", price)
			w.EndObject()
		} else {
			w.Raw("null")
		}
		w.EndObject()
	}
	w.EndArray()
	return w.String()
}

// TraitCounts counts trait values over tokens offset+1 … offset+limit:
// {"n": tokens counted, "counts": {type: {value: count}}} (limit <= 500;
// <= 50 for collections of media engines and of the Katman kit engine). Rarity % for a 1000-token
// collection takes two calls (twenty for an upload). Before Final every token
// reports Status=Unrevealed. Types and values in first-seen order.
func TraitCounts(cid string, offset, limit int64) string {
	info := core.Info(cid)
	c := newCounter()
	max := int64(MaxTraitCounts)
	if smallPages(info.EngineID) {
		max = MaxUploadTraitCounts
	}
	for _, tid := range tokenRange(info.Minted, offset, limit, max) {
		if _, err := core.OwnerOf(cid, tid); err != nil {
			continue
		}
		c.add(core.TokenTraitList(cid, tid))
	}
	return c.json()
}

// StudioTraits is TraitCounts for an engine and params over n sample seeds
// (engine.SampleSeed(from) …), for the Studio's rarity preview (n <= 200;
// <= 50 for the Katman kit engine).
func StudioTraits(engineID, params string, from, n int64) string {
	max := int64(MaxStudio)
	if engineID == kitEngine {
		max = MaxKitStudio
	}
	if n <= 0 || n > max {
		n = max
	}
	if from < 0 {
		from = 0
	}
	c := newCounter()
	for i := from; i < from+n; i++ {
		c.add(core.EngineTraits(engineID, params, engine.SampleSeed(int(i))))
	}
	return c.json()
}

// Art is one token's core.TokenURI (placeholder before Final): an SVG or
// raster data URI, or the "ipfs://<CIDv1>" of an IPFS-stored file (I-15).
func Art(cid, tid string) string {
	uri, err := core.TokenURI(cid, tid)
	if err != nil {
		panic(err)
	}
	return uri
}

// Card is one token's checked SVG card data URI (core.TokenCard): the art
// of an SVG engine, the certificate card of a media engine; never remote.
func Card(cid, tid string) string {
	uri, err := core.TokenCard(cid, tid)
	if err != nil {
		panic(err)
	}
	return uri
}

func Collections(offset, limit int64) string { return core.Collections(offset, limit) }

// Profile is {address, name, collections} for one address. A seller's
// listings come from the indexer (market "Listed"/"Cancelled" events):
// market/v1 keeps no per-seller index on chain (storage, M2).
func Profile(addr address) string {
	w := &safe.JSONWriter{}
	w.BeginObject()
	w.StrField("address", addr.String())
	w.StrField("name", nameOf(addr))
	w.Key("collections")
	w.Raw(core.CollectionsByCreator(addr, 0, MaxCards))
	w.EndObject()
	return w.String()
}

// --- helpers -----------------------------------------------------------------

// nameOf is the r/sys/users name of addr, or "".
func nameOf(addr address) string {
	if u := users.ResolveAddress(addr); u != nil {
		return u.Name()
	}
	return ""
}

// smallPages: collections whose per-token traits are expensive (media
// engines, the Katman kit engine) get the small page sizes.
func smallPages(engineID string) bool {
	return engineID == kitEngine || isMedia(engineID)
}

// isMedia: the collection's engine serves files (engine/v2 KindMedia).
func isMedia(engineID string) bool {
	return core.EngineManifest(engineID).Kind == engine.KindMedia
}

func tokenRange(minted, offset, limit, max int64) []string {
	if limit <= 0 || limit > max {
		limit = max
	}
	if offset < 0 {
		offset = 0
	}
	var out []string
	for n := offset + 1; n <= minted && n <= offset+limit; n++ {
		out = append(out, itoa(n))
	}
	return out
}

func writeTraits(w *safe.JSONWriter, ts []engine.Trait) {
	w.BeginArray()
	for _, t := range ts {
		w.BeginObject()
		w.StrField("trait_type", t.Type)
		w.StrField("value", t.Value)
		w.EndObject()
	}
	w.EndArray()
}

// counter keeps first-seen order so the JSON is deterministic.
type counter struct {
	n      int64
	types  []string
	values map[string][]string         // type -> values in first-seen order
	counts map[string]map[string]int64 // type -> value -> count
}

func newCounter() *counter {
	return &counter{values: map[string][]string{}, counts: map[string]map[string]int64{}}
}

func (c *counter) add(ts []engine.Trait) {
	c.n++
	for _, t := range ts {
		byValue, ok := c.counts[t.Type]
		if !ok {
			byValue = map[string]int64{}
			c.counts[t.Type] = byValue
			c.types = append(c.types, t.Type)
		}
		if _, seen := byValue[t.Value]; !seen {
			c.values[t.Type] = append(c.values[t.Type], t.Value)
		}
		byValue[t.Value]++
	}
}

func (c *counter) json() string {
	w := &safe.JSONWriter{}
	w.BeginObject()
	w.IntField("n", c.n)
	w.Key("counts")
	w.BeginObject()
	for _, typ := range c.types {
		w.Key(typ)
		w.BeginObject()
		for _, v := range c.values[typ] {
			w.IntField(v, c.counts[typ][v])
		}
		w.EndObject()
	}
	w.EndObject()
	w.EndObject()
	return w.String()
}

func itoa(n int64) string { return safe.PadInt(n, 1) }
