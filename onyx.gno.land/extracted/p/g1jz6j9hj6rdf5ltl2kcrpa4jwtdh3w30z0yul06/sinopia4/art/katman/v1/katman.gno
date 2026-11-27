// Package katman is the composition logic of Katman, Sinopia's open PFP
// tool engine: an artist uploads trait layers (SVG parts with rarity
// weights) to a sealed assets/v1 store, and every revealed token is one part
// per layer, drawn from the token's final seed by weight and stacked
// bottom-up into one SVG. Parts may paint with currentColor; the
// collection's palette then gives every layer its own ink, shuffled per
// token, over a paper backdrop.
//
// This package is pure: it never reads a store. The adapter realm
// (r/…/sinopia/engines/katman) reads the drawn parts from assets/v1 and
// hands their bytes to ComposeParts. The demo kit in demo.gno (params store
// 0) is the engine's own sample: the jug characters of the engine gallery,
// redrawn. frontend/src/engines/katman.ts is a byte-identical TypeScript
// twin; katman_test.gno and katman.test.ts pin the same golden vectors.
//
// Why composition can never break the SVG allowlist: every part is a whole
// document that passed safe.AssertSVG when its last byte was stored
// (assets/v1 AppendBytes → media.CheckImage). Its root tag is exactly
// Root(w, h) and the document ends with the closing tag of that root
// (AssertSVG refuses content after the root), so the bytes between them are
// a balanced run of allowlisted elements, attributes and text. ComposeParts
// only concatenates such runs inside <g> elements under one Root(w, h); every
// rule of the allowlist is local to an element, an attribute value or a text
// run, so the result passes too. Core re-checks every render anyway.
//
// Pure integer maths: no floats, no time, no block data.
package katman

import (
	"errors"
	"strconv"
	"strings"

	"gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia4/engine/v2"
)

// Kit limits (the adapter enforces them on a store at CreateCollection).
const (
	MaxLayers        = 8      // = assets/v1 MaxTraitTypes = MaxTiers; trait types
	MaxPartsPerLayer = 64     // parts of one layer
	MaxParts         = 128    // parts of a kit
	MaxKitBytes      = 262144 // on-chain bytes of a kit (sum of part files)
	MaxSVGBytes      = 28672  // worst composed token (Manifest.MaxSVGBytes)
	MaxCanvas        = 4096   // viewBox width and height, 1..MaxCanvas
	MaxStore         = 999999999
	DemoCanvas       = 400
)

// ParamsSchema is the Studio form. Studio sends JSON.stringify of the values
// in this property order; ValidateParams accepts exactly that or "".
const ParamsSchema = `{"type":"object","properties":{` +
	`"store":{"type":"integer","title":"Part store (0 = demo kit)","minimum":0,"maximum":999999999,"default":0},` +
	`"palette":{"type":"string","title":"Palette","enum":["Terracotta","Riso","Iznik","Sea Glass","Dusk",` +
	`"Sinopia","Mono","Kit Colours"],"default":"Terracotta"}}}`

// DefaultParams is the canonical form of the defaults; it renders exactly
// like "".
const DefaultParams = `{"store":0,"palette":"Terracotta"}`

// PaletteKit is the index of "Kit Colours": no paper, no layer inks.
const PaletteKit = 7

type part struct {
	name   string
	weight int64
	inner  string
}

type layer struct {
	name  string
	parts []part
}

type palette struct {
	name, paper string
	inks        []string
}

// Manifest describes the engine. Author and FeeBps are set by the adapter.
func Manifest() engine.Manifest {
	return engine.Manifest{
		Name:    "Katman",
		Version: "1.0.0",
		Description: "Open PFP tool: artists upload their own trait layers (SVG parts with rarity weights) to a " +
			"sealed asset store; at reveal the chain draws one part per layer from each token's seed and stacks " +
			"them. A palette can ink every layer per token. Params store 0 is the built-in demo kit.",
		License:      "CC-BY-NC-4.0",
		ParamsSchema: ParamsSchema,
		TraitTypes:   DemoLayerNames(),
		Living:       false,
		MaxSVGBytes:  MaxSVGBytes,
		Kind:         engine.KindSVG,
	}
}

