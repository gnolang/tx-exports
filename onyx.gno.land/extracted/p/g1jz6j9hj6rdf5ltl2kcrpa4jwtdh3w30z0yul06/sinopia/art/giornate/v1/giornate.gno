// Package giornate is a Sinopia showcase engine: a fresco wall caught
// mid-work. A fresco is painted on wet plaster one day-patch (giornata) at a
// time, from the top of the wall down. The wall is cut into irregular
// patches by slanted lines; one hidden composition runs under all of them.
// Finished patches show it in pigment, the rest still show the red-ochre
// sinopia underdrawing (outline, hatching, construction lines).
//
// Everything is integer maths (a 64-step quarter-sine table, truncating
// division), so the TypeScript twin in frontend/src/engines/giornate.ts is
// byte-identical. Two RNG streams come from the seed: seed+"|traits" decides
// the traits (cheap, no geometry: Traits never renders) and seed+"|art"
// draws the picture, so art draws never shift traits.
package giornate

import (
	"errors"
	"strconv"
	"strings"

	"gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia/engine/v1"
)

// Trait types in the order Traits returns them.
var traitTypes = []string{"Pigments", "Giornate", "Completion", "Motif", "Hatch", "Construction", "Gilding", "Craquelure", "Rarity"}

// MaxSVGBytes: measured max is 14,663 B over 20,000 default seeds and
// 15,005 B with params (docs/engines/giornate.md); 24 KiB leaves ~1.6x margin.
const MaxSVGBytes = 24576

const paramsSchema = `{"type":"object","additionalProperties":false,"properties":{` +
	`"palette":{"type":"string","title":"Pigments","enum":["Seeded","Terra Verde","Lapis & Ochre","Cinnabar","Pompeian","Umber","Rose Madder","Verdaccio","Giotto Blue"],"default":"Seeded"},` +
	`"stage":{"type":"string","title":"Completion","enum":["Seeded","Pure Sinopia","Fresh Start","Half Wall","Advanced","Nearly Done","Finished"],"default":"Seeded"},` +
	`"patches":{"type":"string","title":"Giornate","enum":["Seeded","Few","Several","Many","Countless"],"default":"Seeded"},` +
	`"grain":{"type":"boolean","title":"Plaster grain","default":true}}}`

// Manifest describes the engine. Author and FeeBps are set by the adapter.
func Manifest() engine.Manifest {
	return engine.Manifest{
		Name:    "Giornate",
		Version: "1.0.0",
		Description: "A fresco wall caught mid-work: finished day-patches (giornate) in pigment, " +
			"the rest still in the red sinopia underdrawing.",
		License:      "TBD",
		ParamsSchema: paramsSchema,
		TraitTypes:   append([]string{}, traitTypes...),
		Living:       false,
		MaxSVGBytes:  MaxSVGBytes,
	}
}

// ---------------------------------------------------------------------------
// Params: "" (the showcase look) or exactly the canonical JSON Studio sends,
// keys in schema order, no whitespace:
//   {"palette":"Seeded","stage":"Pure Sinopia","patches":"Seeded","grain":true}
// "Seeded" leaves that trait to the seed. Anything else is rejected.
// ---------------------------------------------------------------------------

type params struct {
	palette int // index into pigments, -1 = seeded
	stage   int // index into completions, -1 = seeded
	patches int // index into giornate, -1 = seeded
	grain   bool
}

func defaultParams() params { return params{-1, -1, -1, true} }

func parseParams(s string) (params, error) {
	p := defaultParams()
	if s == "" {
		return p, nil
	}
	rest := s
	var v string
	var ok bool
	if rest, ok = lit(rest, `{"palette":"`); !ok {
		return p, errors.New(`giornate params: expected {"palette":"…`)
	}
	if v, rest, ok = str(rest); !ok {
		return p, errors.New("giornate params: bad palette")
	}
	if p.palette, ok = lookup(v, pigmentNames()); !ok {
		return p, errors.New("giornate params: unknown palette " + strconv.Quote(v))
	}
	if rest, ok = lit(rest, `,"stage":"`); !ok {
		return p, errors.New("giornate params: expected stage")
	}
	if v, rest, ok = str(rest); !ok {
		return p, errors.New("giornate params: bad stage")
	}
	if p.stage, ok = lookup(v, stageNames()); !ok {
		return p, errors.New("giornate params: unknown stage " + strconv.Quote(v))
	}
	if rest, ok = lit(rest, `,"patches":"`); !ok {
		return p, errors.New("giornate params: expected patches")
	}
	if v, rest, ok = str(rest); !ok {
		return p, errors.New("giornate params: bad patches")
	}
	if p.patches, ok = lookup(v, bucketNames()); !ok {
		return p, errors.New("giornate params: unknown patches " + strconv.Quote(v))
	}
	switch rest {
	case `,"grain":true}`:
		p.grain = true
	case `,"grain":false}`:
		p.grain = false
	default:
		return p, errors.New("giornate params: expected grain true|false and end of object")
	}
	return p, nil
}

