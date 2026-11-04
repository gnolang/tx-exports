// Package rubrica is an asemic-script engine: every token invents an
// alphabet of nine to sixteen glyphs (strokes on a 3x4 node grid) and writes
// one page with it — a ruled manuscript, an inscribed stele, a scroll or a
// glossed page — with red rubrics (initials, first lines) marking where a
// reader should begin.
//
// It is a stateless p/ package implementing engine/v1. Pure integer maths
// (FNV-1a + splitmix64 stream, truncating division, a 256-step cosine
// table), so the TypeScript twin (frontend/src/engines/rubrica.ts) renders
// the same bytes. Traits come from their own cheap stream (seed+"|traits")
// and never render; the art uses seed+"|art", so art draws never shift traits.
//
// Glyphs are defined once in <defs> and placed with <use>; each line is one
// translate and each glyph only an x. A hard glyph budget keeps every page
// small (see GlyphBudget).
package rubrica

import (
	"errors"
	"strconv"
	"strings"

	"gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia/engine/v1"
)

// TraitTypes in the order Traits returns them.
var traitTypes = []string{"Script", "Layout", "Hand", "Rubrication", "Vellum", "Ink", "Damage", "Alphabet", "Rarity"}

// MaxSVGBytes: measured max is ~19.5 KB over thousands of seeds and every
// forced layout; the glyph budget bounds the worst case well below this.
const MaxSVGBytes = 28672

// GlyphBudget and GlossBudget cap the glyphs placed on one page: the size
// (and gas) knob of the engine. A full Fine-hand page holds ~520 glyphs; the
// glossed page's small gloss would hold ~700, so it gets a tighter cap that is
// shared out evenly over its five blocks.
const (
	GlyphBudget = 560
	GlossBudget = 440
)

// ParamsSchema is the Studio form: three optional overrides and a damage
// switch. Studio sends JSON.stringify of the values in this order.
const ParamsSchema = `{"type":"object","properties":{` +
	`"script":{"type":"string","title":"Script","enum":["Any","Uncial","Lapidary","Cursive","Runic","Hanging"],"default":"Any"},` +
	`"layout":{"type":"string","title":"Layout","enum":["Any","Single Column","Two Columns","Stele","Scroll","Glossed"],"default":"Any"},` +
	`"vellum":{"type":"string","title":"Vellum","enum":["Any","Calfskin","Goatskin","Rag Paper","Purple"],"default":"Any"},` +
	`"damage":{"type":"boolean","title":"Damage","default":true}}}`

// Manifest describes the engine. Author and FeeBps are set by the adapter.
func Manifest() engine.Manifest {
	return engine.Manifest{
		Name:    "Rubrica",
		Version: "1.0.0",
		Description: "Every Rubrica invents an alphabet of nine to sixteen letters and writes one page in it, " +
			"a manuscript, a stele, a scroll or a glossed text, with red ink marking where a reader should begin.",
		License:      "TBD",
		ParamsSchema: ParamsSchema,
		TraitTypes:   append([]string{}, traitTypes...),
		Living:       false,
		MaxSVGBytes:  MaxSVGBytes,
	}
}

// ---------------------------------------------------------------------------
// Params: "" (the showcase look) or exactly the canonical Studio JSON
// {"script":"…","layout":"…","vellum":"…","damage":true|false}.
// ---------------------------------------------------------------------------

// Params are the decoded collection params. "Any" keeps the seeded draw.
type Params struct {
	Script, Layout, Vellum string
	Damage                 bool
}

var (
	scriptParam = []string{"Any", "Uncial", "Lapidary", "Cursive", "Runic", "Hanging"}
	layoutParam = []string{"Any", "Single Column", "Two Columns", "Stele", "Scroll", "Glossed"}
	vellumParam = []string{"Any", "Calfskin", "Goatskin", "Rag Paper", "Purple"}
	errParams   = errors.New("rubrica: params must be \"\" or the canonical JSON")
)

// DefaultParams is what "" means.
func DefaultParams() Params { return Params{"Any", "Any", "Any", true} }

