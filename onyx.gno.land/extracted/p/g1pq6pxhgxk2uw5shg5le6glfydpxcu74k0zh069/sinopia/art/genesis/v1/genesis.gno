// Package genesis is the platform's first engine: a pure p/ port of
// the prototype's gen1 engine. The RNG stream, trait tables,
// draw order and SVG drawing are byte-for-byte nftgen1's, so a seed renders
// the same artwork here as there; genesis_test.gno pins trait vectors
// computed independently from the same algorithm.
//
// What changed is only the packaging (RA L-7): it is a stateless p/
// package implementing engine/v1, the seed comes from core's commit–reveal
// (so the salt/seed helpers and the gnoweb Render of nftgen1 are gone), and
// the engine takes no params.
package genesis

import (
	"errors"
	"strconv"
	"strings"

	"gno.land/p/nt/ufmt/v0"

	"gno.land/p/g1pq6pxhgxk2uw5shg5le6glfydpxcu74k0zh069/sinopia/engine/v1"
)

// TraitTypes in the order Traits returns them.
var traitTypes = []string{"Palette", "Shape", "Ground", "Frame", "Finish", "Aura", "Elements", "Symmetry", "Score", "Rarity"}

// MaxSVGBytes: 8 symmetry x 14 elements of the widest primitive plus the
// densest ground and frame stays well under this (gen1 tested < 32,000).
const MaxSVGBytes = 32768

// Manifest describes the engine. Author is left empty: the adapter realm
// that registers this engine sets the address that will ClaimEngine.
func Manifest() engine.Manifest {
	return engine.Manifest{
		Name:    "Genesis",
		Version: "1.0.0",
		Description: "Fully on-chain generative engine, nftgen1 lineage: FNV-1a + splitmix64 stream, " +
			"10 traits, 1,254,400 combinations, score-based rarity over every layer.",
		License:      "TBD",
		ParamsSchema: `{"const":""}`,
		TraitTypes:   append([]string{}, traitTypes...),
		Living:       false,
		MaxSVGBytes:  MaxSVGBytes,
	}
}

// ValidateParams: genesis has no parameters.
func ValidateParams(params string) error {
	if params != "" {
		return errors.New("genesis takes no params")
	}
	return nil
}

// Traits returns the ten traits of in.Seed in TraitTypes order.
func Traits(in engine.Input) []engine.Trait {
	t := TraitsOf(in.Seed)
	return []engine.Trait{
		{Type: "Palette", Value: t.Palette},
		{Type: "Shape", Value: t.Shape},
		{Type: "Ground", Value: t.Ground},
		{Type: "Frame", Value: t.Frame},
		{Type: "Finish", Value: t.Finish},
		{Type: "Aura", Value: t.Aura},
		{Type: "Elements", Value: strconv.Itoa(t.Elements)},
		{Type: "Symmetry", Value: strconv.Itoa(t.Symmetry)},
		{Type: "Score", Value: strconv.Itoa(t.Score)},
		{Type: "Rarity", Value: t.Rarity},
	}
}

// Render returns the raw SVG for in.Seed.
func Render(in engine.Input) string { return SVG(in.Seed) }

// ---------------------------------------------------------------------------
// Deterministic randomness — FNV-1a over the seed, then a splitmix64 mixer.
// Pure integer math: no floats, no time, no block data.
// ---------------------------------------------------------------------------

const (
	fnvOffset uint64 = 14695981039346656037
	fnvPrime  uint64 = 1099511628211
)

type rng struct {
	state uint64
}

func newRNG(seed string) *rng {
	h := fnvOffset
	for i := 0; i < len(seed); i++ {
		h ^= uint64(seed[i])
		h *= fnvPrime
	}
	if h == 0 {
		h = fnvPrime
	}
	return &rng{state: h}
}

func (r *rng) next() uint64 {
	r.state += 0x9E3779B97F4A7C15
	z := r.state
	z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9
	z = (z ^ (z >> 27)) * 0x94D049BB133111EB
	return z ^ (z >> 31)
}

