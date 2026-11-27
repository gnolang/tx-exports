package core

import (
	"chain"

	"gno.land/p/nt/avl/v0"

	"gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia4/safe/v2"
)

// Engine access policy (I-19, docs/mainnet/engine-access-policy.md).
//
// An engine's author decides who may open collections with it:
//
//   - closed   ("signature engine") only the author. Every registration
//     starts closed: nothing an author did not choose to share is usable
//     by others, and a squat copy stays useless to everyone else.
//   - licensed only the author and the creators the author licensed
//     (GrantLicence), each for a bounded number of collections and,
//     optionally, at a licence fee instead of the manifest's.
//   - open     ("tool engine") anyone.
//
// The policy is judged once, in CreateCollection, and never again: a
// policy change, a revoked or used-up licence leaves every collection
// already created (Drafts included) as it is. Only the claimed manifest
// author changes a policy or a licence; no admin op touches them (the
// admin's engine.deprecate still stops new collections for everyone).
//
// For every policy, a collection whose engine and params are byte-identical
// to an earlier collection's is refused unless its creator is that earlier
// collection's current creator (paramsTaken). Empty params (the engine's
// defaults) are exempt: an engine without params (genesis) would otherwise
// back one collection ever.

// Policies.
const (
	PolicyClosed   = "closed"
	PolicyLicensed = "licensed"
	PolicyOpen     = "open"
)

// How a collection's creator was allowed to use the engine (collection
// JSON "access", CollectionCreated.access).
const (
	AccessAuthor  = "author"
	AccessLicence = "licence"
	AccessOpen    = "open"
)

const (
	MaxLicencesPerEngine  = 1000 // live licences of one engine (GrantLicence of a new holder)
	MaxLicenceCollections = 1000 // collections one licence allows
	LicenceFeeDefault     = -1   // GrantLicence feeBps: the manifest's FeeBps applies
)

type licence struct {
	maxCollections int64
	used           int64 // collections created under this licence
	feeBps         int64 // LicenceFeeDefault or 0..EngineFeeCapBps, snapshotted into each collection
	grantedHeight  int64 // last GrantLicence of this holder
}

var (
	licences    avl.Tree // engine id + ":" + holder -> *licence
	paramsTaken avl.Tree // paramsKey(engine id, params) -> cid of the first collection with them
)

// SetEnginePolicy sets who may create collections with engine id: "closed",
// "licensed" or "open". The claimed manifest author only; refused for a
// deprecated or superseded engine (it backs no new collection anyway).
func SetEnginePolicy(cur realm, id, policy string) {
	assertNoDeposit(cur)
	rec := mustEngine(id)
	assertEngineAuthor(cur, rec, "set its policy")
	assertEngineNotRetired(rec)
	if policy != PolicyClosed && policy != PolicyLicensed && policy != PolicyOpen {
		panic("policy must be \"" + PolicyClosed + "\", \"" + PolicyLicensed + "\" or \"" + PolicyOpen + "\"")
	}
	rec.policy = policy
	chain.Emit("EnginePolicySet", "id", id, "policy", policy)
}

