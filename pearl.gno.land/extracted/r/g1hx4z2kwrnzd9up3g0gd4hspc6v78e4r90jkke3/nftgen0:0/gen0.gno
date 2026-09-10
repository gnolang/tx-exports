// Package nftgen0 is a deterministic, fully on-chain generative art
// engine: give it a seed string and it returns traits plus a complete
// SVG, with no IPFS, no gateway and no off-chain renderer anywhere in
// the path. The same seed always produces the same artwork, on any node,
// forever - that is the whole point of putting the generator on chain
// rather than storing 10.000 pre-rendered files.
//
// HOW IT PLUGS INTO THE REST OF THE PROJECT
//
// This realm intentionally does NOT own tokens or mint anything. nft4
// already implements collections, supply caps, per-wallet limits,
// royalties and preset queues, and the marketplace/offers realms are
// wired to it. Duplicating that here would fork the ecosystem for no
// gain. Instead:
//
//   1. a creator makes an ordinary nft4 collection,
//   2. DataURI(seed) is read (a free qeval - it is a pure function),
//   3. that data: URI is queued with nft4.QueuePresetURI, or passed
//      straight to nft4.MintWithTraits together with Traits(seed).
//
// So the artwork is generated on chain, stored on chain, and every
// existing feature - listing, offers, royalty split, trait filtering in
// the marketplace - keeps working unchanged.
//
// WHY THE SEED IS A STRING, NOT AN int64
//
// gno.land's vm.MsgCall and qeval only carry scalar strings, and the
// natural seed in practice is "<collectionID>:<tokenID>", which is what
// the frontend already uses as a token key. SeedFor() builds exactly
// that, so tokenID -> seed -> traits -> SVG is a pure chain of pure
// functions with no stored state at all.
package nftgen0

import (
	"encoding/base64"
	"strconv"
	"strings"

	"gno.land/p/nt/ufmt/v0"
)

// ---------------------------------------------------------------------
// Deterministic randomness
//
// FNV-1a over the seed bytes, then a splitmix64-style mixer to draw
// successive independent values. Both are pure integer arithmetic: no
// floats (gno determinism), no time, no block data, nothing that could
// make two nodes disagree about what a token looks like.
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
// Trait tables
//
// Weights are expressed by repetition inside pick(): rarer entries sit
// at the end of a table and are only reachable on a smaller draw, which
// keeps the tables readable and avoids a second weights slice that can
// silently fall out of sync with the names.
// ---------------------------------------------------------------------

type palette struct {
	name string
	bg   string
	ink  string
	c1   string
	c2   string
	c3   string
}

var palettes = []palette{
	{"Emerald", "#04140f", "#7cf2c4", "#10b981", "#34d399", "#065f46"},
	{"Amethyst", "#0b0713", "#e9d5ff", "#8b5cf6", "#c084fc", "#4c1d95"},
	{"Ember", "#160806", "#fecaca", "#f97316", "#fb923c", "#7c2d12"},
	{"Abyss", "#02101c", "#bae6fd", "#0ea5e9", "#38bdf8", "#0c4a6e"},
	{"Bone", "#f5f5f4", "#1c1917", "#78716c", "#a8a29e", "#292524"},
	{"Solar", "#1a1403", "#fef08a", "#eab308", "#facc15", "#713f12"},
}

var shapes = []string{"Orbit", "Lattice", "Bloom", "Shard", "Spiral"}

var grounds = []string{"Flat", "Halo", "Grid"}

// Traits are the decoded, human-readable properties of a seed. Keeping
// this as a struct (rather than only the flat string nft4 wants) means
// the SVG builder and the trait string are guaranteed to describe the
// same artwork - they read the same values.
type Traits struct {
	Palette  string
	Shape    string
	Ground   string
	Elements int
	Symmetry int
	Aura     bool
	Rarity   string
}

func derive(seed string) (Traits, palette) {
	r := newRNG(seed)
	p := palettes[r.intn(len(palettes))]
	t := Traits{
		Palette:  p.name,
		Shape:    shapes[r.intn(len(shapes))],
		Ground:   grounds[r.intn(len(grounds))],
		Elements: 5 + r.intn(8), // 5..12
		Symmetry: 2 + r.intn(5), // 2..6
	}
	// ~12% of seeds get an aura, which is the only trait a viewer can
	// spot instantly, so it carries the rarity tier with it.
	t.Aura = r.intn(100) < 12
	switch {
	case t.Aura && t.Elements >= 11:
		t.Rarity = "Legendary"
	case t.Aura:
		t.Rarity = "Rare"
	case t.Elements >= 11:
		t.Rarity = "Uncommon"
	default:
		t.Rarity = "Common"
	}
	return t, p
}

// ---------------------------------------------------------------------
// Public API - all pure reads, nothing here writes state or costs a tx.
// ---------------------------------------------------------------------

// SeedFor builds the canonical seed for a token: "<collectionID>:<tokenID>",
// the same key the frontend already uses to identify a token.
func SeedFor(collectionID, tokenID string) string {
	return collectionID + ":" + tokenID
}