// intn returns a value in [0, n).
func (r *rng) intn(n int) int {
	if n <= 0 {
		return 0
	}
	return int(r.next() % uint64(n))
}

// ---------------------------------------------------------------------------
// Weighted trait tables (weights are explicit; one draw walks the sum).
// ---------------------------------------------------------------------------

type option struct {
	name   string
	weight int
	score  int // contribution to the rarity score
}

func pick(r *rng, table []option) option {
	total := 0
	for _, o := range table {
		total += o.weight
	}
	roll := r.intn(total)
	acc := 0
	for _, o := range table {
		acc += o.weight
		if roll < acc {
			return o
		}
	}
	return table[len(table)-1]
}

type palette struct {
	option
	bg  string
	ink string
	c1  string
	c2  string
	c3  string
}

// Palette weights sum to 100, so a weight reads directly as a percent.
var palettes = []palette{
	{option{"Emerald", 18, 0}, "#04140f", "#7cf2c4", "#10b981", "#34d399", "#065f46"},
	{option{"Amethyst", 18, 0}, "#0b0713", "#e9d5ff", "#8b5cf6", "#c084fc", "#4c1d95"},
	{option{"Abyss", 16, 0}, "#02101c", "#bae6fd", "#0ea5e9", "#38bdf8", "#0c4a6e"},
	{option{"Ember", 14, 0}, "#160806", "#fecaca", "#f97316", "#fb923c", "#7c2d12"},
	{option{"Bone", 12, 0}, "#f5f5f4", "#1c1917", "#78716c", "#a8a29e", "#292524"},
	{option{"Solar", 10, 0}, "#1a1403", "#fef08a", "#eab308", "#facc15", "#713f12"},
	{option{"Obsidian", 8, 2}, "#050505", "#e5e5e5", "#404040", "#737373", "#171717"},
	{option{"Prism", 4, 4}, "#0a0a12", "#fdf4ff", "#22d3ee", "#f472b6", "#a78bfa"},
}

var shapes = []option{
	{"Orbit", 20, 0},
	{"Lattice", 18, 0},
	{"Bloom", 18, 0},
	{"Shard", 16, 0},
	{"Spiral", 14, 0},
	{"Weave", 9, 2},
	{"Rift", 5, 4},
}

var grounds = []option{
	{"Flat", 30, 0},
	{"Halo", 25, 0},
	{"Grid", 22, 0},
	{"Rings", 14, 1},
	{"Scatter", 9, 2},
}

var frames = []option{
	{"None", 55, 0},
	{"Thin", 25, 1},
	{"Double", 14, 2},
	{"Ornate", 6, 4},
}

var finishes = []option{
	{"Matte", 50, 0},
	{"Gloss", 28, 1},
	{"Glow", 16, 2},
	{"Foil", 6, 4},
}

var auras = []option{
	{"None", 78, 0},
	{"Soft", 14, 2},
	{"Bright", 6, 4},
	{"Nova", 2, 7},
}

// TraitSet is the decoded properties of a seed. The SVG builder and the
// trait list both read this one struct, so picture and metadata cannot
// describe different artwork.
type TraitSet struct {
	Palette  string
	Shape    string
	Ground   string
	Frame    string
	Finish   string
	Aura     string
	Elements int
	Symmetry int
	Score    int
	Rarity   string
}

// Tier cut-offs, chosen on nftgen1's 1000-seed simulation: Common 21.4% /
// Uncommon 44.4% / Rare 25.2% / Legendary 7.6% / Mythic 1.4%.
const (
	scoreMythic    = 12
	scoreLegendary = 8
	scoreRare      = 5
	scoreUncommon  = 2
)

