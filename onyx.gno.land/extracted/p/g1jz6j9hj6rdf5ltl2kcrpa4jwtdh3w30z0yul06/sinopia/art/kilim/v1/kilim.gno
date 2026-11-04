// Package kilim is a Sinopia engine: a flat-woven rug computed cell by cell
// on a warp grid. Medallions are the stepped rings of an integer distance
// field (the grid turns every diagonal into a staircase, as on a loom), the
// border is a running sawtooth, diamond or stripe band, and "abrash" bands
// shift a dye lot mid-rug like hand-dyed wool.
//
// It is a port of the kilim prototype (Python). The RNG stream, trait
// tables and draw order are the prototype's; the deliberate changes are the
// Weaver's Flaw rule (now visible in every field), the params, and a compact
// SVG encoding that renders the same pixels. Python's // and % floor towards
// minus infinity and Go's truncate, so the lattice maths goes through
// floorDiv/floorMod; kilim_test.gno pins golden vectors produced by the
// Python reference, and frontend/src/engines/kilim.ts asserts the same ones.
//
// Pure integer maths: no floats, no time, no block data.
package kilim

import (
	"errors"
	"strconv"
	"strings"

	"gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia/engine/v1"
)

// TraitTypes in the order Traits returns them.
var traitTypes = []string{"Dyes", "Field", "Motif", "Border", "Abrash", "Symmetry", "Fringe", "Rarity"}

// MaxSVGBytes: the largest output over 10,000 default seeds is 8,514 B
// (Coarse loom: 5,984 B over 2,000 seeds x field); about 2x margin.
const MaxSVGBytes = 16384

// ParamsSchema is the Studio form. Studio sends JSON.stringify of the values
// in this property order; ValidateParams accepts exactly that or "".
const ParamsSchema = `{"type":"object","properties":{` +
	`"dyes":{"type":"string","title":"Dyes","enum":["Seeded","Madder & Indigo","Saffron","Walnut & Bone",` +
	`"Pomegranate","Night Indigo","Steppe","Undyed","Sinopia Earth"],"default":"Seeded"},` +
	`"field":{"type":"string","title":"Field","enum":["Seeded","Medallion","Triple","Lattice","Banded","Ladder"],` +
	`"default":"Seeded"},` +
	`"loom":{"type":"string","title":"Loom","enum":["Fine","Coarse"],"default":"Fine"},` +
	`"abrash":{"type":"boolean","title":"Abrash dye lots","default":true}}}`

// DefaultParams is the canonical form of the defaults; it renders exactly
// like "".
const DefaultParams = `{"dyes":"Seeded","field":"Seeded","loom":"Fine","abrash":true}`

// Manifest describes the engine. Author and FeeBps are set by the adapter.
func Manifest() engine.Manifest {
	return engine.Manifest{
		Name:    "Kilim",
		Version: "1.0.0",
		Description: "A flat-woven rug computed cell by cell on the loom grid: stepped medallions from an " +
			"integer distance field, running borders and abrash dye-lot shifts.",
		License:      "TBD",
		ParamsSchema: ParamsSchema,
		TraitTypes:   append([]string{}, traitTypes...),
		Living:       false,
		MaxSVGBytes:  MaxSVGBytes,
	}
}

// Config is a parsed params string.
type Config struct {
	Dyes   int  // -1: drawn from the seed, else an index into the dye table
	Field  int  // -1: drawn from the seed, else an index into the field table
	Coarse bool // 27 x 41 cells of 26 px instead of 37 x 55 cells of 20 px
	Abrash bool // false: no dye-lot bands (Abrash "None")
}

// Defaults is the showcase look (params "").
func Defaults() Config { return Config{Dyes: -1, Field: -1, Abrash: true} }

var errParams = errors.New(`kilim: params must be "" or ` +
	`{"dyes":<enum>,"field":<enum>,"loom":"Fine"|"Coarse","abrash":true|false} in that order, without spaces`)

