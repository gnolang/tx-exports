// Package genesis is the thin adapter that registers the Genesis engine
// (p/…/sinopia/art/genesis/v1) with core. It dogfoods the third-party path: core
// knows genesis only as this realm's package path plus an interface value.
//
// The adapter is stateless and has no admin: what it renders is fixed by
// the p/ package it imports, which can never change. Never mark this realm
// private (design §5.4: a re-deployable adapter could swap the art).
// Per-chain values (author key, fee) live in config.gno.
package genesis

import (
	art "gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia4/art/genesis/v1"
	"gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia4/engine/v2"
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

func (impl) ValidateParams(params string) error { return art.ValidateParams(params) }

// TraitTypes: a static engine, every collection uses the manifest's list.
func (impl) TraitTypes(params string) []string { return art.Manifest().TraitTypes }

// CheckLaunch: a generative engine has no launch precondition.
func (impl) CheckLaunch(cid, params string, maxSupply int64) error { return nil }

func (impl) Traits(in engine.Input) []engine.Trait { return art.Traits(in) }

func (impl) Render(in engine.Input) string { return art.Render(in) }

// Media: an svg engine; Render is the art.
func (impl) Media(in engine.Input) engine.Media { return engine.Media{} }

// Register is an explicit call, not init: under the inert package policy
// init runs inside the approver's transaction (RA B-1). It registers this
// realm, once. The sample fingerprint is reserved in core's source (I-14),
// so core accepts it only when the transaction is signed by the reserved
// engine-author key, the same key as author (config.gno); no commit
// reservation, so the salt is "".
func Register(cur realm) string {
	return core.RegisterEngine(cross(cur), impl{}, "")
}
