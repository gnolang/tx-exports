// Package strata (v2, "Derin Zaman") is a Sinopia engine: a geological
// plate of an invented earth. On the left a cross-section: beds of eight rock
// types, each with its own texture, folded by an integer sine field, cut by
// faults (every bed boundary steps along the fault plane), crossed by dikes,
// sills or quartz veins, sometimes truncated by an angular unconformity, with
// fossils in the beds and the present land surface on top (meadow, forest,
// bare rock or snow). On the right the stratigraphic column of the same
// beds: each formation named (Kızıldere, Akyayla, ...), dated in Ma, drawn
// with its true thickness and a width by its resistance (a weathering
// profile), fossils and events marked. Rare events tell a story: an aquifer
// with its well, a karst cave, an oil trap under an anticline with its
// derrick, a gold vein, an impact boundary.
//
// It is the successor of Strata v1 (p/.../art/strata/v1, which stays
// untouched): the same FNV-1a + splitmix64 streams (seed+"|traits" and
// seed+"|art") and the same integer sine table, a new picture.
// frontend/src/engines/stratav2.ts is a byte-identical TypeScript twin;
// strata_test.gno pins golden vectors that the twin asserts too.
//
// Unlike v1 the art reads Input.TokenID (the column's title, "Section 42").
// It never reads heights or moves, so the engine is not living. Pure integer
// maths: no floats, no time, no block data.
package strata

import (
	"errors"
	"strconv"
	"strings"

	"gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia4/engine/v2"
)

// traitTypes in the order Traits returns them.
var traitTypes = []string{"Era", "Event", "Fossil", "Intrusion", "Folding", "Tectonics", "Surface", "Rarity"}

// MaxSVGBytes: the largest output measured is 16,755 B (10,000 default seeds
// and 8,000 params renders, docs/engines/strata-v2.md); about 1.7x margin,
// within the 28 KB budget.
const MaxSVGBytes = 28672

// ParamsSchema is the Studio form. Studio sends JSON.stringify of the values
// in this property order; ValidateParams accepts exactly that or "".
const ParamsSchema = `{"type":"object","properties":{` +
	`"era":{"type":"string","title":"Era","enum":["Seeded","Red Beds","Chalk Sea","Volcanic Arc","Coal Age",` +
	`"Desert Dunes","Ice Age","Lapis Vein"],"default":"Seeded"},` +
	`"folding":{"type":"string","title":"Folding","enum":["Seeded","Flat","Gentle","Folded","Contorted"],"default":"Seeded"},` +
	`"surface":{"type":"string","title":"Surface","enum":["Seeded","Meadow","Forest","Bare Rock","Snow"],"default":"Seeded"}}}`

// DefaultParams is the canonical form of the defaults; it renders exactly
// like "".
const DefaultParams = `{"era":"Seeded","folding":"Seeded","surface":"Seeded"}`

