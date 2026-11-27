package core

import (
	"chain"
	"chain/runtime"

	"gno.land/p/nt/grc721/royalty/v0"
	"gno.land/p/nt/grc721/v0"
	"gno.land/p/nt/seqid/v0"

	"gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia4/engine/v2"
	"gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia4/safe/v2"
	"gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia4/types/v2"
)

// --- bound minter only -------------------------------------------------------
//
// A collection is created by an admin-approved minter realm and stays bound
// to it: only that realm can launch, abort, reserve and mint (I-5). The
// minter is trusted to pass the real creator; core trusts nothing else it
// is given and validates every field (I-13).

// CreateCollection stores a Draft collection and returns its id. Nobody can
// mint a Draft, so a creator can configure phases across several messages
// without a race (OA B2).
func CreateCollection(cur realm, creator address, spec types.CollectionSpec) string {
	minter := cur.Previous().PkgPath()
	assertActiveMinter(minter)
	assertNotPaused("create")
	if !creator.IsValid() {
		panic("invalid creator address")
	}
	safe.AssertNonEmptyText("name", spec.Name, MaxNameLen)
	safe.AssertSymbol("symbol", spec.Symbol)
	safe.AssertText("description", spec.Description, MaxDescriptionLen)
	safe.AssertText("params", spec.Params, MaxParamsLen)
	if spec.MaxSupply <= 0 || spec.MaxSupply > MaxSupplyCap {
		panic("maxSupply must be 1.." + itoa(MaxSupplyCap))
	}
	safe.AssertBps("royaltyBps", spec.RoyaltyBps, RoyaltyCapBps)
	if spec.Soulbound && spec.RoyaltyBps != 0 {
		panic("a non-transferable collection has no secondary sales; royaltyBps must be 0")
	}
	primary := safe.ParsePayees("primaryPayees", spec.PrimaryPayees, MaxPayees)
	royal := safe.ParsePayees("royaltyPayees", spec.RoyaltyPayees, MaxPayees)
	next := itoa(collCount + 1)
	assertPayees("primaryPayees", primary, next, spec.EngineID)
	assertPayees("royaltyPayees", royal, next, spec.EngineID)

	rec := mustEngine(spec.EngineID)
	// I-19: claimed and live engine, creator allowed by its policy, params
	// not another creator's; judged before any engine code runs.
	g, why := createAccess(rec, creator, spec.Params)
	if why != "" {
		panic(why)
	}
	// I-16: the creator's own transaction runs the engine they chose.
	if err := rec.impl.ValidateParams(spec.Params); err != nil {
		panic("params rejected by engine: " + err.Error())
	}
	tts := collectionTraitTypes(rec, spec.Params)
	// The engine's optional create gate gets the creator explicitly (no
	// OriginCaller read in the engine; a realm creator works too, K-2).
	if g, ok := rec.impl.(engine.CreateGate); ok {
		err := g.GateCreate(engine.Collection{ID: next, Creator: creator, Params: spec.Params,
			MaxSupply: spec.MaxSupply, Soulbound: spec.Soulbound})
		if err != nil {
			panic("create refused by engine: " + err.Error())
		}
	}

	collCount++
	cid := itoa(collCount)

	// Each collection gets its own sub-realm identity, so Token.ID() and every
	// grc721 event carry "…/core#c/<cid>" (design §2.3; verified by
	// spike/subtoken and core tests on gno v1.7.0).
	tok, led := grc721.NewToken(spec.Name, spec.Symbol, seqid.ID(uint64(collCount)), cur.Sub("c/"+cid))
	st := &tokenState{soulbound: spec.Soulbound}
	led.RegisterExtension(&lockExt{cid: cid, st: st})
	roy, royLed := royalty.NewRoyalty(led, RoyaltyCapBps)
	if spec.RoyaltyBps > 0 {
		if err := royLed.SetDefaultRoyalty(royaltyAddress(cid), spec.RoyaltyBps); err != nil {
			panic(err)
		}
	}

	c := &collection{
		id:            cid,
		name:          spec.Name,
		symbol:        spec.Symbol,
		description:   spec.Description,
		creator:       creator,
		engineID:      spec.EngineID,
		params:        spec.Params,
		traitTypes:    tts,
		soulbound:     spec.Soulbound,
		maxSupply:     spec.MaxSupply,
		nextTID:       1,
		royaltyBps:    spec.RoyaltyBps,
		primaryPayees: primary,
		royaltyPayees: royal,
		minter:        minter,
		state:         types.StateDraft,
		createdHeight: height(),
		access:        g.access,
		licenceFee:    g.fee,
		token:         tok,
		ledger:        led,
		roy:           roy,
		st:            st,
	}
	collections.Set(collKey(cid), c)
	byCreator.Set(creator.String()+":"+collKey(cid), cid)
	byEngine.Set(spec.EngineID+":"+collKey(cid), cid)
	rec.collections++
	if g.key != "" && !g.reuse {
		paramsTaken.Set(g.key, cid)
	}
	if g.lic != nil {
		g.lic.used++
	}

	chain.Emit("CollectionCreated",
		"cid", cid, "creator", creator.String(), "minter", minter,
		"engine", spec.EngineID, "token", tok.ID(), "access", g.access, "soulbound", boolStr(spec.Soulbound))
	return cid
}

