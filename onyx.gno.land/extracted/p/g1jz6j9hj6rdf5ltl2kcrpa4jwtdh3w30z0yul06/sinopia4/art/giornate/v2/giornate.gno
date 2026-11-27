// Package giornate (v2, "Wall Scenes") is a Sinopia signature engine: a
// fresco wall with a real scene on it (a procession, a gathering, an
// encounter at a city gate, an Annunciation, a lone saint or a landscape),
// caught mid-work. A fresco is painted on wet plaster one day-patch
// (giornata) at a time, from the top of the wall down. Finished patches show
// the scene in pigment; the rest of the wall still shows the same scene as
// the red-ochre sinopia underdrawing on the rough arriccio plaster, with its
// squaring grid, compass-drawn haloes and hatching. Where the painted plaster
// has fallen away (lacunae) the sinopia shows through again, as it does on
// real walls.
//
// Every element of the scene is defined once in <defs> and drawn twice with
// <use>: filled in the painted layer, outlined in the sinopia layer. That
// keeps figure-heavy walls small.
//
// Everything is integer maths (a 64-step quarter-sine table, truncating
// division), so the TypeScript twin in frontend/src/engines/giornatev2.ts is
// byte-identical. Two RNG streams come from the seed: seed+"|traits" decides
// the traits (cheap, no geometry: Traits never renders) and seed+"|art"
// draws the picture, so art draws never shift traits.
package giornate

import (
	"errors"
	"strconv"
	"strings"

	"gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia4/engine/v2"
)

// Trait types in the order Traits returns them.
var traitTypes = []string{"Scene", "Pigments", "Sky", "Completion", "Giornate", "Drawing", "Condition", "Rarity"}

// MaxSVGBytes: see docs/engines/giornate-v2.md for the measured sizes.
const MaxSVGBytes = 28672

const paramsSchema = `{"type":"object","additionalProperties":false,"properties":{` +
	`"palette":{"type":"string","title":"Pigments","enum":["Seeded","Terra Verde","Lapis & Ochre","Cinnabar","Pompeian","Umber","Rose Madder","Verdaccio"],"default":"Seeded"},` +
	`"scene":{"type":"string","title":"Scene","enum":["Seeded","Procession","Gathering","Encounter","Annunciation","Lone Figure","Landscape"],"default":"Seeded"},` +
	`"sky":{"type":"string","title":"Sky","enum":["Seeded","Clear Sky","Starry Vault","Gold Ground"],"default":"Seeded"},` +
	`"stage":{"type":"string","title":"Completion","enum":["Seeded","Pure Sinopia","Fresh Start","Half Wall","Advanced","Nearly Done","Finished"],"default":"Seeded"}}}`

// Manifest describes the engine. Author and FeeBps are set by the adapter.
func Manifest() engine.Manifest {
	return engine.Manifest{
		Name:    "Giornate II",
		Version: "2.0.0",
		Description: "A fresco wall with a real scene, caught mid-work: finished day-patches (giornate) " +
			"in pigment, the rest still in the red sinopia underdrawing the platform is named after.",
		License:      "CC-BY-NC-4.0",
		ParamsSchema: paramsSchema,
		TraitTypes:   append([]string{}, traitTypes...),
		Living:       false,
		MaxSVGBytes:  MaxSVGBytes,
		Kind:         engine.KindSVG,
	}
}

// ---------------------------------------------------------------------------
// Params: "" (the showcase look) or exactly the canonical JSON Studio sends,
// keys in schema order, no whitespace:
//   {"palette":"Seeded","scene":"Annunciation","sky":"Seeded","stage":"Seeded"}
// "Seeded" leaves that trait to the seed. Anything else is rejected.
// ---------------------------------------------------------------------------

type params struct {
	palette, scene, sky, stage int // table index, -1 = seeded
}

func parseParams(s string) (params, error) {
	p := params{-1, -1, -1, -1}
	if s == "" {
		return p, nil
	}
	keys := []string{`{"palette":"`, `","scene":"`, `","sky":"`, `","stage":"`}
	tables := [][]string{pigmentNames(), names(scenes), names(skies), names(stages)}
	out := []int{0, 0, 0, 0}
	rest := s
	for i, k := range keys {
		if !strings.HasPrefix(rest, k) {
			return p, errors.New("giornate params: expected " + strconv.Quote(k))
		}
		rest = rest[len(k):]
		end := strings.IndexByte(rest, '"')
		if end < 0 || strings.IndexByte(rest[:end], '\\') >= 0 {
			return p, errors.New("giornate params: bad value")
		}
		v := rest[:end]
		rest = rest[end:]
		idx, ok := lookup(v, tables[i])
		if !ok {
			return p, errors.New("giornate params: unknown value " + strconv.Quote(v))
		}
		out[i] = idx
	}
	if rest != `"}` {
		return p, errors.New("giornate params: expected end of object")
	}
	return params{out[0], out[1], out[2], out[3]}, nil
}

func lookup(v string, names []string) (int, bool) {
	if v == "Seeded" {
		return -1, true
	}
	for i, n := range names {
		if n == v {
			return i, true
		}
	}
	return -1, false
}

// ValidateParams accepts "" and the canonical params JSON only.
func ValidateParams(s string) error {
	_, err := parseParams(s)
	return err
}

// Traits returns the eight traits of in.Seed under in.Params. It never
// renders: one 7-draw RNG pass and a few table walks.
func Traits(in engine.Input) []engine.Trait {
	t := TraitsWith(in.Seed, in.Params)
	return []engine.Trait{
		{Type: "Scene", Value: t.Scene},
		{Type: "Pigments", Value: t.Pigments},
		{Type: "Sky", Value: t.Sky},
		{Type: "Completion", Value: t.Completion},
		{Type: "Giornate", Value: t.Giornate},
		{Type: "Drawing", Value: t.Drawing},
		{Type: "Condition", Value: t.Condition},
		{Type: "Rarity", Value: t.Rarity},
	}
}

// Render returns the raw SVG for in.Seed under in.Params. Core validates
// params before every render; invalid params panic.
func Render(in engine.Input) string { return SVGWith(in.Seed, in.Params) }

// SVG renders a seed with the default (showcase) params.
func SVG(seed string) string { return SVGWith(seed, "") }

// TraitsOf decodes a seed with the default params.
func TraitsOf(seed string) TraitSet { return TraitsWith(seed, "") }

// ---------------------------------------------------------------------------
// Deterministic randomness: FNV-1a over the seed, then splitmix64 (as v1).
// ---------------------------------------------------------------------------

const (
	fnvOffset uint64 = 14695981039346656037
	fnvPrime  uint64 = 1099511628211
)

