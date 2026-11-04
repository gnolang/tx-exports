// Package upload is the engine/v1 adapter for uploaded collections
// (docs/uploaded-collections.md §5.3, §7–§10, §0a). Core knows it as one
// more engine; each collection's params name one sealed asset store
// ("store:<id>", r/…/assets/v1) and Bind locks that store to the collection
// while it is a Draft. After the reveal every token shows the artwork of the
// slot a salt-keyed permutation gives it.
//
// What holds, and why:
//   - art theft (T1): ValidateParams accepts a store only when its owner
//     signs the Create tx; Bind needs caller == collection creator == store
//     owner, from a wallet;
//   - no swap after sale (T2): stores are sealed before Bind and never
//     change; params are fixed by core; Bind and Unbind run only while core
//     says Draft, i.e. before any token was ever minted;
//   - one collection per store (T3); slots == maxSupply (T13);
//   - snipe resistance (T4/T5): before Final core shows its placeholder and
//     never calls Render/Traits; every read here checks Final too; the
//     assignment needs the final salt; Render answers core's real call only
//     (CollectionID, params and seed must match core's), so RenderWith
//     (CollectionID "0") always gets the generic card;
//   - SA-L5: this realm and assets/v1 may not be payees (Bind refuses);
//   - I-12: Render, Traits and ValidateParams only read; Bind, Unbind and
//     Settle are crossing functions; there is no exported non-crossing
//     mutator.
//
// The adapter is stateful by design (bindings and cached keys), declares
// Living false, takes no fee (D3) and holds no coins.
package upload

import (
	"chain"
	"chain/runtime/unsafe"
	"errors"
	"strconv"
	"strings"

	"gno.land/p/nt/avl/v0"

	"gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia/engine/v1"
	"gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia/media/v1"
	"gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia/safe/v1"
	"gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia/types/v1"
	assets "gno.land/r/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia3/assets/v1"
	"gno.land/r/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia3/core"
)

// author claims the engine in core (ClaimEngine).
// TODO(mainnet): the platform's engine-author key, not the deployer.
var author = address("g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06")

func Author() address { return author }

// FeeBps is the engine-author fee (D3: none; fixed forever at Register).
const FeeBps = 0

// Core-path trait slots (engine/v1 manifests fix their trait types at
// registration, so creator trait types appear as "Trait k" = "<Type>: <Value>").
const (
	TraitTier    = "Creator tier"
	TraitArtwork = "Artwork"
	TraitEdition = "Edition"
	TraitStorage = "Storage"
	TraitSlots   = assets.MaxTraitTypes
)

// MaxTraitsBatch bounds TraitsBatch (JSON); MaxTraitLists bounds the typed
// TraitLists the reader pages rarity counts with. Both compute the
// permutation key once per call (§0a), never per token.
// Sized so the worst store the asset limits allow stays <= 1B test gas per
// call (review UP-M1; r/reader/zz_worst_gas_test.gno).
const (
	MaxTraitsBatch    = 20  // JSON (was 50)
	MaxTraitJSONLists = 20  // typed, JSON per token (reader.Cards)
	MaxTraitLists     = 250 // typed (was 500)
	MaxTraitCounts    = 200 // TraitCounts (reader.TraitCounts)
)

var (
	selfPath   string
	assetsPath string

	bound avl.Tree // store id -> cid
	byCID avl.Tree // cid -> *binding
)

type binding struct {
	store string
	salt  string // cached by Settle ("" = read core.Provenance)
	key   string // media.PermKey(cid, salt), cached by Settle
}

func init(cur realm) {
	selfPath = cur.PkgPath()
	assetsPath = strings.TrimSuffix(selfPath, "/engines/upload") + "/assets/v1"
}

// SelfPath and AssetsPath are the engine id and the store realm it reads.
func SelfPath() string   { return selfPath }
func AssetsPath() string { return assetsPath }

// --- engine/v1 ---------------------------------------------------------------

// impl is zero-size and declared here, so core runs it with this realm's
// authority (interrealm v2 borrow rule #1).
type impl struct{}

func traitTypes() []string {
	out := []string{TraitTier, TraitArtwork, TraitEdition, TraitStorage}
	for k := 1; k <= TraitSlots; k++ {
		out = append(out, "Trait "+strconv.Itoa(k))
	}
	return out
}

