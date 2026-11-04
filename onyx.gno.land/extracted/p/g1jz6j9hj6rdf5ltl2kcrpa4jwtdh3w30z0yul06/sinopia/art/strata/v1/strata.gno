// Package strata is a Sinopia engine: cross-sections of an invented earth.
// Sediment beds are folded by a two-term integer sine field and cut by
// faults (each fault block shows the same bed drawing shifted by its throw
// inside a clip polygon), crossed by dikes and sills, sometimes truncated by
// an angular unconformity. Beds are drawn top to bottom and each is filled
// from its top surface down, so a bed costs one curve.
//
// The RNG stream, tables, draw order and geometry are the prototype's
// (koleksiyon-fikirleri/strata/strata.py) for empty params; the only output
// change is that curves are written with relative steps (same points, ~20%
// fewer bytes, so less render and allowlist gas). The pre-change port was
// checked byte for byte against the prototype on 2,011 seeds. Pure integer
// maths: no floats, no time, no block data.
package strata

import (
	"errors"
	"strconv"
	"strings"

	"gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia/engine/v1"
)

// traitTypes in the order Traits returns them.
var traitTypes = []string{"Era", "Section", "Folding", "Faults", "Intrusion", "Bedding", "Unconformity", "Fossil", "Rarity"}

// MaxSVGBytes: the largest output measured is 17,083 B (3,000 seeds x the
// heaviest params; 15,657 B over 3,000 default seeds, docs/engines/strata.md);
// this leaves ~1.4x.
const MaxSVGBytes = 24576

// ParamsSchema is the Studio form. "Any" (the default) leaves the trait to
// the seed; any other value fixes it for the whole collection. Params are
// the canonical JSON Studio sends (all four keys, schema order), or "".
const ParamsSchema = `{"type":"object","properties":{` +
	`"era":{"type":"string","title":"Era (palette)","enum":["Any","Sinopia Redbeds","Ochre Coast","Painted Desert","Chalk Cliff","Terra Verde","Basalt Coast","Lapis Vein"],"default":"Any"},` +
	`"section":{"type":"string","title":"Section","enum":["Any","Cliff","Outcrop","Cores"],"default":"Any"},` +
	`"bedding":{"type":"string","title":"Bedding","enum":["Any","Massive","Bedded","Laminated"],"default":"Any"},` +
	`"folding":{"type":"string","title":"Folding","enum":["Any","Flat","Gentle","Folded","Contorted"],"default":"Any"}}}`

// Manifest describes the engine. Author and FeeBps are set by the adapter
// realm that registers it.
func Manifest() engine.Manifest {
	return engine.Manifest{
		Name:         "Strata",
		Version:      "1.0.0",
		Description:  "Cross-sections of an invented earth: folded red beds, faults, dikes and unconformities in earth pigments.",
		License:      "TBD",
		ParamsSchema: ParamsSchema,
		TraitTypes:   append([]string{}, traitTypes...),
		Living:       false,
		MaxSVGBytes:  MaxSVGBytes,
	}
}

// ValidateParams accepts "" and the canonical params JSON only.
func ValidateParams(params string) error {
	_, err := parseParams(params)
	return err
}

// Traits returns the nine traits of in.Seed under in.Params, in TraitTypes
// order. It never renders.
func Traits(in engine.Input) []engine.Trait {
	t := TraitsWith(in.Seed, in.Params)
	return []engine.Trait{
		{Type: "Era", Value: t.Era},
		{Type: "Section", Value: t.Section},
		{Type: "Folding", Value: t.Folding},
		{Type: "Faults", Value: t.Faults},
		{Type: "Intrusion", Value: t.Intrusion},
		{Type: "Bedding", Value: t.Bedding},
		{Type: "Unconformity", Value: t.Unconformity},
		{Type: "Fossil", Value: t.Fossil},
		{Type: "Rarity", Value: t.Rarity},
	}
}

// Render returns the raw SVG for in.Seed under in.Params.
func Render(in engine.Input) string { return SVGWith(in.Seed, in.Params) }

// ---------------------------------------------------------------------------
// Params
// ---------------------------------------------------------------------------

// params holds a fixed table index per overridable trait, -1 = by seed.
type params struct {
	era, section, bedding, folding int
}

var paramKeys = []string{"era", "section", "bedding", "folding"}

// paramLeads[i] is the canonical text before the i-th value.
var paramLeads = []string{`{"era":"`, `,"section":"`, `,"bedding":"`, `,"folding":"`}

