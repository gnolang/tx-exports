// Package cinar is a Sinopia engine and its first living one: a tree that
// grows with the token's age, turns with the chain's seasons and keeps its
// owners in its bark and roots.
//
// The tree's shape, species, setting and rare marks come from the seed. How
// much of the tree exists, and what it looks like today, comes from the chain
// inputs core passes in engine.Input (Living = true):
//
//   - Height - MintHeight (age): growth (a square-root curve over three
//     chain years) and the Stage trait;
//   - Height alone: the chain season (a 365-day chain year of 24,000-block
//     days, anchored so that gnoland-1 height 1,480,355 = 11 Nov 2026 =
//     day 236 after the spring equinox), the sun's height, and the daily
//     sky (clouds, birds, snowfall) drawn from a per-day stream;
//   - Height - LastMoveHeight (holding time): the current owner's roots,
//     moss after 180 days and a nest after 365 days; the tree's lifetime
//     roots stay as a faint ghost below them;
//   - Moves (transfers): one notch carved in the bark per transfer, or the
//     first owner's seal while it has never moved; a Wish Tree gets more
//     ribbons with every owner.
//
// CollectionID and TokenID are not read. Inputs are clamped to 0..2^32-1
// (core stores them as uint32) and MintHeight <= LastMoveHeight <= Height is
// enforced, so any RenderWithInput call renders.
//
// Pure integer maths: no floats. frontend/src/engines/cinar.ts is the
// byte-identical TypeScript twin; cinar_test.gno and cinar.test.ts assert the
// same golden vectors.
package cinar

import (
	"errors"
	"strconv"
	"strings"

	"gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia4/engine/v2"
)

// Chain time.
const (
	BlocksPerDay    = 24000
	BlocksPerYear   = 365 * BlocksPerDay
	BlocksPerSeason = BlocksPerYear / 4
	CalendarOffset  = 4184000 // (Height + offset) mod year = 0 at the spring equinox
	FullGrowthDays  = 1095
	FullRootsDays   = 365
	maxU32          = 4294967295
)

// TraitTypes in the order Traits returns them.
var traitTypes = []string{"Species", "Setting", "Season", "Stage", "Roots", "Notches", "Mark", "Rarity"}

var seasonNames = []string{"Spring", "Summer", "Autumn", "Winter"}

// MaxSVGBytes: the largest output measured is ~22 KB (full-grown crown,
// many transfers); the cap leaves headroom under the 28 KB budget.
const MaxSVGBytes = 28672

// Fingerprint is sha256(Render(engine.SampleInput())): a sapling on the
// steppe in late summer at height 1. The integration step reserves it in
// core (r/core config.gno reservedFingerprints).
const Fingerprint = "95d4922c9f9cdb02ab96e88c1628deb179ebb8d327054ab64d12040b38c00e83"

// ParamsSchema is the Studio form. Studio sends JSON.stringify of the values
// in this property order; ValidateParams accepts exactly that or "".
const ParamsSchema = `{"type":"object","properties":{` +
	`"species":{"type":"string","title":"Species","enum":["Seeded","Oriental Plane","Olive","Judas Tree","Cypress"],` +
	`"default":"Seeded"},` +
	`"setting":{"type":"string","title":"Setting","enum":["Seeded","Hill","Courtyard","Shore","Steppe"],` +
	`"default":"Seeded"}}}`

// DefaultParams is the canonical form of the defaults; it renders exactly
// like "".
const DefaultParams = `{"species":"Seeded","setting":"Seeded"}`

// Manifest describes the engine. Author and FeeBps are set by the adapter.
func Manifest() engine.Manifest {
	return engine.Manifest{
		Name:    "Cinar",
		Version: "1.0.0",
		Description: "A living tree: it grows with the token's age, turns with the chain's seasons and keeps " +
			"its owners in its bark and roots (one notch per transfer, roots that deepen while it is held).",
		License:      "CC-BY-NC-4.0",
		ParamsSchema: ParamsSchema,
		TraitTypes:   append([]string{}, traitTypes...),
		Living:       true,
		MaxSVGBytes:  MaxSVGBytes,
		Kind:         engine.KindSVG,
	}
}

// Config is a parsed params string.
type Config struct {
	Species int // -1: drawn from the seed
	Setting int // -1: drawn from the seed
}

// Defaults is the showcase look (params "").
func Defaults() Config { return Config{Species: -1, Setting: -1} }

var errParams = errors.New(`cinar: params must be "" or ` +
	`{"species":<enum>,"setting":<enum>} in that order, without spaces`)

