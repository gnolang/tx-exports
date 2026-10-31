package core

import (
	"chain"
	"chain/runtime"
	"strings"

	"gno.land/p/nt/avl/v0"

	"gno.land/p/g19dzk54hhsdc3gllpksuj6gu4a3e6fl8cr6rn4w/minhwa/engine/v1"
	"gno.land/p/g19dzk54hhsdc3gllpksuj6gu4a3e6fl8cr6rn4w/minhwa/safe/v1"
)

// Engine registry ("art as code", design §5).
//
// An engine registers itself from its own /r/ adapter realm; its id is that
// realm's package path, so nobody can register in someone else's name. The
// stored interface value's methods are declared in the adapter, so every
// call runs with the adapter's authority, not core's (interrealm v2 borrow
// rule #1): engine code cannot write core state. It also cannot call back
// into a core mutator: all of core's state-changing functions are crossing
// and need a live cur the engine never has.
//
// Honest limits, surfaced to users rather than hidden:
//   - an adapter realm with state could change its art later; the sample
//     fingerprint (VerifyEngine) detects a change of the sample, and review
//     means reading the adapter for statelessness;
//   - a private (re-deployable) adapter cannot register: the VM aborts the
//     registration when core's state would retain the private realm's type
//     (spike A9, observed in gno v1.7.0 test mode; confirm on Onyx).
type engineRecord struct {
	id               string
	impl             engine.Engine
	manifest         engine.Manifest // core-owned copy
	fingerprint      string          // sha256 of Render(SampleInput())
	claimed          bool
	deprecated       bool
	reviewed         bool
	registeredHeight int64
}

var (
	engines     avl.Tree // engine id -> *engineRecord
	engineOrder avl.Tree // safe.PadInt(seq) -> engine id
	engineCount int64
)

// RegisterEngine stores the calling realm's engine (I-12 exception: one
// sample render in the engine's own registration transaction). The record
// is immutable afterwards except for the claim/deprecate/review flags.
func RegisterEngine(cur realm, e engine.Engine) string {
	id := cur.Previous().PkgPath()
	if !strings.HasPrefix(id, runtime.ChainDomain()+"/r/") || strings.Contains(id, "#") {
		panic("an engine registers from its own realm (an /r/ package, not a sub-realm or wallet)")
	}
	if e == nil {
		panic("nil engine")
	}
	if engines.Has(id) {
		panic("engine already registered: " + id + " (publish a new version under a new path)")
	}
	m := copyManifest(e.Manifest())
	if err := engine.ValidateManifest(m); err != nil {
		panic(err)
	}
	if err := e.ValidateParams(""); err != nil {
		panic("engine must accept empty params (its defaults): " + err.Error())
	}
	sample := e.Render(engine.SampleInput())
	if err := engine.CheckSVG(m, sample); err != nil {
		panic("sample render: " + err.Error())
	}
	if err := engine.ValidateTraits(m, e.Traits(engine.SampleInput())); err != nil {
		panic("sample traits: " + err.Error())
	}

	rec := &engineRecord{
		id:               id,
		impl:             e,
		manifest:         m,
		fingerprint:      safe.Sha256Hex(sample),
		registeredHeight: height(),
	}
	engines.Set(id, rec)
	engineCount++
	engineOrder.Set(safe.PadInt(engineCount, cidWidth), id)
	chain.Emit("EngineRegistered", "id", id, "author", m.Author.String(), "fingerprint", rec.fingerprint)
	return id
}

// ClaimEngine proves the manifest author controls that address. Unclaimed
// engines cannot back a collection.
func ClaimEngine(cur realm, id string) {
	assertNoDeposit(cur)
	rec := mustEngine(id)
	if caller(cur) != rec.manifest.Author {
		panic("only the manifest author " + rec.manifest.Author.String() + " can claim this engine")
	}
	rec.claimed = true
	chain.Emit("EngineClaimed", "id", id)
}

// DeprecateEngine stops new collections; existing ones keep rendering.
func DeprecateEngine(cur realm, id string) {
	assertNoDeposit(cur)
	rec := mustEngine(id)
	if !rec.claimed || caller(cur) != rec.manifest.Author {
		panic("only the engine's author can deprecate it")
	}
	rec.deprecated = true
	chain.Emit("EngineDeprecated", "id", id)
}