func parseParams(s string) (params, error) {
	p := params{-1, -1, -1, -1}
	if s == "" {
		return p, nil
	}
	tables := [][]option{eras, sections, beddings, foldings}
	got := []int{-1, -1, -1, -1}
	rest := s
	for i, k := range paramKeys {
		lead := paramLeads[i]
		if !strings.HasPrefix(rest, lead) {
			return p, errors.New("strata params: want canonical JSON {\"era\",\"section\",\"bedding\",\"folding\"}")
		}
		rest = rest[len(lead):]
		j := strings.IndexByte(rest, '"')
		if j < 0 {
			return p, errors.New("strata params: unterminated value for " + k)
		}
		v := rest[:j]
		rest = rest[j+1:]
		if v == "Any" {
			continue
		}
		idx := -1
		for n, o := range tables[i] {
			if o.name == v {
				idx = n
				break
			}
		}
		if idx < 0 {
			return p, errors.New("strata params: unknown " + k + " value")
		}
		got[i] = idx
	}
	if rest != "}" {
		return p, errors.New("strata params: trailing data")
	}
	return params{got[0], got[1], got[2], got[3]}, nil
}

func mustParams(s string) params {
	p, err := parseParams(s)
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
// Weighted trait tables. Weights sum to 100, so a weight reads as a percent.
// lo/hi are the art ranges a trait sets (bed count, fold amplitude, faults).
// ---------------------------------------------------------------------------

type option struct {
	name   string
	weight int
	score  int // contribution to the rarity score
	lo, hi int
}

func pick(r *rng, table []option) int {
	total := 0
	for _, o := range table {
		total += o.weight
	}
	x := r.n(total)
	for i, o := range table {
		x -= o.weight
		if x < 0 {
			return i
		}
	}
	return len(table) - 1
}

var eras = []option{
	{"Sinopia Redbeds", 22, 0, 0, 0},
	{"Ochre Coast", 18, 0, 0, 0},
	{"Painted Desert", 16, 0, 0, 0},
	{"Chalk Cliff", 14, 1, 0, 0},
	{"Terra Verde", 12, 1, 0, 0},
	{"Basalt Coast", 12, 1, 0, 0},
	{"Lapis Vein", 6, 3, 0, 0},
}

var eraCols = [][]string{
	{"#8e3b25", "#b4573a", "#d08a5c", "#e8c4a0", "#6e2a1c", "#c9a27a"},
	{"#c8962e", "#e3c27a", "#a8692e", "#f0dfb8", "#7a4a22", "#d6a85a"},
	{"#b5523b", "#e0a07a", "#efd8b8", "#8c5a7a", "#c97a4a", "#6a3a4a"},
	{"#efeadf", "#d8d2c4", "#bfb6a3", "#f7f4ec", "#8e8676", "#e4ddce"},
	{"#6f7a55", "#9aa27a", "#c4c39a", "#4e573c", "#d9d3b0", "#8a8458"},
	{"#2a2a2c", "#45403c", "#6a625a", "#8d8378", "#1a1a1b", "#b0a898"},
	{"#2c3340", "#3d4757", "#56657a", "#1f2430", "#7a8aa0", "#2b4fa8"},
}

var eraDark = []string{"#2a2a2c", "#3a3a3a", "#2a2622", "#3a3a3a", "#2a2a2c", "#e8e2d4", "#e8d9a8"}

var sections = []option{
	{"Cliff", 45, 0, 0, 0},
	{"Outcrop", 35, 0, 0, 0},
	{"Cores", 20, 1, 0, 0},
}

var foldings = []option{
	{"Flat", 22, 0, 0, 10},
	{"Gentle", 36, 0, 20, 60},
	{"Folded", 28, 1, 70, 130},
	{"Contorted", 14, 2, 140, 210},
}

var faultsT = []option{
	{"0", 38, 0, 0, 0},
	{"1", 34, 0, 1, 0},
	{"2", 20, 1, 2, 0},
	{"3", 8, 2, 3, 0},
}

var intrusions = []option{
	{"None", 52, 0, 0, 0},
	{"Dike", 20, 1, 0, 0},
	{"Sill", 14, 1, 0, 0},
	{"Dike & Sill", 8, 2, 0, 0},
	{"Vein Swarm", 6, 3, 0, 0},
}

var beddings = []option{
	{"Massive", 25, 0, 7, 10},
	{"Bedded", 50, 0, 12, 18},
	{"Laminated", 25, 1, 22, 30},
}

var unconfs = []option{
	{"None", 84, 0, 0, 0},
	{"Angular", 16, 2, 0, 0},
}

var fossils = []option{
	{"None", 88, 0, 0, 0},
	{"Ammonite", 12, 2, 0, 0},
}

// Rarity cut-offs on the summed score (20,000-seed simulation, empty params):
// Common 39.9% / Uncommon 37.7% / Rare 17.6% / Legendary 4.2% / Mythic 0.6%.
const (
	scoreMythic    = 9
	scoreLegendary = 7
	scoreRare      = 5
	scoreUncommon  = 3
)

// TraitSet is the decoded properties of a seed. The SVG builder and the
// trait list both read it, so picture and metadata cannot disagree.
type TraitSet struct {
	Era          string
	Section      string
	Folding      string
	Faults       string
	Intrusion    string
	Bedding      string
	Unconformity string
	Fossil       string
	Score        int
	Rarity       string
}

type derived struct {
	era, section, folding, faults, intrusion, bedding, unconf, fossil int
}

// derive draws every trait from seed+"|traits" in the prototype's order,
// then applies the params. Forced traits are still drawn, so fixing one
// trait never shifts the others.
func derive(seed string, p params) derived {
	r := newRNG(seed + "|traits")
	d := derived{
		era:       pick(r, eras),
		section:   pick(r, sections),
		folding:   pick(r, foldings),
		faults:    pick(r, faultsT),
		intrusion: pick(r, intrusions),
		bedding:   pick(r, beddings),
		unconf:    pick(r, unconfs),
		fossil:    pick(r, fossils),
	}
	if p.era >= 0 {
		d.era = p.era
	}
	if p.section >= 0 {
		d.section = p.section
	}
	if p.bedding >= 0 {
		d.bedding = p.bedding
	}
	if p.folding >= 0 {
		d.folding = p.folding
	}
	return d
}

func (d derived) traitSet() TraitSet {
	t := TraitSet{
		Era:          eras[d.era].name,
		Section:      sections[d.section].name,
		Folding:      foldings[d.folding].name,
		Faults:       faultsT[d.faults].name,
		Intrusion:    intrusions[d.intrusion].name,
		Bedding:      beddings[d.bedding].name,
		Unconformity: unconfs[d.unconf].name,
		Fossil:       fossils[d.fossil].name,
	}
	score := eras[d.era].score + sections[d.section].score + foldings[d.folding].score +
		faultsT[d.faults].score + intrusions[d.intrusion].score + beddings[d.bedding].score +
		unconfs[d.unconf].score + fossils[d.fossil].score
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

// TraitsOf returns the traits of a seed under default params.
func TraitsOf(seed string) TraitSet { return derive(seed, params{-1, -1, -1, -1}).traitSet() }

// TraitsWith returns the traits of a seed under params; it panics on
// params ValidateParams rejects.
func TraitsWith(seed, ps string) TraitSet { return derive(seed, mustParams(ps)).traitSet() }

// TraitString is "Type=Value;..." in TraitTypes order (golden vectors).
func TraitString(seed, ps string) string {
	t := TraitsWith(seed, ps)
	vals := []string{t.Era, t.Section, t.Folding, t.Faults, t.Intrusion, t.Bedding, t.Unconformity, t.Fossil, t.Rarity}
	var b strings.Builder
	for i, v := range vals {
		if i > 0 {
			b.WriteString(";")
		}
		b.WriteString(traitTypes[i])
		b.WriteString("=")
		b.WriteString(v)
	}
	return b.String()
}

// ---------------------------------------------------------------------------
// Integer trigonometry: a quarter-wave table, 256 steps per turn, x1024.
// ---------------------------------------------------------------------------

var quarter = []int{0, 25, 50, 75, 100, 125, 150, 175, 200, 224, 249, 273, 297, 321, 345, 369, 392, 415, 438, 460,
	483, 505, 526, 548, 569, 590, 610, 630, 650, 669, 688, 706, 724, 742, 759, 775, 792, 807, 822,
	837, 851, 865, 878, 891, 903, 915, 926, 936, 946, 955, 964, 972, 980, 987, 993, 999, 1004, 1009,
	1013, 1016, 1019, 1021, 1023, 1024, 1024}

func isin(a int) int {
	a %= 256 // Euclidean, as the prototype's Python %
	if a < 0 {
		a += 256
	}
	switch {
	case a < 64:
		return quarter[a]
	case a < 128:
		return quarter[128-a]
	case a < 192:
		return -quarter[a-128]
	}
	return -quarter[256-a]
}

func icos(a int) int { return isin(a + 64) }

// ---------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------

const (
	canvas = 1000
	step   = 25
	npts   = canvas/step + 1 // 41 sample columns, x = 0, 25, ... 1000
)

const hexDigits = "0123456789abcdef"

func hexVal(c byte) int {
	if c >= 'a' {
		return int(c-'a') + 10
	}
	return int(c - '0')
}

// shade adds d to each channel of "#rrggbb", clamped to 0..255.
func shade(c string, d int) string {
	out := []byte{'#', 0, 0, 0, 0, 0, 0}
	for i := 0; i < 3; i++ {
		v := hexVal(c[1+2*i])*16 + hexVal(c[2+2*i]) + d
		if v < 0 {
			v = 0
		}
		if v > 255 {
			v = 255
		}
		out[1+2*i] = hexDigits[v/16]
		out[2+2*i] = hexDigits[v%16]
	}
	return string(out)
}

type art struct {
	b    strings.Builder
	tilt int
	p2   int
}

func (a *art) curve(base, amp, ph, fr1, fr2 int) []int {
	ys := make([]int, npts)
	amp3 := amp / 3
	for i := 0; i < npts; i++ {
		x := i * step
		y := base + a.tilt*(x-500)/1000
		y += amp * isin(fr1*x*256/2000+ph) / 1024
		y += amp3 * isin(fr2*x*256/2000+a.p2) / 1024
		ys[i] = y
	}
	return ys
}

func wInt(b *strings.Builder, n int) { b.WriteString(strconv.Itoa(n)) }

func wPt(b *strings.Builder, x, y int) {
	b.WriteString(strconv.Itoa(x))
	b.WriteString(" ")
	b.WriteString(strconv.Itoa(y))
}

// wRel writes the relative pairs "dx dy dx dy..." that follow an `l`
// between consecutive ys; a negative dy needs no separator.
func wRel(b *strings.Builder, ys []int, dx string) {
	for i := 1; i < len(ys); i++ {
		if i > 1 {
			b.WriteString(" ")
		}
		b.WriteString(dx)
		d := ys[i] - ys[i-1]
		if d >= 0 {
			b.WriteString(" ")
		}
		b.WriteString(strconv.Itoa(d))
	}
}

// wPts writes a full curve from x = 0: the absolute first point, then
// relative 25 px steps (same geometry as absolute points, ~20% fewer bytes).
func wPts(b *strings.Builder, ys []int) {
	b.WriteString("0 ")
	b.WriteString(strconv.Itoa(ys[0]))
	b.WriteString("l")
	wRel(b, ys, "25")
}

// wRibbon writes the closed shape from a curve down past the canvas.
func wRibbon(b *strings.Builder, ys []int) {
	b.WriteString("M-400 2400L-400 ")
	wInt(b, ys[0])
	b.WriteString("L")
	wPts(b, ys)
	b.WriteString("L1400 ")
	wInt(b, ys[len(ys)-1])
	b.WriteString("L1400 2400Z")
}

// SVG renders a seed under default params.
func SVG(seed string) string { return render(seed, params{-1, -1, -1, -1}) }

// SVGWith renders a seed under params; it panics on params ValidateParams
// rejects.
func SVGWith(seed, ps string) string { return render(seed, mustParams(ps)) }

func render(seed string, p params) string {
	d := derive(seed, p)
	r := newRNG(seed + "|art")
	cols, dark := eraCols[d.era], eraDark[d.era]
	eraName := eras[d.era].name
	section := sections[d.section].name

	nb := r.rr(beddings[d.bedding].lo, beddings[d.bedding].hi)
	amp := r.rr(foldings[d.folding].lo, foldings[d.folding].hi)
	f1 := r.rr(2, 5)
	f2 := r.rr(6, 14)
	p1 := r.n(256)
	p2 := r.n(256)
	tilt := r.rr(-160, 160)
	a := &art{tilt: tilt, p2: p2}
	top := -260
	if section == "Outcrop" {
		top = 230
	}
	span := 1300 - top

	// bed colours walk the palette with occasional repeats (cyclothems)
	seqc := make([]string, nb+1)
	for k := 0; k <= nb; k++ {
		m := r.rr(1, 3)
		seqc[k] = cols[(k*m+r.n(2))%len(cols)]
	}
	patt := make([]int, nb+1) // 0,1 plain; 2 sandstone, 3 shale, 4 conglomerate
	for k := 0; k <= nb; k++ {
		patt[k] = r.n(5)
	}
	thick := make([]int, nb)
	tsum := 0
	for k := 0; k < nb; k++ {
		thick[k] = r.rr(4, 14)
		tsum += thick[k]
	}
	beds := make([][]int, nb)
	acc := 0
	for k := 0; k < nb; k++ {
		base := top + span*acc/tsum
		if k == 0 {
			base -= 300
		}
		acc += thick[k]
		ak := amp + amp*k/(nb*2) // deeper beds fold more
		beds[k] = a.curve(base, ak, p1+k*r.rr(0, 3), f1, f2)
	}

	b := &a.b
	b.WriteString(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1000 1000" width="1000" height="1000"><defs>`)
	b.WriteString(`<pattern id="s" width="12" height="12" patternUnits="userSpaceOnUse"><circle cx="3" cy="3" r="1.4" fill="#000" opacity=".22"/>` +
		`<circle cx="9" cy="8" r="1" fill="#fff" opacity=".25"/></pattern>`)
	b.WriteString(`<pattern id="h" width="40" height="7" patternUnits="userSpaceOnUse"><path d="M0 3.5H28" stroke="#000" stroke-width="1.2" opacity=".2"/></pattern>`)
	b.WriteString(`<pattern id="c" width="34" height="30" patternUnits="userSpaceOnUse"><ellipse cx="9" cy="9" rx="7" ry="5" fill="#fff" opacity=".22"/>` +
		`<ellipse cx="25" cy="22" rx="5" ry="4" fill="#000" opacity=".18"/></pattern>`)

	// g: the block drawing (beds, unconformity, intrusions, fossil), shown
	// once per fault block through <use>.
	g := &strings.Builder{}
	for k := 0; k < nb; k++ {
		col := seqc[k]
		g.WriteString(`<g fill="`)
		g.WriteString(col)
		g.WriteString(`"><path id="r`)
		wInt(g, k)
		g.WriteString(`" d="`)
		wRibbon(g, beds[k])
		g.WriteString(`" stroke="`)
		g.WriteString(shade(col, -45))
		g.WriteString(`" stroke-width="2"/></g>`)
		if patt[k] >= 2 {
			g.WriteString(`<use href="#r`)
			wInt(g, k)
			g.WriteString(`" fill="url(#`)
			g.WriteString("shc"[patt[k]-2 : patt[k]-1])
			g.WriteString(`)"/>`)
		}
	}
	if unconfs[d.unconf].name == "Angular" {
		ey := top + span*r.rr(28, 42)/100
		ea := r.rr(8, 20)
		eph := r.n(256)
		er := a.curve(ey, ea, eph, 1, 3)
		b.WriteString(`<clipPath id="u"><path d="`)
		wRibbon(b, er)
		b.WriteString(`"/></clipPath>`)
		ng := r.rr(3, 6)
		ng2 := &strings.Builder{}
		for k := 0; k < ng; k++ {
			fy := top - 300
			if k > 0 {
				fy = top + (ey-top)*k/ng
			}
			fc := make([]int, 11)
			for i := 0; i < 11; i++ {
				fc[i] = fy + tilt*(i*100-500)/4000
			}
			ng2.WriteString(`<path d="M-400 2400L-400 `)
			wInt(ng2, fc[0])
			ng2.WriteString("L")
			for i, y := range fc {
				if i > 0 {
					ng2.WriteString("L")
				}
				wPt(ng2, i*100, y)
			}
			ng2.WriteString("L1400 ")
			wInt(ng2, fc[10])
			ng2.WriteString(`L1400 2400Z" fill="`)
			ng2.WriteString(cols[(k*2+1)%len(cols)])
			ng2.WriteString(`"/>`)
		}
		ng2.WriteString(`<g clip-path="url(#u)">`)
		ng2.WriteString(g.String())
		ng2.WriteString(`</g><path d="M`)
		wPts(ng2, er)
		ng2.WriteString(`" fill="none" stroke="`)
		ng2.WriteString(dark)
		ng2.WriteString(`" stroke-width="3" opacity=".6"/>`)
		g = ng2
	}

	// intrusions belong to the block before faulting
	intr := intrusions[d.intrusion].name
	if intr == "Sill" || intr == "Dike & Sill" {
		k := r.rr(2, nb-2)
		c := beds[k]
		th := r.rr(18, 40)
		g.WriteString(`<path d="M`)
		wPts(g, c)
		g.WriteString("L1000 ")
		wInt(g, c[npts-1]+th)
		g.WriteString("l")
		back := make([]int, npts)
		for i := range back {
			back[i] = c[npts-1-i]
		}
		wRel(g, back, "-25")
		g.WriteString(`Z" fill="`)
		g.WriteString(dark)
		g.WriteString(`"/>`)
	}
	if intr == "Dike" || intr == "Dike & Sill" {
		x0 := r.rr(150, 850)
		dx := r.rr(-200, 200)
		w := r.rr(24, 60)
		g.WriteString(`<path d="M`)
		wInt(g, x0)
		g.WriteString(` -400L`)
		wInt(g, x0+w)
		g.WriteString(` -400L`)
		wInt(g, x0+w+dx)
		g.WriteString(` 1400L`)
		wInt(g, x0+dx)
		g.WriteString(` 1400Z" fill="`)
		g.WriteString(dark)
		g.WriteString(`"/>`)
	}
	if intr == "Vein Swarm" {
		g.WriteString(`<path d="`)
		nv := r.rr(10, 18)
		for v := 0; v < nv; v++ {
			x := r.rr(0, canvas)
			y := r.rr(0, canvas)
			g.WriteString("M")
			wPt(g, x, y)
			g.WriteString("l")
			wPt(g, r.rr(-60, 60), r.rr(-200, 200))
			g.WriteString("l")
			wPt(g, r.rr(-40, 40), r.rr(-120, 120))
		}
		g.WriteString(`" fill="none" stroke="`)
		if eraName == "Lapis Vein" {
			g.WriteString(cols[5])
		} else {
			g.WriteString("#f4efe4")
		}
		g.WriteString(`" stroke-width="3" opacity=".85"/>`)
	}
	if fossils[d.fossil].name == "Ammonite" {
		k := r.rr(2, nb-1)
		c := beds[k]
		i := r.rr(6, npts-7)
		fx := i * step
		fy := c[i] + r.rr(30, 60)
		path := &strings.Builder{}
		ribs := &strings.Builder{}
		path.WriteString("M")
		wPt(path, fx, fy)
		rad, ang := 2, 0
		for rad < 46 {
			ang += 12
			rad++
			px := fx + icos(ang)*rad/1024
			py := fy + isin(ang)*rad/1024
			path.WriteString("L")
			wPt(path, px, py)
			if ang%24 == 0 && rad > 12 {
				ribs.WriteString("M")
				wPt(ribs, px, py)
				ribs.WriteString("L")
				wPt(ribs, fx+icos(ang)*(rad-9)/1024, fy+isin(ang)*(rad-9)/1024)
			}
		}
		g.WriteString(`<circle cx="`)
		wInt(g, fx)
		g.WriteString(`" cy="`)
		wInt(g, fy)
		g.WriteString(`" r="`)
		wInt(g, rad)
		g.WriteString(`" fill="`)
		g.WriteString(cols[3])
		g.WriteString(`" opacity=".9"/><path d="`)
		g.WriteString(path.String())
		g.WriteString(ribs.String())
		g.WriteString(`" fill="none" stroke="`)
		g.WriteString(dark)
		g.WriteString(`" stroke-width="2.5"/>`)
	}
	b.WriteString(`<g id="b">`)
	b.WriteString(g.String())
	b.WriteString(`</g>`)

	// fault blocks: polygons between fault lines, each with its own throw
	nf := faultsT[d.faults].lo
	div := nf
	if div < 1 {
		div = 1
	}
	fxs := make([]int, nf)
	fds := make([]int, nf)
	for k := 0; k < nf; k++ {
		fxs[k] = r.rr(120+760*k/div, 120+760*(k+1)/div)
		fds[k] = r.rr(-180, 180)
	}
	// sort by (x, throw), as the prototype's sorted() of tuples
	for i := 1; i < nf; i++ {
		for j := i; j > 0 && (fxs[j] < fxs[j-1] || (fxs[j] == fxs[j-1] && fds[j] < fds[j-1])); j-- {
			fxs[j], fxs[j-1] = fxs[j-1], fxs[j]
			fds[j], fds[j-1] = fds[j-1], fds[j]
		}
	}
	throws := make([]int, nf+1)
	px0, px1 := -10, -10 // previous fault line: top x, bottom x
	throw := 0
	for k := 0; k <= nf; k++ {
		cx0, cx1 := canvas+10, canvas+10
		if k < nf {
			cx0, cx1 = fxs[k]+fds[k], fxs[k]-fds[k]
		}
		b.WriteString(`<clipPath id="f`)
		wInt(b, k)
		b.WriteString(`"><path d="M`)
		wPt(b, px0, -10)
		b.WriteString("L")
		wPt(b, cx0, -10)
		b.WriteString("L")
		wPt(b, cx1, canvas+10)
		b.WriteString("L")
		wPt(b, px1, canvas+10)
		b.WriteString(`Z"/></clipPath>`)
		throws[k] = throw
		px0, px1 = cx0, cx1
		m := r.rr(30, 140)
		if r.n(2) != 0 {
			throw += m
		} else {
			throw -= m
		}
	}
	if section == "Cores" {
		b.WriteString(`<clipPath id="k">`)
		writeCoreRects(b)
		b.WriteString(`</clipPath>`)
	}
	var surf []int
	if section == "Outcrop" {
		sa := r.rr(30, 60)
		sph := r.n(256)
		surf = a.curve(top+20, sa, sph, 1, 2)
		b.WriteString(`<clipPath id="o"><path d="`)
		wRibbon(b, surf)
		b.WriteString(`"/></clipPath>`)
	}
	b.WriteString(`</defs>`)
	switch section {
	case "Cores":
		b.WriteString(`<rect width="1000" height="1000" fill="#ece6da"/><path d="`)
		for k := 0; k < 4; k++ {
			for y := 150; y < 880; y += 25 {
				b.WriteString("M")
				wPt(b, 80+200*k, y)
				if y%100 == 0 {
					b.WriteString("h14")
				} else {
					b.WriteString("h7")
				}
			}
		}
		b.WriteString(`" stroke="#6a6258" stroke-width="2"/><g clip-path="url(#k)">`)
	case "Outcrop":
		sky := "#e9e1cf"
		if eraName == "Basalt Coast" {
			sky = "#c9d3d8"
		} else if eraName == "Lapis Vein" {
			sky = "#d9dde6"
		}
		b.WriteString(`<rect width="1000" height="1000" fill="`)
		b.WriteString(sky)
		b.WriteString(`"/><circle cx="`)
		wInt(b, r.rr(150, 850))
		b.WriteString(`" cy="`)
		wInt(b, r.rr(70, 150))
		b.WriteString(`" r="`)
		wInt(b, r.rr(34, 60))
		b.WriteString(`" fill="#f4efe2"/><g clip-path="url(#o)">`)
	default:
		b.WriteString(`<g>`)
	}
	for k := 0; k <= nf; k++ {
		b.WriteString(`<g clip-path="url(#f`)
		wInt(b, k)
		b.WriteString(`)"><use href="#b" y="`)
		wInt(b, throws[k])
		b.WriteString(`"/></g>`)
	}
	for k := 0; k < nf; k++ {
		b.WriteString(`<path d="M`)
		wPt(b, fxs[k]+fds[k], -10)
		b.WriteString("L")
		wPt(b, fxs[k]-fds[k], canvas+10)
		b.WriteString(`" stroke="`)
		b.WriteString(dark)
		b.WriteString(`" stroke-width="4" opacity=".75"/>`)
	}
	b.WriteString(`</g>`)
	if section == "Outcrop" {
		b.WriteString(`<path d="M`)
		wPts(b, surf)
		b.WriteString(`" fill="none" stroke="#4a5a3a" stroke-width="7" stroke-linecap="round"/>`)
	}
	if section == "Cores" {
		b.WriteString(`<g fill="none" stroke="#3a342c" stroke-width="3">`)
		writeCoreRects(b)
		b.WriteString(`</g>`)
	}
	b.WriteString(`</svg>`)
	return b.String()
}

func writeCoreRects(b *strings.Builder) {
	for k := 0; k < 4; k++ {
		b.WriteString(`<rect x="`)
		wInt(b, 110+200*k)
		b.WriteString(`" y="`)
		wInt(b, 120+30*(k%2))
		b.WriteString(`" width="150" height="760" rx="75"/>`)
	}
}