func derive(seed string) (TraitSet, palette) {
	r := newRNG(seed)

	// Draw order is part of the contract: changing it changes every token.
	p := palettes[0]
	{
		total := 0
		for _, q := range palettes {
			total += q.weight
		}
		roll := r.intn(total)
		acc := 0
		for _, q := range palettes {
			acc += q.weight
			if roll < acc {
				p = q
				break
			}
		}
	}
	shape := pick(r, shapes)
	ground := pick(r, grounds)
	frame := pick(r, frames)
	finish := pick(r, finishes)
	aura := pick(r, auras)

	t := TraitSet{
		Palette:  p.name,
		Shape:    shape.name,
		Ground:   ground.name,
		Frame:    frame.name,
		Finish:   finish.name,
		Aura:     aura.name,
		Elements: 5 + r.intn(10), // 5..14
		Symmetry: 2 + r.intn(7),  // 2..8
	}

	score := p.score + shape.score + ground.score + frame.score + finish.score + aura.score
	if t.Elements >= 13 {
		score++
	}
	if t.Symmetry >= 7 {
		score++
	}
	t.Score = score

	switch {
	case score >= scoreMythic:
		t.Rarity = "Mythic"
	case score >= scoreLegendary:
		t.Rarity = "Legendary"
	case score >= scoreRare:
		t.Rarity = "Rare"
	case score >= scoreUncommon:
		t.Rarity = "Uncommon"
	default:
		t.Rarity = "Common"
	}
	return t, p
}

// TraitsOf returns the decoded traits for a seed.
func TraitsOf(seed string) TraitSet {
	t, _ := derive(seed)
	return t
}

func finishStroke(finish string) int {
	switch finish {
	case "Gloss":
		return 4
	case "Glow":
		return 5
	case "Foil":
		return 6
	default: // Matte
		return 3
	}
}

func auraRing(aura string) (int, int) { // width, opacity percent
	switch aura {
	case "Soft":
		return 4, 22
	case "Bright":
		return 8, 38
	case "Nova":
		return 14, 60
	default:
		return 0, 0
	}
}

