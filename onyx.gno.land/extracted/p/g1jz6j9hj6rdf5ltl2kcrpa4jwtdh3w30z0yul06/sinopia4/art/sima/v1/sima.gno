// Package sima is a Sinopia engine: an on-chain PFP in the language of a
// risograph print. Every token is a bust printed in three drum inks (two
// colours and a skin ink) plus a key ink for the line work; each plate is
// slightly misregistered, shadows are halftone dots and the signature mark is
// a nose drawn as one broken line. Rare tokens are print accidents.
//
// Overprint is emulated with explicit colour layers: every overlap of two or
// three plates is drawn again, clipped to the overlap, in the product of the
// inks (what multiply blending would show). The output never uses
// mix-blend-mode, so wallets that ignore blending still show the right
// colours.
//
// It is a port of the Sima prototype in the engine gallery (JavaScript) with
// curated ink sets, named expressions, one accessory slot, emulated overprint
// and integer maths. frontend/src/engines/sima.ts is a byte-identical
// TypeScript twin; sima_test.gno and sima.test.ts pin the same golden vectors.
//
// Pure integer maths: no floats, no time, no block data.
package sima

import (
	"errors"
	"strconv"
	"strings"

	"gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia4/engine/v2"
)

// TraitTypes in the order Traits returns them.
var traitTypes = []string{"Inks", "Backdrop", "Head", "Hair", "Expression", "Outfit", "Accessory", "Print"}

// MaxSVGBytes: the largest output over 10,000 seeds is 5,243 B; more
// than 2x margin.
const MaxSVGBytes = 12288

// ParamsSchema is the Studio form. Studio sends JSON.stringify of the values
// in this property order; ValidateParams accepts exactly that or "".
const ParamsSchema = `{"type":"object","properties":{` +
	`"inks":{"type":"string","title":"Ink set","enum":["Seeded","Pink & Blue","Tangerine & Teal",` +
	`"Red & Federal Blue","Green & Violet","Sunflower & Blue","Aqua & Burgundy","Pink & Green","Orange & Violet",` +
	`"Kraft Press","Blue on Blush","Blueprint","Sinopia Earth"],"default":"Seeded"}}}`

// DefaultParams is the canonical form of the defaults; it renders exactly
// like "".
const DefaultParams = `{"inks":"Seeded"}`

// Manifest describes the engine. Author and FeeBps are set by the adapter.
func Manifest() engine.Manifest {
	return engine.Manifest{
		Name:    "Sima",
		Version: "1.0.0",
		Description: "On-chain portraits printed like a risograph: three misregistered drum inks that overprint, " +
			"halftone shadows and a one-line nose. Layered traits; the rare ones are print accidents.",
		License:      "CC-BY-NC-4.0",
		ParamsSchema: ParamsSchema,
		TraitTypes:   append([]string{}, traitTypes...),
		Living:       false,
		MaxSVGBytes:  MaxSVGBytes,
		Kind:         engine.KindSVG,
	}
}

// Config is a parsed params string.
type Config struct {
	Inks int // -1: drawn from the seed, else an index into the ink sets
}

// Defaults is the showcase look (params "").
func Defaults() Config { return Config{Inks: -1} }

var errParams = errors.New(`sima: params must be "" or {"inks":<enum>} without spaces`)