func mustEngine(id string) *engineRecord {
	v := engines.Get(id)
	if v == nil {
		panic("unknown engine " + id)
	}
	return v.(*engineRecord)
}

// copyManifest gives core its own copy: the engine's slice was allocated in
// the engine realm.
func copyManifest(m engine.Manifest) engine.Manifest {
	out := m
	out.TraitTypes = append([]string{}, m.TraitTypes...)
	return out
}

// --- engine reads (Studio, Verify) -------------------------------------------

// RenderWith renders any registered engine for arbitrary params and seed as
// a data URI — Studio previews and the Verify button.
func RenderWith(id, params, seed string) string {
	rec := mustEngine(id)
	if err := rec.impl.ValidateParams(params); err != nil {
		panic("params rejected by engine: " + err.Error())
	}
	svg := rec.impl.Render(studioInput(params, seed))
	if err := engine.CheckSVG(rec.manifest, svg); err != nil {
		return dataURI(placeholderSVG(rec.manifest.Name, "Engine output rejected"))
	}
	return dataURI(svg)
}

// EngineTraits returns a core-owned copy of the engine's traits for seed.
func EngineTraits(id, params, seed string) []engine.Trait {
	rec := mustEngine(id)
	if err := rec.impl.ValidateParams(params); err != nil {
		panic("params rejected by engine: " + err.Error())
	}
	ts := rec.impl.Traits(studioInput(params, seed))
	if err := engine.ValidateTraits(rec.manifest, ts); err != nil {
		panic("engine traits rejected: " + err.Error())
	}
	return append([]engine.Trait{}, ts...)
}

func TraitsWith(id, params, seed string) string {
	w := &safe.JSONWriter{}
	writeTraits(w, EngineTraits(id, params, seed))
	return w.String()
}

// VerifyEngine re-renders the sample and compares it with the fingerprint
// stored at registration.
func VerifyEngine(id string) bool {
	rec := mustEngine(id)
	return safe.Sha256Hex(rec.impl.Render(engine.SampleInput())) == rec.fingerprint
}

// EngineManifest is the typed read for other realms (gallery).
func EngineManifest(id string) engine.Manifest { return copyManifest(mustEngine(id).manifest) }

// EngineStatus is "unclaimed", "unverified", "reviewed" or "deprecated".
func EngineStatus(id string) string { return engineStatus(mustEngine(id)) }

func engineStatus(rec *engineRecord) string {
	switch {
	case rec.deprecated:
		return "deprecated"
	case !rec.claimed:
		return "unclaimed"
	case rec.reviewed:
		return "reviewed"
	}
	return "unverified"
}

// Engine is the record as JSON.
func Engine(id string) string {
	w := &safe.JSONWriter{}
	writeEngine(w, mustEngine(id))
	return w.String()
}

func Engines(offset, limit int64) string {
	w := &safe.JSONWriter{}
	w.BeginArray()
	engineOrder.IterateByOffset(int(offset), int(clampLimit(limit)), func(_ string, v any) bool {
		writeEngine(w, mustEngine(v.(string)))
		return false
	})
	w.EndArray()
	return w.String()
}

func writeEngine(w *safe.JSONWriter, rec *engineRecord) {
	m := rec.manifest
	w.BeginObject()
	w.StrField("id", rec.id)
	w.StrField("pkgPath", rec.id) // the adapter realm; read its source (and imports) with vm/qfile
	w.StrField("name", m.Name)
	w.StrField("version", m.Version)
	w.StrField("description", m.Description)
	w.StrField("license", m.License)
	w.StrField("author", m.Author.String())
	w.StrField("paramsSchema", m.ParamsSchema)
	w.Key("traitTypes")
	w.BeginArray()
	for _, t := range m.TraitTypes {
		w.Str(t)
	}
	w.EndArray()
	w.BoolField("living", m.Living)
	w.IntField("maxSvgBytes", m.MaxSVGBytes)
	w.StrField("fingerprint", rec.fingerprint)
	w.StrField("status", engineStatus(rec))
	w.IntField("registeredHeight", rec.registeredHeight)
	w.EndObject()
}

func studioInput(params, seed string) engine.Input {
	in := engine.SampleInput()
	in.Seed = seed
	in.Params = params
	in.Height = height()
	return in
}