// ParseParams accepts "" or the canonical JSON Studio produces, nothing else.
func ParseParams(params string) (Config, error) {
	cfg := Defaults()
	if params == "" {
		return cfg, nil
	}
	v, rest, ok := strValue(params, `{"dyes":"`)
	if !ok {
		return cfg, errParams
	}
	if cfg.Dyes, ok = enumIndex(v, dyeOpts); !ok {
		return cfg, errParams
	}
	if v, rest, ok = strValue(rest, `","field":"`); !ok {
		return cfg, errParams
	}
	if cfg.Field, ok = enumIndex(v, fieldOpts); !ok {
		return cfg, errParams
	}
	if v, rest, ok = strValue(rest, `","loom":"`); !ok {
		return cfg, errParams
	}
	switch v {
	case "Fine":
	case "Coarse":
		cfg.Coarse = true
	default:
		return cfg, errParams
	}
	switch rest {
	case `","abrash":true}`:
	case `","abrash":false}`:
		cfg.Abrash = false
	default:
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
// renders: seven table draws and a score.
func Traits(in engine.Input) []engine.Trait {
	t := TraitsOf(in.Seed, mustConfig(in.Params))
	return []engine.Trait{
		{Type: "Dyes", Value: t.Dyes},
		{Type: "Field", Value: t.Field},
		{Type: "Motif", Value: t.Motif},
		{Type: "Border", Value: t.Border},
		{Type: "Abrash", Value: t.Abrash},
		{Type: "Symmetry", Value: t.Symmetry},
		{Type: "Fringe", Value: t.Fringe},
		{Type: "Rarity", Value: t.Rarity},
	}
}

// Render returns the raw SVG for in.Seed and in.Params.
func Render(in engine.Input) string { return SVG(in.Seed, mustConfig(in.Params)) }

// ---------------------------------------------------------------------------
// Deterministic randomness: FNV-1a over the seed, then splitmix64 (Genesis's
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

var dyeOpts = []option{
	{"Madder & Indigo", 22, 0}, {"Saffron", 15, 0}, {"Walnut & Bone", 15, 0}, {"Pomegranate", 14, 0},
	{"Night Indigo", 12, 1}, {"Steppe", 10, 1}, {"Undyed", 7, 2}, {"Sinopia Earth", 5, 3},
}

// palettes: 0 ground, 1..3 motif dyes, 4 dark outline, 5 light.
var palettes = [][]string{
	{"#9e2a22", "#1f2f5a", "#d9a441", "#4a7a6a", "#2a1712", "#ecdfc2"},
	{"#d6962a", "#7a1f1f", "#2c3d5c", "#4f6b3a", "#3a2416", "#f1e4c6"},
	{"#5a4030", "#a0806a", "#c49a5a", "#2b211b", "#1d1611", "#e9dfc8"},
	{"#b2343b", "#3d5a4a", "#e0a35a", "#5a2a4a", "#2e1c22", "#f0e2cc"},
	{"#1c2848", "#c23b2e", "#6b8fb0", "#d9a441", "#0b1020", "#e5d8b8"},
	{"#4f6b3a", "#d9b45a", "#8c2f23", "#2c3d5c", "#1f2618", "#efe6cf"},
	{"#e2d8c3", "#8a7c66", "#b8ab94", "#5e5346", "#3a332b", "#f3ede0"},
	{"#8f3a26", "#c5643f", "#e8c49a", "#5e2a1a", "#3a150e", "#f4e6cf"},
}

const (
	fieldMedallion = iota
	fieldTriple
	fieldLattice
	fieldBanded
	fieldLadder
)

var fieldOpts = []option{{"Medallion", 22, 0}, {"Triple", 22, 0}, {"Lattice", 26, 0}, {"Banded", 18, 0}, {"Ladder", 12, 1}}

const (
	motifDiamond = iota
	motifHooked
	motifStar
	motifComb
	motifEye
)

var motifOpts = []option{{"Diamond", 26, 0}, {"Hooked", 24, 0}, {"Star", 20, 0}, {"Comb", 18, 0}, {"Eye", 12, 1}}

const (
	borderSawtooth = iota
	borderDiamonds
	borderStripes
	borderDouble
	borderOpen
)

var borderOpts = []option{
	{"Sawtooth", 32, 0}, {"Running Diamonds", 26, 0}, {"Stripes", 24, 0}, {"Double", 12, 1}, {"Open Field", 6, 3},
}

const (
	abrashNone = iota
	abrashFaint
	abrashStrong
)

var abrashOpts = []option{{"None", 40, 0}, {"Faint", 40, 0}, {"Strong", 20, 1}}

var symmetryOpts = []option{{"Mirrored", 82, 0}, {"Weaver's Flaw", 18, 2}}

const (
	fringeLoose = iota
	fringeKnotted
	fringeBound
)

var fringeOpts = []option{{"Loose", 50, 0}, {"Knotted", 38, 0}, {"Bound", 12, 1}}

// Rarity tiers by score (sum of the drawn traits' scores; a trait fixed by
// params scores 0). Over 10,000 sample seeds with default params:
// Common 23.8% / Uncommon 47.9% / Rare 23.0% / Legendary 4.7% / Mythic 0.6%.
const (
	scoreMythic    = 7
	scoreLegendary = 5
	scoreRare      = 3
	scoreUncommon  = 1
)

type draw struct {
	dyes, field, motif, border, abrash, flaw, fringe int
	score                                            int
	rarity                                           string
}

func derive(seed string, cfg Config) draw {
	r := newRNG(seed + "|traits")
	// Draw order is part of the contract: changing it changes every token.
	var d draw
	d.dyes = pick(r, dyeOpts)
	d.field = pick(r, fieldOpts)
	d.motif = pick(r, motifOpts)
	d.border = pick(r, borderOpts)
	d.abrash = pick(r, abrashOpts)
	d.flaw = pick(r, symmetryOpts)
	d.fringe = pick(r, fringeOpts)
	// Params override after the draws, so the stream never shifts.
	score := motifOpts[d.motif].score + borderOpts[d.border].score +
		symmetryOpts[d.flaw].score + fringeOpts[d.fringe].score
	if cfg.Dyes >= 0 {
		d.dyes = cfg.Dyes
	} else {
		score += dyeOpts[d.dyes].score
	}
	if cfg.Field >= 0 {
		d.field = cfg.Field
	} else {
		score += fieldOpts[d.field].score
	}
	if !cfg.Abrash {
		d.abrash = abrashNone
	} else {
		score += abrashOpts[d.abrash].score
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
	Dyes, Field, Motif, Border, Abrash, Symmetry, Fringe string
	Score                                                int
	Rarity                                               string
}

// TraitsOf returns the decoded traits for a seed.
func TraitsOf(seed string, cfg Config) TraitSet {
	d := derive(seed, cfg)
	return TraitSet{
		Dyes:     dyeOpts[d.dyes].name,
		Field:    fieldOpts[d.field].name,
		Motif:    motifOpts[d.motif].name,
		Border:   borderOpts[d.border].name,
		Abrash:   abrashOpts[d.abrash].name,
		Symmetry: symmetryOpts[d.flaw].name,
		Fringe:   fringeOpts[d.fringe].name,
		Score:    d.score,
		Rarity:   d.rarity,
	}
}

// ---------------------------------------------------------------------------
// Integer helpers. Python semantics where the prototype relied on them.
// ---------------------------------------------------------------------------

func abs(a int) int {
	if a < 0 {
		return -a
	}
	return a
}

// floorDiv and floorMod are Python's // and % (b > 0).
func floorDiv(a, b int) int {
	q := a / b
	if a%b != 0 && a < 0 {
		q--
	}
	return q
}

func floorMod(a, b int) int {
	m := a % b
	if m < 0 {
		m += b
	}
	return m
}

// dist is the medallion's integer distance field (arguments >= 0 after abs,
// so / is exact floor division here).
func dist(motif, du, dv int) int {
	au, av := abs(du), abs(dv)
	switch motif {
	case motifStar:
		m := au
		if av > m {
			m = av
		}
		m = m * 3 / 2
		if au+av < m {
			return au + av
		}
		return m
	case motifEye:
		return au*3/2 + av
	}
	return au + av
}

// medallion returns the palette index of a ring cell, or -1 outside.
func medallion(motif, ringw, du, dv, size int, s []int) int {
	d := dist(motif, du, dv)
	if d > size {
		return -1
	}
	if d == size {
		return 4
	}
	k := (size - d) / ringw
	if motif == motifHooked && d >= size-2 && abs(du)%3 == 0 {
		return 0
	}
	if motif == motifComb && d >= size-3 && abs(dv)%2 == 0 && abs(du) > 1 {
		return 0
	}
	return s[k%len(s)]
}

// flawed is a Weaver's Flaw sequence: every dye moved one place along 1..5.
func flawed(s []int) []int {
	out := make([]int, len(s))
	for i, c := range s {
		out[i] = c%5 + 1
	}
	return out
}

func shade(col string, d int) string {
	const hexd = "0123456789abcdef"
	out := []byte{'#', 0, 0, 0, 0, 0, 0}
	for i := 1; i < 7; i += 2 {
		v := unhex(col[i])*16 + unhex(col[i+1]) + d
		if v < 0 {
			v = 0
		}
		if v > 255 {
			v = 255
		}
		out[i], out[i+1] = hexd[v>>4], hexd[v&15]
	}
	return string(out)
}

func unhex(c byte) int {
	if c >= 'a' {
		return int(c-'a') + 10
	}
	return int(c - '0')
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

const (
	ox = 30 // rug offset in px
	oy = 80
)

// SVG renders the artwork for a seed under cfg.
func SVG(seed string, cfg Config) string {
	t := derive(seed, cfg)
	C, R, cell := 37, 55, 20
	if cfg.Coarse {
		C, R, cell = 27, 41, 26
	}
	W, H := C*cell+2*ox, R*cell+2*oy
	r := newRNG(seed + "|art") // separate stream: trait draws never shift the art
	pal := palettes[t.dyes]

	bw := 0
	if t.border == borderDouble {
		bw = 6
	} else if t.border != borderOpen {
		bw = r.between(4, 5)
	}
	fw, fh := C-2*bw, R-2*bw
	seq := make([]int, r.between(3, 5))
	for i := range seq {
		seq[i] = r.between(1, 5)
	}
	seq2 := make([]int, len(seq))
	for i := range seq2 {
		seq2[i] = r.between(1, 5)
	}
	ringw := r.between(1, 2)
	grid := make([]int, R*C)

	var cu, cv, cs []int // medallion centres and sizes
	switch t.field {
	case fieldMedallion:
		sz := fw/2 - 1
		if fh/2-1 < sz {
			sz = fh/2 - 1
		}
		cu, cv, cs = []int{fw / 2}, []int{fh / 2}, []int{sz}
	case fieldTriple:
		sz := fw/2 - 1
		if fh/6 < sz {
			sz = fh / 6
		}
		for k := 1; k <= 5; k += 2 {
			cu, cv, cs = append(cu, fw/2), append(cv, fh*k/6), append(cs, sz)
		}
	case fieldLadder:
		sz := r.between(4, 6)
		step := 2*sz + 2
		n := fh / step
		off := (fh-n*step)/2 + sz + 1
		for k := 0; k < n; k++ {
			cu, cv, cs = append(cu, fw/2), append(cv, off+k*step), append(cs, sz)
		}
	}
	flaw := -1
	if t.flaw == 1 {
		if t.field == fieldLattice || t.field == fieldBanded {
			flaw = r.intn(3)
		} else {
			n := len(cu)
			if n < 1 {
				n = 1
			}
			flaw = r.intn(n)
		}
	}
	lat := r.between(5, 7)
	filler := r.between(5, 7)
	band := r.between(7, 10)
	nbands := (fh + band - 1) / band
	seqF, seq2F := flawed(seq), flawed(seq2)
	motif := t.motif

	for v := 0; v < fh; v++ {
		row := (v + bw) * C
		for u := 0; u < fw; u++ {
			c := 0
			switch t.field {
			case fieldMedallion, fieldTriple, fieldLadder:
				for i := 0; i < len(cu); i++ {
					odd := i == flaw
					if t.field == fieldMedallion {
						odd = flaw >= 0 && u > cu[i] && v < cv[i]
					}
					s := seq
					if odd {
						s = seq2
					}
					if m := medallion(motif, ringw, u-cu[i], v-cv[i], cs[i], s); m >= 0 {
						c = m
						break
					}
				}
				if c == 0 && t.field != fieldLadder {
					fu, fv := u%filler-filler/2, v%filler-filler/2
					if abs(fu)+abs(fv) <= 1 {
						near := false
						for i := 0; i < len(cu); i++ {
							if dist(motif, u-cu[i], v-cv[i])-cs[i] <= 2 {
								near = true
								break
							}
						}
						if !near {
							c = seq[len(seq)-1]
						}
					}
				}
				if t.field == fieldLadder && c == 0 && (u < 3 || u >= fw-3) && u%2 == 0 {
					c = seq[(v/2)%len(seq)]
				}
			case fieldLattice:
				p := 2 * lat
				x, y := u-fw/2, v-fh/2
				du, dv := floorMod(x, p)-lat, floorMod(y, p)-lat
				odd := floorMod(floorDiv(x+lat, p)+floorDiv(y+lat, p), 2) != 0
				isFlaw := flaw >= 0 && floorDiv(x, p) == 0 && floorDiv(y, p) == flaw-1
				s := seq
				if odd {
					s = seq2
				}
				if isFlaw {
					s = seqF
					if odd {
						s = seq2F
					}
				}
				if m := medallion(motif, ringw, du, dv, lat-1, s); m >= 0 {
					c = m
				} else if floorMod(du+dv, 2) == 0 && abs(du) == abs(dv) {
					c = 4
				}
			default: // fieldBanded
				bi := v / band
				dv := v%band - band/2
				if dv == -(band / 2) {
					c = 4
				} else {
					per := band - 1
					du := (u+(bi%2)*(per/2))%per - per/2
					s := seq
					if bi%2 != 0 {
						s = seq2
					}
					if flaw >= 0 && bi == nbands/2-1+flaw {
						s = seqF
						if bi%2 != 0 {
							s = seq2F
						}
					}
					if m := medallion(motif, ringw, du, dv, band/2-1, s); m >= 0 {
						c = m
					} else if bi%3 == 2 {
						c = 5
					}
				}
			}
			grid[row+u+bw] = c
		}
	}

	if bw > 0 {
		bc0 := r.between(1, 3)
		bc2 := r.between(1, 3)
		bc := []int{bc0, 5, bc2}
		for v := 0; v < R; v++ {
			for u := 0; u < C; u++ {
				s := u
				if v < s {
					s = v
				}
				if C-1-u < s {
					s = C - 1 - u
				}
				if R-1-v < s {
					s = R - 1 - v
				}
				if s >= bw {
					continue
				}
				along := v
				if s == v || s == R-1-v {
					along = u
				}
				c := 0
				switch {
				case s == 0 || s == bw-1:
					c = 4
				case t.border == borderStripes:
					c = bc[s%3]
				case t.border == borderSawtooth || (t.border == borderDouble && s >= 3):
					span, ss := bw-2, s-1
					if t.border == borderDouble {
						span, ss = 2, s-3
					}
					c = 5
					if ss < abs(along%(2*span)-span) {
						c = bc[0]
					}
				case t.border == borderDiamonds:
					p := 2 * (bw - 2)
					e := 0
					if bw%2 == 0 {
						e = 1
					}
					c = 5
					if abs(along%p-p/2)+abs(s-(bw-1)/2-e) <= (bw-2)/2 {
						c = bc[2]
					}
				default: // Double, inner stripes
					c = bc[s%2]
				}
				grid[v*C+u] = c
			}
		}
	}

	// abrash: dye lots change in horizontal bands. Both counts are always
	// drawn (the prototype evaluated a dict literal).
	nFaint := r.between(1, 2)
	nStrong := r.between(2, 3)
	nab, amt := 0, 30
	if t.abrash == abrashFaint {
		nab, amt = nFaint, 14
	} else if t.abrash == abrashStrong {
		nab = nStrong
	}
	var la, lb, lc, ld []int
	for k := 0; k < nab; k++ {
		y0 := r.between(bw, R-bw-4)
		la = append(la, y0)
		lb = append(lb, y0+r.between(2, 8))
		lc = append(lc, r.between(0, 3))
		if r.intn(2) != 0 {
			ld = append(ld, amt)
		} else {
			ld = append(ld, -amt)
		}
	}

	// run-length rows; colours keyed by their final hex string, first-seen order
	var cols []string
	var counts []int
	var ru, rv, rn, rc []int
	for v := 0; v < R; v++ {
		u := 0
		for u < C {
			c := grid[v*C+u]
			col := pal[c]
			for k := 0; k < len(la); k++ {
				if la[k] <= v && v < lb[k] && lc[k] == c {
					col = shade(col, ld[k])
				}
			}
			e := u + 1
			for e < C && grid[v*C+e] == c {
				e++
			}
			ci := -1
			for k := 0; k < len(cols); k++ {
				if cols[k] == col {
					ci = k
					break
				}
			}
			if ci < 0 {
				ci = len(cols)
				cols = append(cols, col)
				counts = append(counts, 0)
			}
			counts[ci]++
			ru, rv, rn, rc = append(ru, u), append(rv, v), append(rn, e-u), append(rc, ci)
			u = e
		}
	}
	bg := 0
	for k := 1; k < len(counts); k++ {
		if counts[k] > counts[bg] {
			bg = k
		}
	}

	var b strings.Builder
	sW, sH, sC, sR, sOX, sOY := strconv.Itoa(W), strconv.Itoa(H), strconv.Itoa(C), strconv.Itoa(R), strconv.Itoa(ox), strconv.Itoa(oy)
	b.WriteString(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 `)
	b.WriteString(sW + " " + sH + `" width="` + sW + `" height="` + sH + `">`)
	b.WriteString(`<defs><pattern id="w" width="4" height="2" patternUnits="userSpaceOnUse">` +
		`<path d="M0 1.6L4 .4" stroke="#000" stroke-width=".7" opacity=".22"/></pattern>` +
		`<pattern id="k" width="1" height="1" patternUnits="userSpaceOnUse">` +
		`<path d="M0 0h1" stroke="#fff" stroke-width=".12" opacity=".2"/></pattern><path id="f" d="`)
	// fringe (warp ends), drawn after the lots: the stream order is the prototype's
	loose := t.fringe == fringeLoose
	top, bottom := strconv.Itoa(oy), strconv.Itoa(oy+R*cell)
	for u := 0; u < C; u++ {
		x := strconv.Itoa(ox + u*cell + cell/2)
		for side := 0; side < 2; side++ {
			ln, sway := 50, 0
			if loose {
				ln = r.between(46, 62)
				sway = r.between(-6, 6)
			}
			b.WriteString("M" + x + " ")
			if side == 0 {
				b.WriteString(top + "l" + strconv.Itoa(sway) + " " + strconv.Itoa(-ln))
			} else {
				b.WriteString(bottom + "l" + strconv.Itoa(sway) + " " + strconv.Itoa(ln))
			}
		}
	}
	b.WriteString(`"/></defs><rect width="` + sW + `" height="` + sH + `" fill="#e9e4da"/>`)
	b.WriteString(`<use href="#f" stroke="#e7dcc4" stroke-width="5" stroke-linecap="round"/>` +
		`<use href="#f" stroke="#b9ab8e" stroke-width="1.2" opacity=".6"/>`)
	switch t.fringe {
	case fringeKnotted:
		b.WriteString(`<g fill="#d8cbb0">`)
		kw := strconv.Itoa(4*cell - 16)
		y1, y2 := strconv.Itoa(oy-22), strconv.Itoa(oy+R*cell+12)
		for u := 1; u < C-3; u += 4 {
			x := strconv.Itoa(ox + u*cell - 2)
			b.WriteString(`<rect x="` + x + `" y="` + y1 + `" width="` + kw + `" height="10" rx="5"/>`)
			b.WriteString(`<rect x="` + x + `" y="` + y2 + `" width="` + kw + `" height="10" rx="5"/>`)
		}
		b.WriteString(`</g>`)
	case fringeBound:
		rw := strconv.Itoa(C * cell)
		b.WriteString(`<path d="M` + sOX + " " + strconv.Itoa(oy-6) + "h" + rw + "M" + sOX + " " +
			strconv.Itoa(oy+R*cell+6) + "h" + rw + `" stroke="` + pal[4] + `" stroke-width="12"/>`)
	}
	b.WriteString(`<g transform="translate(` + sOX + " " + sOY + ") scale(" + strconv.Itoa(cell) +
		`)" shape-rendering="crispEdges"><rect width="` + sC + `" height="` + sR + `" fill="` + cols[bg] +
		`"/><g transform="translate(0 .5)">`)
	// every run except the background colour's is a one-cell-wide stroke on
	// its row's centre line; same-row runs continue with a relative move
	for k := 0; k < len(cols); k++ {
		if k == bg {
			continue
		}
		b.WriteString(`<path d="`)
		lastV, lastE := -1, 0
		for i := 0; i < len(rc); i++ {
			if rc[i] != k {
				continue
			}
			if rv[i] == lastV {
				b.WriteString("m" + strconv.Itoa(ru[i]-lastE) + " 0h" + strconv.Itoa(rn[i]))
			} else {
				b.WriteString("M" + strconv.Itoa(ru[i]) + " " + strconv.Itoa(rv[i]) + "h" + strconv.Itoa(rn[i]))
			}
			lastV, lastE = rv[i], ru[i]+rn[i]
		}
		b.WriteString(`" stroke="` + cols[k] + `"/>`)
	}
	b.WriteString(`</g><rect width="` + sC + `" height="` + sR + `" fill="url(#k)"/></g>`)
	b.WriteString(`<rect x="` + sOX + `" y="` + sOY + `" width="` + strconv.Itoa(C*cell) + `" height="` +
		strconv.Itoa(R*cell) + `" fill="url(#w)"/></svg>`)
	return b.String()
}
