// Package cantiere is a Sinopia showcase engine: isometric maquettes of
// imaginary hill towns on a ruled drafting sheet, with red scaffolding for
// the storeys not yet built ("cantiere" is Italian for building site).
//
// A plan generator writes an N x N height map (N = 6..8); columns are drawn
// back to front, one anti-diagonal at a time. Columns on one diagonal never
// overlap, so each diagonal is a handful of merged paths, one per fill, and
// windows are skewed <pattern> tiles instead of one element per window. That
// keeps the SVG small (median ~5.5 KB) and the render cheap.
//
// Determinism: the same FNV-1a + splitmix64 stream as Genesis, with separate
// streams for traits (seed+"|traits") and art (seed+"|art"), so art draws
// never shift traits. Pure integer math; every division truncates (Go). The
// TypeScript twin (frontend/src/engines/cantiere.ts) is byte-identical; the
// golden vectors in cantiere_test.gno pin both.
//
// Params ("" = the showcase): canonical JSON in schema order, e.g.
// {"light":"Night","material":"Any","plan":"Any","scaffold":true}. A param
// pins one trait after all trait draws, so the other traits of a seed stay
// the same in every variant.
package cantiere

import (
	"errors"
	"strconv"
	"strings"

	"gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia/engine/v1"
)

// traitTypes in the order Traits returns them.
var traitTypes = []string{"Plan", "Material", "Light", "Scaffold", "Openings", "Garden", "Water", "Storeys", "Rarity"}

// MaxSVGBytes: the largest output measured is 15,448 B (5,000 default seeds)
// and 15,174 B (19,600 renders over every param set); median ~5.5 KB. 2x margin.
const MaxSVGBytes = 32768

// ParamsSchema is the Studio form: three trait pins and a scaffolding switch.
const ParamsSchema = `{"type":"object","properties":{` +
	`"light":{"type":"string","title":"Light","enum":["Any","Morning","Evening","Noon","Night"],"default":"Any"},` +
	`"material":{"type":"string","title":"Material","enum":["Any","Tufa","Brick","Travertine","Painted Plaster","Concrete","Basalt"],"default":"Any"},` +
	`"plan":{"type":"string","title":"Plan","enum":["Any","Hill Town","Ziggurat","Courtyard","Terraces","Towers","Ruin"],"default":"Any"},` +
	`"scaffold":{"type":"boolean","title":"Scaffolding","default":true}}}`

// Manifest describes the engine. Author and FeeBps are set by the adapter
// realm that registers it.
func Manifest() engine.Manifest {
	return engine.Manifest{
		Name:    "Cantiere",
		Version: "1.0.0",
		Description: "Isometric maquettes of imaginary hill towns on a ruled drafting sheet, " +
			"with red scaffolding for the storeys not yet built.",
		License:      "TBD",
		ParamsSchema: ParamsSchema,
		TraitTypes:   append([]string{}, traitTypes...),
		Living:       false,
		MaxSVGBytes:  MaxSVGBytes,
	}
}

// ValidateParams accepts "" or exactly the canonical params JSON.
func ValidateParams(params string) error {
	_, err := ParseParams(params)
	return err
}

// Traits returns the nine traits of in.Seed in TraitTypes order. It never
// renders: a few table draws only.
func Traits(in engine.Input) []engine.Trait {
	t := TraitsOf(in.Seed, in.Params)
	return []engine.Trait{
		{Type: "Plan", Value: t.Plan},
		{Type: "Material", Value: t.Material},
		{Type: "Light", Value: t.Light},
		{Type: "Scaffold", Value: t.Scaffold},
		{Type: "Openings", Value: t.Openings},
		{Type: "Garden", Value: t.Garden},
		{Type: "Water", Value: t.Water},
		{Type: "Storeys", Value: strconv.Itoa(t.Storeys)},
		{Type: "Rarity", Value: t.Rarity},
	}
}

// Render returns the raw SVG for in.Seed and in.Params.
func Render(in engine.Input) string { return SVG(in.Seed, in.Params) }

// ---------------------------------------------------------------------------
// Params
// ---------------------------------------------------------------------------

const anyValue = "Any"

var (
	paramLights    = []string{anyValue, "Morning", "Evening", "Noon", "Night"}
	paramMaterials = []string{anyValue, "Tufa", "Brick", "Travertine", "Painted Plaster", "Concrete", "Basalt"}
	paramPlans     = []string{anyValue, "Hill Town", "Ziggurat", "Courtyard", "Terraces", "Towers", "Ruin"}
)

