// Package upload is the engine/v2 adapter for uploaded collections
// (docs/uploaded-collections.md §5.3, §7–§10, §0a; mainnet plan §2.3, WP-F).
// Core knows it as a media engine (Manifest.Kind "media"): each
// collection's params name one sealed asset store ("store:<id>",
// r/…/assets/v1) and Bind locks that store to the collection while it is a
// Draft. After the reveal every token's art is the artwork of the slot a
// salt-keyed permutation gives it, and core itself serves it:
//
//   - core.TokenURI = Media(in): the checked on-chain file as a data URI
//     (raster or SVG) or "ipfs://<CIDv1>" (I-15);
//   - core.TokenCard = Render(in): the on-chain SVG itself, or a
//     certificate card for raster/IPFS art (SVG-only clients, gnoweb);
//   - core.TokenTraits = Traits(in) with the creator's real trait names,
//     checked by core against TraitTypes(params) (stored per collection);
//   - core.Launch runs CheckLaunch (T14: no launch without a bound store).
//
// What holds, and why:
//   - art theft (T1): ValidateParams accepts a store only when its owner
//     signs the Create tx; Bind needs caller == collection creator == store
//     owner, from a wallet;
//   - no swap after sale (T2): stores are sealed before Bind and never
//     change; params are fixed by core; Bind and Unbind run only while core
//     says Draft, i.e. before any token was ever minted;
//   - one collection per store (T3); slots == maxSupply (T13), checked at
//     Bind and again by CheckLaunch;
//   - unbound launch (T14): CheckLaunch refuses a collection whose store is
//     not bound to it, so core never launches one (closes the residual of
//     docs/uploaded-collections.md T14 for every client);
//   - snipe resistance (T4/T5): before Final core shows its placeholder and
//     never calls Media/Render/Traits; every read here checks Final too; the
//     assignment needs the final salt (core.Salt); Media/Render/Traits
//     answer core's real call only (CollectionID, params and seed must match
//     core's), so RenderWith/TraitsWith (CollectionID "0") always get the
//     generic card and no traits;
//   - SA-L5: core's static payee deny list refuses this realm and assets/v1
//     as payees and treasury at Create and SetPayees (also after Final);
//   - I-12/I-16: Media, Render, Traits, TraitTypes, CheckLaunch and
//     ValidateParams only read; Bind, Unbind and Settle are crossing
//     functions; there is no exported non-crossing mutator.
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

	"gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia4/engine/v2"
	"gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia4/media/v2"
	"gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia4/safe/v2"
	"gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia4/types/v2"
	assets "gno.land/r/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia4/assets/v1"
	"gno.land/r/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia4/core"
)

// Author is the engine author (config.gno).
func Author() address { return author }

// FeeBps is the engine-author fee (D3: none; fixed forever at Register).
const FeeBps = 0

// EngineVersion is Manifest().Version.
const EngineVersion = "2.0.0"

// Trait names the adapter adds itself (assets/v1 reserves them, so a
// creator's trait type can never collide). A collection's trait list is
// TraitTypes(params): Tier (if the store has tiers), the creator's types in
// store order, Edition (if an artwork has editions), Storage.
const (
	TraitTier    = "Tier"
	TraitEdition = "Edition"
	TraitStorage = "Storage"
)

// defaultTraitTypes is Manifest().TraitTypes and TraitTypes(""): core
// stores a collection's list only when it differs from this one.
var defaultTraitTypes = []string{TraitTier, TraitEdition, TraitStorage}

// MaxTraitsBatch bounds TraitsBatch (JSON); MaxTraitLists bounds the typed
// TraitLists. Both compute the permutation key once per call (§0a), never
// per token. Sized so the worst store the asset limits allow stays <= 1B
// test gas per call (review UP-M1; zz_worst_gas_test.gno).
const (
	MaxTraitsBatch    = 20  // JSON
	MaxTraitJSONLists = 20  // typed, JSON per token (reader.Cards)
	MaxTraitLists     = 250 // typed
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
	salt  string // cached by Settle ("" = read core.Salt)
	key   string // media.PermKey(cid, salt), cached by Settle
}

func init(cur realm) {
	selfPath = cur.PkgPath()
	assetsPath = strings.TrimSuffix(selfPath, "/engines/upload") + "/assets/v1"
}

