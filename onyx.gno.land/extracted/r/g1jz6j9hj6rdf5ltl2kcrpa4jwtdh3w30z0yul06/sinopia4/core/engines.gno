package core

import (
	"chain"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strings"

	"gno.land/p/nt/avl/v0"

	"gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia4/engine/v2"
	"gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia4/safe/v2"
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
	deprecatedBy     string // "author" or "admin" (engine.deprecate)
	superseded       bool   // a reserved registration of the same art won (I-14)
	supersededBy     string // engine id
	reviewed         bool
	registeredHeight int64
	reservation      string // reservationSource, reservationCommit or ""
	priority         int64  // 0 (in source), the reservation height, or registeredHeight
	collections      int64  // collections created on this engine (CollectionsByEngine)
	policy           string // PolicyClosed (at registration), PolicyLicensed or PolicyOpen (access.gno, I-19)
	licences         int64  // live licences (<= MaxLicencesPerEngine)
}

// Engine statuses (EngineStatus, engine JSON "status").
const (
	EngineUnclaimed  = "unclaimed"
	EngineUnverified = "unverified"
	EngineReviewed   = "reviewed"
	EngineDeprecated = "deprecated"
	EngineSuperseded = "superseded"
)

const (
	reservationSource = "source" // fingerprint reserved in config.gno
	reservationCommit = "commit" // backed by a ReserveFingerprint commitment
)

var (
	engines       avl.Tree // engine id -> *engineRecord
	engineOrder   avl.Tree // safe.PadInt(seq) -> engine id
	byFingerprint avl.Tree // fingerprint + ":" + engine id -> "" (CV-L3)
	byEngine      avl.Tree // engine id + ":" + padded cid -> cid (CollectionsByEngine, M-18)
	engineCount   int64

	// reservations: author + ":" + commit -> *fpReservation (ENG-M1). Keyed
	// by author so copying a pending commitment from the mempool only
	// creates a useless entry under the copier's own address.
	reservations avl.Tree
)

type fpReservation struct {
	height int64
}

// RegisterEngine stores the calling realm's engine (I-16: the manifest,
// default params and one sample render with its traits, in the engine's
// own registration transaction). The record is immutable afterwards except
// for the claim/deprecate/review/superseded flags, the collection count and
// the access policy (access.gno: every engine starts closed).
//
// salt is "" or the salt of a ReserveFingerprint commitment made by the
// manifest author (ENG-M1 rule 2). Fingerprint rules (I-14), with signer =
// OriginCaller:
//   - every registration must be signed by its manifest author (signer ==
//     Manifest.Author; WP-J J-2: otherwise a tx the author of a live engine
//     signs into a foreign realm could register a re-wrap of that art under
//     another author, since CV-L3 exempts the author's own versions);
//   - a fingerprint reserved in source (config.gno) registers only with
//     signer == Manifest.Author == its reserved author;
//   - a live record of the same art by another author (not deprecated, not
//     superseded) blocks the registration (CV-L3) unless this registration
//     is reserved in source, or backed by a reservation made before that
//     record's own priority (so the record was registered after the
//     reservation's commit; WP-J J-3), or the record is unclaimed and older
//     than UnclaimedHoldBlocks; such records are marked superseded instead.
func RegisterEngine(cur realm, e engine.Engine, salt string) string {
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

	fp := safe.Sha256Hex(sample)
	h := height()
	signer := unsafe.OriginCaller()
	kind, priority, resKey := registrationPriority(fp, m.Author, signer, salt, h)
	losers := conflicts(fp, m.Author, kind, priority, h)
	// every check passed: consume the reservation, then write
	if resKey != "" {
		reservations.Remove(resKey)
	}
	rec := &engineRecord{
		id:               id,
		impl:             e,
		manifest:         m,
		fingerprint:      fp,
		registeredHeight: h,
		reservation:      kind,
		priority:         priority,
		policy:           PolicyClosed,
	}
	engines.Set(id, rec)
	byFingerprint.Set(fp+":"+id, "")
	engineCount++
	engineOrder.Set(safe.PadInt(engineCount, cidWidth), id)
	chain.Emit("EngineRegistered", "id", id, "author", m.Author.String(), "feeBps", itoa(m.FeeBps),
		"fingerprint", rec.fingerprint, "kind", m.Kind, "reservation", kind)
	for _, l := range losers {
		l.superseded, l.supersededBy = true, id
		chain.Emit("EngineSuperseded", "id", l.id, "by", id)
	}
	return id
}