// Params are the decoded collection params.
type Params struct {
	Light, Material, Plan string
	Scaffold              bool
}

var errParams = errors.New(`cantiere params: want "" or {"light":"…","material":"…","plan":"…","scaffold":true|false} with values from the schema`)

type paramReader struct {
	s string
	i int
}

func (q *paramReader) lit(l string) bool {
	if !strings.HasPrefix(q.s[q.i:], l) {
		return false
	}
	q.i += len(l)
	return true
}

func (q *paramReader) str(allowed []string) (string, bool) {
	end := strings.IndexByte(q.s[q.i:], '"')
	if end < 0 {
		return "", false
	}
	v := q.s[q.i : q.i+end]
	q.i += end + 1
	for _, a := range allowed {
		if a == v {
			return v, true
		}
	}
	return "", false
}

// ParseParams decodes "" (defaults) or the canonical JSON Studio sends
// (schema order, no whitespace). Anything else is an error.
func ParseParams(s string) (Params, error) {
	p := Params{Light: anyValue, Material: anyValue, Plan: anyValue, Scaffold: true}
	if s == "" {
		return p, nil
	}
	q := &paramReader{s: s}
	var ok bool
	if !q.lit(`{"light":"`) {
		return p, errParams
	}
	if p.Light, ok = q.str(paramLights); !ok || !q.lit(`,"material":"`) {
		return p, errParams
	}
	if p.Material, ok = q.str(paramMaterials); !ok || !q.lit(`,"plan":"`) {
		return p, errParams
	}
	if p.Plan, ok = q.str(paramPlans); !ok || !q.lit(`,"scaffold":`) {
		return p, errParams
	}
	switch {
	case q.lit("true"):
		p.Scaffold = true
	case q.lit("false"):
		p.Scaffold = false
	default:
		return p, errParams
	}
	if !q.lit("}") || q.i != len(s) {
		return p, errParams
	}
	return p, nil
}

func mustParams(s string) Params {
	p, err := ParseParams(s)
	if err != nil {
		panic(err.Error())
	}
	return p
}

// ---------------------------------------------------------------------------
// Deterministic randomness: FNV-1a over the seed, then splitmix64 (Genesis).
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

// rangeIn returns a value in [lo, hi].
func (r *rng) rangeIn(lo, hi int) int { return lo + r.intn(hi-lo+1) }

// ---------------------------------------------------------------------------
// Trait tables: weights sum to 100; score feeds the rarity tier.
// ---------------------------------------------------------------------------

type option struct {
	name   string
	weight int
	score  int
}

// weightTotal: every table's weights sum to 100 (TestTableWeights), so one
// draw of intn(100) walks the table; the TS twin sums them, same value.
const weightTotal = 100

// pickIdx returns the index of the drawn option.
func pickIdx(r *rng, table []option) int {
	roll := r.intn(weightTotal)
	acc := 0
	for k := 0; k < len(table); k++ {
		acc += table[k].weight
		if roll < acc {
			return k
		}
	}
	return len(table) - 1
}

func findIdx(table []option, name string) int {
	for k := 0; k < len(table); k++ {
		if table[k].name == name {
			return k
		}
	}
	return 0
}

var (
	plans     = []option{{"Hill Town", 26, 0}, {"Ziggurat", 18, 1}, {"Courtyard", 18, 1}, {"Terraces", 16, 1}, {"Towers", 14, 1}, {"Ruin", 8, 3}}
	materials = []option{{"Tufa", 22, 0}, {"Brick", 20, 0}, {"Travertine", 18, 0}, {"Painted Plaster", 18, 1}, {"Concrete", 12, 1}, {"Basalt", 10, 2}}
	lights    = []option{{"Morning", 34, 0}, {"Evening", 34, 0}, {"Noon", 18, 1}, {"Night", 14, 3}}
	scaffolds = []option{{"None", 40, 0}, {"Some", 40, 0}, {"Heavy", 20, 2}}
	openingsT = []option{{"Windows", 55, 0}, {"Loggias", 25, 1}, {"Blind", 20, 1}}
	gardens   = []option{{"None", 55, 0}, {"Cypresses", 32, 1}, {"Roof Gardens", 13, 2}}
	waters    = []option{{"None", 55, 0}, {"Pool", 25, 1}, {"Canal", 20, 1}}
)

