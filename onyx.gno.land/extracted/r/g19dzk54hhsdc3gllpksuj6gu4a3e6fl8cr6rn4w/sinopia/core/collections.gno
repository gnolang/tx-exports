package core

import (
	"chain"
	"chain/runtime"

	"gno.land/p/nt/grc721/royalty/v0"
	"gno.land/p/nt/grc721/v0"
	"gno.land/p/nt/seqid/v0"

	"gno.land/p/g19dzk54hhsdc3gllpksuj6gu4a3e6fl8cr6rn4w/sinopia/safe/v1"
	"gno.land/p/g19dzk54hhsdc3gllpksuj6gu4a3e6fl8cr6rn4w/sinopia/types/v1"
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
	primary := safe.ParsePayees("primaryPayees", spec.PrimaryPayees, MaxPayees)
	royal := safe.ParsePayees("royaltyPayees", spec.RoyaltyPayees, MaxPayees)

	rec := mustEngine(spec.EngineID)
	if !rec.claimed {
		panic("engine is not claimed by its author yet")
	}
	if rec.deprecated {
		panic("engine is deprecated")
	}
	// I-12 exception: the creator's own transaction runs the engine they chose.
	if err := rec.impl.ValidateParams(spec.Params); err != nil {
		panic("params rejected by engine: " + err.Error())
	}

	collCount++
	cid := itoa(collCount)

	// Each collection gets its own sub-realm identity, so Token.ID() and every
	// grc721 event carry "…/core#c/<cid>" (design §2.3; verified by
	// spike/subtoken and core tests on gno v1.7.0).
	tok, led := grc721.NewToken(spec.Name, spec.Symbol, seqid.ID(uint64(collCount)), cur.Sub("c/"+cid))
	st := &tokenState{}
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
		maxSupply:     spec.MaxSupply,
		nextTID:       1,
		royaltyBps:    spec.RoyaltyBps,
		primaryPayees: primary,
		royaltyPayees: royal,
		minter:        minter,
		state:         types.StateDraft,
		createdHeight: height(),
		token:         tok,
		ledger:        led,
		roy:           roy,
		st:            st,
	}
	collections.Set(collKey(cid), c)
	byCreator.Set(creator.String()+":"+collKey(cid), cid)

	chain.Emit("CollectionCreated",
		"cid", cid, "creator", creator.String(), "minter", minter,
		"engine", spec.EngineID, "token", tok.ID())
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
	if l.RevealWindow < RevealWindowMin || l.RevealWindow > RevealWindowMax {
		panic("revealWindow must be " + itoa(RevealWindowMin) + ".." + itoa(RevealWindowMax) + " blocks")
	}
	commit := safe.AssertHex("creatorCommit", l.CreatorCommit, 32)
	if usedCommits.Has(commit) {
		panic("this commitment was already used; derive a new secret")
	}
	if l.UseBeacon && beacon == "" {
		panic("no beacon is configured; launch without useBeacon")
	}

	usedCommits.Set(commit, cid)
	c.prov = &provenance{creatorCommit: commit, acc: safe.InitialEntropy(runtime.ChainID(), cid)}
	c.startHeight, c.endHeight, c.revealWindow = l.StartHeight, l.EndHeight, l.RevealWindow
	c.useBeacon = l.UseBeacon
	c.state = types.StateScheduled

	chain.Emit("CollectionScheduled",
		"cid", cid, "start", itoa(c.startHeight), "end", itoa(c.endHeight),
		"revealWindow", itoa(c.revealWindow), "useBeacon", boolStr(c.useBeacon),
		"creatorCommit", commit)
}

// AbortLaunch returns a launched collection to Draft while nothing has been
// minted — the way out when a beacon never commits. Used commitments stay
// used.
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
	c.prov = nil
	c.startHeight, c.endHeight, c.revealWindow, c.closeHeight = 0, 0, 0, 0
	c.useBeacon = false
	c.state = types.StateDraft
	chain.Emit("CollectionState", "cid", cid, "state", c.state.String())
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
	// A reserve is a mint, and the beacon may only commit while nothing is
	// minted: reserving first would leave the collection unmintable and
	// unabortable (found on Onyx, collection 1).
	if c.useBeacon && c.prov.beaconCommit == "" {
		panic("waiting for the beacon commitment; reserve after the beacon commits")
	}
	assertMintCount(c, n)
	if c.reserved+n > c.maxSupply*MaxReserveBps/safe.BpsDenominator {
		panic("reserve would exceed " + itoa(MaxReserveBps/100) + "% of supply")
	}
	first, last = mintBatchTo(c, to, n, h)
	c.reserved += n
	emitBatch("Reserved", c, to, first, last)
	return first, last
}

// MintTo mints n tokens during the sale. The minter has already checked
// phase, price, allowlist and wallet cap; core re-checks only what it owns:
// state, supply, beacon commitment, and the lifetime counter (I-5, I-9).
func MintTo(cur realm, cid string, to address, n int64) (first, last int64) {
	c := mustCollection(cid)
	assertBoundMinter(cur, c)
	assertNotPaused("mint")
	h := height()
	refresh(c, h)
	if c.state != types.StateMinting {
		panic("collection is not minting (state " + c.state.String() + ")")
	}
	if c.useBeacon && c.prov.beaconCommit == "" {
		panic("waiting for the beacon commitment; minting has not opened")
	}
	assertMintCount(c, n)
	first, last = mintBatchTo(c, to, n, h)
	c.mintedBy.Set(to.String(), mintedBy(c, to)+n)
	if c.minted() == c.maxSupply {
		c.closeHeight = h
		c.state = types.StateClosed
		chain.Emit("CollectionState", "cid", cid, "state", c.state.String())
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
	c.st.addBatch(first, last, h)
	c.prov.acc = safe.MixEntropy(c.prov.acc, to, h, first, last)
	return first, last
}

func mintedBy(c *collection, addr address) int64 {
	if v := c.mintedBy.Get(addr.String()); v != nil {
		return v.(int64)
	}
	return 0
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
	chain.Emit("CreatorTransferStarted", "cid", cid, "from", c.creator.String(), "to", to.String())
}

func AcceptCreator(cur realm, cid string) {
	assertNoDeposit(cur)
	c := mustCollection(cid)
	who := caller(cur)
	if c.pendingCreator == "" || who != c.pendingCreator {
		panic("no pending creator transfer to this address")
	}
	byCreator.Remove(c.creator.String() + ":" + collKey(cid))
	byCreator.Set(who.String()+":"+collKey(cid), cid)
	chain.Emit("CreatorTransferred", "cid", cid, "from", c.creator.String(), "to", who.String())
	c.creator = who
	c.pendingCreator = ""
}

// SetPayees changes the royalty split after Final. The primary-sale split is
// frozen with the sale (I-6); the royalty receiver stays the collection's
// sub-treasury, so third-party markets are unaffected.
func SetPayees(cur realm, cid, payees string) {
	assertNoDeposit(cur)
	c := mustCollection(cid)
	assertCreator(cur, c)
	if c.state != types.StateFinal {
		panic("royalty payees can change only after the collection is final")
	}
	c.royaltyPayees = safe.ParsePayees("royaltyPayees", payees, MaxPayees)
	chain.Emit("RoyaltyPayees", "cid", cid, "payees", payees)
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