// ParseParams decodes "" or the canonical JSON and refuses anything else
// (other key order, spaces, unknown keys or values, "{}").
func ParseParams(s string) (Params, error) {
	if s == "" {
		return DefaultParams(), nil
	}
	var p Params
	rest := s
	lit := func(l string) bool {
		if !strings.HasPrefix(rest, l) {
			return false
		}
		rest = rest[len(l):]
		return true
	}
	str := func(allowed []string) (string, bool) {
		end := strings.IndexByte(rest, '"')
		if end < 0 {
			return "", false
		}
		v := rest[:end]
		rest = rest[end:]
		for _, a := range allowed {
			if a == v {
				return v, true
			}
		}
		return "", false
	}
	ok := false
	if !lit(`{"script":"`) {
		return p, errParams
	}
	if p.Script, ok = str(scriptParam); !ok {
		return p, errors.New("rubrica: invalid script")
	}
	if !lit(`","layout":"`) {
		return p, errParams
	}
	if p.Layout, ok = str(layoutParam); !ok {
		return p, errors.New("rubrica: invalid layout")
	}
	if !lit(`","vellum":"`) {
		return p, errParams
	}
	if p.Vellum, ok = str(vellumParam); !ok {
		return p, errors.New("rubrica: invalid vellum")
	}
	if !lit(`","damage":`) {
		return p, errParams
	}
	switch rest {
	case "true}":
		p.Damage = true
	case "false}":
		p.Damage = false
	default:
		return p, errParams
	}
	return p, nil
}

// ValidateParams accepts "" and the canonical JSON only.
func ValidateParams(params string) error {
	_, err := ParseParams(params)
	return err
}

func mustParams(s string) Params {
	p, err := ParseParams(s)
	if err != nil {
		panic(err)
	}
	return p
}

// Traits returns the nine traits of in.Seed under in.Params, in TraitTypes
// order. It never renders.
func Traits(in engine.Input) []engine.Trait {
	t := TraitsOf(in.Seed, in.Params)
	return []engine.Trait{
		{Type: "Script", Value: t.Script},
		{Type: "Layout", Value: t.Layout},
		{Type: "Hand", Value: t.Hand},
		{Type: "Rubrication", Value: t.Rubrication},
		{Type: "Vellum", Value: t.Vellum},
		{Type: "Ink", Value: t.Ink},
		{Type: "Damage", Value: t.Damage},
		{Type: "Alphabet", Value: strconv.Itoa(t.Alphabet)},
		{Type: "Rarity", Value: t.Rarity},
	}
}

// Render returns the raw SVG for in.Seed under in.Params.
func Render(in engine.Input) string { return SVG(in.Seed, in.Params) }

// ---------------------------------------------------------------------------
// Deterministic randomness: FNV-1a over the seed, then splitmix64 (Genesis).
// ---------------------------------------------------------------------------

const (
	fnvOffset uint64 = 14695981039346656037
	fnvPrime  uint64 = 1099511628211
)

type rng struct{ s uint64 }

func newRNG(seed string) *rng {
	h := fnvOffset
	for i := 0; i < len(seed); i++ {
		h ^= uint64(seed[i])
		h *= fnvPrime
	}
	if h == 0 {
		h = fnvPrime
	}
	return &rng{s: h}
}

func (r *rng) next() uint64 {
	r.s += 0x9E3779B97F4A7C15
	z := r.s
	z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9
	z = (z ^ (z >> 27)) * 0x94D049BB133111EB
	return z ^ (z >> 31)
}

// n returns a value in [0, k).
func (r *rng) n(k int) int {
	if k <= 0 {
		return 0
	}
	return int(r.next() % uint64(k))
}

// rr returns a value in [a, b].
func (r *rng) rr(a, b int) int { return a + r.n(b-a+1) }

// ---------------------------------------------------------------------------
// Trait tables. Weights read as percent; score feeds the rarity tier.
// ---------------------------------------------------------------------------

type option struct {
	name   string
	weight int
	score  int
	v      int // Hand: glyph height
}

func pick(r *rng, table []option) option {
	total := 0
	for _, o := range table {
		total += o.weight
	}
	roll := r.n(total)
	acc := 0
	for _, o := range table {
		acc += o.weight
		if roll < acc {
			return o
		}
	}
	return table[len(table)-1]
}

func byName(table []option, name string) option {
	for _, o := range table {
		if o.name == name {
			return o
		}
	}
	return table[0]
}

