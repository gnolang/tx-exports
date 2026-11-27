// Package cantiere (v2, "Kasaba Dili") is a Sinopia engine: an isometric
// maquette of an imaginary town on a drafting sheet, built from a vocabulary
// of architectural elements — gabled houses, crenellated towers, domes, a
// bell tower, arcades, gardens with cypresses, a square with a fountain and
// building sites in red scaffolding — on six plans (Hill Town, Terraces,
// Courtyard, Coast, Citadel, Ruin), in six materials and four lights. The
// title block of the sheet carries the token number ("TAV. 42").
//
// It is the successor of Cantiere v1 (p/.../art/cantiere/v1, which stays
// untouched): the same FNV-1a + splitmix64 streams, a new town. Three streams:
// seed+"|traits" (the trait draws), seed+"|town" (the 6 x 6 parcel plan, which
// Traits reads too, so Landmark and Tallest come without rendering) and
// seed+"|art" (colours and details). frontend/src/engines/cantierev2.ts is a
// byte-identical TypeScript twin; cantiere_test.gno pins golden vectors that
// the twin asserts too.
//
// The art reads Input.TokenID (the title block). It never reads heights or
// moves, so the engine is not living. Pure integer maths: every division is a
// floor division (fdiv), as in the twin.
package cantiere

import (
	"errors"
	"strconv"
	"strings"

	"gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia4/engine/v2"
)

// TraitTypes in the order Traits returns them.
var traitTypes = []string{"Plan", "Material", "Light", "Scaffolding", "Landmark", "Event", "Tallest", "Rarity"}

// MaxSVGBytes: the largest output over 10,000 default seeds is about 22 KB
// (docs/engines/cantiere-v2.md); the 28 KB budget.
const MaxSVGBytes = 28672

// ParamsSchema is the Studio form. Studio sends JSON.stringify of the values
// in this property order; ValidateParams accepts exactly that or "".
const ParamsSchema = `{"type":"object","properties":{` +
	`"plan":{"type":"string","title":"Plan","enum":["Seeded","Hill Town","Terraces","Courtyard","Coast","Citadel","Ruin"],"default":"Seeded"},` +
	`"material":{"type":"string","title":"Material","enum":["Seeded","Tufa","Brick","Travertine","Painted Plaster","Whitewash","Basalt"],"default":"Seeded"},` +
	`"light":{"type":"string","title":"Light","enum":["Seeded","Morning","Noon","Evening","Night"],"default":"Seeded"}}}`

// DefaultParams is the canonical form of the defaults; it renders exactly
// like "".
const DefaultParams = `{"plan":"Seeded","material":"Seeded","light":"Seeded"}`

// Manifest describes the engine. Author and FeeBps are set by the adapter.
func Manifest() engine.Manifest {
	return engine.Manifest{
		Name:    "Cantiere · Kasaba Dili",
		Version: "2.0.0",
		Description: "Cantiere v2: an isometric maquette of an imaginary town on a drafting sheet, built from a " +
			"vocabulary of architecture — gabled houses, towers, domes, a bell tower, arcades, gardens, a fountain " +
			"square and building sites in red scaffolding — on hill, terrace, courtyard, coast, citadel or ruin plans. " +
			"The title block carries the token number.",
		License:      "CC-BY-NC-4.0",
		ParamsSchema: ParamsSchema,
		TraitTypes:   append([]string{}, traitTypes...),
		Living:       false,
		MaxSVGBytes:  MaxSVGBytes,
		Kind:         engine.KindSVG,
	}
}

// Config is a parsed params string; -1 means drawn from the seed.
type Config struct {
	Plan, Material, Light int
}

// Defaults is the showcase look (params "").
func Defaults() Config { return Config{Plan: -1, Material: -1, Light: -1} }

var errParams = errors.New(`cantierev2: params must be "" or ` +
	`{"plan":<enum>,"material":<enum>,"light":<enum>} in that order, without spaces`)

// ParseParams accepts "" or the canonical JSON Studio produces, nothing else.
func ParseParams(params string) (Config, error) {
	cfg := Defaults()
	if params == "" {
		return cfg, nil
	}
	v, rest, ok := strValue(params, `{"plan":"`)
	if !ok {
		return cfg, errParams
	}
	if cfg.Plan, ok = enumIndex(v, plans); !ok {
		return cfg, errParams
	}
	if v, rest, ok = strValue(rest, `","material":"`); !ok {
		return cfg, errParams
	}
	if cfg.Material, ok = enumIndex(v, materials); !ok {
		return cfg, errParams
	}
	if v, rest, ok = strValue(rest, `","light":"`); !ok {
		return cfg, errParams
	}
	if cfg.Light, ok = enumIndex(v, lights); !ok {
		return cfg, errParams
	}
	if rest != `"}` {
		return cfg, errParams
	}
	return cfg, nil
}

// strValue expects s to start with prefix and returns the text up to the
// next '"' and the remainder starting at that quote.
func strValue(s, prefix string) (string, string, bool) {
	if !strings.HasPrefix(s, prefix) {
		return "", "", false
	}
	s = s[len(prefix):]
	end := strings.IndexByte(s, '"')
	if end < 0 {
		return "", "", false
	}
	return s[:end], s[end:], true
}

func enumIndex(v string, table []option) (int, bool) {
	if v == "Seeded" {
		return -1, true
	}
	for i, o := range table {
		if o.name == v {
			return i, true
		}
	}
	return 0, false
}

// ValidateParams accepts "" (the showcase defaults) and the canonical JSON.
func ValidateParams(params string) error {
	_, err := ParseParams(params)
	return err
}

func mustConfig(params string) Config {
	cfg, err := ParseParams(params)
	if err != nil {
		panic(err)
	}
	return cfg
}

// Traits returns the eight traits of in.Seed in TraitTypes order. It never
// renders: six draws and the 36-parcel town plan.
func Traits(in engine.Input) []engine.Trait {
	t := TraitsOf(in.Seed, mustConfig(in.Params))
	return []engine.Trait{
		{Type: "Plan", Value: t.Plan},
		{Type: "Material", Value: t.Material},
		{Type: "Light", Value: t.Light},
		{Type: "Scaffolding", Value: t.Scaffolding},
		{Type: "Landmark", Value: t.Landmark},
		{Type: "Event", Value: t.Event},
		{Type: "Tallest", Value: t.Tallest},
		{Type: "Rarity", Value: t.Rarity},
	}
}

// Render returns the raw SVG for in.Seed, in.Params and in.TokenID.
func Render(in engine.Input) string { return SVG(in.Seed, mustConfig(in.Params), in.TokenID) }

// ---------------------------------------------------------------------------
// Deterministic randomness: FNV-1a over the seed, then splitmix64.
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

// intn is in [0, n); one draw whenever n > 0.
func (r *rng) intn(n int) int {
	if n <= 0 {
		return 0
	}
	return int(r.next() % uint64(n))
}