// materialColours in materials order; Painted Plaster picks one per column.
var materialColours = [][]string{
	{"#d9b46a"},
	{"#b3563a"},
	{"#e6dcc6"},
	{"#e8a06a", "#e9c46a", "#d9786a", "#c9b48a", "#9ab08a", "#e6d2b0"},
	{"#a9a59c"},
	{"#5a5650"},
}

// Tier cut-offs on the summed scores (Storeys is derived, not scored). Over
// 1,000 sample seeds: Common 25% / Uncommon 39% / Rare 26% / Legendary 9% /
// Mythic 1%.
const (
	scoreMythic    = 9
	scoreLegendary = 7
	scoreRare      = 5
	scoreUncommon  = 3
)

// TraitSet is the decoded properties of a seed; the SVG and the trait list
// both read it, so picture and metadata cannot disagree.
type TraitSet struct {
	Plan, Material, Light, Scaffold, Openings, Garden, Water string
	Storeys                                                  int // tallest built column
	Score                                                    int
	Rarity                                                   string
	material                                                 int // index into materials
}

func derive(seed string, p Params) TraitSet {
	r := newRNG(seed + "|traits")
	// Draw order is part of the contract: changing it changes every token.
	ip := pickIdx(r, plans)
	im := pickIdx(r, materials)
	il := pickIdx(r, lights)
	is := pickIdx(r, scaffolds)
	io := pickIdx(r, openingsT)
	ig := pickIdx(r, gardens)
	iw := pickIdx(r, waters)
	hm := r.rangeIn(5, 8)

	if p.Plan != anyValue {
		ip = findIdx(plans, p.Plan)
	}
	if p.Material != anyValue {
		im = findIdx(materials, p.Material)
	}
	if p.Light != anyValue {
		il = findIdx(lights, p.Light)
	}
	if !p.Scaffold {
		is = 0
	}
	if ip == 2 && iw == 0 { // Courtyard: the court always holds a pool
		iw = 1
	}
	plan, material, light, scaffold := plans[ip], materials[im], lights[il], scaffolds[is]
	openings, garden, water := openingsT[io], gardens[ig], waters[iw]

	storeys := hm
	if ip == 4 { // Towers
		storeys = hm + 2
	} else if ip == 5 { // Ruin
		storeys = hm - 2
	}

	t := TraitSet{
		Plan: plan.name, Material: material.name, Light: light.name, Scaffold: scaffold.name,
		Openings: openings.name, Garden: garden.name, Water: water.name, Storeys: storeys,
		material: im,
	}
	t.Score = plan.score + material.score + light.score + scaffold.score + openings.score + garden.score + water.score
	switch {
	case t.Score >= scoreMythic:
		t.Rarity = "Mythic"
	case t.Score >= scoreLegendary:
		t.Rarity = "Legendary"
	case t.Score >= scoreRare:
		t.Rarity = "Rare"
	case t.Score >= scoreUncommon:
		t.Rarity = "Uncommon"
	default:
		t.Rarity = "Common"
	}
	return t
}

// TraitsOf returns the decoded traits of a seed; it panics on invalid params.
func TraitsOf(seed, params string) TraitSet {
	return derive(seed, mustParams(params))
}

// TraitString is "Type=Value;…" in TraitTypes order (the golden-vector form
// shared with the TypeScript twin).
func TraitString(seed, params string) string {
	var b strings.Builder
	for i, tr := range Traits(engine.Input{Seed: seed, Params: params}) {
		if i > 0 {
			b.WriteString(";")
		}
		b.WriteString(tr.Type + "=" + tr.Value)
	}
	return b.String()
}

// ---------------------------------------------------------------------------
// Art
// ---------------------------------------------------------------------------

const (
	canvas     = 1000
	gardenTone = 6 // top-tone key of a roof garden
	hexDigits  = "0123456789abcdef"
)

func hexVal(c byte) int {
	if c >= 'a' {
		return int(c-'a') + 10
	}
	return int(c - '0')
}

// shade adds d to each channel of #rrggbb, clamped to 0..255.
func shade(col string, d int) string {
	out := []byte{'#', 0, 0, 0, 0, 0, 0}
	for k := 1; k < 7; k += 2 {
		v := hexVal(col[k])*16 + hexVal(col[k+1]) + d
		if v < 0 {
			v = 0
		}
		if v > 255 {
			v = 255
		}
		out[k] = hexDigits[v>>4]
		out[k+1] = hexDigits[v&15]
	}
	return string(out)
}

