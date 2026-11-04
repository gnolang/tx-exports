package upload

import (
	"errors"
	"strconv"
	"strings"

	"gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia/engine/v1"
	"gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia/media/v1"
	"gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia/safe/v1"
	"gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia/types/v1"
	assets "gno.land/r/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia3/assets/v1"
	"gno.land/r/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia3/core"
)

// Every function in this file is read-only. Every token read returns core's
// placeholder / "Unrevealed" before the collection is Final (T5).

// Readiness reasons (Status.reason).
const (
	ReasonNotUpload      = "not-upload"
	ReasonNoStore        = "no-store"
	ReasonNotSealed      = "store-not-sealed"
	ReasonBoundElsewhere = "bound-elsewhere"
	ReasonSupply         = "supply-mismatch"
	ReasonUnbound        = "unbound"
	ReasonReady          = "ready"
)

type col struct {
	cid     string
	info    types.CollectionInfo
	upload  bool
	store   string // params store id ("" if none or unknown)
	si      media.StoreInfo
	b       *binding // this collection's binding (nil if unbound)
	boundTo string   // collection the store is bound to ("" if none)
}

func loadCol(cid string) col {
	c := col{cid: cid, info: core.Info(cid)}
	c.upload = c.info.EngineID == selfPath
	if !c.upload {
		return c
	}
	if id, ok := parseParams(c.info.Params); ok && storeExists(id) {
		c.store = id
		c.si = assets.Info(id)
		if v := bound.Get(id); v != nil {
			c.boundTo = v.(string)
		}
	}
	if v := byCID.Get(cid); v != nil {
		c.b = v.(*binding)
	}
	return c
}

// status: ready = bound ∧ store sealed ∧ supply match (§6).
func (c *col) status() (bool, string) {
	switch {
	case !c.upload:
		return false, ReasonNotUpload
	case c.store == "":
		return false, ReasonNoStore
	case !c.si.Sealed:
		return false, ReasonNotSealed
	case c.boundTo != "" && c.boundTo != c.cid:
		return false, ReasonBoundElsewhere
	case c.info.MaxSupply != c.si.Slots:
		return false, ReasonSupply
	case c.b == nil || c.b.store != c.store:
		return false, ReasonUnbound
	}
	return true, ReasonReady
}

func (c *col) badge() string {
	if !c.upload {
		return "computed"
	}
	if ok, _ := c.status(); !ok {
		return "unbound"
	}
	return media.Badge(c.si.OnchainN, c.si.IPFSN)
}

func mustUpload(cid string) col {
	c := loadCol(cid)
	if !c.upload {
		panic("collection " + cid + " does not use the upload engine")
	}
	return c
}

// IsUpload reports whether cid's engine is this adapter.
func IsUpload(cid string) bool { return core.Info(cid).EngineID == selfPath }

// StoreOf is the store named by cid's params ("" if none).
func StoreOf(cid string) string { return loadCol(cid).store }

// Readiness is the typed Status for other realms.
func Readiness(cid string) (ready bool, reason, store, badge string) {
	c := loadCol(cid)
	ready, reason = c.status()
	return ready, reason, c.store, c.badge()
}

// Status is {cid, upload, state, store, bound, ready, reason, badge, settled,
// maxSupply, slots}. The frontend shows the mint UI only when ready (T14).
func Status(cid string) string {
	c := loadCol(cid)
	ready, reason := c.status()
	w := &safe.JSONWriter{}
	w.BeginObject()
	w.StrField("cid", cid)
	w.BoolField("upload", c.upload)
	w.StrField("state", c.info.State.String())
	w.StrField("store", c.store)
	w.BoolField("bound", c.b != nil)
	w.BoolField("ready", ready)
	w.StrField("reason", reason)
	w.StrField("badge", c.badge())
	w.BoolField("settled", c.b != nil && c.b.key != "")
	w.IntField("maxSupply", c.info.MaxSupply)
	w.IntField("slots", c.si.Slots)
	w.EndObject()
	return w.String()
}