// Manifest describes the engine. Author and FeeBps are set by the adapter.
func Manifest() engine.Manifest {
	return engine.Manifest{
		Name:    "Strata · Derin Zaman",
		Version: "2.0.0",
		Description: "Strata v2: a geological plate of an invented earth. A cross-section of textured beds, " +
			"folded, faulted and cut by dikes, with fossils and the land surface on top, beside the " +
			"stratigraphic column of the same beds: every formation named and dated. Rare events tell a " +
			"story: an aquifer, a karst cave, an oil trap, a gold vein, an impact boundary. The token " +
			"number titles the section.",
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
	Era, Folding, Surface int
}

// Defaults is the showcase look (params "").
func Defaults() Config { return Config{Era: -1, Folding: -1, Surface: -1} }

var errParams = errors.New(`stratav2: params must be "" or ` +
	`{"era":<enum>,"folding":<enum>,"surface":<enum>} in that order, without spaces`)

// ParseParams accepts "" or the canonical JSON Studio produces, nothing else.
func ParseParams(params string) (Config, error) {
	cfg := Defaults()
	if params == "" {
		return cfg, nil
	}
	v, rest, ok := strValue(params, `{"era":"`)
	if !ok {
		return cfg, errParams
	}
	if cfg.Era, ok = enumIndex(v, eras); !ok {
		return cfg, errParams
	}
	if v, rest, ok = strValue(rest, `","folding":"`); !ok {
		return cfg, errParams
	}
	if cfg.Folding, ok = enumIndex(v, foldings); !ok {
		return cfg, errParams
	}
	if v, rest, ok = strValue(rest, `","surface":"`); !ok {
		return cfg, errParams
	}
	if cfg.Surface, ok = enumIndex(v, surfaces); !ok {
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
// renders: eight draws and a score.
func Traits(in engine.Input) []engine.Trait {
	t := TraitsOf(in.Seed, mustConfig(in.Params))
	return []engine.Trait{
		{Type: "Era", Value: t.Era},
		{Type: "Event", Value: t.Event},
		{Type: "Fossil", Value: t.Fossil},
		{Type: "Intrusion", Value: t.Intrusion},
		{Type: "Folding", Value: t.Folding},
		{Type: "Tectonics", Value: t.Tectonics},
		{Type: "Surface", Value: t.Surface},
		{Type: "Rarity", Value: t.Rarity},
	}
}

// Render returns the raw SVG for in.Seed, in.Params and in.TokenID.
func Render(in engine.Input) string { return SVG(in.Seed, mustConfig(in.Params), in.TokenID) }

// ---------------------------------------------------------------------------
// Deterministic randomness: FNV-1a over the seed, then splitmix64 (Strata
// v1's stream). Traits use seed+"|traits", the art seed+"|art".
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

// ---------------------------------------------------------------------------
// Tables
// ---------------------------------------------------------------------------

type option struct {
	name   string
	weight int
	score  int // contribution to the rarity score when drawn (not pinned)
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

var eras = []option{
	{"Red Beds", 22, 0}, {"Chalk Sea", 18, 0}, {"Volcanic Arc", 14, 0}, {"Coal Age", 14, 0},
	{"Desert Dunes", 14, 0}, {"Ice Age", 10, 1}, {"Lapis Vein", 6, 4},
}

const (
	eVolcanic = 2
	eDesert   = 4
	eLapis    = 6
)

// eraSky: the sky gradient, top and bottom.
var eraSky = [][]string{
	{"#e9dcc4", "#f4ecdc"}, {"#dfe6e4", "#f2f2ea"}, {"#d8d2d6", "#eeeae6"}, {"#d6dccd", "#ecefe4"},
	{"#f0d9b0", "#f8eedc"}, {"#d6e2ea", "#eef3f5"}, {"#d9dbe6", "#f0eff2"},
}

// eraRock: the rock colours in liths order.
var eraRock = [][]string{
	{"#c0643f", "#7a3426", "#d9b38c", "#a8553a", "#b98a6a", "#9a6b5a", "#3a2620", "#e8d6c0"},
	{"#d8c49a", "#8a8a7a", "#ece4cc", "#b8a684", "#cfc7a8", "#a7a294", "#33302a", "#f4efe2"},
	{"#8d7a76", "#4a3f48", "#b8aca8", "#6e5a5a", "#9a8c8c", "#b5a3b8", "#211d22", "#d9d0d4"},
	{"#b0a080", "#4c4a44", "#c4bca4", "#8a7c64", "#9c967e", "#8c8678", "#1b1a18", "#e2ddcc"},
	{"#dd9a55", "#9c5a36", "#e8cfa0", "#c07a45", "#d2a074", "#b88a6a", "#4a3022", "#f3e6cc"},
	{"#a9b2b0", "#5f6a72", "#d2d8d6", "#87908e", "#b4bcbc", "#9aa0a8", "#262b30", "#eef2f2"},
	{"#4a5a8a", "#1f2747", "#8a93b8", "#3a4670", "#6a73a0", "#5a5f86", "#141726", "#c9cde0"},
}

var liths = []option{
	{"Sandstone", 26, 0}, {"Shale", 22, 0}, {"Limestone", 20, 0}, {"Conglomerate", 9, 0},
	{"Marl", 10, 0}, {"Tuff", 6, 0}, {"Coal", 4, 0}, {"Evaporite", 3, 0},
}

const (
	lSandstone = 0
	lShale     = 1
	lLimestone = 2
	lCoal      = 6
)

// lithW is the column width of each rock: resistant rocks stand out.
var lithW = []int{26, 16, 30, 28, 20, 22, 12, 18}

const lithID = "kslcmtoe"

var lithPat = []string{
	`<pattern id="k" width="14" height="10" patternUnits="userSpaceOnUse"><path d="M2 3h1M9 2h1M5 7h1M12 8h1" stroke="#000" stroke-opacity=".28" stroke-width="1.6" stroke-linecap="round"/></pattern>`,
	`<pattern id="s" width="22" height="6" patternUnits="userSpaceOnUse"><path d="M1 2h9M13 5h7" stroke="#000" stroke-opacity=".2"/></pattern>`,
	`<pattern id="l" width="28" height="14" patternUnits="userSpaceOnUse"><path d="M0 .5h28M0 7.5h28M7 0v7M21 7v7" stroke="#000" stroke-opacity=".16"/></pattern>`,
	`<pattern id="c" width="24" height="18" patternUnits="userSpaceOnUse"><ellipse cx="6" cy="5" rx="4" ry="3" fill="#fff" fill-opacity=".22" stroke="#000" stroke-opacity=".25"/><ellipse cx="17" cy="12" rx="5" ry="3.4" fill="#000" fill-opacity=".1" stroke="#000" stroke-opacity=".25"/><circle cx="20" cy="3" r="1.6" fill="#000" fill-opacity=".25"/></pattern>`,
	`<pattern id="m" width="16" height="8" patternUnits="userSpaceOnUse"><path d="M0 4h5M8 4h5" stroke="#000" stroke-opacity=".13"/><circle cx="12" cy="1.5" r=".9" fill="#000" fill-opacity=".2"/></pattern>`,
	`<pattern id="t" width="12" height="12" patternUnits="userSpaceOnUse"><path d="M2 2l2 1M8 7l1 2M4 9l2-1" stroke="#fff" stroke-opacity=".35"/><circle cx="10" cy="3" r="1" fill="#000" fill-opacity=".25"/></pattern>`,
	`<pattern id="o" width="10" height="4" patternUnits="userSpaceOnUse"><path d="M0 1h10" stroke="#fff" stroke-opacity=".08"/></pattern>`,
	`<pattern id="e" width="18" height="14" patternUnits="userSpaceOnUse"><path d="M4 4l3 3 3-3-3-3zM11 10l3 3 3-3-3-3z" fill="none" stroke="#000" stroke-opacity=".15"/></pattern>`,
}

var foldings = []option{{"Flat", 22, 0}, {"Gentle", 34, 0}, {"Folded", 30, 0}, {"Contorted", 14, 1}}

var foldAmp = []int{0, 18, 42, 70}

var faultsT = []option{{"0", 30, 0}, {"1", 44, 0}, {"2", 26, 1}}

var intrusions = []option{{"None", 46, 0}, {"Dike", 24, 0}, {"Sill", 16, 0}, {"Dike & Sill", 10, 1}, {"Vein Swarm", 4, 3}}

const (
	iDike  = 1
	iSill  = 2
	iBoth  = 3
	iSwarm = 4
)

var fossils = []option{
	{"None", 34, 0}, {"Ammonite", 20, 0}, {"Fish", 14, 0}, {"Leaf", 14, 0}, {"Sea Urchin", 12, 0}, {"Fossil Bed", 6, 2},
}

const fBed = 5

var fossilSym = []string{
	`<symbol id="fa" viewBox="-12 -12 24 24"><path d="M0 0a2 2 0 0 1 4 0a4 4 0 0 1-8 0a6 6 0 0 1 12 0a8 8 0 0 1-16 0a10 10 0 0 1 20 0M7 0h5M-5 1l-5 2M2-6l1-4M-1 7l-1 4" fill="none" stroke="currentColor" stroke-width="1.8"/></symbol>`,
	`<symbol id="fb" viewBox="-14 -7 28 14"><path d="M-12 0q10-9 21 0q-11 9-21 0zM9 0l4-4v8zM-9 0h18M-6-3l2 6M-2-4l2 8M2-4l2 8M6-3l1 6" fill="none" stroke="currentColor" stroke-width="1.2"/></symbol>`,
	`<symbol id="fy" viewBox="-8 -14 16 28"><path d="M0-12q8 8 0 22q-8-14 0-22zM0-10v24M0-4l4-3M0 1l4-3M0-4l-4-3M0 1l-4-3" fill="none" stroke="currentColor" stroke-width="1.2"/></symbol>`,
	`<symbol id="fd" viewBox="-10 -10 20 20"><circle r="8" fill="none" stroke="currentColor" stroke-width="1.4"/><path d="M0-6v12M-6 0h12M-4-4l8 8M4-4l-8 8" stroke="currentColor" stroke-dasharray="1 2"/></symbol>`,
}

var fossilID = []string{"fa", "fb", "fy", "fd"}

var events = []option{
	{"None", 64, 0}, {"Aquifer", 9, 3}, {"Karst Cave", 9, 3}, {"Oil Trap", 6, 3}, {"Gold Vein", 6, 3}, {"Impact Boundary", 6, 3},
}

const (
	evAquifer = 1
	evKarst   = 2
	evOil     = 3
	evGold    = 4
	evImpact  = 5
)

var surfaces = []option{{"Meadow", 40, 0}, {"Forest", 26, 0}, {"Bare Rock", 22, 0}, {"Snow", 12, 0}}

const (
	sMeadow = 0
	sForest = 1
	sSnow   = 3
)

const (
	unconfPct   = 28
	scoreUnconf = 1
)

var tectonics = []string{"Undisturbed", "One Fault", "Two Faults", "Unconformity", "Unconformity + One Fault", "Unconformity + Two Faults"}

// Rarity cut-offs on the summed score (10,000 default seeds: see
// docs/engines/strata-v2.md).
const (
	scoreMythic    = 8
	scoreLegendary = 6
	scoreRare      = 4
	scoreUncommon  = 2
)

var namesA = []string{"Kızıl", "Ak", "Kara", "Sarı", "Boz", "Gök", "Demir", "Taş", "Çam", "Göl", "Kuru", "Ulu", "Ilı", "Yel", "Elma", "Dikmen"}

var namesB = []string{"dere", "tepe", "kaya", "ova", "pınar", "bel", "yurt", "köy", "sırt", "yayla", "çay", "bük"}

// ---------------------------------------------------------------------------
// Traits
// ---------------------------------------------------------------------------

type draw struct {
	era, folding, faults, intrusion int
	unconf                          bool
	fossil, event, surface          int
	score                           int
	rarity                          string
}

// derive draws the traits from seed+"|traits". The draw order is part of the
// contract: era, folding, faults, intrusion, unconformity (intn(100) < 28),
// fossil, event, surface. Params pin era/folding/surface after all draws, so
// a seed's other traits never move; a pinned trait scores 0.
func derive(seed string, cfg Config) draw {
	r := newRNG(seed + "|traits")
	d := draw{}
	d.era = pick(r, eras)
	d.folding = pick(r, foldings)
	d.faults = pick(r, faultsT)
	d.intrusion = pick(r, intrusions)
	d.unconf = r.intn(100) < unconfPct
	d.fossil = pick(r, fossils)
	d.event = pick(r, events)
	d.surface = pick(r, surfaces)
	score := faultsT[d.faults].score + intrusions[d.intrusion].score + fossils[d.fossil].score + events[d.event].score
	if d.unconf {
		score += scoreUnconf
	}
	if cfg.Era >= 0 {
		d.era = cfg.Era
	} else {
		score += eras[d.era].score
	}
	if cfg.Folding >= 0 {
		d.folding = cfg.Folding
	} else {
		score += foldings[d.folding].score
	}
	if cfg.Surface >= 0 {
		d.surface = cfg.Surface
	} else {
		score += surfaces[d.surface].score
	}
	d.score = score
	switch {
	case score >= scoreMythic:
		d.rarity = "Mythic"
	case score >= scoreLegendary:
		d.rarity = "Legendary"
	case score >= scoreRare:
		d.rarity = "Rare"
	case score >= scoreUncommon:
		d.rarity = "Uncommon"
	default:
		d.rarity = "Common"
	}
	return d
}

// TraitSet is the decoded traits of a seed; the picture reads the same draw.
type TraitSet struct {
	Era, Event, Fossil, Intrusion, Folding, Tectonics, Surface, Rarity string
	Score                                                              int
}

// TraitsOf returns the traits of a seed under cfg.
func TraitsOf(seed string, cfg Config) TraitSet {
	d := derive(seed, cfg)
	tec := d.faults
	if d.unconf {
		tec += 3
	}
	return TraitSet{
		Era:       eras[d.era].name,
		Event:     events[d.event].name,
		Fossil:    fossils[d.fossil].name,
		Intrusion: intrusions[d.intrusion].name,
		Folding:   foldings[d.folding].name,
		Tectonics: tectonics[tec],
		Surface:   surfaces[d.surface].name,
		Rarity:    d.rarity,
		Score:     d.score,
	}
}

// SectionNumber is the number in the column title: Input.TokenID read as a
// decimal, modulo 1,000,000. Anything but ASCII digits (or "") is 0.
func SectionNumber(tokenID string) int {
	v := 0
	for i := 0; i < len(tokenID); i++ {
		c := tokenID[i]
		if c < '0' || c > '9' {
			return 0
		}
		v = (v*10 + int(c-'0')) % 1000000
	}
	return v
}

// ---------------------------------------------------------------------------
// Integer helpers
// ---------------------------------------------------------------------------

func iabs(a int) int {
	if a < 0 {
		return -a
	}
	return a
}

func imin(a, b int) int {
	if a < b {
		return a
	}
	return b
}

func imax(a, b int) int {
	if a > b {
		return a
	}
	return b
}

// quarter is a quarter wave, 256 steps per turn, x1024 (Strata v1's table).
var quarter = []int{0, 25, 50, 75, 100, 125, 150, 175, 200, 224, 249, 273, 297, 321, 345, 369, 392, 415, 438, 460,
	483, 505, 526, 548, 569, 590, 610, 630, 650, 669, 688, 706, 724, 742, 759, 775, 792, 807, 822,
	837, 851, 865, 878, 891, 903, 915, 926, 936, 946, 955, 964, 972, 980, 987, 993, 999, 1004, 1009,
	1013, 1016, 1019, 1021, 1023, 1024, 1024}

func isin(a int) int {
	a %= 256
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

const hexDigits = "0123456789abcdef"

func hexByte(c string, i int) int {
	return strings.IndexByte(hexDigits, c[i])*16 + strings.IndexByte(hexDigits, c[i+1])
}

// mix is a + (b - a) * t / 100 per channel (truncated), "#rrggbb".
func mix(a, b string, t int) string {
	out := []byte{'#', 0, 0, 0, 0, 0, 0}
	for i := 1; i < 7; i += 2 {
		va, vb := hexByte(a, i), hexByte(b, i)
		v := va + (vb-va)*t/100
		out[i] = hexDigits[v>>4]
		out[i+1] = hexDigits[v&15]
	}
	return string(out)
}

// contrast is a colour that reads on top of rock colour c.
func contrast(c string) string {
	luma := (299*hexByte(c, 1) + 587*hexByte(c, 3) + 114*hexByte(c, 5)) / 1000
	if luma > 110 {
		return mix(c, "#1a120c", 65)
	}
	return mix(c, "#ffffff", 60)
}

func itoa(n int) string { return strconv.Itoa(n) }

// ---------------------------------------------------------------------------
// The section
// ---------------------------------------------------------------------------

const (
	sheetW = 640 // sheet
	sheetH = 800
	sx     = 16 // section box; the section is drawn in local coordinates
	sy     = 16
	sw     = 480
	sh     = 768
	bot    = sh + 40 // rock bodies close below the box
	step   = 16      // 30 steps, 31 samples
	ns     = sw / step
	colX   = 512 // the column
	colTop = 80
	colH   = 660
	none   = 99
)

// relSteps writes the relative steps between consecutive points,
// "dx dy dx dy", with no separator before a minus; zero moves are skipped.
func relSteps(b *strings.Builder, xs, ys []int) {
	first := true
	px, py := xs[0], ys[0]
	for i := 1; i < len(xs); i++ {
		dx, dy := xs[i]-px, ys[i]-py
		if dx == 0 && dy == 0 {
			continue
		}
		if !first && dx >= 0 {
			b.WriteString(" ")
		}
		b.WriteString(itoa(dx))
		if dy >= 0 {
			b.WriteString(" ")
		}
		b.WriteString(itoa(dy))
		first = false
		px, py = xs[i], ys[i]
	}
}

// openPath writes an open polyline "Mx yl...".
func openPath(b *strings.Builder, xs, ys []int) {
	b.WriteString("M")
	b.WriteString(itoa(xs[0]))
	b.WriteString(" ")
	b.WriteString(itoa(ys[0]))
	b.WriteString("l")
	relSteps(b, xs, ys)
}

// bodyPath writes a rock body: the curve, continued 20 px past both sides,
// closed below the box.
func bodyPath(b *strings.Builder, xs, ys []int) {
	b.WriteString("M-20 " + itoa(bot) + "V" + itoa(ys[0]) + "h20l")
	relSteps(b, xs, ys)
	b.WriteString("h20V" + itoa(bot) + "z")
}

type fault struct{ x0, sl, th int }

type section struct {
	n, uIdx, a0, lam, ph, ph2, tilt, uTilt, anti int
	depth, surf                                  []int
	faults                                       []fault
}

func (s *section) surfAt(x int) int {
	if x <= 0 {
		return s.surf[0]
	}
	if x >= sw {
		return s.surf[ns]
	}
	i := x / step
	rem := x - i*step
	return s.surf[i] + (s.surf[i+1]-s.surf[i])*rem/step
}

func (s *section) fx(f fault, y int) int { return f.x0 + f.sl*(y-300)/100 }

func (s *section) throwAt(x, y int) int {
	t := 0
	for _, f := range s.faults {
		if x > s.fx(f, y) {
			t += f.th
		}
	}
	return t
}

// eAt is the erosion surface of the unconformity.
func (s *section) eAt(x int) int {
	return s.depth[s.uIdx] - 8 + (6*isin(3*x+s.ph)+3*isin(x*256/61+s.ph2))/1024
}

// raw is boundary k (the top of bed k+1) at x before faulting.
func (s *section) raw(k, x int) int {
	if k == s.uIdx {
		return s.eAt(x)
	}
	old := k > s.uIdx
	a := s.a0 * k / (s.n + 4)
	if old {
		a = s.a0 + 26
	}
	y := s.depth[k] + a*isin(x*256/s.lam+s.ph+3*k)/1024 +
		(a>>2)*isin(x*256/97+s.ph2)/1024 + s.tilt*(x-240)*(k+2)/(100*s.n)
	if old {
		y += s.uTilt * (x - 240) / 100
	}
	if s.anti >= 0 && k >= 1 {
		d := iabs(x - s.anti)
		if d < 170 {
			y -= 15 * imin(k, 4) * (1024 + icos(d*128/170)) / 2048
		}
	}
	if old {
		y = imax(y, s.eAt(x)+1)
	}
	return y
}

func (s *section) clampY(x, y int) int { return imin(imax(y, s.surfAt(x)+2), sh+20) }

// at is boundary k at x after faulting, kept below the land surface.
func (s *section) at(k, x int) int {
	y0 := s.raw(k, x)
	return s.clampY(x, y0+s.throwAt(x, y0))
}

// boundary samples boundary k every 16 px, with a step on the fault plane at
// every fault it crosses.
func (s *section) boundary(k int) ([]int, []int) {
	xs := make([]int, 0, ns+8)
	ys := make([]int, 0, ns+8)
	nf := len(s.faults)
	prev := make([]bool, nf)
	for x := 0; x <= sw; x += step {
		y0 := s.raw(k, x)
		for fi := 0; fi < nf; fi++ {
			f := s.faults[fi]
			side := x > s.fx(f, y0)
			if x > 0 && side != prev[fi] {
				xf := s.fx(f, y0)
				yb := s.raw(k, xf)
				// each side meets the fault plane at its own (thrown) depth
				yl, yr := yb+s.throwAt(xf-2, yb), yb+s.throwAt(xf+2, yb)
				xl, xr := s.fx(f, yl)-1, s.fx(f, yr)+1
				xs = append(xs, xl, xr)
				ys = append(ys, s.clampY(xl, yl), s.clampY(xr, yr))
			}
			prev[fi] = side
		}
		xs = append(xs, x)
		ys = append(ys, s.clampY(x, y0+s.throwAt(x, y0)))
	}
	return xs, ys
}

// ---------------------------------------------------------------------------
// The plate
// ---------------------------------------------------------------------------

// SVG renders a seed under cfg with the token number tokenID. The art
// stream's draw order is part of the contract (it mirrors stratav2.ts).
func SVG(seed string, cfg Config, tokenID string) string {
	d := derive(seed, cfg)
	r := newRNG(seed + "|art")
	rock := eraRock[d.era]
	sky := eraSky[d.era]
	s := &section{uIdx: none, anti: -1}

	// --- the plan: beds, names, ages ---
	n := r.between(10, 14)
	s.n = n
	lith := make([]int, n)
	for i := 0; i < n; i++ {
		l := pick(r, liths)
		if d.event == evAquifer && i == 3 {
			l = lSandstone
		}
		if d.event == evKarst && i == 5 {
			l = lLimestone
		}
		if d.event == evOil && i == 4 {
			l = lShale // the cap rock
		}
		if d.event == evOil && i == 5 {
			l = lSandstone // the reservoir
		}
		lith[i] = l
	}
	thick := make([]int, n)
	total := 0
	for i := 0; i < n; i++ {
		if lith[i] == lCoal {
			thick[i] = r.between(10, 16)
		} else {
			thick[i] = r.between(30, 70)
		}
		total += thick[i]
	}
	names := make([]string, n)
	for i := 0; i < n; i++ {
		a := namesA[r.intn(len(namesA))]
		names[i] = a + namesB[r.intn(len(namesB))]
	}
	sBase := r.between(130, 190)
	sp1 := r.intn(256)
	sp2 := r.intn(256)
	sa1 := r.between(14, 40)
	sa2 := r.between(6, 16)
	if d.unconf {
		s.uIdx = r.between(3, imin(6, n-3))
	}
	ages := make([]int, n)
	age := r.between(2, 12)
	for i := 0; i < n; i++ {
		ages[i] = age
		age += r.between(4, 30)
		if i == s.uIdx {
			age += r.between(60, 200) // the hiatus
		}
	}
	s.a0 = foldAmp[d.folding]
	s.lam = r.between(150, 330)
	s.ph = r.intn(256)
	s.tilt = r.between(-14, 14)
	s.ph2 = r.intn(256)
	if d.unconf {
		s.uTilt = r.between(18, 34)
		if r.intn(2) != 0 {
			s.uTilt = -s.uTilt
		}
	}
	for f := 0; f < d.faults; f++ {
		x0 := r.between(90, sw-90)
		sl := r.between(-35, 35)
		th := r.between(16, 46)
		if r.intn(100) >= 70 {
			th = -th
		}
		s.faults = append(s.faults, fault{x0, sl, th})
	}
	if d.event == evOil {
		s.anti = r.between(170, sw-170)
	}
	seedR := r.between(1, 900)
	seedG := r.between(1, 900)
	sunX := r.between(60, 420)
	sunY := r.between(36, 80)
	sunR := r.between(16, 28)
	ridge := make([]int, 14)
	for i := 0; i < 14; i++ {
		ridge[i] = sBase - r.between(10, 60)
	}
	volc := -1
	if d.era == eVolcanic {
		volc = r.between(2, 10)
	}

	// --- geometry ---
	s.surf = make([]int, ns+1)
	sxs := make([]int, ns+1)
	for i := 0; i <= ns; i++ {
		x := i * step
		sxs[i] = x
		s.surf[i] = sBase + (sa1*isin(x*256/700+sp1)+sa2*isin(x*256/190+sp2))/1024
	}
	top0 := sBase + 20
	span := sh - 40 - top0
	s.depth = make([]int, n-1)
	cum := 0
	for k := 0; k < n-1; k++ {
		cum += thick[k]
		s.depth[k] = top0 + span*cum/total
	}
	bx := make([][]int, n-1)
	by := make([][]int, n-1)
	for k := 0; k < n-1; k++ {
		bx[k], by[k] = s.boundary(k)
	}

	// --- SVG ---
	tid := itoa(SectionNumber(tokenID))
	out := &strings.Builder{}
	out.WriteString(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 640 800" width="640" height="800">`)
	out.WriteString(`<title>Strata · Section ` + tid + `</title><desc>` + eras[d.era].name + `: ` + itoa(n) +
		` formations, ` + names[0] + ` (` + itoa(ages[0]) + ` Ma) down to ` + names[n-1] + ` (` + itoa(ages[n-1]) + ` Ma)`)
	if d.event > 0 {
		out.WriteString("; " + events[d.event].name)
	}
	out.WriteString(`.</desc>`)

	defs := &strings.Builder{}
	defs.WriteString(`<defs><linearGradient id="sk" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="` + sky[0] +
		`"/><stop offset="1" stop-color="` + sky[1] + `"/></linearGradient>`)
	used := make([]bool, 8)
	for _, l := range lith {
		used[l] = true
	}
	for l := 0; l < 8; l++ {
		if used[l] {
			defs.WriteString(lithPat[l])
		}
	}
	dunes := d.era == eDesert && used[lSandstone]
	if dunes {
		defs.WriteString(`<pattern id="x" width="40" height="22" patternUnits="userSpaceOnUse"><path d="M0 22l40-20M10 22l30-15M20 22l20-10" stroke="#000" stroke-opacity=".14" fill="none"/></pattern>`)
	}
	defs.WriteString(`<filter id="r" x="-2%" y="-2%" width="104%" height="104%"><feTurbulence type="fractalNoise" baseFrequency=".03" numOctaves="2" seed="` + itoa(seedR) + `"/>` +
		`<feDisplacementMap in="SourceGraphic" scale="6" xChannelSelector="R" yChannelSelector="G"/></filter>`)
	defs.WriteString(`<filter id="g" x="0" y="0" width="1" height="1"><feTurbulence type="fractalNoise" baseFrequency=".9" numOctaves="1" seed="` + itoa(seedG) + `"/>` +
		`<feColorMatrix values="0 0 0 0 .1 0 0 0 0 .08 0 0 0 0 .05 0 0 0 -1.4 .7"/><feComposite in2="SourceAlpha" operator="in"/></filter>`)
	var kinds []int
	if d.fossil == fBed {
		kinds = []int{0, 1, 2, 3}
	} else if d.fossil > 0 {
		kinds = []int{d.fossil - 1}
	}
	for _, fk := range kinds {
		defs.WriteString(fossilSym[fk])
	}
	defs.WriteString(`<clipPath id="cl"><rect width="480" height="768"/></clipPath><path id="L0" d="`)
	bodyPath(defs, sxs, s.surf)
	defs.WriteString(`"/>`)
	for k := 0; k < n-1; k++ {
		defs.WriteString(`<path id="L` + itoa(k+1) + `" d="`)
		bodyPath(defs, bx[k], by[k])
		defs.WriteString(`"/>`)
	}

	// rock colour of each bed
	col := make([]string, n)
	for i := 0; i < n; i++ {
		if d.event == evAquifer && i == 3 {
			col[i] = mix(rock[lSandstone], "#3f7fa8", 45)
		} else {
			col[i] = rock[lith[i]]
		}
	}

	body := &strings.Builder{}
	// sky, sun, distant ridge
	body.WriteString(`<rect width="480" height="768" fill="url(#sk)"/><circle cx="` + itoa(sunX) + `" cy="` + itoa(sunY) +
		`" r="` + itoa(sunR) + `" fill="#fbf6ea" opacity=".8"/>`)
	rxs := make([]int, 14)
	rys := make([]int, 14)
	for i := 0; i < 14; i++ {
		y := ridge[i]
		if volc >= 0 {
			y = imin(y, sBase-118+26*iabs(i-volc))
		}
		rxs[i] = -20 + 40*i
		rys[i] = y
	}
	body.WriteString(`<path d="M-20 ` + itoa(sBase+60) + `V` + itoa(rys[0]) + `l`)
	relSteps(body, rxs, rys)
	body.WriteString(`V` + itoa(sBase+60) + `z" fill="` + mix(sky[1], rock[lShale], 30) + `"/>`)
	if volc >= 0 {
		vx, vy := -20+40*volc, sBase-118
		body.WriteString(`<path d="M` + itoa(vx-6) + ` ` + itoa(vy-6) + `q-14-16 4-30q-8-18 14-28q14-12 30-2" fill="none" stroke="#fbf6ea" stroke-width="9" stroke-linecap="round" opacity=".7"/>`)
	}

	// beds
	body.WriteString(`<g filter="url(#r)" stroke-width="1.2" stroke-opacity=".45">`)
	for i := 0; i < n; i++ {
		li := itoa(i)
		body.WriteString(`<use href="#L` + li + `" fill="` + col[i] + `" stroke="` + mix(col[i], "#000000", 55) +
			`"/><use href="#L` + li + `" fill="url(#` + lithID[lith[i]:lith[i]+1] + `)"/>`)
		if dunes && lith[i] == lSandstone {
			body.WriteString(`<use href="#L` + li + `" fill="url(#x)"/>`)
		}
	}

	// intrusions cut the beds
	ign := "#4a3b38"
	if d.era == eVolcanic {
		ign = "#3a3036"
	}
	ignEdge := mix(ign, "#ffffff", 45)
	quartz := "#eee8dc" // vein swarm: pale quartz
	if d.era == eLapis {
		quartz = "#e9d9a0"
	}
	if d.intrusion == iDike || d.intrusion == iBoth || d.intrusion == iSwarm {
		nd := 1
		if d.intrusion == iSwarm {
			nd = 4
		}
		for k := 0; k < nd; k++ {
			x0 := r.between(60, sw-60)
			var w0 int
			if d.intrusion == iSwarm {
				w0 = r.between(4, 8)
			} else {
				w0 = r.between(14, 26)
			}
			sl := r.between(-20, 20)
			var top int
			if d.unconf {
				top = s.eAt(x0) + 6
			} else {
				top = sBase + r.between(20, 60)
			}
			var cx, cy []int
			for y := bot; y >= top; y -= 40 {
				cx = append(cx, x0+sl*(bot-y)/100+r.between(-3, 3))
				cy = append(cy, y)
			}
			m := len(cx)
			xs := make([]int, 0, 2*m+1)
			ys := make([]int, 0, 2*m+1)
			for i := 0; i < m; i++ {
				xs = append(xs, cx[i]-w0/2)
				ys = append(ys, cy[i])
			}
			xs = append(xs, cx[m-1])
			ys = append(ys, top-6)
			right := make([]int, m)
			for i := 0; i < m; i++ {
				right[i] = cx[i] + w0/2 + r.between(-2, 2)
			}
			for i := m - 1; i >= 0; i-- {
				xs = append(xs, right[i])
				ys = append(ys, cy[i])
			}
			body.WriteString(`<path d="`)
			openPath(body, xs, ys)
			if d.intrusion == iSwarm {
				body.WriteString(`z" fill="` + quartz + `" stroke="#6a5f55"/>`)
			} else {
				body.WriteString(`z" fill="` + ign + `" stroke="` + ignEdge + `" stroke-width="1.5"/>`)
			}
		}
	}
	if d.intrusion == iSill || d.intrusion == iBoth {
		k := imin(n-3, r.between(4, 8))
		bxs, bys := bx[k], by[k]
		i0 := r.between(2, 10)
		i1 := imin(len(bxs)-1, i0+r.between(12, 24))
		th := r.between(8, 14)
		var xs, ys []int
		for i := i0; i <= i1; i++ {
			xs = append(xs, bxs[i])
			ys = append(ys, bys[i])
		}
		for i := i1; i >= i0; i-- {
			xs = append(xs, bxs[i])
			ys = append(ys, bys[i]+th*imin(3, imin(i-i0, i1-i))/3)
		}
		if i1 > i0 {
			body.WriteString(`<path d="`)
			openPath(body, xs, ys)
			body.WriteString(`z" fill="` + ign + `" stroke="` + ignEdge + `"/>`)
		}
	}
	body.WriteString(`</g>`)

	// the unconformity: a dashed erosion line
	if d.unconf {
		body.WriteString(`<path d="`)
		openPath(body, bx[s.uIdx], by[s.uIdx])
		body.WriteString(`" fill="none" stroke="#2a1d16" stroke-width="2.4" stroke-dasharray="10 3 2 3"/>`)
	}

	// fossils
	fossilIn := make([]int, n)
	for i := range fossilIn {
		fossilIn[i] = -1
	}
	nfos := 0
	if d.fossil == fBed {
		nfos = 14
	} else if len(kinds) > 0 {
		nfos = r.between(3, 6)
	}
	for i := 0; i < nfos; i++ {
		fk := kinds[r.intn(len(kinds))]
		k := r.between(0, n-3)
		x := r.between(30, sw-30)
		sz0 := r.between(14, 26)
		rot := r.between(-40, 40)
		yt := s.at(k, x)
		gap := s.at(k+1, x) - yt
		if gap < 8 {
			continue
		}
		sz := imin(sz0, imax(8, gap-4))
		y := yt + gap/2
		body.WriteString(`<use href="#` + fossilID[fk] + `" x="` + itoa(x-sz/2) + `" y="` + itoa(y-sz/2) + `" width="` + itoa(sz) +
			`" height="` + itoa(sz) + `" transform="rotate(` + itoa(rot) + ` ` + itoa(x) + ` ` + itoa(y) + `)" color="` +
			contrast(col[k+1]) + `" opacity=".85"/>`)
		if fossilIn[k+1] < 0 {
			fossilIn[k+1] = fk
		}
	}

	// events
	goldLayer, impactK := -1, -1
	if d.event == evImpact {
		impactK = r.between(1, n-4)
		defs.WriteString(`<path id="ib" d="`)
		openPath(defs, bx[impactK], by[impactK])
		defs.WriteString(`"/>`)
		body.WriteString(`<use href="#ib" fill="none" stroke="#111" stroke-width="3"/>` +
			`<use href="#ib" y="-4" fill="none" stroke="#c9a24a" stroke-width="1.4" stroke-dasharray="1 6" stroke-linecap="round"/>`)
	}
	if d.event == evKarst {
		// a chamber in the limestone: vaulted roof, flat floor with a pool, dripstones
		x := r.between(120, sw-120)
		rw := r.between(40, 64)
		rh := r.between(22, 34)
		yc := s.at(4, x) + rh + 6
		drip := mix(rock[lLimestone], "#ffffff", 40)
		st := &strings.Builder{}
		for xi := x - rw + 8; xi < x+rw-8; xi += r.between(6, 11) {
			dd := xi - x
			ln := r.between(3, 3+rh*(rw*rw-dd*dd)/(rw*rw*2))
			st.WriteString("M" + itoa(xi-1) + " " + itoa(yc-rh*(rw*rw-dd*dd)/(rw*rw)-1) + "l1 " + itoa(ln) + "l1-" + itoa(ln) + "z")
			if r.intn(3) == 0 {
				st.WriteString("M" + itoa(xi-2) + " " + itoa(yc+1) + "l2-" + itoa(ln/2+2) + "l2 " + itoa(ln/2+2) + "z")
			}
		}
		body.WriteString(`<path d="M` + itoa(x-rw) + ` ` + itoa(yc) + `q` + itoa(rw) + `-` + itoa(2*rh) + ` ` + itoa(2*rw) +
			` 0q-` + itoa(rw) + ` ` + itoa(rh/4) + `-` + itoa(2*rw) + ` 0z" fill="#1d1712"/>` +
			`<ellipse cx="` + itoa(x) + `" cy="` + itoa(yc+1) + `" rx="` + itoa(rw/2) + `" ry="2" fill="#4f86a6"/><path d="` +
			st.String() + `" fill="` + drip + `"/>`)
	}
	if d.event == evGold {
		defs.WriteString(`<linearGradient id="au" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#f7e08a"/><stop offset=".5" stop-color="#c9952c"/><stop offset="1" stop-color="#fff2b0"/></linearGradient>`)
		x := r.between(80, sw-80)
		y := sh + 10
		p := &strings.Builder{}
		p.WriteString("M" + itoa(x) + " " + itoa(y))
		for i := 0; i < 14; i++ {
			dx := r.between(-26, 26)
			dy := -r.between(18, 34)
			p.WriteString("l" + itoa(dx) + " " + itoa(dy))
			x += dx
			y += dy
			if r.intn(100) < 30 {
				ex := r.between(-30, 30)
				ey := r.between(-20, 8)
				p.WriteString("l" + itoa(ex) + " " + itoa(ey) + "m" + itoa(-ex) + " " + itoa(-ey))
			}
		}
		body.WriteString(`<path d="` + p.String() + `" fill="none" stroke="url(#au)" stroke-width="3" stroke-linejoin="bevel"/>`)
		goldLayer = n - 1
	}
	if d.event == evOil {
		crest := s.at(4, s.anti)
		owc := crest + r.between(16, 26) // the oil-water contact is flat
		var xs, ys []int
		for x := s.anti - 140; x <= s.anti+140; x += 8 {
			xs = append(xs, x)
			ys = append(ys, imin(s.at(4, x), owc))
		}
		body.WriteString(`<path d="`)
		openPath(body, xs, ys)
		body.WriteString(`z" fill="#16130f" opacity=".88"/><path d="M` + itoa(s.anti-140) + ` ` + itoa(owc) +
			`h280" stroke="#4f86a6" stroke-dasharray="4 3"/>`)
		y := s.surfAt(s.anti)
		body.WriteString(`<path d="M` + itoa(s.anti-10) + ` ` + itoa(y) + `l10-46l10 46M` + itoa(s.anti-6) + ` ` + itoa(y-18) +
			`h12M` + itoa(s.anti-3) + ` ` + itoa(y-32) + `h6M` + itoa(s.anti) + ` ` + itoa(y) + `V` + itoa(crest+4) +
			`" fill="none" stroke="#2a2420" stroke-width="1.6"/>`)
	}
	if d.event == evAquifer {
		x := r.between(100, sw-100)
		y := s.surfAt(x)
		b := s.at(2, x) + 16
		well := `M` + itoa(x) + ` ` + itoa(y) + `V` + itoa(b)
		body.WriteString(`<path d="` + well + `" stroke="#2c2420" stroke-width="5"/><path d="` + well +
			`" stroke="#5e8fae" stroke-width="2" stroke-dasharray="3 5"/><path d="M` + itoa(x-12) + ` ` + itoa(y-2) +
			`h24v-14h-24zM` + itoa(x-14) + ` ` + itoa(y-16) + `h28l-14-10z" fill="#6b4a32"/>`)
	}

	// faults: from the land surface down
	fl := ""
	for _, f := range s.faults {
		yt := s.surfAt(s.fx(f, sBase))
		fl += "M" + itoa(s.fx(f, yt)) + " " + itoa(yt) + "L" + itoa(s.fx(f, sh+10)) + " " + itoa(sh+10)
	}
	if fl != "" {
		body.WriteString(`<path d="` + fl + `" stroke="#21170f" stroke-width="2.2"/><path d="` + fl +
			`" stroke="#f0e6d6" stroke-width=".6" stroke-dasharray="6 9" stroke-opacity=".6"/>`)
	}

	// the land surface
	body.WriteString(`<path d="`)
	openPath(body, sxs, s.surf)
	body.WriteString(`" fill="none" stroke="#3a2a1e" stroke-width="7" stroke-opacity=".55"/>`)
	if d.surface == sMeadow || d.surface == sForest {
		green := "#4d6b38"
		if d.surface == sMeadow {
			green = "#6f8a44"
		}
		body.WriteString(`<path d="`)
		openPath(body, sxs, offset(s.surf, 2))
		body.WriteString(`" fill="none" stroke="` + green + `" stroke-width="5"/>`)
	}
	if d.surface == sSnow {
		body.WriteString(`<path d="`)
		openPath(body, sxs, offset(s.surf, 3))
		body.WriteString(`" fill="none" stroke="#fbfbf7" stroke-width="7"/>`)
	}
	if d.surface == sMeadow || d.surface == sForest {
		t0 := &strings.Builder{}
		t1 := &strings.Builder{}
		var nt int
		if d.surface == sForest {
			nt = r.between(10, 18)
		} else {
			nt = r.between(2, 4)
		}
		for i := 0; i < nt; i++ {
			x := r.between(8, sw-8)
			h := r.between(16, 34)
			y := s.surfAt(x) + 1
			tr := "M" + itoa(x) + " " + itoa(y-h) + "l" + itoa(h/4) + " " + itoa(h) + "h-" + itoa(h/2) + "z"
			if r.intn(2) == 0 {
				t0.WriteString(tr)
			} else {
				t1.WriteString(tr)
			}
		}
		if t0.Len() > 0 {
			body.WriteString(`<path d="` + t0.String() + `" fill="#3f5a36"/>`)
		}
		if t1.Len() > 0 {
			body.WriteString(`<path d="` + t1.String() + `" fill="#536e3c"/>`)
		}
	}
	body.WriteString(`<use href="#L0" filter="url(#g)" opacity=".55"/>`)

	defs.WriteString(`</defs>`)
	out.WriteString(defs.String())
	out.WriteString(`<rect width="640" height="800" fill="#f3eee4"/><g transform="translate(16 16)" clip-path="url(#cl)">`)
	out.WriteString(body.String())
	out.WriteString(`</g><rect x="16" y="16" width="480" height="768" fill="none" stroke="#2a2420" stroke-width="1.5"/><path d="`)
	for i := 1; i < 12; i++ {
		out.WriteString("M16 " + itoa(sy+64*i) + "h6")
	}
	out.WriteString(`" stroke="#2a2420"/>`)

	// --- the stratigraphic column ---
	yb := make([]int, n+1)
	acc := 0
	for i := 0; i < n; i++ {
		yb[i] = colTop + colH*acc/total
		acc += thick[i]
	}
	yb[n] = colTop + colH
	leaders := &strings.Builder{}
	labels := &strings.Builder{}
	for i := 0; i < n; i++ {
		w, h := lithW[lith[i]], yb[i+1]-yb[i]
		box := `<rect x="512" y="` + itoa(yb[i]) + `" width="` + itoa(w) + `" height="` + itoa(h) + `" fill="`
		out.WriteString(box + col[i] + `"/>` + box + `url(#` + lithID[lith[i]:lith[i]+1] + `)" stroke="#2a2420" stroke-width=".6"/>`)
		mid := (yb[i] + yb[i+1]) / 2
		ly := colTop + colH*(2*i+1)/(2*n)
		leaders.WriteString("M" + itoa(colX+w+2) + " " + itoa(mid) + "L546 " + itoa(ly-5))
		labels.WriteString(`<text x="550" y="` + itoa(ly-2) + `">` + names[i] + `<tspan x="550" dy="10" font-size="7.5" fill="#7a6d60">` +
			itoa(ages[i]) + ` Ma · ` + liths[lith[i]].name + `</tspan></text>`)
		if fossilIn[i] >= 0 {
			out.WriteString(`<use href="#` + fossilID[fossilIn[i]] + `" x="` + itoa(colX+w/2-5) + `" y="` + itoa(mid-5) +
				`" width="10" height="10" color="` + contrast(col[i]) + `"/>`)
		}
	}
	if d.unconf {
		out.WriteString(`<path d="M510 ` + itoa(yb[s.uIdx+1]) + `q3-3 6 0t6 0t6 0t6 0t6 0" fill="none" stroke="#2a2420" stroke-width="1.4"/>`)
	}
	// event marks left of the column
	switch d.event {
	case evAquifer:
		out.WriteString(`<path d="M501 ` + itoa((yb[3]+yb[4])/2-2) + `q2-2 4 0t4 0m-8 4q2-2 4 0t4 0" fill="none" stroke="#3f7fa8" stroke-width="1.2"/>`)
	case evKarst:
		out.WriteString(`<path d="M501 ` + itoa((yb[5]+yb[6])/2+3) + `q4-9 8 0z" fill="#1d1712"/>`)
	case evOil:
		out.WriteString(`<path d="M505 ` + itoa((yb[5]+yb[6])/2-5) + `q5 6 0 9q-5-3 0-9z" fill="#16130f"/>`)
	}
	if goldLayer >= 0 {
		out.WriteString(`<path d="M505 ` + itoa((yb[goldLayer]+yb[goldLayer+1])/2-4) + `l3 4-3 4-3-4z" fill="#c9952c" stroke="#6a4a12" stroke-width=".6"/>`)
	}
	if impactK >= 0 {
		y := yb[impactK+1]
		out.WriteString(`<path d="M509 ` + itoa(y) + `h34" stroke="#111" stroke-width="2.4"/><text x="499" y="` + itoa(y+2) +
			`" font-family="Georgia, serif" font-size="6" fill="#111">Ir</text>`)
	}
	out.WriteString(`<path d="` + leaders.String() + `" fill="none" stroke="#8a7d70" stroke-width=".6"/>`)
	out.WriteString(`<g font-family="Georgia, serif" font-size="9.5" fill="#2a2420"><text x="512" y="38" font-size="14">Section ` + tid +
		`</text><text x="512" y="53" font-size="9" font-style="italic" fill="#6a5f55">` + eras[d.era].name +
		`</text><text x="512" y="66" font-size="7.5" fill="#7a6d60">` + itoa(n) + ` formations · ` + itoa(ages[0]) + `–` +
		itoa(ages[n-1]) + ` Ma</text>`)
	out.WriteString(labels.String())
	out.WriteString(`<path d="M512 766h50M512 762v8M537 764v4M562 762v8" stroke="#2a2420" stroke-width="1.2"/>` +
		`<text x="512" y="782" font-size="7.5">0 · 100 m</text><text x="628" y="782" font-size="7" font-style="italic" text-anchor="end" fill="#8a7d70">Derin Zaman</text></g></svg>`)
	return out.String()
}

func offset(ys []int, d int) []int {
	o := make([]int, len(ys))
	for i, y := range ys {
		o[i] = y - d
	}
	return o
}