var (
	scripts  = []option{{"Uncial", 26, 0, 0}, {"Lapidary", 22, 0, 0}, {"Cursive", 22, 0, 0}, {"Runic", 18, 1, 0}, {"Hanging", 12, 2, 0}}
	layouts  = []option{{"Single Column", 30, 0, 0}, {"Two Columns", 26, 0, 0}, {"Stele", 16, 1, 0}, {"Scroll", 16, 1, 0}, {"Glossed", 12, 2, 0}}
	hands    = []option{{"Fine", 30, 0, 22}, {"Book", 45, 0, 30}, {"Display", 25, 0, 40}}
	rubrics  = []option{{"None", 18, 0, 0}, {"Initials", 32, 0, 0}, {"Rubrics", 28, 0, 0}, {"Full", 22, 1, 0}}
	vellums  = []option{{"Calfskin", 40, 0, 0}, {"Goatskin", 30, 0, 0}, {"Rag Paper", 24, 0, 0}, {"Purple", 6, 4, 0}}
	inks     = []option{{"Iron Gall", 40, 0, 0}, {"Carbon", 30, 0, 0}, {"Sepia", 22, 0, 0}, {"Lapis", 8, 2, 0}}
	damages  = []option{{"None", 62, 0, 0}, {"Wormholes", 16, 1, 0}, {"Water Stain", 14, 1, 0}, {"Torn Corner", 8, 2, 0}}
	rulings  = []option{{"None", 30, 0, 0}, {"Dry-point", 45, 0, 0}, {"Pricked", 25, 0, 0}}
)

// Rarity tier cut-offs on the score (10,000-seed simulation, default
// params): Common 43% / Uncommon 26% / Rare 23% / Legendary 6% / Mythic 1.4%.
const (
	scoreMythic    = 7
	scoreLegendary = 5
	scoreRare      = 3
	scoreUncommon  = 2
)

// TraitSet is the decoded token. The SVG and the trait list both read it.
type TraitSet struct {
	Script, Layout, Hand, Rubrication string
	Vellum, Ink, Damage               string // as shown (Stone, Incised, Chrysography)
	Alphabet                          int
	Score                             int
	Rarity                            string

	ruling    string
	glyphH    int
	vellumRaw string // colour sources
	inkRaw    string
}