// StorageBadge is "computed" (any other engine), "onchain", "ipfs",
// "mixed", or "unbound" for an upload collection that is not ready (§9).
func StorageBadge(cid string) string {
	c := loadCol(cid)
	return c.badge()
}

// SetComposition is {collection, store, ready, reason, set}, set =
// assets.Composition of the collection's store: slots per tier and per
// trait value over the planned set (public and fixed before the sale, D8).
func SetComposition(cid string) string {
	c := mustUpload(cid)
	if c.store == "" {
		panic("collection " + cid + " names no store")
	}
	ready, reason := c.status()
	w := &safe.JSONWriter{}
	w.BeginObject()
	w.StrField("collection", cid)
	w.StrField("store", c.store)
	w.BoolField("ready", ready)
	w.StrField("reason", reason)
	w.Key("set")
	w.Raw(assets.Composition(c.store))
	w.EndObject()
	return w.String()
}

const (
	stHidden   = 0 // not Final: placeholder
	stNotReady = 1 // Final but not bound/ready: no art
	stResolved = 2
)

func readToken(cid, tid string) (col, resolved, int, error) {
	c := mustUpload(cid)
	if _, err := core.OwnerOf(cid, tid); err != nil {
		return c, resolved{}, stHidden, err
	}
	if c.info.State != types.StateFinal {
		return c, resolved{}, stHidden, nil
	}
	if ok, _ := c.status(); !ok {
		return c, resolved{}, stNotReady, nil
	}
	salt := saltOf(cid, c.b)
	if salt == "" {
		return c, resolved{}, stNotReady, nil
	}
	n := tidNum(tid)
	r := assign(cid, tid, n, c.info, c.store, c.si, keyOf(cid, c.b, salt), nil)
	return c, r, stResolved, nil
}

func mustReadToken(cid, tid string) (col, resolved, int) {
	c, r, st, err := readToken(cid, tid)
	if err != nil {
		panic(err)
	}
	return c, r, st
}

// TokenURI is the canonical art URI: "data:<mime>;base64,…" for on-chain
// art, "ipfs://<cidv1>" for IPFS art; core's placeholder before Final and
// core's TokenURI (the generic card) for a collection that is not ready.
func TokenURI(cid, tid string) (string, error) {
	if !IsUpload(cid) {
		return "", errors.New("collection " + cid + " does not use the upload engine")
	}
	_, r, st, err := readToken(cid, tid)
	if err != nil {
		return "", err
	}
	if st != stResolved {
		return core.TokenURI(cid, tid)
	}
	return artURI(r), nil
}

func artURI(r resolved) string {
	if r.art.Kind == media.KindChain {
		return assets.ArtworkDataURI(r.store, r.art.Index)
	}
	return "ipfs://" + r.art.CID
}

// TokenImage is the inline image: a data URI for on-chain art, "" for IPFS
// art (never a remote URL); core's placeholder before Final.
func TokenImage(cid, tid string) string {
	_, r, st := mustReadToken(cid, tid)
	if st != stResolved {
		uri, _ := core.TokenURI(cid, tid)
		return uri
	}
	if r.art.Kind != media.KindChain {
		return ""
	}
	return assets.ArtworkDataURI(r.store, r.art.Index)
}

// Assignment is the typed TokenArtwork for other realms (gallery): ready is
// false before Final or when the collection is not ready; a is a copy.
func Assignment(cid, tid string) (ready bool, slot, edition int64, a media.Artwork) {
	_, r, st := mustReadToken(cid, tid)
	if st != stResolved {
		return false, 0, 0, media.Artwork{}
	}
	return true, r.slot, r.edition, r.art
}