func (impl) Manifest() engine.Manifest {
	return engine.Manifest{
		Name:    "Sinopia Upload",
		Version: "1.0.0",
		Description: "Uploaded art: each token shows the artwork of its slot in a sealed asset store (assets/v1), " +
			"assigned by a permutation keyed by the final salt. Stateful platform engine (store bindings); " +
			"tiers and traits are assigned by the creator.",
		License:     "artist's own",
		Author:      author,
		TraitTypes:  traitTypes(),
		Living:      false,
		MaxSVGBytes: media.MaxSVGBytes,
		FeeBps:      FeeBps,
	}
}

// ValidateParams accepts "" (registration, Studio) or exactly
// "store:<id>" of an existing, sealed, unbound store whose owner signs this
// transaction (art-theft guard). In qeval there is no signer, so store
// params are refused there: intended (Studio never offers them). No writes.
func (impl) ValidateParams(p string) error {
	if p == "" {
		return nil
	}
	id, ok := parseParams(p)
	if !ok {
		return errors.New("params must be store:<id>")
	}
	if !storeExists(id) {
		return errors.New("unknown store " + id)
	}
	si := assets.Info(id)
	if !si.Sealed {
		return errors.New("store " + id + " is not sealed")
	}
	if v := bound.Get(id); v != nil {
		return errors.New("store " + id + " is already bound to collection " + v.(string))
	}
	if si.Owner != unsafe.OriginCaller() {
		return errors.New("store owner is not the signer")
	}
	return nil
}

func (impl) Render(in engine.Input) string {
	r, ok := coreResolve(in)
	if !ok {
		return cardSVG
	}
	if r.art.Kind == media.KindChain && r.art.Mime == media.MimeSVG {
		return assets.ArtworkBytes(r.store, r.art.Index) // passed AssertSVG(16 KiB) at upload; core re-checks
	}
	return certificateSVG(r)
}

func (impl) Traits(in engine.Input) []engine.Trait {
	if in.Params == "" || in.CollectionID == "0" {
		return []engine.Trait{}
	}
	r, ok := coreResolve(in)
	if !ok {
		return []engine.Trait{{Type: TraitStorage, Value: "Not bound"}}
	}
	a := r.art
	var out []engine.Trait
	if a.Tier != "" {
		out = append(out, engine.Trait{Type: TraitTier, Value: a.Tier})
	}
	title := a.Title
	if title == "" {
		title = "#" + strconv.FormatInt(a.Index+1, 10)
	}
	out = append(out, engine.Trait{Type: TraitArtwork, Value: title})
	if a.Editions > 1 {
		out = append(out, engine.Trait{Type: TraitEdition, Value: editionLabel(r.edition, a.Editions)})
	}
	out = append(out, engine.Trait{Type: TraitStorage, Value: storageLabel(a.Kind)})
	for k, v := range a.Traits {
		if v != "" {
			out = append(out, engine.Trait{Type: "Trait " + strconv.Itoa(k+1), Value: r.si.TraitTypes[k] + ": " + v})
		}
	}
	return out
}

// Register is an explicit call (not init: under the inert package policy
// init runs in the approver's tx). Anyone may call it, once.
func Register(cur realm) string {
	return core.RegisterEngine(cross(cur), impl{})
}

// --- binding -----------------------------------------------------------------

// Bind locks the collection's store (its params "store:<id>") to the
// collection. Caller == core creator == store owner, from a wallet; core
// state Draft; the collection uses this engine; the store is sealed and not
// bound elsewhere; maxSupply == the store's slots; no primary or royalty
// payee is this realm or assets/v1 (SA-L5). Event StoreBound{store, cid}.
func Bind(cur realm, cid string) {
	assertWallet(cur)
	who := cur.Previous().Address()
	info := core.Info(cid)
	assertUploadDraft(info, cid)
	if who != info.Creator {
		panic("only the collection's creator can bind its store")
	}
	id, ok := parseParams(info.Params)
	if !ok || !storeExists(id) {
		panic("collection " + cid + " has no store params (store:<id>)")
	}
	si := assets.Info(id)
	if si.Owner != who {
		panic("only the owner of store " + id + " can bind it")
	}
	if !si.Sealed {
		panic("store " + id + " is not sealed")
	}
	if byCID.Has(cid) {
		panic("collection " + cid + " is already bound")
	}
	if v := bound.Get(id); v != nil {
		panic("store " + id + " is already bound to collection " + v.(string))
	}
	if info.MaxSupply != si.Slots {
		panic("maxSupply " + strconv.FormatInt(info.MaxSupply, 10) + " must equal the store's slots " +
			strconv.FormatInt(si.Slots, 10))
	}
	assertPayees(cid)
	bound.Set(id, cid)
	byCID.Set(cid, &binding{store: id})
	chain.Emit("StoreBound", "store", id, "cid", cid)
}

