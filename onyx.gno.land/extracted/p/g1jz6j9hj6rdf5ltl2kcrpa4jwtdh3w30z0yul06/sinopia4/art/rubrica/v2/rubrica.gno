// Package rubrica (v2, "Living Language") is a Sinopia engine: every token
// invents a language and writes one manuscript leaf in it.
//
// The language is an alphabet of 12-20 glyphs (strokes on a 3x4 node grid in
// one of five hands) and a lexicon of 22-40 words built from it. Glyph use and
// word use both follow a Zipf law and the most frequent words are the
// shortest, so the text reads like writing rather than noise. The leaf is
// laid out like a real codex page: justified lines, paragraphs closed by a
// punctus, ink that fades until the scribe dips the pen again, a great
// initial, lombards, rubrics and line fillers, a vine border or a full frame,
// a marginal drawing, a running head, a catchword and the folio number,
// which is the token number written in medieval numerals (f. xiiij v).
//
// A stateless p/ package implementing engine/v2. Pure integer maths (FNV-1a +
// splitmix64 streams, truncating and floor division), so the TypeScript twin
// (frontend/src/engines/rubricav2.ts) renders the same bytes. Traits come
// from their own cheap stream (seed+"|traits") and never render; the art uses
// seed+"|art", so art draws never shift traits. Words are defined once in
// <defs> and placed with <use>; a word budget caps every leaf.
//
// The render depends on Input.TokenID (the folio number) and on nothing else
// outside Seed and Params; it is not a living engine.
package rubrica

import (
	"errors"
	"strconv"
	"strings"

	"gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia4/engine/v2"
)

// TraitTypes in the order Traits returns them.
var traitTypes = []string{"Hand", "Layout", "Decoration", "Vellum", "Marginalia", "Condition", "Alphabet", "Rarity"}

// MaxSVGBytes: the measured maximum is 25,666 B over ~100,000 renders with
// every forced hand/layout set (docs/engines/rubrica-v2.md); WordBudget
// bounds the text.
const MaxSVGBytes = 28672

// WordBudget caps the words placed on one leaf (text, gloss, palimpsest): the
// size and gas knob. It binds only on the densest glossed leaves, whose last
// gloss (or palimpsest) lines then stay short.
const WordBudget = 500

// ParamsSchema is the Studio form: three optional overrides and a wear
// switch. Studio sends JSON.stringify of the values in this order.
const ParamsSchema = `{"type":"object","properties":{` +
	`"hand":{"type":"string","title":"Hand","enum":["Any","Angular","Round","Hooked","Dotted","Slanted"],"default":"Any"},` +
	`"layout":{"type":"string","title":"Layout","enum":["Any","Single Column","Two Columns","Glossed"],"default":"Any"},` +
	`"vellum":{"type":"string","title":"Vellum","enum":["Any","Calfskin","Goatskin","Rag Paper","Purple"],"default":"Any"},` +
	`"damage":{"type":"boolean","title":"Wear and damage","default":true}}}`

// Manifest describes the engine. Author and FeeBps are set by the adapter.
func Manifest() engine.Manifest {
	return engine.Manifest{
		Name:    "Rubrica v2 · Living Language",
		Version: "2.0.0",
		Description: "Every Rubrica invents a language, an alphabet of twelve to twenty letters and a lexicon of " +
			"its own words, and writes one leaf of a manuscript in it: justified lines, rubrics, lombards, " +
			"gilded initials, marginal drawings, and the token's number as the folio.",
		License:      "CC-BY-NC-4.0",
		ParamsSchema: ParamsSchema,
		TraitTypes:   append([]string{}, traitTypes...),
		Living:       false,
		MaxSVGBytes:  MaxSVGBytes,
		Kind:         engine.KindSVG,
	}
}

// ---------------------------------------------------------------------------
// Params: "" or exactly the canonical Studio JSON
// {"hand":"…","layout":"…","vellum":"…","damage":true|false}.
// ---------------------------------------------------------------------------

// Params are the decoded collection params. "Any" keeps the seeded draw;
// Damage false makes every leaf Fine.
type Params struct {
	Hand, Layout, Vellum string
	Damage               bool
}

