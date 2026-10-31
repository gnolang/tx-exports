// Package engine is the "art as code" contract (design §5.2): what a
// generative engine implements, what core hands it, and the conformance
// rules both core and engine authors check against.
//
// An engine is registered from its own /r/ adapter realm. Because the
// adapter's methods are declared in that realm, core calling them runs the
// engine with the adapter's authority, never core's (interrealm v2 borrow
// rule #1). Methods receive and return plain values only: an engine never
// gets a reference into core state.
package engine

import (
	"errors"
	"strconv"

	"gno.land/p/g19dzk54hhsdc3gllpksuj6gu4a3e6fl8cr6rn4w/minhwa/safe/v1"
)

// Input is everything an engine may depend on. p/ packages are frozen once
// deployed, so the fields "living" engines will need later (phase 2) are
// here from day one.
type Input struct {
	Seed           string // 64-hex final seed (sample seeds in Studio)
	Params         string // collection params, in the engine's own format
	CollectionID   string
	TokenID        string
	MintHeight     int64
	LastMoveHeight int64 // patina: holding time = Height - LastMoveHeight
	Moves          int64 // transfers so far
	Height         int64 // height of the read (fixed by Verify)
}

type Trait struct {
	Type, Value string
}

type Manifest struct {
	Name, Version, Description, License string
	Author                              address // proven by core.ClaimEngine
	ParamsSchema                        string  // JSON Schema subset; Studio builds its form from it
	TraitTypes                          []string
	Living                              bool  // Render depends on LastMoveHeight/Moves/Height
	MaxSVGBytes                         int64 // <= MaxSVGBytes
}

// Engine is implemented by a stateless value declared in the adapter realm.
//
// Contract: deterministic in Input; ValidateParams("") must accept the
// engine's defaults; Render returns raw SVG (core does the base64); Traits
// only uses types listed in the manifest, each at most once.
type Engine interface {
	Manifest() Manifest
	ValidateParams(params string) error
	Traits(in Input) []Trait
	Render(in Input) string
}

// Limits core enforces on every engine.
const (
	MaxSVGBytes      = 65536
	MaxTraits        = 32
	MaxTraitLen      = 64
	MaxNameLen       = 64
	MaxVersionLen    = 32
	MaxDescLen       = 1024
	MaxLicenseLen    = 64
	MaxParamsSchema  = 4096
)

// SampleInput is the fixed input of an engine's fingerprint: core renders it
// at registration and stores sha256(svg); anyone can recompute it later.
func SampleInput() Input {
	return Input{
		Seed:           safe.Sha256Hex(safe.Domain + "|engine-sample|v1"),
		CollectionID:   "0",
		TokenID:        "0",
		MintHeight:     1,
		LastMoveHeight: 1,
		Height:         1,
	}
}

// SampleSeed returns the i-th Studio/conformance sample seed.
func SampleSeed(i int) string {
	return safe.Sha256Hex(safe.Domain + "|sample|v1|" + strconv.Itoa(i))
}

// ValidateManifest checks sizes, text hygiene and the author address.
func ValidateManifest(m Manifest) error {
	fields := []struct {
		name, value string
		max         int
		required    bool
	}{
		{"name", m.Name, MaxNameLen, true},
		{"version", m.Version, MaxVersionLen, true},
		{"description", m.Description, MaxDescLen, false},
		{"license", m.License, MaxLicenseLen, false},
		{"paramsSchema", m.ParamsSchema, MaxParamsSchema, false},
	}
	for _, f := range fields {
		if f.required && f.value == "" {
			return errors.New("manifest " + f.name + ": must not be empty")
		}
		if err := safe.CheckText(f.value, f.max); err != nil {
			return errors.New("manifest " + f.name + ": " + err.Error())
		}
	}
	if !m.Author.IsValid() {
		return errors.New("manifest author: invalid address")
	}
	if len(m.TraitTypes) > MaxTraits {
		return errors.New("manifest: too many trait types")
	}
	for i, tt := range m.TraitTypes {
		if tt == "" {
			return errors.New("manifest: empty trait type")
		}
		if err := safe.CheckText(tt, MaxTraitLen); err != nil {
			return errors.New("manifest trait type: " + err.Error())
		}
		for _, prev := range m.TraitTypes[:i] {
			if prev == tt {
				return errors.New("manifest: duplicate trait type " + tt)
			}
		}
	}
	if m.MaxSVGBytes <= 0 || m.MaxSVGBytes > MaxSVGBytes {
		return errors.New("manifest maxSVGBytes: must be 1.." + strconv.Itoa(MaxSVGBytes))
	}
	return nil
}

// ValidateTraits checks one Traits() result against the manifest.
func ValidateTraits(m Manifest, ts []Trait) error {
	if len(ts) > len(m.TraitTypes) {
		return errors.New("traits: more traits than manifest trait types")
	}
	for i, t := range ts {
		if !contains(m.TraitTypes, t.Type) {
			return errors.New("traits: type not in manifest: " + t.Type)
		}
		for _, prev := range ts[:i] {
			if prev.Type == t.Type {
				return errors.New("traits: duplicate type " + t.Type)
			}
		}
		if err := safe.CheckText(t.Value, MaxTraitLen); err != nil {
			return errors.New("traits " + t.Type + ": " + err.Error())
		}
	}
	return nil
}

// CheckSVG is the output rule core applies to every render.
func CheckSVG(m Manifest, svg string) error {
	return safe.AssertSVG(svg, int(m.MaxSVGBytes))
}

// Conformance is the self-test engine authors run in their _test.gno
// before registering: manifest, default params, determinism, size, SVG
// hygiene, traits, and — for non-living engines — independence from the
// living fields.
func Conformance(e Engine, samples int) error {
	m := e.Manifest()
	if err := ValidateManifest(m); err != nil {
		return err
	}
	if err := e.ValidateParams(""); err != nil {
		return errors.New("default params rejected: " + err.Error())
	}
	inputs := []Input{SampleInput()}
	for i := 0; i < samples; i++ {
		in := SampleInput()
		in.Seed = SampleSeed(i)
		in.TokenID = strconv.Itoa(i + 1)
		inputs = append(inputs, in)
	}
	for _, in := range inputs {
		svg := e.Render(in)
		if svg != e.Render(in) {
			return errors.New("render is not deterministic for seed " + in.Seed)
		}
		if err := CheckSVG(m, svg); err != nil {
			return errors.New("seed " + in.Seed + ": " + err.Error())
		}
		if err := ValidateTraits(m, e.Traits(in)); err != nil {
			return errors.New("seed " + in.Seed + ": " + err.Error())
		}
		if !m.Living {
			moved := in
			moved.Height, moved.Moves, moved.LastMoveHeight = in.Height+1000, in.Moves+3, in.Height+500
			if e.Render(moved) != svg {
				return errors.New("non-living engine depends on Height/Moves/LastMoveHeight")
			}
		}
	}
	return nil
}

func contains(list []string, s string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}