// Launch freezes the configuration (I-6): sale window, reveal window and the
// creator's commitment. The sale must start in the future so a beacon can
// commit before the first mint.
func Launch(cur realm, cid string, l types.LaunchSpec) {
	c := mustCollection(cid)
	assertBoundMinter(cur, c)
	h := height()
	if c.state != types.StateDraft {
		panic("only a draft can be launched")
	}
	if l.StartHeight <= h {
		panic("startHeight must be in the future")
	}
	if l.EndHeight < l.StartHeight || l.EndHeight-l.StartHeight > MaxSaleBlocks {
		panic("sale window must be 0.." + itoa(MaxSaleBlocks) + " blocks")
	}
	if l.Mode == types.ModeOpen {
		launchOpen(c, l)
		return
	}
	if l.Mode != types.ModeReveal {
		panic("mode must be \"\" (commit-reveal) or \"" + types.ModeOpen + "\"")
	}
	if l.RevealWindow < RevealWindowMin || l.RevealWindow > RevealWindowMax {
		panic("revealWindow must be " + itoa(RevealWindowMin) + ".." + itoa(RevealWindowMax) + " blocks")
	}
	commit := safe.AssertHex("creatorCommit", l.CreatorCommit, 32)
	// Commitments are domain-separated by chain, collection and role
	// (safe.Commit), so only this collection's own history matters: a secret
	// that went public here is never accepted again (SA-L1, RA M-5).
	if isBurned(c, commit) {
		panic("this commitment's secret was already revealed; derive a new secret")
	}
	source := l.BeaconSource
	if l.UseBeacon {
		if source == "" {
			source = types.BeaconCommitted
		}
		if source == types.BeaconCommitted {
			if beacon == "" {
				panic("no beacon is configured; launch without useBeacon or with an approved randomness provider")
			}
		} else {
			assertActiveProvider(source)
		}
	} else {
		if source != "" {
			panic("beaconSource needs useBeacon")
		}
		// SA-M2: without the beacon the creator alone knows the only secret
		// and can grind the last mint for the map it wants. While the
		// platform has a beacon or an approved randomness provider, nobody
		// may opt out.
		if beaconAvailable() {
			panic("the platform beacon is configured; launch with useBeacon")
		}
	}

	checkLaunch(c, types.ModeReveal)

	c.prov = &provenance{creatorCommit: commit, acc: safe.InitialEntropy(runtime.ChainID(), c.id)}
	c.startHeight, c.endHeight, c.revealWindow = l.StartHeight, l.EndHeight, l.RevealWindow
	c.useBeacon = l.UseBeacon
	c.beaconSource = source
	c.mode = types.ModeReveal
	schedule(c)
}

// launchOpen is Launch in open mode (I-17): no commitment, no beacon or
// provider, no reveal window. The salt is public (openSalt) and anyone may
// finalize once the sale is Closed.
func launchOpen(c *collection, l types.LaunchSpec) {
	if l.CreatorCommit != "" || l.UseBeacon || l.BeaconSource != "" {
		panic("an open launch has no creatorCommit, useBeacon or beaconSource")
	}
	if l.RevealWindow != 0 {
		panic("an open launch has revealWindow 0")
	}
	checkLaunch(c, types.ModeOpen)
	c.prov = &provenance{acc: safe.InitialEntropy(runtime.ChainID(), c.id)}
	c.startHeight, c.endHeight, c.revealWindow = l.StartHeight, l.EndHeight, 0
	c.useBeacon, c.beaconSource = false, ""
	c.mode = types.ModeOpen
	schedule(c)
}

