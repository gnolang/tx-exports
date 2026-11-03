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
//     is committed before the sale; the round is fixed by the creator's
//     reveal (same transaction) or, for a silent creator, in the grace
//     period / at the deadline, and its value is then consumed by whoever
//     calls first (FulfillRandomness or Finalize): no caller can skip it.
//
// Before any provider is approved (randomness.add) a keeper must run that
// requests in the grace period for silent creators and fulfills bound
// rounds as soon as they are published (README "Randomness keeper").
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
// Order with a provider (same guarantees as the committed beacon, SA-M1;
// CV-M1: the outcome never depends on who calls, or when):
//
//  1. the creator reveals until revealDeadline - BeaconGraceBlocks; the
//     reveal itself binds the collection to provider.Target() in the same
//     transaction, a round nobody knows yet (its secret is public now, so
//     nobody holding a choice learns anything new later);
//  2. a silent creator: RequestRandomness (anyone, a keeper) inside the
//     grace period, or the first Finalize after revealDeadline, binds the
//     round instead — the creator's window is closed by then;
//  3. once the provider has the bound round (and not in the binding
//     block, CV-I6), FulfillRandomness or Finalize (anyone, before or
//     after the deadline) takes its value as the beacon secret and the
//     collection is Final (2/2 after the creator, beacon-only otherwise).
//     After the deadline Finalize refuses to fall back while the bound
//     round may still arrive;
//  4. fallback (creator-only / fallback badge, never a FairLaunch) only
//     once the provider failed to deliver for ProviderWaitBlocks after the
//     deadline or the binding, whichever is later.
//
// A provider that panics aborts the calling transaction (a realm-boundary
// panic cannot be recovered); if an approved provider breaks, the admin
// deprecates it and, after the wait, Finalize stops calling it.
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

// RequestRandomness binds a provider-backed collection whose creator stayed
// silent to the provider's next unknowable round (a creator's reveal binds
// it itself). Permissionless and never paused (I-2); after the deadline the
// first Finalize binds instead.
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
	if !p.creatorRevealed && h < revealDeadline(c)-BeaconGraceBlocks {
		panic("randomness is requested after the creator reveals, or in the window's last " +
			itoa(BeaconGraceBlocks) + " blocks")
	}
	if !bindRound(c, h) {
		panic("randomness provider returned an invalid or already published round; retry in a later block")
	}
	return p.round
}

// FulfillRandomness takes the bound round's value from the provider as the
// beacon secret and finalizes (2/2 after the creator, beacon-only when it
// stayed silent). Permissionless and never paused (I-2); works before and
// after the deadline while the collection is Closed.
func FulfillRandomness(cur realm, cid string) {
	assertNoDeposit(cur)
	c := mustCollection(cid)
	h := height()
	refresh(c, h)
	if c.state != types.StateClosed {
		panic("secrets are accepted only after the sale closed (state " + c.state.String() + ")")
	}
	if !usesProvider(c) {
		panic("this collection does not use a randomness provider")
	}
	p := c.prov
	if p.round == 0 {
		panic("randomness was not requested yet")
	}
	if h <= p.roundHeight {
		panic("round " + itoa(p.round) + " was bound in this block; fulfill it in a later one")
	}
	v := mustProvider(c.beaconSource).impl.Randomness(p.round)
	if v == "" {
		panic("round " + itoa(p.round) + " is not available from the provider yet")
	}
	consumeRound(c, safe.AssertHex("randomness", v, 32), h)
}

// bindRound fixes the collection's round to provider.Target() at height h.
// It refuses (false) a non-positive round or one whose value the provider
// already has: that value would be known before binding (CV-I6).
func bindRound(c *collection, h int64) bool {
	impl := mustProvider(c.beaconSource).impl
	round := impl.Target()
	if round <= 0 || isRandomness(impl.Randomness(round)) {
		return false
	}
	c.prov.round, c.prov.roundHeight = round, h
	chain.Emit("RandomnessRequested", "cid", c.id, "provider", c.beaconSource, "round", itoa(round))
	return true
}

func consumeRound(c *collection, v string, h int64) {
	p := c.prov
	p.beaconSecret = v
	p.beaconRevealed = true
	chain.Emit("BeaconRevealed", "cid", c.id, "provider", c.beaconSource, "round", itoa(p.round), "secret", v)
	finalize(c, h)
}

// providerWaitEnd is the last height at which Finalize still waits for the
// provider: ProviderWaitBlocks after the deadline or the binding.
func providerWaitEnd(c *collection) int64 {
	from := revealDeadline(c)
	if c.prov.roundHeight > from {
		from = c.prov.roundHeight
	}
	return from + ProviderWaitBlocks
}

// settleProvider is Finalize's provider step after the deadline (CV-M1).
// It returns true when Finalize is done: the round was bound now (a later
// Finalize or FulfillRandomness takes its value), or its value finalized
// the collection. It returns false only when the provider is provably
// unavailable — no usable value after providerWaitEnd — and Finalize falls
// back (creator-only / fallback, never a FairLaunch). While the bound round
// may still arrive it refuses, so nobody can pick the fallback by not
// fulfilling. After the wait a deprecated provider is not called at all
// (escape hatch for a provider whose code aborts every call).
func settleProvider(c *collection, h int64) bool {
	p := c.prov
	waited := h > providerWaitEnd(c)
	if waited && !mustProvider(c.beaconSource).active {
		return false
	}
	if p.round == 0 {
		if bindRound(c, h) {
			return true
		}
		if waited {
			return false
		}
		panic("the randomness provider cannot bind a round now; retry later (fallback after height " +
			itoa(providerWaitEnd(c)) + ")")
	}
	if h > p.roundHeight {
		if v := mustProvider(c.beaconSource).impl.Randomness(p.round); isRandomness(v) {
			consumeRound(c, safe.AssertHex("randomness", v, 32), h)
			return true
		}
	}
	if waited {
		return false
	}
	panic("waiting for randomness round " + itoa(p.round) + " (FulfillRandomness once it is published; fallback after height " +
		itoa(providerWaitEnd(c)) + ")")
}

// isRandomness: a provider value core accepts (64 hex characters).
func isRandomness(v string) bool {
	if len(v) != 64 {
		return false
	}
	for i := 0; i < len(v); i++ {
		c := v[i]
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f' || c >= 'A' && c <= 'F') {
			return false
		}
	}
	return true
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