type rng struct{ state uint64 }

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

// rr returns a value in [a, b].
func (r *rng) rr(a, b int) int { return a + r.intn(b-a+1) }

// pick walks cumulative weights once.
func (r *rng) pick(weights []int) int {
	total := 0
	for _, w := range weights {
		total += w
	}
	roll := r.intn(total)
	for i, w := range weights {
		roll -= w
		if roll < 0 {
			return i
		}
	}
	return len(weights) - 1
}

// Quarter sine, 64 steps per quarter turn, scaled by 1024.
var qsin = []int{0, 25, 50, 75, 100, 125, 150, 175, 200, 224, 249, 273, 297, 321, 345, 369, 392, 415, 438, 460,
	483, 505, 526, 548, 569, 590, 610, 630, 650, 669, 688, 706, 724, 742, 759, 775, 792, 807, 822,
	837, 851, 865, 878, 891, 903, 915, 926, 936, 946, 955, 964, 972, 980, 987, 993, 999, 1004, 1009,
	1013, 1016, 1019, 1021, 1023, 1024, 1024}

// isin takes an angle in 1/256 turn and returns sin*1024.
func isin(a int) int {
	a = ((a % 256) + 256) % 256
	switch {
	case a < 64:
		return qsin[a]
	case a < 128:
		return qsin[128-a]
	case a < 192:
		return -qsin[a-128]
	}
	return -qsin[256-a]
}

func icos(a int) int { return isin(a + 64) }

// ---------------------------------------------------------------------------
// Trait tables. Weights per table sum to 100; score feeds the rarity tier.
// ---------------------------------------------------------------------------

type option struct {
	name   string
	weight int
	score  int
}

// pigment: cols = robe, second robe, accent, light (walls, frame), land.
type pigment struct {
	option
	flesh, dark string
	cols        []string
}

var pigments = []pigment{
	{option{"Terra Verde", 18, 0}, "#e6c3a0", "#2f2a22", []string{"#6f8a5e", "#c69a5a", "#a8553f", "#e2d3b0", "#4f6a52"}},
	{option{"Lapis & Ochre", 17, 0}, "#e6c3a0", "#1f2433", []string{"#2f4f8a", "#c9893a", "#b5452f", "#e8dcc0", "#7a5a8a"}},
	{option{"Cinnabar", 15, 0}, "#e8c2a0", "#2a1d19", []string{"#c0392b", "#e6c178", "#3b5a7a", "#efe3c8", "#6a7a4a"}},
	{option{"Pompeian", 13, 1}, "#ddb08c", "#1d1a17", []string{"#9e2a22", "#d8b24a", "#2f2a26", "#e9d6b0", "#5a7a6a"}},
	{option{"Umber", 14, 0}, "#e2bf9a", "#1e1a17", []string{"#6a4a32", "#b88a52", "#3f4a3a", "#e2d2b2", "#8a3a2a"}},
	{option{"Rose Madder", 13, 1}, "#ecc8aa", "#3a2630", []string{"#c96b7a", "#6f8fb0", "#e3c27a", "#efe2cc", "#8a6aa0"}},
	{option{"Verdaccio", 10, 2}, "#cfc29c", "#34362a", []string{"#5f6b4a", "#9a8a5a", "#b98a6a", "#ddd2b6", "#7a6a5a"}},
}

const (
	scProcession = iota
	scGathering
	scEncounter
	scAnnunciation
	scLone
	scLandscape
)

var scenes = []option{
	{"Procession", 24, 0}, {"Gathering", 22, 0}, {"Encounter", 20, 0},
	{"Annunciation", 8, 3}, {"Lone Figure", 14, 2}, {"Landscape", 12, 2},
}

const (
	skyClear = iota
	skyStarry
	skyGold
)

var skies = []option{{"Clear Sky", 40, 0}, {"Starry Vault", 36, 1}, {"Gold Ground", 24, 2}}

const (
	stPure = iota
	stFresh
	stHalf
	stAdvanced
	stNearly
	stFinished
)

var stages = []option{
	{"Pure Sinopia", 6, 3}, {"Fresh Start", 16, 1}, {"Half Wall", 26, 0},
	{"Advanced", 26, 0}, {"Nearly Done", 18, 1}, {"Finished", 8, 2},
}

// giornate buckets: patch-count ranges in lo/hi.
type bucket struct {
	option
	lo, hi int
}

var buckets = []bucket{
	{option{"Few", 18, 1}, 6, 9},
	{option{"Several", 34, 0}, 10, 14},
	{option{"Many", 32, 0}, 15, 20},
	{option{"Countless", 16, 1}, 21, 28},
}

const (
	drLine = iota
	drSpolvero
	drPentimento
)

var drawings = []option{{"Sinopia Line", 72, 0}, {"Spolvero", 16, 2}, {"Pentimento", 12, 3}}

const (
	cdIntact = iota
	cdCraquelure
	cdLacunae
	cdRuined
)

var conditions = []option{{"Intact", 40, 0}, {"Craquelure", 30, 0}, {"Lacunae", 20, 1}, {"Ruined", 10, 2}}

func names(t []option) []string {
	out := make([]string, len(t))
	for i, o := range t {
		out[i] = o.name
	}
	return out
}

func pigmentNames() []string {
	out := make([]string, len(pigments))
	for i, p := range pigments {
		out[i] = p.name
	}
	return out
}

func weights(t []option) []int {
	out := make([]int, len(t))
	for i, o := range t {
		out[i] = o.weight
	}
	return out
}

func pigmentWeights() []int {
	out := make([]int, len(pigments))
	for i, p := range pigments {
		out[i] = p.weight
	}
	return out
}

func bucketWeights() []int {
	out := make([]int, len(buckets))
	for i, b := range buckets {
		out[i] = b.weight
	}
	return out
}

// Weights per table, built once at package init (Traits runs for hundreds of
// tokens per query).
var (
	pigmentW   = pigmentWeights()
	sceneW     = weights(scenes)
	skyW       = weights(skies)
	stageW     = weights(stages)
	bucketW    = bucketWeights()
	drawingW   = weights(drawings)
	conditionW = weights(conditions)
)

// Tier cut-offs on the score, chosen on a 10,000-seed simulation with
// default params (docs/engines/giornate-v2.md has the distribution).
const (
	scoreMythic    = 9
	scoreLegendary = 7
	scoreRare      = 5
	scoreUncommon  = 3
)

// TraitSet is a decoded seed. The SVG builder and the trait list read the
// same struct, so picture and metadata cannot disagree.
type TraitSet struct {
	Scene, Pigments, Sky, Completion, Giornate, Drawing, Condition string
	Score                                                          int
	Rarity                                                         string

	pig, scene, sky, stage, gio, draw, cond int // table indices actually used
}

