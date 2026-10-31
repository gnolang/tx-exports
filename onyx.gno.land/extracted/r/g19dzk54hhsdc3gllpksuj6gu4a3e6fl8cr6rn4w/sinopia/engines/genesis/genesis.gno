// Package genesis is the thin adapter that registers the genesis engine
// (p/…/art/art/genesis/v1) with core. It dogfoods the third-party path: core
// knows genesis only as this realm's package path plus an interface value.
//
// The adapter is stateless and has no admin: what it renders is fixed by
// the p/ package it imports, which can never change. Never mark this realm
// private (design §5.4: a re-deployable adapter could swap the art).
package genesis

import (
	art "gno.land/p/g19dzk54hhsdc3gllpksuj6gu4a3e6fl8cr6rn4w/sinopia/art/genesis/v1"
	"gno.land/p/g19dzk54hhsdc3gllpksuj6gu4a3e6fl8cr6rn4w/sinopia/engine/v1"
	"gno.land/r/g19dzk54hhsdc3gllpksuj6gu4a3e6fl8cr6rn4w/sinopia/core"
)

// author is the address that claims the engine in core (ClaimEngine).
// TODO(mainnet): the platform's engine-author key, not the deployer.
var author = address("g19dzk54hhsdc3gllpksuj6gu4a3e6fl8cr6rn4w")

func Author() address { return author }

// impl is zero-size and declared here, so core runs it with this realm's
// authority (interrealm v2 borrow rule #1).
type impl struct{}

func (impl) Manifest() engine.Manifest {
	m := art.Manifest()
	m.Author = author
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
	if err := art.ValidateParams(params); err != nil {
		panic(err)
	}
	return art.SVG(seed)
}

func TraitsSeed(seed, params string) []engine.Trait {
	in := engine.SampleInput()
	in.Seed, in.Params = seed, params
	if err := art.ValidateParams(params); err != nil {
		panic(err)
	}
	return art.Traits(in)
}