// Unbind releases the store while the collection is still a Draft.
// Creator only. Event StoreUnbound{store, cid}.
func Unbind(cur realm, cid string) {
	assertWallet(cur)
	info := core.Info(cid)
	assertUploadDraft(info, cid)
	if cur.Previous().Address() != info.Creator {
		panic("only the collection's creator can unbind its store")
	}
	v := byCID.Get(cid)
	if v == nil {
		panic("collection " + cid + " is not bound")
	}
	id := v.(*binding).store
	byCID.Remove(cid)
	bound.Remove(id)
	chain.Emit("StoreUnbound", "store", id, "cid", cid)
}

// Settle caches the permutation key once the collection is Final. Anyone
// may call it; it is deterministic (the salt is final) and idempotent, and
// it only saves read gas: the lazy path computes the same key.
// Event Settled{cid, key} (first call only).
func Settle(cur realm, cid string) {
	if cur.Previous().IsUserCall() && !unsafe.OriginSend().IsZero() {
		panic("this function does not accept coins")
	}
	info := core.Info(cid)
	if info.EngineID != selfPath {
		panic("collection " + cid + " does not use the upload engine")
	}
	if info.State != types.StateFinal {
		panic("collection " + cid + " is not final yet")
	}
	v := byCID.Get(cid)
	if v == nil {
		panic("collection " + cid + " is not bound to a store")
	}
	b := v.(*binding)
	if b.key != "" {
		return
	}
	salt := provenanceSalt(core.Provenance(cid))
	if salt == "" {
		panic("collection " + cid + " has no final salt")
	}
	b.salt = salt
	b.key = media.PermKey(cid, salt)
	chain.Emit("Settled", "cid", cid, "key", b.key)
}

func assertWallet(cur realm) {
	if !cur.Previous().IsUserCall() {
		panic("call this directly from a wallet")
	}
	if !unsafe.OriginSend().IsZero() {
		panic("this function does not accept coins")
	}
}

func assertUploadDraft(info types.CollectionInfo, cid string) {
	if info.EngineID != selfPath {
		panic("collection " + cid + " does not use the upload engine")
	}
	if info.State != types.StateDraft {
		panic("collection " + cid + " is " + info.State.String() +
			"; stores are bound or unbound only while it is a draft (no token was ever minted)")
	}
}

// assertPayees refuses this realm and assets/v1 as primary or royalty
// payees (SA-L5: neither can ever spend a payment). Core already refuses
// itself, its sub-addresses, minters, the engine adapter and its siblings.
func assertPayees(cid string) {
	bad := []address{chain.PackageAddress(selfPath), chain.PackageAddress(assetsPath)}
	var addrs []address
	for _, p := range core.PrimaryPayees(cid) {
		addrs = append(addrs, p.Addr)
	}
	for _, part := range strings.Split(jsonStrField(core.Collection(cid), "royaltyPayees"), ",") {
		if a, _, ok := strings.Cut(part, ":"); ok {
			addrs = append(addrs, address(a))
		}
	}
	for _, a := range addrs {
		for _, b := range bad {
			if a == b {
				panic("payee " + a.String() + " is a platform realm that cannot spend; use a wallet")
			}
		}
	}
}

// jsonStrField reads a string field of core's JSON. Values written by
// safe.JSONWriter escape '"', so the key pattern cannot be forged by user text.
func jsonStrField(js, key string) string {
	pat := `"` + key + `":"`
	i := strings.Index(js, pat)
	if i < 0 {
		return ""
	}
	rest := js[i+len(pat):]
	j := strings.IndexByte(rest, '"')
	if j < 0 {
		return ""
	}
	return rest[:j]
}

