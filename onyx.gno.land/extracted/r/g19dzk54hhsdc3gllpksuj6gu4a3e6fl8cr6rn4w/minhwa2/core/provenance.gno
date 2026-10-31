package core

import (
	"chain"
	"chain/runtime"

	"gno.land/p/g19dzk54hhsdc3gllpksuj6gu4a3e6fl8cr6rn4w/minhwa/safe/v1"
	"gno.land/p/g19dzk54hhsdc3gllpksuj6gu4a3e6fl8cr6rn4w/minhwa/types/v1"
)

// Commit–reveal v2 (design §4.2–4.3, closes RA H-3, M-5, M-6).
//
// The map is fixed by three inputs: the creator's secret sc, the beacon's
// secret sb and the public mint-entropy accumulator acc. Neither committer
// knows the other's secret while minting is open, so neither can time the
// last mint for a good map. Order of reveals:
//
//  1. nothing is accepted before Closed (an early reveal informs the other
//     side);
//  2. the creator reveals first; the beacon follows, or reveals first
//     inside the last BeaconGraceBlocks of the window;
//  3. after revealDeadline anyone finalizes with whatever was revealed.
//
// What stays open, by design: the last revealer can still choose between
// revealing and not (one bit). The beacon is last, runs public code, and
// the badge shows the outcome. The transfer lock (tokens.gno) keeps anyone
// from trading on early knowledge until Final.
type provenance struct {
	creatorCommit, beaconCommit string
	acc                         string
	creatorSecret, beaconSecret string
	creatorRevealed             bool
	beaconRevealed              bool
	salt, badge                 string
	finalHeight                 int64
}

const (
	roleCreator = "creator"
	roleBeacon  = "beacon"
)

// BeaconCommit is the beacon's commitment, before any token exists.
func BeaconCommit(cur realm, cid, commitHex string) {
	assertNoDeposit(cur)
	c := mustCollection(cid)
	if beacon == "" || caller(cur) != beacon {
		panic("only the configured beacon can commit")
	}
	if c.state == types.StateDraft || c.prov == nil || !c.useBeacon {
		panic("this collection is not waiting for a beacon")
	}
	if c.prov.beaconCommit != "" {
		panic("the beacon already committed")
	}
	if c.minted() > 0 {
		panic("too late: tokens were minted before the beacon committed")
	}
	commit := safe.AssertHex("commit", commitHex, 32)
	if usedCommits.Has(commit) {
		panic("this commitment was already used")
	}
	usedCommits.Set(commit, cid)
	c.prov.beaconCommit = commit
	chain.Emit("BeaconCommitted", "cid", cid, "commit", commit)
}

func RevealCreatorSecret(cur realm, cid, secret string) {
	assertNoDeposit(cur)
	c := mustCollection(cid)
	assertCreator(cur, c)
	h := height()
	assertRevealOpen(c, h)
	if c.prov.creatorRevealed {
		panic("the creator secret is already revealed")
	}
	assertSecret(c, roleCreator, secret, c.prov.creatorCommit)
	c.prov.creatorSecret = secret
	c.prov.creatorRevealed = true
	chain.Emit("CreatorRevealed", "cid", cid, "secret", secret)
	if revealsComplete(c) {
		finalize(c, h)
	}
}

func RevealBeaconSecret(cur realm, cid, secret string) {
	assertNoDeposit(cur)
	c := mustCollection(cid)
	if beacon == "" || caller(cur) != beacon {
		panic("only the configured beacon can reveal")
	}
	h := height()
	assertRevealOpen(c, h)
	if !c.useBeacon || c.prov.beaconCommit == "" {
		panic("this collection has no beacon commitment")
	}
	if c.prov.beaconRevealed {
		panic("the beacon secret is already revealed")
	}
	if !c.prov.creatorRevealed && h < revealDeadline(c)-BeaconGraceBlocks {
		panic("the beacon reveals after the creator, or in the window's last " + itoa(BeaconGraceBlocks) + " blocks")
	}
	assertSecret(c, roleBeacon, secret, c.prov.beaconCommit)
	c.prov.beaconSecret = secret
	c.prov.beaconRevealed = true
	chain.Emit("BeaconRevealed", "cid", cid, "secret", secret)
	if revealsComplete(c) {
		finalize(c, h)
	}
}

