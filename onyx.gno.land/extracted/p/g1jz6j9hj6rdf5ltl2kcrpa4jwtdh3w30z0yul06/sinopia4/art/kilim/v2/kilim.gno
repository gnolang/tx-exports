// Package kilim (v2, "Niyet") is a Sinopia engine: a flat-woven rug that
// says something. The seed first chooses an intent (Protection, Abundance,
// Wish, Strength), then a main motif and two companions from fourteen
// Anatolian motif families, each with its traditional meaning (Elibelinde,
// Koçboynuzu, Bereket, Nazarlık, ...). The motifs are woven cell by cell on a
// 49 x 75 loom grid into one of five layouts inside one of five borders, and
// the token number is woven into the bottom frame as a 14-bit band (the
// "künye"). The meanings reach collectors through the traits (Main Motif,
// Companions and Border carry them) and the SVG's <title>/<desc>.
//
// It is the successor of Kilim v1 (p/.../art/kilim/v1, which stays untouched):
// the same loom, the same FNV-1a + splitmix64 streams (seed+"|traits" and
// seed+"|art"), the same run-length SVG encoding, a richer field.
// frontend/src/engines/kilimv2.ts is a byte-identical TypeScript twin;
// kilim_test.gno pins golden vectors that the twin asserts too.
//
// Unlike v1 the art reads Input.TokenID (the künye). It never reads heights
// or moves, so the engine is not living. Pure integer maths: no floats, no
// time, no block data.
package kilim

import (
	"errors"
	"strconv"
	"strings"

	"gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia4/engine/v2"
)

// TraitTypes in the order Traits returns them.
var traitTypes = []string{"Intent", "Main Motif", "Companions", "Layout", "Border", "Dyes", "Weaver's Mark", "Rarity"}

// MaxSVGBytes: the largest output over 10,000 default seeds is about 14.6 KB
// (docs/engines/kilim-v2.md); about 2x margin, within the 28 KB budget.
const MaxSVGBytes = 28672

// ParamsSchema is the Studio form. Studio sends JSON.stringify of the values
// in this property order; ValidateParams accepts exactly that or "".
const ParamsSchema = `{"type":"object","properties":{` +
	`"intent":{"type":"string","title":"Intent","enum":["Seeded","Protection","Abundance","Wish","Strength"],"default":"Seeded"},` +
	`"layout":{"type":"string","title":"Layout","enum":["Seeded","Three Göls","Great Göl","Lattice","Bands","Mihrab"],"default":"Seeded"},` +
	`"dyes":{"type":"string","title":"Dyes","enum":["Seeded","Madder & Indigo","Buckthorn Gold","Walnut & Fleece",` +
	`"Pomegranate","Night Indigo","Highland Green","Sinopia Earth","Saffron & Plum"],"default":"Seeded"}}}`

// DefaultParams is the canonical form of the defaults; it renders exactly
// like "".
const DefaultParams = `{"intent":"Seeded","layout":"Seeded","dyes":"Seeded"}`

