// Package reader is the batch JSON read API for the frontend and the
// aggregator (design §2.5.6). It is private (re-deployable in place, no
// other realm may import it) and holds no state or money: everything comes
// from core, market and r/sys/users.
//
// Every string goes out through safe.JSONWriter, so stored text can never
// forge a record (RA H-1: the old TSV reader split on tabs and newlines).
// Art is never batched: one token per Art call, because SVG rendering is
// what exhausted the query gas in nftread1 (RA L-9).
package reader

import (
	"gno.land/r/sys/users"

	"gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia/engine/v1"
	"gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia/safe/v1"
	"gno.land/r/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia3/core"
	upload "gno.land/r/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia3/engines/upload"
	market "gno.land/r/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia3/market/v1"
)

// Batch limits. Hypothesis (S-4): sized for the genesis engine under the
// public qeval gas cap; measure on Onyx and lower if a full page runs out.
const (
	MaxCards       = 50
	MaxTraitCounts = 500
	MaxStudio      = 200
	// Uploaded collections carry the creator's real trait names (up to 8 types
	// of 32 bytes); pages are smaller so the worst store the asset limits allow
	// stays <= 1B test gas per read (review UP-M1, zz_worst_gas_test.gno).
	MaxUploadCards       = 20
	MaxUploadTraitCounts = 200
)

// Cards is one gallery page: [{tid, owner, ownerName, traits, listing}] for
// tokens offset+1 … offset+limit (limit <= 50; <= 20 for uploaded
// collections). Burned tokens are skipped; listing is
// {id, price} or null. Uploaded collections carry the creator's real trait
// names (upload.TraitLists, one permutation key per page) instead of core's
// fixed engine slots.
func Cards(cid string, offset, limit int64) string {
	info := core.Info(cid)
	var upTraits map[string]string
	max := int64(MaxCards)
	if info.EngineID == upload.SelfPath() {
		max = MaxUploadCards
		upTraits = uploadTraits(cid, offset, clamp(limit, max))
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
		if upTraits != nil {
			w.Raw(upTraits[tid]) // JSON escaped once by the store (upload.TraitJSONLists)
		} else {
			writeTraits(w, core.TokenTraitList(cid, tid))
		}
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
// <= 200 for uploaded collections). Rarity % for a 1000-token collection
// takes two calls (five for an uploaded one). Before Final every token reports
// Status=Unrevealed.
func TraitCounts(cid string, offset, limit int64) string {
	info := core.Info(cid)
	c := newCounter()
	if info.EngineID == upload.SelfPath() {
		// creator-assigned tiers and real trait names, counted by the store
		// over integer ids (burned tokens skipped; order: Tier, the creator's
		// types, Edition, Storage)
		return upload.TraitCounts(cid, offset, clamp(limit, MaxUploadTraitCounts))
	}
	for _, tid := range tokenRange(info.Minted, offset, limit, MaxTraitCounts) {
		if _, err := core.OwnerOf(cid, tid); err != nil {
			continue
		}
		c.add(core.TokenTraitList(cid, tid))
	}
	return c.json()
}

// StudioTraits is TraitCounts for an engine and params over n sample seeds
// (engine.SampleSeed(from) …), for the Studio's rarity preview.
func StudioTraits(engineID, params string, from, n int64) string {
	if n <= 0 || n > MaxStudio {
		n = MaxStudio
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

// Art is one token's data URI (placeholder before Final).
func Art(cid, tid string) string {
	uri, err := core.TokenURI(cid, tid)
	if err != nil {
		panic(err)
	}
	return uri
}

func Collections(offset, limit int64) string { return core.Collections(offset, limit) }

// SetComposition passes upload.SetComposition through: slots per
// creator-assigned tier and trait value over an uploaded collection's set.
func SetComposition(cid string) string { return upload.SetComposition(cid) }

// UploadStatus passes upload.Status through (mint gating, storage badge).
func UploadStatus(cid string) string { return upload.Status(cid) }

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

func uploadTraits(cid string, offset, limit int64) map[string]string {
	tids, lists := upload.TraitJSONLists(cid, offset, limit)
	out := make(map[string]string, len(tids))
	for i, tid := range tids {
		out[tid] = lists[i]
	}
	return out
}

func clamp(limit, max int64) int64 {
	if limit <= 0 || limit > max {
		return max
	}
	return limit
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
	values map[string][]string       // type -> values in first-seen order
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