// between is in [a, b].
func (r *rng) between(a, b int) int { return a + r.intn(b-a+1) }

// fdiv is floor division (b > 0), as Math.floor(a / b) in the twin.
func fdiv(a, b int) int {
	q := a / b
	if a%b != 0 && a < 0 {
		q--
	}
	return q
}

func absInt(x int) int {
	if x < 0 {
		return -x
	}
	return x
}

func maxInt(a, b int) int {
	if a > b {
		return a
	}
	return b
}

func minInt(a, b int) int {
	if a < b {
		return a
	}
	return b
}

// ---------------------------------------------------------------------------
// Trait tables. A weight is a percent; score feeds the rarity tier.
// ---------------------------------------------------------------------------

type option struct {
	name   string
	weight int
	score  int
}

func pick(r *rng, table []option) int {
	total := 0
	for _, o := range table {
		total += o.weight
	}
	x := r.intn(total)
	for i, o := range table {
		x -= o.weight
		if x < 0 {
			return i
		}
	}
	return len(table) - 1
}

var (
	plans     = []option{{"Hill Town", 28, 0}, {"Terraces", 22, 0}, {"Courtyard", 18, 0}, {"Coast", 16, 1}, {"Citadel", 9, 3}, {"Ruin", 7, 3}}
	materials = []option{{"Tufa", 22, 0}, {"Brick", 20, 0}, {"Travertine", 16, 0}, {"Painted Plaster", 20, 0}, {"Whitewash", 14, 0}, {"Basalt", 8, 2}}
	lights    = []option{{"Morning", 28, 0}, {"Noon", 24, 0}, {"Evening", 30, 0}, {"Night", 18, 2}}
	scaffolds = []option{{"None", 24, 0}, {"Some", 46, 0}, {"Heavy", 30, 1}}
	landmarks = []option{{"Bell Tower", 32, 0}, {"Dome", 30, 0}, {"Tower", 22, 0}, {"Dome and Bell Tower", 10, 1}, {"Twin Towers", 6, 2}}
	events    = []option{{"None", 58, 0}, {"Festival", 12, 2}, {"Fog", 12, 2}, {"Birds", 12, 2}, {"Crane", 6, 3}}
)

const (
	pHill = iota
	pTerraces
	pCourtyard
	pCoast
	pCitadel
	pRuin
)

const (
	mPlaster   = 3
	mWhitewash = 4
	mBasalt    = 5
)

const (
	lMorning = iota
	lNoon
	lEvening
	lNight
)

const (
	sSome  = 1
	sHeavy = 2
)

const (
	eFestival = 1
	eFog      = 2
	eBirds    = 3
	eCrane    = 4
)

// Rarity tiers on the summed score.
var tierCuts = []int{8, 6, 4, 2}
var tierNames = []string{"Mythic", "Legendary", "Rare", "Uncommon"}

// ---------------------------------------------------------------------------
// The town plan (stream seed+"|town"; Traits reads it, never renders).
// ---------------------------------------------------------------------------

const n6 = 6 // cells per side

const (
	kHouse = iota
	kTower
	kDome
	kBell
	kArcade
	kGarden
	kSquare
	kSite
	kWall
	kWater
)

// Weighted kinds of the free parcels: house, tower, arcade, garden, square;
// then site (weight from the Scaffolding trait).
var (
	freeKinds     = []int{kHouse, kTower, kArcade, kGarden, kSquare}
	freeWeights   = []int{50, 5, 9, 15, 6}
	siteWeight    = []int{0, 9, 20}
	landmarkKinds = [][]int{{kBell}, {kDome}, {kTower}, {kDome, kBell}, {kTower, kTower}}
)

type draw struct {
	plan, material, light, scaffold, landmark, event, score int
}

// deriveDraw: the draw order is part of the contract: changing it changes
// every token.
func deriveDraw(seed string, cfg Config) draw {
	r := newRNG(seed + "|traits")
	plan := pick(r, plans)
	material := pick(r, materials)
	light := pick(r, lights)
	scaffold := pick(r, scaffolds)
	landmark := pick(r, landmarks)
	event := pick(r, events)
	// params override after the draws, so the stream never shifts; a pinned trait scores 0
	score := scaffolds[scaffold].score + landmarks[landmark].score + events[event].score
	if cfg.Plan >= 0 {
		plan = cfg.Plan
	} else {
		score += plans[plan].score
	}
	if cfg.Material >= 0 {
		material = cfg.Material
	} else {
		score += materials[material].score
	}
	if cfg.Light >= 0 {
		light = cfg.Light
	} else {
		score += lights[light].score
	}
	return draw{plan, material, light, scaffold, landmark, event, score}
}

type town struct {
	t, kind, st []int // per cell i*6+j: terrain steps 0..3, kind, storeys
	tallest     int
}

func clampInt(v, lo, hi int) int {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}

func terrain(plan, i, j int) int {
	d := absInt(2*i-5) + absInt(2*j-5)
	switch plan {
	case pHill, pRuin:
		return clampInt(fdiv(2*(10-d), 5), 0, 3)
	case pTerraces:
		return clampInt(fdiv(10-i-j, 3), 0, 3)
	case pCoast:
		if i+j >= 8 {
			return 0
		}
		return clampInt(fdiv(9-i-j, 3), 1, 3)
	case pCitadel:
		if d <= 4 {
			return 2
		}
		return 1
	}
	return 1
}

func storeys(r *rng, k int) int {
	switch k {
	case kHouse:
		return r.between(1, 4)
	case kTower:
		return r.between(4, 7)
	case kDome:
		return r.between(2, 3)
	case kBell:
		return r.between(5, 7)
	case kArcade:
		return r.between(2, 3)
	case kSite:
		return r.between(1, 2)
	}
	return 0
}

// highest returns one of the free cells (kind -1) of among on the highest
// ground, drawn from r; -1 if none is free.
func highest(r *rng, t, kind, among []int) int {
	best := -1
	var list []int
	for _, c := range among {
		if kind[c] != -1 {
			continue
		}
		if t[c] > best {
			best = t[c]
			list = list[:0]
		}
		if t[c] == best {
			list = append(list, c)
		}
	}
	if len(list) == 0 {
		return -1
	}
	return list[r.intn(len(list))]
}