// checkLaunch refuses an engine that was deprecated or superseded after the
// Draft was made (WP-J J-1: I-14's "no new sales" covers Launch and every
// relaunch after AbortLaunch, not only CreateCollection; a collection that
// is already Scheduled or later is not touched), then runs the engine's
// launch gate (I-16: the creator's own tx; everything the engine needs is
// passed in). An engine that implements engine.LaunchGate is then asked
// again with the launch mode (e.g. an engine that only works in reveal
// mode refuses an open launch).
func checkLaunch(c *collection, mode string) {
	rec := mustEngine(c.engineID)
	assertEngineUsable(rec)
	if err := rec.impl.CheckLaunch(c.id, c.params, c.maxSupply); err != nil {
		panic("launch refused by engine: " + err.Error())
	}
	if g, ok := rec.impl.(engine.LaunchGate); ok {
		err := g.GateLaunch(engine.Collection{ID: c.id, Creator: c.creator, Params: c.params,
			MaxSupply: c.maxSupply, Mode: mode, Soulbound: c.soulbound})
		if err != nil {
			panic("launch refused by engine: " + err.Error())
		}
	}
}

// assertEngineUsable is the engine gate of Launch: claimed, not deprecated,
// not superseded (CreateCollection's createAccess starts with the same
// checks and texts). The access policy is not judged again (I-19).
func assertEngineUsable(rec *engineRecord) {
	if !rec.claimed {
		panic("engine is not claimed by its author yet")
	}
	assertEngineNotRetired(rec)
}

// schedule snapshots the fees and moves c to Scheduled (both modes).
func schedule(c *collection) {
	c.primaryBps = fees.PrimaryBps
	c.engineAuthor, c.engineBps = engineFeeQuote(c)
	c.state = types.StateScheduled
	commit := ""
	if c.prov != nil {
		commit = c.prov.creatorCommit
	}
	chain.Emit("CollectionScheduled",
		"cid", c.id, "start", itoa(c.startHeight), "end", itoa(c.endHeight),
		"revealWindow", itoa(c.revealWindow), "useBeacon", boolStr(c.useBeacon),
		"beaconSource", c.beaconSource, "creatorCommit", commit,
		"engineAuthor", c.engineAuthor.String(), "engineFeeBps", itoa(c.engineBps),
		"mode", modeName(c.mode))
}

// modeName is the mode as shown in events and JSON ("reveal" or "open").
func modeName(m string) string {
	if m == types.ModeOpen {
		return types.ModeOpen
	}
	return "reveal"
}

// collectionTraitTypes asks the engine for the collection's trait list
// (I-16) and returns a core-owned copy, or nil when it equals the
// manifest's (nothing extra stored).
func collectionTraitTypes(rec *engineRecord, params string) []string {
	tts := rec.impl.TraitTypes(params)
	if err := engine.ValidateTraitTypes(tts); err != nil {
		panic("trait types rejected: " + err.Error())
	}
	if sameList(tts, rec.manifest.TraitTypes) {
		return nil
	}
	return append([]string{}, tts...)
}