// derive draws all seven picks in a fixed order (the order is part of the
// contract), then applies params. A trait fixed by params or hidden by the
// completion stage adds nothing to the score: rarity only counts what the
// seed chose and the picture shows.
func derive(seed string, p params) TraitSet {
	r := newRNG(seed + "|traits")
	t := TraitSet{
		pig:   r.pick(pigmentW),
		scene: r.pick(sceneW),
		sky:   r.pick(skyW),
		stage: r.pick(stageW),
		gio:   r.pick(bucketW),
		draw:  r.pick(drawingW),
		cond:  r.pick(conditionW),
	}
	score := 0
	if p.scene >= 0 {
		t.scene = p.scene
	} else {
		score += scenes[t.scene].score
	}
	if p.sky >= 0 {
		t.sky = p.sky
	} else {
		score += skies[t.sky].score
	}
	if p.stage >= 0 {
		t.stage = p.stage
	} else {
		score += stages[t.stage].score
	}
	if p.palette >= 0 {
		t.pig = p.palette
	}
	t.Scene = scenes[t.scene].name
	t.Pigments = pigments[t.pig].name
	t.Sky = skies[t.sky].name
	t.Completion = stages[t.stage].name
	t.Giornate = buckets[t.gio].name
	t.Drawing = drawings[t.draw].name
	t.Condition = conditions[t.cond].name
	score += conditions[t.cond].score
	if t.stage == stPure { // no pigment and no day-patch shows yet
		t.Pigments = "Unpainted"
		t.Giornate = "None"
	} else {
		score += buckets[t.gio].score
		if p.palette < 0 {
			score += pigments[t.pig].score
		}
	}
	if t.stage == stFinished && t.draw != drPentimento && (t.cond == cdIntact || t.cond == cdCraquelure) {
		// the drawing is painted over everywhere (no loss reopens it)
		t.Drawing = "Covered"
	} else {
		score += drawings[t.draw].score
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

// TraitsWith decodes a seed under params; invalid params panic.
func TraitsWith(seed, ps string) TraitSet {
	p, err := parseParams(ps)
	if err != nil {
		panic(err)
	}
	return derive(seed, p)
}

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

func itoa(n int) string { return strconv.Itoa(n) }

func hexv(c byte) int {
	if c >= 'a' {
		return int(c-'a') + 10
	}
	return int(c - '0')
}

const hexDigits = "0123456789abcdef"

func hex2(v int) string { return string([]byte{hexDigits[v>>4], hexDigits[v&15]}) }

// mix blends a towards b by t percent (truncating), both "#rrggbb".
func mix(a, b string, t int) string {
	out := "#"
	for i := 1; i < 7; i += 2 {
		x := hexv(a[i])*16 + hexv(a[i+1])
		y := hexv(b[i])*16 + hexv(b[i+1])
		out += hex2(x + (y-x)*t/100)
	}
	return out
}

// shade scales a colour by f percent (f <= 100).
func shade(a string, f int) string {
	out := "#"
	for i := 1; i < 7; i += 2 {
		out += hex2((hexv(a[i])*16 + hexv(a[i+1])) * f / 100)
	}
	return out
}

type pt struct{ x, y int }

// relPath: "M x y l dx dy dx dy …z" (zero moves skipped).
func relPath(p []pt) string {
	var b strings.Builder
	px, py := p[0].x, p[0].y
	b.WriteString("M" + itoa(px) + " " + itoa(py))
	first := true
	for i := 1; i < len(p); i++ {
		dx, dy := p[i].x-px, p[i].y-py
		if dx == 0 && dy == 0 {
			continue
		}
		if first {
			b.WriteString("l")
			first = false
		} else {
			b.WriteString(" ")
		}
		b.WriteString(itoa(dx) + " " + itoa(dy))
		px, py = p[i].x, p[i].y
	}
	b.WriteString("z")
	return b.String()
}

// ---------------------------------------------------------------------------
// Day-patches: convex polygons cut by lines (v1's subdivision on 600x800).
// ---------------------------------------------------------------------------

const (
	cW = 600
	cH = 800
)

func area2(p []pt) int {
	s := 0
	n := len(p)
	for i := 0; i < n; i++ {
		a, b := p[i], p[(i+1)%n]
		s += a.x*b.y - b.x*a.y
	}
	if s < 0 {
		return -s
	}
	return s
}

// cut splits poly by the line through (px,py) with direction (dx,dy).
func cut(poly []pt, px, py, dx, dy int) ([]pt, []pt) {
	var a, b []pt
	n := len(poly)
	for i := 0; i < n; i++ {
		p, q := poly[i], poly[(i+1)%n]
		sa := dx*(p.y-py) - dy*(p.x-px)
		sb := dx*(q.y-py) - dy*(q.x-px)
		if sa >= 0 {
			a = append(a, p)
		}
		if sa <= 0 {
			b = append(b, p)
		}
		if (sa > 0 && sb < 0) || (sa < 0 && sb > 0) {
			c := pt{p.x + (q.x-p.x)*sa/(sa-sb), p.y + (q.y-p.y)*sa/(sa-sb)}
			a = append(a, c)
			b = append(b, c)
		}
	}
	return a, b
}

// subdivide cuts the wall into target patches, always cutting the largest.
func subdivide(r *rng, target int) [][]pt {
	polys := [][]pt{{{0, 0}, {cW, 0}, {cW, cH}, {0, cH}}}
	areas := []int{2 * cW * cH}
	mn := 2 * cW * cH / (target * 4)
	for tries := 0; len(polys) < target && tries < 400; tries++ {
		bi := 0
		for i := 1; i < len(areas); i++ {
			if areas[i] > areas[bi] {
				bi = i
			}
		}
		p := polys[bi]
		minx, maxx, miny, maxy, sx, sy := p[0].x, p[0].x, p[0].y, p[0].y, 0, 0
		for _, q := range p {
			sx += q.x
			sy += q.y
			if q.x < minx {
				minx = q.x
			}
			if q.x > maxx {
				maxx = q.x
			}
			if q.y < miny {
				miny = q.y
			}
			if q.y > maxy {
				maxy = q.y
			}
		}
		bw, bh := maxx-minx, maxy-miny
		cx := sx/len(p) + r.rr(-bw/5, bw/5)
		cy := sy/len(p) + r.rr(-bh/5, bh/5)
		ang := r.rr(-12, 12)
		if bw > bh {
			ang += 64
		}
		a, b := cut(p, cx, cy, icos(ang), isin(ang))
		if len(a) < 3 || len(b) < 3 {
			continue
		}
		aa, ab := area2(a), area2(b)
		if aa < mn || ab < mn {
			continue
		}
		polys[bi], areas[bi] = a, aa
		polys = append(polys, b)
		areas = append(areas, ab)
	}
	return polys
}

// ---------------------------------------------------------------------------
// The scene: every element is a part, defined once in <defs> and drawn as a
// filled <use> in the painted layer and an outlined <use> in the sinopia.
// ---------------------------------------------------------------------------

type part struct {
	ref   int    // id of the <defs> element (q<ref>)
	fill  string // painted fill; "" for a line part
	line  string // line colour (line parts)
	sw    string // line width (line parts)
	dash  bool   // dotted line in the painted layer (halo punchwork)
	hatch bool   // hatched in the sinopia (draperies)
	ghost bool   // painted only: no sinopia outline, no painted contour
	over  bool   // painted overlay of an earlier element (sky pattern)
	sketch bool  // sinopia only (a ridge line)
}

type scene struct {
	defs  strings.Builder
	parts []part
	n     int
	hatch  bool   // a hatch pattern is needed
	gold   bool   // the gold gradient is needed
	shadow string // cast-shadow colour on the ground
}

func (s *scene) def(tag, attrs string) int {
	id := s.n
	s.n++
	s.defs.WriteString("<" + tag + ` id="q` + itoa(id) + `" ` + attrs + "/>")
	return id
}

func (s *scene) fill(tag, attrs, fill string) int {
	id := s.def(tag, attrs)
	s.parts = append(s.parts, part{ref: id, fill: fill})
	return id
}

func (s *scene) ghost(tag, attrs, fill string) int {
	id := s.def(tag, attrs)
	s.parts = append(s.parts, part{ref: id, fill: fill, ghost: true})
	return id
}

func (s *scene) drape(d, fill string) int {
	id := s.def("path", `d="`+d+`"`)
	s.parts = append(s.parts, part{ref: id, fill: fill, hatch: true})
	s.hatch = true
	return id
}

func (s *scene) line(d, colour, width string) int {
	id := s.def("path", `d="`+d+`"`)
	s.parts = append(s.parts, part{ref: id, line: colour, sw: width})
	return id
}

func path(d string) string { return `d="` + d + `"` }

func circleA(cx, cy, r int) string {
	return `cx="` + itoa(cx) + `" cy="` + itoa(cy) + `" r="` + itoa(r) + `"`
}

func ellipseA(cx, cy, rx, ry int) string {
	return `cx="` + itoa(cx) + `" cy="` + itoa(cy) + `" rx="` + itoa(rx) + `" ry="` + itoa(ry) + `"`
}

// hill: a rolling ridge across the wall (two sine harmonics), painted as a
// ghost fill down to bottom; the sinopia draws only its ridge line.
func (s *scene) hill(yb, amp, ph, bottom int, fill string) {
	var b strings.Builder
	for x := 40; x <= 560; x += 20 {
		t := (x - 40) * 256 / 520
		y := yb - amp*(1536+isin(ph+t)+isin(3*ph+2*t)/2)/3072
		if x == 40 {
			b.WriteString("M40 " + itoa(y) + "L")
		} else {
			b.WriteString(" " + itoa(x) + " " + itoa(y))
		}
	}
	ridge := b.String()
	s.ghost("path", path(ridge+"V"+itoa(bottom)+"H40z"), fill)
	id := s.def("path", path(ridge))
	s.parts = append(s.parts, part{ref: id, sketch: true})
}

// robe: the bell-shaped gown of a standing figure.
func robe(x, y, ht, sy, sw, hw int) string {
	return "M" + itoa(x-sw) + " " + itoa(sy) +
		"C" + itoa(x-sw-6) + " " + itoa(sy+ht*3/10) + " " + itoa(x-hw) + " " + itoa(y-ht/5) + " " + itoa(x-hw) + " " + itoa(y) +
		"H" + itoa(x+hw) +
		"C" + itoa(x+hw) + " " + itoa(y-ht/5) + " " + itoa(x+sw+6) + " " + itoa(sy+ht*3/10) + " " + itoa(x+sw) + " " + itoa(sy) +
		"Q" + itoa(x) + " " + itoa(sy-10) + " " + itoa(x-sw) + " " + itoa(sy) + "z"
}

var hairs = []string{"#4a3222", "#8a5a2a", "#2a2020", "#c9a060", "#6a6a6a"}

const (
	atNone = iota
	atBook
	atStaff
	atFlower
	atScroll
)

var attrW = []int{30, 25, 20, 15, 10}

type figure struct{ x, y, ht int }

// person draws one standing figure; it returns the ids of its robe and head
// (the pentimento redraws them). attr < 0 draws the attribute from r.
func (s *scene) person(r *rng, pg pigment, f figure, halo, wings bool, attr int) (int, int) {
	pal := pg.cols
	x, y, ht := f.x, f.y, f.ht
	hr := ht * 3 / 40
	hy := y - ht + hr
	sy := hy + hr + hr*6/10
	sw := ht * 12 / 100
	hw := ht*17/100 + r.rr(-4, 6)
	c1 := pal[r.intn(4)]
	c2 := pal[r.intn(5)]
	if c2 == c1 {
		c2 = pal[4]
	}
	s.ghost("ellipse", ellipseA(x, y, hw+12, 7), s.shadow)
	if wings {
		wy := sy + 6
		wing := "#ece2cc"
		s.fill("path", path(
			"M"+itoa(x-8)+" "+itoa(wy)+"C"+itoa(x-60)+" "+itoa(wy-80)+" "+itoa(x-128)+" "+itoa(wy-30)+" "+itoa(x-112)+" "+itoa(wy+120)+
				"C"+itoa(x-86)+" "+itoa(wy+66)+" "+itoa(x-46)+" "+itoa(wy+52)+" "+itoa(x-8)+" "+itoa(wy+40)+"z"+
				"M"+itoa(x+8)+" "+itoa(wy)+"C"+itoa(x+60)+" "+itoa(wy-80)+" "+itoa(x+128)+" "+itoa(wy-30)+" "+itoa(x+112)+" "+itoa(wy+120)+
				"C"+itoa(x+86)+" "+itoa(wy+66)+" "+itoa(x+46)+" "+itoa(wy+52)+" "+itoa(x+8)+" "+itoa(wy+40)+"z"), wing)
		fd := ""
		for k := 0; k < 3; k++ {
			o := 30 + k*26
			fd += "M" + itoa(x-o) + " " + itoa(wy-14+k*8) + "l" + itoa(-24+k*6) + " " + itoa(70-k*14) +
				"M" + itoa(x+o) + " " + itoa(wy-14+k*8) + "l" + itoa(24-k*6) + " " + itoa(70-k*14)
		}
		s.line(fd, mix(pal[2], "#a89070", 50), "1.4")
	}
	if halo {
		s.gold = true
		s.fill("circle", circleA(x, hy, hr*17/10), "url(#au)")
		dot := s.def("circle", circleA(x, hy, hr*145/100))
		s.parts = append(s.parts, part{ref: dot, line: "#8a6420", sw: "1.4", dash: true})
	}
	nw := hr * 4 / 10
	s.ghost("path", path("M"+itoa(x-nw)+" "+itoa(hy+hr/2)+"V"+itoa(sy+4)+"H"+itoa(x+nw)+"V"+itoa(hy+hr/2)+"z"), shade(pg.flesh, 88))
	rb := s.drape(robe(x, y, ht, sy, sw, hw), c1)
	ms := 1
	if r.intn(2) == 0 {
		ms = -1
	}
	s.drape("M"+itoa(x-ms*sw)+" "+itoa(sy)+
		"Q"+itoa(x+ms*sw*2)+" "+itoa(sy+ht/4)+" "+itoa(x+ms*hw)+" "+itoa(y-ht/4)+
		"L"+itoa(x+ms*hw)+" "+itoa(y-ht/20)+
		"Q"+itoa(x-ms*(hw*4/10))+" "+itoa(y-ht*3/10)+" "+itoa(x-ms*sw)+" "+itoa(sy)+"z", c2)
	fd := ""
	for k := 0; k < 4; k++ {
		fx := x - hw*6/10 + k*(hw*4/10)
		fd += "M" + itoa(x-sw/2+k*(sw/3)) + " " + itoa(sy+ht*35/100) +
			"Q" + itoa(fx+r.rr(-8, 8)) + " " + itoa(y-ht/5) + " " + itoa(fx) + " " + itoa(y-4)
	}
	s.line(fd, shade(c1, 62), "1.6")
	hd := s.fill("ellipse", ellipseA(x, hy, hr*82/100, hr), pg.flesh)
	hc := hairs[r.intn(len(hairs))]
	s.fill("path", path("M"+itoa(x-hr)+" "+itoa(hy+4)+
		"Q"+itoa(x-hr)+" "+itoa(hy-hr*125/100)+" "+itoa(x)+" "+itoa(hy-hr*105/100)+
		"Q"+itoa(x+hr)+" "+itoa(hy-hr*125/100)+" "+itoa(x+hr)+" "+itoa(hy+4)+
		"Q"+itoa(x+hr*6/10)+" "+itoa(hy-hr/2)+" "+itoa(x)+" "+itoa(hy-hr*55/100)+
		"Q"+itoa(x-hr*6/10)+" "+itoa(hy-hr/2)+" "+itoa(x-hr)+" "+itoa(hy+4)+"z"), hc)
	s.line("M"+itoa(x-hr*35/100)+" "+itoa(hy-1)+"h4M"+itoa(x+hr*2/10)+" "+itoa(hy-1)+"h4M"+itoa(x)+" "+itoa(hy+3)+"v"+itoa(hr/5)+"M"+itoa(x-2)+" "+itoa(hy+hr*45/100)+"h5",
		"#5a3a2a", "1.4")
	if attr < 0 {
		attr = r.pick(attrW)
	}
	hx := x + r.rr(-6, 6)
	hyy := sy + ht/4
	switch attr {
	case atBook:
		s.fill("path", path("M"+itoa(hx-12)+" "+itoa(hyy-14)+"h24v28h-24z"), pal[2])
	case atStaff:
		s.line("M"+itoa(x+sw+4)+" "+itoa(sy-hr*2)+"V"+itoa(y), "#6a4a2a", "3.5")
	case atFlower:
		s.line("M"+itoa(hx)+" "+itoa(hyy)+"v-34", "#4f6a3a", "2")
		s.fill("circle", circleA(hx, hyy-38, 6), "#f2ece0")
	case atScroll:
		s.fill("path", path("M"+itoa(hx-14)+" "+itoa(hyy-6)+"h28v14h-28z"), "#efe4c8")
	}
	s.fill("ellipse", ellipseA(hx, hyy+2, 6, 5), pg.flesh)
	return rb, hd
}

// ---------------------------------------------------------------------------
// SVG
// ---------------------------------------------------------------------------

const (
	sinRed   = "#a8432c"
	intonaco = "#efe6d4"
	arriccio = "#cdb497"
)

// SVGWith renders a seed under params as a standalone SVG document.
func SVGWith(seed, ps string) string {
	t := TraitsWith(seed, ps)
	pg := pigments[t.pig]
	pal := pg.cols
	r := newRNG(seed + "|art")
	s := &scene{}

	// 1. sky, hills, city, road, trees
	yh := r.rr(440, 500)
	if t.scene == scLandscape {
		yh = r.rr(420, 480)
	}
	skyFill := "url(#sk)"
	if t.sky == skyStarry {
		skyFill = "#23386b"
	} else if t.sky == skyGold {
		skyFill = "url(#au)"
		s.gold = true
	}
	sky := s.ghost("rect", `x="40" y="40" width="520" height="`+itoa(yh-40)+`"`, skyFill)
	if t.sky == skyClear {
		for c := 0; c < 3; c++ {
			cx := r.rr(90, 510)
			cy := r.rr(80, 220)
			s.fill("path", path("M"+itoa(cx-40)+" "+itoa(cy)+"q10-22 30-12q14-20 34-2q22-4 20 14z"), "#f1f3ee")
		}
	} else {
		s.parts = append(s.parts, part{ref: sky, fill: "url(#st)", ghost: true, over: true})
	}
	s.hill(yh-10, r.rr(40, 110), r.intn(256), yh+40, mix(pal[4], "#c8c0a0", 40))
	if t.scene != scProcession || r.intn(2) == 0 {
		cx := r.rr(140, 460)
		if t.scene == scLone { // the town stands beside the saint, not behind
			cx = 150 + (cx%2)*300
		}
		cy := yh - r.rr(30, 70)
		camp := r.intn(6)
		d, rf := "", ""
		for k := 0; k < 6; k++ {
			x := cx - 70 + k*24 + r.rr(-4, 4)
			hgt := r.rr(26, 70)
			if k == camp {
				hgt += 40
			}
			d += "M" + itoa(x) + " " + itoa(cy) + "v-" + itoa(hgt) + "h20v" + itoa(hgt) + "z"
			rf += "M" + itoa(x-3) + " " + itoa(cy-hgt) + "l13-14 13 14z"
		}
		s.fill("path", path("M"+itoa(cx-80)+" "+itoa(yh+30)+"V"+itoa(cy)+"h160V"+itoa(yh+30)+"z"+d), pal[3])
		s.fill("path", path(rf), pal[2])
	}
	s.hill(yh+20, r.rr(20, 60), r.intn(256), yh+60, mix(pal[4], "#8a9a60", 30))
	ground := mix(pal[4], "#9a8a5a", 50)
	s.shadow = shade(ground, 80)
	s.hill(yh+40, r.rr(4, 14), r.intn(256), 760, ground)
	if t.scene == scLandscape {
		bx := r.rr(200, 400)
		tx := r.rr(220, 380)
		mx := (bx+tx)/2 + r.rr(-60, 60)
		my := (760 + yh) / 2
		s.fill("path", path("M"+itoa(bx-44)+" 760Q"+itoa(mx-18)+" "+itoa(my)+" "+itoa(tx-3)+" "+itoa(yh+42)+
			"h6Q"+itoa(mx+18)+" "+itoa(my)+" "+itoa(bx+44)+" 760z"), mix(pal[3], "#c9b48a", 40))
		x := r.rr(90, 470)
		s.fill("path", path("M"+itoa(x)+" "+itoa(yh+30)+"v-34h40v34zM"+itoa(x+30)+" "+itoa(yh-4)+"v-30h12v30z"), pal[3])
		s.fill("path", path("M"+itoa(x-4)+" "+itoa(yh-4)+"l24-18 24 18zM"+itoa(x+28)+" "+itoa(yh-34)+"l8-12 8 12z"), pal[2])
	}
	ntree := r.rr(1, 3)
	if t.scene == scLandscape {
		ntree = r.rr(4, 7)
	}
	depth := 60
	if t.scene == scLandscape {
		depth = 230
	}
	for k := 0; k < ntree; k++ {
		x := r.rr(70, 530)
		y := yh + r.rr(10, depth)
		g := 100 + (y-yh-10)*80/230 // nearer trees are larger
		if r.intn(2) == 0 {
			s.fill("ellipse", ellipseA(x, y-40*g/100, 11*g/100, 42*g/100), mix("#3f5a3a", pal[4], 25))
		} else {
			s.line("M"+itoa(x)+" "+itoa(y)+"v-"+itoa(30*g/100), "#5a3e28", "4")
			s.fill("circle", circleA(x, y-44*g/100, 22*g/100), mix("#5d7a3c", pal[4], 25))
		}
	}
	if t.scene == scLandscape { // vineyard rows and a flight of birds
		vx := r.rr(60, 330)
		vy := yh + r.rr(90, 190)
		d := ""
		for k := 0; k < 6; k++ {
			d += "M" + itoa(vx+k*8) + " " + itoa(vy+k*14) + "h" + itoa(150+k*10)
		}
		s.line(d, shade(ground, 70), "3")
		d = ""
		for k := 0; k < 7; k++ {
			bx := r.rr(120, 480)
			by := r.rr(70, yh-120)
			w := r.rr(5, 9)
			d += "M" + itoa(bx-w) + " " + itoa(by-w/2) + "q" + itoa(w/2) + " 0 " + itoa(w) + " " + itoa(w/2) + "q" + itoa(w/2) + "-" + itoa(w/2) + " " + itoa(w) + "-" + itoa(w/2)
		}
		bird := "#3a332c"
		if t.sky == skyStarry {
			bird = "#d8dcea"
		}
		s.line(d, bird, "1.4")
	}

	// 2. the figures
	gY := 760 - r.rr(50, 80)
	var figs []figure
	switch t.scene {
	case scProcession:
		n := r.rr(4, 6)
		for k := 0; k < n; k++ {
			x := 100 + k*420/(n-1) + r.rr(-8, 8)
			y := gY - r.rr(0, 10)
			figs = append(figs, figure{x, y, r.rr(340, 400)})
		}
	case scGathering:
		n := r.rr(5, 7)
		b := n / 2
		for j := 0; j < b; j++ {
			x := 300 - (b-1)*55 + j*110 + r.rr(-10, 10)
			figs = append(figs, figure{x, gY - 46, r.rr(310, 350)})
		}
		f := n - b
		for j := 0; j < f; j++ {
			figs = append(figs, figure{300 - (f-1)*60 + j*120, gY, r.rr(350, 400)})
		}
	case scEncounter:
		l := r.rr(2, 3)
		rt := r.rr(2, 3)
		for k := l - 1; k >= 0; k-- {
			figs = append(figs, figure{95 + k*70, gY - k*4, r.rr(350, 400)})
		}
		for k := rt - 1; k >= 0; k-- {
			figs = append(figs, figure{505 - k*70, gY - k*4, r.rr(350, 400)})
		}
	case scAnnunciation:
		figs = append(figs, figure{r.rr(150, 180), gY, r.rr(360, 395)})
		figs = append(figs, figure{r.rr(430, 450), gY - 6, r.rr(330, 355)})
	case scLone:
		figs = append(figs, figure{300, gY + 10, r.rr(540, 600)})
	}
	hm := r.intn(3) // haloes: none, some, all
	if t.scene == scAnnunciation || t.scene == scLone {
		hm = 2
	}
	if t.scene == scEncounter {
		s.fill("path", path("M250 "+itoa(gY)+"v-150a50 50 0 0 1 100 0v150z"), pal[3])
		s.fill("path", path("M274 "+itoa(gY)+"v-110a26 26 0 0 1 52 0v110z"), "#2c241e")
	}
	if t.scene == scAnnunciation {
		top := gY - 328
		s.ghost("path", path("M368 "+itoa(gY)+"V"+itoa(top)+"H522V"+itoa(gY)+"z"), mix(pal[1], "#2c241e", 55))
		s.fill("path", path("M354 "+itoa(gY)+"V"+itoa(top)+"h14V"+itoa(gY)+"zM522 "+itoa(gY)+"V"+itoa(top)+"h14V"+itoa(gY)+
			"zM368 "+itoa(top)+"H522V"+itoa(top+78)+"A77 60 0 0 0 368 "+itoa(top+78)+"z"), pal[3])
		s.fill("path", path("M344 "+itoa(top-22)+"h202v22h-202z"), pal[2])
	}
	var robes, heads []int
	for i, f := range figs {
		halo := hm == 2 || (hm == 1 && r.intn(2) == 0)
		attr := -1
		wings := false
		if t.scene == scAnnunciation {
			if i == 0 {
				attr, wings = atFlower, true
			} else {
				attr = atBook
			}
		}
		rb, hd := s.person(r, pg, f, halo, wings, attr)
		robes = append(robes, rb)
		heads = append(heads, hd)
	}
	if t.scene == scAnnunciation {
		v := figs[1]
		vhy := v.y - v.ht + v.ht*3/40
		s.line("M60 60L"+itoa(v.x-8)+" "+itoa(vhy)+"M60 60L"+itoa(v.x)+" "+itoa(vhy-10)+"M60 60L"+itoa(v.x-14)+" "+itoa(vhy+10), "#d9b54a", "1.5")
		dx := 60 + (v.x-60)*45/100
		dy := 60 + (vhy-60)*45/100
		s.fill("path", path("M"+itoa(dx-9)+" "+itoa(dy)+"q9-9 18 0q-9 5-18 0zM"+itoa(dx-2)+" "+itoa(dy-2)+"l-6-9 10 5z"), "#f6f1e6")
	}

	// 3. pentimento: a figure the painter moved, still showing through
	pent := ""
	if t.draw == drPentimento {
		if len(robes) > 0 {
			gi := r.intn(len(robes))
			dx := r.rr(20, 44)
			if r.intn(2) == 0 {
				dx = -dx
			}
			dy := r.rr(-20, 6)
			pent = `<g transform="translate(` + itoa(dx) + " " + itoa(dy) + `)" fill="none" stroke="` + sinRed +
				`" stroke-opacity=".55" stroke-width="2.4"><use href="#q` + itoa(robes[gi]) + `"/><use href="#q` + itoa(heads[gi]) + `"/></g>`
		} else {
			x := r.rr(220, 380)
			ht := r.rr(320, 370)
			hr := ht * 3 / 40
			hy := gY - ht + hr
			sy := hy + hr + hr*6/10
			pent = `<g fill="none" stroke="` + sinRed + `" stroke-opacity=".55" stroke-width="2.4"><path d="` +
				robe(x, gY, ht, sy, ht*12/100, ht*17/100) + `"/><ellipse ` + ellipseA(x, hy, hr*82/100, hr) + `/></g>`
		}
	}

	// 4. the wall, cut into day-patches, painted top-down
	gb := buckets[t.gio]
	polys := subdivide(r, r.rr(gb.lo, gb.hi))
	n := len(polys)
	key := make([]int, n)
	order := make([]int, n)
	for i, p := range polys {
		sy := 0
		for _, q := range p {
			sy += q.y
		}
		key[i] = sy/len(p) + r.rr(0, 170)
		order[i] = i
	}
	for i := 1; i < n; i++ { // stable insertion sort
		for j := i; j > 0 && key[order[j-1]] > key[order[j]]; j-- {
			order[j-1], order[j] = order[j], order[j-1]
		}
	}
	pct := 0
	switch t.stage {
	case stFresh:
		pct = r.rr(12, 28)
	case stHalf:
		pct = r.rr(40, 60)
	case stAdvanced:
		pct = r.rr(65, 82)
	case stNearly:
		pct = r.rr(86, 96)
	case stFinished:
		pct = 100
	}
	k := (n*pct + 50) / 100
	if pct > 0 && pct < 100 {
		if k < 1 {
			k = 1
		}
		if k > n-1 {
			k = n - 1
		}
	}
	arSeed := r.rr(1, 900)
	cracks := t.cond == cdCraquelure || t.cond == cdRuined
	ckSeed := 0
	if cracks {
		ckSeed = r.rr(1, 900)
	}
	lac, core := "", ""
	if t.cond == cdLacunae || t.cond == cdRuined {
		nl := r.rr(1, 3)
		if t.cond == cdRuined {
			nl = r.rr(3, 5)
		}
		for l := 0; l < nl; l++ {
			cx := r.rr(70, 530)
			cy := r.rr(90, 730)
			r0 := r.rr(18, 56)
			var outer, inner []pt
			for a := 0; a < 256; a += 21 {
				rad := r0 * r.rr(70, 120) / 100
				outer = append(outer, pt{cx + rad*icos(a)/1024, cy + rad*isin(a)/1024})
				ri := rad * 55 / 100
				inner = append(inner, pt{cx + ri*icos(a)/1024, cy + ri*isin(a)/1024})
			}
			lac += relPath(outer)
			core += relPath(inner)
		}
	}

	// 5. write the document
	fresco := k > 0
	sinopia := k < n || lac != ""
	clip := fresco && k < n
	var b strings.Builder
	b.WriteString(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 600 800" width="600" height="800"><defs>`)
	if s.gold && fresco {
		b.WriteString(`<linearGradient id="au" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#e9c873"/><stop offset=".5" stop-color="#c49a3e"/><stop offset="1" stop-color="#ead18a"/></linearGradient>`)
	}
	switch {
	case !fresco && t.sky != skyStarry:
	case t.sky == skyClear:
		b.WriteString(`<linearGradient id="sk" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#8fb3c8"/><stop offset="1" stop-color="#dfe6dc"/></linearGradient>`)
	case t.sky == skyStarry:
		if fresco {
			b.WriteString(`<pattern id="st" width="46" height="40" patternUnits="userSpaceOnUse"><path d="M10 6l1.6 3.4 3.4 1.6-3.4 1.6-1.6 3.4-1.6-3.4-3.4-1.6 3.4-1.6zM33 26l1.4 3 3 1.4-3 1.4-1.4 3-1.4-3-3-1.4 3-1.4z" fill="#e3c26a"/></pattern>`)
		}
		if sinopia {
			b.WriteString(`<pattern id="sm" width="46" height="40" patternUnits="userSpaceOnUse"><path d="M10 6v8M6 10h8M33 26v8M29 30h8" stroke="` + sinRed + `" stroke-opacity=".6"/></pattern>`)
		}
	case t.sky == skyGold:
		b.WriteString(`<pattern id="st" width="14" height="14" patternUnits="userSpaceOnUse"><circle cx="7" cy="7" r="1.1" fill="#8a6420" fill-opacity=".5"/></pattern>`)
	}
	if sinopia && s.hatch {
		b.WriteString(`<pattern id="ht" width="7" height="7" patternUnits="userSpaceOnUse" patternTransform="rotate(35)"><path d="M0 3.5h7" stroke="` +
			sinRed + `" stroke-opacity=".55" stroke-width=".9"/></pattern>`)
	}
	if fresco {
		b.WriteString(`<pattern id="fr" width="24" height="24" patternUnits="userSpaceOnUse"><rect width="24" height="24" fill="` + pal[3] +
			`"/><path d="M0 0l12 12L0 24zM24 0L12 12l12 12z" fill="` + pal[2] + `"/><path d="M12 6l6 6-6 6-6-6z" fill="` + pal[0] + `"/></pattern>`)
	}
	b.WriteString(`<filter id="ar" x="0" y="0" width="1" height="1"><feTurbulence type="fractalNoise" baseFrequency=".05" numOctaves="3" seed="` +
		itoa(arSeed) + `"/><feColorMatrix values="0 0 0 0 .45 0 0 0 0 .32 0 0 0 0 .22 0 0 0 -1.3 .62"/></filter>`)
	if cracks {
		b.WriteString(`<filter id="ck" x="0" y="0" width="1" height="1"><feTurbulence type="fractalNoise" baseFrequency=".03" numOctaves="2" seed="` +
			itoa(ckSeed) + `" result="t"/><feColorMatrix in="t" values="0 0 0 0 .2 0 0 0 0 .14 0 0 0 0 .1 1 0 0 0 0" result="a"/>` +
			`<feComponentTransfer in="a" result="c"><feFuncA type="discrete" tableValues="0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 .5 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0"/></feComponentTransfer>` +
			`<feComposite in="c" in2="SourceAlpha" operator="in" result="d"/><feMerge><feMergeNode in="SourceGraphic"/><feMergeNode in="d"/></feMerge></filter>`)
	}
	b.WriteString(s.defs.String())
	if fresco {
		var dn strings.Builder
		for i := 0; i < k; i++ {
			dn.WriteString(relPath(polys[order[i]]))
		}
		b.WriteString(`<path id="dn" d="` + dn.String() + `"/>`)
		if clip {
			b.WriteString(`<clipPath id="cp"><use href="#dn"/></clipPath>`)
		}
	}
	if lac != "" {
		b.WriteString(`<path id="lc" d="` + lac + `"/>`)
		if fresco {
			b.WriteString(`<mask id="lm"><rect width="600" height="800" fill="#fff"/><use href="#lc" fill="#000"/></mask>`)
		}
	}
	if sinopia {
		// the sinopia strokes, once, for the drawing and its searching double
		b.WriteString(`<g id="sn">`)
		for _, p := range s.parts {
			if !p.over && !p.ghost {
				b.WriteString(`<use href="#q` + itoa(p.ref) + `"/>`)
			}
		}
		b.WriteString(`</g>`)
	}
	b.WriteString(`</defs>`)
	if cracks {
		b.WriteString(`<g filter="url(#ck)">`)
	}

	// sinopia layer: arriccio, squaring grid, the drawing
	if sinopia {
		b.WriteString(`<rect width="600" height="800" fill="` + arriccio + `"/><rect width="600" height="800" filter="url(#ar)"/><path d="`)
		for x := 40; x <= 560; x += 52 {
			b.WriteString("M" + itoa(x) + " 40V760")
		}
		for y := 40; y <= 760; y += 52 {
			b.WriteString("M40 " + itoa(y) + "H560")
		}
		b.WriteString(`M300 40V760M40 ` + itoa(yh) + `H560" stroke="` + sinRed + `" stroke-opacity=".28" stroke-width=".8"/>`)
		switch t.sky {
		case skyStarry:
			b.WriteString(`<use href="#q` + itoa(sky) + `" fill="url(#sm)"/>`)
		case skyGold: // the red bole laid under gold
			b.WriteString(`<use href="#q` + itoa(sky) + `" fill="#b5653f" fill-opacity=".22"/>`)
		}
		b.WriteString(`<path d="M40 40H560V760H40z" fill="none" stroke="` + sinRed + `" stroke-width="1.5"/>`)
		b.WriteString(`<g fill="none" stroke="` + sinRed + `" stroke-linejoin="round" stroke-linecap="round"`)
		if t.draw == drSpolvero {
			b.WriteString(` stroke-dasharray="1.2 4" stroke-width="2.4"><use href="#sn"/>`)
		} else {
			b.WriteString(` stroke-width="1.8"><use href="#sn"/><use href="#sn" transform="translate(3 -2)" stroke-opacity=".35" stroke-width="1"/>`)
		}
		for _, p := range s.parts {
			if p.hatch {
				b.WriteString(`<use href="#q` + itoa(p.ref) + `" fill="url(#ht)" stroke="none"/>`)
			}
		}
		b.WriteString(`</g>`)
	}

	// painted layer: the finished giornate
	if fresco {
		if lac != "" {
			b.WriteString(`<g mask="url(#lm)">`)
		}
		if clip {
			b.WriteString(`<g clip-path="url(#cp)">`)
		} else {
			b.WriteString(`<g>`)
		}
		b.WriteString(`<rect width="600" height="800" fill="` + intonaco + `"/><g stroke="` + pg.dark + `" stroke-opacity=".45" stroke-width="1.1" stroke-linejoin="round">`)
		for _, p := range s.parts {
			if p.sketch {
				continue
			}
			b.WriteString(`<use href="#q` + itoa(p.ref) + `"`)
			switch {
			case p.fill == "":
				b.WriteString(` fill="none" stroke="` + p.line + `" stroke-width="` + p.sw + `" stroke-opacity="1"`)
				if p.dash {
					b.WriteString(` stroke-dasharray="2 4"`)
				}
			case p.ghost:
				b.WriteString(` fill="` + p.fill + `" stroke="none"`)
			default:
				b.WriteString(` fill="` + p.fill + `"`)
			}
			b.WriteString(`/>`)
		}
		b.WriteString(`</g><path d="M0 0H600V800H0zM40 40V760H560V40z" fill="url(#fr)" fill-rule="evenodd" stroke="` + pg.dark + `" stroke-width="2"/></g>`)
		if lac != "" {
			b.WriteString(`</g>`)
		}
		// the seams between the days: a raised lip of plaster and its shadow
		b.WriteString(`<use href="#dn" fill="none" stroke="#fbf5ea" stroke-opacity=".5" stroke-width="2.4"/><use href="#dn" fill="none" stroke="#5a4434" stroke-opacity=".35" stroke-width=".8"/>`)
		if clip { // today's giornata, its intonaco still wet
			b.WriteString(`<path d="` + relPath(polys[order[k-1]]) + `" fill="#3a2a1a" fill-opacity=".07" stroke="#7a6050" stroke-opacity=".5" stroke-width="1.4"/>`)
		}
	}
	b.WriteString(pent)
	if cracks {
		b.WriteString(`</g>`)
	}
	if lac != "" {
		if fresco { // the broken edge of the intonaco around each loss
			if clip {
				b.WriteString(`<g clip-path="url(#cp)">`)
			} else {
				b.WriteString(`<g>`)
			}
			b.WriteString(`<use href="#lc" fill="none" stroke="#f3ead8" stroke-width="2.5"/></g>`)
		}
		b.WriteString(`<path d="` + core + `" fill="#9c8770" stroke="#e2d4be" stroke-width="1.5"/>`)
	}
	b.WriteString(`<rect width="600" height="800" filter="url(#ar)" opacity=".3"/></svg>`)
	return b.String()
}
