// Package katman is the adapter of Katman, Sinopia's open PFP tool engine
// (p/…/sinopia/art/katman/v1). Core knows the engine only as this realm's
// package path plus an interface value.
//
// A collection's params name a kit: {"store":<id>,"palette":<name>}. Store 0
// is the art package's built-in demo kit (the engine's sample and Studio
// preview; CheckLaunch never launches it). Any other id is a sealed
// assets/v1 store the artist uploaded; this realm reads it and nothing else.
// The kit layout in a store (docs/engines/katman.md "Kit format"):
//
//   - layers = the store's trait types, bottom first (1..8); the store's
//     tiers are the same names in the same order, so assets.TierSlots gives
//     every layer's weight line in one O(layers) read;
//   - one part = one on-chain SVG artwork: its tier is its layer, its only
//     non-empty trait value (in that layer's column) is the part's name, its
//     editions are the part's rarity weight; artworks are sorted by layer;
//   - every part file is exactly art.Root(w, h) + inner + "</svg>" with one
//     w x h canvas for the whole kit.
//
// A token draws one point per layer from its final seed (art.Draw); since a
// layer's parts are consecutive editions, the point is a slot and
// assets.SlotArtwork its part (O(log n)). Render stacks the drawn parts
// (art.ComposeParts); Traits are layer name = part name.
//
// What holds, and why:
//   - art theft: GateCreate (engine.CreateGate) accepts a store kit only
//     when core's creator owns the store — core passes the creator
//     explicitly, so no OriginCaller read (stores are wallet-owned, so
//     the creator must be that wallet); core's paramsTaken refuses the same params to anyone else, so
//     only the owner's collections use the kit;
//   - no swap after sale: stores are sealed before Create and never change;
//     params are fixed by core;
//   - composition never fails at mint: the creator's Create runs the full
//     kit check (layout, every part's root and size, worst composed token
//     <= MaxSVGBytes); a sealed store and this code never change afterwards.
//     Even an unchecked kit (a Studio preview) composes an allowlisted
//     document: a part that does not fit is left out (art.ComposeParts);
//   - snipe resistance is core's: before Final every token is core's
//     placeholder and the seed does not exist yet; the kit itself is public
//     by design (like an engine's code).
//
// The adapter is stateless, has no admin and holds no coins. Never mark
// this realm private (design §5.4).
package katman

import (
	"errors"
	"strconv"

	art "gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia4/art/katman/v1"
	"gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia4/engine/v2"
	"gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia4/media/v2"
	assets "gno.land/r/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia4/assets/v1"
	"gno.land/r/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia4/core"
)

// Author is the engine-author key that registers, claims and may deprecate
// this engine in core.
func Author() address { return author }

// impl is zero-size and declared here, so core runs it with this realm's
// authority (interrealm v2 borrow rule #1).
type impl struct{}

func (impl) Manifest() engine.Manifest {
	m := art.Manifest()
	m.Author = author
	m.FeeBps = AuthorFeeBps
	return m
}

// ValidateParams accepts "" and the canonical JSON. Store 0 is the demo
// kit. A store kit needs an existing, sealed store laid out as a kit (cheap
// O(layers) reads), in every context, so anyone can preview a kit (Studio's
// RenderWith/TraitsWith); an unchecked kit still renders safely. Who may
// use the kit, and the full per-part check, is GateCreate's job.
func (impl) ValidateParams(params string) error {
	cfg, err := art.ParseParams(params)
	if err != nil {
		return err
	}
	if cfg.Store == 0 {
		return nil
	}
	return checkKit(cfg, "", false)
}

// GateCreate (engine.CreateGate) runs in core.CreateCollection, in the
// creator's transaction, after ValidateParams: a store kit needs the
// creator (as core records it) to own the store, and every part is checked
// (checkKit full). The demo kit needs nothing here (CheckLaunch never
// launches it).
func (impl) GateCreate(c engine.Collection) error {
	cfg, err := art.ParseParams(c.Params)
	if err != nil {
		return err
	}
	if cfg.Store == 0 {
		return nil
	}
	if !c.Creator.IsValid() {
		return errors.New("katman: invalid creator")
	}
	return checkKit(cfg, c.Creator, true)
}