// registrationPriority applies the reservation rules and returns the
// registration's kind, priority (lower wins) and the reservation key it
// consumes ("" for none). It writes nothing.
func registrationPriority(fp string, author, signer address, salt string, h int64) (string, int64, string) {
	if reserved, ok := reservedAuthorOf(fp); ok {
		if signer != reserved || author != reserved {
			panic("fingerprint " + fp + " is reserved for " + reserved.String() +
				"; only that author may register it (signed by and named in the manifest)")
		}
		return reservationSource, 0, ""
	}
	if signer != author {
		panic("an engine registration must be signed by the manifest author " + author.String())
	}
	if salt == "" {
		return "", h, ""
	}
	if len(salt) < MinReserveSaltLen || len(salt) > MaxReserveSaltLen {
		panic("reservation salt must be " + itoa(MinReserveSaltLen) + ".." + itoa(MaxReserveSaltLen) + " bytes")
	}
	safe.AssertText("salt", salt, MaxReserveSaltLen)
	commit := ReservationCommit(runtime.ChainID(), fp, author, salt)
	key := author.String() + ":" + commit
	v := reservations.Get(key)
	if v == nil {
		panic("no fingerprint reservation of " + author.String() + " matches this engine and salt")
	}
	r := v.(*fpReservation)
	if h <= r.height {
		panic("the reservation is usable from height " + itoa(r.height+1))
	}
	if h > r.height+ReservationTTLBlocks {
		panic("the reservation expired at height " + itoa(r.height+ReservationTTLBlocks))
	}
	return reservationCommit, r.height, key
}

// conflicts returns the live records of the same art by other authors that
// this registration (by author, who signed it) supersedes, and panics on one
// that blocks it (CV-L3, I-14). A deprecated or superseded record never
// blocks.
//
// A commit reservation (priority = its ReserveFingerprint height) beats only
// a record with a later priority: a plain record registered after the
// commit height, or a record backed by a later reservation. A record
// registered at or before the commit height — claimed or not — is never
// superseded by it (WP-J J-3; rec.priority <= rec.registeredHeight, so a
// later priority implies a later registration). Unclaimed records still
// expire after UnclaimedHoldBlocks for every registration.
func conflicts(fp string, author address, kind string, priority, h int64) []*engineRecord {
	var losers []*engineRecord
	byFingerprint.Iterate(fp+":", fp+";", func(k string, _ any) bool {
		rec := mustEngine(k[len(fp)+1:])
		if rec.deprecated || rec.superseded || rec.manifest.Author == author {
			return false
		}
		switch {
		case kind == reservationSource:
		case !rec.claimed && h > rec.registeredHeight+UnclaimedHoldBlocks:
		case kind == reservationCommit && rec.priority > priority && rec.registeredHeight > priority:
		default:
			panic("engine renders the same art as " + rec.id + "; only its author " + rec.manifest.Author.String() +
				" may register another version (or deprecate it first)")
		}
		losers = append(losers, rec)
		return false
	})
	return losers
}

// reservedAuthorOf is fp's in-source reserved author (config.gno).
func reservedAuthorOf(fp string) (address, bool) {
	for _, r := range reservedFingerprints {
		if r.fingerprint == fp {
			return r.author, true
		}
	}
	return "", false
}

// ReserveFingerprint records a commitment to register an engine whose art
// is not public yet (ENG-M1 rule 2):
//
//	commit = ReservationCommit(chainId, fingerprint, author, salt)
//
// with salt 32..256 bytes. The caller (a wallet) is the author; the
// reservation is usable from the next block for ReservationTTLBlocks by a
// RegisterEngine(…, salt) signed by that author with that Manifest.Author.
// The commitment reveals nothing, so it cannot be front-run.
func ReserveFingerprint(cur realm, commitHex string) {
	assertNoDeposit(cur)
	if !cur.Previous().IsUserCall() {
		panic("reserve a fingerprint from the author's wallet")
	}
	author := caller(cur)
	commit := safe.AssertHex("commit", commitHex, 32)
	key := author.String() + ":" + commit
	h := height()
	if v := reservations.Get(key); v != nil && h <= v.(*fpReservation).height+ReservationTTLBlocks {
		panic("this commitment is already reserved until height " + itoa(v.(*fpReservation).height+ReservationTTLBlocks))
	}
	reservations.Set(key, &fpReservation{height: h})
	chain.Emit("FingerprintReserved", "author", author.String(), "commit", commit,
		"height", itoa(h), "expires", itoa(h+ReservationTTLBlocks))
}