// Manifest describes the engine. Author and FeeBps are set by the adapter.
func Manifest() engine.Manifest {
	return engine.Manifest{
		Name:    "Kilim · Niyet",
		Version: "2.0.0",
		Description: "Kilim v2: a flat-woven rug that speaks. Each rug chooses an intent (protection, abundance, " +
			"a wish or strength) and weaves a main motif and two companions from fourteen Anatolian motif " +
			"families, each with its traditional meaning, inside a meaningful border. The traits carry the " +
			"meanings; the token number is woven into the bottom frame in binary.",
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
	Intent, Layout, Dyes int
}

// Defaults is the showcase look (params "").
func Defaults() Config { return Config{Intent: -1, Layout: -1, Dyes: -1} }

var errParams = errors.New(`kilimv2: params must be "" or ` +
	`{"intent":<enum>,"layout":<enum>,"dyes":<enum>} in that order, without spaces`)

// ParseParams accepts "" or the canonical JSON Studio produces, nothing else.
func ParseParams(params string) (Config, error) {
	cfg := Defaults()
	if params == "" {
		return cfg, nil
	}
	v, rest, ok := strValue(params, `{"intent":"`)
	if !ok {
		return cfg, errParams
	}
	if cfg.Intent, ok = enumIndex(v, intentOpts); !ok {
		return cfg, errParams
	}
	if v, rest, ok = strValue(rest, `","layout":"`); !ok {
		return cfg, errParams
	}
	if cfg.Layout, ok = enumIndex(v, layoutOpts); !ok {
		return cfg, errParams
	}
	if v, rest, ok = strValue(rest, `","dyes":"`); !ok {
		return cfg, errParams
	}
	if cfg.Dyes, ok = enumIndex(v, dyeOpts); !ok {
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
// renders: eleven draws and a score.
func Traits(in engine.Input) []engine.Trait {
	t := TraitsOf(in.Seed, mustConfig(in.Params))
	return []engine.Trait{
		{Type: "Intent", Value: t.Intent},
		{Type: "Main Motif", Value: t.MainMotif},
		{Type: "Companions", Value: t.Companions},
		{Type: "Layout", Value: t.Layout},
		{Type: "Border", Value: t.Border},
		{Type: "Dyes", Value: t.Dyes},
		{Type: "Weaver's Mark", Value: t.Mark},
		{Type: "Rarity", Value: t.Rarity},
	}
}

// Render returns the raw SVG for in.Seed, in.Params and in.TokenID.
func Render(in engine.Input) string { return SVG(in.Seed, mustConfig(in.Params), in.TokenID) }

// ---------------------------------------------------------------------------
// Deterministic randomness: FNV-1a over the seed, then splitmix64 (Kilim v1's
// stream). Traits use seed+"|traits", the art seed+"|art".
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
// Motifs. Bitmaps: '.' empty, '#' outline, '+' light, 'o' accent; drawn for
// this engine on the loom grid (odd widths, stepped diagonals).
// ---------------------------------------------------------------------------

type motif struct {
	name, gloss, meaning string
	bm                   []string
}

var motifs = []motif{
	{"Elibelinde", "motherhood", "motherhood and fertility", []string{
		"....#o#....", "....###....", ".....#.....", ".#########.", "#.#.#+#.#.#", "#..##o##..#",
		".#..#+#..#.", "..#######..", "...#+o+#...", "..#+++++#..", ".#+++o+++#.", "###########"}},
	{"Koçboynuzu", "strength", "strength, heroism and male fertility", []string{
		".###...###.", "#...#.#...#", "#.#.#.#.#.#", "#.###.###.#", "##...#...##", ".#...#...#.",
		".....#.....", "....#+#....", "...#+o+#...", "....#+#....", ".....#....."}},
	{"Bereket", "plenty", "plenty and a fruitful home", []string{
		"#....#....#", ".#..###..#.", "..#######..", ".##+#+#+##.", "###+o+o+###", ".##+#+#+##.",
		"..#######..", ".#..###..#.", "#....#....#"}},
	{"Nazarlık", "warding", "protection from the evil eye", []string{
		".....#.....", "....#+#....", "...#+++#...", "..#++o++#..", ".#++ooo++#.", "#++oo#oo++#",
		".#++ooo++#.", "..#++o++#..", "...#+++#...", "....#+#....", ".....#....."}},
	{"Yıldız", "luck", "happiness, luck and guidance", []string{
		".....#.....", ".#...#...#.", "..#.###.#..", "...#####...", "..##+++##..", "####+o+####",
		"..##+++##..", "...#####...", "..#.###.#..", ".#...#...#.", ".....#....."}},
	{"Hayat Ağacı", "eternity", "immortality and the line that goes on", []string{
		".....o.....", "....###....", "..#..#..#..", ".###.#.###.", "..#.#+#.#..", ".....#.....",
		".#..###..#.", "###.#+#.###", ".#..#+#..#.", ".....#.....", "..#..#..#..", ".###+#+###.", "...#####..."}},
	{"Pıtrak", "defence", "a thorn that wards off evil", []string{
		"..#..#..#..", "...#.#.#...", "#...###...#", ".#.##+##.#.", "..##+o+##..", "####ooo####",
		"..##+o+##..", ".#.##+##.#.", "#...###...#", "...#.#.#...", "..#..#..#.."}},
	{"Akrep", "safety", "safety from scorpions and all harm", []string{
		"..#.....#..", ".#.#...#.#.", "..#.###.#..", "...##+##...", "....#+#....", "..#######..",
		".#..#o#..#.", "#...#+#...#", "....###....", ".....#.....", "....#.#...."}},
	{"Kurt İzi", "valour", "guarding the flock; courage", []string{
		"...#...#...", "..###.###..", "...#...#...", ".#.......#.", "###.....###", ".#..###..#.",
		"...#####...", "..###o###..", "...#####...", "....###...."}},
	{"Saç Bağı", "marriage", "the wish to marry", []string{
		"#.........#", "##.......##", "#+#.....#+#", "#++#...#++#", "#+++#.#+++#", ".####o####.",
		"#+++#.#+++#", "#++#...#++#", "#+#.....#+#", "##.......##", "#.........#"}},
	{"Bukağı", "unity", "unity; a family never parted", []string{
		".###...###.", "#...#.#...#", "#.#.###.#.#", "#.#..#..#.#", ".#..#+#..#.", "...#+o+#...",
		".#..#+#..#.", "#.#..#..#.#", "#.#.###.#.#", "#...#.#...#", ".###...###."}},
	{"Muska", "talisman", "an amulet for luck and safety", []string{
		".....#.....", "....#+#....", "...#+o+#...", "..#+++++#..", ".#+o+o+o+#.", "###########",
		"....#.#....", "....#.#....", "...#...#..."}},
	{"Turna", "longing", "love, longing and news from afar", []string{
		".....#.....", "....###....", "#....#....#", "##..###..##", ".##.###.##.", "..#######..",
		"...#####...", "....###....", "...#.#.#...", "..#..#..#.."}},
	{"Sandık", "hope", "the dowry chest: hope and a new home", []string{
		"###########", "#+++++++++#", "#+#######+#", "#+#ooooo#+#", "#+#######+#", "#+++++++++#",
		"###########", ".#.......#."}},
}

const (
	mElibelinde = iota
	mKocboynuzu
	mBereket
	mNazarlik
	mYildiz
	mHayat
	mPitrak
	mAkrep
	mKurtizi
	mSacbagi
	mBukagi
	mMuska
	mTurna
	mSandik
)

var (
	tohum   = []string{".#.", "#o#", ".#."}
	kgoz    = []string{"..#..", ".#o#.", "#ooo#", ".#o#.", "..#.."}
	kyildiz = []string{"#...#", ".#.#.", "..o..", ".#.#.", "#...#"}
)

// MotifMeaning returns the name, one-word gloss and meaning of motif i
// (0..13), the dictionary collectors see in the traits.
func MotifMeaning(i int) (name, gloss, meaning string) {
	m := motifs[i]
	return m.name, m.gloss, m.meaning
}

// MotifCount is the number of motif families.
func MotifCount() int { return len(motifs) }

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

var intentOpts = []option{{"Protection", 30, 0}, {"Abundance", 28, 0}, {"Wish", 26, 0}, {"Strength", 16, 0}}

// families: the motif family of each intent.
var families = [][]int{
	{mNazarlik, mPitrak, mAkrep, mMuska, mKurtizi},
	{mElibelinde, mBereket, mHayat, mKocboynuzu},
	{mSacbagi, mBukagi, mSandik, mTurna, mYildiz},
	{mKocboynuzu, mKurtizi, mAkrep, mYildiz},
}

const (
	layThree = iota
	layGreat
	layLattice
	layBands
	layMihrab
)

var layoutOpts = []option{{"Three Göls", 30, 0}, {"Great Göl", 22, 1}, {"Lattice", 18, 0}, {"Bands", 18, 0}, {"Mihrab", 12, 2}}

const (
	bWolf = iota
	bWater
	bEyes
	bAmulets
	bStars
)

var borderOpts = []option{
	{"Kurt Ağzı", 26, 0}, {"Su Yolu", 22, 0}, {"Göz Dizisi", 20, 0}, {"Muska Dizisi", 18, 0}, {"Yıldız Dizisi", 14, 0},
}

var borderMeanings = []string{
	"teeth that guard the flock and the home",
	"the flow of life, never broken",
	"a row of eyes that seals the edge from harm",
	"a belt of triangle amulets",
	"guiding stars all around",
}

var dyeOpts = []option{
	{"Madder & Indigo", 22, 0}, {"Buckthorn Gold", 14, 0}, {"Walnut & Fleece", 12, 0}, {"Pomegranate", 14, 0},
	{"Night Indigo", 12, 0}, {"Highland Green", 10, 2}, {"Sinopia Earth", 8, 2}, {"Saffron & Plum", 8, 2},
}

// palettes: ground, dark, madder (m), saffron (s), light, accent, abrash ground.
var palettes = [][]string{
	{"#a6342b", "#1e2542", "#2e5578", "#d8a23b", "#ecdfc4", "#4b6e44", "#8f2c26"},
	{"#d4a03c", "#3a2418", "#a33a28", "#2f4f6e", "#f1e4c6", "#6b7a3a", "#c2903a"},
	{"#e6d9bf", "#3b2b20", "#7a5236", "#a8865c", "#f8f1e2", "#5a4433", "#d8caae"},
	{"#6e1f28", "#1a1320", "#c0502e", "#e2b257", "#efe0c8", "#2f6a6a", "#5f1b24"},
	{"#1f2b4a", "#0e1322", "#a9362d", "#d9b46a", "#e7dcc6", "#5b8a8c", "#28365a"},
	{"#4e6a3f", "#22281c", "#b03a2c", "#e0b04a", "#eee2c8", "#2e4f74", "#435c36"},
	{"#b4583c", "#2a1a14", "#e9d8ba", "#6d2a1e", "#f3e7d0", "#c9963c", "#a24e35"},
	{"#5a2e55", "#1c1020", "#e0a630", "#c24a3a", "#f1e3c4", "#3f7a6a", "#4c2648"},
}

// darkGround: motifs on bare ground get a light outline on these dyes.
var darkGround = []bool{false, false, false, true, true, false, false, true}

const (
	abrashNone = iota
	abrashFaint
	abrashStrong
)

var abrashOpts = []option{{"None", 30, 0}, {"Faint", 50, 0}, {"Strong", 20, 0}}

const (
	fringeLoose = iota
	fringeKnotted
	fringeBraided
)

var fringeOpts = []option{{"Loose", 50, 0}, {"Knotted", 35, 0}, {"Braided", 15, 0}}

var marks = []string{"None", "Nazar Bead", "On the Loom", "Nazar Bead + On the Loom"}

// Rarity: sum of the drawn traits' scores (a trait pinned by params scores
// 0). Over 10,000 sample seeds with default params: Common 37.4% /
// Uncommon 39.1% / Rare 17.0% / Legendary 5.2% / Mythic 1.3%.
const (
	scoreNazar     = 3
	scoreLoom      = 4
	scoreMainRare  = 1 // Hayat Ağacı or Sandık as the main motif
	scoreMythic    = 7
	scoreLegendary = 5
	scoreRare      = 3
	scoreUncommon  = 1
)

type draw struct {
	intent               int
	main, second, third  int
	layout, border, dyes int
	abrash, fringe       int
	nazar, loom          bool
	score                int
	rarity               string
}

func derive(seed string, cfg Config) draw {
	r := newRNG(seed + "|traits")
	// Draw order is part of the contract: changing it changes every token.
	var d draw
	d.intent = pick(r, intentOpts)
	r0, r1, r2, r3 := r.intn(60), r.intn(60), r.intn(100), r.intn(60)
	d.layout = pick(r, layoutOpts)
	d.border = pick(r, borderOpts)
	d.dyes = pick(r, dyeOpts)
	d.abrash = pick(r, abrashOpts)
	d.fringe = pick(r, fringeOpts)
	d.nazar = r.intn(100) < 9
	d.loom = r.intn(100) < 5
	// Params override after the draws, so the stream never shifts.
	score := 0
	if cfg.Intent >= 0 {
		d.intent = cfg.Intent
	} else {
		score += intentOpts[d.intent].score
	}
	if cfg.Layout >= 0 {
		d.layout = cfg.Layout
	} else {
		score += layoutOpts[d.layout].score
	}
	if cfg.Dyes >= 0 {
		d.dyes = cfg.Dyes
	} else {
		score += dyeOpts[d.dyes].score
	}
	// the motif sentence: main and second from the intent's family, the
	// third from anywhere (55%) or from the family
	fam := families[d.intent]
	n := len(fam)
	d.main = fam[r0%n]
	var rest []int
	for _, k := range fam {
		if k != d.main {
			rest = append(rest, k)
		}
	}
	d.second = rest[r1%(n-1)]
	var pool []int
	if r2 < 55 {
		for k := 0; k < len(motifs); k++ {
			if k != d.main && k != d.second {
				pool = append(pool, k)
			}
		}
	} else {
		for _, k := range rest {
			if k != d.second {
				pool = append(pool, k)
			}
		}
	}
	d.third = pool[r3%len(pool)]
	if d.main == mHayat || d.main == mSandik {
		score += scoreMainRare
	}
	if d.nazar {
		score += scoreNazar
	}
	if d.loom {
		score += scoreLoom
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

// TraitSet is the decoded properties of a seed under a config.
type TraitSet struct {
	Intent, MainMotif, Companions, Layout, Border, Dyes, Mark string
	Score                                                     int
	Rarity                                                    string
}

// TraitsOf returns the decoded traits for a seed.
func TraitsOf(seed string, cfg Config) TraitSet {
	d := derive(seed, cfg)
	m0, m1, m2 := motifs[d.main], motifs[d.second], motifs[d.third]
	mark := 0
	if d.nazar {
		mark++
	}
	if d.loom {
		mark += 2
	}
	return TraitSet{
		Intent:     intentOpts[d.intent].name,
		MainMotif:  m0.name + ": " + m0.meaning,
		Companions: m1.name + " (" + m1.gloss + ") + " + m2.name + " (" + m2.gloss + ")",
		Layout:     layoutOpts[d.layout].name,
		Border:     borderOpts[d.border].name + ": " + borderMeanings[d.border],
		Dyes:       dyeOpts[d.dyes].name,
		Mark:       marks[mark],
		Score:      d.score,
		Rarity:     d.rarity,
	}
}

// KunyeNumber is Input.TokenID read as a decimal, modulo 2^14 (the band has
// 14 bits; core's supply cap is 10,000). Anything but ASCII digits is 0.
func KunyeNumber(tokenID string) int {
	v := 0
	for i := 0; i < len(tokenID); i++ {
		c := tokenID[i]
		if c < '0' || c > '9' {
			return 0
		}
		v = (v*10 + int(c-'0')) % 16384
	}
	return v
}

// ---------------------------------------------------------------------------
// The loom
// ---------------------------------------------------------------------------

const (
	gw, gh   = 49, 75 // cells
	fx0, fy0 = 8, 8
	fx1, fy1 = gw - 9, gh - 9
	cx, cy   = 24, 37
	ncol     = 9
	cell     = 11
	ox, oy   = 24, 36
	pw, ph   = gw*cell + 2*ox, gh*cell + 2*oy
)

// colour indices
const (
	cG  = iota // ground
	cD         // dark outline
	cM         // madder
	cS         // saffron
	cL         // light
	cA         // accent
	cAB        // abrash ground
	cNZ        // nazar blue
	cNW        // nazar white
)

func abs(a int) int {
	if a < 0 {
		return -a
	}
	return a
}

// floorMod is Python's % (b > 0); only the lattice has negative operands.
func floorMod(a, b int) int {
	m := a % b
	if m < 0 {
		m += b
	}
	return m
}

type loom struct{ g []int }

// stamp paints a bitmap centred on (mx, my), clipped to the field.
// cmap: colours of '#', '+', 'o'.
func (lm *loom) stamp(bm []string, mx, my, sc int, cmap []int, mirror bool) {
	h, w := len(bm), len(bm[0])
	x0, y0 := mx-w*sc/2, my-h*sc/2
	g := lm.g
	for j := 0; j < h; j++ {
		row := bm[j]
		for i := 0; i < w; i++ {
			ch := row[i]
			if mirror {
				ch = row[w-1-i]
			}
			if ch == '.' {
				continue
			}
			c := cmap[2]
			if ch == '#' {
				c = cmap[0]
			} else if ch == '+' {
				c = cmap[1]
			}
			for a := 0; a < sc; a++ {
				X := x0 + i*sc + a
				if X < fx0 || X > fx1 {
					continue
				}
				for b := 0; b < sc; b++ {
					Y := y0 + j*sc + b
					if Y >= fy0 && Y <= fy1 {
						g[Y*gw+X] = c
					}
				}
			}
		}
	}
}

// free: the box around a w x h motif plus one cell is inside the field and
// all ground.
func (lm *loom) free(mx, my, w, h int) bool {
	y0, y1, x0, x1 := my-h/2-1, my+h/2+1, mx-w/2-1, mx+w/2+1
	if x0 < fx0 || x1 > fx1 || y0 < fy0 || y1 > fy1 {
		return false
	}
	for y := y0; y <= y1; y++ {
		for x := x0; x <= x1; x++ {
			if lm.g[y*gw+x] != cG {
				return false
			}
		}
	}
	return true
}

// hexgol draws a stepped hexagonal göl: outline, a ring, the fill, and hooks
// on its slopes.
func (lm *loom) hexgol(gx, gy, a, b, c, fill, ring int) {
	g := lm.g
	for y := gy - b - 2; y <= gy+b+2; y++ {
		if y < fy0 || y > fy1 {
			continue
		}
		for x := gx - a - 2; x <= gx+a+2; x++ {
			if x < fx0 || x > fx1 {
				continue
			}
			dx, dy := x-gx, y-gy
			ax, ay := abs(dx), abs(dy)
			if ax <= a && ay <= b && ax+ay <= c {
				col := fill
				if ax+1 > a || ay+1 > b || ax+ay+1 > c {
					col = cD
				} else if ax+2 > a || ay+2 > b || ax+ay+2 > c {
					col = ring
				}
				g[y*gw+x] = col
			} else {
				s := ax + ay
				if s == c+1 && ay < b && ax < a && (dx+dy)&3 == 0 {
					g[y*gw+x] = cD
				}
				if s == c+2 && ay < b-1 && ax < a-1 && (dx+dy)&3 == 1 {
					g[y*gw+x] = cD
				}
			}
		}
	}
}

var (
	onGround     = []int{cD, cL, cS}
	onDarkGround = []int{cL, cS, cM}
	wolfUp       = []int{0, 1, 2, 3, 2, 1}
	wolfDown     = []int{3, 2, 1, 0, 1, 2}
	waterZ       = []int{1, 2, 3, 4, 4, 3, 2, 1}
	waterZP      = []int{1, 1, 2, 3, 4, 4, 3, 2}
)

func onFill(f int) []int {
	p, o := cL, cS
	if f == cL {
		p = cS
	}
	if f == cS {
		o = cM
	}
	return []int{cD, p, o}
}

func (lm *loom) border(kind, bBg int) {
	g := lm.g
	for y := 0; y < gh; y++ {
		for x := 0; x < gw; x++ {
			if x >= fx0 && x <= fx1 && y >= fy0 && y <= fy1 {
				continue
			}
			e := x
			if y < e {
				e = y
			}
			if gw-1-x < e {
				e = gw - 1 - x
			}
			if gh-1-y < e {
				e = gh - 1 - y
			}
			if e == 0 || e == 7 {
				g[y*gw+x] = cD
				continue
			}
			c := bBg
			if (x < 7 || x > gw-8) && (y < 7 || y > gh-8) {
				// corner rosette (centre 3.5 cells from the edges: doubled coordinates)
				vx, vy := abs(2*x-7), abs(2*y-7)
				if x >= 7 {
					vx = abs(2*x - (2*gw - 9))
				}
				if y >= 7 {
					vy = abs(2*y - (2*gh - 9))
				}
				v := vx + vy
				switch {
				case v <= 2:
					c = cS
				case v <= 4:
					c = cD
				case v <= 6:
					c = cA
				}
			} else {
				var t, dd int
				switch {
				case e == y:
					t, dd = x, y-1
				case e == gh-1-y:
					t, dd = x, gh-2-y
				case e == x:
					t, dd = y, x-1
				default:
					t, dd = y, gw-2-x
				}
				switch kind {
				case bWolf:
					k := (t - 1) % 6
					if dd < wolfUp[k] {
						c = cD
					} else if 5-dd < wolfDown[k] {
						c = cS
					}
				case bWater:
					k := t % 8
					if dd == waterZ[k] || dd == waterZP[k] {
						c = cD
					} else if (k == 0 || k == 1) && dd == 4 {
						c = cA
					} else if (k == 4 || k == 5) && dd == 1 {
						c = cS
					}
				case bEyes:
					k := (t - 1) % 7
					v := abs(2*k-6) + abs(2*dd-5)
					if v <= 1 {
						c = cL
					} else if v <= 3 {
						c = cA
					} else if v <= 5 {
						c = cD
					}
				case bAmulets:
					k := (t - 1) % 12
					lim := 2*dd - 4
					if k < 6 {
						lim = 2*(5-dd) - 4
					}
					if abs(2*(k%6)-5) <= lim {
						c = cS
						if k < 6 {
							c = cD
						}
					}
				default:
					sx := (t-1)%7 - 1
					if sx >= 0 && sx < 5 && dd < 5 {
						ch := kyildiz[dd][sx]
						if ch == 'o' {
							c = cS
						} else if ch != '.' {
							c = cD
						}
					}
				}
			}
			g[y*gw+x] = c
		}
	}
}

func (lm *loom) field(layout, main, second, third int, og []int) {
	g := lm.g
	switch layout {
	case layThree:
		// top to bottom the göls read as a sentence: second, main, third
		fills := []int{cM, cA, cM}
		ks := []int{second, main, third}
		ys := []int{cy - 19, cy, cy + 19}
		for i := 0; i < 3; i++ {
			lm.hexgol(cx, ys[i], 13, 8, 17, fills[i], cL)
			f := onFill(fills[i])
			lm.stamp(motifs[ks[i]].bm, cx, ys[i], 1, f, false)
			lm.stamp(tohum, cx-9, ys[i], 1, f, false)
			lm.stamp(tohum, cx+9, ys[i], 1, f, false)
		}
		for _, yy := range []int{cy - 28, cy - 10, cy + 10, cy + 28} {
			for _, xx := range []int{fx0 + 3, fx1 - 3} {
				if lm.free(xx, yy, 3, 3) {
					lm.stamp(tohum, xx, yy, 1, og, false)
				}
			}
		}
		for _, yy := range []int{cy - 9, cy + 9} {
			for _, xx := range []int{fx0 + 5, fx1 - 5} {
				if lm.free(xx, yy, 5, 5) {
					lm.stamp(kgoz, xx, yy, 1, og, false)
				}
			}
		}
	case layGreat:
		// end panels [second, third, second] around one great göl with the
		// main motif twice its size
		fa := onFill(cA)
		for p := 0; p < 2; p++ {
			y0, y1, sep := fy0, fy0+11, fy0+12
			if p == 1 {
				y0, y1, sep = fy1-11, fy1, fy1-12
			}
			for y := y0; y <= y1; y++ {
				for x := fx0; x <= fx1; x++ {
					g[y*gw+x] = cA
				}
			}
			for x := fx0; x <= fx1; x++ {
				g[sep*gw+x] = cD
			}
			my := y0 + 6
			lm.stamp(motifs[second].bm, cx-11, my, 1, fa, false)
			lm.stamp(motifs[third].bm, cx, my, 1, fa, false)
			lm.stamp(motifs[second].bm, cx+11, my, 1, fa, true)
		}
		lm.hexgol(cx, cy, 14, 16, 26, cM, cL)
		lm.hexgol(cx, cy, 10, 12, 18, cA, cL)
		lm.stamp(motifs[main].bm, cx, cy, 2, fa, false)
		for _, yy := range []int{cy - 13, cy + 13} {
			for _, xx := range []int{fx0 + 2, fx1 - 2} {
				if lm.free(xx, yy, 3, 3) {
					lm.stamp(tohum, xx, yy, 1, og, false)
				}
			}
		}
	case layLattice:
		for y := fy0; y <= fy1; y++ {
			for x := fx0; x <= fx1; x++ {
				u := floorMod(x-cx+(y-cy)+11, 22)
				v := floorMod(x-cx-(y-cy)+11, 22)
				if u == 0 || v == 0 {
					g[y*gw+x] = cD
				} else if u == 1 || v == 1 || u == 21 || v == 21 {
					g[y*gw+x] = cS
				}
			}
		}
		// centre column: the main motif with the third above and below; the
		// sides carry the second
		centre := []int{cD, cL, cA}
		if og[0] != cD {
			centre = []int{cL, cS, cA}
		}
		for j := -3; j <= 3; j++ {
			for i := -1; i <= 1; i++ {
				if floorMod(i+j, 2) != 0 {
					continue
				}
				if i == 0 {
					k := third
					if j == 0 {
						k = main
					}
					lm.stamp(motifs[k].bm, cx, cy+11*j, 1, centre, false)
				} else {
					lm.stamp(motifs[second].bm, cx+11*i, cy+11*j, 1, og, i > 0)
				}
			}
		}
	case layBands:
		ks := []int{main, second, third, main}
		bgs := []int{cG, cM, cA, cG}
		y := fy0 + 1
		for bi := 0; bi < 4; bi++ {
			bg := bgs[bi]
			for yy := y; yy < y+13; yy++ {
				for x := fx0; x <= fx1; x++ {
					g[yy*gw+x] = bg
				}
			}
			cm := og
			if bg != cG {
				cm = onFill(bg)
			}
			bm := motifs[ks[bi]].bm
			lm.stamp(bm, cx-11, y+6, 1, cm, false)
			lm.stamp(bm, cx, y+6, 1, cm, false)
			lm.stamp(bm, cx+11, y+6, 1, cm, true)
			y += 13
			if bi < 3 {
				for x := fx0; x <= fx1; x++ {
					z := 0
					if x&3 == 1 || x&3 == 2 {
						z = 1
					}
					g[(y+z)*gw+x] = cD
					g[(y+1-z)*gw+x] = cL
				}
				y += 2
			}
		}
	default:
		// mihrab: a stepped prayer niche over a base panel
		top, base := fy0+1, fy1-14
		inN := func(x, y int) bool {
			ax := abs(x - cx)
			return ax <= 13 && y >= top+ax && y <= base
		}
		for y := fy0; y <= fy1; y++ {
			for x := fx0; x <= fx1; x++ {
				c := cM
				if y > base {
					if y == base+1 {
						c = cD
					}
				} else if inN(x, y) {
					c = cG
					if !inN(x+1, y) || !inN(x-1, y) || !inN(x, y-1) || !inN(x, y+1) {
						c = cD
					}
				} else if inN(x+1, y) || inN(x-1, y) || inN(x, y+1) {
					c = cL
				}
				g[y*gw+x] = c
			}
		}
		fm := onFill(cM)
		lm.stamp(motifs[second].bm, cx, top+12, 1, og, false)
		lm.stamp(motifs[main].bm, cx, base-12, 2, og, false)
		lm.stamp(motifs[third].bm, cx-9, base+7, 1, fm, false)
		lm.stamp(motifs[third].bm, cx+9, base+7, 1, fm, true)
		lm.stamp(kyildiz, fx0+3, fy0+4, 1, fm, false)
		lm.stamp(kyildiz, fx1-3, fy0+4, 1, fm, false)
	}
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

const (
	fringeShade = "#b3a27f"
	fringeLight = "#e2d6bb"
	fringeKnot  = "#a8977a"
	fringeBraid = "#8f7f63"
)

func fringeGroup(b *strings.Builder, y int, flip bool, knots string, braided bool) {
	b.WriteString(`<g transform="translate(0 ` + strconv.Itoa(y) + ")")
	if flip {
		b.WriteString(` scale(1 -1)`)
	}
	b.WriteString(`"><use href="#f" stroke="` + fringeShade + `" stroke-width="3.2"/><use href="#f" stroke="` +
		fringeLight + `" stroke-width="1.8"/>`)
	if knots != "" {
		b.WriteString(`<path d="` + knots + `" stroke="` + fringeKnot + `" stroke-width="5"/>`)
	}
	if braided {
		b.WriteString(`<use href="#f" stroke="` + fringeBraid + `" stroke-width="1" stroke-dasharray="2 3"/>`)
	}
	b.WriteString(`</g>`)
}

// SVG renders the artwork for a seed under cfg, with the token number
// tokenID woven into the künye band.
func SVG(seed string, cfg Config, tokenID string) string {
	d := derive(seed, cfg)
	pal := palettes[d.dyes]
	r := newRNG(seed + "|art") // separate stream: trait draws never shift the art
	lm := &loom{g: make([]int, gw*gh)}
	g := lm.g
	bBg := cL
	if r.intn(2) == 0 {
		bBg = cM
	}
	lm.border(d.border, bBg)
	og := onGround
	if darkGround[d.dyes] {
		og = onDarkGround
	}
	lm.field(d.layout, d.main, d.second, d.third, og)

	// abrash: a new dye lot recolours the ground in a few weft bands
	if d.abrash != abrashNone {
		nb, hmax := 4, 7
		if d.abrash == abrashFaint {
			nb, hmax = 2, 4
		}
		for k := 0; k < nb; k++ {
			y0 := r.between(fy0, fy1-4)
			hh := r.between(2, hmax)
			for y := y0; y < y0+hh && y <= fy1; y++ {
				for x := fx0; x <= fx1; x++ {
					if g[y*gw+x] == cG {
						g[y*gw+x] = cAB
					}
				}
			}
		}
	}
	// nazar bead: one blue eye that breaks the symmetry on purpose (on bare
	// ground when one of 40 tries finds room, else over the last spot tried)
	if d.nazar {
		x, y := 0, 0
		for tries := 0; tries < 40; tries++ {
			x = r.between(fx0+3, fx1-3)
			y = r.between(fy0+3, fy1-3)
			if abs(x-cx) >= 4 && lm.free(x, y, 5, 5) {
				break
			}
		}
		for j := -2; j <= 2; j++ {
			for i := -2; i <= 2; i++ {
				v := abs(i) + abs(j)
				if v <= 2 {
					c := cD
					if v == 2 {
						c = cNZ
					} else if v == 1 {
						c = cNW
					}
					g[(y+j)*gw+x+i] = c
				}
			}
		}
	}
	// künye: the token number in 14 bits on the bottom frame line
	tokenNo := KunyeNumber(tokenID)
	ky := (gh - 8) * gw
	g[ky+cx-15] = cL
	g[ky+cx+15] = cL
	for i := 0; i < 14; i++ {
		c := cA
		if (tokenNo>>uint(13-i))&1 != 0 {
			c = cS
		}
		g[ky+cx-13+2*i] = c
	}
	// on the loom: the top rows are not woven yet
	cut := 0
	if d.loom {
		cut = r.between(10, 24)
	}
	noise := r.between(1, 999)

	// run-length rows; the most frequent colour is the background rect
	var cnt [ncol]int
	for i := cut * gw; i < gw*gh; i++ {
		cnt[g[i]]++
	}
	bg := 0
	for i := 1; i < ncol; i++ {
		if cnt[i] > cnt[bg] {
			bg = i
		}
	}
	cols := []string{pal[0], pal[1], pal[2], pal[3], pal[4], pal[5], pal[6], "#2d6db5", "#f4f1ea"}
	paths := make([]strings.Builder, ncol)
	var last [ncol]int
	for y := cut; y < gh; y++ {
		for k := 0; k < ncol; k++ {
			last[k] = -1
		}
		row := y * gw
		sy := strconv.Itoa(y)
		x := 0
		for x < gw {
			c := g[row+x]
			e := x
			for e+1 < gw && g[row+e+1] == c {
				e++
			}
			if c != bg {
				p := &paths[c]
				if last[c] >= 0 {
					p.WriteString("m" + strconv.Itoa(x-last[c]) + " 0h" + strconv.Itoa(e-x+1))
				} else {
					p.WriteString("M" + strconv.Itoa(x) + " " + sy + "h" + strconv.Itoa(e-x+1))
				}
				last[c] = e + 1
			}
			x = e + 1
		}
	}

	var b strings.Builder
	sPW, sPH := strconv.Itoa(pw), strconv.Itoa(ph)
	b.WriteString(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ` + sPW + " " + sPH + `" width="` + sPW +
		`" height="` + sPH + `">`)
	b.WriteString(`<title>Kilim, Niyet: ` + intentOpts[d.intent].name + `</title><desc>`)
	for _, k := range []int{d.main, d.second, d.third} {
		b.WriteString(motifs[k].name + ": " + motifs[k].meaning + ". ")
	}
	b.WriteString(borderOpts[d.border].name + ": " + borderMeanings[d.border] + ". Künye " + strconv.Itoa(tokenNo) + ".</desc>")
	b.WriteString(`<defs><pattern id="w" width="11" height="11" patternUnits="userSpaceOnUse">` +
		`<path d="M0 1h11M0 6h11" stroke="#fff" stroke-opacity=".08"/><path d="M0 3.5h11M0 9h11" stroke="#000" stroke-opacity=".09"/>` +
		`<path d="M3 0v11M8 0v11" stroke="#000" stroke-opacity=".035"/></pattern>` +
		`<filter id="n" x="0" y="0" width="1" height="1"><feTurbulence type="fractalNoise" baseFrequency=".01 .5" numOctaves="2" seed="` +
		strconv.Itoa(noise) + `"/>` +
		`<feColorMatrix values="0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 -2 1.1"/></filter>` +
		`<filter id="s" x="-.1" y="-.1" width="1.2" height="1.2"><feGaussianBlur stdDeviation="6"/></filter><path id="f" d="`)
	// fringe: warp ends in pairs, cut to uneven lengths
	for i := 0; i < 2*gw; i++ {
		b.WriteString("M" + strconv.Itoa(ox+3+(11*i+1)/2) + " 0v" + strconv.Itoa(16+r.intn(9)))
	}
	b.WriteString(`"/></defs><rect width="` + sPW + `" height="` + sPH + `" fill="#ece5d6"/>`)
	top := oy + cut*cell
	sTop, sRW, sRH := strconv.Itoa(top), strconv.Itoa(gw*cell), strconv.Itoa((gh-cut)*cell)
	b.WriteString(`<rect x="` + strconv.Itoa(ox+3) + `" y="` + strconv.Itoa(top+6) + `" width="` + sRW + `" height="` + sRH +
		`" fill="#000" opacity=".22" filter="url(#s)"/>`)
	knots := ""
	if d.fringe == fringeKnotted {
		for i := 0; i < 25; i++ {
			knots += "M" + strconv.Itoa(ox+6+22*i) + " 6h8"
		}
	}
	braided := d.fringe == fringeBraided
	if !d.loom {
		fringeGroup(&b, oy, true, knots, braided)
	}
	fringeGroup(&b, oy+gh*cell, false, knots, braided)
	b.WriteString(`<g transform="translate(` + strconv.Itoa(ox) + " " + strconv.Itoa(oy) + `) scale(11)" shape-rendering="crispEdges">`)
	sCut := strconv.Itoa(cut)
	if d.loom {
		b.WriteString(`<rect y="-4" width="49" height="` + strconv.Itoa(cut+4) + `" fill="#3b2f25"/><path d="`)
		sWarp := strconv.Itoa(cut + 4)
		for x := 0; x < gw; x++ {
			b.WriteString("M" + strconv.Itoa(x) + ".5 -4v" + sWarp)
		}
		b.WriteString(`" stroke="` + pal[4] + `" stroke-width=".22"/>`)
	}
	b.WriteString(`<rect y="` + sCut + `" width="49" height="` + strconv.Itoa(gh-cut) + `" fill="` + cols[bg] +
		`"/><g transform="translate(0 .5)" stroke-width="1.02">`)
	for c := 0; c < ncol; c++ {
		if paths[c].Len() > 0 {
			b.WriteString(`<path stroke="` + cols[c] + `" d="` + paths[c].String() + `"/>`)
		}
	}
	b.WriteString(`</g>`)
	if d.loom {
		b.WriteString(`<rect x="-1" y="` + strconv.Itoa(cut-1) + `" width="51" height="1" fill="#7a5a3a"/>`)
		b.WriteString(`<path d="M` + strconv.Itoa(r.between(5, 20)) + " " + sCut + `q4 3 9 1t8 4" stroke="` + pal[2] +
			`" stroke-width=".35" fill="none"/>`)
	}
	b.WriteString(`</g><rect x="` + strconv.Itoa(ox) + `" y="` + sTop + `" width="` + sRW + `" height="` + sRH + `" fill="url(#w)"/>`)
	b.WriteString(`<rect x="` + strconv.Itoa(ox) + `" y="` + sTop + `" width="` + sRW + `" height="` + sRH +
		`" filter="url(#n)" opacity=".3"/></svg>`)
	return b.String()
}