func lit(s, prefix string) (string, bool) {
	if !strings.HasPrefix(s, prefix) {
		return s, false
	}
	return s[len(prefix):], true
}

// str reads a JSON string body up to its closing quote; escapes are never
// needed by the enum values, so a backslash is rejected.
func str(s string) (string, string, bool) {
	for i := 0; i < len(s); i++ {
		switch s[i] {
		case '"':
			return s[:i], s[i+1:], true
		case '\\':
			return "", s, false
		}
	}
	return "", s, false
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

// Traits returns the nine traits of in.Seed under in.Params. It never
// renders: one 8-draw RNG pass and a few table walks.
func Traits(in engine.Input) []engine.Trait {
	t := TraitsWith(in.Seed, in.Params)
	return []engine.Trait{
		{Type: "Pigments", Value: t.Pigments},
		{Type: "Giornate", Value: t.Giornate},
		{Type: "Completion", Value: t.Completion},
		{Type: "Motif", Value: t.Motif},
		{Type: "Hatch", Value: t.Hatch},
		{Type: "Construction", Value: t.Construction},
		{Type: "Gilding", Value: t.Gilding},
		{Type: "Craquelure", Value: t.Craquelure},
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
// Deterministic randomness: FNV-1a over the seed, then splitmix64 (Genesis).
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
// Trait tables. Weights per table sum to 100 (they read as percents); score
// feeds the rarity tier.
// ---------------------------------------------------------------------------

type option struct {
	name   string
	weight int
	score  int
}

type pigment struct {
	option
	plaster, red, dark, wall string
	cols                     []string
}

var pigments = []pigment{
	{option{"Terra Verde", 20, 0}, "#ebe1ca", "#a4432c", "#2f2a22", "#d8c9a4", []string{"#7d8b6a", "#a9b38f", "#c9a96e", "#55634a", "#e6d8b5"}},
	{option{"Lapis & Ochre", 18, 0}, "#ece3cd", "#9e3b26", "#1f2433", "#e2d3ae", []string{"#2f4f8f", "#c8962e", "#e3c27a", "#1c2f5c", "#b9a68a"}},
	{option{"Cinnabar", 15, 0}, "#efe4cc", "#8f3a22", "#2a1d19", "#e8d3b0", []string{"#b5321f", "#e0a25a", "#3a2a24", "#7a2418", "#d9b98c"}},
	{option{"Pompeian", 14, 0}, "#efe3c9", "#9a3a24", "#1d1a17", "#8e1f17", []string{"#1d1a17", "#d9a441", "#f2e6cc", "#5e1510", "#c98a5b"}},
	{option{"Umber", 12, 0}, "#e4d6ba", "#93402a", "#1e1a17", "#c2a77d", []string{"#3b2f28", "#6b5440", "#a68a64", "#e9dcc0", "#8a3b26"}},
	{option{"Rose Madder", 10, 1}, "#f0e5d2", "#a54a3a", "#3a2630", "#efd9c4", []string{"#c46a6a", "#6d3b47", "#e8b4a0", "#9a8a9e", "#f5e9d8"}},
	{option{"Verdaccio", 7, 2}, "#e8e3cf", "#9d4a30", "#34362a", "#c3c3a8", []string{"#6f7258", "#4a4c3a", "#9a9c80", "#e2e0cc", "#8a7a58"}},
	{option{"Giotto Blue", 4, 3}, "#f1e8d4", "#a03e28", "#141d3a", "#2b4c9a", []string{"#e9d8b4", "#c98f3f", "#1a2e66", "#f3ead6", "#8a3f2a"}},
}

// giornate buckets: patch-count ranges in lo/hi.
type bucket struct {
	option
	lo, hi int
}

var giornate = []bucket{
	{option{"Few", 24, 1}, 5, 8},
	{option{"Several", 44, 0}, 9, 14},
	{option{"Many", 24, 1}, 15, 21},
	{option{"Countless", 8, 2}, 22, 30},
}

// completions: pct is the share of patches already painted.
type stage struct {
	option
	pct int
}

var completions = []stage{
	{option{"Fresh Start", 14, 1}, 25},
	{option{"Half Wall", 28, 0}, 50},
	{option{"Advanced", 30, 0}, 70},
	{option{"Nearly Done", 18, 1}, 88},
	{option{"Pure Sinopia", 5, 3}, 0},
	{option{"Finished", 5, 3}, 100},
}

var motifs = []option{
	{"Procession", 24, 0}, {"Tondi", 20, 0}, {"Arcade", 20, 0},
	{"Stair", 14, 1}, {"Mandorla", 14, 1}, {"Annunciation", 8, 2},
}
var hatches = []option{{"Parallel", 50, 0}, {"Cross", 32, 0}, {"Stipple", 18, 1}}
var constructions = []option{{"Axes", 45, 0}, {"Squaring Grid", 35, 0}, {"Compass Arcs", 20, 1}}
var gildings = []option{{"None", 78, 0}, {"Leaf Halos", 17, 1}, {"Gold Ground", 5, 3}}
var craquelures = []option{{"None", 55, 0}, {"Light", 33, 0}, {"Heavy", 12, 2}}

func pigmentNames() []string {
	out := make([]string, len(pigments))
	for i, p := range pigments {
		out[i] = p.name
	}
	return out
}

func stageNames() []string {
	out := make([]string, len(completions))
	for i, c := range completions {
		out[i] = c.name
	}
	return out
}

func bucketNames() []string {
	out := make([]string, len(giornate))
	for i, g := range giornate {
		out[i] = g.name
	}
	return out
}

// pickIndex walks the cumulative weights once.
func pickIndex(r *rng, weights []int) int {
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

func optWeights(t []option) []int {
	out := make([]int, len(t))
	for i, o := range t {
		out[i] = o.weight
	}
	return out
}

// Weights per table, computed once at package init (Traits runs for
// hundreds of tokens per query).
var (
	pigmentW, giornateW, completionW = tableWeights()
	motifW                           = optWeights(motifs)
	hatchW                           = optWeights(hatches)
	constructionW                    = optWeights(constructions)
	gildingW                         = optWeights(gildings)
	craquelureW                      = optWeights(craquelures)
)

func tableWeights() ([]int, []int, []int) {
	pw := make([]int, len(pigments))
	for i, q := range pigments {
		pw[i] = q.weight
	}
	gw := make([]int, len(giornate))
	for i, q := range giornate {
		gw[i] = q.weight
	}
	cw := make([]int, len(completions))
	for i, q := range completions {
		cw[i] = q.weight
	}
	return pw, gw, cw
}

// Tier cut-offs on the score, chosen on a 10,000-seed simulation with
// default params (docs/engines/giornate.md has the distribution).
const (
	scoreMythic    = 8
	scoreLegendary = 6
	scoreRare      = 4
	scoreUncommon  = 2
)

// TraitSet is a decoded seed. The SVG builder and the trait list read the
// same struct, so picture and metadata cannot disagree.
type TraitSet struct {
	Pigments, Giornate, Completion, Motif, Hatch, Construction, Gilding, Craquelure string
	Score                                                                          int
	Rarity                                                                         string

	pig, gio, comp, motif, hatch, cons, gild, craq int // table indices actually used
	grain                                          bool
}

// derive draws all eight picks in a fixed order (the order is part of the
// contract), then applies params. A trait fixed by params or hidden by the
// completion stage adds nothing to the score: rarity only counts what the
// seed chose and the picture shows.
func derive(seed string, p params) TraitSet {
	r := newRNG(seed + "|traits")
	t := TraitSet{
		pig:   pickIndex(r, pigmentW),
		gio:   pickIndex(r, giornateW),
		comp:  pickIndex(r, completionW),
		motif: pickIndex(r, motifW),
		hatch: pickIndex(r, hatchW),
		cons:  pickIndex(r, constructionW),
		gild:  pickIndex(r, gildingW),
		craq:  pickIndex(r, craquelureW),
		grain: p.grain,
	}
	score := 0
	if p.palette >= 0 {
		t.pig = p.palette
	}
	if p.patches >= 0 {
		t.gio = p.patches
	} else {
		score += giornate[t.gio].score
	}
	if p.stage >= 0 {
		t.comp = p.stage
	} else {
		score += completions[t.comp].score
	}
	pct := completions[t.comp].pct
	unpainted := pct == 0  // no pigment and no gold shows
	finished := pct == 100 // no underdrawing shows

	t.Pigments = pigments[t.pig].name
	t.Giornate = giornate[t.gio].name
	t.Completion = completions[t.comp].name
	t.Motif = motifs[t.motif].name
	t.Hatch = hatches[t.hatch].name
	t.Construction = constructions[t.cons].name
	t.Gilding = gildings[t.gild].name
	t.Craquelure = craquelures[t.craq].name
	score += motifs[t.motif].score + craquelures[t.craq].score
	if unpainted {
		t.Pigments = "Unpainted"
		t.Gilding = "None"
	} else {
		score += gildings[t.gild].score
		if p.palette < 0 {
			score += pigments[t.pig].score
		}
	}
	if finished {
		t.Hatch = "None"
		t.Construction = "None"
	} else {
		score += hatches[t.hatch].score + constructions[t.cons].score
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
// Geometry: convex polygons cut by lines, integer maths throughout.
// ---------------------------------------------------------------------------

const (
	cW = 1000
	cH = 1250
)

type pt struct{ x, y int }

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

func itoa(n int) string { return strconv.Itoa(n) }

func pts(p []pt) string {
	var b strings.Builder
	for i, q := range p {
		if i > 0 {
			b.WriteByte(' ')
		}
		b.WriteString(itoa(q.x))
		b.WriteByte(',')
		b.WriteString(itoa(q.y))
	}
	return b.String()
}

// ---------------------------------------------------------------------------
// The hidden composition: element geometry + colour index + halo flag.
// ---------------------------------------------------------------------------

type shape struct {
	g    string // `rect x="…" …` without the leading '<' and the paint
	ci   int
	halo bool
}

func rect(x, y, w, h int) string {
	return `rect x="` + itoa(x) + `" y="` + itoa(y) + `" width="` + itoa(w) + `" height="` + itoa(h) + `"`
}

func circle(cx, cy, rad int) string {
	return `circle cx="` + itoa(cx) + `" cy="` + itoa(cy) + `" r="` + itoa(rad) + `"`
}

func composition(r *rng, motif string) []shape {
	var sh []shape
	add := func(g string, ci int, halo bool) { sh = append(sh, shape{g, ci, halo}) }
	switch motif {
	case "Procession":
		n := r.rr(4, 7)
		gap := (cW - 160) / n
		base := r.rr(1000, 1120)
		add(rect(40, base, 920, cH-base), 3, false)
		for i := 0; i < n; i++ {
			w := gap * 62 / 100
			x := 80 + i*gap + (gap-w)/2
			hgt := r.rr(480, 640)
			y := base - hgt
			add(rect(x, y, w, hgt+20)+` rx="`+itoa(w/2)+`"`, i%3, false)
			hr := w * 30 / 100
			cx := x + w/2
			add(circle(cx, y-hr+10, hr+hr/2), 4, true)
			add(circle(cx, y-hr+10, hr), 2, false)
		}
	case "Tondi":
		n := r.rr(3, 6)
		big := r.rr(260, 360)
		bx := r.rr(380, 620)
		by := r.rr(420, 700)
		add(circle(bx, by, big), 0, true)
		for i := 0; i < n; i++ {
			rad := r.rr(50, 170)
			cx := r.rr(rad, cW-rad)
			cy := r.rr(rad, cH-rad)
			add(circle(cx, cy, rad), 1+i%4, false)
		}
		cx := r.rr(400, 600)
		cy := r.rr(500, 700)
		add(circle(cx, cy, big/3), 2, false)
	case "Arcade":
		n := r.rr(2, 4)
		span := (cW - 120) / n
		top := r.rr(380, 560)
		bot := r.rr(1050, 1180)
		add(rect(0, top-r.rr(140, 220), cW, cH), 3, false)
		for i := 0; i < n; i++ {
			rad := span * r.rr(30, 42) / 100
			cx := 60 + i*span + span/2
			x0, x1 := cx-rad, cx+rad
			add(`path d="M`+itoa(x0)+` `+itoa(bot)+`V`+itoa(top)+`A`+itoa(rad)+` `+itoa(rad)+` 0 0 1 `+
				itoa(x1)+` `+itoa(top)+`V`+itoa(bot)+`Z"`, i%2, false)
			add(circle(cx, top-rad/6, rad/3), 4, true)
		}
		add(rect(0, bot, cW, cH-bot), 2, false)
	case "Stair":
		steps := r.rr(4, 8)
		sw := cW / steps
		sh2 := 700 / steps
		d := "M0 " + itoa(cH)
		for i := 0; i < steps; i++ {
			d += "V" + itoa(cH-120-i*sh2) + "H" + itoa((i+1)*sw)
		}
		d += "V" + itoa(cH) + "Z"
		add(`path d="`+d+`"`, 0, false)
		rad := r.rr(90, 160)
		cx := r.rr(150, 400)
		cy := r.rr(200, 380)
		add(circle(cx, cy, rad), 4, true)
		x := r.rr(500, 700)
		y := r.rr(150, 300)
		w := r.rr(60, 120)
		h := r.rr(300, 500)
		add(rect(x, y, w, h)+` rx="40"`, 1, false)
	case "Mandorla":
		cx := 500
		cy := r.rr(560, 700)
		hh := r.rr(380, 470)
		rr := hh + r.rr(40, 160)
		add(`path d="M`+itoa(cx)+` `+itoa(cy-hh)+`A`+itoa(rr)+` `+itoa(rr)+` 0 0 1 `+itoa(cx)+` `+itoa(cy+hh)+
			`A`+itoa(rr)+` `+itoa(rr)+` 0 0 1 `+itoa(cx)+` `+itoa(cy-hh)+`Z"`, 0, true)
		add(rect(cx-90, cy-hh+170, 180, 2*hh-260)+` rx="90"`, 1, false)
		add(circle(cx, cy-hh+120, 95), 4, true)
		add(circle(cx, cy-hh+120, 60), 2, false)
		for side := -1; side <= 1; side += 2 {
			sx := cx + side*r.rr(320, 390)
			sy := r.rr(200, 320)
			sr := r.rr(50, 90)
			add(circle(sx, sy, sr), 3, false)
		}
	default: // Annunciation
		base := r.rr(1080, 1160)
		add(rect(0, base, cW, cH-base), 3, false)
		add(`path d="M380 `+itoa(base)+`V420A120 120 0 0 1 620 420V`+itoa(base)+`Z"`, 2, false)
		for i, cx := range []int{180, 820} {
			add(rect(cx-80, base-560, 160, 580)+` rx="80"`, i, false)
			add(circle(cx, base-620, 90), 4, true)
			add(circle(cx, base-620, 58), 2, false)
		}
		x1 := r.rr(560, 700)
		y1 := r.rr(560, 760)
		x2 := r.rr(380, 470)
		add(`path d="M0 0L`+itoa(x1)+` `+itoa(y1)+`L`+itoa(x2)+` 0Z"`, 4, true)
	}
	return sh
}

// ---------------------------------------------------------------------------
// SVG
// ---------------------------------------------------------------------------

const gold = "#c9a24a"

// SVGWith renders a seed under params as a standalone SVG document.
func SVGWith(seed, ps string) string {
	t := TraitsWith(seed, ps)
	pg := pigments[t.pig]
	cols := pg.cols
	red, dark := pg.red, pg.dark
	r := newRNG(seed + "|art")

	// 1. the wall, cut into day-patches
	g := giornate[t.gio]
	polys := subdivide(r, r.rr(g.lo, g.hi))
	n := len(polys)

	// 2. painted top-down: the highest centroids first, with some jitter
	key := make([]int, n)
	order := make([]int, n)
	for i, p := range polys {
		sy := 0
		for _, q := range p {
			sy += q.y
		}
		key[i] = sy/len(p) + r.rr(0, 260)
		order[i] = i
	}
	for i := 1; i < n; i++ { // stable insertion sort
		for j := i; j > 0 && key[order[j-1]] > key[order[j]]; j-- {
			order[j-1], order[j] = order[j], order[j-1]
		}
	}
	k := (n*completions[t.comp].pct + 50) / 100
	painted := make([]bool, n)
	for i := 0; i < k; i++ {
		painted[order[i]] = true
	}

	motif := motifs[t.motif].name
	hatch := hatches[t.hatch].name
	cons := constructions[t.cons].name
	gild := gildings[t.gild].name
	shapes := composition(r, motif)
	hz := r.rr(380, 640)
	fr := r.rr(50, 70)
	rot := 45
	if hatch == "Parallel" {
		rot = r.rr(30, 60)
	}
	grainSeed := r.rr(1, 999)

	var b strings.Builder
	b.WriteString(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1000 1250" width="1000" height="1250">`)
	sinopia := k < n
	fresco := k > 0
	if sinopia || t.grain {
		b.WriteString(`<defs>`)
	}
	if sinopia {
		switch hatch {
		case "Stipple":
			b.WriteString(`<pattern id="h" width="14" height="14" patternUnits="userSpaceOnUse"><circle cx="4" cy="4" r="2.2" fill="` +
				red + `" opacity=".6"/><circle cx="11" cy="10" r="1.6" fill="` + red + `" opacity=".5"/></pattern>`)
		case "Cross":
			b.WriteString(`<pattern id="h" width="16" height="16" patternUnits="userSpaceOnUse" patternTransform="rotate(45)"><path d="M0 0V16M0 0H16" stroke="` +
				red + `" stroke-width="2.5" opacity=".5"/></pattern>`)
		default:
			b.WriteString(`<pattern id="h" width="16" height="16" patternUnits="userSpaceOnUse" patternTransform="rotate(` + itoa(rot) +
				`)"><path d="M0 0V16" stroke="` + red + `" stroke-width="3" opacity=".55"/></pattern>`)
		}
	}
	if t.grain {
		b.WriteString(`<filter id="t" x="0" y="0" width="100%" height="100%"><feTurbulence type="fractalNoise" baseFrequency=".9" numOctaves="2" seed="` +
			itoa(grainSeed) + `"/><feColorMatrix values="0 0 0 0 .35 0 0 0 0 .3 0 0 0 0 .25 0 0 0 .55 0"/></filter>`)
	}
	if sinopia && fresco {
		for pass := 0; pass < 2; pass++ {
			if pass == 0 {
				b.WriteString(`<clipPath id="P">`)
			} else {
				b.WriteString(`<clipPath id="S">`)
			}
			for i, p := range polys {
				if painted[i] == (pass == 0) {
					b.WriteString(`<polygon points="` + pts(p) + `"/>`)
				}
			}
			b.WriteString(`</clipPath>`)
		}
	}
	if sinopia || t.grain {
		b.WriteString(`</defs>`)
	}
	b.WriteString(`<rect width="1000" height="1250" fill="` + pg.plaster + `"/>`)

	// 3. sinopia layer: the unfinished patches
	if sinopia {
		if fresco {
			b.WriteString(`<g clip-path="url(#S)">`)
		} else {
			b.WriteString(`<g>`)
		}
		switch cons {
		case "Squaring Grid":
			step := r.rr(100, 140)
			b.WriteString(`<path d="`)
			for x := step; x < cW; x += step {
				b.WriteString("M" + itoa(x) + " 0V1250")
			}
			for y := step; y < cH; y += step {
				b.WriteString("M0 " + itoa(y) + "H1000")
			}
			b.WriteString(`" stroke="` + red + `" stroke-width="1.5" opacity=".45"/>`)
		case "Compass Arcs":
			cx := r.rr(300, 700)
			cy := r.rr(300, 900)
			step := r.rr(110, 170)
			b.WriteString(`<g fill="none" stroke="` + red + `" stroke-width="1.5" opacity=".45">`)
			for rad := 120; rad < 1300; rad += step {
				b.WriteString(`<` + circle(cx, cy, rad) + `/>`)
			}
			b.WriteString(`</g>`)
		}
		b.WriteString(`<path d="M0 ` + itoa(fr) + `H1000M0 ` + itoa(cH-fr) + `H1000M0 ` + itoa(hz) + `H1000" stroke="` + red +
			`" stroke-width="3" opacity=".6"/>`)
		b.WriteString(`<path d="M500 0V1250M0 416H1000M0 833H1000M0 0L1000 1250M1000 0L0 1250" stroke="` + red +
			`" stroke-width="2" opacity=".5"/>`)
		for i, s := range shapes {
			fill := "none"
			if i%2 == 0 {
				fill = "url(#h)"
			}
			b.WriteString(`<` + s.g + ` fill="` + fill + `" stroke="` + red + `" stroke-width="5" stroke-linejoin="round"/>`)
			dx := r.rr(-9, 9)
			dy := r.rr(-9, 9)
			b.WriteString(`<` + s.g + ` fill="none" stroke="` + red + `" stroke-width="2" opacity=".5" transform="translate(` +
				itoa(dx) + ` ` + itoa(dy) + `)"/>`)
		}
		b.WriteString(`</g>`)
	}

	// 4. fresco layer: the finished giornate
	if fresco {
		if sinopia {
			b.WriteString(`<g clip-path="url(#P)">`)
		} else {
			b.WriteString(`<g>`)
		}
		if gild == "Gold Ground" {
			b.WriteString(`<rect width="1000" height="1250" fill="` + gold + `"/>`)
		} else {
			b.WriteString(`<rect width="1000" height="1250" fill="` + pg.wall + `"/><rect width="1000" height="` + itoa(hz) +
				`" fill="` + cols[3] + `"/><rect y="` + itoa(hz-14) + `" width="1000" height="14" fill="` + cols[2] + `"/>`)
		}
		for _, s := range shapes {
			fill := cols[s.ci%5]
			if s.halo && gild != "None" {
				fill = gold
			}
			b.WriteString(`<` + s.g + ` fill="` + fill + `" stroke="` + dark + `" stroke-width="3" stroke-opacity=".35"/>`)
		}
		b.WriteString(`<path d="M0 0H1000V` + itoa(fr) + `H0ZM0 ` + itoa(cH-fr) + `H1000V1250H0Z" fill="` + dark + `"/>`)
		b.WriteString(`<path d="`)
		for x := 10; x < cW; x += 125 {
			b.WriteString(`M` + itoa(x) + ` 10h115v` + itoa(fr-20) + `h-115zM` + itoa(x) + ` ` + itoa(cH-fr+10) + `h115v` + itoa(fr-20) + `h-115z`)
		}
		b.WriteString(`" fill="` + cols[1] + `"/><g fill="` + cols[2] + `">`)
		for x := 67; x < cW; x += 125 {
			b.WriteString(`<` + circle(x, fr/2, 9) + `/><` + circle(x, cH-fr/2, 9) + `/>`)
		}
		b.WriteString(`</g>`)
		if gild != "None" {
			for _, s := range shapes {
				if s.halo {
					b.WriteString(`<` + s.g + ` fill="none" stroke="#8a6a24" stroke-width="3"/>`)
				}
			}
		}
		if sinopia {
			// today's giornata: the last painted patch, its intonaco still wet
			b.WriteString(`<polygon points="` + pts(polys[order[k-1]]) + `" fill="` + dark + `" opacity=".09"/>`)
		}
		b.WriteString(`</g>`)
	}

	// 5. seams between the days, then cracks, then plaster grain
	b.WriteString(`<path d="`)
	for _, p := range polys {
		for i, q := range p {
			if i == 0 {
				b.WriteString("M")
			} else {
				b.WriteString("L")
			}
			b.WriteString(itoa(q.x) + "," + itoa(q.y))
		}
		b.WriteString("Z")
	}
	b.WriteString(`" fill="none" stroke="` + dark + `" stroke-width="2.5" opacity=".35" stroke-linejoin="round"/>`)
	cracks := 0
	switch craquelures[t.craq].name {
	case "Light":
		cracks = 7
	case "Heavy":
		cracks = 20
	}
	if cracks > 0 {
		b.WriteString(`<path d="`)
		for c := 0; c < cracks; c++ {
			x := r.rr(0, cW)
			y := r.rr(0, cH)
			b.WriteString("M" + itoa(x) + " " + itoa(y))
			a := r.intn(256)
			segs := r.rr(5, 12)
			for s := 0; s < segs; s++ {
				a += r.rr(-24, 24)
				ln := r.rr(14, 46)
				x += icos(a) * ln / 1024
				y += isin(a) * ln / 1024
				b.WriteString("L" + itoa(x) + " " + itoa(y))
			}
		}
		b.WriteString(`" fill="none" stroke="` + dark + `" stroke-width="1.6" opacity=".45"/>`)
	}
	if t.grain {
		b.WriteString(`<rect width="1000" height="1250" filter="url(#t)" opacity=".5"/>`)
	}
	b.WriteString(`</svg>`)
	return b.String()
}