// DemoLayerNames are the demo kit's layers: its trait types.
func DemoLayerNames() []string {
	out := make([]string, len(demoLayers))
	for i, l := range demoLayers {
		out[i] = l.name
	}
	return out
}

// Config is a parsed params string.
type Config struct {
	Store   int64 // assets/v1 store id; 0 = the demo kit
	Palette int   // index into the palettes; PaletteKit = the kit's own colours
}

// Defaults is params "": the demo kit in Terracotta.
func Defaults() Config { return Config{} }

var errParams = errors.New(`katman: params must be "" or {"store":<0..999999999>,"palette":<enum>} without spaces`)

// ParseParams accepts "" or the canonical JSON Studio produces, nothing else.
func ParseParams(params string) (Config, error) {
	cfg := Defaults()
	if params == "" {
		return cfg, nil
	}
	const pre, mid, post = `{"store":`, `,"palette":"`, `"}`
	if !strings.HasPrefix(params, pre) || !strings.HasSuffix(params, post) {
		return cfg, errParams
	}
	rest := params[len(pre) : len(params)-len(post)]
	k := strings.Index(rest, mid)
	if k < 1 || k > 9 {
		return cfg, errParams
	}
	digits, name := rest[:k], rest[k+len(mid):]
	if len(digits) > 1 && digits[0] == '0' {
		return cfg, errParams
	}
	var n int64
	for i := 0; i < len(digits); i++ {
		c := digits[i]
		if c < '0' || c > '9' {
			return cfg, errParams
		}
		n = n*10 + int64(c-'0')
	}
	cfg.Store = n
	for i, p := range palettes {
		if p.name == name {
			cfg.Palette = i
			return cfg, nil
		}
	}
	return cfg, errParams
}

// ValidateParams accepts "" (the demo kit) and the canonical JSON. Whether a
// store kit is usable is the adapter's call (it reads the store).
func ValidateParams(params string) error {
	_, err := ParseParams(params)
	return err
}

// MustConfig is ParseParams for params core already validated.
func MustConfig(params string) Config {
	cfg, err := ParseParams(params)
	if err != nil {
		panic(err)
	}
	return cfg
}

// PaletteName is the palette's enum value.
func PaletteName(i int) string { return palettes[i].name }

// ---------------------------------------------------------------------------
// Deterministic randomness: FNV-1a over the seed, then splitmix64 (the stream
// of every Sinopia engine). Parts use seed+"|katman|parts", inks
// seed+"|katman|inks", so a palette never moves a token's parts.
// ---------------------------------------------------------------------------

type rng struct{ state uint64 }