var (
	handParam   = []string{"Any", "Angular", "Round", "Hooked", "Dotted", "Slanted"}
	layoutParam = []string{"Any", "Single Column", "Two Columns", "Glossed"}
	vellumParam = []string{"Any", "Calfskin", "Goatskin", "Rag Paper", "Purple"}
	errParams   = errors.New("rubrica v2: params must be \"\" or the canonical JSON")
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
	if !lit(`{"hand":"`) {
		return p, errParams
	}
	if p.Hand, ok = str(handParam); !ok {
		return p, errors.New("rubrica v2: invalid hand")
	}
	if !lit(`","layout":"`) {
		return p, errParams
	}
	if p.Layout, ok = str(layoutParam); !ok {
		return p, errors.New("rubrica v2: invalid layout")
	}
	if !lit(`","vellum":"`) {
		return p, errParams
	}
	if p.Vellum, ok = str(vellumParam); !ok {
		return p, errors.New("rubrica v2: invalid vellum")
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

// ---------------------------------------------------------------------------
// Deterministic randomness: FNV-1a over the seed, then splitmix64 (as v1).
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

// n returns a value in [0, k). It inlines next: a GnoVM call costs more
// than the arithmetic, and the art draws thousands of these.
func (r *rng) n(k int) int {
	if k <= 0 {
		return 0
	}
	r.s += 0x9E3779B97F4A7C15
	z := r.s
	z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9
	z = (z ^ (z >> 27)) * 0x94D049BB133111EB
	return int((z ^ (z >> 31)) % uint64(k))
}

// rr returns a value in [a, b].
func (r *rng) rr(a, b int) int { return a + r.n(b-a+1) }

// w returns an index into a weight list.
func (r *rng) w(weights []int) int {
	total := 0
	for _, x := range weights {
		total += x
	}
	roll := r.n(total)
	for i, x := range weights {
		if roll < x {
			return i
		}
		roll -= x
	}
	return len(weights) - 1
}

// cumulative turns positive weights into running sums for pick.
func cumulative(weights []int) []int {
	cum := make([]int, len(weights))
	acc := 0
	for i, x := range weights {
		acc += x
		cum[i] = acc
	}
	return cum
}

// pick is w over running sums: the first index whose sum exceeds the roll,
// found by bisection (the same index w's linear scan returns).
func (r *rng) pick(cum []int) int {
	roll := r.n(cum[len(cum)-1])
	lo, hi := 0, len(cum)-1
	for lo < hi {
		mid := (lo + hi) / 2
		if roll < cum[mid] {
			hi = mid
		} else {
			lo = mid + 1
		}
	}
	return lo
}

// ---------------------------------------------------------------------------
// Trait tables: names, weights (percent), rarity score.
// ---------------------------------------------------------------------------

type table struct {
	names   []string
	weights []int
	scores  []int
}

var (
	hands   = table{[]string{"Angular", "Round", "Hooked", "Dotted", "Slanted"}, []int{26, 24, 18, 16, 16}, []int{0, 0, 0, 0, 0}}
	layouts = table{[]string{"Single Column", "Two Columns", "Glossed"}, []int{40, 36, 24}, []int{0, 0, 2}}
	decos   = table{[]string{"Plain", "Rubricated", "Lombards", "Gilded", "Vine Border", "Full Illumination"},
		[]int{20, 28, 22, 16, 9, 5}, []int{0, 0, 0, 1, 2, 4}}
	vellums = table{[]string{"Calfskin", "Goatskin", "Rag Paper", "Purple"}, []int{38, 28, 26, 8}, []int{0, 0, 0, 4}}
	inks    = table{[]string{"Iron Gall", "Carbon", "Sepia", "Lapis"}, []int{40, 26, 24, 10}, []int{0, 0, 0, 0}}
	margs   = table{[]string{"None", "Pointing Hand", "Snail", "Bird", "Flower"}, []int{44, 16, 14, 14, 12}, []int{0, 1, 1, 1, 1}}
	conds   = table{[]string{"Fine", "Wormholes", "Water Stain", "Torn Corner", "Palimpsest", "Burnt Edge"},
		[]int{40, 18, 17, 12, 8, 5}, []int{0, 1, 1, 1, 3, 3}}
)

// Rarity tier cut-offs on the score (10,000 SampleSeeds, default params):
// Common 48.3% / Uncommon 30.7% / Rare 14.4% / Legendary 5.0% / Mythic 1.5%.
const (
	scoreMythic    = 9
	scoreLegendary = 7
	scoreRare      = 5
	scoreUncommon  = 3
)

func indexOf(t table, name string) int {
	for i, n := range t.names {
		if n == name {
			return i
		}
	}
	return 0
}

// TraitSet is the decoded token: indexes into the tables above. The SVG and
// the trait list both read it.
type TraitSet struct {
	Hand, Layout, Decoration, Vellum, Ink, Marginalia, Condition int
	Alphabet, Lexicon                                            int
	Score                                                        int
	Rarity                                                       string
}

func derive(seed string, p Params) TraitSet {
	r := newRNG(seed + "|traits")
	// Draw order is part of the contract: every draw happens whatever the params.
	var t TraitSet
	t.Hand = r.w(hands.weights)
	t.Layout = r.w(layouts.weights)
	t.Decoration = r.w(decos.weights)
	t.Vellum = r.w(vellums.weights)
	t.Ink = r.w(inks.weights)
	t.Marginalia = r.w(margs.weights)
	t.Condition = r.w(conds.weights)
	t.Alphabet = r.rr(12, 20)
	t.Lexicon = r.rr(22, 40)
	if p.Hand != "Any" {
		t.Hand = indexOf(hands, p.Hand)
	}
	if p.Layout != "Any" {
		t.Layout = indexOf(layouts, p.Layout)
	}
	if p.Vellum != "Any" {
		t.Vellum = indexOf(vellums, p.Vellum)
	}
	if !p.Damage {
		t.Condition = 0
	}
	score := hands.scores[t.Hand] + layouts.scores[t.Layout] + decos.scores[t.Decoration] +
		vellums.scores[t.Vellum] + margs.scores[t.Marginalia] + conds.scores[t.Condition]
	if t.Alphabet >= 19 {
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

func traitList(t TraitSet) []engine.Trait {
	return []engine.Trait{
		{Type: "Hand", Value: hands.names[t.Hand]},
		{Type: "Layout", Value: layouts.names[t.Layout]},
		{Type: "Decoration", Value: decos.names[t.Decoration]},
		{Type: "Vellum", Value: vellums.names[t.Vellum]},
		{Type: "Marginalia", Value: margs.names[t.Marginalia]},
		{Type: "Condition", Value: conds.names[t.Condition]},
		{Type: "Alphabet", Value: strconv.Itoa(t.Alphabet) + " letters"},
		{Type: "Rarity", Value: t.Rarity},
	}
}

// Traits returns the eight traits of in.Seed under in.Params, in TraitTypes
// order. It never renders.
func Traits(in engine.Input) []engine.Trait { return traitList(TraitsOf(in.Seed, in.Params)) }

// Render returns the raw SVG for in.Seed under in.Params; in.TokenID is the
// folio number.
func Render(in engine.Input) string { return SVG(in.Seed, in.Params, in.TokenID) }

// TraitString is "Type=Value;…" in TraitTypes order (golden vectors).
func TraitString(seed, params string) string {
	var b strings.Builder
	for i, t := range traitList(TraitsOf(seed, params)) {
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
	hAngular = 0
	hRound   = 1
	hHooked  = 2
	hDotted  = 3
	hSlanted = 4

	lSingle  = 0
	lTwo     = 1
	lGlossed = 2

	dPlain      = 0
	dRubricated = 1
	dLombards   = 2
	dGilded     = 3
	dVine       = 4
	dFull       = 5

	vGoat   = 1
	vRag    = 2
	vPurple = 3

	mNone   = 0
	mHand   = 1
	mSnail  = 2
	mBird   = 3
	mFlower = 4

	cWorm       = 1
	cStain      = 2
	cTorn       = 3
	cPalimpsest = 4
	cBurnt      = 5

	goldInk = "#e2bd62"
	green   = "#4f7a3a"
	dark    = "#2a221d"

	adv    = 11 // glyph advance inside a word
	gap    = 7  // word space
	tries  = 3  // draws a scribe tries before ending a line
	maxGap = 9  // justification never widens a word space by more than this
	// one-letter ids of the lexicon's words (Lexicon <= 40 never reaches "v",
	// the texture filter)
	wid = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmn"
)

var (
	pageLight  = []string{"#efe1c2", "#eadbb9", "#f2ebda", "#4e2346"}
	pageEdge   = []string{"#cfb489", "#c8ad80", "#d6c8a8", "#2a0f26"}
	inkColor   = []string{"#3a2a1c", "#1e1b18", "#5c3c22", "#1f3566"}
	gx3        = []int{0, 4, 8}
	gy4        = []int{-12, -8, -4, 0}
	qx3        = []int{-2, 4, 10}
	qy3        = []int{-14, -6, 2}
	stemEnd    = []int{0, 0, -4}
	dotY       = []int{-16, 4}
	lenWeights = []int{5, 14, 20, 20, 16, 11, 8} // word length 1..7
	romanVals  = []int{1000, 900, 500, 400, 100, 90, 50, 40, 10, 9, 5, 4, 1}
	romanSyms  = []string{"m", "cm", "d", "cd", "c", "xc", "l", "xl", "x", "ix", "v", "iv", "i"}
)

// pairs holds "00".."99"; itoa slices it instead of calling strconv, whose
// formatting loop is the most expensive thing an SVG writer does in GnoVM.
const pairs = "00010203040506070809101112131415161718192021222324252627282930313233343536373839" +
	"40414243444546474849505152535455565758596061626364656667686970717273747576777879" +
	"8081828384858687888990919293949596979899"

func itoa(n int) string {
	switch {
	case n < 0:
		return "-" + itoa(-n)
	case n < 10:
		return pairs[2*n+1 : 2*n+2]
	case n < 100:
		return pairs[2*n : 2*n+2]
	case n < 1000:
		q, m := n/100, n%100
		return pairs[2*q+1:2*q+2] + pairs[2*m:2*m+2]
	}
	return strconv.Itoa(n)
}

func floorDiv(a, b int) int {
	q := a / b
	if a%b != 0 && (a < 0) != (b < 0) {
		q--
	}
	return q
}

// RomanFolio writes n in medieval lower-case roman numerals; a final i is
// written j (iij, viij).
func RomanFolio(n int) string {
	s := ""
	for i, v := range romanVals {
		for n >= v {
			s += romanSyms[i]
			n -= v
		}
	}
	if len(s) >= 2 && strings.HasSuffix(s, "ii") {
		s = s[:len(s)-1] + "j"
	}
	return s
}

// FolioNumber reads Input.TokenID: 1..99999, else 0 (sample, Studio).
func FolioNumber(tokenID string) int {
	if len(tokenID) == 0 || len(tokenID) > 5 {
		return 0
	}
	n := 0
	for i := 0; i < len(tokenID); i++ {
		c := tokenID[i]
		if c < '0' || c > '9' {
			return 0
		}
		n = n*10 + int(c-'0')
	}
	return n
}

// part is one stroke of a glyph, points already slanted.
// k: 0 line a-b, 1 line a-c-b, 2 quad a(c)b, 3 hook at a, 4 dot at a.
type part struct {
	k int
	p [6]int
}

// sp is the separator before y in "x y": none before a minus sign.
func sp(y int) string {
	if y < 0 {
		return ""
	}
	return " "
}

// glyphPath is the path data of a glyph shifted right by ox.
func glyphPath(parts []part, ox int) string {
	d := ""
	for _, q := range parts {
		p := q.p
		d += "M" + itoa(p[0]+ox) + sp(p[1]) + itoa(p[1])
		switch q.k {
		case 0:
			d += "L" + itoa(p[2]+ox) + sp(p[3]) + itoa(p[3])
		case 1:
			d += "L" + itoa(p[4]+ox) + sp(p[5]) + itoa(p[5]) + "L" + itoa(p[2]+ox) + sp(p[3]) + itoa(p[3])
		case 2:
			d += "Q" + itoa(p[4]+ox) + sp(p[5]) + itoa(p[5]) + " " + itoa(p[2]+ox) + sp(p[3]) + itoa(p[3])
		case 3:
			d += "l3 2"
		default:
			d += "h.5"
		}
	}
	return d
}

// opac is the opacity attribute of an ink level 70..100 (100: none).
func opac(v int) string {
	if v >= 100 {
		return ""
	}
	return ` opacity=".` + itoa(v) + `"`
}

type column struct {
	x, y int // page x of the column, page y of its first baseline
	w, n int // width in text units, lines
	s    int // scale x100
	ss   string
}

// leaf holds what the layout helpers share.
type leaf struct {
	lex    [][]int
	wl     []int // drawn width of each word
	budget int
}

// justify returns the final x of each word of a line: justified to width
// (the gap left over is spread over the word spaces) unless ragged (a
// paragraph's last line).
func (l *leaf) justify(words, xs []int, width int, ragged bool) []int {
	n := len(words)
	extra := 0
	if !ragged && n > 1 {
		extra = width - (xs[n-1] + l.wl[words[n-1]])
		if extra < 0 || extra > maxGap*(n-1) {
			extra = 0
		}
	}
	px := make([]int, n)
	for i := 0; i < n; i++ {
		px[i] = xs[i]
		if extra > 0 {
			px[i] += extra * i / (n - 1)
		}
	}
	return px
}

// uses is the <use> elements for words[from:to] at px.
func uses(words, px []int, from, to int) string {
	out := ""
	for i := from; i < to; i++ {
		w := words[i]
		if px[i] == 0 {
			out += `<use href="#` + wid[w:w+1] + `"/>`
		} else {
			out += `<use href="#` + wid[w:w+1] + `" x="` + itoa(px[i]) + `"/>`
		}
	}
	return out
}

func leafPath(x, y, s int) string {
	return "M" + itoa(x) + " " + itoa(y) + "q" + itoa(6*s) + "-9 " + itoa(18*s) + "-3q" + itoa(-7*s) + " 8 " + itoa(-18*s) + " 3z"
}

// SVG renders the leaf for a seed, params string and token id ("" or "0":
// the folio number is drawn from the seed).
func SVG(seed, params, tokenID string) string {
	return svgOf(seed, derive(seed, mustParams(params)), tokenID)
}

func svgOf(seed string, t TraitSet, tokenID string) string {
	R := newRNG(seed + "|art")
	A := t.Alphabet
	V := t.Lexicon
	hand := t.Hand
	purple := t.Vellum == vPurple
	page := pageLight[t.Vellum]
	edge := pageEdge[t.Vellum]
	ink := inkColor[t.Ink]
	red, blue := "#ae3328", "#2a4f8a"
	if purple {
		ink, red, blue = goldInk, "#e8e2d8", "#9fc2e8"
	}
	deco := t.Decoration
	gilded := deco >= dGilded
	hasLomb := deco == dLombards || deco >= dGilded
	hasHead := deco == dRubricated || deco == dVine || deco == dFull
	usesGold := gilded || t.Marginalia == mBird || t.Marginalia == mFlower

	filterSeed := R.rr(1, 900)

	// --- the alphabet ---
	sk := func(y int) int {
		if hand == hSlanted {
			return floorDiv(5-3*y, 10)
		}
		return 0
	}
	glyphs := make([][]part, A)
	for g := 0; g < A; g++ {
		var parts []part
		ns := R.rr(2, 3)
		for s := 0; s < ns; s++ {
			var ax, ay, bx, by int
			if s == 0 {
				ax = gx3[R.n(3)]
				ay = -12
				if R.n(5) == 0 {
					ay = -16 // ascender
				}
				bx = gx3[R.n(3)]
				by = stemEnd[R.n(3)]
				if R.n(6) == 0 {
					by = 4 // descender
				}
			} else {
				ai := R.n(12)
				bi := R.n(12)
				for bi == ai {
					bi = R.n(12)
				}
				ax, ay = gx3[ai%3], gy4[ai/3]
				bx, by = gx3[bi%3], gy4[bi/3]
			}
			q := part{k: 0, p: [6]int{ax + sk(ay), ay, bx + sk(by), by, 0, 0}}
			if hand == hRound && R.n(100) < 70 {
				cy := qy3[R.n(3)]
				cx := qx3[R.n(3)]
				q.k, q.p[4], q.p[5] = 2, cx+sk(cy), cy
			} else if hand == hAngular && R.n(100) < 50 {
				cx := gx3[R.n(3)]
				cy := gy4[R.n(4)]
				q.k, q.p[4], q.p[5] = 1, cx+sk(cy), cy
			}
			parts = append(parts, q)
		}
		if hand == hHooked {
			e := parts[0].p
			parts = append(parts, part{k: 3, p: [6]int{e[2], e[3], 0, 0, 0, 0}})
		}
		if hand == hDotted && R.n(100) < 55 {
			dx := gx3[R.n(3)]
			dy := dotY[R.n(2)]
			parts = append(parts, part{k: 4, p: [6]int{dx + sk(dy), dy, 0, 0, 0, 0}})
		}
		glyphs[g] = parts
	}

	// --- the lexicon: Zipf-weighted glyphs, frequent words shortest ---
	gw := make([]int, A)
	for i := 0; i < A; i++ {
		gw[i] = 600 / (i + 1)
	}
	gcum := cumulative(gw)
	lf := &leaf{lex: make([][]int, V), wl: make([]int, V), budget: WordBudget}
	for w := 0; w < V; w++ {
		n := 1 + R.w(lenWeights)
		word := make([]int, n)
		for i := 0; i < n; i++ {
			word[i] = R.pick(gcum)
		}
		lf.lex[w] = word
	}
	// stable insertion sort by length
	for i := 1; i < V; i++ {
		for j := i; j > 0 && len(lf.lex[j]) < len(lf.lex[j-1]); j-- {
			lf.lex[j], lf.lex[j-1] = lf.lex[j-1], lf.lex[j]
		}
	}
	ww := make([]int, V)
	for i := 0; i < V; i++ {
		ww[i] = 1000 / (i + 2)
		lf.wl[i] = len(lf.lex[i])*adv - 3
	}
	wcum := cumulative(ww)
	wl := lf.wl

	var defs strings.Builder
	defs.WriteString("<defs>")
	for i := 0; i < V; i++ {
		d := ""
		for k, g := range lf.lex[i] {
			d += glyphPath(glyphs[g], k*adv)
		}
		defs.WriteString(`<path id="` + wid[i:i+1] + `" d="` + d + `"/>`)
	}

	// --- the leaf ---
	defs.WriteString(`<radialGradient id="ed" cx=".5" cy=".48" r=".72"><stop offset=".55" stop-color="` + edge +
		`" stop-opacity="0"/><stop offset="1" stop-color="` + edge + `" stop-opacity=".9"/></radialGradient>`)
	defs.WriteString(`<filter id="v" x="0" y="0" width="1" height="1"><feTurbulence type="fractalNoise" baseFrequency=".012" numOctaves="3" seed="` +
		itoa(filterSeed) + `"/><feColorMatrix values="0 0 0 0 .45 0 0 0 0 .3 0 0 0 0 .15 0 0 0 -1.6 .75"/><feComposite in2="SourceAlpha" operator="in"/></filter>`)
	if usesGold {
		defs.WriteString(`<linearGradient id="au" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#f6e29a"/><stop offset=".45" stop-color="#c89a3a"/>` +
			`<stop offset=".7" stop-color="#f3dc8c"/><stop offset="1" stop-color="#a87a28"/></linearGradient>`)
	}
	pageD := "M16 14H584V806H16z"
	if t.Condition == cTorn {
		var pb strings.Builder
		pb.WriteString("M16 14H584V656")
		x, y := 584, 656
		for y < 806 && x > 414 {
			x -= R.rr(8, 20)
			y += R.rr(8, 22)
			yc := y
			if yc > 806 {
				yc = 806
			}
			pb.WriteString("L" + itoa(x) + " " + itoa(yc))
		}
		pb.WriteString("L" + itoa(x) + " 806H16z")
		pageD = pb.String()
	}
	defs.WriteString(`<path id="pg" d="` + pageD + `"/><clipPath id="cp"><use href="#pg"/></clipPath>`)
	if t.Vellum == vGoat {
		defs.WriteString(`<pattern id="tx" width="9" height="11" patternUnits="userSpaceOnUse"><circle cx="2" cy="3" r=".7" fill="#6a4a2a" fill-opacity=".22"/>` +
			`<circle cx="7" cy="8" r=".6" fill="#6a4a2a" fill-opacity=".18"/></pattern>`)
	} else if t.Vellum == vRag {
		defs.WriteString(`<pattern id="tx" width="40" height="3" patternUnits="userSpaceOnUse"><path d="M0 1h40" stroke="#8a7650" stroke-opacity=".12" stroke-width=".6"/>` +
			`<path d="M20 0v3" stroke="#8a7650" stroke-opacity=".2"/></pattern>`)
	}
	if gilded {
		defs.WriteString(`<pattern id="dp" width="6" height="6" patternUnits="userSpaceOnUse"><path d="M3 1v4M1 3h4" stroke="#fff" stroke-opacity=".3" stroke-width=".7"/></pattern>`)
	}
	body := `<rect width="600" height="820" fill="` + dark + `"/><use href="#pg" fill="` + page + `"/>`
	if t.Vellum == vGoat || t.Vellum == vRag {
		body += `<use href="#pg" fill="url(#tx)"/>`
	}
	body += `<use href="#pg" fill="url(#ed)"/><use href="#pg" filter="url(#v)" opacity=".7"/>`

	// --- the text block ---
	var cols []column
	switch t.Layout {
	case lSingle:
		cols = []column{{78, 118, 360, 24, 115, "1.15"}}
	case lTwo:
		cols = []column{{70, 116, 190, 26, 100, ""}, {282, 116, 190, 26, 100, ""}}
	default:
		cols = []column{{182, 126, 210, 23, 120, "1.2"}}
	}

	var ruling, fill, textOut strings.Builder
	var lombards []int // x, y pairs
	para, dip, firstWord := 0, 100, -1
	sw := "1.35"
	if hand == hAngular {
		sw = "1.5"
	}
	for ci, c := range cols {
		lh := c.s / 5 // 20 px x scale
		right := c.x + c.w*c.s/100
		bottom := c.y + (c.n-1)*lh
		ruling.WriteString("M" + itoa(c.x) + " " + itoa(c.y-14) + "V" + itoa(bottom+6) + "M" + itoa(right) + " " + itoa(c.y-14) + "V" + itoa(bottom+6))
		ox := c.x * 100 / c.s
		var inkLines, redLines, puncts strings.Builder
		for L := 0; L < c.n; L++ {
			yy := c.y + L*lh
			uy := yy * 100 / c.s
			ruling.WriteString("M" + itoa(c.x) + " " + itoa(yy) + "h" + itoa(right-c.x))
			x := 0
			if ci == 0 && L*lh < 64 {
				x = 66 * 100 / c.s
			}
			start := ci == 0 && L == 0
			lineRed := false
			if start {
				para = R.rr(4, 7)
				if hasHead {
					lineRed = true
				}
			} else if para == 0 {
				para = R.rr(4, 8)
				if hasLomb {
					lombards = append(lombards, c.x+x*c.s/100, yy)
					x += 22 * 100 / c.s
				}
				if hasHead {
					lineRed = true
				}
			}
			last := para == 1
			lineW := c.w
			if last {
				lineW = c.w * R.rr(35, 80) / 100
			}
			var words, xs []int
			for miss := 0; miss < tries && lf.budget > 0; {
				wi := R.pick(wcum)
				if x+wl[wi] > lineW {
					miss++
					continue
				}
				lf.budget--
				words = append(words, wi)
				xs = append(xs, x)
				x += wl[wi] + gap
			}
			if len(words) > 0 {
				n := len(words)
				px := lf.justify(words, xs, lineW, last)
				// a punctus ends some words and every paragraph
				for i := 0; i < n; i++ {
					if (last && i == n-1) || (i < n-1 && R.n(9) == 0) {
						puncts.WriteString("M" + itoa(ox+px[i]+wl[words[i]]+3) + " " + itoa(uy) + "h.1")
					}
				}
				if firstWord < 0 {
					firstWord = words[0]
				}
				tr := `<g transform="translate(` + itoa(ox) + " " + itoa(uy) + `)"`
				switch {
				case start && !hasHead:
					// the first word is rubricated
					redLines.WriteString(tr + ">" + uses(words, px, 0, 1) + "</g>")
					if n > 1 {
						inkLines.WriteString(tr + opac(dip) + ">" + uses(words, px, 1, n) + "</g>")
					}
				case lineRed:
					redLines.WriteString(tr + ">" + uses(words, px, 0, n) + "</g>")
				default:
					inkLines.WriteString(tr + opac(dip) + ">" + uses(words, px, 0, n) + "</g>")
				}
				dip -= R.rr(1, 4)
				if dip < 70 {
					dip = 100
				}
			}
			if last && hasHead && x < lineW {
				// line filler after the paragraph's last word
				fx := c.x + (x+4)*c.s/100
				if right-fx > 12 {
					fill.WriteString("M" + itoa(fx) + " " + itoa(yy-4) + "H" + itoa(right))
				}
			}
			para--
		}
		scale := ""
		if c.ss != "" {
			scale = ` transform="scale(` + c.ss + `)"`
		}
		textOut.WriteString("<g" + scale + ` fill="none" stroke="` + ink + `" stroke-width="` + sw + `" stroke-linecap="round" stroke-linejoin="round">`)
		textOut.WriteString(inkLines.String())
		if puncts.Len() > 0 {
			textOut.WriteString(`<path d="` + puncts.String() + `" stroke-width="2.6"/>`)
		}
		textOut.WriteString("</g>")
		if redLines.Len() > 0 {
			textOut.WriteString("<g" + scale + ` fill="none" stroke="` + red + `" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">`)
			textOut.WriteString(redLines.String())
			textOut.WriteString("</g>")
		}
	}

	// --- gloss around a glossed text ---
	gloss := ""
	if t.Layout == lGlossed {
		var gl strings.Builder
		for side := 0; side < 2; side++ {
			gx, lw := 70, 150
			if side == 1 {
				gx, lw = 448, 165
			}
			gox := gx * 100 / 62
			y := 128 + R.rr(0, 40)
			for b := 0; b < 3 && y < 700; b++ {
				nl := R.rr(4, 9)
				for L := 0; L < nl && y < 716; L++ {
					var words, xs []int
					x := 0
					for miss := 0; miss < tries && lf.budget > 0; {
						wi := R.pick(wcum)
						if x+wl[wi] > lw {
							miss++
							continue
						}
						lf.budget--
						words = append(words, wi)
						xs = append(xs, x)
						x += wl[wi] + 6
					}
					if len(words) > 0 {
						gl.WriteString(`<g transform="translate(` + itoa(gox) + " " + itoa(y*100/62) + `)">` +
							uses(words, lf.justify(words, xs, lw, L == nl-1), 0, len(words)) + "</g>")
					}
					y += 12
				}
				y += R.rr(20, 70)
			}
		}
		gloss = `<g transform="scale(.62)" fill="none" stroke="` + ink + `" stroke-opacity=".85" stroke-width="1.6" stroke-linecap="round">` + gl.String() + "</g>"
	}

	// --- lombards: alternating red and blue, each with a pen flourish in the other colour ---
	var lomb, lombPen strings.Builder
	lc := R.n(2)
	for i := 0; i < len(lombards); i += 2 {
		lx, ly := lombards[i], lombards[i+1]
		g := R.n(A)
		col, pen := red, blue
		if lc != 0 {
			col, pen = blue, red
		}
		lomb.WriteString(`<path transform="translate(` + itoa(lx+2) + " " + itoa(ly+4) + `) scale(1.6)" d="` + glyphPath(glyphs[g], 0) + `" stroke="` + col + `"/>`)
		lombPen.WriteString(`<path d="M` + itoa(lx-3) + " " + itoa(ly-16) + `q-5 9 0 18t0 18" stroke="` + pen + `"/>`)
		lc = 1 - lc
	}
	lombOut := ""
	if lomb.Len() > 0 {
		lombOut = `<g fill="none" stroke-width=".8" opacity=".8">` + lombPen.String() +
			`</g><g fill="none" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round">` + lomb.String() + "</g>"
	}
	fillOut := ""
	if fill.Len() > 0 {
		fillOut = `<path d="` + fill.String() + `" stroke="` + red + `" stroke-width="2.2" stroke-linecap="round" stroke-dasharray=".1 5" opacity=".85"/>`
	}

	// --- the great initial ---
	c0 := cols[0]
	bx := c0.x - 2
	by := c0.y - 18
	const bs = 62
	if firstWord < 0 {
		firstWord = 0
	}
	ig := glyphPath(glyphs[lf.lex[firstWord][0]], 0)
	ini := ""
	if gilded {
		var dots strings.Builder
		for i := 0; i < 6; i++ {
			dots.WriteString("M" + itoa(bx+11+i*8) + " " + itoa(by+bs-9) + "h.1")
		}
		ini = `<rect x="` + itoa(bx) + `" y="` + itoa(by) + `" width="62" height="62" fill="url(#au)" stroke="` + red + `" stroke-width="2"/>` +
			`<rect x="` + itoa(bx+5) + `" y="` + itoa(by+5) + `" width="52" height="52" fill="` + blue + `"/>` +
			`<rect x="` + itoa(bx+5) + `" y="` + itoa(by+5) + `" width="52" height="52" fill="url(#dp)"/>` +
			`<path d="` + dots.String() + `" stroke="#f6e7b0" stroke-width="2.4" stroke-linecap="round"/>` +
			`<g fill="none" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path transform="translate(` + itoa(bx+17) + " " + itoa(by+49) +
			`) scale(3.2)" d="` + ig + `" stroke="#1a1430" stroke-opacity=".45"/><path transform="translate(` + itoa(bx+15) + " " + itoa(by+47) +
			`) scale(3.2)" d="` + ig + `" stroke="#f8ecc4"/></g>`
	} else {
		letter, penc := red, blue
		if deco == dLombards {
			letter, penc = blue, red
		}
		if deco == dPlain {
			ini = `<rect x="` + itoa(bx) + `" y="` + itoa(by) + `" width="62" height="62" fill="none" stroke="` + red + `" stroke-width="2"/>`
		} else {
			// pen-flourished initial: a hairline frame, a dotted halo and a tail down the margin
			ini = `<g fill="none" stroke="` + penc + `" stroke-width=".9" stroke-linecap="round"><rect x="` + itoa(bx+3) + `" y="` + itoa(by+3) + `" width="56" height="56"/>` +
				`<rect x="` + itoa(bx-2) + `" y="` + itoa(by-2) + `" width="66" height="66" stroke-width="2" stroke-dasharray=".1 5"/>` +
				`<path d="M` + itoa(bx+4) + " " + itoa(by+bs) + `q-12 20 0 40t0 40t0 40m0-120q-14 4-16 14m16 26q14 4 16 14m-16 26q-14 4-16 14"/></g>`
		}
		ini += `<path transform="translate(` + itoa(bx+15) + " " + itoa(by+47) + `) scale(3.2)" d="` + ig + `" fill="none" stroke="` + letter +
			`" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"/>`
	}

	// --- vine border (and the full frame) ---
	if deco == dVine || deco == dFull {
		// beside the text from the initial down; on a glossed leaf outside the gloss, from the top
		glossed := t.Layout == lGlossed
		vx, vy, vx0 := c0.x-30, by+bs, bx+4
		if glossed {
			vx, vy, vx0 = 44, 100, 44
		}
		var d, leafA, leafB, golds strings.Builder
		d.WriteString("M" + itoa(vx0) + " " + itoa(vy) + "Q" + itoa(vx-10) + " " + itoa(vy+20) + " " + itoa(vx) + " " + itoa(vy+50))
		y := vy + 50
		side := 1
		for y < 700 {
			ny := y + 56
			d.WriteString("T" + itoa(vx) + " " + itoa(ny))
			if side > 0 {
				leafA.WriteString(leafPath(vx, y+28, side))
			} else {
				leafB.WriteString(leafPath(vx, y+28, side))
			}
			golds.WriteString("M" + itoa(vx-side*11) + " " + itoa(y+30) + "h.1")
			side = -side
			y = ny
		}
		frame := ""
		if deco == dFull {
			cl := cols[len(cols)-1]
			tx, top := cl.x+cl.w*cl.s/100+24, bx+30
			if glossed {
				tx, top = 556, vx
			}
			d.WriteString("Q" + itoa(vx) + " 748 " + itoa(vx+60) + " 748H" + itoa(tx) + "V84H" + itoa(top))
			for x := vx + 70; x < tx; x += 48 {
				if side > 0 {
					leafB.WriteString(leafPath(x, 748, side))
				} else {
					leafA.WriteString(leafPath(x-18, 748, side))
				}
				golds.WriteString("M" + itoa(x+24) + " 748h.1")
				side = -side
			}
			frame = `<rect x="` + itoa(vx-18) + `" y="70" width="` + itoa(tx-vx+36) + `" height="696" fill="none" stroke="` + red + `" stroke-width="1.2"/>` +
				`<rect x="` + itoa(vx-22) + `" y="66" width="` + itoa(tx-vx+44) + `" height="704" fill="none" stroke="url(#au)" stroke-width="2.5"/>`
		}
		ini = frame + `<path d="` + d.String() + `" fill="none" stroke="` + green + `" stroke-width="2.2"/><path d="` + leafA.String() + `" fill="` + blue +
			`"/><path d="` + leafB.String() + `" fill="` + green + `"/><path d="` + golds.String() + `" stroke="url(#au)" stroke-width="7" stroke-linecap="round"/>` + ini
	}

	// --- ruling, prickings, running head, catchword, folio ---
	ruleColor := "#8a6a48"
	if purple {
		ruleColor = goldInk
	}
	rule := `<path d="` + ruling.String() + `" stroke="` + ruleColor + `" stroke-opacity=".16" stroke-width=".7"/>`
	var pr strings.Builder
	for y := 110; y < 720; y += 40 {
		pr.WriteString("M566 " + itoa(y) + "h.1")
	}
	pricks := `<path d="` + pr.String() + `" stroke="#5a4030" stroke-opacity=".5" stroke-width="2" stroke-linecap="round"/>`
	var hw [3]int
	hwTotal := 0
	for i := 0; i < 3; i++ {
		hw[i] = R.n(V)
		hwTotal += wl[hw[i]]
		if i > 0 {
			hwTotal += 12
		}
	}
	hx := 375 - hwTotal/2 // centred on x = 300 at scale .8
	var head strings.Builder
	head.WriteString(`<g transform="scale(.8)" fill="none" stroke="` + red + `" stroke-width="1.4" stroke-linecap="round">`)
	for i := 0; i < 3; i++ {
		head.WriteString(`<use href="#` + wid[hw[i]:hw[i]+1] + `" x="` + itoa(hx) + `" y="62"/>`)
		hx += wl[hw[i]] + 12
	}
	head.WriteString("</g>")
	cw := R.n(V)
	cl := wl[cw]
	catchword := `<g transform="translate(` + itoa(470-cl) + ` 784)" fill="none" stroke="` + ink + `" stroke-width="1.3" stroke-linecap="round"><use href="#` +
		wid[cw:cw+1] + `"/><path d="M-6 6q` + itoa(cl/2+6) + " 8 " + itoa(cl+12) + ` 0" stroke="` + red + `"/></g>`
	fallback := R.rr(1, 240)
	sideMark := "v"
	if R.n(2) == 0 {
		sideMark = "r"
	}
	fn := FolioNumber(tokenID)
	if fn == 0 {
		fn = fallback
	}
	folio := `<text x="548" y="50" font-family="Georgia, serif" font-style="italic" font-size="15" fill="` + ink + `" text-anchor="end">f. ` + RomanFolio(fn) +
		`<tspan font-size="10" dy="-6">` + sideMark + "</tspan></text>"

	// --- marginal drawing ---
	my := R.rr(260, 600)
	bxm := R.rr(200, 400)
	mg := ""
	if t.Marginalia != mNone {
		mx, yy := 522, my
		if t.Layout == lGlossed || deco == dFull { // bas-de-page, standing on y = 748
			mx = bxm
			foot := 12 // lower on a bare page
			if deco == dFull {
				foot = 0 // on the frame's lower bar
			}
			switch t.Marginalia {
			case mHand:
				yy = foot + 739
			case mSnail:
				yy = foot + 738
			case mBird:
				yy = foot + 726
			default:
				yy = foot + 708
			}
		}
		at := `<g transform="translate(` + itoa(mx) + " " + itoa(yy) + `)" stroke="` + ink + `"`
		switch t.Marginalia {
		case mHand:
			mg = at + ` stroke-width="1.3" fill="` + page + `"><rect x="18" y="-9" width="22" height="18" rx="3"/><path d="M22-9v18M27-9v18M32-9v18" fill="none" stroke-opacity=".5"/>` +
				`<path d="M18-7h-14q-4 0-4 4t4 4h6q-3 2 0 5h8z"/><path d="M-26-4h30q3 0 3 3t-3 3h-30q-3 0-3-3t3-3z"/></g>`
		case mSnail:
			shell := blue
			if R.n(2) == 0 {
				shell = red
			}
			body2 := "#c9c79a"
			if purple {
				body2 = "#6f6a4a"
			}
			mg = at + ` stroke-width="1.3"><path d="M-30 10h50q8 0 10-8l4-10M30-6l-2-12M34-6l4-10" fill="` + body2 +
				`"/><path d="M0 8a3 3 0 0 1 6 0a7 7 0 0 1-14 0a11 11 0 0 1 22 0a15 15 0 0 1-30 0" fill="` + shell + `" fill-opacity=".85"/></g>`
		case mBird:
			mg = at + ` stroke-width="1.2"><path d="M-22 4l-12 6M-22 2l-13 0" fill="none"/><ellipse rx="22" ry="12" fill="` + blue + `"/><circle cx="20" cy="-10" r="8" fill="` +
				blue + `"/><path d="M27-11l9 2-9 3z" fill="url(#au)"/><path d="M-12-4q10-14 22 0q-10-4-22 0z" fill="` + red +
				`"/><path d="M-4 12l-2 10M4 12l2 10" fill="none"/><circle cx="22" cy="-12" r="1.4" fill="` + ink + `"/></g>`
		default:
			mg = at + ` stroke-width="1.1"><path d="M0 40q-10-30 0-80" fill="none" stroke="` + green + `" stroke-width="2"/><path d="M-1 12q-14-2-18-12q12 0 18 12z" fill="` +
				green + `"/><path d="M9-40a7 7 0 1 0 0 1zM3-31a7 7 0 1 0 0 1zM-7-34a7 7 0 1 0 0 1zM-7-46a7 7 0 1 0 0 1zM3-49a7 7 0 1 0 0 1z" fill="` + red +
				`"/><circle cy="-40" r="5" fill="url(#au)"/></g>`
		}
	}

	// --- condition ---
	dm, pal := "", ""
	switch t.Condition {
	case cWorm:
		x := R.rr(120, 460)
		y := R.rr(150, 650)
		n := R.rr(5, 11)
		var holes strings.Builder
		for i := 0; i < n; i++ {
			r := R.rr(2, 5)
			holes.WriteString(`<ellipse cx="` + itoa(x) + `" cy="` + itoa(y) + `" rx="` + itoa(r) + `" ry="` + itoa(r+1) + `"/>`)
			x += R.rr(-30, 30)
			y += R.rr(10, 40)
		}
		dm = `<g fill="` + dark + `" stroke="` + edge + `" stroke-width="1.5">` + holes.String() + "</g>"
	case cStain:
		defs.WriteString(`<radialGradient id="st"><stop offset=".6" stop-color="#8a6a40" stop-opacity="0"/><stop offset=".93" stop-color="#7a5a32" stop-opacity=".18"/>` +
			`<stop offset=".98" stop-color="#5a3a1a" stop-opacity=".45"/><stop offset="1" stop-color="#5a3a1a" stop-opacity="0"/></radialGradient>`)
		cx := R.rr(100, 500)
		cy := R.rr(600, 760)
		rx := R.rr(140, 220)
		ry := R.rr(90, 150)
		rot := R.rr(-20, 20)
		dm = `<ellipse cx="` + itoa(cx) + `" cy="` + itoa(cy) + `" rx="` + itoa(rx) + `" ry="` + itoa(ry) + `" fill="url(#st)" transform="rotate(` + itoa(rot) + ` 300 700)"/>`
	case cBurnt:
		defs.WriteString(`<linearGradient id="bn" x1="1" y1="0" x2="0" y2="0"><stop offset="0" stop-color="#140c08"/><stop offset=".06" stop-color="#3a2210" stop-opacity=".9"/>` +
			`<stop offset=".16" stop-color="#7a4a20" stop-opacity=".3"/><stop offset=".3" stop-color="#7a4a20" stop-opacity="0"/></linearGradient>` +
			`<filter id="bf"><feTurbulence type="fractalNoise" baseFrequency=".04" numOctaves="3" seed="` + itoa(R.rr(1, 99)) +
			`"/><feDisplacementMap in="SourceGraphic" scale="40" xChannelSelector="R" yChannelSelector="G"/></filter>`)
		dm = `<rect x="300" width="300" height="820" fill="url(#bn)" filter="url(#bf)"/>`
	case cPalimpsest:
		// the scraped older text, written across the leaf
		var u strings.Builder
		for L := 0; L < 9; L++ {
			var words, xs []int
			x := 0
			for lf.budget > 0 {
				wi := R.n(V)
				if x+wl[wi] > 400 {
					break
				}
				lf.budget--
				words = append(words, wi)
				xs = append(xs, x)
				x += wl[wi] + 10
			}
			u.WriteString(`<g transform="translate(22 ` + itoa(L*38-404) + `)">` + uses(words, lf.justify(words, xs, 400, false), 0, len(words)) + "</g>")
		}
		pal = `<g transform="rotate(90) scale(1.4)" fill="none" stroke="#8a3a22" stroke-opacity=".16" stroke-width="2.2" stroke-linecap="round">` + u.String() + "</g>"
	}

	var out strings.Builder
	out.WriteString(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 600 820">`)
	out.WriteString(defs.String())
	out.WriteString("</defs>")
	out.WriteString(body)
	out.WriteString(`<g clip-path="url(#cp)">`)
	out.WriteString(pal)
	out.WriteString(rule)
	out.WriteString(pricks)
	out.WriteString(textOut.String())
	out.WriteString(gloss)
	out.WriteString(fillOut)
	out.WriteString(lombOut)
	out.WriteString(ini)
	out.WriteString(head.String())
	out.WriteString(catchword)
	out.WriteString(folio)
	out.WriteString(mg)
	out.WriteString(dm)
	out.WriteString("</g></svg>")
	return out.String()
}
