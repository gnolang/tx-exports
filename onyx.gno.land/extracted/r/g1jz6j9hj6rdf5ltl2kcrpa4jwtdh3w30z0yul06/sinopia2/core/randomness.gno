package core

import (
	"chain"
	"chain/runtime"
	"strings"

	"gno.land/p/nt/avl/v0"

	"gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia/safe/v1"
	"gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia/types/v1"
)

// Pluggable randomness sources (beacon v2).
//
// A collection launched with useBeacon picks its second entropy source at
// Launch (LaunchSpec.BeaconSource, frozen by I-6):
//
//   - types.BeaconCommitted: the platform beacon's commit-reveal
//     (provenance.gno; BeaconCommit before the first mint,
//     RevealBeaconSecret after the creator).
//   - the package path of a randomness provider realm: a public random
//     value nobody can know in advance, e.g. a drand round relayed and
//     BLS-verified on chain (gnolang/gno#6268 p/drand + r/drand). Nothing
//     is committed before the sale; the round is fixed only once the
//     creator can no longer choose (RequestRandomness), then anyone pulls
//     its value (FulfillRandomness).
//
// A provider realm registers itself (its id is its package path, as for
// engines) and is usable only after the admin approves it through the
// timelocked op randomness.add; randomness.deprecate stops new launches,
// running collections finish with it. So a drand provider plugs in without
// a core redeploy. Its methods are declared in its own realm, so core
// calling them runs the provider with the provider's authority (interrealm
// v2 borrow rule #1): it cannot write core state, and with no cur it cannot
// call a core mutator.
//
// Order with a provider (same guarantees as the committed beacon, SA-M1):
//
//  1. the creator reveals until revealDeadline - BeaconGraceBlocks;
//  2. RequestRandomness (anyone) after the creator revealed, or inside the
//     grace period when it stayed silent, and no later than revealDeadline
//     - RequestMargin: binds the collection to provider.Target(), a round
//     whose value nobody knows yet — not the creator, whose secret is
//     public or whose window is closed, not the minters, whose sale is over;
//  3. FulfillRandomness (anyone) once the provider has that round: the
//     value becomes the beacon secret and the collection is Final at once
//     (2/2 after the creator, beacon-only in grace);
//  4. after revealDeadline Finalize works as before (creator-only /
//     fallback if the provider never delivered).
type RandomnessProvider interface {
	// Name is a short label for UIs, e.g. "drand quicknet".
	Name() string
	// Target is the round a request made in the current block is bound
	// to. Its value must be unknowable to anyone at this block (a round
	// published strictly in the future). Read-only.
	Target() int64
	// Randomness is round's verified value as 64 lowercase hex characters
	// (32 bytes), or "" while it is not available. Read-only.
	Randomness(round int64) string
}

type providerRecord struct {
	id               string
	name             string
	impl             RandomnessProvider
	active           bool // approved by the admin and not deprecated
	registeredHeight int64
}

var (
	providers       avl.Tree // provider pkgpath -> *providerRecord
	activeProviders int64
)

const MaxProviderNameLen = 64

// RegisterRandomnessProvider stores the calling realm's provider. It is
// inert until the admin approves it (randomness.add, timelocked).
func RegisterRandomnessProvider(cur realm, p RandomnessProvider) string {
	assertNoDeposit(cur)
	id := cur.Previous().PkgPath()
	if !strings.HasPrefix(id, runtime.ChainDomain()+"/r/") || strings.Contains(id, "#") {
		panic("a randomness provider registers from its own realm (an /r/ package, not a sub-realm or wallet)")
	}
	if p == nil {
		panic("nil provider")
	}
	if providers.Has(id) {
		panic("randomness provider already registered: " + id)
	}
	name := p.Name()
	safe.AssertNonEmptyText("provider name", name, MaxProviderNameLen)
	providers.Set(id, &providerRecord{id: id, name: name, impl: p, registeredHeight: height()})
	chain.Emit("RandomnessProviderRegistered", "id", id, "name", name)
	return id
}

func mustProvider(id string) *providerRecord {
	v := providers.Get(id)
	if v == nil {
		panic("unknown randomness provider " + id)
	}
	return v.(*providerRecord)
}

func assertActiveProvider(id string) {
	if !mustProvider(id).active {
		panic("randomness provider " + id + " is not approved")
	}
}

// beaconAvailable: some unpredictable second source exists, so no launch
// may opt out of it (SA-M2).
func beaconAvailable() bool { return beacon != "" || activeProviders > 0 }

func usesProvider(c *collection) bool {
	return c.useBeacon && c.beaconSource != types.BeaconCommitted
}

// RequestRandomness binds a provider-backed collection to the provider's
// next unknowable round. Permissionless and never paused (I-2).
func RequestRandomness(cur realm, cid string) int64 {
	assertNoDeposit(cur)
	c := mustCollection(cid)
	h := height()
	assertRevealOpen(c, h)
	if !usesProvider(c) {
		panic("this collection does not use a randomness provider")
	}
	p := c.prov
	if p.round != 0 {
		panic("randomness already requested for round " + itoa(p.round))
	}
	dl := revealDeadline(c)
	if !p.creatorRevealed && h < dl-BeaconGraceBlocks {
		panic("randomness is requested after the creator reveals, or in the window's last " +
			itoa(BeaconGraceBlocks) + " blocks")
	}
	if h > dl-RequestMargin {
		panic("too late to request randomness (last height " + itoa(dl-RequestMargin) + "); call Finalize after the deadline")
	}
	round := mustProvider(c.beaconSource).impl.Target()
	if round <= 0 {
		panic("randomness provider returned an invalid round")
	}
	p.round = round
	chain.Emit("RandomnessRequested", "cid", cid, "provider", c.beaconSource, "round", itoa(round))
	return round
}

// FulfillRandomness takes the requested round's value from the provider as
// the beacon secret and finalizes (2/2 after the creator, beacon-only when
// it stayed silent). Permissionless and never paused (I-2).
func FulfillRandomness(cur realm, cid string) {
	assertNoDeposit(cur)
	c := mustCollection(cid)
	h := height()
	assertRevealOpen(c, h)
	if !usesProvider(c) {
		panic("this collection does not use a randomness provider")
	}
	p := c.prov
	if p.round == 0 {
		panic("randomness was not requested yet")
	}
	v := mustProvider(c.beaconSource).impl.Randomness(p.round)
	if v == "" {
		panic("round " + itoa(p.round) + " is not available from the provider yet")
	}
	v = safe.AssertHex("randomness", v, 32)
	p.beaconSecret = v
	p.beaconRevealed = true
	chain.Emit("BeaconRevealed", "cid", cid, "provider", c.beaconSource, "round", itoa(p.round), "secret", v)
	finalize(c, h)
}

// RandomnessProviders lists registered providers (by path) as JSON:
// [{id, name, active, registeredHeight}]. Registration is open, so only
// "active" ones (admin-approved) can be chosen at Launch.
func RandomnessProviders(offset, limit int64) string {
	w := &safe.JSONWriter{}
	w.BeginArray()
	providers.IterateByOffset(int(offset), int(clampLimit(limit)), func(_ string, v any) bool {
		r := v.(*providerRecord)
		w.BeginObject()
		w.StrField("id", r.id)
		w.StrField("name", r.name)
		w.BoolField("active", r.active)
		w.IntField("registeredHeight", r.registeredHeight)
		w.EndObject()
		return false
	})
	w.EndArray()
	return w.String()
}