func buildTown(seed string, d draw) town {
	r := newRNG(seed + "|town")
	t := make([]int, 0, n6*n6)
	kind := make([]int, 0, n6*n6)
	st := make([]int, 0, n6*n6)
	all := make([]int, 0, n6*n6)
	// fixed parcels: the sea, the courtyard, the citadel's walls and corner towers
	for i := 0; i < n6; i++ {
		for j := 0; j < n6; j++ {
			t = append(t, terrain(d.plan, i, j))
			all = append(all, i*n6+j)
			edgeI, edgeJ := i == 0 || i == n6-1, j == 0 || j == n6-1
			k, s := -1, 0
			if d.plan == pCoast && i+j >= 8 {
				k = kWater
			} else if d.plan == pCourtyard && i >= 2 && i <= 3 && j >= 2 && j <= 3 {
				k = kGarden
				if i == j {
					k = kSquare
				}
			} else if d.plan == pCitadel && (edgeI || edgeJ) {
				k, s = kWall, 2
				if edgeI && edgeJ {
					k, s = kTower, 4
				}
			}
			kind = append(kind, k)
			st = append(st, s)
		}
	}
	// the landmark on the highest free ground; a second one beside it
	lk := landmarkKinds[d.landmark]
	first := highest(r, t, kind, all)
	kind[first] = lk[0]
	st[first] = storeys(r, lk[0])
	if len(lk) > 1 {
		i, j := fdiv(first, n6), first%n6
		var nb []int
		if i > 0 {
			nb = append(nb, first-n6)
		}
		if j > 0 {
			nb = append(nb, first-1)
		}
		if i < n6-1 {
			nb = append(nb, first+n6)
		}
		if j < n6-1 {
			nb = append(nb, first+1)
		}
		second := highest(r, t, kind, nb)
		if second < 0 {
			second = highest(r, t, kind, all)
		}
		kind[second] = lk[1]
		if lk[1] == kTower {
			st[second] = st[first] // twin towers match
		} else {
			st[second] = storeys(r, lk[1])
		}
	}
	// the free parcels
	sw := siteWeight[d.scaffold]
	towers, sites := 0, 0
	for c := 0; c < n6*n6; c++ {
		if kind[c] != -1 {
			continue
		}
		x := r.intn(85 + sw)
		k := kSite
		for q := 0; q < len(freeKinds); q++ {
			x -= freeWeights[q]
			if x < 0 {
				k = freeKinds[q]
				break
			}
		}
		if k == kTower {
			if towers >= 2 {
				k = kHouse
			}
			towers++
		}
		if k == kSite {
			sites++
		}
		kind[c] = k
		st[c] = storeys(r, k)
	}
	// the Scaffolding trait is always visible: Some has a site, Heavy three
	// (front-most houses become sites first)
	need := 0
	if d.scaffold == sHeavy {
		need = 3
	} else if d.scaffold == sSome {
		need = 1
	}
	for s := 2*n6 - 2; s >= 0 && sites < need; s-- {
		for i := minInt(s, n6-1); i >= 0 && s-i < n6 && sites < need; i-- {
			c := i*n6 + s - i
			if kind[c] == kHouse {
				kind[c] = kSite
				st[c] = r.between(1, 2)
				sites++
			}
		}
	}
	// a ruin keeps a part of its storeys
	tallest := 0
	for c := 0; c < n6*n6; c++ {
		if d.plan == pRuin && st[c] > 1 {
			st[c] = r.between(1, st[c])
		}
		if st[c] > tallest {
			tallest = st[c]
		}
	}
	return town{t: t, kind: kind, st: st, tallest: tallest}
}

// TraitSet is the decoded traits of a seed; the SVG and the trait list both
// read it, so picture and metadata cannot disagree.
type TraitSet struct {
	Plan, Material, Light, Scaffolding, Landmark, Event, Tallest, Rarity string
	Score                                                                int
}

func traitsOf(d draw, tw town) TraitSet {
	rarity := "Common"
	for i, cut := range tierCuts {
		if d.score >= cut {
			rarity = tierNames[i]
			break
		}
	}
	tallest := strconv.Itoa(tw.tallest) + " storeys"
	if tw.tallest == 1 {
		tallest = "1 storey"
	}
	return TraitSet{
		Plan: plans[d.plan].name, Material: materials[d.material].name, Light: lights[d.light].name,
		Scaffolding: scaffolds[d.scaffold].name, Landmark: landmarks[d.landmark].name, Event: events[d.event].name,
		Tallest: tallest, Rarity: rarity, Score: d.score,
	}
}

// TraitsOf returns the decoded traits of a seed under cfg.
func TraitsOf(seed string, cfg Config) TraitSet {
	d := deriveDraw(seed, cfg)
	return traitsOf(d, buildTown(seed, d))
}

// TavNumber is the sheet number in the title block: TokenID read as a
// decimal, modulo 100,000 (core's supply cap is 10,000). Anything but ASCII
// digits is 0, which prints "PROVA" (a proof; Studio renders use "0").
func TavNumber(tokenID string) int {
	v := 0
	for i := 0; i < len(tokenID); i++ {
		c := tokenID[i]
		if c < '0' || c > '9' {
			return 0
		}
		v = (v*10 + int(c-'0')) % 100000
	}
	return v
}

// ---------------------------------------------------------------------------
// Colour
// ---------------------------------------------------------------------------

const hexDigits = "0123456789abcdef"

func hx(c string, k int) int {
	return strings.IndexByte(hexDigits, c[k])*16 + strings.IndexByte(hexDigits, c[k+1])
}

func hex2(b *strings.Builder, v int) {
	b.WriteByte(hexDigits[v>>4])
	b.WriteByte(hexDigits[v&15])
}

// shade scales each channel by f/100, rounded, capped at 255.
func shade(c string, f int) string {
	var b strings.Builder
	b.WriteByte('#')
	for k := 1; k < 7; k += 2 {
		hex2(&b, minInt(255, fdiv(hx(c, k)*f+50, 100)))
	}
	return b.String()
}

// mix goes t % of the way from a to b, rounded.
func mix(a, c string, t int) string {
	var b strings.Builder
	b.WriteByte('#')
	for k := 1; k < 7; k += 2 {
		hex2(&b, fdiv(hx(a, k)*(100-t)+hx(c, k)*t+50, 100))
	}
	return b.String()
}

// Light: left / right / top face factors.
var lightFactors = [][]int{{100, 70, 114}, {92, 80, 120}, {72, 100, 108}, {46, 36, 58}}

var (
	skies    = []string{"#f6e3c8", "#e7eef0", "#f2c49a", "#141a28"}
	pastels  = []string{"#e8b48a", "#e6cf8f", "#d98b74", "#c9d1b0", "#efd9b8", "#d4a5a0", "#bfc9cf"}
	wallCols = []string{"#cdbf9a", "#b5623f", "#e6dcc4", "", "#f2efe8", "#6e6b66"}
	roofCols = []string{"#b5523a", "#a9492f", "#c0603f"}
	lanterns = []string{"#e8473a", "#f2c14e", "#3c8dbc", "#7bc043"}
)

type palette struct {
	light int
	memo  map[string]string
}

func (p *palette) tint(c string) string {
	switch p.light {
	case lEvening:
		return mix(c, "#e88a4a", 14)
	case lNight:
		return mix(c, "#1e2a48", 35)
	}
	return c
}

// face: 0 left, 1 right, 2 top.
func (p *palette) face(c string, face int) string {
	key := c + string(rune('0'+face))
	if v, ok := p.memo[key]; ok {
		return v
	}
	v := p.tint(shade(c, lightFactors[p.light][face]))
	p.memo[key] = v
	return v
}