// ParseParams accepts "" or the canonical JSON Studio produces, nothing else.
func ParseParams(params string) (Config, error) {
	cfg := Defaults()
	if params == "" {
		return cfg, nil
	}
	const pre, post = `{"inks":"`, `"}`
	if !strings.HasPrefix(params, pre) || !strings.HasSuffix(params, post) || len(params) < len(pre)+len(post) {
		return cfg, errParams
	}
	v := params[len(pre) : len(params)-len(post)]
	if strings.IndexByte(v, '"') >= 0 {
		return cfg, errParams
	}
	if v == "Seeded" {
		return cfg, nil
	}
	for i, s := range inkSets {
		if s.name == v {
			cfg.Inks = i
			return cfg, nil
		}
	}
	return cfg, errParams
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
// renders: eight table draws.
func Traits(in engine.Input) []engine.Trait {
	t := TraitsOf(in.Seed, mustConfig(in.Params))
	return []engine.Trait{
		{Type: "Inks", Value: t.Inks},
		{Type: "Backdrop", Value: t.Backdrop},
		{Type: "Head", Value: t.Head},
		{Type: "Hair", Value: t.Hair},
		{Type: "Expression", Value: t.Expression},
		{Type: "Outfit", Value: t.Outfit},
		{Type: "Accessory", Value: t.Accessory},
		{Type: "Print", Value: t.Print},
	}
}

// Render returns the raw SVG for in.Seed and in.Params.
func Render(in engine.Input) string { return SVG(in.Seed, mustConfig(in.Params)) }

// ---------------------------------------------------------------------------
// Deterministic randomness: FNV-1a over the seed, then splitmix64 (the stream
// of every Sinopia engine). Traits use seed+"|traits", the art seed+"|art".
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

func (r *rng) between(a, b int) int { return a + r.intn(b-a+1) }

// ---------------------------------------------------------------------------
// Trait tables (weights out of the table total).
// ---------------------------------------------------------------------------

type option struct {
	name   string
	weight int
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

// inkSet: A (accent drum), B (second drum), C (skin drum), K (key), P (paper).
type inkSet struct {
	name          string
	weight        int
	a, b, c, k, p string
}

var inkSets = []inkSet{
	{"Pink & Blue", 14, "#ff48b0", "#0078bf", "#ffe14a", "#23202e", "#f4ede0"},
	{"Tangerine & Teal", 12, "#ff6c2f", "#00838a", "#ffc2dc", "#1f2433", "#f4ede0"},
	{"Red & Federal Blue", 11, "#f15060", "#3d5588", "#f2d3a8", "#23202e", "#f7f3ea"},
	{"Green & Violet", 10, "#00a95c", "#765ba7", "#ffb994", "#2b2420", "#f4ede0"},
	{"Sunflower & Blue", 10, "#ffb511", "#3255a4", "#b8e3b2", "#1f2433", "#f7f3ea"},
	{"Aqua & Burgundy", 9, "#5ec8e5", "#914e72", "#ffe14a", "#2b2420", "#f4ede0"},
	{"Pink & Green", 8, "#ff48b0", "#00a95c", "#a6d6f0", "#23202e", "#f7f3ea"},
	{"Orange & Violet", 8, "#ff6c2f", "#765ba7", "#a6d6f0", "#1f2433", "#f4ede0"},
	{"Kraft Press", 6, "#f15060", "#00838a", "#f7e3b5", "#2b2420", "#d9c09a"},
	{"Blue on Blush", 5, "#0078bf", "#765ba7", "#ffe14a", "#23202e", "#f7d6d3"},
	{"Blueprint", 4, "#5ec8e5", "#3255a4", "#d8ecf5", "#1f2433", "#f7f3ea"},
	{"Sinopia Earth", 3, "#b5432c", "#2e4a3a", "#f1d2b0", "#2a1712", "#efe4cc"},
}

var inkOpts = func() []option {
	o := make([]option, len(inkSets))
	for i, s := range inkSets {
		o[i] = option{s.name, s.weight}
	}
	return o
}()

const (
	bgSun = iota
	bgArch
	bgStripes
	bgHalftone
	bgTwin
	bgPlain
)

var backdropOpts = []option{{"Sun", 24}, {"Arch", 18}, {"Stripes", 16}, {"Halftone", 16}, {"Twin Circles", 12}, {"Plain", 14}}

const (
	headEgg = iota
	headBean
	headBlock
	headLong
	headRound
)

var headOpts = []option{{"Egg", 30}, {"Bean", 22}, {"Block", 18}, {"Long", 16}, {"Round", 14}}

const (
	hairBangs = iota
	hairBun
	hairCloud
	hairBob
	hairQuiff
	hairBraid
	hairWave
	hairBuzz
)

var hairOpts = []option{
	{"Bangs", 16}, {"Bun", 14}, {"Cloud", 13}, {"Bob", 14}, {"Quiff", 12}, {"Braid", 11}, {"Long Wave", 11}, {"Buzz", 9},
}

const (
	eyeDot = iota
	eyeAlmond
	eyeSleepy
	eyeClosed
	eyeRound
	eyeWink
)

const (
	mouthFlat = iota
	mouthSmile
	mouthO
	mouthWhistle
	mouthGrin
	mouthLips
)

// expression: eyes and mouth.
type expression struct {
	name         string
	weight       int
	eyes, mouth int
}

var expressions = []expression{
	{"Calm", 14, eyeDot, mouthFlat},
	{"Content", 12, eyeClosed, mouthSmile},
	{"Bright", 12, eyeAlmond, mouthSmile},
	{"Dreamy", 10, eyeSleepy, mouthLips},
	{"Pensive", 10, eyeAlmond, mouthFlat},
	{"Drowsy", 8, eyeSleepy, mouthO},
	{"Whistling", 8, eyeDot, mouthWhistle},
	{"Sly", 8, eyeAlmond, mouthGrin},
	{"Surprised", 7, eyeRound, mouthO},
	{"Cheeky", 6, eyeWink, mouthGrin},
	{"Serene", 5, eyeClosed, mouthLips},
}

const exprSurprised = 8

var expressionOpts = func() []option {
	o := make([]option, len(expressions))
	for i, e := range expressions {
		o[i] = option{e.name, e.weight}
	}
	return o
}()

const (
	outfitTurtle = iota
	outfitShirt
	outfitKaftan
	outfitJacket
	outfitOveralls
	outfitScarf
)

var outfitOpts = []option{
	{"Turtleneck", 20}, {"Shirt Collar", 18}, {"Kaftan", 16}, {"Jacket", 18}, {"Overalls", 14}, {"Scarf", 14},
}

const (
	accNone = iota
	accHoop
	accEarFlower
	accPencil
	accEvilEye
	accStar
	accBeret
	accCap
	accCrown
	accPhones
	accBandana
	accBird
)

var accessoryOpts = []option{
	{"None", 30}, {"Hoop Earring", 12}, {"Ear Flower", 10}, {"Pencil", 7}, {"Evil-Eye Pin", 8}, {"Star Pin", 5},
	{"Beret", 8}, {"Cap", 7}, {"Flower Crown", 5}, {"Headphones", 4}, {"Bandana", 4}, {"Shoulder Bird", 3},
}

const (
	printClean = iota
	printShifted
	printDouble
	printBlot
	printStarved
	printGhost
)

var printOpts = []option{
	{"Clean", 70}, {"Shifted Plate", 9}, {"Double Key", 9}, {"Ink Blot", 6}, {"Starved Ink", 4}, {"Ghost", 2},
}

// noseOpts are drawn from the art stream (not a trait).
var noseOpts = []option{{"Straight", 34}, {"Hooked", 26}, {"Upturned", 22}, {"Button", 18}}

type draw struct {
	inks, backdrop, head, hair, expression, outfit, accessory, print int
}

func derive(seed string, cfg Config) draw {
	r := newRNG(seed + "|traits")
	// Draw order is part of the contract: changing it changes every token.
	var d draw
	d.inks = pick(r, inkOpts)
	d.backdrop = pick(r, backdropOpts)
	d.head = pick(r, headOpts)
	d.hair = pick(r, hairOpts)
	d.expression = pick(r, expressionOpts)
	d.outfit = pick(r, outfitOpts)
	d.accessory = pick(r, accessoryOpts)
	d.print = pick(r, printOpts)
	// Params override after the draws, so the stream never shifts.
	if cfg.Inks >= 0 {
		d.inks = cfg.Inks
	}
	return d
}

// TraitSet is the decoded properties of a seed under a config.
type TraitSet struct {
	Inks, Backdrop, Head, Hair, Expression, Outfit, Accessory, Print string
}

// TraitsOf returns the decoded traits for a seed.
func TraitsOf(seed string, cfg Config) TraitSet {
	d := derive(seed, cfg)
	return TraitSet{
		Inks:       inkSets[d.inks].name,
		Backdrop:   backdropOpts[d.backdrop].name,
		Head:       headOpts[d.head].name,
		Hair:       hairOpts[d.hair].name,
		Expression: expressions[d.expression].name,
		Outfit:     outfitOpts[d.outfit].name,
		Accessory:  accessoryOpts[d.accessory].name,
		Print:      printOpts[d.print].name,
	}
}

// ---------------------------------------------------------------------------
// Integer helpers (Go's truncating / everywhere; the TS twin uses Math.trunc).
// ---------------------------------------------------------------------------

func n(v int) string { return strconv.Itoa(v) }

// pc is v*p/100 (v, p >= 0 in every call).
func pc(v, p int) int { return v * p / 100 }

// qsin is a quarter-wave sine table, Q10: sin(i*pi/128)*1024 for i = 0..64.
var qsin = []int{
	0, 25, 50, 75, 100, 125, 150, 175, 200, 224, 249, 273, 297, 321, 345, 369, 392, 415, 438, 460, 483, 505, 526, 548,
	569, 590, 610, 630, 650, 669, 688, 706, 724, 742, 759, 775, 792, 807, 822, 837, 851, 865, 878, 891, 903, 915, 926,
	936, 946, 955, 964, 972, 980, 987, 993, 999, 1004, 1009, 1013, 1016, 1019, 1021, 1023, 1024, 1024,
}

// sn is sin(a) with 256 steps per turn, Q10; a >= 0.
func sn(a int) int {
	q := a % 256
	switch {
	case q <= 64:
		return qsin[q]
	case q <= 128:
		return qsin[128-q]
	case q <= 192:
		return -qsin[q-128]
	}
	return -qsin[256-q]
}

func cs(a int) int { return sn(a + 64) }

const hexDigits = "0123456789abcdef"

func unhex(c byte) int {
	switch {
	case c >= '0' && c <= '9':
		return int(c - '0')
	case c >= 'a' && c <= 'f':
		return int(c-'a') + 10
	}
	return 0
}

// mul is the overprint of two inks: the channel-wise product, rounded.
func mul(a, b string) string {
	out := []byte{'#', 0, 0, 0, 0, 0, 0}
	for i := 1; i < 7; i += 2 {
		v := ((unhex(a[i])*16+unhex(a[i+1]))*(unhex(b[i])*16+unhex(b[i+1])) + 127) / 255
		out[i] = hexDigits[v>>4]
		out[i+1] = hexDigits[v&15]
	}
	return string(out)
}

func tr(x, y int) string { return "translate(" + n(x) + " " + n(y) + ")" }

func dotPattern(id, ink string, s int, rad string, rot int) string {
	return `<pattern id="` + id + `" width="` + n(s) + `" height="` + n(s) +
		`" patternUnits="userSpaceOnUse" patternTransform="rotate(` + n(rot) + `)">` +
		`<circle cx="` + n(s/2) + `" cy="` + n(s/2) + `" r="` + rad + `" fill="` + ink + `"/></pattern>`
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

// canvas collects the plates while the figure is built.
type canvas struct {
	defs, aEls, bEls, tex, texSkin, key, keyF string
	aIDs                                      []string
}

func (c *canvas) addA(tag, attrs string) {
	id := "a" + n(len(c.aIDs))
	c.aIDs = append(c.aIDs, id)
	c.aEls += "<" + tag + ` id="` + id + `" ` + attrs + "/>"
}

func (c *canvas) addB(tag, attrs string) { c.bEls += "<" + tag + " " + attrs + "/>" }

// eye draws one eye at (x, y), scaled s percent.
func (c *canvas) eye(x, y, s, kind int) {
	m := func(v int) int { return v * s / 100 }
	switch kind {
	case eyeDot:
		c.keyF += `<circle cx="` + n(x) + `" cy="` + n(y) + `" r="` + n(m(6)) + `"/>`
	case eyeAlmond:
		c.key += "M" + n(x-m(14)) + " " + n(y) + "q" + n(m(14)) + " " + n(-m(12)) + " " + n(m(28)) + " 0q" +
			n(-m(14)) + " " + n(m(10)) + " " + n(-m(28)) + " 0"
		c.keyF += `<circle cx="` + n(x+2) + `" cy="` + n(y-1) + `" r="` + n(m(5)) + `"/>`
	case eyeSleepy:
		c.key += "M" + n(x-m(14)) + " " + n(y-2) + "h" + n(m(28)) + "M" + n(x-m(11)) + " " + n(y+6) + "q" +
			n(m(11)) + " 6 " + n(m(22)) + " 0"
		c.keyF += `<path d="M` + n(x-m(8)) + " " + n(y-2) + "a" + n(m(8)) + " 7 0 0 0 " + n(m(16)) + ` 0z"/>`
	case eyeClosed:
		c.key += "M" + n(x-m(13)) + " " + n(y) + "q" + n(m(13)) + " " + n(m(12)) + " " + n(m(26)) + " 0M" +
			n(x-m(8)) + " " + n(y+6) + "l-4 6M" + n(x) + " " + n(y+8) + "v7M" + n(x+m(8)) + " " + n(y+6) + "l4 6"
	case eyeRound:
		c.key += "M" + n(x-m(12)) + " " + n(y) + "a" + n(m(12)) + " " + n(m(12)) + " 0 1 0 " + n(m(24)) + " 0a" +
			n(m(12)) + " " + n(m(12)) + " 0 1 0 " + n(-m(24)) + " 0"
		c.keyF += `<circle cx="` + n(x+3) + `" cy="` + n(y) + `" r="` + n(m(4)) + `"/>`
	default: // wink
		c.key += "M" + n(x-m(12)) + " " + n(y+4) + "l" + n(m(12)) + "-10l" + n(m(12)) + " 10"
	}
}

// SVG renders the artwork for a seed under cfg.
func SVG(seed string, cfg Config) string {
	t := derive(seed, cfg)
	R := newRNG(seed + "|art") // separate stream: trait draws never shift the art
	ink := inkSets[t.inks]
	A, B, C, K, P := ink.a, ink.b, ink.c, ink.k, ink.p
	AB, AC, BC := mul(A, B), mul(A, C), mul(B, C)
	ABC := mul(AB, C)
	eyes, mouth := expressions[t.expression].eyes, expressions[t.expression].mouth

	// Plate offsets (misregistration).
	oAx, oAy := R.between(-5, 5), R.between(-5, 5)
	oBx, oBy := R.between(-5, 5), R.between(-5, 5)
	oCx, oCy := R.between(-5, 5), R.between(-5, 5)
	oKx, oKy := R.between(-2, 2), R.between(-2, 2)
	if t.print == printShifted {
		oBx = R.between(12, 18)
		oBy = R.between(6, 12)
		if R.intn(2) == 1 {
			oBx = -oBx
		}
		if R.intn(2) == 1 {
			oBy = -oBy
		}
	}
	left := R.intn(2) == 1

	// Geometry (a bust in three-quarter view, facing right before mirroring).
	cx := 290 + R.between(-12, 12)
	cy := 252 + R.between(-10, 10)
	rx, ry, fwd, kap := R.between(98, 114), R.between(124, 140), R.between(18, 34), 56
	switch t.head {
	case headBean:
		fwd += 18
		rx += 6
	case headBlock:
		kap = 78
	case headLong:
		ry += 24
		rx -= 12
	case headRound:
		ry = rx + 6
	}
	sw := R.between(150, 190)
	inkSeed, paperSeed := R.between(1, 900), R.between(1, 900)

	tY, fry, chy := cy-ry, cy+pc(ry, 8), cy+ry
	k1, k2 := pc(rx, kap), pc(ry, kap)
	k3, k4, k5 := ry*kap*70/10000, rx*kap*60/10000, rx*kap*130/10000
	headD := "M" + n(cx) + " " + n(tY) + "C" + n(cx+k1) + " " + n(tY) + " " + n(cx+rx) + " " + n(fry-k2) + " " +
		n(cx+rx) + " " + n(fry) +
		"C" + n(cx+rx) + " " + n(fry+k3) + " " + n(cx+fwd+k4) + " " + n(chy) + " " + n(cx+fwd) + " " + n(chy) +
		"C" + n(cx+fwd-k5) + " " + n(chy) + " " + n(cx-rx) + " " + n(cy+k2) + " " + n(cx-rx) + " " + n(cy) +
		"C" + n(cx-rx) + " " + n(cy-k2) + " " + n(cx-k1) + " " + n(tY) + " " + n(cx) + " " + n(tY) + "z"
	neckD := "M" + n(cx-34) + " " + n(cy+pc(ry, 45)) + "L" + n(cx-40) + " 490L" + n(cx+46) + " 490L" + n(cx+38) +
		" " + n(cy+pc(ry, 55)) + "z"
	bodyD := "M" + n(cx-sw-70) + " 620C" + n(cx-sw-50) + " 520 " + n(cx-sw+10) + " 478 " + n(cx-10) + " 470" +
		"C" + n(cx+sw-10) + " 474 " + n(cx+sw+50) + " 520 " + n(cx+sw+70) + " 620z"
	earX := cx - pc(rx, 55)
	fx, ey := cx+pc(rx, 36), cy-4
	neckTop := cy + ry - 40

	c := &canvas{}

	// --- backdrop (A drum; the twin circle adds a B disc) ---
	bg := ""
	switch t.backdrop {
	case bgSun:
		dx, dy, rr := R.between(-40, 60), R.between(0, 40), R.between(170, 210)
		bg = `<circle cx="` + n(cx+dx+oAx) + `" cy="` + n(cy-dy+oAy) + `" r="` + n(rr) + `" fill="` + A + `"/>`
	case bgArch:
		bg = `<path d="M` + n(cx-200+oAx) + " 600V" + n(cy-20+oAy) + `a200 200 0 0 1 400 0V600z" fill="` + A + `"/>`
	case bgStripes:
		rot := []int{30, -30, 60}[R.intn(3)]
		c.defs += `<pattern id="sr" width="34" height="34" patternUnits="userSpaceOnUse" patternTransform="rotate(` +
			n(rot) + `)"><rect width="15" height="34" fill="` + A + `"/></pattern>`
		bg = `<rect width="600" height="600" fill="url(#sr)"/>`
	case bgHalftone:
		c.defs += dotPattern("hz", A, 14, "4.2", 30)
		bg = `<rect width="600" height="600" fill="url(#hz)"/>`
	case bgTwin:
		ax, ay, bx, by := cx-70+oAx, cy-30+oAy, cx+90+oBx, cy+10+oBy
		c.defs += `<clipPath id="ct"><circle cx="` + n(ax) + `" cy="` + n(ay) + `" r="170"/></clipPath>`
		bg = `<circle cx="` + n(ax) + `" cy="` + n(ay) + `" r="170" fill="` + A + `"/><circle cx="` + n(bx) +
			`" cy="` + n(by) + `" r="170" fill="` + B + `"/><circle cx="` + n(bx) + `" cy="` + n(by) +
			`" r="170" fill="` + AB + `" clip-path="url(#ct)"/>`
	}

	// --- outfit ---
	if t.outfit == outfitKaftan || t.outfit == outfitOveralls {
		c.aIDs = append(c.aIDs, "bd")
		c.aEls += `<path id="bd" d="` + bodyD + `"/>`
	} else {
		c.bEls += `<path id="bd" d="` + bodyD + `"/>`
	}
	switch t.outfit {
	case outfitTurtle:
		c.addB("path", `d="M`+n(cx-46)+" 492L"+n(cx-42)+" "+n(neckTop+30)+"Q"+n(cx+4)+" "+n(neckTop+40)+" "+
			n(cx+46)+" "+n(neckTop+30)+"L"+n(cx+52)+` 492z"`)
		c.key += "M" + n(cx-40) + " " + n(neckTop+48) + "q44 10 88 0M" + n(cx-41) + " " + n(neckTop+62) + "q45 10 90 0"
	case outfitShirt:
		c.addA("path", `d="M`+n(cx-44)+" 478l40 40 6-46zM"+n(cx+52)+` 478l-40 40-6-46z"`)
		c.key += "M" + n(cx+3) + " 520v90"
		for y := 535; y < 600; y += 26 {
			c.key += "M" + n(cx+3) + " " + n(y) + "h.1"
		}
	case outfitKaftan:
		c.defs += `<pattern id="kf" width="22" height="22" patternUnits="userSpaceOnUse">` +
			`<path d="M3 0v22M14 0l4 5-4 6 4 5-4 6" stroke="` + AB + `" stroke-width="3" fill="none"/></pattern>`
		c.tex += `<use href="#bd" transform="` + tr(oBx, oBy) + `" fill="url(#kf)"/>`
		c.key += "M" + n(cx-40) + " 478L" + n(cx+4) + " 560L" + n(cx+46) + " 478"
	case outfitJacket:
		c.addA("path", `d="M`+n(cx-30)+" 480L"+n(cx+4)+" 600L"+n(cx+40)+` 480z"`)
		c.key += "M" + n(cx-44) + " 478L" + n(cx-60) + " 530L" + n(cx-30) + " 540L" + n(cx+2) + " 600M" +
			n(cx+50) + " 478L" + n(cx+66) + " 530L" + n(cx+38) + " 540L" + n(cx+6) + " 600"
	case outfitOveralls:
		c.addB("path", `d="M`+n(cx-80)+" 600V545h170V600zM"+n(cx-76)+" 548l-30-70h22l30 70zM"+n(cx+86)+
			` 548l30-70h-22l-30 70z"`)
		c.key += "M" + n(cx-60) + " 560h.1M" + n(cx+70) + " 560h.1"
	default: // outfitScarf
		c.addA("path", `d="M`+n(cx-64)+" "+n(neckTop+20)+"Q"+n(cx+4)+" "+n(neckTop+70)+" "+n(cx+74)+" "+
			n(neckTop+20)+"L"+n(cx+80)+" "+n(neckTop+60)+"Q"+n(cx+4)+" "+n(neckTop+110)+" "+n(cx-70)+" "+
			n(neckTop+60)+"zM"+n(cx+30)+" "+n(neckTop+70)+`l-10 90h34l6-90z"`)
		for k := 0; k < 4; k++ {
			c.key += "M" + n(cx+22+10*k) + " " + n(neckTop+160) + "v14"
		}
	}

	// --- hair (B drum) ---
	hair := t.hair
	capD := func(low int) string {
		return "M" + n(cx-rx-6) + " " + n(cy+low) + "C" + n(cx-rx-10) + " " + n(tY-40) + " " + n(cx+pc(rx, 70)) +
			" " + n(tY-46) + " " + n(cx+rx+8) + " " + n(cy-pc(ry, 35)) +
			"Q" + n(cx+pc(rx, 40)) + " " + n(cy-pc(ry, 55)) + " " + n(cx-pc(rx, 20)) + " " + n(cy-pc(ry, 45)) +
			"Q" + n(cx-pc(rx, 45)) + " " + n(cy-10) + " " + n(cx-pc(rx, 50)) + " " + n(cy+low) + "z"
	}
	if hair == hairWave {
		c.addB("path", `d="M`+n(cx-rx-20)+" "+n(cy-40)+"Q"+n(cx-rx-50)+" "+n(cy+160)+" "+n(cx-rx-10)+" 540Q"+
			n(cx-40)+" 560 "+n(cx-pc(rx, 25))+" "+n(cy+ry-10)+"L"+n(cx-pc(rx, 35))+" "+n(cy-30)+`z"`)
	}
	if hair == hairBraid {
		d := ""
		for k := 0; k < 5; k++ {
			d += "M" + n(cx-rx-10-6*k) + " " + n(cy+40+36*k) + "a16 20 0 1 0 32 0a16 20 0 1 0-32 0z"
		}
		c.addB("path", `d="`+d+`"`)
	}
	if hair == hairBangs || hair == hairBun || hair == hairBraid || hair == hairWave {
		low := 30
		if hair == hairBangs {
			low = 0
		}
		c.addB("path", `d="`+capD(low)+`"`)
	}
	if hair == hairBangs {
		d := "M" + n(cx-pc(rx, 20)) + " " + n(cy-pc(ry, 45))
		for k := 0; k < 6; k++ {
			if k%2 == 1 {
				d += "l16-14"
			} else {
				d += "l16 22"
			}
		}
		c.addB("path", `d="`+d+"L"+n(cx+pc(rx, 70))+" "+n(cy-pc(ry, 70))+`z"`)
	}
	if hair == hairBun {
		c.addB("circle", `cx="`+n(cx-pc(rx, 35))+`" cy="`+n(tY-18)+`" r="`+n(R.between(40, 52))+`"`)
	}
	if hair == hairCloud {
		d := ""
		for k := 0; k < 11; k++ {
			a, rr := 96+9*k, R.between(34, 46)
			x, y := cx+(rx+6)*cs(a)/1024-10, cy+(ry+4)*sn(a)/1024-6
			d += "M" + n(x-rr) + " " + n(y) + "a" + n(rr) + " " + n(rr) + " 0 1 0 " + n(2*rr) + " 0a" + n(rr) + " " +
				n(rr) + " 0 1 0-" + n(2*rr) + " 0z"
		}
		c.addB("path", `d="`+d+`"`)
	}
	if hair == hairBob {
		c.addB("path", `d="M`+n(cx-rx-14)+" "+n(cy+pc(ry, 55))+"V"+n(cy-20)+"C"+n(cx-rx-14)+" "+n(tY-50)+" "+
			n(cx+rx+10)+" "+n(tY-50)+" "+n(cx+rx+12)+" "+n(cy-pc(ry, 25))+"H"+n(cx-pc(rx, 30))+"V"+
			n(cy+pc(ry, 55))+`z"`)
	}
	if hair == hairQuiff {
		c.addB("path", `d="M`+n(cx-rx-4)+" "+n(cy+10)+"C"+n(cx-rx-20)+" "+n(tY-30)+" "+n(cx)+" "+n(tY-110)+" "+
			n(cx+rx+40)+" "+n(tY-70)+"Q"+n(cx+pc(rx, 30))+" "+n(tY-50)+" "+n(cx+pc(rx, 90))+" "+n(cy-pc(ry, 45))+
			"Q"+n(cx)+" "+n(cy-pc(ry, 60))+" "+n(cx-pc(rx, 45))+" "+n(cy+10)+`z"`)
	}
	if hair == hairBuzz {
		c.texSkin += `<path d="` + capD(-20) + `" transform="` + tr(oBx-oCx, oBy-oCy) + `" fill="url(#hb)"/>`
	}

	// --- accessory ---
	acc := t.accessory
	if acc == accBeret {
		c.addB("path", `d="M`+n(cx-rx-20)+" "+n(tY+40)+"Q"+n(cx-40)+" "+n(tY-70)+" "+n(cx+rx+30)+" "+n(tY+20)+
			"Q"+n(cx)+" "+n(tY+30)+" "+n(cx-rx-20)+" "+n(tY+40)+`z"`)
		c.addB("circle", `cx="`+n(cx-10)+`" cy="`+n(tY-28)+`" r="7"`)
	}
	if acc == accCap {
		c.addB("path", `d="M`+n(cx-rx-8)+" "+n(tY+60)+"C"+n(cx-rx)+" "+n(tY-40)+" "+n(cx+rx)+" "+n(tY-40)+" "+
			n(cx+rx+6)+" "+n(tY+44)+"Q"+n(cx+rx+80)+" "+n(tY+40)+" "+n(cx+rx+70)+" "+n(tY+62)+"Q"+n(cx)+" "+
			n(tY+40)+" "+n(cx-rx-8)+" "+n(tY+60)+`z"`)
	}
	if acc == accCrown {
		for k := 0; k < 6; k++ {
			a := 150 + 16*k
			x, y := cx+(rx-6)*cs(a)/1024, cy+(ry-10)*sn(a)/1024-6
			c.addA("circle", `cx="`+n(x)+`" cy="`+n(y)+`" r="15"`)
			c.key += "M" + n(x) + " " + n(y) + "h.1"
		}
	}
	if acc == accPhones {
		l, rr := cx-pc(rx, 60), cx+pc(rx, 30)
		c.addA("path", `d="M`+n(l)+" "+n(cy+8)+"C"+n(cx-pc(rx, 70))+" "+n(tY-60)+" "+n(cx+pc(rx, 50))+" "+
			n(tY-60)+" "+n(rr)+" "+n(tY+20)+"L"+n(rr-11)+" "+n(tY+23)+"C"+n(cx+pc(rx, 50)-8)+" "+n(tY-46)+" "+
			n(cx-pc(rx, 70)+12)+" "+n(tY-46)+" "+n(l+12)+" "+n(cy+8)+`z"`)
		c.addA("rect", `x="`+n(cx-pc(rx, 55)-24)+`" y="`+n(cy-20)+`" width="44" height="62" rx="16"`)
	}
	if acc == accBandana {
		c.addA("path", `d="M`+n(cx-rx-6)+" "+n(cy-pc(ry, 30))+"Q"+n(cx)+" "+n(cy-pc(ry, 75))+" "+n(cx+rx+6)+" "+
			n(cy-pc(ry, 55))+"l2 26Q"+n(cx)+" "+n(cy-pc(ry, 50))+" "+n(cx-rx-2)+" "+n(cy-pc(ry, 5))+"zM"+
			n(cx-rx-4)+" "+n(cy-pc(ry, 20))+`l-40 30 10 10z"`)
	}

	// --- skin (C drum) ---
	skin := `<path id="nk" d="` + neckD + `"/><path id="hd" d="` + headD + `"/><ellipse id="ea" cx="` + n(earX) +
		`" cy="` + n(cy+12) + `" rx="15" ry="24"/>`

	// --- face (key drum) ---
	nose := pick(R, noseOpts)
	nl, nt := R.between(44, 60), R.between(26, 40)
	n0x, n0y, tipX, tipY, bX, bY := fx+4, ey-26, fx+nt, ey+nl, fx+8, ey+nl+12
	switch nose {
	case 0:
		c.key += "M" + n(n0x) + " " + n(n0y) + "L" + n(tipX) + " " + n(tipY) + "L" + n(bX) + " " + n(bY)
	case 1:
		c.key += "M" + n(n0x) + " " + n(n0y) + "Q" + n(tipX+14) + " " + n(n0y+20) + " " + n(tipX) + " " + n(tipY+6) +
			"L" + n(bX) + " " + n(bY)
	case 2:
		c.key += "M" + n(n0x) + " " + n(n0y) + "L" + n(tipX-6) + " " + n(tipY-10) + "l12-4L" + n(bX) + " " + n(bY)
	default:
		c.key += "M" + n(n0x) + " " + n(n0y) + "L" + n(tipX-10) + " " + n(tipY-14) + "a14 14 0 1 1-2 26L" + n(bX) +
			" " + n(bY)
	}

	// near eye (s = 100) left of the nose, far eye (s = 80) beyond it
	e1x, e1y, e2x, e2y := fx-36, ey+2, fx+38, ey
	c.eye(e1x, e1y, 100, eyes)
	if eyes == eyeWink {
		c.eye(e2x, e2y, 80, eyeDot)
	} else {
		c.eye(e2x, e2y, 80, eyes)
	}
	bl := R.between(-8, 8)
	lift := 0
	if t.expression == exprSurprised {
		lift = 10
	}
	c.key += "M" + n(e1x-16) + " " + n(e1y-24+bl-lift) + "l30 " + n(-bl-4) + "M" + n(e2x-10) + " " +
		n(e2y-22-bl/2-lift) + "l20 " + n(bl/2)
	mx, my := fx+12, ey+nl+40
	switch mouth {
	case mouthFlat:
		c.key += "M" + n(mx-14) + " " + n(my) + "h30"
	case mouthSmile:
		c.key += "M" + n(mx-18) + " " + n(my-4) + "q18 16 36-2"
	case mouthO:
		c.key += "M" + n(mx-6) + " " + n(my) + "a7 9 0 1 0 14 0a7 9 0 1 0-14 0"
	case mouthWhistle:
		c.keyF += `<circle cx="` + n(mx+4) + `" cy="` + n(my) + `" r="6"/>`
		c.key += "M" + n(mx+26) + " " + n(my-12) + "l10-8M" + n(mx+30) + " " + n(my) + "h12"
	case mouthGrin:
		c.key += "M" + n(mx-22) + " " + n(my-6) + "q22 26 44 0zM" + n(mx-18) + " " + n(my) + "h36"
	default: // lips
		c.addA("path", `d="M`+n(mx-18)+" "+n(my)+`q9-12 18-4q9-8 18 4q-18 16-36 0z"`)
	}
	c.key += "M" + n(earX-4) + " " + n(cy+2) + "q10 8 2 22"

	// --- small accessories ---
	if acc == accHoop {
		c.key += "M" + n(earX-9) + " " + n(cy+40) + "a10 12 0 1 0 20 0a10 12 0 1 0-20 0"
	}
	if acc == accEarFlower {
		x, y := cx-pc(rx, 62), cy-22
		for k := 0; k < 5; k++ {
			c.addA("circle", `cx="`+n(x+15*cs(51*k)/1024)+`" cy="`+n(y+15*sn(51*k)/1024)+`" r="11"`)
		}
		c.keyF += `<circle cx="` + n(x) + `" cy="` + n(y) + `" r="5"/>`
	}
	if acc == accPencil {
		x, y := cx-rx-30, cy+4
		c.addA("path", `d="M`+n(x)+" "+n(y)+`l95-31 5 14-95 31z"`)
		c.key += "M" + n(x+95) + " " + n(y-31) + "l16 5-11 9"
	}
	if acc == accEvilEye {
		x := cx - 80
		c.addA("circle", `cx="`+n(x)+`" cy="548" r="18"`)
		c.tex += `<circle cx="` + n(x+oAx) + `" cy="` + n(548+oAy) + `" r="10" fill="` + P + `"/>`
		c.keyF += `<circle cx="` + n(x) + `" cy="548" r="5"/>`
		c.key += "M" + n(x-18) + " 548a18 18 0 1 0 36 0a18 18 0 1 0-36 0"
	}
	if acc == accStar {
		c.addA("path", `d="M`+n(cx+90)+` 532l6 13 14 2-10 10 2 14-12-7-12 7 2-14-10-10 14-2z"`)
	}
	if acc == accBird {
		x := cx + sw - 30
		c.addA("ellipse", `cx="`+n(x)+`" cy="482" rx="26" ry="18"`)
		c.addA("circle", `cx="`+n(x+22)+`" cy="466" r="12"`)
		c.key += "M" + n(x-22) + " 478q20-18 36 2M" + n(x+32) + " 464l10 3-10 4"
		c.keyF += `<circle cx="` + n(x+24) + `" cy="463" r="2.5"/>`
	}

	// --- misprints ---
	if t.print == printBlot {
		x, y := R.between(80, 520), R.between(80, 520)
		c.addB("path", `d="M`+n(x)+" "+n(y)+`q36-52 68-8q44 8 12 52q-12 40-56 20q-52 4-24-64z"`)
		c.addB("circle", `cx="`+n(x+96)+`" cy="`+n(y-18)+`" r="8"`)
		c.addB("circle", `cx="`+n(x-26)+`" cy="`+n(y+70)+`" r="5"`)
	}

	// --- shading (halftone dots, pre-multiplied with the skin ink they sit on) ---
	c.defs += dotPattern("hb", BC, 7, "2.1", 45) + dotPattern("ha", AC, 9, "2.7", 15)
	shade := `<circle cx="` + n(cx-pc(rx, 125)+oBx-oCx) + `" cy="` + n(cy+20+oBy-oCy) + `" r="` + n(pc(rx, 105)) +
		`" fill="url(#hb)"/><circle cx="` + n(fx-34+oAx-oCx) + `" cy="` + n(ey+46+oAy-oCy) +
		`" r="24" fill="url(#ha)"/>`
	// the head's cast shadow on the neck: the head moved down, clipped to the neck and outside the head
	neckShade := `<use href="#hd" transform="` + tr(oBx-oCx+6, oBy-oCy+28) + `" fill="url(#hb)"/>`

	// --- assemble ---
	fa, fb := "url(#ik)", "url(#ik)"
	if t.print == printStarved {
		fb = "url(#is)"
	}
	clipA := ""
	for _, id := range c.aIDs {
		clipA += `<use href="#` + id + `"/>`
	}
	out := `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 600 600"><defs>` + c.defs +
		`<clipPath id="cc"><use href="#nk"/><use href="#hd"/><use href="#ea"/></clipPath>` +
		`<clipPath id="cn"><use href="#nk"/></clipPath><clipPath id="co"><path clip-rule="evenodd" d="M-50-50h700v700h-700z` +
		headD + `"/></clipPath><clipPath id="ca">` + clipA + `</clipPath>` +
		`<g id="rm" fill="none" stroke-width="2"><circle cx="560" cy="40" r="10"/><path d="M542 40h36M560 22v36"/></g>` +
		`<filter id="ik" x="-5%" y="-5%" width="110%" height="110%"><feTurbulence type="fractalNoise" baseFrequency="1.1" ` +
		`numOctaves="1" seed="` + n(inkSeed) + `" result="n"/><feColorMatrix in="n" values="0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 -14 11.4" ` +
		`result="m"/><feComposite in="SourceGraphic" in2="m" operator="in"/></filter>`
	if t.print == printStarved {
		out += `<filter id="is" x="-5%" y="-5%" width="110%" height="110%"><feTurbulence type="fractalNoise" baseFrequency=".9" ` +
			`numOctaves="2" seed="` + n(inkSeed) + `" result="n"/><feColorMatrix in="n" values="0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 -9 5.6" ` +
			`result="m"/><feComposite in="SourceGraphic" in2="m" operator="in"/></filter>`
	}
	out += `<filter id="pp" x="0" y="0" width="1" height="1"><feTurbulence type="fractalNoise" baseFrequency=".6" ` +
		`numOctaves="2" seed="` + n(paperSeed) + `"/><feColorMatrix values="0 0 0 0 .4 0 0 0 0 .32 0 0 0 0 .22 0 0 0 -1.5 .8"/></filter>` +
		`</defs><rect width="600" height="600" fill="` + P + `"/>`
	if left {
		out += `<g transform="matrix(-1 0 0 1 600 0)">`
	} else {
		out += "<g>"
	}
	if bg != "" {
		out += `<g filter="` + fa + `">` + bg + `</g>`
		// knock-out: no backdrop ink under the figure (the A plate's own offset)
		out += `<g transform="` + tr(oAx, oAy) + `" fill="` + P + `"><use href="#C"/><use href="#A"/><use href="#B"/></g>`
	}
	if t.print == printGhost {
		gx := R.between(50, 90)
		if R.intn(2) == 1 {
			gx = -gx
		}
		gy := R.between(-20, 20)
		out += `<g transform="` + tr(oBx+gx, oBy+gy) + `" fill="` + B + `" opacity=".22"><use href="#B"/></g>`
	}
	// single plates
	out += `<g transform="` + tr(oCx, oCy) + `" fill="` + C + `" filter="` + fa + `"><g id="C">` + skin + `</g></g>`
	out += `<g transform="` + tr(oAx, oAy) + `" fill="` + A + `" filter="` + fa + `"><g id="A">` + c.aEls + `</g></g>`
	out += `<g transform="` + tr(oBx, oBy) + `" fill="` + B + `" filter="` + fb + `"><g id="B">` + c.bEls + `</g></g>`
	// overprint: each overlap gets the product of its inks
	out += `<g transform="` + tr(oCx, oCy) + `" clip-path="url(#cc)">` +
		`<g transform="` + tr(oAx-oCx, oAy-oCy) + `" fill="` + AC + `" filter="` + fa + `"><use href="#A"/></g>` +
		`<g transform="` + tr(oBx-oCx, oBy-oCy) + `" fill="` + BC + `" filter="` + fb + `"><use href="#B"/></g></g>`
	if len(c.aIDs) > 0 {
		out += `<g transform="` + tr(oAx, oAy) + `" clip-path="url(#ca)">` +
			`<g transform="` + tr(oBx-oAx, oBy-oAy) + `" fill="` + AB + `" filter="` + fb + `"><use href="#B"/></g></g>` +
			`<g transform="` + tr(oCx, oCy) + `" clip-path="url(#cc)"><g transform="` + tr(oAx-oCx, oAy-oCy) +
			`" clip-path="url(#ca)"><g transform="` + tr(oBx-oAx, oBy-oAy) + `" fill="` + ABC + `" filter="` + fb +
			`"><use href="#B"/></g></g></g>`
	}
	// halftone shading and textures
	out += `<g transform="` + tr(oCx, oCy) + `" clip-path="url(#cc)" filter="` + fb + `">` + shade + c.texSkin + `</g>` +
		`<g transform="` + tr(oCx, oCy) + `" clip-path="url(#cn)"><g clip-path="url(#co)" filter="` + fb + `">` +
		neckShade + `</g></g>`
	if c.tex != "" {
		out += `<g filter="` + fb + `">` + c.tex + `</g>`
	}
	// key plate
	out += `<g id="K" transform="` + tr(oKx, oKy) + `"><path d="` + c.key + `" fill="none" stroke="` + K +
		`" stroke-width="4" stroke-linecap="round" stroke-linejoin="round"/><g fill="` + K + `">` + c.keyF + `</g></g>`
	if t.print == printDouble {
		dx := R.between(5, 9)
		dy := R.between(-7, 7)
		out += `<use href="#K" transform="` + tr(dx, dy) + `" opacity=".45"/>`
	}
	// registration marks, one per plate
	out += `<use href="#rm" stroke="` + C + `" transform="` + tr(oCx, oCy) + `"/><use href="#rm" stroke="` + A +
		`" transform="` + tr(oAx, oAy) + `"/><use href="#rm" stroke="` + B + `" transform="` + tr(oBx, oBy) +
		`"/><use href="#rm" stroke="` + K + `" transform="` + tr(oKx, oKy) + `"/>`
	out += `</g><rect width="600" height="600" filter="url(#pp)" opacity=".3"/></svg>`
	return out
}
