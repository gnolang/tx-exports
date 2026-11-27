// Package squatgen is a rehearsal squat probe (R3): an adapter around the already-public
// genesis art, author = the squatter. core must refuse Register (reserved fingerprint).
package squatgen

import (
	art "gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia4/art/genesis/v1"
	"gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia4/engine/v2"
	"gno.land/r/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia4/core"
)

const author = address("g1dd9qqssjc6lqlyxf49pp655fyn66ac0zazqv9t")

type impl struct{}

func (impl) Manifest() engine.Manifest {
	m := art.Manifest()
	m.Name = "Genesis (copy)"
	m.Author = author
	m.FeeBps = 500
	return m
}
func (impl) ValidateParams(params string) error                    { return art.ValidateParams(params) }
func (impl) TraitTypes(params string) []string                     { return art.Manifest().TraitTypes }
func (impl) CheckLaunch(cid, params string, maxSupply int64) error { return nil }
func (impl) Traits(in engine.Input) []engine.Trait                 { return art.Traits(in) }
func (impl) Render(in engine.Input) string                         { return art.Render(in) }
func (impl) Media(in engine.Input) engine.Media                    { return engine.Media{} }

func Register(cur realm) string { return core.RegisterEngine(cross(cur), impl{}, "") }