// TraitTypes: the demo kit's layers, or the store kit's layer names.
func (impl) TraitTypes(params string) []string {
	cfg, err := art.ParseParams(params)
	if err != nil || cfg.Store == 0 || !storeExists(cfg.Store) {
		return art.DemoLayerNames()
	}
	names, _ := layout(storeID(cfg.Store))
	return names
}

// CheckLaunch: only a store kit launches (the demo kit is a preview), and
// its store must still be sealed (it always is: sealing is final).
func (impl) CheckLaunch(cid, params string, maxSupply int64) error {
	cfg, err := art.ParseParams(params)
	if err != nil {
		return err
	}
	if cfg.Store == 0 {
		return errors.New("katman: collection " + cid + " uses the demo kit; a launch needs a part store (params store >= 1)")
	}
	if !storeExists(cfg.Store) || !assets.Info(storeID(cfg.Store)).Sealed {
		return errors.New("katman: store " + storeID(cfg.Store) + " is not a sealed store")
	}
	return nil
}

func (impl) Traits(in engine.Input) []engine.Trait {
	cfg := art.MustConfig(in.Params)
	if cfg.Store == 0 {
		return art.Traits(in)
	}
	id := storeID(cfg.Store)
	names, totals := layout(id)
	idx := drawn(id, in.Seed, totals)
	out := make([]engine.Trait, len(names))
	for k, i := range idx {
		v := ""
		if i >= 0 {
			if a := assets.ArtworkMeta(id, i); k < len(a.Traits) {
				v = a.Traits[k]
			}
		}
		if v == "" {
			v = "Part " + strconv.FormatInt(i+1, 10)
		}
		out[k] = engine.Trait{Type: names[k], Value: v}
	}
	return out
}

func (impl) Render(in engine.Input) string {
	cfg := art.MustConfig(in.Params)
	if cfg.Store == 0 {
		return art.Render(in)
	}
	id := storeID(cfg.Store)
	_, totals := layout(id)
	idx := drawn(id, in.Seed, totals)
	parts := make([]string, len(idx))
	for k, i := range idx {
		if i >= 0 {
			parts[k] = assets.ArtworkBytes(id, i) // "" unless a complete on-chain file
		}
	}
	return art.ComposeParts(in.Seed, cfg.Palette, parts)
}

// Media: an svg engine; Render is the art.
func (impl) Media(in engine.Input) engine.Media { return engine.Media{} }

// Register is an explicit call, not init: under the inert package policy
// init runs inside the approver's transaction (RA B-1). It registers this
// realm, once, and core accepts it only when the transaction is signed by
// the manifest author (author, config.gno). salt "" = no commit
// reservation; the fingerprint is in core's in-source reserved table
// (r/core config.gno), so only that key can register this art anywhere.
func Register(cur realm) string {
	return core.RegisterEngine(cross(cur), impl{}, "")
}

// CheckKit is the full kit check of params, without the owner rule: ""
// when a collection over them would be accepted (by the store's owner),
// else the reason. The Create wizard calls it right after Seal (a query).
func CheckKit(params string) string {
	cfg, err := art.ParseParams(params)
	if err != nil {
		return err.Error()
	}
	if cfg.Store == 0 {
		return ""
	}
	if err := checkKit(cfg, "", true); err != nil {
		return err.Error()
	}
	return ""
}

// --- store kits ----------------------------------------------------------------

func storeID(n int64) string { return strconv.FormatInt(n, 10) }

func storeExists(n int64) bool { return n >= 1 && n <= assets.StoreCount() }

// layout is a kit's layer names (its tiers) and weight lines (tier slots).
func layout(id string) ([]string, []int64) {
	names, totals, _ := assets.TierSlots(id)
	return names, totals
}

// drawn maps a seed to the artwork index of every layer's part: the drawn
// point of layer k is slot start_k + point (layers are consecutive slot
// ranges in a checked kit). -1 for a layer without weight (unchecked kits).
func drawn(id, seed string, totals []int64) []int64 {
	at := art.Draw(seed, totals)
	out := make([]int64, len(totals))
	var start int64
	for k, t := range totals {
		out[k] = -1
		if t > 0 {
			out[k], _ = assets.SlotArtwork(id, start+at[k])
		}
		start += t
	}
	return out
}