func isqrt(n int) int {
	if n <= 0 {
		return 0
	}
	x := n
	y := (x + 1) / 2
	for y < x {
		x = y
		y = (x + n/x) / 2
	}
	return x
}

func absInt(x int) int {
	if x < 0 {
		return -x
	}
	return x
}

func maxInt(x, y int) int {
	if x > y {
		return x
	}
	return y
}

func minInt(x, y int) int {
	if x < y {
		return x
	}
	return y
}

func grid(n int) [][]int {
	g := make([][]int, n)
	for i := range g {
		g[i] = make([]int, n)
	}
	return g
}

func flags(n int) [][]bool {
	g := make([][]bool, n)
	for i := range g {
		g[i] = make([]bool, n)
	}
	return g
}

func heights(r *rng, plan string, n, peak int) [][]int {
	h := grid(n)
	for i := 0; i < n; i++ {
		for j := 0; j < n; j++ {
			k := maxInt(absInt(2*i-(n-1)), absInt(2*j-(n-1))) // 2 x Chebyshev distance from the centre
			v := 0
			switch plan {
			case "Ziggurat":
				top := 0
				if k <= 1 {
					top = 1
				}
				v = maxInt(1, peak-(k/2)*r.rangeIn(1, 2)+top)
			case "Courtyard":
				if i == 0 || i == n-1 || j == 0 || j == n-1 {
					v = r.rangeIn(3, peak)
				} else if k >= n-3 {
					v = 1
				}
			case "Terraces":
				v = maxInt(1, peak-((i+j)*peak)/(2*n-2)+r.rangeIn(0, 1))
			case "Towers":
				v = 1
			case "Ruin":
				if r.intn(10) < 3 {
					v = 0
				} else {
					v = r.rangeIn(1, peak)
				}
			default: // Hill Town
				dx := 2*i - n - 1
				dy := 2*j - n + 2
				d := isqrt(dx*dx + dy*dy)
				v = maxInt(0, peak-(d*3)/4+r.rangeIn(-1, 1))
				if r.intn(9) == 0 {
					v = 0
				}
			}
			h[i][j] = minInt(v, peak)
		}
	}
	if plan == "Towers" {
		towers := r.rangeIn(4, 8)
		for k := 0; k < towers; k++ {
			ti := r.intn(n)
			tj := r.intn(n)
			h[ti][tj] = r.rangeIn(4, peak)
		}
	}
	return h
}

// town is the laid-out maquette: grid, scale and projection origin.
type town struct {
	n, a, b, c, ox, oy int
	hts                [][]int
}

func (t *town) px(i, j int) int    { return t.ox + (i-j)*t.a }
func (t *town) py(i, j, z int) int { return t.oy + (i+j)*t.b - z*t.c }

func (t *town) hl(i, j int) int { // height of the neighbour in front-left
	if j+1 < t.n {
		return t.hts[i][j+1]
	}
	return 0
}

func (t *town) hr(i, j int) int { // height of the neighbour in front-right
	if i+1 < t.n {
		return t.hts[i+1][j]
	}
	return 0
}

func num(b *strings.Builder, v int) { b.WriteString(strconv.Itoa(v)) }

func (t *town) rhomb(b *strings.Builder, x, y int) {
	b.WriteString("M")
	num(b, x)
	b.WriteString(" ")
	num(b, y)
	b.WriteString("l")
	num(b, t.a)
	b.WriteString(" ")
	num(b, t.b)
	num(b, -t.a)
	b.WriteString(" ")
	num(b, t.b)
	num(b, -t.a)
	b.WriteString(" ")
	num(b, -t.b)
	b.WriteString("z")
}

// face writes the visible part of a column's left (side 0) or right (side 1) face.
func (t *town) face(b *strings.Builder, side, i, j int) {
	h := t.hts[i][j]
	var x, y, lo, dx int
	if side == 0 {
		lo = t.hl(i, j)
		x, y, dx = t.px(i, j+1), t.py(i, j+1, lo), t.a
	} else {
		lo = t.hr(i, j)
		x, y, dx = t.px(i+1, j), t.py(i+1, j, lo), -t.a
	}
	b.WriteString("M")
	num(b, x)
	b.WriteString(" ")
	num(b, y)
	b.WriteString("l")
	num(b, dx)
	b.WriteString(" ")
	num(b, t.b)
	b.WriteString("v")
	num(b, -(h-lo)*t.c)
	b.WriteString("l")
	num(b, -dx)
	b.WriteString(" ")
	num(b, -t.b)
	b.WriteString("z")
}

