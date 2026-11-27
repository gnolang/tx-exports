// Package tpcopy is a rehearsal probe (R3, J-3 flow): a tiny third-party engine "Tessera Probe".
// tpengine (third-party author) reserves its fingerprint first; tpcopy (squatter) registers the
// same art in between; tpengine's reservation-backed Register must supersede the copy.
package tpcopy

import (
	"gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia4/engine/v2"
	"gno.land/r/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia4/core"
)

const author = address("g1dd9qqssjc6lqlyxf49pp655fyn66ac0zazqv9t")

type impl struct{}

func (impl) Manifest() engine.Manifest {
	return engine.Manifest{
		Name: "Tessera Probe (copy)", Version: "1.0.0", Description: "Rehearsal probe engine (Onyx test data).",
		License: "CC0-1.0", Author: author, TraitTypes: []string{"Tone"},
		MaxSVGBytes: 2048, FeeBps: 100, Kind: engine.KindSVG,
	}
}
func (impl) ValidateParams(params string) error {
	if params != "" {
		panic("no params")
	}
	return nil
}
func (impl) TraitTypes(params string) []string                     { return []string{"Tone"} }
func (impl) CheckLaunch(cid, params string, maxSupply int64) error { return nil }
func (impl) Traits(in engine.Input) []engine.Trait                 { return []engine.Trait{{Type: "Tone", Value: in.Seed[:6]}} }
func (impl) Render(in engine.Input) string {
	return "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 64 64\"><rect width=\"64\" height=\"64\" fill=\"#" + in.Seed[:6] +
		"\"/><circle cx=\"32\" cy=\"32\" r=\"20\" fill=\"#" + in.Seed[6:12] + "\"/></svg>"
}
func (impl) Media(in engine.Input) engine.Media { return engine.Media{} }

func Register(cur realm) string { return core.RegisterEngine(cross(cur), impl{}, "") }