// Finalize is permissionless and never paused (I-2): immediately once every
// expected secret is revealed, otherwise after revealDeadline (fallback).
func Finalize(cur realm, cid string) {
	assertNoDeposit(cur)
	c := mustCollection(cid)
	h := height()
	refresh(c, h)
	if c.state != types.StateClosed {
		panic("only a closed collection can be finalized (state " + c.state.String() + ")")
	}
	if !revealsComplete(c) && h <= revealDeadline(c) {
		panic("the reveal window is open until height " + itoa(revealDeadline(c)))
	}
	finalize(c, h)
}

func assertRevealOpen(c *collection, h int64) {
	refresh(c, h)
	if c.state != types.StateClosed {
		panic("secrets are accepted only after the sale closed (state " + c.state.String() + ")")
	}
	if h > revealDeadline(c) {
		panic("the reveal window closed; call Finalize")
	}
}

func assertSecret(c *collection, role, secret, commit string) {
	if len(secret) < MinSecretLen || len(secret) > MaxSecretLen {
		panic("secret must be " + itoa(MinSecretLen) + ".." + itoa(MaxSecretLen) + " bytes")
	}
	safe.AssertText("secret", secret, MaxSecretLen)
	if safe.Commit(runtime.ChainID(), c.id, role, secret) != commit {
		panic("secret does not match the " + role + " commitment")
	}
}

func revealsComplete(c *collection) bool {
	return c.prov.creatorRevealed && (!c.useBeacon || c.prov.beaconRevealed)
}

// finalize runs at most once per collection (I-10): every caller checks
// state Closed, and this sets Final.
func finalize(c *collection, h int64) {
	p := c.prov
	p.salt = safe.Salt(c.id, p.creatorSecret, p.beaconSecret, p.acc)
	switch {
	case p.creatorRevealed && p.beaconRevealed:
		p.badge = BadgeBoth
	case p.creatorRevealed:
		p.badge = BadgeCreatorOnly
	case p.beaconRevealed:
		p.badge = BadgeBeaconOnly
	default:
		p.badge = BadgeFallback
	}
	p.finalHeight = h
	c.state = types.StateFinal
	c.st.final = true
	chain.Emit("CollectionFinal", "cid", c.id, "salt", p.salt, "badge", p.badge)
}

// VerifyProvenance recomputes every commitment and the salt from public
// data. True only for a Final collection whose record is consistent.
func VerifyProvenance(cid string) bool {
	c := mustCollection(cid)
	if c.state != types.StateFinal {
		return false
	}
	p := c.prov
	chainID := runtime.ChainID()
	if p.creatorRevealed && safe.Commit(chainID, c.id, roleCreator, p.creatorSecret) != p.creatorCommit {
		return false
	}
	if p.beaconRevealed && safe.Commit(chainID, c.id, roleBeacon, p.beaconSecret) != p.beaconCommit {
		return false
	}
	return p.salt == safe.Salt(c.id, p.creatorSecret, p.beaconSecret, p.acc)
}

// Provenance is the whole record as JSON; secrets and salt stay "" until
// revealed / final.
func Provenance(cid string) string {
	c := mustCollection(cid)
	w := &safe.JSONWriter{}
	w.BeginObject()
	w.StrField("cid", c.id)
	w.StrField("chainId", runtime.ChainID())
	w.StrField("state", stateAt(c, height()).String())
	w.IntField("minted", c.minted())
	w.IntField("reserved", c.reserved)
	if p := c.prov; p != nil {
		w.BoolField("useBeacon", c.useBeacon)
		w.StrField("creatorCommit", p.creatorCommit)
		w.StrField("beaconCommit", p.beaconCommit)
		w.StrField("entropy", p.acc)
		w.StrField("creatorSecret", p.creatorSecret)
		w.StrField("beaconSecret", p.beaconSecret)
		w.StrField("salt", p.salt)
		w.StrField("badge", p.badge)
		w.IntField("revealDeadline", revealDeadline(c))
		w.IntField("finalHeight", p.finalHeight)
		w.BoolField("verified", VerifyProvenance(cid))
	}
	w.EndObject()
	return w.String()
}