func (t *town) hasFace(side, i, j int) bool {
	if side == 0 {
		return t.hts[i][j] > t.hl(i, j)
	}
	return t.hts[i][j] > t.hr(i, j)
}

// opening writes one window (Windows: slot k of 2) or loggia of the bay
// whose tile corner is (u, v).
func opening(b *strings.Builder, openings string, a, u, v, k int) {
	ww := maxInt(3, a/8)
	wy := (a * 3) / 10
	wh := a / 2
	x, w := u+a/4, a/2
	if openings == "Windows" {
		wh = (a * 45) / 100
		w = ww
		x = u + a/3 - ww/2
		if k != 0 {
			x = u + (2*a)/3 - ww/2
		}
	}
	b.WriteString("M")
	num(b, x)
	b.WriteString(" ")
	num(b, v+wy)
	b.WriteString("h")
	num(b, w)
	b.WriteString("v")
	num(b, wh)
	b.WriteString("h")
	num(b, -w)
	b.WriteString("z")
}

func pathEl(b *strings.Builder, d, attrs string) {
	b.WriteString(`<path d="`)
	b.WriteString(d)
	b.WriteString(`" `)
	b.WriteString(attrs)
	b.WriteString(`/>`)
}

// SVG renders the artwork for a seed and params; it panics on invalid params.
func SVG(seed, params string) string {
	tr := derive(seed, mustParams(params))
	return draw(seed, tr)
}