// ---------------------------------------------------------------------------
// Geometry: isometric cells of 52 x 26 px, storeys of 26 px; positions in
// 1/20 cell.
// ---------------------------------------------------------------------------

const (
	canvas = 704
	ox     = 364
	oy     = 338
	storey = 26
	cell   = 20
)

func px(u, v int) int    { return ox + fdiv((u-v)*13, 5) }
func py(u, v, z int) int { return oy + fdiv((u+v)*13, 10) - z }

func itoa(n int) string { return strconv.Itoa(n) }

// sp writes n with a leading space unless it is negative.
func sp(n int) string {
	if n < 0 {
		return strconv.Itoa(n)
	}
	return " " + strconv.Itoa(n)
}

// poly is "Mx y" then relative "l" moves over the flat point list; zero
// moves are dropped.
func poly(p []int, close bool) string {
	var b strings.Builder
	x, y := p[0], p[1]
	b.WriteString("M" + itoa(x) + sp(y))
	first := true
	for k := 2; k < len(p); k += 2 {
		dx, dy := p[k]-x, p[k+1]-y
		if dx == 0 && dy == 0 {
			continue
		}
		if first {
			b.WriteString("l" + itoa(dx) + sp(dy))
		} else {
			b.WriteString(sp(dx) + sp(dy))
		}
		first = false
		x, y = p[k], p[k+1]
	}
	if close {
		b.WriteString("z")
	}
	return b.String()
}

// pts projects (u, v, z) triples to a flat point list.
func pts(uvz ...int) []int {
	out := make([]int, 0, len(uvz)/3*2)
	for k := 0; k < len(uvz); k += 3 {
		out = append(out, px(uvz[k], uvz[k+1]), py(uvz[k], uvz[k+1], uvz[k+2]))
	}
	return out
}

// Layers of one diagonal. Cells on a diagonal never overlap, so each layer
// merges the paths of all its cells by attributes; a cell's own elements keep
// their order through the layer numbers.
const (
	lyTL = iota
	lyTR
	lyTT
	lyGround
	lyWL
	lyWR
	lyArc
	lyUL
	lyUR
	lyTop
	lyDetail
	lyR1
	lyR2
	lyR3
	lyEdge
	lyAir
	nLayers
)

type entry struct {
	key string
	val strings.Builder
	raw bool
}

type diagonal struct {
	layers [nLayers][]*entry
}

func (g *diagonal) path(l int, attrs, d string) {
	for _, e := range g.layers[l] {
		if !e.raw && e.key == attrs {
			e.val.WriteString(d)
			return
		}
	}
	e := &entry{key: attrs}
	e.val.WriteString(d)
	g.layers[l] = append(g.layers[l], e)
}

func (g *diagonal) element(l int, s string) {
	e := &entry{raw: true}
	e.val.WriteString(s)
	g.layers[l] = append(g.layers[l], e)
}

func (g *diagonal) flush(o *strings.Builder) {
	for l := 0; l < nLayers; l++ {
		for _, e := range g.layers[l] {
			if e.raw {
				o.WriteString(e.val.String())
			} else {
				o.WriteString(`<path d="` + e.val.String() + `" ` + e.key + `/>`)
			}
		}
	}
}

func fill(c string) string { return `fill="` + c + `"` }

// box writes the left (v = v1) and right (u = u1) faces of a block whose
// faces start at zl / zr.
func box(g *diagonal, ll, lr, u0, v0, u1, v1, z1, zl, zr int, fl, fr string) {
	if z1 > zl {
		g.path(ll, fl, poly(pts(u0, v1, z1, u1, v1, z1, u1, v1, zl, u0, v1, zl), true))
	}
	if z1 > zr {
		g.path(lr, fr, poly(pts(u1, v0, z1, u1, v1, z1, u1, v1, zr, u1, v0, zr), true))
	}
}

func top(g *diagonal, l, u0, v0, u1, v1, z int, f string) {
	g.path(l, f, poly(pts(u0, v0, z, u1, v0, z, u1, v1, z, u0, v1, z), true))
}

// opening is an arched opening on the left (side 0, along u from u0) or right
// (side 1, along -v from v1) face, from a to b, h px high above z.
func opening(side, u0, v1, a, b, z, h int) string {
	var p []int
	if side == 0 {
		p = pts(u0+a, v1, z, u0+b, v1, z)
	} else {
		p = pts(u0, v1-a, z, u0, v1-b, z)
	}
	half := fdiv(absInt(p[2]-p[0]), 2)
	return "M" + itoa(p[0]) + sp(p[1]) + "v" + itoa(-h) + "a" + itoa(half) + " " + itoa(half) + " 0 0 1 " +
		itoa(p[2]-p[0]) + sp(p[3]-p[1]) + "v" + itoa(h) + "z"
}

// ---------------------------------------------------------------------------
// Render
// ---------------------------------------------------------------------------