// ParseParams accepts "" or the canonical JSON Studio produces, nothing else.
func ParseParams(params string) (Config, error) {
	cfg := Defaults()
	if params == "" {
		return cfg, nil
	}
	const p1, p2, end = `{"species":"`, `","setting":"`, `"}`
	if len(params) < len(p1)+len(end) || !strings.HasPrefix(params, p1) || !strings.HasSuffix(params, end) {
		return cfg, errParams
	}
	body := params[len(p1) : len(params)-len(end)]
	i := strings.Index(body, p2)
	if i < 0 {
		return cfg, errParams
	}
	sp, st := body[:i], body[i+len(p2):]
	if strings.IndexByte(sp, '"') >= 0 || strings.IndexByte(st, '"') >= 0 {
		return cfg, errParams
	}
	var ok bool
	if cfg.Species, ok = enumIndex(sp, speciesOpts); !ok {
		return cfg, errParams
	}
	if cfg.Setting, ok = enumIndex(st, settingOpts); !ok {
		return cfg, errParams
	}
	return cfg, nil
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

// ---------------------------------------------------------------------------
// Chain time
// ---------------------------------------------------------------------------

// Clock is everything the art reads from chain time, after clamping.
type Clock struct {
	Height, MintHeight, LastMoveHeight, Moves int
	AgeDays, HoldDays                         int
	Season                                    int // 0 spring .. 3 winter
	Progress                                  int // 0..999 within the season
	YearAngle                                 int // 0..255, spring equinox = 0
	Day                                       int // chain day number
}

func u32(v int64) int {
	if v < 0 {
		return 0
	}
	if v > maxU32 {
		return maxU32
	}
	return int(v)
}

// ClockOf reads the living fields of in.
func ClockOf(in engine.Input) Clock {
	var c Clock
	c.Height = u32(in.Height)
	c.MintHeight = u32(in.MintHeight)
	c.LastMoveHeight = u32(in.LastMoveHeight)
	c.Moves = u32(in.Moves)
	if c.MintHeight > c.Height {
		c.MintHeight = c.Height
	}
	if c.LastMoveHeight < c.MintHeight {
		c.LastMoveHeight = c.MintHeight
	}
	if c.LastMoveHeight > c.Height {
		c.LastMoveHeight = c.Height
	}
	t := (c.Height + CalendarOffset) % BlocksPerYear
	c.AgeDays = (c.Height - c.MintHeight) / BlocksPerDay
	c.HoldDays = (c.Height - c.LastMoveHeight) / BlocksPerDay
	c.Season = t / BlocksPerSeason
	c.Progress = (t % BlocksPerSeason) * 1000 / BlocksPerSeason
	c.YearAngle = t * 256 / BlocksPerYear
	c.Day = (c.Height + CalendarOffset) / BlocksPerDay
	return c
}

// ---------------------------------------------------------------------------
// Deterministic randomness: FNV-1a over the stream name, then splitmix64
// (the v1 engines' stream). Streams: seed+"|traits", "|tree", "|leaf",
// "|land", "|roots", "|marks", "|fall|<season>", "|sky|<day>", "|snow|<day>".
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
// Traits
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

var speciesOpts = []option{{"Oriental Plane", 34, 0}, {"Olive", 24, 0}, {"Judas Tree", 24, 0}, {"Cypress", 18, 1}}
var settingOpts = []option{{"Hill", 30, 0}, {"Courtyard", 24, 0}, {"Shore", 24, 1}, {"Steppe", 22, 0}}
var markOpts = []option{{"None", 88, 0}, {"Lightning Scar", 5, 2}, {"Wish Tree", 4, 3}, {"White Tree", 3, 4}}

const (
	spPlane = iota
	spOlive
	spJudas
	spCypress
)

const (
	setHill = iota
	setCourtyard
	setShore
	setSteppe
)

const (
	mkNone = iota
	mkLightning
	mkWish
	mkWhite
)

type draw struct {
	species, setting, mark, score int
	rarity                        string
}

func derive(seed string, cfg Config) draw {
	r := newRNG(seed + "|traits")
	// Draw order is part of the contract: changing it changes every token.
	var d draw
	d.species = pick(r, speciesOpts)
	d.setting = pick(r, settingOpts)
	d.mark = pick(r, markOpts)
	// Params override after the draws, so the stream never shifts.
	d.score = markOpts[d.mark].score
	if cfg.Species >= 0 {
		d.species = cfg.Species
	} else {
		d.score += speciesOpts[d.species].score
	}
	if cfg.Setting >= 0 {
		d.setting = cfg.Setting
	} else {
		d.score += settingOpts[d.setting].score
	}
	switch {
	case d.score >= 5:
		d.rarity = "Mythic"
	case d.score >= 4:
		d.rarity = "Legendary"
	case d.score >= 2:
		d.rarity = "Rare"
	case d.score >= 1:
		d.rarity = "Uncommon"
	default:
		d.rarity = "Common"
	}
	return d
}

func stageOf(age int) string {
	switch {
	case age < 30:
		return "Sapling"
	case age < 180:
		return "Young"
	case age < 730:
		return "Mature"
	}
	return "Venerable"
}

func rootsOf(hold int) string {
	switch {
	case hold < 30:
		return "Fresh"
	case hold < 180:
		return "Settled"
	case hold < 365:
		return "Deep"
	}
	return "Ancient"
}

func notchesOf(m int) string {
	switch {
	case m == 0:
		return "First Owner"
	case m == 1:
		return "1 Notch"
	case m <= 4:
		return "2-4 Notches"
	case m <= 9:
		return "5-9 Notches"
	}
	return "10+ Notches"
}

// TraitSet is the decoded properties of an input.
type TraitSet struct {
	Species, Setting, Season, Stage, Roots, Notches, Mark string
	Score                                                 int
	Rarity                                                string
}

// TraitsOf returns the traits for in under cfg. Species, Setting, Mark and
// Rarity come from the seed; Season, Stage, Roots and Notches from chain time.
func TraitsOf(in engine.Input, cfg Config) TraitSet {
	d := derive(in.Seed, cfg)
	c := ClockOf(in)
	return TraitSet{
		Species: speciesOpts[d.species].name,
		Setting: settingOpts[d.setting].name,
		Season:  seasonNames[c.Season],
		Stage:   stageOf(c.AgeDays),
		Roots:   rootsOf(c.HoldDays),
		Notches: notchesOf(c.Moves),
		Mark:    markOpts[d.mark].name,
		Score:   d.score,
		Rarity:  d.rarity,
	}
}

// Traits returns the eight traits of in in TraitTypes order. It never
// renders: three table draws and the clock.
func Traits(in engine.Input) []engine.Trait {
	t := TraitsOf(in, mustConfig(in.Params))
	return []engine.Trait{
		{Type: "Species", Value: t.Species},
		{Type: "Setting", Value: t.Setting},
		{Type: "Season", Value: t.Season},
		{Type: "Stage", Value: t.Stage},
		{Type: "Roots", Value: t.Roots},
		{Type: "Notches", Value: t.Notches},
		{Type: "Mark", Value: t.Mark},
		{Type: "Rarity", Value: t.Rarity},
	}
}

// Render returns the raw SVG for in.
func Render(in engine.Input) string { return SVG(in, mustConfig(in.Params)) }

// ---------------------------------------------------------------------------
// Integer helpers
// ---------------------------------------------------------------------------

// qsin is sin(a * 2π / 256) * 1024 over the first quadrant.
var qsin = []int{
	0, 25, 50, 75, 100, 125, 150, 175, 200, 224, 249, 273, 297, 321, 345, 369, 392, 415, 438, 460, 483, 505, 526, 548, 569,
	590, 610, 630, 650, 669, 688, 706, 724, 742, 759, 775, 792, 807, 822, 837, 851, 865, 878, 891, 903, 915, 926, 936, 946,
	955, 964, 972, 980, 987, 993, 999, 1004, 1009, 1013, 1016, 1019, 1021, 1023, 1024, 1024,
}

func sn(a int) int {
	a = ((a % 256) + 256) % 256
	switch {
	case a <= 64:
		return qsin[a]
	case a <= 128:
		return qsin[128-a]
	case a <= 192:
		return -qsin[a-128]
	}
	return -qsin[256-a]
}

func cs(a int) int { return sn(a + 64) }

// isqrt for 0 <= n <= 1,000,000.
func isqrt(n int) int {
	lo, hi := 0, 1001
	for hi-lo > 1 {
		m := (lo + hi) / 2
		if m*m <= n {
			lo = m
		} else {
			hi = m
		}
	}
	return lo
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

func clampI(v, a, b int) int {
	if v < a {
		return a
	}
	if v > b {
		return b
	}
	return v
}

func itoa(n int) string { return strconv.Itoa(n) }

// f10 prints tenths as a decimal: 12 -> "1.2", 30 -> "3", 7 -> "0.7".
func f10(v int) string {
	if v%10 == 0 {
		return itoa(v / 10)
	}
	return itoa(v/10) + "." + itoa(v%10)
}

const hexd = "0123456789abcdef"

func unhex(c byte) int {
	if c >= 'a' {
		return int(c) - 87
	}
	return int(c) - 48
}

// mix is a + (b - a) * w / 1000 per channel (w in permille).
func mix(a, b string, w int) string {
	out := []byte{'#', 0, 0, 0, 0, 0, 0}
	for i := 1; i < 7; i += 2 {
		x := unhex(a[i])*16 + unhex(a[i+1])
		y := unhex(b[i])*16 + unhex(b[i+1])
		v := clampI(x+(y-x)*w/1000, 0, 255)
		out[i], out[i+1] = hexd[v>>4], hexd[v&15]
	}
	return string(out)
}

// seasonal blends a season palette smoothly into the neighbouring seasons.
func seasonal(p []string, season, prog int) string {
	if prog < 500 {
		return mix(p[(season+3)%4], p[season], 500+prog)
	}
	return mix(p[season], p[(season+1)%4], prog-500)
}

// buf is an append-only byte buffer (amortised appends, no quadratic +=).
type buf struct{ b []byte }

func (s *buf) w(x string)  { s.b = append(s.b, x...) }
func (s *buf) n(v int)     { s.b = append(s.b, strconv.Itoa(v)...) }
func (s *buf) empty() bool { return len(s.b) == 0 }

// mv appends "M<x> <y>".
func (s *buf) mv(x, y int) {
	s.b = append(s.b, 'M')
	s.n(x)
	s.b = append(s.b, ' ')
	s.n(y)
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

const (
	cw   = 600
	ch   = 760
	gy   = 584 // ground line
	maxB = 250 // branch cap
)

// tree: spread (1/256 turn), ratio ‰, max depth, trunk length px, jitter,
// lean, 3-split %, curve %.
var tree = [][]int{
	{24, 760, 8, 150, 22, 6, 30, 16},
	{30, 700, 7, 116, 40, 12, 18, 30},
	{22, 760, 7, 138, 20, 8, 18, 20},
	{5, 900, 9, 64, 8, 3, 18, 5},
}

var barkCol = []string{"#857560", "#6b6252", "#4f3b2c", "#5a4434"}

// taper is the branch width per depth, ‰ of the trunk.
var taper = []int{1000, 640, 420, 280, 190, 130, 90, 62, 43, 30}

var (
	skyTopP = []string{"#cfe6e6", "#a9d0ea", "#e8cda6", "#d3dbe6"}
	skyBotP = []string{"#f6f1de", "#f3efdc", "#f6e9d4", "#f1f3f3"}
	sunP    = []string{"#f6d36a", "#f8c94e", "#f2b25a", "#f2efe4"}
	grassP  = []string{"#8fb36a", "#7c9b4f", "#b39a5b", "#e6ebee"}
	seaP    = []string{"#7fb0c8", "#6aa6c8", "#7f9fb0", "#9fb3c2"}
	wallP   = []string{"#dccfb6", "#e0d2b6", "#d6c6aa", "#d2ccc2"}
)

// leaves[species][season]; a deciduous autumn list runs green -> rust.
var leaves = [][][]string{
	{{"#a8c96f", "#8fb85c"}, {"#5d8a3a", "#4c7a33", "#6f9a45"}, {"#8a9a3a", "#d6a43a", "#d0702a", "#a8461f"}, {}},
	{{"#8a9a78", "#a3b08f"}, {"#7d8f6c", "#97a585"}, {"#7a8c68", "#94a382"}, {"#76866a", "#8c9a7e"}},
	{{"#9cc46a", "#b4d27c"}, {"#5f8f3c", "#6f9c48", "#527f34"}, {"#a0a040", "#d9b84a", "#c99a3a", "#a0662a"}, {}},
	{{"#3a5a3a", "#2f4a32"}, {"#2f4c34", "#24402a"}, {"#2f4a30", "#3a5536"}, {"#26402c", "#2f4a33"}},
}

var ribbonCol = []string{"#c0392b", "#f1e9d2", "#2e6da4", "#e0b03a", "#3f8a4a"}

type branch struct {
	x, y, cx, cy, ex, ey int
	d, kids, ang, len    int
	u1, u2, jx, jy       int
}

type painter struct {
	sp, maxD, curve int
	r, lr           *rng
	br              []branch
	gx, sc          int
}

func (p *painter) add(x, y, ang, ln, d int) {
	ex, ey := x+ln*cs(ang)/1024, y+ln*sn(ang)/1024
	off := ln * p.r.between(-p.curve, p.curve) / 100
	cx := (x+ex)/2 + off*cs(ang+64)/1024
	cy := (y+ey)/2 + off*sn(ang+64)/1024
	z := p.lr.next()
	p.br = append(p.br, branch{
		x: x, y: y, cx: cx, cy: cy, ex: ex, ey: ey, d: d, ang: ang, len: ln,
		u1: int(z % 1000), u2: int((z >> 10) % 1000),
		jx: int((z>>20)%9) - 4, jy: int((z>>24)%9) - 4,
	})
}

func (p *painter) X(v int) int { return p.gx + v*p.sc/8000 }
func (p *painter) Y(v int) int { return gy + v*p.sc/8000 }

// SVG renders the artwork for in under cfg.
func SVG(in engine.Input, cfg Config) string {
	seed := in.Seed
	t := derive(seed, cfg)
	c := ClockOf(in)
	sp := t.species
	season, prog := c.Season, c.Progress
	evergreen := sp == spOlive || sp == spCypress
	white := t.mark == mkWhite

	// growth: a square-root curve over three chain years
	g := isqrt(imin(c.AgeDays, FullGrowthDays) * 1000000 / FullGrowthDays)
	P := tree[sp]
	spread, ratio, maxD, L0, jit, bend, split3 := P[0], P[1], P[2], P[3], P[4], P[5], P[6]

	// tree structure from the seed alone (breadth first, so the cap trims the crown evenly)
	p := &painter{sp: sp, maxD: maxD, curve: P[7], r: newRNG(seed + "|tree"), lr: newRNG(seed + "|leaf")}
	R := p.r
	p.add(0, 0, 192+R.between(-bend, bend), L0*8, 0)
	for i := 0; i < len(p.br); i++ {
		b := &p.br[i]
		if b.d >= maxD-1 || b.len < 56 {
			continue
		}
		n := 2
		if b.d != 0 && R.intn(100) < split3 {
			n = 3
		}
		if len(p.br)+n > maxB {
			break
		}
		b.kids = n
		bex, bey, bang, blen, bd := b.ex, b.ey, b.ang, b.len, b.d
		for k := 0; k < n; k++ {
			base := (k - 1) * spread
			if n == 2 {
				base = -spread
				if k > 0 {
					base = spread
				}
			}
			na := bang + base + R.between(-jit, jit)/2
			if sp == spCypress {
				na += (192 - bang) / 2
			}
			p.add(bex, bey, na, blen*ratio*R.between(84, 110)/100000, bd+1)
		}
	}
	br := p.br

	// fit the grown tree into the frame
	minX, maxX, minY := 0, 0, 0
	for i := range br {
		b := &br[i]
		minX = imin(minX, imin(b.ex, b.cx))
		maxX = imax(maxX, imax(b.ex, b.cx))
		minY = imin(minY, imin(b.ey, b.cy))
	}
	LD := newRNG(seed + "|land")
	gx := 300 - clampI((minX+maxX)/16, -60, 60)
	fit := 1000
	if minX < 0 {
		fit = imin(fit, (gx-34)*8000/(-minX))
	}
	if maxX > 0 {
		fit = imin(fit, (566-gx)*8000/maxX)
	}
	if minY < 0 {
		fit = imin(fit, (gy-70)*8000/(-minY))
	}
	gx += LD.between(-12, 12)
	p.gx = gx
	p.sc = (520 + 480*g/1000) * fit / 1000
	dvP := 1600 + (maxD*1000-1600)*g/1000
	tw10 := (60 + 240*g/1000) * fit / 1000 // trunk width, tenths of a px

	// visible geometry per branch (partial growth = de Casteljau split at f)
	byD := make([]buf, maxD+1)
	var tips []int // x, y, kind, branch index
	trunkTopX, trunkTopY, fork := gx, gy, -1
	for i := range br {
		b := &br[i]
		if b.d*1000 >= dvP {
			continue
		}
		f := imin(1000, dvP-b.d*1000)
		cx, cy, ex, ey := b.cx, b.cy, b.ex, b.ey
		if f < 1000 {
			ax, ay := b.x+(b.cx-b.x)*f/1000, b.y+(b.cy-b.y)*f/1000
			bx, by := b.cx+(b.ex-b.cx)*f/1000, b.cy+(b.ey-b.cy)*f/1000
			ex = ax + (bx-ax)*f/1000
			ey = ay + (by-ay)*f/1000
			cx, cy = ax, ay
		}
		bb := &byD[b.d]
		bb.mv(p.X(b.x), p.Y(b.y))
		bb.w("Q")
		bb.n(p.X(cx))
		bb.w(" ")
		bb.n(p.Y(cy))
		bb.w(" ")
		bb.n(p.X(ex))
		bb.w(" ")
		bb.n(p.Y(ey))
		if b.d == 0 {
			trunkTopX, trunkTopY = p.X(ex), p.Y(ey)
		}
		if b.d == 2 && fork < 0 {
			fork = i
		}
		terminal := (b.d+1)*1000 >= dvP || b.kids == 0
		if b.d >= 1 && (terminal || b.d >= maxD-2 || (sp == spCypress && b.d >= 2)) {
			kind := 1
			if terminal {
				kind = 0
			}
			tips = append(tips, p.X(ex)+b.jx, p.Y(ey)+b.jy, kind, i)
		}
	}
	trunkW10 := imax(10, tw10)

	// palette for this moment
	skyTop, skyBot := seasonal(skyTopP, season, prog), seasonal(skyBotP, season, prog)
	grass := seasonal(grassP, season, prog)
	bark := barkCol[sp]
	if white {
		bark = "#dcd6ca"
	}
	barkLight := mix(bark, "#fff4e0", 320)

	o := &buf{b: make([]byte, 0, 24576)}
	o.w(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 600 760" width="600" height="760"><defs>`)
	o.w(`<linearGradient id="sk" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="` + skyTop +
		`"/><stop offset="1" stop-color="` + skyBot + `"/></linearGradient>`)
	o.w(`<radialGradient id="vg" cx=".5" cy=".45" r=".75"><stop offset=".6" stop-opacity="0"/><stop offset="1" stop-opacity=".22"/></radialGradient>`)
	o.w(`<pattern id="so" width="40" height="22" patternUnits="userSpaceOnUse"><circle cx="8" cy="6" r="2.2" fill="#3a2a1e" fill-opacity=".3"/><circle cx="28" cy="16" r="1.4" fill="#e8d8c0" fill-opacity=".18"/></pattern>`)
	o.w(`<g id="cl"><ellipse rx="46" ry="14"/><ellipse cx="-16" cy="-9" rx="22" ry="15"/><ellipse cx="14" cy="-13" rx="26" ry="19"/></g>`)
	o.w(`<path id="lf" d="M0 0q4-3 8 0q-4 3-8 0z"/>`)
	for d := range byD {
		if !byD[d].empty() {
			o.w(`<path id="b` + itoa(d) + `" d="`)
			o.b = append(o.b, byD[d].b...)
			o.w(`"/>`)
		}
	}

	// leaves: colour groups as dot paths, drawn in three tones
	pal := leaves[sp][season]
	groups := make([]buf, len(pal))
	var hl, blossom, flowers, fruit, balls buf
	k := (450 + 550*g/1000) * fit / 1000
	plane, judas := sp == spPlane, sp == spJudas
	lwk := 11
	switch sp {
	case spPlane:
		lwk = 22
	case spJudas:
		lwk = 20
	case spOlive:
		lwk = 12
	}
	lw := imax(5, lwk*k/1000)
	for i := 0; i < len(tips); i += 4 {
		x, y := tips[i], tips[i+1]
		b := &br[tips[i+3]]
		u1, u2 := b.u1, b.u2
		show := len(pal) > 0
		ci := u2 % imax(1, len(pal))
		if !evergreen {
			if season == 0 {
				if judas {
					show = u1 < (prog-300)*2
				} else {
					show = u1 < prog*17/10
				}
			} else if season == 2 {
				show = u1 >= prog*95/100
				ci = imin(3, (prog*3+u2)/1000)
			}
		}
		if show {
			gb := &groups[ci]
			gb.mv(x, y)
			switch sp {
			case spCypress:
				L := imax(6, 16*k/1000)
				gb.w("v-")
				gb.n(L)
				gb.w("m-5 ")
				gb.n(L - 3)
				gb.w("v-")
				gb.n(L - 2)
			case spOlive:
				gb.w("h.1m7 -5h.1m-13 9h.1")
			default:
				gb.w("h.1m")
				gb.n(lw*6/10 + b.jy)
				gb.w(" ")
				gb.n(3 + b.jx)
				gb.w("h.1m")
				gb.n(-(lw * 11 / 10) - b.jx)
				gb.w(" ")
				gb.n(-(lw * 6 / 10))
				gb.w("h.1")
			}
			if u2 < 450 {
				hl.mv(x, y)
				if sp == spCypress {
					hl.w("v-6")
				} else {
					hl.w("h.1")
				}
			}
		}
		if judas && season == 0 {
			bloom := 1000
			if prog < 200 {
				bloom = prog * 5
			} else if prog >= 450 {
				bloom = 1000 - (prog-450)*4
			}
			if u2 < bloom {
				blossom.mv(x, y)
				blossom.w("h.1")
				blossom.mv(p.X(b.cx)+b.jy, p.Y(b.cy)+b.jx)
				blossom.w("h.1")
			}
		}
		if sp == spOlive && season == 0 && prog > 500 && prog < 900 && u2 < 400 {
			flowers.mv(x+b.jy, y-3)
			flowers.w("h.1")
		}
		if sp == spOlive && (season == 2 || (season == 3 && prog < 300)) && u2 < 300 {
			fruit.mv(x-b.jy, y+5)
			fruit.w("h.1")
		}
		if plane && (season == 3 || (season == 2 && prog > 300)) && u2 < 220 {
			fruit.mv(x, y+4)
			fruit.w("v7")
			balls.mv(x, y+15)
			balls.w("h.1")
		}
	}
	anyLeaf := false
	for i := range groups {
		if !groups[i].empty() {
			anyLeaf = true
			o.w(`<path id="v` + itoa(i) + `" d="`)
			o.b = append(o.b, groups[i].b...)
			o.w(`"/>`)
		}
	}
	if !hl.empty() {
		o.w(`<path id="vh" d="`)
		o.b = append(o.b, hl.b...)
		o.w(`"/>`)
	}
	o.w(`</defs>`)

	// sky, sun, clouds, birds
	o.w(`<rect width="600" height="` + itoa(gy) + `" fill="url(#sk)"/>`)
	sunX := LD.between(70, 530)
	sunY := 175 - 85*sn(c.YearAngle)/1024
	sun := seasonal(sunP, season, prog)
	o.w(`<circle cx="` + itoa(sunX) + `" cy="` + itoa(sunY) + `" r="46" fill="` + sun + `" fill-opacity=".22"/><circle cx="` +
		itoa(sunX) + `" cy="` + itoa(sunY) + `" r="26" fill="` + sun + `"/>`)
	CR := newRNG(seed + "|sky|" + itoa(c.Day))
	nClouds := CR.intn(4)
	clouds := make([]int, 0, 9)
	for i := 0; i < 3; i++ {
		a := CR.between(40, 560)
		b := CR.between(50, 240)
		s := CR.between(7, 15)
		clouds = append(clouds, a, b, s)
	}
	snowing := CR.intn(100) < 50
	nBirds := CR.intn(3)
	birds := make([]int, 0, 4)
	for i := 0; i < 2; i++ {
		a := CR.between(60, 540)
		b := CR.between(70, 260)
		birds = append(birds, a, b)
	}
	if nClouds > 0 {
		op := ".72"
		if season == 3 {
			op = ".85"
		}
		o.w(`<g fill="#fff" opacity="` + op + `">`)
		for i := 0; i < nClouds; i++ {
			o.w(`<use href="#cl" transform="translate(` + itoa(clouds[i*3]) + ` ` + itoa(clouds[i*3+1]) + `) scale(` +
				f10(clouds[i*3+2]) + `)"/>`)
		}
		o.w(`</g>`)
	}
	if (season == 0 || season == 1) && nBirds > 0 {
		var d buf
		for i := 0; i < nBirds; i++ {
			d.mv(birds[i*2], birds[i*2+1])
			d.w("q4 -5 8 0q4 -5 8 0")
		}
		o.w(`<path d="` + string(d.b) + `" stroke="#3a3530" stroke-width="1.5" fill="none" stroke-linecap="round"/>`)
	}

	// the setting
	far, near := mix(grass, skyBot, 520), mix(grass, skyBot, 220)
	switch t.setting {
	case setHill:
		a := LD.between(80, 260)
		b2 := LD.between(330, 520)
		o.w(`<path d="M0 ` + itoa(gy-70) + `Q` + itoa(a) + ` ` + itoa(gy-175) + ` ` + itoa(a+170) + ` ` + itoa(gy-92) +
			`T600 ` + itoa(gy-120) + `V` + itoa(gy) + `H0z" fill="` + far + `"/>`)
		o.w(`<path d="M0 ` + itoa(gy-22) + `Q` + itoa(b2-200) + ` ` + itoa(gy-96) + ` ` + itoa(b2) + ` ` + itoa(gy-34) +
			`T600 ` + itoa(gy-40) + `V` + itoa(gy) + `H0z" fill="` + near + `"/>`)
	case setCourtyard:
		wall := seasonal(wallP, season, prog)
		nx := LD.between(70, 530)
		o.w(`<pattern id="bk" width="60" height="25" patternUnits="userSpaceOnUse"><path d="M0 .5H60M30 .5V12.5M0 12.5H60M.5 12.5V25" stroke="#000" stroke-opacity=".13" fill="none"/></pattern>`)
		o.w(`<rect y="` + itoa(gy-150) + `" width="600" height="150" fill="` + wall + `"/><rect y="` + itoa(gy-150) +
			`" width="600" height="150" fill="url(#bk)"/>`)
		o.w(`<path d="M` + itoa(nx-24) + ` ` + itoa(gy) + `V` + itoa(gy-84) + `a24 24 0 0 1 48 0V` + itoa(gy) + `z" fill="` +
			mix(wall, "#3a2a1e", 300) + `"/>`)
		o.w(`<rect y="` + itoa(gy-158) + `" width="600" height="10" fill="` + mix(wall, "#6a5a44", 220) + `"/>`)
	case setShore:
		sea := seasonal(seaP, season, prog)
		bx := LD.between(60, 500)
		o.w(`<path d="M0 ` + itoa(gy-96) + `Q90 ` + itoa(gy-112) + ` 180 ` + itoa(gy-98) + `V` + itoa(gy-92) + `H0z" fill="` + far + `"/>`)
		o.w(`<rect y="` + itoa(gy-94) + `" width="600" height="94" fill="` + sea + `"/>`)
		o.w(`<path d="M0 ` + itoa(gy-70) + `h600M0 ` + itoa(gy-44) + `h600M0 ` + itoa(gy-20) +
			`h600" stroke="#fff" stroke-opacity=".35" stroke-dasharray="18 34"/>`)
		o.w(`<path d="M` + itoa(bx) + ` ` + itoa(gy-100) + `h30l-5 6h-21zM` + itoa(bx+14) + ` ` + itoa(gy-101) +
			`v-24l13 22z" fill="#5a4a3a"/>`)
	default:
		var d buf
		d.w("M0 ")
		d.n(gy - 50)
		for i := 1; i <= 8; i++ {
			d.w("L")
			d.n(i * 75)
			d.w(" ")
			d.n(gy - LD.between(30, 128))
		}
		o.w(`<path d="` + string(d.b) + `V` + itoa(gy) + `H0z" fill="` + mix(skyBot, "#5d6e86", 260) + `"/>`)
		o.w(`<rect y="` + itoa(gy-26) + `" width="600" height="26" fill="` + mix(grass, "#d8b870", 360) + `"/>`)
	}

	// ground, soil, roots
	o.w(`<rect y="` + itoa(gy-4) + `" width="600" height="12" fill="` + grass + `"/>`)
	soilH := itoa(ch - gy - 6)
	o.w(`<rect y="` + itoa(gy+6) + `" width="600" height="` + soilH + `" fill="#6b5240"/><rect y="` + itoa(gy+6) +
		`" width="600" height="` + soilH + `" fill="url(#so)"/>`)
	o.w(`<path d="M0 ` + itoa(gy+62) + `q150 -8 300 0t300 0M0 ` + itoa(gy+122) +
		`q150 7 300 0t300 0" stroke="#4e3b2c" stroke-width="3" stroke-opacity=".45" fill="none"/>`)
	if season != 3 {
		var d buf
		for i := 0; i < 18; i++ {
			d.mv(LD.between(10, 590), gy-2)
			d.w("l-3 -7m3 7l1 -9m-1 9l4 -6")
		}
		o.w(`<path d="` + string(d.b) + `" stroke="` + mix(grass, "#1e2a10", 350) +
			`" stroke-width="1.4" fill="none" stroke-linecap="round"/>`)
	}
	// roots: one seeded structure; the current owner's roots (holding time)
	// solid, the tree's lifetime roots (age) as a faint ghost below them
	RR := newRNG(seed + "|roots")
	var roots []int // x, y, ex, ey, d
	rq := make([]int, 0, 5*189)
	for i := 0; i < 3; i++ {
		rq = append(rq, 0, 0, 64+(i-1)*30+RR.between(-6, 6), 46*8, 0)
	}
	for i := 0; i < len(rq); i += 5 {
		x, y, ang, ln, d := rq[i], rq[i+1], rq[i+2], rq[i+3], rq[i+4]
		ex, ey := x+ln*cs(ang)/1024, y+ln*sn(ang)/1024
		roots = append(roots, x, y, ex, ey, d)
		if d < 5 {
			for s := -1; s <= 1; s += 2 {
				rq = append(rq, ex, ey, clampI(ang+s*RR.between(10, 26), 10, 118), ln*72/100, d+1)
			}
		}
	}
	rs := 600 + 400*g/1000
	rootPaths := func(depthP int) []buf {
		ps := make([]buf, 6)
		for i := 0; i < len(roots); i += 5 {
			d := roots[i+4]
			if d*1000 >= depthP {
				continue
			}
			f := imin(1000, depthP-d*1000)
			x, y := roots[i], roots[i+1]
			ex, ey := x+(roots[i+2]-x)*f/1000, y+(roots[i+3]-y)*f/1000
			ps[d].mv(gx+x*rs/8000, gy+6+y*rs/8000)
			ps[d].w("L")
			ps[d].n(gx + ex*rs/8000)
			ps[d].w(" ")
			ps[d].n(gy + 6 + ey*rs/8000)
		}
		return ps
	}
	ageRoots := 400 + imin(c.AgeDays, 730)*5600/730
	holdRoots := 400 + imin(c.HoldDays, FullRootsDays)*5600/FullRootsDays
	if ageRoots > holdRoots {
		o.w(`<path d="`)
		for _, ps := range rootPaths(ageRoots) {
			o.b = append(o.b, ps.b...)
		}
		o.w(`" stroke="#2a1c12" stroke-opacity=".28" stroke-width="1.5" fill="none" stroke-linecap="round"/>`)
	}
	rp := rootPaths(holdRoots)
	o.w(`<g stroke="#33231a" fill="none" stroke-linecap="round">`)
	for d := range rp {
		if !rp[d].empty() {
			o.w(`<path d="`)
			o.b = append(o.b, rp[d].b...)
			o.w(`" stroke-width="` + f10(imax(10, trunkW10*taper[d+1]/1600)) + `"/>`)
		}
	}
	o.w(`</g>`)

	// trunk flare, branches, bark light
	tw := trunkW10/10 + 1
	o.w(`<path d="M` + itoa(gx-tw*16/10) + ` ` + itoa(gy+2) + `Q` + itoa(gx-tw/2) + ` ` + itoa(gy-1) + ` ` + itoa(gx-tw/2) + ` ` +
		itoa(gy-tw*13/10) + `H` + itoa(gx+tw/2) + `Q` + itoa(gx+tw/2) + ` ` + itoa(gy-1) + ` ` + itoa(gx+tw*16/10) + ` ` +
		itoa(gy+2) + `z" fill="` + bark + `"/>`)
	o.w(`<g stroke="` + bark + `" fill="none" stroke-linecap="round">`)
	for d := range byD {
		if !byD[d].empty() {
			o.w(`<use href="#b` + itoa(d) + `" stroke-width="` + f10(imax(8, trunkW10*taper[d]/1000)) + `"/>`)
		}
	}
	o.w(`</g><g stroke="` + barkLight + `" fill="none" stroke-linecap="round" stroke-opacity=".7">`)
	for d := range byD {
		wd := trunkW10 * taper[d] / 1000
		if !byD[d].empty() && wd >= 20 {
			o.w(`<use href="#b` + itoa(d) + `" stroke-width="` + f10(wd*35/100) + `" transform="translate(-` + f10(wd*22/100) + ` 0)"/>`)
		}
	}
	o.w(`</g>`)
	MK := newRNG(seed + "|marks")
	if plane && tw >= 8 && !white {
		o.w(`<g fill="#d9cfb2" fill-opacity=".55">`)
		for i := 0; i < 7; i++ {
			v := MK.between(80, 900)
			px := gx + (trunkTopX-gx)*v/1000 + MK.between(-(tw/3), tw/3)
			py := gy + (trunkTopY-gy)*v/1000
			o.w(`<ellipse cx="` + itoa(px) + `" cy="` + itoa(py) + `" rx="` + itoa(imax(2, tw/6)) + `" ry="` + itoa(imax(3, tw/3)) + `"/>`)
		}
		o.w(`</g>`)
	}
	if season == 3 {
		o.w(`<g stroke="#fbfcfd" fill="none" stroke-linecap="round">`)
		for d := 1; d < len(byD); d++ {
			wd := imax(8, trunkW10*taper[d]/1000)
			if !byD[d].empty() {
				o.w(`<use href="#b` + itoa(d) + `" stroke-width="` + f10(imax(6, wd*4/10)) + `" transform="translate(0 -` +
					f10(imax(4, wd*35/100)) + `)"/>`)
			}
		}
		o.w(`</g>`)
	}
	if c.AgeDays < 30 {
		// a sapling is staked and tied
		o.w(`<path d="M` + itoa(gx+9) + ` ` + itoa(gy+6) + `V` + itoa(gy-54) + `" stroke="#a0825a" stroke-width="3" stroke-linecap="round"/><path d="M` +
			itoa(gx) + ` ` + itoa(gy-40) + `h9M` + itoa(gx) + ` ` + itoa(gy-22) + `h9" stroke="#d8c49a" stroke-width="2"/>`)
	}

	// the owners: notches, the first owner's seal, moss, ribbons, nest
	trunkH := gy - trunkTopY
	along := func(y int) int {
		if trunkH > 0 {
			return gx + (trunkTopX-gx)*(gy-y)/trunkH
		}
		return gx
	}
	if c.Moves == 0 {
		y := gy - trunkH*42/100
		r := imax(3, tw*3/10)
		o.w(`<circle cx="` + itoa(along(y)) + `" cy="` + itoa(y) + `" r="` + itoa(r) + `" fill="none" stroke="#2a1d14" stroke-width="1.6"/><circle cx="` +
			itoa(along(y)) + `" cy="` + itoa(y) + `" r="1.5" fill="#2a1d14"/>`)
	} else {
		room := imax(1, (trunkH*85/100-14)/5+1)
		n := imin(c.Moves, imin(25, room))
		nw := imax(5, tw+3)
		var d buf
		for i := 0; i < n; i++ {
			y := gy - 14 - i*5 - i/5*4
			d.mv(along(y)-nw/2, y)
			d.w("l")
			d.n(nw)
			d.w(" -3")
		}
		o.w(`<path d="` + string(d.b) + `" stroke="#2a1d14" stroke-width="1.6" stroke-linecap="round"/>`)
	}
	if c.HoldDays >= 180 {
		n := imin(24, 6+(c.HoldDays-180)/20)
		var d buf
		for i := 0; i < n; i++ {
			d.mv(gx-tw+(i*7)%imax(3, 2*tw), gy-(i*5)%22)
			d.w("h.1")
		}
		o.w(`<path d="` + string(d.b) + `" stroke="#5f8a3a" stroke-width="4" stroke-linecap="round"/>`)
	}
	if t.mark == mkLightning && trunkH > 20 {
		y0, h3 := gy-trunkH*88/100, trunkH/6
		zig := `<path d="M` + itoa(along(y0)) + ` ` + itoa(y0) + `l-4 ` + itoa(h3) + ` 6 4 -5 ` + itoa(h3) + ` 5 3 -3 ` + itoa(h3)
		o.w(zig + `" stroke="#2a1a10" stroke-width="4" fill="none" stroke-linejoin="round"/>`)
		o.w(zig + `" stroke="#f1e6c8" stroke-width="1.8" fill="none" stroke-linejoin="round"/>`)
	}
	if t.mark == mkWish {
		// every owner ties ribbons: more transfers, more ribbons
		want := imin(28, 4+c.Moves*3)
		ribbons := make([]buf, 5)
		n := 0
		for i := 0; i < len(br) && n < want; i++ {
			b := &br[i]
			if b.d < 1 || b.d > 3 || b.d*1000+1000 > dvP {
				continue
			}
			ln := 12 + b.u1%10
			rb := &ribbons[n%5]
			rb.mv(p.X(b.cx), p.Y(b.cy))
			rb.w("q")
			rb.n(b.jx)
			rb.w(" ")
			rb.n(ln / 2)
			rb.w(" ")
			rb.n(b.jy)
			rb.w(" ")
			rb.n(ln)
			n++
		}
		for i := range ribbons {
			if !ribbons[i].empty() {
				o.w(`<path d="` + string(ribbons[i].b) + `" stroke="` + ribbonCol[i] + `" stroke-width="3" fill="none" stroke-linecap="round"/>`)
			}
		}
	}
	if c.HoldDays >= FullRootsDays && fork >= 0 {
		b := &br[fork]
		x, y := p.X(b.x), p.Y(b.y)
		o.w(`<ellipse cx="` + itoa(x) + `" cy="` + itoa(y+3) + `" rx="13" ry="6" fill="#6a4a2a"/><path d="M` + itoa(x-12) + ` ` +
			itoa(y+1) + `q12 6 24 0" stroke="#3a2818" fill="none"/>`)
		if season == 0 {
			o.w(`<circle cx="` + itoa(x-4) + `" cy="` + itoa(y) + `" r="3" fill="#9fd0e0"/><circle cx="` + itoa(x+3) + `" cy="` +
				itoa(y) + `" r="3" fill="#9fd0e0"/>`)
		}
	}

	// the crown
	if anyLeaf {
		base0 := pal[0]
		if white {
			base0 = mix(base0, "#f4f1e8", 550)
		}
		shade := mix(base0, "#1d2a14", 480)
		light := mix(base0, "#fff8e0", 380)
		if season == 3 {
			light = "#f6f8fa"
		}
		if sp == spCypress {
			// the cypress's flame: a closed column behind the sprays
			x0, x1, y0, y1 := tips[0], tips[0], tips[1], tips[1]
			for i := 0; i < len(tips); i += 4 {
				x0 = imin(x0, tips[i])
				x1 = imax(x1, tips[i])
				y0 = imin(y0, tips[i+1])
				y1 = imax(y1, tips[i+1])
			}
			mx, hw, top, bot := (x0+x1)/2, imax(8, (x1-x0)/2+6), y0-16, y1+6
			hh := bot - top
			fd := "M" + itoa(mx) + " " + itoa(top) + "C" + itoa(mx+hw) + " " + itoa(top+hh*35/100) + " " + itoa(mx+hw*9/10) + " " +
				itoa(bot) + " " + itoa(mx) + " " + itoa(bot+8) + "C" + itoa(mx-hw*9/10) + " " + itoa(bot) + " " + itoa(mx-hw) + " " +
				itoa(top+hh*35/100) + " " + itoa(mx) + " " + itoa(top) + "z"
			flame := pal[1]
			if white {
				flame = mix(pal[1], "#f4f1e8", 550)
			}
			o.w(`<path d="` + fd + `" fill="` + shade + `" fill-opacity=".6" transform="translate(2 3)"/><path d="` + fd + `" fill="` + flame + `"/>`)
		}
		o.w(`<g fill="none" stroke-linecap="round"><g stroke="` + shade + `" stroke-opacity=".6" stroke-width="` + itoa(lw+4) +
			`" transform="translate(2 3)">`)
		for i := range groups {
			if !groups[i].empty() {
				o.w(`<use href="#v` + itoa(i) + `"/>`)
			}
		}
		o.w(`</g><g stroke-width="` + itoa(lw) + `">`)
		for i := range groups {
			col := pal[i]
			if white {
				col = mix(col, "#f4f1e8", 550)
			}
			if !groups[i].empty() {
				o.w(`<use href="#v` + itoa(i) + `" stroke="` + col + `"/>`)
			}
		}
		o.w(`</g>`)
		if !hl.empty() {
			op := ".55"
			if season == 3 {
				op = ".9"
			}
			o.w(`<use href="#vh" stroke="` + light + `" stroke-opacity="` + op + `" stroke-width="` + itoa(imax(3, lw*45/100)) +
				`" transform="translate(-3 -4)"/>`)
		}
		o.w(`</g>`)
	}
	if !blossom.empty() {
		o.w(`<path d="` + string(blossom.b) + `" stroke="#c8457f" stroke-width="` + itoa(imax(5, 9*k/1000)) + `" stroke-linecap="round"/>`)
	}
	if !flowers.empty() {
		o.w(`<path d="` + string(flowers.b) + `" stroke="#f4f0e0" stroke-width="4" stroke-linecap="round"/>`)
	}
	if !fruit.empty() {
		if plane {
			o.w(`<path d="` + string(fruit.b) + `" stroke="#6e5236" stroke-width="1.2" stroke-linecap="round"/>`)
		} else {
			o.w(`<path d="` + string(fruit.b) + `" stroke="#3a2440" stroke-width="5" stroke-linecap="round"/>`)
		}
	}
	if !balls.empty() {
		o.w(`<path d="` + string(balls.b) + `" stroke="#7a5a3a" stroke-width="6" stroke-linecap="round"/>`)
	}

	// fallen leaves, snow
	if !evergreen && (season == 2 || season == 3) {
		FR := newRNG(seed + "|fall|" + itoa(season))
		n := 8
		fall := []string{"#8a6a4a"}
		if season == 2 {
			n = 6 + prog*44/1000
			fall = leaves[sp][2][1:]
		}
		lg := make([]buf, len(fall))
		for i := 0; i < n; i++ {
			x := FR.between(70, 530)
			var y int
			if i%4 == 0 && season == 2 {
				y = FR.between(gy-260, gy-20)
			} else {
				y = gy + FR.between(-4, 5)
			}
			l := &lg[i%len(lg)]
			l.w(`<use href="#lf" x="`)
			l.n(x)
			l.w(`" y="`)
			l.n(y)
			l.w(`"/>`)
		}
		for i := range lg {
			if !lg[i].empty() {
				o.w(`<g fill="` + fall[i] + `">` + string(lg[i].b) + `</g>`)
			}
		}
	}
	if season == 3 {
		o.w(`<path d="M0 ` + itoa(gy-5) + `h600v10H0z" fill="#f7f9fb"/>`)
		if snowing {
			SR := newRNG(seed + "|snow|" + itoa(c.Day))
			var d buf
			for i := 0; i < 40; i++ {
				x := SR.between(5, 595)
				y := SR.between(10, gy-10)
				d.mv(x, y)
				d.w("h.1")
			}
			o.w(`<path d="` + string(d.b) + `" stroke="#fff" stroke-width="3.5" stroke-linecap="round" stroke-opacity=".9"/>`)
		}
	}

	// frame, chain-time strip, year dial
	o.w(`<rect width="600" height="760" fill="url(#vg)"/>`)
	o.w(`<rect y="` + itoa(ch-30) + `" width="600" height="30" fill="#1c140e" fill-opacity=".4"/>`)
	tr := " transfers"
	if c.Moves == 1 {
		tr = " transfer"
	}
	o.w(`<text x="16" y="` + itoa(ch-11) + `" font-family="Menlo, monospace" font-size="11" fill="#f4ecdf">block ` + itoa(c.Height) +
		` · ` + seasonNames[season] + ` · age ` + itoa(c.AgeDays) + ` d · rooted ` + itoa(c.HoldDays) + ` d · ` + itoa(c.Moves) + tr + `</text>`)
	dx, dy := cw-22, ch-15
	o.w(`<g fill="none" stroke-width="2.5"><path d="M` + itoa(dx) + ` ` + itoa(dy-9) + `a9 9 0 0 1 9 9" stroke="#9fc46a"/><path d="M` +
		itoa(dx+9) + ` ` + itoa(dy) + `a9 9 0 0 1 -9 9" stroke="#f2c94e"/><path d="M` + itoa(dx) + ` ` + itoa(dy+9) +
		`a9 9 0 0 1 -9 -9" stroke="#d0702a"/><path d="M` + itoa(dx-9) + ` ` + itoa(dy) + `a9 9 0 0 1 9 -9" stroke="#e6ebee"/></g>`)
	ha := 192 + c.YearAngle
	o.w(`<path d="M` + itoa(dx) + ` ` + itoa(dy) + `L` + itoa(dx+8*cs(ha)/1024) + ` ` + itoa(dy+8*sn(ha)/1024) +
		`" stroke="#f4ecdf" stroke-width="1.6" stroke-linecap="round"/>`)
	o.w(`</svg>`)
	return string(o.b)
}