func draw(seed string, tr TraitSet) string {
	r := newRNG(seed + "|art") // separate stream: art draws never shift traits
	n := r.rangeIn(6, 8)
	peak := tr.Storeys
	hts := heights(r, tr.Plan, n, peak)
	water := flags(n)

	if tr.Water == "Canal" {
		cj := r.rangeIn(1, n-2)
		for i := 0; i < n; i++ {
			hts[i][cj] = 0
			water[i][cj] = true
		}
	} else if tr.Water == "Pool" {
		ci := n/2 - 1
		cj := ci
		if tr.Plan != "Courtyard" { // towards the front, where the town does not hide it
			ci = r.rangeIn(n/2-1, n-2)
			cj = r.rangeIn(n/2-1, n-2)
		}
		for i := ci; i <= ci+1; i++ {
			for j := cj; j <= cj+1; j++ {
				hts[i][j] = 0
				water[i][j] = true
			}
		}
	}

	// The landmark: the tallest dry column is raised to the Storeys trait.
	li, lj := -1, -1
	for i := 0; i < n; i++ {
		for j := 0; j < n; j++ {
			if !water[i][j] && (li < 0 || hts[i][j] > hts[li][lj]) {
				li, lj = i, j
			}
		}
	}
	hts[li][lj] = peak

	// Per-column choices, scanned row by row.
	cols := materialColours[tr.material]
	plaster := len(cols) > 1
	tone := grid(n)
	roof := flags(n)
	tree := flags(n)
	toneUsed := make([]bool, 6)
	roofs, trees := 0, 0
	for i := 0; i < n; i++ {
		for j := 0; j < n; j++ {
			h := hts[i][j]
			if h > 0 && plaster {
				tone[i][j] = r.intn(6)
			}
			if h > 0 {
				toneUsed[tone[i][j]] = true
			}
			if tr.Garden == "Roof Gardens" && h > 0 && r.intn(3) == 0 {
				roof[i][j] = true
				roofs++
			}
			if tr.Garden == "Cypresses" && !water[i][j] && h <= 3 && r.intn(4) == 0 {
				tree[i][j] = true
				trees++
			}
		}
	}
	// A garden trait is always visible: fall back to the front-most column that can carry it.
	if tr.Garden == "Roof Gardens" && roofs == 0 {
		done := false
		for i := n - 1; i >= 0 && !done; i-- {
			for j := n - 1; j >= 0; j-- {
				if hts[i][j] > 0 {
					roof[i][j] = true
					done = true
					break
				}
			}
		}
	}
	if tr.Garden == "Cypresses" && trees == 0 {
		// the front-most low dry column, else the front-most dry one
		fi, fj, gi, gj := -1, -1, -1, -1
		for i := n - 1; i >= 0; i-- {
			for j := n - 1; j >= 0; j-- {
				if water[i][j] {
					continue
				}
				if gi < 0 {
					gi, gj = i, j
				}
				if fi < 0 && hts[i][j] <= 3 {
					fi, fj = i, j
				}
			}
		}
		if fi < 0 {
			fi, fj = gi, gj
		}
		tree[fi][fj] = true
	}

	// Scaffolding: unbuilt storeys on top of a column (or on an empty lot).
	scaf := grid(n)
	ns := 0
	if tr.Scaffold == "Some" {
		ns = r.rangeIn(2, 4)
	} else if tr.Scaffold == "Heavy" {
		ns = r.rangeIn(6, 11)
	}
	if tr.Plan == "Ruin" && ns > 0 {
		ns += 3
	}
	for k := 0; k < ns; k++ {
		si := r.intn(n)
		sj := r.intn(n)
		for water[si][sj] {
			sj = (sj + 1) % n
		}
		scaf[si][sj] = r.rangeIn(1, 3)
	}

	sunY := r.rangeIn(130, 200)
	sunR := r.rangeIn(50, 80)

	night := tr.Light == "Night"
	openings := tr.Openings
	slots := 1
	if openings == "Windows" {
		slots = 2
	}
	// Night: which windows of a 3 x 4 bay tile are lit.
	var lit []bool
	if night && openings != "Blind" {
		for k := 0; k < 12*slots; k++ {
			lit = append(lit, r.intn(5) < 2)
		}
	}

	hmax := 0
	for i := 0; i < n; i++ {
		for j := 0; j < n; j++ {
			hmax = maxInt(hmax, hts[i][j]+scaf[i][j])
		}
	}

	// Scale: fit the tallest stack and the plan inside the sheet.
	a := minInt(380/n, 1800/(2*hmax+2*n+1))
	a -= a % 2
	t := &town{n: n, a: a, b: a / 2, c: a, ox: 500, hts: hts} // storey height = bay width: window tiles fit exactly
	total := hmax*t.c + n*a + t.c/2
	t.oy = (canvas-total)/2 + hmax*t.c + 20
	ox, oy, b, c := t.ox, t.oy, t.b, t.c

	paper, sun := "#1b2a44", "#e8e4d0"
	switch tr.Light {
	case "Morning":
		paper, sun = "#efe8d8", "#e9b44c"
	case "Evening":
		paper, sun = "#eadfd0", "#d9643a"
	case "Noon":
		paper, sun = "#f2efe6", "#f2d27a"
	}
	gridc, base, ink, winc := "#c9b9a0", "#cdbfa5", "#4a3b2e", "#3a3430"
	if night {
		gridc, base, ink, winc = "#4a6a9a", "#2c3e60", "#060c18", "#0d1424"
	}

	// Face tones per material colour: top, left, right.
	tops := make([]string, len(cols))
	lefts := make([]string, len(cols))
	rights := make([]string, len(cols))
	for k, col := range cols {
		if night {
			col = shade(col, -95)
		}
		switch tr.Light {
		case "Morning":
			tops[k], lefts[k], rights[k] = shade(col, 40), col, shade(col, -55)
		case "Evening":
			tops[k], lefts[k], rights[k] = shade(col, 40), shade(col, -55), col
		default:
			tops[k], lefts[k], rights[k] = shade(col, 55), shade(col, -25), shade(col, -45)
		}
	}

	var o strings.Builder
	o.WriteString(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1000 1000" width="1000" height="1000"><defs>`)
	o.WriteString(`<pattern id="g" x="` + strconv.Itoa(ox) + `" y="` + strconv.Itoa(oy) + `" width="` + strconv.Itoa(2*a) +
		`" height="` + strconv.Itoa(a) + `" patternUnits="userSpaceOnUse">`)
	o.WriteString(`<path d="M0 0L` + strconv.Itoa(2*a) + " " + strconv.Itoa(a) + "M0 " + strconv.Itoa(a) + "L" + strconv.Itoa(2*a) +
		` 0" stroke="` + gridc + `"/></pattern>`)

	// Openings live in skewed pattern tiles of one bay x one storey.
	matrix := " 0 1 " + strconv.Itoa(ox) + " " + strconv.Itoa(oy) + `)">`
	if openings != "Blind" {
		var tile strings.Builder
		for k := 0; k < slots; k++ {
			opening(&tile, openings, a, 0, 0, k)
		}
		as := strconv.Itoa(a)
		for k := range cols {
			if !toneUsed[k] {
				continue
			}
			ks := strconv.Itoa(k)
			o.WriteString(`<pattern id="l` + ks + `" width="` + as + `" height="` + as + `" patternUnits="userSpaceOnUse" patternTransform="matrix(1 .5` + matrix)
			o.WriteString(`<rect width="` + as + `" height="` + as + `" fill="` + lefts[k] + `"/><path d="` + tile.String() + `" fill="` + winc + `"/></pattern>`)
			o.WriteString(`<pattern id="r` + ks + `" width="` + as + `" height="` + as + `" patternUnits="userSpaceOnUse" patternTransform="matrix(1 -.5` + matrix)
			o.WriteString(`<rect width="` + as + `" height="` + as + `" fill="` + rights[k] + `"/><path d="` + tile.String() + `" fill="` + winc + `"/></pattern>`)
		}
		if night {
			var litd strings.Builder
			for by := 0; by < 4; by++ {
				for bx := 0; bx < 3; bx++ {
					for k := 0; k < slots; k++ {
						if lit[(by*3+bx)*slots+k] {
							opening(&litd, openings, a, bx*a, by*a, k)
						}
					}
				}
			}
			if litd.Len() == 0 {
				opening(&litd, openings, a, 0, 0, 0)
			}
			dims := `" width="` + strconv.Itoa(3*a) + `" height="` + strconv.Itoa(4*a) + `" patternUnits="userSpaceOnUse" patternTransform="matrix(1 `
			o.WriteString(`<pattern id="nl` + dims + `.5` + matrix + `<path d="` + litd.String() + `" fill="#f2c35a"/></pattern>`)
			o.WriteString(`<pattern id="nr` + dims + `-.5` + matrix + `<path d="` + litd.String() + `" fill="#f2c35a"/></pattern>`)
		}
	}
	o.WriteString(`</defs><rect width="1000" height="1000" fill="` + paper + `"/><rect width="1000" height="1000" fill="url(#g)" opacity=".7"/>`)
	sx := 820
	if tr.Light == "Morning" {
		sx = 180
	}
	o.WriteString(`<circle cx="` + strconv.Itoa(sx) + `" cy="` + strconv.Itoa(sunY) + `" r="` + strconv.Itoa(sunR) + `" fill="` + sun + `" opacity=".9"/>`)

	// Plinth, half a storey thick.
	na, nb, hc := n*a, n*b, c/2
	o.WriteString(`<path d="M` + strconv.Itoa(t.px(0, n)) + " " + strconv.Itoa(t.py(0, n, 0)) + "l" + strconv.Itoa(na) + " " + strconv.Itoa(nb) +
		"v" + strconv.Itoa(hc) + "l" + strconv.Itoa(-na) + " " + strconv.Itoa(-nb) + `z" fill="` + shade(base, -30) + `"/>`)
	o.WriteString(`<path d="M` + strconv.Itoa(t.px(n, 0)) + " " + strconv.Itoa(t.py(n, 0, 0)) + "l" + strconv.Itoa(-na) + " " + strconv.Itoa(nb) +
		"v" + strconv.Itoa(hc) + "l" + strconv.Itoa(na) + " " + strconv.Itoa(-nb) + `z" fill="` + shade(base, -55) + `"/>`)
	o.WriteString(`<path d="M` + strconv.Itoa(t.px(0, 0)) + " " + strconv.Itoa(t.py(0, 0, 0)) + "l" + strconv.Itoa(na) + " " + strconv.Itoa(nb) +
		strconv.Itoa(-na) + " " + strconv.Itoa(nb) + strconv.Itoa(-na) + " " + strconv.Itoa(-nb) + `z" fill="` + base + `"/>`)

	waterFill := "#3d6f8f"
	if night {
		waterFill = "#20406a"
	}
	o.WriteString(`<g stroke="` + ink + `" stroke-opacity=".55">`)
	// Back to front: columns on one diagonal (i + j = s) never overlap, so
	// each diagonal is drawn as a few merged paths, one per fill.
	for s := 0; s <= 2*n-2; s++ {
		i0 := maxInt(0, s-n+1)
		i1 := minInt(s, n-1)

		var wd, rip strings.Builder
		for i := i0; i <= i1; i++ {
			j := s - i
			if !water[i][j] {
				continue
			}
			t.rhomb(&wd, t.px(i, j), t.py(i, j, 0))
			x, y := t.px(i, j+1), t.py(i, j+1, 0)
			rip.WriteString("M" + strconv.Itoa(x+a/2) + " " + strconv.Itoa(y-b/4) + "l" + strconv.Itoa(a/2) + " " + strconv.Itoa(b/4))
			rip.WriteString("M" + strconv.Itoa(x+a/2+a/3) + " " + strconv.Itoa(y-b/2-b/4) + "l" + strconv.Itoa(a/2) + " " + strconv.Itoa(b/4))
		}
		if wd.Len() > 0 {
			pathEl(&o, wd.String(), `fill="`+waterFill+`"`)
			pathEl(&o, rip.String(), `stroke="#a9d0e0" stroke-width="2"`)
		}

		// faces: left then right, one path per tone
		for side := 0; side < 2; side++ {
			for k := 0; k < 6; k++ {
				var d strings.Builder
				for i := i0; i <= i1; i++ {
					j := s - i
					if hts[i][j] == 0 || tone[i][j] != k || !t.hasFace(side, i, j) {
						continue
					}
					t.face(&d, side, i, j)
				}
				if d.Len() == 0 {
					continue
				}
				fill := ""
				switch {
				case openings == "Blind" && side == 0:
					fill = lefts[k]
				case openings == "Blind":
					fill = rights[k]
				case side == 0:
					fill = "url(#l" + strconv.Itoa(k) + ")"
				default:
					fill = "url(#r" + strconv.Itoa(k) + ")"
				}
				pathEl(&o, d.String(), `fill="`+fill+`"`)
			}
		}
		for k := 0; k <= gardenTone; k++ {
			var d strings.Builder
			for i := i0; i <= i1; i++ {
				j := s - i
				h := hts[i][j]
				if h == 0 {
					continue
				}
				key := tone[i][j]
				if roof[i][j] {
					key = gardenTone
				}
				if key == k {
					t.rhomb(&d, t.px(i, j), t.py(i, j, h))
				}
			}
			if d.Len() == 0 {
				continue
			}
			fill := "#7a9a5a"
			if k != gardenTone {
				fill = tops[k]
			}
			pathEl(&o, d.String(), `fill="`+fill+`"`)
		}
		if night && openings != "Blind" {
			for side := 0; side < 2; side++ {
				var d strings.Builder
				for i := i0; i <= i1; i++ {
					j := s - i
					if t.hasFace(side, i, j) {
						t.face(&d, side, i, j)
					}
				}
				if d.Len() == 0 {
					continue
				}
				if side == 0 {
					pathEl(&o, d.String(), `fill="url(#nl)" stroke="none"`)
				} else {
					pathEl(&o, d.String(), `fill="url(#nr)" stroke="none"`)
				}
			}
		}
		for i := i0; i <= i1; i++ {
			j := s - i
			if !tree[i][j] {
				continue
			}
			o.WriteString(`<ellipse cx="` + strconv.Itoa(t.px(i, j)) + `" cy="` + strconv.Itoa(t.py(i, j, hts[i][j])+b-c) +
				`" rx="` + strconv.Itoa(a/6) + `" ry="` + strconv.Itoa(c) + `" fill="#2f4a2a"/>`)
		}
		var sd strings.Builder
		for i := i0; i <= i1; i++ {
			j := s - i
			sc := scaf[i][j]
			if sc == 0 {
				continue
			}
			z0 := hts[i][j]
			corners := [4][2]int{{i, j}, {i + 1, j}, {i + 1, j + 1}, {i, j + 1}}
			for _, cn := range corners {
				sd.WriteString("M" + strconv.Itoa(t.px(cn[0], cn[1])) + " " + strconv.Itoa(t.py(cn[0], cn[1], z0)) + "v" + strconv.Itoa(-sc*c))
			}
			for z := z0 + 1; z <= z0+sc; z++ {
				t.rhomb(&sd, t.px(i, j), t.py(i, j, z))
			}
			sd.WriteString("M" + strconv.Itoa(t.px(i, j+1)) + " " + strconv.Itoa(t.py(i, j+1, z0)) + "l" + strconv.Itoa(a) + " " + strconv.Itoa(b-sc*c))
		}
		if sd.Len() > 0 {
			pathEl(&o, sd.String(), `fill="none" stroke="#b0442c" stroke-width="2" stroke-opacity=".9"`)
		}
	}
	o.WriteString(`</g></svg>`)
	return o.String()
}