// SVG renders the artwork for a seed, a config and a token id.
func SVG(seed string, cfg Config, tokenID string) string {
	d := deriveDraw(seed, cfg)
	tw := buildTown(seed, d)
	tr := traitsOf(d, tw)
	r := newRNG(seed + "|art") // separate stream: trait draws never shift the art
	pal := &palette{light: d.light, memo: map[string]string{}}
	night := d.light == lNight
	ruin := d.plan == pRuin
	plaster := d.material == mPlaster
	stone := "#b9ab8e"
	if d.material == mBasalt {
		stone = "#7a756c"
	}
	// wall colours: the material's, or under painted plaster the seven pastels and tufa for civic buildings
	walls := []string{wallCols[d.material]}
	if plaster {
		walls = append(append([]string{}, pastels...), wallCols[0])
	}
	arched := d.material <= 2 // tufa, brick, travertine: arched windows
	tid := TavNumber(tokenID)

	// night: which of the 16 windows of a 2 x 4 bay tile are lit (a ruin stays dark)
	var lit []bool
	nlit := 0
	if night && !ruin {
		for k := 0; k < 16; k++ {
			lit = append(lit, r.intn(100) < 40)
			if lit[k] {
				nlit++
			}
		}
		for k := 1; nlit < 3; k += 5 {
			if !lit[k] {
				lit[k] = true
				nlit++
			}
		}
	}
	var stars strings.Builder
	if night {
		for k := 0; k < 28; k++ {
			x := r.between(16, 688)
			stars.WriteString("M" + itoa(x) + " " + itoa(r.between(12, 300)) + "h0")
		}
	}
	// the crane stands at the front corner of a site, else a garden or square
	crane := -1
	if d.event == eCrane {
		for pass := 0; pass < 3 && crane < 0; pass++ {
			for c := n6*n6 - 1; c >= 0; c-- {
				k := tw.kind[c]
				if (pass == 0 && k == kSite) || (pass == 1 && (k == kGarden || k == kSquare)) || (pass == 2 && k != kWater) {
					crane = c
					break
				}
			}
		}
	}

	usedWin := make([]bool, len(walls))
	usedArc := false
	win := func(ci, side int) string {
		usedWin[ci] = true
		if side == 0 {
			return `fill="url(#w` + itoa(ci) + `l)"`
		}
		return `fill="url(#w` + itoa(ci) + `r)"`
	}
	var tops []int // x, y of roof tops in drawing order (festival)
	var body strings.Builder
	h := storey

	for s := 0; s <= 2*n6-2; s++ {
		g := &diagonal{}
		for i := maxInt(0, s-n6+1); i <= minInt(s, n6-1); i++ {
			j := s - i
			c := i*n6 + j
			k := tw.kind[c]
			u0, v0 := i*cell, j*cell
			u1, v1 := u0+cell, v0+cell
			zt := tw.t[c] * h
			nl, nr := 0, 0
			if j+1 < n6 {
				nl = tw.t[c+1] * h
			}
			if i+1 < n6 {
				nr = tw.t[c+n6] * h
			}
			cu, cv := u0+10, v0+10
			if k == kWater {
				wc := "#6fa2bf"
				if night {
					wc = "#1d3550"
				}
				top(g, lyTT, u0, v0, u1, v1, 0, fill(pal.tint(wc)))
				x, y := px(cu, cv), py(cu, cv, 0)
				g.path(lyGround, `fill="none" stroke="#fff" stroke-opacity=".5"`,
					"M"+itoa(x-16)+" "+itoa(y-3)+"q4-3 8 0t8 0M"+itoa(x-4)+" "+itoa(y+5)+"q4-3 8 0t8 0")
				if r.intn(100) < 30 {
					g.path(lyDetail, fill(pal.tint("#7a4a2a")),
						"M"+itoa(x-10)+" "+itoa(y-2)+"h20l-4 5h-12zM"+itoa(x)+" "+itoa(y-3)+"v-16l9 14z")
				}
				continue
			}
			topc := pal.face(stone, 2)
			if k == kGarden {
				gc := "#8aa05a"
				if night {
					gc = "#3c4a32"
				}
				topc = pal.tint(gc)
			} else if k == kSquare {
				topc = pal.face("#d9cfba", 2)
			}
			box(g, lyTL, lyTR, u0, v0, u1, v1, zt, nl, nr, fill(pal.face(stone, 0)), fill(pal.face(stone, 1)))
			top(g, lyTT, u0, v0, u1, v1, zt, fill(topc))
			if crane == c {
				q := pts(u1-3, v1-3, zt)
				cx, cy := q[0], q[1]
				tp := maxInt(40, cy-260)
				dir := 1
				if cx > 500 {
					dir = -1
				}
				var p strings.Builder
				p.WriteString("M" + itoa(cx-4) + " " + itoa(cy) + "V" + itoa(tp) + "M" + itoa(cx+4) + " " + itoa(cy) + "V" + itoa(tp))
				for y := cy; y > tp+12; y -= 12 {
					p.WriteString("M" + itoa(cx-4) + " " + itoa(y) + "l8-12")
				}
				p.WriteString("M" + itoa(cx-40*dir) + " " + itoa(tp) + "h" + itoa(170*dir) +
					"M" + itoa(cx) + " " + itoa(tp-18) + "L" + itoa(cx-40*dir) + " " + itoa(tp) +
					"M" + itoa(cx) + " " + itoa(tp-18) + "L" + itoa(cx+130*dir) + " " + itoa(tp) +
					"M" + itoa(cx+110*dir) + " " + itoa(tp) + "v60")
				g.element(lyAir, `<path d="`+p.String()+`" fill="none" stroke="`+pal.tint("#b8402a")+`" stroke-width="2.5"/>`+
					`<path d="M`+itoa(cx+110*dir-6)+" "+itoa(tp+60)+"h12v8h-12zM"+itoa(cx-40*dir-6*dir)+" "+itoa(tp)+
					"h"+itoa(12*dir)+"v10h"+itoa(-12*dir)+`z" `+fill(pal.tint("#5a4a3a"))+`/>`)
			}

			if k == kGarden {
				n := r.between(1, 3)
				var tree []int
				for q := 0; q < n; q++ {
					tu := u0 + 4 + r.intn(12)
					tv := v0 + 4 + r.intn(12)
					cyp := 0
					if r.intn(100) < 60 {
						cyp = 1
					}
					tree = append(tree, tu, tv, cyp)
				}
				// back to front
				for a := 0; a < n; a++ {
					for b := a + 1; b < n; b++ {
						if tree[3*b]+tree[3*b+1] < tree[3*a]+tree[3*a+1] {
							for q := 0; q < 3; q++ {
								tree[3*a+q], tree[3*b+q] = tree[3*b+q], tree[3*a+q]
							}
						}
					}
				}
				for q := 0; q < n; q++ {
					x, y := px(tree[3*q], tree[3*q+1]), py(tree[3*q], tree[3*q+1], zt)
					if tree[3*q+2] == 1 {
						g.element(lyGround, `<path d="M`+itoa(x)+" "+itoa(y-34)+`c4 6 7 18 5 31q-5 4-10 0c-2-13 1-25 5-31z" `+fill(pal.tint("#3b5234"))+`/>`+
							`<path d="M`+itoa(x)+" "+itoa(y-34)+`c4 6 7 18 5 31q-2 2-5 2z" `+fill(pal.tint("#28391f"))+`/>`)
					} else {
						g.element(lyGround, `<path d="M`+itoa(x)+" "+itoa(y)+`v-8" stroke="`+pal.tint("#5a3e28")+`" stroke-width="2"/>`+
							`<path d="M`+itoa(x-9)+" "+itoa(y-13)+`a9 9 0 1 0 18 0a9 9 0 1 0-18 0z" `+fill(pal.tint("#5d7a3c"))+`/>`)
					}
				}
				continue
			}
			if k == kSquare {
				x, y := px(cu, cv), py(cu, cv, zt)
				g.element(lyGround, `<ellipse cx="`+itoa(x)+`" cy="`+itoa(y)+`" rx="17" ry="8" `+fill(pal.face("#b7ab94", 2))+`/>`+
					`<ellipse cx="`+itoa(x)+`" cy="`+itoa(y-1)+`" rx="13" ry="6" `+fill(pal.tint("#6fa2bf"))+`/>`+
					`<path d="M`+itoa(x)+" "+itoa(y-2)+`v-12" stroke="`+pal.tint("#cfe3ee")+`" stroke-width="2"/>`)
				continue
			}

			// painted plaster: each house its own colour; towers and walls stay in tufa
			civic := k == kTower || k == kWall || k == kBell
			ci := 0
			if plaster {
				if civic {
					ci = len(pastels)
				} else {
					ci = r.intn(len(pastels))
				}
			}
			col := walls[ci]
			fl, fr, ft := fill(pal.face(col, 0)), fill(pal.face(col, 1)), fill(pal.face(col, 2))
			z1 := zt + tw.st[c]*h

			if k == kBell {
				box(g, lyWL, lyWR, u0+4, v0+4, u1-4, v1-4, z1, zt, zt, fl, fr)
				top(g, lyTop, u0+4, v0+4, u1-4, v1-4, z1, ft)
				a, b := pts(u0+7, v1-4, z1-6), pts(u1-4, v1-7, z1-6)
				g.path(lyDetail, fill(pal.tint("#2c2620")),
					"M"+itoa(a[0])+" "+itoa(a[1])+"v-10l6 3v10zM"+itoa(b[0])+" "+itoa(b[1])+"v-10l-6 3v10z")
				x, y := px(cu, cv), py(cu, cv, z1)-34
				rc := "#b5523a"
				if d.material == mBasalt {
					rc = "#5a5650"
				}
				g.path(lyR1, fill(pal.face(rc, 0)), poly(append(pts(u0+4, v1-4, z1, u1-4, v1-4, z1), x, y), true))
				g.path(lyR2, fill(pal.face(rc, 1)), poly(append(pts(u1-4, v1-4, z1, u1-4, v0+4, z1), x, y), true))
				g.path(lyAir, `stroke="`+pal.tint("#3a332c")+`" stroke-width="1.5"`,
					"M"+itoa(x)+" "+itoa(y)+"v-9M"+itoa(x-3)+" "+itoa(y-6)+"h6")
				tops = append(tops, x, y)
				continue
			}
			if k == kSite {
				box(g, lyWL, lyWR, u0, v0, u1, v1, z1, zt, zt, win(ci, 0), win(ci, 1))
				top(g, lyTop, u0, v0, u1, v1, z1, fill(pal.face("#c9bfae", 2)))
				sh := r.between(2, 4) * h
				var p strings.Builder
				corners := []int{u0, v0, u1, v0, u1, v1, u0, v1}
				for q := 0; q < 8; q += 2 {
					pp := pts(corners[q], corners[q+1], z1)
					p.WriteString("M" + itoa(pp[0]) + " " + itoa(pp[1]) + "v" + itoa(-sh))
				}
				for z := z1 + h; z <= z1+sh; z += h {
					p.WriteString(poly(pts(u0, v1, z, u1, v1, z, u1, v0, z, u0, v0, z), true))
				}
				p.WriteString(poly(pts(u0, v1, z1, u1, v1, z1+sh), false) + poly(pts(u1, v0, z1, u1, v1, z1+sh), false))
				g.path(lyAir, `fill="none" stroke="`+pal.tint("#b5452f")+`" stroke-width="1.3"`, p.String())
				// a plank on the first lift
				g.path(lyAir, `stroke="`+pal.tint("#8a6a3a")+`" stroke-width="3"`, poly(pts(u0+2, v1, z1+h, u1, v1, z1+h), false))
				tops = append(tops, px(cu, cv), py(cu, cv, z1+sh))
				continue
			}
			if k == kArcade {
				box(g, lyWL, lyWR, u0, v0, u1, v1, zt+h, zt, zt, fl, fr)
				g.path(lyArc, `fill="url(#al)"`, poly(pts(u0, v1, zt+h, u1, v1, zt+h, u1, v1, zt, u0, v1, zt), true))
				g.path(lyArc, `fill="url(#ar)"`, poly(pts(u1, v0, zt+h, u1, v1, zt+h, u1, v1, zt, u1, v0, zt), true))
				usedArc = true
				box(g, lyUL, lyUR, u0, v0, u1, v1, z1, zt+h, zt+h, win(ci, 0), win(ci, 1))
				top(g, lyTop, u0, v0, u1, v1, z1, ft)
				g.path(lyEdge, `fill="none" stroke="`+shade(pal.face(col, 2), 60)+`" stroke-width="1.2"`,
					poly(pts(u0, v1, z1+5, u1, v1, z1+5, u1, v0, z1+5), false))
				tops = append(tops, px(cu, cv), py(cu, cv, z1))
				continue
			}
			if k == kHouse && ruin {
				// a roofless shell: broken wall tops, the floor inside in shadow
				h1 := z1 - fdiv(r.intn(3)*h, 2)
				h2 := z1 - fdiv(r.intn(3)*h, 2)
				lo := maxInt(zt+fdiv(h, 2), minInt(h1, h2)-fdiv(h, 2))
				top(g, lyGround, u0, v0, u1, v1, lo, fill(pal.face("#5b4c3e", 2)))
				wl, wr := maxInt(zt+6, h1), maxInt(zt+6, h2)
				g.path(lyWL, win(ci, 0), poly(pts(u0, v1, zt, u0, v1, wl, u0+7, v1, wl, u0+7, v1, z1, u0+13, v1, z1, u0+13, v1, wr, u1, v1, wr, u1, v1, zt), true))
				g.path(lyWR, win(ci, 1), poly(pts(u1, v1, zt, u1, v1, wr, u1, v1-8, wr, u1, v1-8, wl, u1, v0, wl, u1, v0, zt), true))
			} else {
				if k == kWall {
					box(g, lyWL, lyWR, u0, v0, u1, v1, z1, zt, zt, fl, fr)
				} else {
					box(g, lyWL, lyWR, u0, v0, u1, v1, z1, zt, zt, win(ci, 0), win(ci, 1))
				}
				if k != kHouse {
					top(g, lyTop, u0, v0, u1, v1, z1, ft)
				}
			}
			switch k {
			case kHouse:
				// a door on the front face that is not hidden by higher ground
				side := r.intn(2)
				if (side == 0 && zt >= nl) || (side == 1 && zt >= nr) {
					du := u0
					if side == 1 {
						du = u1
					}
					g.path(lyDetail, fill(pal.tint("#4a3426")), opening(side, du, v1, 8, 12, zt, 9))
				}
				if !ruin {
					rc := "#5a5650"
					if d.material != mBasalt {
						rc = roofCols[r.intn(3)]
					}
					zr := z1 + 19
					if r.intn(2) == 0 {
						ridge := pts(u0, cv, zr, u1, cv, zr)
						g.path(lyR1, fill(pal.face(rc, 2)), poly(append(pts(u0, v0, z1, u1, v0, z1), ridge[2], ridge[3], ridge[0], ridge[1]), true))
						g.path(lyR2, fr, poly(append(pts(u1, v0, z1, u1, v1, z1), ridge[2], ridge[3]), true))
						g.path(lyR3, fill(pal.face(rc, 0)), poly(append(pts(u0, v1, z1, u1, v1, z1), ridge[2], ridge[3], ridge[0], ridge[1]), true))
					} else {
						ridge := pts(cu, v0, zr, cu, v1, zr)
						g.path(lyR1, fill(pal.face(rc, 2)), poly(append(pts(u0, v0, z1, u0, v1, z1), ridge[2], ridge[3], ridge[0], ridge[1]), true))
						g.path(lyR2, fl, poly(append(pts(u0, v1, z1, u1, v1, z1), ridge[2], ridge[3]), true))
						g.path(lyR3, fill(pal.face(rc, 1)), poly(append(pts(u1, v0, z1, u1, v1, z1), ridge[2], ridge[3], ridge[0], ridge[1]), true))
					}
					tops = append(tops, px(cu, cv), py(cu, cv, zr))
				} else {
					tops = append(tops, px(cu, cv), py(cu, cv, z1))
				}
			case kTower, kWall:
				zc := z1 + 4
				cl := `fill="none" stroke="` + pal.face(col, 0) + `" stroke-width="8" stroke-dasharray="6 5"`
				cr := `fill="none" stroke="` + pal.face(col, 1) + `" stroke-width="8" stroke-dasharray="6 5"`
				g.path(lyDetail, cl, poly(pts(u0, v0, zc, u1, v0, zc), false))
				g.path(lyDetail, cr, poly(pts(u0, v0, zc, u0, v1, zc), false))
				g.path(lyEdge, cl, poly(pts(u0, v1, zc, u1, v1, zc), false))
				g.path(lyEdge, cr, poly(pts(u1, v1, zc, u1, v0, zc), false))
				// the citadel gate, in the middle of the two front walls
				if k == kWall && i == n6-1 && j == 2 {
					g.path(lyDetail, fill(pal.tint("#2c2620")), opening(1, u1, v1, 2, 18, zt, 22))
				}
				if k == kWall && j == n6-1 && i == 2 {
					g.path(lyDetail, fill(pal.tint("#2c2620")), opening(0, u0, v1, 2, 18, zt, 22))
				}
				tops = append(tops, px(cu, cv), py(cu, cv, z1))
			case kDome:
				x, y := px(cu, cv), py(cu, cv, z1)
				dc := "#c8a04a"
				if gd := r.intn(8); gd < 4 {
					dc = "#8d9aa0"
				} else if gd < 7 {
					dc = "#6f9c8a"
				}
				dome := "M" + itoa(x-34) + " " + itoa(y) + "a34 34 0 0 1 68 0a34 15 0 0 1-68 0z"
				g.path(lyR1, fill(pal.face(dc, 2)), dome)
				g.path(lyR2, `fill="url(#dm)"`, dome)
				g.path(lyR3, fill(pal.face(col, 0))+` stroke="`+pal.face(dc, 0)+`"`,
					"M"+itoa(x-3)+" "+itoa(y-30)+"h6v-8h-6zM"+itoa(x)+" "+itoa(y-46)+"v8")
				tops = append(tops, x, y-30)
			}
		}
		g.flush(&body)
	}

	// --- assemble ---
	winD := "#3a332c"
	if night {
		winD = "#2a2c38"
	} else if d.material == mWhitewash {
		winD = "#3c6fa8"
	}
	var wd, wlit, sills strings.Builder
	for k := 0; k < 16; k++ {
		x, y := 8+26*(k%4), 8+26*(k>>2)
		w := "M" + itoa(x) + " " + itoa(y) + "h9v12h-9z"
		if arched {
			w = "M" + itoa(x) + " " + itoa(y+12) + "v-7a4.5 4.5 0 0 1 9 0v7z"
		}
		if len(lit) > 0 && lit[k] {
			wlit.WriteString(w)
		} else {
			wd.WriteString(w)
		}
		sills.WriteString("M" + itoa(x-1) + " " + itoa(y+13) + "h11")
	}
	var o strings.Builder
	W := itoa(canvas)
	o.WriteString(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ` + W + " " + W + `" width="` + W + `" height="` + W + `">`)
	sheet := "Prova"
	if tid > 0 {
		sheet = "Tav. " + itoa(tid)
	}
	o.WriteString(`<title>Cantiere · Kasaba Dili</title><desc>` + tr.Plan + " in " + strings.ToLower(tr.Material) + ", " +
		strings.ToLower(tr.Light) + " light. Landmark: " + strings.ToLower(tr.Landmark) + ". Event: " +
		strings.ToLower(tr.Event) + ". " + sheet + ".</desc>")
	grid, skyLow, paper := "#d9cfbb", "#f1ead9", "#f1ead9"
	if night {
		grid, skyLow, paper = "#3b4766", "#1f2738", "#1b2232"
	}
	o.WriteString(`<defs><pattern id="gr" width="52" height="26" patternUnits="userSpaceOnUse"><path d="M0 0l52 26M0 26l52-26" stroke="` + grid + `" stroke-width=".7"/></pattern>`)
	o.WriteString(`<linearGradient id="sky" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="` + skies[d.light] + `"/><stop offset="1" stop-color="` + skyLow + `" stop-opacity="0"/></linearGradient>`)
	o.WriteString(`<radialGradient id="dm" cx=".35" cy=".3" r=".8"><stop offset="0" stop-color="#fff" stop-opacity=".55"/><stop offset="1" stop-color="#000" stop-opacity=".25"/></radialGradient>`)
	o.WriteString(`<filter id="sh" x="-.2" y="-.3" width="1.4" height="1.6"><feGaussianBlur stdDeviation="9"/></filter>`)
	o.WriteString(`<path id="wd" d="` + wd.String() + `" fill="` + winD + `"/>`)
	if wlit.Len() > 0 {
		o.WriteString(`<path id="wl" d="` + wlit.String() + `" fill="#ffd36a"/>`)
	} else if !night {
		o.WriteString(`<path id="wl" d="` + sills.String() + `" stroke="#fff" stroke-opacity=".45"/>`)
	}
	mtx := []string{"1 .5", "1 -.5"}
	lr := []string{"l", "r"}
	for ci := 0; ci < len(walls); ci++ {
		if !usedWin[ci] {
			continue
		}
		for side := 0; side < 2; side++ {
			o.WriteString(`<pattern id="w` + itoa(ci) + lr[side] + `" width="104" height="104" patternUnits="userSpaceOnUse" patternTransform="matrix(` + mtx[side] + ` 0 1 0 0)">` +
				`<rect width="104" height="104" fill="` + pal.face(walls[ci], side) + `"/><use href="#wd"/>`)
			if !night || wlit.Len() > 0 {
				o.WriteString(`<use href="#wl"/>`)
			}
			o.WriteString(`</pattern>`)
		}
	}
	if usedArc {
		for side := 0; side < 2; side++ {
			o.WriteString(`<pattern id="a` + lr[side] + `" width="26" height="26" patternUnits="userSpaceOnUse" patternTransform="matrix(` + mtx[side] + ` 0 1 0 0)">` +
				`<path d="M6 26v-11a7 7 0 0 1 14 0v11z" fill="#2c2620" fill-opacity=".75"/></pattern>`)
		}
	}
	if d.event == eFog {
		fogc := "#fff"
		if night {
			fogc = "#aab4ca"
		}
		o.WriteString(`<linearGradient id="fg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" stop-opacity="0"/>` +
			`<stop offset=".7" stop-color="` + fogc + `" stop-opacity=".75"/><stop offset="1" stop-color="#fff" stop-opacity=".2"/></linearGradient>`)
	}
	o.WriteString(`</defs><rect width="` + W + `" height="` + W + `" fill="` + paper + `"/><rect width="` + W + `" height="` + W + `" fill="url(#gr)"/><rect width="` + W + `" height="360" fill="url(#sky)"/>`)
	if night {
		o.WriteString(`<path d="` + stars.String() + `" stroke="#e9e4cf" stroke-width="2" stroke-linecap="round" opacity=".7"/><path d="M588 74a22 22 0 1 0 20 34a20 20 0 0 1-20-34z" fill="#e9e4cf"/>`)
	} else {
		sx, sy, sc := 110, 120, "#f0c35a"
		if d.light == lEvening {
			sx, sc = 600, "#ef9a52"
		}
		if d.light == lNoon {
			sy = 70
		}
		o.WriteString(`<circle cx="` + itoa(sx) + `" cy="` + itoa(sy) + `" r="54" fill="` + sc + `" opacity=".18"/><circle cx="` + itoa(sx) + `" cy="` + itoa(sy) + `" r="34" fill="` + sc + `" opacity=".85"/>`)
	}
	// the maquette's shadow on the sheet, away from the sun
	sdx := 0
	if d.light == lMorning {
		sdx = 26
	} else if d.light == lEvening {
		sdx = -26
	}
	e := n6 * cell
	shadowOp := ".3"
	if night {
		shadowOp = ".45"
	}
	o.WriteString(`<path d="` + poly([]int{px(0, 0) + sdx, py(0, 0, -18) + 14, px(e, 0) + sdx, py(e, 0, -18) + 14,
		px(e, e) + sdx, py(e, e, -18) + 14, px(0, e) + sdx, py(0, e, -18) + 14}, true) +
		`" fill="#2a2018" opacity="` + shadowOp + `" filter="url(#sh)"/>`)
	o.WriteString(`<g stroke="#2a2420" stroke-opacity=".25" stroke-width=".6" stroke-linejoin="round">`)
	base := "#a58a64"
	o.WriteString(`<path d="` + poly(pts(0, e, 0, e, e, 0, e, e, -18, 0, e, -18), true) + `" ` + fill(pal.face(base, 0)) + `/>`)
	o.WriteString(`<path d="` + poly(pts(e, 0, 0, e, e, 0, e, e, -18, e, 0, -18), true) + `" ` + fill(pal.face(base, 1)) + `/>`)
	o.WriteString(body.String())
	o.WriteString(`</g>`)

	// --- events ---
	switch d.event {
	case eFestival:
		// a string of lanterns from the highest top to the top that spans furthest across
		if len(tops) < 4 {
			tops = append(tops, 200, 220, 504, 220)
		}
		a := 0
		for q := 2; q < len(tops); q += 2 {
			if tops[q+1] < tops[a+1] {
				a = q
			}
		}
		b, best := -1, 0
		for q := 0; q < len(tops); q += 2 {
			if q == a {
				continue
			}
			v := 2*absInt(tops[q]-tops[a]) - (tops[q+1] - tops[a+1])
			if b < 0 || v > best {
				b, best = q, v
			}
		}
		ax, ay, bx, by := tops[a], tops[a+1], tops[b], tops[b+1]
		my := maxInt(ay, by) + 40
		var lx []int
		for q := 1; q < 12; q++ {
			x := fdiv((12-q)*(12-q)*2*ax+2*q*(12-q)*(ax+bx)+q*q*2*bx, 288)
			y := fdiv((12-q)*(12-q)*ay+2*q*(12-q)*my+q*q*by, 144)
			lx = append(lx, x, y+3)
		}
		o.WriteString(`<path d="M` + itoa(ax) + " " + itoa(ay) + "Q" + itoa(fdiv(ax+bx, 2)) + " " + itoa(my) + " " + itoa(bx) + " " + itoa(by) +
			`" fill="none" stroke="#2a2420" stroke-width=".8"/>`)
		for col := 0; col < 4; col++ {
			var p strings.Builder
			for q := 1; q < 12; q++ {
				if q%4 == col {
					p.WriteString("M" + itoa(lx[2*q-2]-4) + " " + itoa(lx[2*q-1]) + "a4 4 0 1 0 8 0a4 4 0 1 0-8 0z")
				}
			}
			o.WriteString(`<path d="` + p.String() + `" fill="` + lanterns[col] + `"/>`)
		}
	case eFog:
		o.WriteString(`<rect y="380" width="` + W + `" height="260" fill="url(#fg)"/>`)
	case eBirds:
		var p strings.Builder
		for q := 0; q < 7; q++ {
			x := r.between(120, 600)
			y := r.between(40, 160)
			s := 2 * r.between(2, 4)
			hh := s / 2
			p.WriteString("M" + itoa(x-s) + " " + itoa(y-hh) + "q" + itoa(hh) + " 0 " + itoa(s) + " " + itoa(hh) +
				"q" + itoa(hh) + "-" + itoa(hh) + " " + itoa(s) + "-" + itoa(hh))
		}
		bc := "#3a332c"
		if night {
			bc = "#cfd6e6"
		}
		o.WriteString(`<path d="` + p.String() + `" fill="none" stroke="` + bc + `" stroke-width="1.4"/>`)
	}

	// --- title block, north arrow and scale bar ---
	ink := "#3a332c"
	if night {
		ink = "#c9d2e6"
	}
	head := "PROVA"
	if tid > 0 {
		head = "TAV. " + itoa(tid)
	}
	o.WriteString(`<g font-family="Georgia, serif" fill="` + ink + `"><rect x="520" y="626" width="164" height="54" fill="none" stroke="` + ink + `"/>` +
		`<path d="M520 646h164M610 646v34" stroke="` + ink + `" stroke-width=".7"/>` +
		`<text x="528" y="641" font-size="11" letter-spacing="1">CANTIERE · ` + head + `</text>` +
		`<text x="528" y="662" font-size="9">` + tr.Plan + `</text><text x="528" y="674" font-size="9">` + tr.Material + `</text>` +
		`<text x="618" y="662" font-size="9">1:500</text><text x="618" y="674" font-size="9">` + tr.Light + `</text></g>`)
	o.WriteString(`<g stroke="` + ink + `" fill="none"><circle cx="46" cy="650" r="16"/><path d="M46 628v44M42 640l4-12 4 12z" fill="` + ink + `"/>` +
		`<path d="M80 670h60M80 666v8M110 667v6M140 666v8" stroke-width="1.2"/><path d="M80 668h30v4h-30z" fill="` + ink + `"/></g>`)
	o.WriteString(`</svg>`)
	return o.String()
}

// TraitString is "Type=Value;…" in TraitTypes order (the golden-vector form
// shared with the TypeScript twin).
func TraitString(seed, params string) string {
	parts := []string{}
	for _, t := range Traits(engine.Input{Seed: seed, Params: params}) {
		parts = append(parts, t.Type+"="+t.Value)
	}
	return strings.Join(parts, ";")
}