func derive(seed string, p Params) TraitSet {
	r := newRNG(seed + "|traits")
	// Draw order is part of the contract: every draw happens whatever the params.
	script := pick(r, scripts)
	layout := pick(r, layouts)
	hand := pick(r, hands)
	rub := pick(r, rubrics)
	vellum := pick(r, vellums)
	ink := pick(r, inks)
	damage := pick(r, damages)
	ruling := pick(r, rulings)
	alphabet := 9 + r.n(8)

	if p.Script != "Any" {
		script = byName(scripts, p.Script)
	}
	if p.Layout != "Any" {
		layout = byName(layouts, p.Layout)
	}
	if p.Vellum != "Any" {
		vellum = byName(vellums, p.Vellum)
	}
	if !p.Damage {
		damage = damages[0]
	}

	// What the page can actually show.
	if layout.name == "Stele" {
		if rub.name == "Initials" {
			rub = rubrics[0]
		}
		if rub.name == "Full" {
			rub = rubrics[2]
		}
	}
	if (layout.name == "Stele" || layout.name == "Scroll") && damage.name == "Torn Corner" {
		damage = damages[0]
	}
	t := TraitSet{
		Script: script.name, Layout: layout.name, Hand: hand.name, Rubrication: rub.name,
		Vellum: vellum.name, Ink: ink.name, Damage: damage.name, Alphabet: alphabet,
		ruling: ruling.name, glyphH: hand.v, vellumRaw: vellum.name, inkRaw: ink.name,
	}
	score := script.score + layout.score + rub.score + damage.score
	switch {
	case layout.name == "Stele":
		t.Vellum, t.Ink = "Stone", "Incised"
	case vellum.name == "Purple":
		t.Ink = "Chrysography"
		score += vellum.score
	default:
		score += ink.score
	}
	if alphabet == 16 {
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
	return t
}

// TraitsOf returns the decoded traits for a seed and params string; it
// panics on invalid params (core validates them at CreateCollection).
func TraitsOf(seed, params string) TraitSet { return derive(seed, mustParams(params)) }

// TraitString is "Type=Value;…" in TraitTypes order (golden vectors).
func TraitString(seed, params string) string {
	ts := Traits(engine.Input{Seed: seed, Params: params})
	var b strings.Builder
	for i, t := range ts {
		if i > 0 {
			b.WriteByte(';')
		}
		b.WriteString(t.Type)
		b.WriteByte('=')
		b.WriteString(t.Value)
	}
	return b.String()
}

// ---------------------------------------------------------------------------
// Art
// ---------------------------------------------------------------------------

const (
	pageW = 800
	pageH = 1100
	red0  = "#b03a22"
	ids   = "abcdefghijklmnop"
)

var (
	dirs8    = [][2]int{{1, 0}, {-1, 0}, {0, 1}, {0, -1}, {1, 1}, {-1, -1}, {1, -1}, {-1, 1}}
	dirsRune = [][2]int{{0, 1}, {0, -1}, {1, 1}, {-1, -1}, {1, -1}, {-1, 1}}
	// quarter cosine, x1024, 0..64 of a 256-step turn
	cosQ = []int{0, 25, 50, 75, 100, 125, 150, 175, 200, 224, 249, 273, 297, 321, 345, 369, 392, 415, 438, 460, 483, 505, 526,
		548, 569, 590, 610, 630, 650, 669, 688, 706, 724, 742, 759, 775, 792, 807, 822, 837, 851, 865, 878, 891, 903,
		915, 926, 936, 946, 955, 964, 972, 980, 987, 993, 999, 1004, 1009, 1013, 1016, 1019, 1021, 1023, 1024, 1024}
)

func cos256(a int) int {
	s := (a + 64) % 256
	switch {
	case s < 64:
		return cosQ[s]
	case s < 128:
		return cosQ[128-s]
	case s < 192:
		return -cosQ[s-128]
	default:
		return -cosQ[256-s]
	}
}

func vellumColor(name string) string {
	switch name {
	case "Goatskin":
		return "#e6d3ac"
	case "Rag Paper":
		return "#f2ecdd"
	case "Purple":
		return "#3e1a33"
	default: // Calfskin
		return "#efe3c6"
	}
}

func inkColor(name string) string {
	switch name {
	case "Carbon":
		return "#1b1a19"
	case "Sepia":
		return "#5e4128"
	case "Lapis":
		return "#2a3f7a"
	default: // Iron Gall
		return "#3b2a1e"
	}
}

func strokeDiv(script string) int {
	switch script {
	case "Lapidary":
		return 7
	case "Cursive":
		return 10
	case "Runic":
		return 9
	default: // Uncial, Hanging
		return 8
	}
}

const hexDigits = "0123456789abcdef"

func hexVal(c byte) int {
	switch {
	case c >= '0' && c <= '9':
		return int(c - '0')
	case c >= 'a' && c <= 'f':
		return int(c-'a') + 10
	default:
		return int(c-'A') + 10
	}
}

// shade adds d to each channel of a #rrggbb colour, clamped to 0..255.
func shade(c string, d int) string {
	out := []byte{'#'}
	for _, i := range []int{1, 3, 5} {
		v := hexVal(c[i])*16 + hexVal(c[i+1]) + d
		if v < 0 {
			v = 0
		}
		if v > 255 {
			v = 255
		}
		out = append(out, hexDigits[v/16], hexDigits[v%16])
	}
	return string(out)
}

func itoa(n int) string { return strconv.Itoa(n) }

func maxInt(a, b int) int {
	if a > b {
		return a
	}
	return b
}

func makeGlyph(r *rng, script string, gw, gh int) string {
	slant := script == "Cursive" // glyph-local skew: x shifts by -y/4
	pt := func(gx, gy int) (int, int) {
		y := gy*gh/3 - gh // baseline at y=0
		x := gx * gw / 2
		if slant {
			x -= y / 4
		}
		return x, y
	}
	dirs := dirs8
	if script == "Runic" {
		dirs = dirsRune
	}
	var d strings.Builder
	strokes := r.rr(2, 4)
	for s := 0; s < strokes; s++ {
		gx := r.n(3)
		gy := 0
		if !(script == "Hanging" && s == 0) {
			gy = r.n(4)
		}
		path := [][2]int{{gx, gy}}
		steps := r.rr(1, 3)
		for st := 0; st < steps; st++ {
			for tries := 0; tries < 8; tries++ {
				dir := dirs[r.n(len(dirs))]
				nx, ny := gx+dir[0], gy+dir[1]
				if nx < 0 || nx > 2 || ny < 0 || ny > 3 {
					continue
				}
				seen := false
				for _, q := range path {
					if q[0] == nx && q[1] == ny {
						seen = true
						break
					}
				}
				if seen {
					continue
				}
				gx, gy = nx, ny
				path = append(path, [2]int{gx, gy})
				break
			}
		}
		if len(path) < 2 {
			continue
		}
		px := make([]int, len(path))
		py := make([]int, len(path))
		for k, q := range path {
			px[k], py[k] = pt(q[0], q[1])
		}
		last := len(path) - 1
		d.WriteString("M" + itoa(px[0]) + " " + itoa(py[0]))
		if (script == "Uncial" || script == "Cursive") && len(path) > 2 {
			for k := 1; k < last; k++ {
				mx := (px[k] + px[k+1]) / 2
				my := (py[k] + py[k+1]) / 2
				d.WriteString("Q" + itoa(px[k]) + " " + itoa(py[k]) + " " + itoa(mx) + " " + itoa(my))
			}
			d.WriteString("L" + itoa(px[last]) + " " + itoa(py[last]))
		} else {
			for k := 1; k <= last; k++ {
				d.WriteString("L" + itoa(px[k]) + " " + itoa(py[k]))
			}
		}
	}
	if script != "Runic" && r.n(4) == 0 {
		x, y := pt(r.n(3), 0)
		d.WriteString("M" + itoa(x) + " " + itoa(y-gh/4) + "h0")
	}
	if d.Len() == 0 {
		return "M0 0V" + itoa(-gh)
	}
	return d.String()
}

type block struct{ x0, y0, x1, y1, sc int }

// SVG renders the page for a seed and params string as a standalone SVG.
func SVG(seed, params string) string {
	return svgOf(seed, derive(seed, mustParams(params)))
}

func svgOf(seed string, t TraitSet) string {
	r := newRNG(seed + "|art")
	script, layout, rub := t.Script, t.Layout, t.Rubrication
	gh := t.glyphH
	gw := gh * 2 / 3
	vel := vellumColor(t.vellumRaw)
	ink := inkColor(t.inkRaw)
	red := red0
	if layout == "Stele" {
		vel = "#bdb5a6"
		ink = "#4a4238"
	} else if t.vellumRaw == "Purple" {
		ink = "#d4af5a"
		red = "#d8d4cc"
	}
	ng := t.Alphabet
	caps := "round"
	if script == "Lapidary" {
		caps = "square"
	} else if script == "Runic" {
		caps = "butt"
	}
	sw := maxInt(2, gh/strokeDiv(script))

	var b strings.Builder
	b.WriteString(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 800 1100" width="800" height="1100"><defs>`)
	for k := 0; k < ng; k++ {
		b.WriteString(`<path id="` + ids[k:k+1] + `" d="` + makeGlyph(r, script, gw, gh) + `"/>`)
	}
	b.WriteString(`<radialGradient id="v"><stop offset=".6" stop-color="#000" stop-opacity="0"/><stop offset="1" stop-color="#3a2410" stop-opacity=".2"/></radialGradient></defs>`)
	b.WriteString(`<rect width="800" height="1100" fill="#2b2420"/>`)

	const px0, py0, px1, py1 = 40, 40, pageW - 40, pageH - 40
	var page string
	switch {
	case layout == "Stele":
		page = "M110 " + itoa(py1) + "V300A290 290 0 0 1 690 300V" + itoa(py1) + "Z"
	case layout == "Scroll":
		page = "M190 90H610V1010H190Z"
	case t.Damage == "Torn Corner":
		cut := r.rr(160, 260)
		var pb strings.Builder
		pb.WriteString("M" + itoa(px0) + " " + itoa(py0) + "H" + itoa(px1) + "V" + itoa(py1-cut) +
			"L" + itoa(px1-4) + " " + itoa(py1-cut))
		for k := 1; k < 6; k++ {
			jx := px1 - cut*k/6 + r.rr(-14, 14)
			jy := py1 - cut + cut*k/6 + r.rr(-14, 14)
			pb.WriteString("L" + itoa(jx) + " " + itoa(jy))
		}
		pb.WriteString("L" + itoa(px1-cut) + " " + itoa(py1) + "H" + itoa(px0) + "Z")
		page = pb.String()
	default:
		page = "M" + itoa(px0) + " " + itoa(py0) + "H" + itoa(px1) + "V" + itoa(py1) + "H" + itoa(px0) + "Z"
	}
	b.WriteString(`<path d="` + page + `" fill="` + vel + `"/>`)
	if layout == "Scroll" {
		for _, y := range []int{60, 1010} {
			b.WriteString(`<rect x="160" y="` + itoa(y) + `" width="480" height="30" rx="15" fill="#6a4a2a"/><rect x="170" y="` +
				itoa(y+6) + `" width="460" height="8" rx="4" fill="#9a7a4a"/>`)
		}
	}
	if t.Damage == "Water Stain" {
		cx := r.rr(250, 550)
		cy := r.rr(300, 800)
		rr := r.rr(140, 240)
		b.WriteString(`<path d="M`)
		for k := 0; k < 16; k++ {
			ang := k * 16
			rad := rr + r.rr(-30, 30)
			if k > 0 {
				b.WriteString("L")
			}
			b.WriteString(itoa(cx+rad*cos256(ang)/1024) + " " + itoa(cy+rad*cos256(ang+192)/1024))
		}
		b.WriteString(`Z" fill="` + shade(vel, -14) + `" stroke="` + shade(vel, -40) + `" stroke-width="3" opacity=".8"/>`)
	}

	var blocks []block
	switch layout {
	case "Single Column":
		blocks = []block{{130, 130, 670, 920, 100}}
	case "Two Columns":
		blocks = []block{{110, 130, 385, 930, 100}, {415, 130, 690, 930, 100}}
	case "Stele":
		blocks = []block{{170, 330, 630, 980, 100}}
	case "Scroll":
		blocks = []block{{230, 150, 570, 960, 100}}
	default: // Glossed: main text in the centre, a fine gloss around it
		gs := maxInt(60, 1900/gh)
		blocks = []block{{250, 300, 550, 700, 100}, {90, 120, 710, 280, gs}, {90, 300, 230, 960, gs},
			{570, 300, 710, 960, gs}, {250, 720, 550, 960, gs}}
	}

	freqTotal := ng * (ng + 5) / 2 // sum of (ng + 2 - k), k = 0..ng-1

	budget := GlyphBudget
	if layout == "Glossed" {
		budget = GlossBudget
	}
	var ruleD, prick strings.Builder
	var linesOut strings.Builder
	display := t.Hand == "Display"
	for bi, bl := range blocks {
		x0, y0, x1, y1, sc := bl.x0, bl.y0, bl.x1, bl.y1, bl.sc
		g := gh
		adv := gw * 5 / 4
		lead := g * 150 / 100
		if display {
			lead = g * 135 / 100
		}
		ymax := y0 + (y1-y0)*100/sc
		xmax := x0 + (x1-x0)*100/sc
		box := 2*lead - 6
		allow := budget / (len(blocks) - bi) // every block gets its share
		left := allow
		y := y0 + g
		paraLeft, indLeft := 0, 0
		var uses, reds, ligs strings.Builder
		for y <= ymax {
			if sc == 100 && t.ruling == "Dry-point" {
				ruleD.WriteString("M" + itoa(x0-10) + " " + itoa(y) + "H" + itoa(x1+10))
			}
			if sc == 100 && t.ruling == "Pricked" {
				prick.WriteString("M" + itoa(x1+40) + " " + itoa(y) + "h0")
			}
			first := paraLeft == 0
			if first {
				paraLeft = r.rr(3, 8)
			}
			x, xend := x0, xmax
			if layout == "Stele" {
				width := (x1 - x0) * r.rr(70, 100) / 100
				x = x0 + (x1-x0-width)/2
				xend = x + width
			}
			if first && (rub == "Initials" || rub == "Full") && sc == 100 && layout != "Stele" {
				k := r.n(ng)
				boxFill, glyphStroke := "none", red
				if rub == "Full" {
					boxFill, glyphStroke = "#2a3f7a", "#e8c46a"
				}
				reds.WriteString(`<rect x="` + itoa(x) + `" y="` + itoa(y-g-4) + `" width="` + itoa(box) + `" height="` + itoa(box) +
					`" fill="` + boxFill + `" stroke="` + red + `" stroke-width="3"/>`)
				reds.WriteString(`<use href="#` + ids[k:k+1] + `" transform="translate(` + itoa(x+box/5) + " " +
					itoa(y-g-4+box*85/100) + `) scale(1.9)" stroke="` + glyphStroke + `"/>`)
				indLeft = 2
			}
			if indLeft > 0 {
				x += box + 10
				indLeft--
			}
			limit := xend
			if paraLeft == 1 {
				limit = xend - (xend-x)*r.rr(30, 70)/100
			}
			redLine := first && (rub == "Rubrics" || rub == "Full")
			if redLine && layout != "Stele" {
				reds.WriteString(`<path d="M` + itoa(x+4) + " " + itoa(y-g/2) + `h0" stroke="` + red + `" stroke-width="` +
					itoa(g/2+4) + `" stroke-linecap="round"/>`)
				x += g
			}
			var line strings.Builder
			for {
				wl := r.rr(1, 7)
				if x+wl*adv > limit || left < wl {
					break
				}
				left -= wl
				wx0 := x
				for i := 0; i < wl; i++ {
					roll := r.n(freqTotal)
					acc, k := 0, ng-1
					for j := 0; j < ng; j++ {
						acc += ng + 2 - j
						if roll < acc {
							k = j
							break
						}
					}
					line.WriteString(`<use href="#` + ids[k:k+1] + `" x="` + itoa(x) + `"/>`)
					x += adv
				}
				if script == "Cursive" {
					ligs.WriteString("M" + itoa(wx0) + " " + itoa(y) + "H" + itoa(x-adv+gw/2))
				}
				if script == "Hanging" {
					ligs.WriteString("M" + itoa(wx0-2) + " " + itoa(y-g) + "H" + itoa(x-adv+gw+2))
				}
				x += adv * 4 / 5
			}
			if line.Len() > 0 {
				// one translate per line: each glyph then only needs x
				if redLine {
					reds.WriteString(`<g transform="translate(0 ` + itoa(y) + `)" stroke="` + red + `">` + line.String() + `</g>`)
				} else {
					uses.WriteString(`<g transform="translate(0 ` + itoa(y) + `)">` + line.String() + `</g>`)
				}
			}
			paraLeft--
			y += lead
		}
		budget -= allow - left
		body := uses.String()
		if ligs.Len() > 0 {
			body += `<path d="` + ligs.String() + `" stroke-width="` + itoa(maxInt(1, sw-1)) + `"/>`
		}
		grp := `<g fill="none" stroke="` + ink + `" stroke-width="` + itoa(sw) + `" stroke-linecap="` + caps + `" stroke-linejoin="round">`
		switch {
		case layout == "Stele":
			// the incised light edge reuses the text body instead of repeating it
			linesOut.WriteString(`<g fill="none" stroke="#f1ece2" stroke-width="` + itoa(sw) + `" stroke-linecap="` + caps +
				`" transform="translate(2 2)" opacity=".7"><g id="t">` + body + `</g></g>`)
			linesOut.WriteString(grp + `<use href="#t"/>` + reds.String() + `</g>`)
		case sc == 100:
			linesOut.WriteString(grp + body + reds.String() + `</g>`)
		default:
			linesOut.WriteString(grp + `<g transform="translate(` + itoa(x0) + " " + itoa(y0) + ") scale(." + itoa(sc) +
				") translate(-" + itoa(x0) + " -" + itoa(y0) + `)">` + body + reds.String() + `</g></g>`)
		}
	}
	if ruleD.Len() > 0 {
		b.WriteString(`<path d="` + ruleD.String() + `" stroke="` + shade(vel, -30) + `" stroke-width="1" opacity=".6"/>`)
	}
	if prick.Len() > 0 {
		b.WriteString(`<path d="` + prick.String() + `" stroke="` + shade(vel, -80) + `" stroke-width="4" stroke-linecap="round"/>`)
	}
	b.WriteString(linesOut.String())
	if t.Damage == "Wormholes" {
		b.WriteString(`<g fill="#2b2420">`)
		n := r.rr(8, 20)
		for i := 0; i < n; i++ {
			cx := r.rr(80, 720)
			cy := r.rr(80, 1020)
			rad := r.rr(3, 8)
			b.WriteString(`<circle cx="` + itoa(cx) + `" cy="` + itoa(cy) + `" r="` + itoa(rad) + `"/>`)
		}
		b.WriteString(`</g>`)
	}
	b.WriteString(`<path d="` + page + `" fill="url(#v)"/></svg>`)
	return b.String()
}
