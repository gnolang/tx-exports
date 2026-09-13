// Package nftgen1 is the second generation of the fully on-chain
// generative engine. Same contract as nftgen0 - pure functions, seed in,
// traits and SVG out, no IPFS and no off-chain renderer - but it fixes
// the three weaknesses that offline simulation found in gen0 at a
// 1000-token supply (scripts/gen-sim.py, scripts/gen1-proposal-sim.py):
//
//  1. TRAIT SPACE. gen0 has 7.200 possible combinations, so a 1000-token
//     drop lands 112 tokens (11,2%) on a combination somebody else also
//     has, worst case four identical trait sets. gen1 has 1.254.400
//     combinations: two new layers (Frame, Finish), wider Palette/Shape/
//     Ground tables and wider Elements/Symmetry ranges.
//
//  2. RARITY. In gen0 the tier is decided by Aura plus Elements>=11 and
//     nothing else, so Palette/Shape/Ground carry zero rarity signal and
//     the only visible "rare" cue is one ring. gen1 scores EVERY trait
//     and derives the tier from the total, which is why a Prism palette
//     or an Ornate frame is worth something on its own.
//
//  3. SNIPING. gen0's seed is exactly "<collectionID>:<tokenID>", so
//     anybody can compute the whole rarity map before the first mint and
//     wait for a good ID to come up in the sequential queue. gen1 seeds
//     accept a per-collection SALT (SeedForSalted). A collection that is
//     created with an unpredictable salt has an unpredictable rarity map
//     until the salt is public, while determinism is untouched: the salt
//     is fixed at collection creation and never changes, so a token's
//     artwork is still identical on every node, forever.
//
// WHY THIS IS A NEW REALM AND NOT AN EDIT
//
// Gno realms are immutable and nft56 pins its engine at COMPILE time
// (`import "gno.land/r/.../nftgen0"` plus `const Engine`). Deploying
// nftgen1 therefore does nothing on its own - it needs a new NFT realm
// family (nft57) that imports it. That is deliberate: tokens already
// minted from gen0 must keep rendering exactly as they do today.
package nftgen1

import (
	"encoding/base64"
	"strconv"
	"strings"

	"gno.land/p/nt/ufmt/v0"
)

// ---------------------------------------------------------------------
// Deterministic randomness - byte-for-byte the gen0 stream.
//
// FNV-1a over the seed, then a splitmix64 mixer. Pure integer math: no
// floats, no time, no block data. The offline simulators port this exact
// arithmetic, so the distribution numbers quoted above are the numbers
// this code produces.
// ---------------------------------------------------------------------

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

// ---------------------------------------------------------------------
// Weighted trait tables
//
// gen0 expressed weights by repeating entries inside a uniform table,
// which cannot express "4%" without a 25-entry slice. Here the weight is
// explicit and a single draw walks the cumulative sum, so a trait can be
// genuinely scarce and the tables stay readable.
// ---------------------------------------------------------------------

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

