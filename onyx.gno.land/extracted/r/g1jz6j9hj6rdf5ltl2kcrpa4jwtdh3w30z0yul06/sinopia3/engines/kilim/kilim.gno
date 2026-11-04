// Package kilim is the thin adapter that registers the Kilim engine
// (p/…/sinopia/art/kilim/v1) with core. Core knows the engine only as this
// realm's package path plus an interface value.
//
// The adapter is stateless and has no admin: what it renders is fixed by
// the p/ package it imports, which can never change. Never mark this realm
// private (design §5.4: a re-deployable adapter could swap the art).
package kilim

import (
	art "gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia/art/kilim/v1"
	"gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia/engine/v1"
	"gno.land/r/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia3/core"
)

// author is the address that claims the engine in core (ClaimEngine).
// TODO(mainnet): the engine author's own key, not the deployer.
var author = address("g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06")

func Author() address { return author }

// AuthorFeeBps is the author's fee on sales of collections by other
// creators (engine.Manifest.FeeBps; 0 for the author's own collections).
// TODO(mainnet): product decision; 1% here so Onyx exercises the path.
const AuthorFeeBps = 100

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

func (impl) Traits(in engine.Input) []engine.Trait { return art.Traits(in) }

func (impl) Render(in engine.Input) string { return art.Render(in) }

// Register is an explicit call, not init: under the inert package policy
// init runs inside the approver's transaction (RA B-1). Anyone may call it;
// it can only ever register this realm, once.
func Register(cur realm) string {
	return core.RegisterEngine(cross(cur), impl{})
}

// RenderSeed and TraitsSeed are the plan-B surface (design §5.6): if
// dynamic registration fails on chain, readers call the engine directly.
func RenderSeed(seed, params string) string {
	in := engine.SampleInput()
	in.Seed, in.Params = seed, params
	return art.Render(in) // panics on invalid params
}

func TraitsSeed(seed, params string) []engine.Trait {
	in := engine.SampleInput()
	in.Seed, in.Params = seed, params
	return art.Traits(in) // panics on invalid params
}