// checkKit is the kit check. Always (O(layers)): the store exists and is
// sealed; 1..MaxLayers layers; its tiers are its trait types; every layer
// has weight; no untiered artwork; at most MaxParts parts, all on chain,
// at most MaxKitBytes in all. With an owner: owner owns the store. With
// full: every part (O(parts)) — an SVG; sorted by layer;
// exactly its own layer's value set; names unique per layer; at most
// MaxPartsPerLayer per layer; the file is art.Root(w, h) of the first part
// + inner + "</svg>"; and the worst composed token under cfg's palette is at
// most art.MaxSVGBytes.
func checkKit(cfg art.Config, owner address, full bool) error {
	if !storeExists(cfg.Store) {
		return errors.New("katman: unknown store " + storeID(cfg.Store))
	}
	id := storeID(cfg.Store)
	si := assets.Info(id)
	if !si.Sealed {
		return errors.New("katman: store " + id + " is not sealed")
	}
	n := len(si.TraitTypes)
	if n < 1 || n > art.MaxLayers {
		return errors.New("katman: a kit has 1.." + strconv.Itoa(art.MaxLayers) + " layers (the store's trait types)")
	}
	if len(si.Tiers) != n {
		return errors.New("katman: the store's tiers must be its trait types (one tier per layer)")
	}
	for k := range si.Tiers {
		if si.Tiers[k] != si.TraitTypes[k] {
			return errors.New("katman: tier " + strconv.Itoa(k+1) + " must be the layer " + si.TraitTypes[k])
		}
	}
	_, totals, untiered := assets.TierSlots(id)
	if untiered != 0 {
		return errors.New("katman: every part needs its layer as tier")
	}
	for k, t := range totals {
		if t < 1 {
			return errors.New("katman: layer " + si.TraitTypes[k] + " has no part")
		}
	}
	if si.Artworks > art.MaxParts {
		return errors.New("katman: a kit has at most " + strconv.Itoa(art.MaxParts) + " parts")
	}
	if si.OnchainN != si.Artworks {
		return errors.New("katman: every part must be an on-chain SVG")
	}
	if si.OnchainBytes > art.MaxKitBytes {
		return errors.New("katman: a kit holds at most " + strconv.Itoa(art.MaxKitBytes) + " bytes of parts")
	}
	if owner.IsValid() && owner != si.Owner {
		return errors.New("katman: the creator does not own store " + id)
	}
	if !full {
		return nil
	}
	root, w, h := "", 0, 0
	maxInner := make([]int, n)
	count := make([]int, n)
	seen := map[string]bool{}
	prev := 0
	for i := int64(0); i < si.Artworks; i++ {
		at := "katman: part " + strconv.FormatInt(i+1, 10) + ": "
		a := assets.ArtworkMeta(id, i)
		if a.Mime != media.MimeSVG {
			return errors.New(at + "must be an SVG")
		}
		k := -1
		for j, t := range si.Tiers {
			if t == a.Tier {
				k = j
			}
		}
		if k < prev {
			return errors.New(at + "parts must be sorted by layer (tier)")
		}
		prev = k
		for j, v := range a.Traits {
			if (j == k) != (v != "") {
				return errors.New(at + "must name itself in its own layer " + si.TraitTypes[k] + " only")
			}
		}
		if key := strconv.Itoa(k) + "|" + a.Traits[k]; seen[key] {
			return errors.New(at + "two parts of layer " + si.TraitTypes[k] + " are named " + a.Traits[k])
		} else {
			seen[key] = true
		}
		count[k]++
		if count[k] > art.MaxPartsPerLayer {
			return errors.New(at + "a layer has at most " + strconv.Itoa(art.MaxPartsPerLayer) + " parts")
		}
		file := assets.ArtworkBytes(id, i)
		if root == "" {
			r, ww, hh, ok := art.ParseRoot(file)
			if !ok {
				return errors.New(at + `must start with <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 W H"> (W, H 1..4096)`)
			}
			root, w, h = r, ww, hh
		}
		inner, ok := art.Inner(file, root)
		if !ok {
			return errors.New(at + "must start with the kit's root " + root + " and end with </svg>")
		}
		if len(inner) > maxInner[k] {
			maxInner[k] = len(inner)
		}
	}
	if worst := art.WorstBytes(root, w, h, cfg.Palette, maxInner); worst > art.MaxSVGBytes {
		return errors.New("katman: the largest token would be " + strconv.Itoa(worst) + " bytes; at most " +
			strconv.Itoa(art.MaxSVGBytes) + " (make the largest part of some layer smaller)")
	}
	return nil
}