// TokenArtwork is the token's assignment as JSON:
// {collection, tid, revealed, ready, reason} and, once revealed and ready,
// {store, artwork, slot, edition, editions, assignment, kind, mime, mimeType,
// size, sha256, digest, cid, uri, tier, tierSource, title, traits}.
// uri is "ipfs://<cid>" for IPFS art and "" for on-chain art (read its bytes
// with TokenImage / TokenURI: base64 of up to 256 KiB is not free).
func TokenArtwork(cid, tid string) string {
	c, r, st := mustReadToken(cid, tid)
	_, reason := c.status()
	w := &safe.JSONWriter{}
	w.BeginObject()
	w.StrField("collection", cid)
	w.StrField("tid", tid)
	w.BoolField("revealed", c.info.State == types.StateFinal)
	w.BoolField("ready", st == stResolved)
	w.StrField("reason", reason)
	if st == stResolved {
		a := r.art
		w.StrField("store", r.store)
		w.IntField("artwork", a.Index)
		w.IntField("slot", r.slot)
		w.IntField("edition", r.edition)
		w.IntField("editions", a.Editions)
		w.StrField("assignment", assignmentMode(r.si))
		w.StrField("kind", media.KindName(a.Kind))
		w.StrField("mime", media.MimeName(a.Mime))
		w.StrField("mimeType", media.MimeType(a.Mime))
		w.IntField("size", a.Size)
		w.StrField("sha256", a.SHA256)
		w.StrField("digest", a.Digest)
		w.StrField("cid", a.CID)
		if a.Kind == media.KindChain {
			w.StrField("uri", "")
		} else {
			w.StrField("uri", "ipfs://"+a.CID)
		}
		w.StrField("tier", a.Tier)
		w.StrField("tierSource", "creator")
		w.StrField("title", a.Title)
		w.Key("traits")
		w.Raw(realTraitsJSON(r))
	}
	w.EndObject()
	return w.String()
}

func assignmentMode(si media.StoreInfo) string {
	if si.Artworks == 1 {
		return "edition"
	}
	return "shuffled"
}

// realTraits are the upload-path attributes with the creator's real type
// names: Tier, the creator's traits in store order, Edition (when the
// artwork has more than one) and Storage.
func realTraits(r resolved) []engine.Trait {
	a := r.art
	out := []engine.Trait{}
	if a.Tier != "" {
		out = append(out, engine.Trait{Type: "Tier", Value: a.Tier})
	}
	for k, v := range a.Traits {
		if v != "" {
			out = append(out, engine.Trait{Type: r.si.TraitTypes[k], Value: v})
		}
	}
	if a.Editions > 1 {
		out = append(out, engine.Trait{Type: "Edition", Value: editionLabel(r.edition, a.Editions)})
	}
	out = append(out, engine.Trait{Type: "Storage", Value: storageLabel(a.Kind)})
	return out
}

var (
	unrevealed = []engine.Trait{{Type: "Status", Value: "Unrevealed"}}
	notReady   = []engine.Trait{{Type: "Status", Value: "Not ready"}}
)

const (
	unrevealedJSON = `[{"trait_type":"Status","value":"Unrevealed"}]`
	notReadyJSON   = `[{"trait_type":"Status","value":"Not ready"}]`
)