// provenanceSalt is the final salt from core.Provenance JSON ("" before
// Final). The pattern `"salt":"` cannot be forged: JSONWriter escapes every
// '"' inside a secret.
func provenanceSalt(prov string) string {
	s := jsonStrField(prov, "salt")
	if !media.IsHex32(s) {
		return ""
	}
	return s
}

// parseParams accepts exactly "store:<id>" with a canonical decimal id.
func parseParams(p string) (string, bool) {
	if !strings.HasPrefix(p, "store:") {
		return "", false
	}
	id := p[len("store:"):]
	if id == "" || len(id) > 10 || id[0] == '0' {
		return "", false
	}
	for i := 0; i < len(id); i++ {
		if id[i] < '0' || id[i] > '9' {
			return "", false
		}
	}
	return id, true
}

func storeExists(id string) bool {
	n, err := strconv.ParseInt(id, 10, 64)
	return err == nil && n >= 1 && n <= assets.StoreCount()
}

// tidNum is the numeric token id, 0 for a non-canonical one.
func tidNum(tid string) int64 {
	if tid == "" || len(tid) > 12 || tid[0] == '0' {
		return 0
	}
	var n int64
	for i := 0; i < len(tid); i++ {
		c := tid[i]
		if c < '0' || c > '9' {
			return 0
		}
		n = n*10 + int64(c-'0')
	}
	return n
}

// --- resolution ----------------------------------------------------------------

// resolved is one token's assignment.
type resolved struct {
	cid, tid      string
	info          types.CollectionInfo
	store         string
	si            media.StoreInfo
	key           string
	slot, edition int64
	art           media.Artwork
}

// coreResolve answers only core's own TokenURI/TokenTraits call for a
// Final, bound collection: CollectionID, params and seed must be exactly
// what core passes (§7 snipe resistance). Anything else gets the card.
func coreResolve(in engine.Input) (resolved, bool) {
	var r resolved
	if in.Params == "" || in.CollectionID == "0" {
		return r, false
	}
	v := byCID.Get(in.CollectionID)
	if v == nil {
		return r, false
	}
	b := v.(*binding)
	if in.Params != "store:"+b.store {
		return r, false
	}
	info := core.Info(in.CollectionID)
	if info.EngineID != selfPath || info.State != types.StateFinal || info.Params != in.Params {
		return r, false
	}
	salt := saltOf(in.CollectionID, b)
	if salt == "" || in.Seed != safe.Seed(in.CollectionID, in.TokenID, salt) {
		return r, false
	}
	n := tidNum(in.TokenID)
	if n < 1 || n > info.MaxSupply {
		return r, false
	}
	return assign(in.CollectionID, in.TokenID, n, info, b.store, assets.Info(b.store), keyOf(in.CollectionID, b, salt), nil), true
}

func saltOf(cid string, b *binding) string {
	if b.salt != "" {
		return b.salt
	}
	return provenanceSalt(core.Provenance(cid))
}

func keyOf(cid string, b *binding, salt string) string {
	if b.key != "" {
		return b.key
	}
	return media.PermKey(cid, salt)
}

// assign maps token n to its slot, artwork and edition. With a cache (trait
// batches) artworks are read once per batch and without their hashes/CID
// (assets.ArtworkMeta); without one the full record is read.
func assign(cid, tid string, n int64, info types.CollectionInfo, store string, si media.StoreInfo, key string,
	cache map[int64]media.Artwork,
) resolved {
	slot := media.Slot(key, si.Artworks, si.Slots, n)
	idx, edition := assets.SlotArtwork(store, slot)
	var a media.Artwork
	if cache != nil {
		if c, ok := cache[idx]; ok {
			a = c
		} else {
			a = assets.ArtworkMeta(store, idx)
			cache[idx] = a
		}
	} else {
		a = assets.ArtworkAt(store, idx)
	}
	return resolved{cid: cid, tid: tid, info: info, store: store, si: si, key: key, slot: slot, edition: edition, art: a}
}

func editionLabel(e, of int64) string {
	return strconv.FormatInt(e, 10) + "/" + strconv.FormatInt(of, 10)
}

func storageLabel(kind int) string {
	if kind == media.KindChain {
		return "On-chain"
	}
	return "IPFS"
}