// SVG renders the artwork for a seed as a standalone SVG document.
func SVG(seed string) string {
	t, p := derive(seed)
	r := newRNG(seed + "|art") // separate stream: trait draws never shift the art

	var b strings.Builder
	b.WriteString(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" width="512" height="512">`)
	b.WriteString(ufmt.Sprintf(`<rect width="512" height="512" fill="%s"/>`, p.bg))

	// --- ground layer ---
	switch t.Ground {
	case "Halo":
		b.WriteString(ufmt.Sprintf(
			`<circle cx="256" cy="256" r="200" fill="none" stroke="%s" stroke-width="1" opacity="0.35"/>`, p.c3))
	case "Grid":
		for i := 64; i < 512; i += 64 {
			b.WriteString(ufmt.Sprintf(
				`<line x1="%d" y1="0" x2="%d" y2="512" stroke="%s" stroke-width="1" opacity="0.18"/>`, i, i, p.c3))
			b.WriteString(ufmt.Sprintf(
				`<line x1="0" y1="%d" x2="512" y2="%d" stroke="%s" stroke-width="1" opacity="0.18"/>`, i, i, p.c3))
		}
	case "Rings":
		for rad := 60; rad <= 240; rad += 45 {
			b.WriteString(ufmt.Sprintf(
				`<circle cx="256" cy="256" r="%d" fill="none" stroke="%s" stroke-width="1" opacity="0.22"/>`, rad, p.c3))
		}
	case "Scatter":
		for i := 0; i < 40; i++ {
			b.WriteString(ufmt.Sprintf(
				`<circle cx="%d" cy="%d" r="2" fill="%s" opacity="0.30"/>`,
				16+r.intn(480), 16+r.intn(480), p.c3))
		}
	}

	// --- aura layer ---
	if w, op := auraRing(t.Aura); w > 0 {
		b.WriteString(ufmt.Sprintf(
			`<circle cx="256" cy="256" r="230" fill="none" stroke="%s" stroke-width="%d" opacity="0.%d"/>`,
			p.ink, w, op))
	}

	// --- composition: one pass, mirrored Symmetry times ---
	stroke := finishStroke(t.Finish)
	step := 360 / t.Symmetry
	for s := 0; s < t.Symmetry; s++ {
		b.WriteString(ufmt.Sprintf(`<g transform="rotate(%d 256 256)">`, s*step))
		for e := 0; e < t.Elements; e++ {
			color := p.c1
			switch r.intn(3) {
			case 1:
				color = p.c2
			case 2:
				color = p.ink
			}
			x := 96 + r.intn(320)
			y := 96 + r.intn(320)
			size := 12 + r.intn(70)
			opacity := 40 + r.intn(55) // percent, integer only
			if t.Finish == "Glow" || t.Finish == "Foil" {
				opacity = 55 + r.intn(40)
			}

			switch t.Shape {
			case "Orbit":
				b.WriteString(ufmt.Sprintf(
					`<circle cx="%d" cy="%d" r="%d" fill="none" stroke="%s" stroke-width="%d" opacity="0.%d"/>`,
					x, y, size, color, stroke, opacity))
			case "Lattice":
				b.WriteString(ufmt.Sprintf(
					`<rect x="%d" y="%d" width="%d" height="%d" fill="none" stroke="%s" stroke-width="%d" opacity="0.%d"/>`,
					x, y, size, size, color, stroke-1, opacity))
			case "Bloom":
				b.WriteString(ufmt.Sprintf(
					`<circle cx="%d" cy="%d" r="%d" fill="%s" opacity="0.%d"/>`,
					x, y, size/2, color, opacity))
			case "Shard":
				b.WriteString(ufmt.Sprintf(
					`<polygon points="%d,%d %d,%d %d,%d" fill="%s" opacity="0.%d"/>`,
					x, y, x+size, y+size/2, x+size/3, y+size, color, opacity))
			case "Weave":
				b.WriteString(ufmt.Sprintf(
					`<line x1="%d" y1="%d" x2="%d" y2="%d" stroke="%s" stroke-width="%d" opacity="0.%d"/>`,
					x, y, x+size, y+size/3, color, stroke, opacity))
				b.WriteString(ufmt.Sprintf(
					`<line x1="%d" y1="%d" x2="%d" y2="%d" stroke="%s" stroke-width="%d" opacity="0.%d"/>`,
					x+size, y, x, y+size/3, color, stroke, opacity))
			case "Rift":
				b.WriteString(ufmt.Sprintf(
					`<path d="M%d %d l %d %d l %d %d l %d %d" fill="none" stroke="%s" stroke-width="%d" opacity="0.%d"/>`,
					x, y, size/2, -size/3, size/3, size, size/2, -size/2,
					color, stroke, opacity))
			default: // Spiral
				b.WriteString(ufmt.Sprintf(
					`<path d="M%d %d q %d %d %d %d" fill="none" stroke="%s" stroke-width="%d" opacity="0.%d"/>`,
					x, y, size, -size, size*2, 0, color, stroke, opacity))
			}
		}
		b.WriteString(`</g>`)
	}

	// --- frame layer, drawn last so it always sits on top ---
	switch t.Frame {
	case "Thin":
		b.WriteString(ufmt.Sprintf(
			`<rect x="12" y="12" width="488" height="488" fill="none" stroke="%s" stroke-width="2" opacity="0.55"/>`, p.ink))
	case "Double":
		b.WriteString(ufmt.Sprintf(
			`<rect x="10" y="10" width="492" height="492" fill="none" stroke="%s" stroke-width="3" opacity="0.60"/>`, p.ink))
		b.WriteString(ufmt.Sprintf(
			`<rect x="24" y="24" width="464" height="464" fill="none" stroke="%s" stroke-width="1" opacity="0.45"/>`, p.c2))
	case "Ornate":
		b.WriteString(ufmt.Sprintf(
			`<rect x="8" y="8" width="496" height="496" fill="none" stroke="%s" stroke-width="4" opacity="0.70"/>`, p.ink))
		b.WriteString(ufmt.Sprintf(
			`<rect x="22" y="22" width="468" height="468" fill="none" stroke="%s" stroke-width="2" opacity="0.55"/>`, p.c2))
		for _, c := range [][2]int{{8, 8}, {504, 8}, {8, 504}, {504, 504}} {
			b.WriteString(ufmt.Sprintf(
				`<circle cx="%d" cy="%d" r="10" fill="none" stroke="%s" stroke-width="3" opacity="0.80"/>`,
				c[0], c[1], p.c1))
		}
	}

	b.WriteString(`</svg>`)
	return b.String()
}