// realTraitsJSON is realTraits as JSON, from the names the store escaped
// once (media.Artwork.TierJSON / TraitsJSON): same bytes as writeTraits of
// realTraits, without escaping creator text on every read (review UP-M1).
func realTraitsJSON(r resolved) string {
	a := r.art
	parts := make([]string, 0, 4)
	if a.TierJSON != "" {
		parts = append(parts, `{"trait_type":"Tier","value":`+a.TierJSON+`}`)
	}
	if a.TraitsJSON != "" {
		parts = append(parts, a.TraitsJSON)
	}
	if a.Editions > 1 {
		parts = append(parts, `{"trait_type":"Edition","value":"`+editionLabel(r.edition, a.Editions)+`"}`)
	}
	parts = append(parts, `{"trait_type":"Storage","value":"`+storageLabel(a.Kind)+`"}`)
	return "[" + strings.Join(parts, ",") + "]"
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

// TokenTraitList is the typed real-name trait list of one token (a copy).
func TokenTraitList(cid, tid string) []engine.Trait {
	_, r, st := mustReadToken(cid, tid)
	switch st {
	case stHidden:
		return append([]engine.Trait{}, unrevealed...)
	case stNotReady:
		return append([]engine.Trait{}, notReady...)
	}
	return realTraits(r)
}

// TokenTraits is TokenTraitList as [{"trait_type","value"}] JSON.
func TokenTraits(cid, tid string) string {
	_, r, st := mustReadToken(cid, tid)
	switch st {
	case stHidden:
		return unrevealedJSON
	case stNotReady:
		return notReadyJSON
	}
	return realTraitsJSON(r)
}

// TokenMetadata is the canonical metadata (§10.2). Before Final: core's
// placeholder image and [{Status: Unrevealed}].
func TokenMetadata(cid, tid string) string {
	c, r, st := mustReadToken(cid, tid)
	w := &safe.JSONWriter{}
	w.BeginObject()
	w.StrField("name", c.info.Name+" #"+tid)
	w.StrField("description", c.info.Description)
	if st != stResolved {
		uri, _ := core.TokenURI(cid, tid)
		w.StrField("image", uri)
		w.Key("attributes")
		if st == stHidden {
			writeTraits(w, unrevealed)
		} else {
			writeTraits(w, notReady)
		}
		w.EndObject()
		return w.String()
	}
	a := r.art
	w.StrField("image", artURI(r))
	w.StrField("image_mime", media.MimeType(a.Mime))
	w.StrField("image_sha256", a.SHA256)
	w.IntField("image_size", a.Size)
	w.Key("attributes")
	w.Raw(realTraitsJSON(r))
	w.Key("properties")
	w.BeginObject()
	w.StrField("collection", cid)
	w.StrField("store", r.store)
	w.IntField("artwork", a.Index)
	w.StrField("edition", editionLabel(r.edition, a.Editions))
	if a.Kind == media.KindChain {
		w.StrField("storage", "onchain")
	} else {
		w.StrField("storage", "ipfs")
		w.StrField("cid", a.CID)
	}
	w.StrField("title", a.Title)
	w.StrField("tier", a.Tier)
	w.StrField("tierSource", "creator")
	w.StrField("assignment", assignmentMode(r.si))
	w.BoolField("fair", core.FairLaunch(cid))
	w.EndObject()
	w.EndObject()
	return w.String()
}

// TraitLists returns, for tokens offset+1 … offset+limit (limit <=
// MaxTraitLists, burned tokens skipped), the token ids and their real-name
// traits. The permutation key is computed once per call.
func TraitLists(cid string, offset, limit int64) ([]string, [][]engine.Trait) {
	tids, rs, st := tokenPage(cid, offset, limit, MaxTraitLists)
	lists := make([][]engine.Trait, len(tids))
	for i := range tids {
		switch st {
		case stHidden:
			lists[i] = append([]engine.Trait{}, unrevealed...)
		case stNotReady:
			lists[i] = append([]engine.Trait{}, notReady...)
		default:
			lists[i] = realTraits(rs[i])
		}
	}
	return tids, lists
}

// TraitJSONLists is TraitLists with each token's traits as a JSON array
// (the bytes TokenTraits returns), for pages that print them (reader.Cards).
// limit <= MaxTraitJSONLists.
func TraitJSONLists(cid string, offset, limit int64) ([]string, []string) {
	tids, rs, st := tokenPage(cid, offset, limit, MaxTraitJSONLists)
	out := make([]string, len(tids))
	for i := range tids {
		switch st {
		case stHidden:
			out[i] = unrevealedJSON
		case stNotReady:
			out[i] = notReadyJSON
		default:
			out[i] = realTraitsJSON(rs[i])
		}
	}
	return tids, out
}

// tokenPage resolves tokens offset+1 … offset+limit (limit <= max, burned
// skipped) with one permutation key per call and one record read per
// distinct artwork. st is stHidden before Final, stNotReady when the
// collection is Final but not ready, else stResolved.
func tokenPage(cid string, offset, limit, max int64) ([]string, []resolved, int) {
	c := mustUpload(cid)
	if limit <= 0 || limit > max {
		limit = max
	}
	if offset < 0 {
		offset = 0
	}
	st := stHidden
	key := ""
	if c.info.State == types.StateFinal {
		st = stNotReady
		if ready, _ := c.status(); ready {
			if salt := saltOf(cid, c.b); salt != "" {
				key = keyOf(cid, c.b, salt)
				st = stResolved
			}
		}
	}
	cache := map[int64]media.Artwork{}
	var tids []string
	var rs []resolved
	for n := offset + 1; n <= c.info.Minted && n <= offset+limit; n++ {
		tid := strconv.FormatInt(n, 10)
		if _, err := core.OwnerOf(cid, tid); err != nil {
			continue // burned
		}
		tids = append(tids, tid)
		if st == stResolved {
			rs = append(rs, assign(cid, tid, n, c.info, c.store, c.si, key, cache))
		}
	}
	return tids, rs, st
}

// TraitCounts is {"n": tokens counted, "counts": {type: {value: count}}}
// over tokens offset+1 … offset+limit (limit <= MaxTraitCounts, burned
// skipped), with the creator's real names: Tier, the creator's trait types
// (store order, values in dictionary order), Edition, Storage. Before Final
// every token counts as {"Status": "Unrevealed"}, Final but not ready as
// {"Status": "Not ready"}. One permutation key per call; the counting runs in
// assets/v1 over integer ids (review UP-M1).
func TraitCounts(cid string, offset, limit int64) string {
	c := mustUpload(cid)
	if limit <= 0 || limit > MaxTraitCounts {
		limit = MaxTraitCounts
	}
	if offset < 0 {
		offset = 0
	}
	st := stHidden
	key := ""
	if c.info.State == types.StateFinal {
		st = stNotReady
		if ready, _ := c.status(); ready {
			if salt := saltOf(cid, c.b); salt != "" {
				key = keyOf(cid, c.b, salt)
				st = stResolved
			}
		}
	}
	var n int64
	var idxs, eds []int64
	for t := offset + 1; t <= c.info.Minted && t <= offset+limit; t++ {
		if _, err := core.OwnerOf(cid, strconv.FormatInt(t, 10)); err != nil {
			continue // burned
		}
		n++
		if st == stResolved {
			idx, ed := assets.SlotArtwork(c.store, media.Slot(key, c.si.Artworks, c.si.Slots, t))
			idxs = append(idxs, idx)
			eds = append(eds, ed)
		}
	}
	head := `{"n":` + strconv.FormatInt(n, 10) + `,"counts":{`
	switch {
	case n == 0:
		return head + `}}`
	case st == stHidden:
		return head + `"Status":{"Unrevealed":` + strconv.FormatInt(n, 10) + `}}}`
	case st == stNotReady:
		return head + `"Status":{"Not ready":` + strconv.FormatInt(n, 10) + `}}}`
	}
	return head + assets.CountsJSON(c.store, idxs, eds) + `}}`
}

// TraitsBatch is [{tid, traits:[{trait_type, value}]}] for tokens
// offset+1 … offset+limit (limit <= MaxTraitsBatch), burned tokens skipped.
func TraitsBatch(cid string, offset, limit int64) string {
	tids, lists := traitJSONPage(cid, offset, limit, MaxTraitsBatch)
	parts := make([]string, len(tids))
	for i, tid := range tids {
		parts[i] = `{"tid":"` + tid + `","traits":` + lists[i] + `}`
	}
	return "[" + strings.Join(parts, ",") + "]"
}

func traitJSONPage(cid string, offset, limit, max int64) ([]string, []string) {
	if limit <= 0 || limit > max {
		limit = max
	}
	return TraitJSONLists(cid, offset, limit)
}

// Render stays minimal; uploaded collections are browsed in the gallery.
func Render(path string) string {
	return "# Sinopia Upload engine\n\n" + strconv.Itoa(byCID.Size()) +
		" collections bound to sealed asset stores. Each token shows the artwork of its slot, assigned by a " +
		"permutation keyed by the collection's final salt; tiers and traits are assigned by the creator.\n"
}