func sameList(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// traitTypesOf is c's effective trait list (shared; callers copy before
// handing it out).
func traitTypesOf(c *collection) []string {
	if c.traitTypes != nil {
		return c.traitTypes
	}
	return mustEngine(c.engineID).manifest.TraitTypes
}

// AbortLaunch returns a launched collection to Draft while nothing has been
// minted — the way out when a beacon never commits. A commitment whose
// secret was revealed is burned for this collection; unrevealed ones (the
// beacon's deterministic one included) may be committed again (SA-L1).
func AbortLaunch(cur realm, cid string) {
	c := mustCollection(cid)
	assertBoundMinter(cur, c)
	refresh(c, height())
	if c.state == types.StateDraft || c.state == types.StateFinal {
		panic("only a launched, unfinished collection can be aborted")
	}
	if c.minted() > 0 {
		panic("tokens were minted; the launch can no longer be aborted")
	}
	if c.prov.creatorRevealed {
		c.burnedCommits = append(c.burnedCommits, c.prov.creatorCommit)
	}
	if c.prov.beaconRevealed {
		c.burnedCommits = append(c.burnedCommits, c.prov.beaconCommit)
	}
	c.prov = nil
	c.startHeight, c.endHeight, c.revealWindow, c.closeHeight = 0, 0, 0, 0
	c.useBeacon, c.beaconSource, c.mode = false, "", types.ModeReveal
	c.engineBps, c.engineAuthor = 0, ""
	c.state = types.StateDraft
	chain.Emit("CollectionState", "cid", c.id, "state", c.state.String())
}

// ReserveTo mints the creator's reserve before the sale starts. Reserve
// mints feed the entropy like any mint, appear in Provenance, and do not
// count toward wallet caps.
func ReserveTo(cur realm, cid string, to address, n int64) (first, last int64) {
	c := mustCollection(cid)
	assertBoundMinter(cur, c)
	assertNotPaused("mint")
	h := height()
	refresh(c, h)
	if c.state != types.StateScheduled {
		panic("reserve is only possible after launch and before the sale starts")
	}
	if c.mode == types.ModeOpen {
		panic("an open collection has no creator reserve")
	}
	// SA-M2: a reserve is the creator's own allocation; it needs a map the
	// creator cannot steer, i.e. the beacon.
	if !c.useBeacon {
		panic("a creator reserve needs a beacon launch")
	}
	// A reserve is a mint, and the beacon may only commit while nothing is
	// minted: reserving first would leave the collection unmintable and
	// unabortable (found on Onyx, collection 1). A randomness provider has
	// nothing to commit: its value is drawn only after the reveal starts.
	if awaitingBeaconCommit(c) {
		panic("waiting for the beacon commitment; reserve after the beacon commits")
	}
	assertMintCount(c, n)
	if c.reserved+n > c.maxSupply*MaxReserveBps/safe.BpsDenominator {
		panic("reserve would exceed " + itoa(MaxReserveBps/100) + "% of supply")
	}
	first, last = mintBatchTo(c, to, n, h)
	c.reserved += n
	c.reservedTo.Set(to.String(), reservedTo(c, to)+n)
	emitBatch("Reserved", c, to, first, last)
	return first, last
}

// MintTo mints n tokens during the sale. The minter has already checked
// phase, price, allowlist and wallet cap; core re-checks only what it owns:
// state, supply and the beacon commitment (I-5). The lifetime counter of
// I-9 is the grc721 balance itself (mintedBy).
func MintTo(cur realm, cid string, to address, n int64) (first, last int64) {
	c := mustCollection(cid)
	assertBoundMinter(cur, c)
	assertNotPaused("mint")
	h := height()
	refresh(c, h)
	if c.state != types.StateMinting {
		panic("collection is not minting (state " + c.state.String() + ")")
	}
	if awaitingBeaconCommit(c) {
		panic("waiting for the beacon commitment; minting has not opened")
	}
	assertMintCount(c, n)
	first, last = mintBatchTo(c, to, n, h)
	if c.minted() == c.maxSupply {
		c.closeHeight = h
		c.state = types.StateClosed
		chain.Emit("CollectionState", "cid", c.id, "state", c.state.String())
	}
	emitBatch("MintBatch", c, to, first, last)
	return first, last
}

func assertMintCount(c *collection, n int64) {
	if n <= 0 || n > MaxMintPerTx {
		panic("count must be 1.." + itoa(MaxMintPerTx))
	}
	if c.minted()+n > c.maxSupply {
		panic("only " + itoa(c.maxSupply-c.minted()) + " tokens left")
	}
}

// mintBatchTo is the only place tokens come into existence.
func mintBatchTo(c *collection, to address, n, h int64) (first, last int64) {
	first = c.nextTID
	last = first + n - 1
	for tid := first; tid <= last; tid++ {
		if err := c.ledger.Mint(to, grc721.TokenID(itoa(tid))); err != nil {
			panic(err)
		}
	}
	c.nextTID = last + 1
	c.st.appendTokens(first, last, h)
	c.st.appendOwners(first, last, to)
	c.prov.acc = safe.MixEntropy(c.prov.acc, to, h, first, last)
	return first, last
}

// mintedBy is addr's lifetime count of sale mints (I-9) while the
// collection is not Final: before Final no token can move or burn (I-11,
// lockExt) and tokens only come from mintBatchTo, so the grc721 balance is
// exactly sale mints + reserves received. This replaces a stored counter
// (~2 KB per new wallet, storage-cost-analysis P2). After Final the
// balance moves freely and no minter needs the count any more: -1.
func mintedBy(c *collection, addr address) int64 {
	if c.st.final {
		return -1
	}
	bal, err := c.token.BalanceOf(addr)
	if err != nil {
		return 0
	}
	return bal - reservedTo(c, addr)
}

func reservedTo(c *collection, addr address) int64 {
	if v := c.reservedTo.Get(addr.String()); v != nil {
		return v.(int64)
	}
	return 0
}

// awaitingBeaconCommit: a committed-beacon launch whose beacon has not
// committed yet; nothing may be minted (or reserved) before it does.
func awaitingBeaconCommit(c *collection) bool {
	return c.useBeacon && c.beaconSource == types.BeaconCommitted && c.prov.beaconCommit == ""
}

// CloseMint materializes Closed once the sale window has passed. Anyone may
// call it; reveals and Finalize work without it.
func CloseMint(cur realm, cid string) {
	assertNoDeposit(cur)
	c := mustCollection(cid)
	refresh(c, height())
	if c.state != types.StateClosed {
		panic("the sale is not over (state " + c.state.String() + ")")
	}
}

// --- creator -----------------------------------------------------------------

// TransferCreator starts a two-step handover (RA M-11).
func TransferCreator(cur realm, cid string, to address) {
	assertNoDeposit(cur)
	c := mustCollection(cid)
	assertCreator(cur, c)
	if !to.IsValid() {
		panic("invalid address")
	}
	c.pendingCreator = to
	chain.Emit("CreatorTransferStarted", "cid", c.id, "from", c.creator.String(), "to", to.String())
}

func AcceptCreator(cur realm, cid string) {
	assertNoDeposit(cur)
	c := mustCollection(cid)
	who := caller(cur)
	if c.pendingCreator == "" || who != c.pendingCreator {
		panic("no pending creator transfer to this address")
	}
	byCreator.Remove(c.creator.String() + ":" + collKey(c.id))
	byCreator.Set(who.String()+":"+collKey(c.id), c.id)
	chain.Emit("CreatorTransferred", "cid", c.id, "from", c.creator.String(), "to", who.String())
	c.creator = who
	c.pendingCreator = ""
}

// SetPayees changes the royalty split after Final. The primary-sale split is
// frozen with the sale (I-6); the royalty receiver stays the collection's
// sub-treasury, so third-party markets are unaffected. Royalties earned so
// far are first paid to the current payees (SA-I4).
func SetPayees(cur realm, cid, payees string) {
	assertNoDeposit(cur)
	c := mustCollection(cid)
	assertCreator(cur, c)
	if c.state != types.StateFinal {
		panic("royalty payees can change only after the collection is final")
	}
	ps := safe.ParsePayees("royaltyPayees", payees, MaxPayees)
	assertPayees("royaltyPayees", ps, c.id, c.engineID)
	distribute(cur, c)
	c.royaltyPayees = ps
	chain.Emit("RoyaltyPayees", "cid", c.id, "payees", payees)
}

// assertPayees refuses payees that can never spend what they receive
// (SA-L5): the platform's own realms and sub-addresses. cid is the
// collection being configured, engineID its engine adapter.
func assertPayees(field string, ps []types.Payee, cid, engineID string) {
	for _, p := range ps {
		assertSpendable(field, p.Addr, cid, engineID)
	}
}

// assertSpendable panics for core, core's sub-addresses of collection cid
// (token identity c/<cid>, royalty treasury roy/<cid>), the engine adapter,
// and every address of the deny set: the static platform realms next to
// core, every minter ever approved and every payee.deny realm (I-18). None
// of them has a path that spends an incoming payment, so the coins would be
// stranded (I-3).
func assertSpendable(field string, addr address, cid, engineID string) {
	bad := []address{chain.PackageAddress(selfPath)}
	if cid != "" {
		bad = append(bad, chain.DerivePkgSubAddr(selfPath, "c/"+cid), royaltyAddress(cid))
	}
	if engineID != "" {
		bad = append(bad, chain.PackageAddress(engineID))
	}
	for _, b := range bad {
		if addr == b {
			panic(field + ": " + addr.String() + " is a platform realm address that cannot spend; use a wallet")
		}
	}
	if v := deniedPayees.Get(addr.String()); v != nil {
		d := v.(*deniedPayee)
		if d.source == "minter" {
			panic(field + ": " + addr.String() + " is the minter realm " + d.path + "; use a wallet")
		}
		panic(field + ": " + addr.String() + " is the platform realm " + d.path + " that cannot spend; use a wallet")
	}
}

func assertCreator(cur realm, c *collection) {
	if caller(cur) != c.creator {
		panic("only the collection's creator can do this")
	}
}

func assertBoundMinter(cur realm, c *collection) {
	if cur.Previous().PkgPath() != c.minter {
		panic("only the collection's bound minter (" + c.minter + ") can do this")
	}
}

func boolStr(b bool) string {
	if b {
		return "true"
	}
	return "false"
}