// GrantLicence lets holder create up to maxCollections (1..
// MaxLicenceCollections) collections with engine id while its policy is
// "licensed". feeBps is LicenceFeeDefault (-1, the manifest fee) or
// 0..EngineFeeCapBps: the engine-author fee of the holder's collections,
// snapshotted at their creation (a sale still pays at most the platform
// cap). Granting again to a holder updates maxCollections (not below the
// used count) and feeBps and keeps the used count. Claimed author only;
// not on a deprecated or superseded engine. A grant does not change the
// policy.
func GrantLicence(cur realm, id string, holder address, maxCollections, feeBps int64) {
	assertNoDeposit(cur)
	rec := mustEngine(id)
	assertEngineAuthor(cur, rec, "grant a licence")
	assertEngineNotRetired(rec)
	if !holder.IsValid() {
		panic("invalid licence holder address")
	}
	if holder == rec.manifest.Author {
		panic("the engine's author needs no licence")
	}
	if maxCollections < 1 || maxCollections > MaxLicenceCollections {
		panic("maxCollections must be 1.." + itoa(MaxLicenceCollections))
	}
	if feeBps != LicenceFeeDefault && (feeBps < 0 || feeBps > EngineFeeCapBps) {
		panic("licence feeBps must be -1 (the manifest fee) or 0.." + itoa(EngineFeeCapBps))
	}
	key := licenceKey(id, holder)
	l, _ := licences.Get(key).(*licence)
	if l == nil {
		if rec.licences >= MaxLicencesPerEngine {
			panic("engine has " + itoa(MaxLicencesPerEngine) + " licences; revoke one first")
		}
		l = &licence{}
		licences.Set(key, l)
		rec.licences++
	} else if maxCollections < l.used {
		panic("maxCollections must be at least the " + itoa(l.used) +
			" collections already created under this licence (revoke it to stop it)")
	}
	l.maxCollections, l.feeBps, l.grantedHeight = maxCollections, feeBps, height()
	chain.Emit("LicenceGranted", "id", id, "holder", holder.String(),
		"maxCollections", itoa(maxCollections), "feeBps", itoa(feeBps))
}

// RevokeLicence removes holder's licence on engine id. Collections already
// created under it are not affected. Claimed author only (also on a
// deprecated or superseded engine).
func RevokeLicence(cur realm, id string, holder address) {
	assertNoDeposit(cur)
	rec := mustEngine(id)
	assertEngineAuthor(cur, rec, "revoke a licence")
	key := licenceKey(id, holder)
	v := licences.Get(key)
	if v == nil {
		panic(holder.String() + " holds no licence on " + id)
	}
	licences.Remove(key)
	rec.licences--
	chain.Emit("LicenceRevoked", "id", id, "holder", holder.String(), "used", itoa(v.(*licence).used))
}

func assertEngineAuthor(cur realm, rec *engineRecord, what string) {
	if caller(cur) != rec.manifest.Author {
		panic("only the engine's author " + rec.manifest.Author.String() + " can " + what)
	}
	if !rec.claimed {
		panic("engine is not claimed by its author yet")
	}
}

func assertEngineNotRetired(rec *engineRecord) {
	if rec.deprecated {
		panic("engine is deprecated")
	}
	if rec.superseded {
		panic("engine is superseded by " + rec.supersededBy)
	}
}

func licenceKey(id string, holder address) string { return id + ":" + holder.String() }

// paramsKey identifies an (engine, params) pair in bounded space.
func paramsKey(id, params string) string {
	return safe.Sha256Hex(safe.Domain + "|params|v1|" + id + "|" + params)
}

// createGrant is what CreateCollection learned from the access gate.
type createGrant struct {
	access string
	lic    *licence // the licence used (AccessLicence), else nil
	fee    int64    // engine fee override snapshotted into the collection, or LicenceFeeDefault
	key    string   // paramsKey, "" for empty params
	reuse  bool     // key already held by this creator
}