// SelfPath and AssetsPath are the engine id and the store realm it reads.
func SelfPath() string   { return selfPath }
func AssetsPath() string { return assetsPath }

// --- engine/v2 ---------------------------------------------------------------

// impl is zero-size and declared here, so core runs it with this realm's
// authority (interrealm v2 borrow rule #1).
type impl struct{}

func (impl) Manifest() engine.Manifest {
	return engine.Manifest{
		Name:    "Sinopia Upload",
		Version: EngineVersion,
		Description: "Uploaded art: each token shows the artwork of its slot in a sealed asset store (assets/v1), " +
			"assigned by a permutation keyed by the final salt. Media engine: core serves the file itself " +
			"(on-chain data URI or ipfs:// CIDv1). Stateful platform engine (store bindings); tiers and traits are " +
			"assigned by the creator.",
		License:       "artist's own",
		Author:        author,
		TraitTypes:    append([]string{}, defaultTraitTypes...),
		Living:        false,
		MaxSVGBytes:   media.MaxSVGBytes, // the card, and on-chain SVG art as its own card
		FeeBps:        FeeBps,
		Kind:          engine.KindMedia,
		MaxMediaBytes: media.MaxRasterBytes,
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

// TraitTypes is the trait list of a collection over store params: Tier
// (if the store declares tiers), the store's trait types in order, Edition
// (if some artwork has more than one edition), Storage. The store is
// sealed (ValidateParams), so the list is fixed; core stores it at Create
// (when it differs from the manifest's) and checks every Traits result
// against it. Anything but store params gets the manifest's list.
func (impl) TraitTypes(p string) []string {
	id, ok := parseParams(p)
	if !ok || !storeExists(id) {
		return append([]string{}, defaultTraitTypes...)
	}
	return storeTraitTypes(assets.Info(id))
}

func storeTraitTypes(si media.StoreInfo) []string {
	out := make([]string, 0, len(si.TraitTypes)+3)
	if len(si.Tiers) > 0 {
		out = append(out, TraitTier)
	}
	out = append(out, si.TraitTypes...)
	if si.HasEditions() {
		out = append(out, TraitEdition)
	}
	return append(out, TraitStorage)
}

// CheckLaunch is core's launch gate (T14): the collection must be bound to
// the store its params name, that store sealed, its slots == maxSupply.
// Everything comes from this realm and assets/v1; core is not read.
func (impl) CheckLaunch(cid, params string, maxSupply int64) error {
	id, ok := parseParams(params)
	if !ok {
		return errors.New("collection " + cid + " names no store (params store:<id>)")
	}
	v := byCID.Get(cid)
	if v == nil {
		return errors.New("collection " + cid + " is not bound to store " + id + " (call Bind first)")
	}
	if b := v.(*binding); b.store != id {
		return errors.New("collection " + cid + " is bound to store " + b.store + ", not " + id)
	}
	si := assets.Info(id)
	if !si.Sealed {
		return errors.New("store " + id + " is not sealed")
	}
	if si.Slots != maxSupply {
		return errors.New("maxSupply " + strconv.FormatInt(maxSupply, 10) + " must equal the store's slots " +
			strconv.FormatInt(si.Slots, 10))
	}
	return nil
}

// Media is the token's file for core's real TokenURI call: the on-chain
// bytes (Data + Sha256) or "ipfs://<cid>" (+ the declared Sha256). Media{}
// for anything else (core then shows the card).
func (impl) Media(in engine.Input) engine.Media {
	r, ok := coreResolve(in)
	if !ok {
		return engine.Media{}
	}
	a := r.art
	if a.Kind == media.KindChain {
		return engine.Media{Mime: a.MimeType(), Data: assets.ArtworkBytes(r.store, a.Index), Sha256: a.SHA256}
	}
	return engine.Media{Mime: a.MimeType(), URI: a.URI(), Sha256: a.SHA256}
}

// Render is the token's card: an on-chain SVG artwork is its own card
// (passed AssertSVG(16 KiB) at upload; core re-checks), raster and IPFS art
// get the certificate; anything that is not core's real call gets the
// generic card (registration sample, RenderWith).
func (impl) Render(in engine.Input) string {
	r, ok := coreResolve(in)
	if !ok {
		return cardSVG
	}
	if r.art.Kind == media.KindChain && r.art.Mime == media.MimeSVG {
		return assets.ArtworkBytes(r.store, r.art.Index)
	}
	return certificateSVG(r)
}

// Traits are the real-name attributes (realTraits) for core's real call;
// none for the registration sample / RenderWith; {Storage: Not bound} for a
// Final collection that is not ready (unreachable once CheckLaunch passed).
func (impl) Traits(in engine.Input) []engine.Trait {
	if in.Params == "" || in.CollectionID == "0" {
		return []engine.Trait{}
	}
	r, ok := coreResolve(in)
	if !ok {
		return []engine.Trait{{Type: TraitStorage, Value: "Not bound"}}
	}
	return realTraits(r)
}

// Register is an explicit call (not init: under the inert package policy
// init runs in the approver's tx). The card's fingerprint is reserved in
// core's source for the platform author, so only that key can sign it.
func Register(cur realm) string {
	return core.RegisterEngine(cross(cur), impl{}, "")
}

// --- binding -----------------------------------------------------------------

// Bind locks the collection's store (its params "store:<id>") to the
// collection. Caller == core creator == store owner, from a wallet; core
// state Draft; the collection uses this engine; the store is sealed and not
// bound elsewhere; maxSupply == the store's slots. cid may be "<cid>" or
// "c/<cid>"; the binding is kept under core's bare id. Event
// StoreBound{store, cid}.
func Bind(cur realm, cid string) {
	assertWallet(cur)
	who := cur.Previous().Address()
	info := core.Info(cid)
	cid = info.ID
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
	bound.Set(id, cid)
	byCID.Set(cid, &binding{store: id})
	chain.Emit("StoreBound", "store", id, "cid", cid)
}

// Unbind releases the store while the collection is still a Draft.
// Creator only. Event StoreUnbound{store, cid}.
func Unbind(cur realm, cid string) {
	assertWallet(cur)
	info := core.Info(cid)
	cid = info.ID
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

// Settle caches the salt and permutation key once the collection is Final.
// Anyone may call it; it is deterministic (the salt is final) and
// idempotent, and it only saves read gas: the lazy path computes the same
// key. Event Settled{cid, key} (first call only).
func Settle(cur realm, cid string) {
	if cur.Previous().IsUserCall() && !unsafe.OriginSend().IsZero() {
		panic("this function does not accept coins")
	}
	info := core.Info(cid)
	cid = info.ID
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
	salt := finalSalt(info.Salt)
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

// finalSalt is core's typed salt (M-5: core.Salt / Info.Salt, "" before
// Final) when it is 64 lower-case hex, else "".
func finalSalt(s string) string {
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

// coreResolve answers only core's own TokenURI/TokenCard/TokenTraits call
// for a Final, bound collection: CollectionID, params and seed must be
// exactly what core passes (§7 snipe resistance). Anything else gets the
// card (Media{} / cardSVG).
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
	if info.ID != in.CollectionID || info.EngineID != selfPath || info.State != types.StateFinal ||
		info.Params != in.Params {
		return r, false
	}
	salt := b.salt
	if salt == "" {
		salt = finalSalt(info.Salt)
	}
	if salt == "" || in.Seed != safe.Seed(in.CollectionID, in.TokenID, salt) {
		return r, false
	}
	n := tidNum(in.TokenID)
	if n < 1 || n > info.MaxSupply {
		return r, false
	}
	return assign(in.CollectionID, in.TokenID, n, info, b.store, assets.Info(b.store), keyOf(in.CollectionID, b, salt), nil), true
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

// realTraits are the upload-path attributes with the creator's real type
// names, in TraitTypes order: Tier, the creator's traits in store order,
// Edition (when the artwork has more than one) and Storage.
func realTraits(r resolved) []engine.Trait {
	a := r.art
	out := []engine.Trait{}
	if a.Tier != "" {
		out = append(out, engine.Trait{Type: TraitTier, Value: a.Tier})
	}
	for k, v := range a.Traits {
		if v != "" {
			out = append(out, engine.Trait{Type: r.si.TraitTypes[k], Value: v})
		}
	}
	if a.Editions > 1 {
		out = append(out, engine.Trait{Type: TraitEdition, Value: editionLabel(r.edition, a.Editions)})
	}
	out = append(out, engine.Trait{Type: TraitStorage, Value: storageLabel(a.Kind)})
	return out
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