// TraitsOf returns the decoded traits for a seed.
func TraitsOf(seed string) Traits {
	t, _ := derive(seed)
	return t
}

// TraitString returns the traits in the compact "k=v;k=v" form that
// nft4.MintWithTraits parses.
func TraitString(seed string) string {
	t, _ := derive(seed)
	aura := "No"
	if t.Aura {
		aura = "Yes"
	}
	return strings.Join([]string{
		"Palette=" + t.Palette,
		"Shape=" + t.Shape,
		"Ground=" + t.Ground,
		"Elements=" + strconv.Itoa(t.Elements),
		"Symmetry=" + strconv.Itoa(t.Symmetry),
		"Aura=" + aura,
		"Rarity=" + t.Rarity,
	}, ";")
}

// SVG renders the artwork for a seed as a standalone SVG document.
func SVG(seed string) string {
	t, p := derive(seed)
	r := newRNG(seed + "|art") // separate stream so trait draws don't shift the art

	var b strings.Builder
	b.WriteString(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" width="512" height="512">`)
	b.WriteString(ufmt.Sprintf(`<rect width="512" height="512" fill="%s"/>`, p.bg))

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
	}

	if t.Aura {
		b.WriteString(ufmt.Sprintf(
			`<circle cx="256" cy="256" r="230" fill="none" stroke="%s" stroke-width="6" opacity="0.30"/>`, p.ink))
	}

	// The artwork is drawn once and then mirrored around the centre
	// Symmetry times, which is what makes even a handful of random
	// primitives read as a deliberate composition.
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

			switch t.Shape {
			case "Orbit":
				b.WriteString(ufmt.Sprintf(
					`<circle cx="%d" cy="%d" r="%d" fill="none" stroke="%s" stroke-width="3" opacity="0.%d"/>`,
					x, y, size, color, opacity))
			case "Lattice":
				b.WriteString(ufmt.Sprintf(
					`<rect x="%d" y="%d" width="%d" height="%d" fill="none" stroke="%s" stroke-width="2" opacity="0.%d"/>`,
					x, y, size, size, color, opacity))
			case "Bloom":
				b.WriteString(ufmt.Sprintf(
					`<circle cx="%d" cy="%d" r="%d" fill="%s" opacity="0.%d"/>`,
					x, y, size/2, color, opacity))
			case "Shard":
				b.WriteString(ufmt.Sprintf(
					`<polygon points="%d,%d %d,%d %d,%d" fill="%s" opacity="0.%d"/>`,
					x, y, x+size, y+size/2, x+size/3, y+size, color, opacity))
			default: // Spiral
				b.WriteString(ufmt.Sprintf(
					`<path d="M%d %d q %d %d %d %d" fill="none" stroke="%s" stroke-width="3" opacity="0.%d"/>`,
					x, y, size, -size, size*2, 0, color, opacity))
			}
		}
		b.WriteString(`</g>`)
	}

	b.WriteString(`</svg>`)
	return b.String()
}

// DataURI returns the artwork as a base64 data: URI, ready to be stored
// as an nft4 tokenURI. Base64 rather than raw utf8 because a tokenURI
// travels through JSON-RPC, shell arguments and HTML attributes on its
// way to a browser, and raw SVG contains quotes and angle brackets that
// get mangled by at least one of those layers.
func DataURI(seed string) string {
	return "data:image/svg+xml;base64," + base64.StdEncoding.EncodeToString([]byte(SVG(seed)))
}

// Preview is a convenience for the frontend: traits and artwork for a
// token in a single qeval instead of two.
func Preview(collectionID, tokenID string) (string, string) {
	seed := SeedFor(collectionID, tokenID)
	return TraitString(seed), DataURI(seed)
}

// Render makes the generator browsable from gnoweb: the index shows a
// contact sheet of the first ten seeds, and :<seed> renders one piece
// with its traits.
func Render(path string) string {
	if path != "" {
		t := TraitsOf(path)
		aura := "no"
		if t.Aura {
			aura = "yes"
		}
		return ufmt.Sprintf(
			"# gen0 · %s\n\n![%s](%s)\n\n- Palette: %s\n- Shape: %s\n- Ground: %s\n"+
				"- Elements: %d\n- Symmetry: %d\n- Aura: %s\n- Rarity: **%s**\n",
			path, path, DataURI(path), t.Palette, t.Shape, t.Ground,
			t.Elements, t.Symmetry, aura, t.Rarity)
	}

	out := "# gen0 — on-chain generative engine\n\n" +
		"Pure functions: seed → traits → SVG → `data:` URI. No IPFS, no gateway.\n\n" +
		"## Sample drop (seeds `gen0:1` … `gen0:10`)\n\n"
	for i := 1; i <= 10; i++ {
		seed := "gen0:" + strconv.Itoa(i)
		t := TraitsOf(seed)
		out += ufmt.Sprintf("- [%s](:%s) — %s %s, %d elements, %s\n",
			seed, seed, t.Palette, t.Shape, t.Elements, t.Rarity)
	}
	return out
}