// Traits are the decoded, human readable properties of a seed. The SVG
// builder and the trait string both read this one struct, so the picture
// and the metadata can never describe different artwork.
type Traits struct {
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

// Tier cut-offs. Chosen on the 1000-seed simulation, which gives
// Common 21,4% / Uncommon 44,4% / Rare 25,2% / Legendary 7,6% /
// Mythic 1,4% - a top segment wide enough to matter and narrow enough
// to stay special.
const (
	scoreMythic    = 12
	scoreLegendary = 8
	scoreRare      = 5
	scoreUncommon  = 2
)

func derive(seed string) (Traits, palette) {
	r := newRNG(seed)

	// Draw order is part of the contract: changing it changes every
	// token's artwork, so it must match the simulators exactly.
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

	t := Traits{
		Palette:  p.name,
		Shape:    shape.name,
		Ground:   ground.name,
		Frame:    frame.name,
		Finish:   finish.name,
		Aura:     aura.name,
		Elements: 5 + r.intn(10), // 5..14
		Symmetry: 2 + r.intn(7),  // 2..8
	}

	// Rarity is a score over every trait, not a single visible flag.
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

// ---------------------------------------------------------------------
// Public API - all pure reads. Nothing here writes state or costs a tx.
// ---------------------------------------------------------------------

// SeedFor builds the unsalted seed "<collectionID>:<tokenID>", the key
// the frontend already uses for a token. Kept for drop-in compatibility
// with gen0 call sites.
func SeedFor(collectionID, tokenID string) string {
	return collectionID + ":" + tokenID
}

// SeedForSalted builds a salted seed. The salt is a per-collection
// constant chosen at creation time; an empty salt degrades to SeedFor,
// so a collection that does not care about sniping behaves like gen0.
//
// The salt goes in FRONT of the token key because FNV-1a is sequential:
// a leading salt changes the hash state before the token bytes are even
// mixed in, so neighbouring token IDs do not stay neighbours.
func SeedForSalted(collectionID, tokenID, salt string) string {
	if salt == "" {
		return SeedFor(collectionID, tokenID)
	}
	return salt + "|" + collectionID + ":" + tokenID
}

// TraitsOf returns the decoded traits for a seed.
func TraitsOf(seed string) Traits {
	t, _ := derive(seed)
	return t
}

// RarityOf returns just the tier, for callers that only rank tokens.
func RarityOf(seed string) string {
	t, _ := derive(seed)
	return t.Rarity
}

// TraitString returns the traits in the compact "k=v;k=v" form that
// nft5x.MintWithTraits parses. Nine pairs, well under the 16-attribute
// and 64-character-per-value realm limits.
func TraitString(seed string) string {
	t, _ := derive(seed)
	return strings.Join([]string{
		"Palette=" + t.Palette,
		"Shape=" + t.Shape,
		"Ground=" + t.Ground,
		"Frame=" + t.Frame,
		"Finish=" + t.Finish,
		"Aura=" + t.Aura,
		"Elements=" + strconv.Itoa(t.Elements),
		"Symmetry=" + strconv.Itoa(t.Symmetry),
		"Rarity=" + t.Rarity,
	}, ";")
}

// finishStroke maps the Finish layer onto stroke width, and glowOpacity
// onto a shared opacity bump, so Finish is genuinely visible instead of
// being metadata-only.
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

	// --- aura layer (four tiers instead of gen0's on/off ring) ---
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
				// two crossing strokes: reads as woven once mirrored
				b.WriteString(ufmt.Sprintf(
					`<line x1="%d" y1="%d" x2="%d" y2="%d" stroke="%s" stroke-width="%d" opacity="0.%d"/>`,
					x, y, x+size, y+size/3, color, stroke, opacity))
				b.WriteString(ufmt.Sprintf(
					`<line x1="%d" y1="%d" x2="%d" y2="%d" stroke="%s" stroke-width="%d" opacity="0.%d"/>`,
					x+size, y, x, y+size/3, color, stroke, opacity))
			case "Rift":
				// a jagged tear through the frame
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

// DataURI returns the artwork as a base64 data: URI, ready to be stored
// as a tokenURI. Base64 rather than raw utf8 because a tokenURI travels
// through JSON-RPC, shell arguments and HTML attributes on its way to a
// browser, and raw SVG contains quotes and angle brackets that at least
// one of those layers will mangle.
func DataURI(seed string) string {
	return "data:image/svg+xml;base64," + base64.StdEncoding.EncodeToString([]byte(SVG(seed)))
}

// Preview is a convenience for the frontend: traits and artwork for a
// token in a single qeval instead of two.
func Preview(collectionID, tokenID string) (string, string) {
	seed := SeedFor(collectionID, tokenID)
	return TraitString(seed), DataURI(seed)
}

// PreviewSalted is Preview for a collection that uses a seed salt.
func PreviewSalted(collectionID, tokenID, salt string) (string, string) {
	seed := SeedForSalted(collectionID, tokenID, salt)
	return TraitString(seed), DataURI(seed)
}

// Render makes the generator browsable from gnoweb: the index shows a
// sample drop, and :<seed> renders one piece with its traits.
func Render(path string) string {
	if path != "" {
		t := TraitsOf(path)
		return ufmt.Sprintf(
			"# gen1 \u00b7 %s\n\n![%s](%s)\n\n- Palette: %s\n- Shape: %s\n- Ground: %s\n"+
				"- Frame: %s\n- Finish: %s\n- Aura: %s\n- Elements: %d\n- Symmetry: %d\n"+
				"- Score: %d\n- Rarity: **%s**\n",
			path, path, DataURI(path), t.Palette, t.Shape, t.Ground,
			t.Frame, t.Finish, t.Aura, t.Elements, t.Symmetry, t.Score, t.Rarity)
	}

	out := "# gen1 \u2014 on-chain generative engine (second generation)\n\n" +
		"Pure functions: seed \u2192 traits \u2192 SVG \u2192 `data:` URI. No IPFS, no gateway.\n\n" +
		"1.254.400 trait combinations, score-based rarity over every layer, and an\n" +
		"optional per-collection seed salt so the rarity map is not public before\n" +
		"the first mint.\n\n## Sample drop (seeds `gen1:1` \u2026 `gen1:10`)\n\n"
	for i := 1; i <= 10; i++ {
		seed := "gen1:" + strconv.Itoa(i)
		t := TraitsOf(seed)
		out += ufmt.Sprintf("- [%s](:%s) \u2014 %s %s, %s frame, %s finish, %d elements, **%s**\n",
			seed, seed, t.Palette, t.Shape, t.Frame, t.Finish, t.Elements, t.Rarity)
	}
	return out
}