// ReservationCommit is the commitment ReserveFingerprint takes:
// sha256("art|fpres|v1|" + chainID + "|" + fp + "|" + author + "|" + salt).
func ReservationCommit(chainID, fp string, author address, salt string) string {
	return safe.Sha256Hex(safe.Domain + "|fpres|v1|" + chainID + "|" + fp + "|" + author.String() + "|" + salt)
}

// Reservation is the reservation of author for commitHex as JSON
// {author, commit, height, validFrom, expires, active}, or null.
func Reservation(author address, commitHex string) string {
	v := reservations.Get(author.String() + ":" + commitHex)
	if v == nil {
		return "null"
	}
	r := v.(*fpReservation)
	h := height()
	w := &safe.JSONWriter{}
	w.BeginObject()
	w.StrField("author", author.String())
	w.StrField("commit", commitHex)
	w.IntField("height", r.height)
	w.IntField("validFrom", r.height+1)
	w.IntField("expires", r.height+ReservationTTLBlocks)
	w.BoolField("active", h > r.height && h <= r.height+ReservationTTLBlocks)
	w.EndObject()
	return w.String()
}

// ReservedAuthor is fp's in-source reserved author, or "".
func ReservedAuthor(fp string) address {
	a, _ := reservedAuthorOf(fp)
	return a
}

// ReservedFingerprints is the in-source table as JSON [{name, fingerprint, author}].
func ReservedFingerprints() string {
	w := &safe.JSONWriter{}
	w.BeginArray()
	for _, r := range reservedFingerprints {
		w.BeginObject()
		w.StrField("name", r.name)
		w.StrField("fingerprint", r.fingerprint)
		w.StrField("author", r.author.String())
		w.EndObject()
	}
	w.EndArray()
	return w.String()
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
	rec.deprecated, rec.deprecatedBy = true, "author"
	chain.Emit("EngineDeprecated", "id", id, "by", "author")
}

// --- engine-author fee ---------------------------------------------------------
//
// An engine's author earns FeeBps (manifest, fixed at registration, <=
// EngineFeeCapBps) of every primary and secondary sale of a collection that
// uses the engine, capped by the platform's fees.EngineCapBps. A collection
// snapshots the fee at Launch (like the protocol fee, SA-I5) and later sales
// pay min(snapshot, current platform cap), so neither the author nor the
// admin can raise it on a running collection. No fee when the creator is
// the author: the creator's own payees already get the sale.

// engineFeeOf is the engine's fee under the current platform cap.
func engineFeeOf(rec *engineRecord) int64 {
	if rec.manifest.FeeBps < fees.EngineCapBps {
		return rec.manifest.FeeBps
	}
	return fees.EngineCapBps
}

// engineFeeQuote is what c would snapshot at a Launch now.
func engineFeeQuote(c *collection) (address, int64) {
	rec := mustEngine(c.engineID)
	author := rec.manifest.Author
	if author == c.creator {
		return author, 0
	}
	if c.licenceFee == LicenceFeeDefault {
		return author, engineFeeOf(rec)
	}
	if c.licenceFee < fees.EngineCapBps {
		return author, c.licenceFee
	}
	return author, fees.EngineCapBps
}

// collectionEngineFee is the fee a sale of c pays now: the Launch snapshot
// bounded by the current cap; before Launch, the current quote.
func collectionEngineFee(c *collection) (address, int64) {
	if c.prov == nil {
		return engineFeeQuote(c)
	}
	if c.engineBps < fees.EngineCapBps {
		return c.engineAuthor, c.engineBps
	}
	return c.engineAuthor, fees.EngineCapBps
}