// createAccess is the engine side of CreateCollection's gate: engine
// usable (claimed, live), creator allowed by the policy, params not held
// by another creator. It returns the refusal text ("" = allowed) and
// writes nothing; CreateCollection panics with that text and CreateRefusal
// returns it.
func createAccess(rec *engineRecord, creator address, params string) (createGrant, string) {
	g := createGrant{fee: LicenceFeeDefault}
	switch {
	case !rec.claimed:
		return g, "engine is not claimed by its author yet"
	case rec.deprecated:
		return g, "engine is deprecated"
	case rec.superseded:
		return g, "engine is superseded by " + rec.supersededBy
	}
	switch {
	case creator == rec.manifest.Author:
		g.access = AccessAuthor
	case rec.policy == PolicyOpen:
		g.access = AccessOpen
	case rec.policy == PolicyLicensed:
		l, _ := licences.Get(licenceKey(rec.id, creator)).(*licence)
		if l == nil {
			return g, "engine " + rec.id + " is licensed: " + creator.String() +
				" holds no licence from its author " + rec.manifest.Author.String()
		}
		if l.used >= l.maxCollections {
			return g, "the licence of " + creator.String() + " on " + rec.id + " is used up (" +
				itoa(l.used) + "/" + itoa(l.maxCollections) + " collections)"
		}
		g.access, g.lic, g.fee = AccessLicence, l, l.feeBps
	default:
		return g, "engine " + rec.id + " is closed: only its author " + rec.manifest.Author.String() +
			" creates collections with it"
	}
	if params == "" {
		return g, ""
	}
	g.key = paramsKey(rec.id, params)
	if v := paramsTaken.Get(g.key); v != nil {
		first := mustCollection(v.(string))
		if first.creator != creator {
			return g, "engine " + rec.id + " with these params already backs collection " + first.id +
				" of another creator; choose other params"
		}
		g.reuse = true
	}
	return g, ""
}

// --- reads ---------------------------------------------------------------------

// EnginePolicy is engine id's policy: "closed", "licensed" or "open".
func EnginePolicy(id string) string { return mustEngine(id).policy }

// Licensed reports whether holder holds a licence on engine id with room
// for another collection (whatever the current policy).
func Licensed(id string, holder address) bool {
	mustEngine(id)
	l, _ := licences.Get(licenceKey(id, holder)).(*licence)
	return l != nil && l.used < l.maxCollections
}

// Licence is holder's licence on engine id as JSON
// {engine, holder, maxCollections, used, feeBps, grantedHeight}, or null.
func Licence(id string, holder address) string {
	mustEngine(id)
	v := licences.Get(licenceKey(id, holder))
	if v == nil {
		return "null"
	}
	w := &safe.JSONWriter{}
	writeLicence(w, id, holder.String(), v.(*licence))
	return w.String()
}

// Licences pages engine id's licences in holder-address order.
func Licences(id string, offset, limit int64) string {
	mustEngine(id)
	w := &safe.JSONWriter{}
	w.BeginArray()
	prefix := id + ":"
	skipped, written, want := int64(0), int64(0), clampLimit(limit)
	licences.Iterate(prefix, prefix+"\xff", func(k string, v any) bool {
		if skipped < offset {
			skipped++
			return false
		}
		writeLicence(w, id, k[len(prefix):], v.(*licence))
		written++
		return written >= want
	})
	w.EndArray()
	return w.String()
}

func writeLicence(w *safe.JSONWriter, id, holder string, l *licence) {
	w.BeginObject()
	w.StrField("engine", id)
	w.StrField("holder", holder)
	w.IntField("maxCollections", l.maxCollections)
	w.IntField("used", l.used)
	w.IntField("feeBps", l.feeBps)
	w.IntField("grantedHeight", l.grantedHeight)
	w.EndObject()
}

// ParamsTaken is the cid of the first collection created with engine id and
// exactly these params, or "" (always "" for empty params).
func ParamsTaken(id, params string) string {
	if params == "" {
		return ""
	}
	if v := paramsTaken.Get(paramsKey(id, params)); v != nil {
		return v.(string)
	}
	return ""
}

// CreateRefusal is why CreateCollection would refuse creator on engine id
// with params now, as core's own text, or "" when the engine gates pass:
// unknown engine, create paused, unclaimed/deprecated/superseded, the
// policy, a used-up licence, params of another creator. The engine's own
// ValidateParams and the spec's other fields are not judged here.
func CreateRefusal(id string, creator address, params string) string {
	v := engines.Get(id)
	if v == nil {
		return "unknown engine " + id
	}
	if Paused("create") {
		return "paused: create"
	}
	_, why := createAccess(v.(*engineRecord), creator, params)
	return why
}