func newRNG(seed string) *rng {
	h := uint64(14695981039346656037)
	for i := 0; i < len(seed); i++ {
		h ^= uint64(seed[i])
		h *= 1099511628211
	}
	if h == 0 {
		h = 1099511628211
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

func (r *rng) intn(n int) int {
	if n <= 0 {
		return 0
	}
	return int(r.next() % uint64(n))
}

// Draw returns, per layer, a point in 0..totals[k]-1: the token's position
// on that layer's weight line (the sum of its parts' weights). Part i of a
// layer covers [w_0+…+w_{i-1}, w_0+…+w_i): exactly the slot ranges assets/v1
// gives editions, so the adapter maps the point to a part with
// assets.SlotArtwork. One draw per layer, also for an empty layer (0).
func Draw(seed string, totals []int64) []int64 {
	r := newRNG(seed + "|katman|parts")
	out := make([]int64, len(totals))
	for k, t := range totals {
		v := r.next()
		if t > 0 {
			out[k] = int64(v % uint64(t))
		}
	}
	return out
}

// Pick maps Draw onto explicit weight lists: the index of the drawn part of
// every layer (the walk the TS twin and the demo kit use).
func Pick(seed string, weights [][]int64) []int {
	totals := make([]int64, len(weights))
	for k, ws := range weights {
		for _, w := range ws {
			totals[k] += w
		}
	}
	at := Draw(seed, totals)
	out := make([]int, len(weights))
	for k, ws := range weights {
		x := at[k]
		out[k] = len(ws) - 1
		for i, w := range ws {
			if x < w {
				out[k] = i
				break
			}
			x -= w
		}
	}
	return out
}

// Inks is the ink of each of n layers under palette pal for seed: the
// palette's eight inks shuffled per token (Fisher-Yates), layer k taking the
// (k mod 8)-th. nil for Kit Colours.
func Inks(seed string, pal, n int) []string {
	p := palettes[pal]
	m := len(p.inks)
	if m == 0 {
		return nil
	}
	order := make([]int, m)
	for i := range order {
		order[i] = i
	}
	r := newRNG(seed + "|katman|inks")
	for i := m - 1; i > 0; i-- {
		j := r.intn(i + 1)
		order[i], order[j] = order[j], order[i]
	}
	out := make([]string, n)
	for k := range out {
		out[k] = p.inks[order[k%m]]
	}
	return out
}

// ---------------------------------------------------------------------------
// Parts and composition.
// ---------------------------------------------------------------------------

const rootPrefix = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 `

// Root is the one root tag every part of a w x h kit starts with, and the
// root of every composed token.
func Root(w, h int) string {
	return rootPrefix + strconv.Itoa(w) + " " + strconv.Itoa(h) + `">`
}

// ParseRoot reads a part's root tag: exactly Root(w, h) with canonical
// decimals 1..MaxCanvas. ok is false for anything else.
func ParseRoot(svg string) (root string, w, h int, ok bool) {
	if !strings.HasPrefix(svg, rootPrefix) {
		return "", 0, 0, false
	}
	i := len(rootPrefix)
	w, i, ok = dim(svg, i, ' ')
	if !ok {
		return "", 0, 0, false
	}
	h, i, ok = dim(svg, i, '"')
	if !ok || i >= len(svg) || svg[i] != '>' {
		return "", 0, 0, false
	}
	return svg[:i+1], w, h, true
}

// dim parses a canonical decimal 1..MaxCanvas at s[i:] followed by end;
// it returns the index after end.
func dim(s string, i int, end byte) (int, int, bool) {
	v, start := 0, i
	for i < len(s) && i-start <= 4 && s[i] >= '0' && s[i] <= '9' {
		v = v*10 + int(s[i]-'0')
		i++
	}
	n := i - start
	if n == 0 || n > 4 || s[start] == '0' || v > MaxCanvas || i >= len(s) || s[i] != end {
		return 0, 0, false
	}
	return v, i + 1, true
}

// Inner is a part's content between its root tag and its final </svg>, or
// ok false when the part does not start with root or end with </svg>.
func Inner(svg, root string) (string, bool) {
	if len(svg) < len(root)+6 || svg[:len(root)] != root || svg[len(svg)-6:] != "</svg>" {
		return "", false
	}
	return svg[len(root) : len(svg)-6], true
}

// compose stacks the layers' inner SVG bottom-up: root, the palette's paper,
// then one <g> per non-empty layer (with its ink when the palette has
// inks), then </svg>.
func compose(root string, w, h, pal int, inks []string, inners []string) string {
	var b strings.Builder
	b.WriteString(root)
	if p := palettes[pal].paper; p != "" {
		b.WriteString(`<rect width="` + strconv.Itoa(w) + `" height="` + strconv.Itoa(h) + `" fill="` + p + `"/>`)
	}
	for k, in := range inners {
		if in == "" {
			continue
		}
		if inks != nil {
			b.WriteString(`<g color="` + inks[k] + `">`)
		} else {
			b.WriteString(`<g>`)
		}
		b.WriteString(in)
		b.WriteString(`</g>`)
	}
	b.WriteString(`</svg>`)
	return b.String()
}

// ComposeParts is a store kit's token: parts[k] is the whole file of the
// part drawn for layer k (bottom first). The canvas is the first part whose
// root parses; a part with another root, or no file (""), leaves its layer
// empty, so an unchecked kit still composes a valid document (a checked kit
// never has such a part: the adapter refuses it at CreateCollection).
func ComposeParts(seed string, pal int, parts []string) string {
	root, w, h := "", 0, 0
	for _, p := range parts {
		if r, ww, hh, ok := ParseRoot(p); ok {
			root, w, h = r, ww, hh
			break
		}
	}
	if root == "" {
		root, w, h = Root(DemoCanvas, DemoCanvas), DemoCanvas, DemoCanvas
	}
	inners := make([]string, len(parts))
	for k, p := range parts {
		if in, ok := Inner(p, root); ok {
			inners[k] = in
		}
	}
	return compose(root, w, h, pal, Inks(seed, pal, len(parts)), inners)
}

// WorstBytes is the largest token a kit can compose under palette pal:
// maxInner[k] is the largest inner part of layer k (0 = all empty).
func WorstBytes(root string, w, h, pal int, maxInner []int) int {
	n := len(root) + len(`</svg>`)
	if p := palettes[pal].paper; p != "" {
		n += len(`<rect width="` + strconv.Itoa(w) + `" height="` + strconv.Itoa(h) + `" fill="` + p + `"/>`)
	}
	open := len(`<g>`)
	if len(palettes[pal].inks) > 0 {
		open = len(`<g color="#000000">`)
	}
	for _, m := range maxInner {
		if m > 0 {
			n += open + m + len(`</g>`)
		}
	}
	return n
}

// ---------------------------------------------------------------------------
// The demo kit (params store 0): the engine's sample and Studio preview.
// ---------------------------------------------------------------------------

func demoPick(seed string) []int {
	ws := make([][]int64, len(demoLayers))
	for k, l := range demoLayers {
		ws[k] = make([]int64, len(l.parts))
		for i, p := range l.parts {
			ws[k][i] = p.weight
		}
	}
	return Pick(seed, ws)
}

// SVG is the demo kit's token for seed under palette pal.
func SVG(seed string, pal int) string {
	at := demoPick(seed)
	inners := make([]string, len(demoLayers))
	for k, l := range demoLayers {
		inners[k] = l.parts[at[k]].inner
	}
	return compose(Root(DemoCanvas, DemoCanvas), DemoCanvas, DemoCanvas, pal,
		Inks(seed, pal, len(demoLayers)), inners)
}

// DemoTraits are the demo kit's part names for seed, in layer order.
func DemoTraits(seed string) []engine.Trait {
	at := demoPick(seed)
	out := make([]engine.Trait, len(demoLayers))
	for k, l := range demoLayers {
		out[k] = engine.Trait{Type: l.name, Value: l.parts[at[k]].name}
	}
	return out
}

// Render is the demo kit's art (params store 0). Store kits are composed by
// the adapter (ComposeParts); asking this package for one panics.
func Render(in engine.Input) string {
	cfg := MustConfig(in.Params)
	if cfg.Store != 0 {
		panic("katman: a store kit is composed by the adapter")
	}
	return SVG(in.Seed, cfg.Palette)
}

// Traits are the demo kit's traits (params store 0): one per layer.
func Traits(in engine.Input) []engine.Trait {
	cfg := MustConfig(in.Params)
	if cfg.Store != 0 {
		panic("katman: a store kit's traits come from the adapter")
	}
	return DemoTraits(in.Seed)
}