// EngineFee is the engine-author share of cid's sales: the author and the
// bps a sale pays now (0 when the creator is the author). mint/v1 and
// market/v1 pay safe.BpsOf(amount, bps) to author.
func EngineFee(cid string) (author address, bps int64) {
	return collectionEngineFee(mustCollection(cid))
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
// a data URI — Studio previews and the Verify button. For a media engine it
// is the card.
func RenderWith(id, params, seed string) string {
	return renderChecked(mustEngine(id), studioInput(params, seed))
}

// RenderWithInput is RenderWith for a full Input, so living engines can be
// verified off chain and against their TS twins (M-24). CollectionID and
// TokenID are "0" and Salt "" as in every studio render; firstOwner is
// passed through as Input.FirstOwner ("" = none).
func RenderWithInput(id, params, seed string, mintHeight, lastMove, moves, h int64, firstOwner address) string {
	in := studioInput(params, seed)
	in.MintHeight, in.LastMoveHeight, in.Moves, in.Height = mintHeight, lastMove, moves, h
	in.FirstOwner = firstOwner
	return renderChecked(mustEngine(id), in)
}

func renderChecked(rec *engineRecord, in engine.Input) string {
	if err := rec.impl.ValidateParams(in.Params); err != nil {
		panic("params rejected by engine: " + err.Error())
	}
	svg := rec.impl.Render(in)
	if err := engine.CheckSVG(rec.manifest, svg); err != nil {
		return dataURI(placeholderSVG(rec.manifest.Name, "Engine output rejected"))
	}
	return dataURI(svg)
}

// EngineTraits returns a core-owned copy of the engine's traits for seed,
// checked against TraitTypes(params).
func EngineTraits(id, params, seed string) []engine.Trait {
	rec := mustEngine(id)
	if err := rec.impl.ValidateParams(params); err != nil {
		panic("params rejected by engine: " + err.Error())
	}
	tts := rec.impl.TraitTypes(params)
	if err := engine.ValidateTraitTypes(tts); err != nil {
		panic("trait types rejected: " + err.Error())
	}
	ts := rec.impl.Traits(studioInput(params, seed))
	if err := engine.ValidateTraitsFor(tts, ts); err != nil {
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

// EngineStatus is "unclaimed", "unverified", "reviewed", "deprecated" or
// "superseded".
func EngineStatus(id string) string { return engineStatus(mustEngine(id)) }

func engineStatus(rec *engineRecord) string {
	switch {
	case rec.deprecated:
		return EngineDeprecated
	case rec.superseded:
		return EngineSuperseded
	case !rec.claimed:
		return EngineUnclaimed
	case rec.reviewed:
		return EngineReviewed
	}
	return EngineUnverified
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

// EnginesByFingerprint pages every record with fingerprint fp, in path
// order (the deploy check's squat scan).
func EnginesByFingerprint(fp string, offset, limit int64) string {
	w := &safe.JSONWriter{}
	w.BeginArray()
	skipped, written, want := int64(0), int64(0), clampLimit(limit)
	byFingerprint.Iterate(fp+":", fp+";", func(k string, _ any) bool {
		if skipped < offset {
			skipped++
			return false
		}
		writeEngine(w, mustEngine(k[len(fp)+1:]))
		written++
		return written >= want
	})
	w.EndArray()
	return w.String()
}

// CollectionsByEngine pages the collections created on engine id, in
// creation order (M-18). The count is the engine JSON's "collections".
func CollectionsByEngine(id string, offset, limit int64) string {
	mustEngine(id)
	w := &safe.JSONWriter{}
	w.BeginArray()
	prefix := id + ":"
	skipped, written, want := int64(0), int64(0), clampLimit(limit)
	byEngine.Iterate(prefix, prefix+"\xff", func(_ string, v any) bool {
		if skipped < offset {
			skipped++
			return false
		}
		writeCollection(w, mustCollection(v.(string)))
		written++
		return written >= want
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
	w.IntField("feeBps", m.FeeBps)
	w.IntField("effectiveFeeBps", engineFeeOf(rec))
	w.StrField("paramsSchema", m.ParamsSchema)
	w.Key("traitTypes")
	writeStrings(w, m.TraitTypes)
	w.BoolField("living", m.Living)
	w.IntField("maxSvgBytes", m.MaxSVGBytes)
	w.StrField("kind", m.Kind)
	w.IntField("maxMediaBytes", m.MaxMediaBytes)
	w.StrField("fingerprint", rec.fingerprint)
	w.StrField("status", engineStatus(rec))
	w.IntField("registeredHeight", rec.registeredHeight)
	w.StrField("reservation", rec.reservation)
	w.IntField("priority", rec.priority)
	w.StrField("supersededBy", rec.supersededBy)
	w.StrField("deprecatedBy", rec.deprecatedBy)
	w.IntField("collections", rec.collections)
	w.StrField("policy", rec.policy)
	w.IntField("licences", rec.licences)
	w.EndObject()
}

func writeStrings(w *safe.JSONWriter, list []string) {
	w.BeginArray()
	for _, t := range list {
		w.Str(t)
	}
	w.EndArray()
}

func studioInput(params, seed string) engine.Input {
	in := engine.SampleInput()
	in.Seed = seed
	in.Params = params
	in.Height = height()
	return in
}
