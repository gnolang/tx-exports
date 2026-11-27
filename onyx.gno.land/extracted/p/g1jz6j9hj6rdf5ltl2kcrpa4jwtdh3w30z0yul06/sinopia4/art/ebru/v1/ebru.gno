// Package ebru is a Sinopia engine: Turkish paper marbling, computed. Paint
// drops are laid on a bath and every drop pushes the boundaries already
// floating outwards while keeping their area
// (P' = C + (P - C) * sqrt(1 + r^2 / |P - C|^2)); styluses and combs then drag
// the paint. The pattern types are the real ebru styles (Battal, Gelgit,
// Taraklı, Şal, Hatip, Bülbül Yuvası, Çiçekli), drawn originally.
//
// It is a port of the Ebru prototype in the engine gallery (JavaScript),
// redesigned for the on-chain gas budget: a drop's stretch comes from a
// 1,024-entry table instead of two square roots per point, combs are one
// pass over a precomputed displacement table, points beyond the margin are
// pruned in runs and a point budget bounds the work and the output.
// frontend/src/engines/ebru.ts is a byte-identical TypeScript twin;
// ebru_test.gno and ebru.test.ts pin the same golden vectors.
//
// Pure integer maths: no floats, no time, no block data.
package ebru

import (
	"errors"
	"strconv"
	"strings"

	"gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia4/engine/v2"
)

// TraitTypes in the order Traits returns them.
var traitTypes = []string{"Pattern", "Palette", "Ground", "Stones", "Flow", "Finish", "Frame", "Rarity"}

// MaxSVGBytes bounds the output (the point budget keeps it far below).
const MaxSVGBytes = 28672

// ParamsSchema is the Studio form. Studio sends JSON.stringify of the values
// in this property order; ValidateParams accepts exactly that or "".
const ParamsSchema = `{"type":"object","properties":{` +
	`"pattern":{"type":"string","title":"Pattern","enum":["Seeded","Battal","Gelgit","Taraklı","Şal","Hatip",` +
	`"Bülbül Yuvası","Çiçekli"],"default":"Seeded"},` +
	`"palette":{"type":"string","title":"Palette","enum":["Seeded","Lahore & Ochre","Spring","Night","Earth","Sea",` +
	`"Soot & Gold","Sinopia"],"default":"Seeded"}}}`

// DefaultParams is the canonical form of the defaults; it renders exactly
// like "".
const DefaultParams = `{"pattern":"Seeded","palette":"Seeded"}`

// Manifest describes the engine. Author and FeeBps are set by the adapter.
func Manifest() engine.Manifest {
	return engine.Manifest{
		Name:    "Ebru",
		Version: "1.0.0",
		Description: "Turkish paper marbling computed on chain: every drop of paint pushes the paint already " +
			"floating, then the stylus and the comb drag it. Battal, Gelgit, Taraklı, Şal, Hatip, Bülbül Yuvası, Çiçekli.",
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
	Pattern int // -1: drawn from the seed, else an index into the patterns
	Palette int // -1: drawn from the seed, else an index into the palettes
}

// Defaults is the showcase look (params "").
func Defaults() Config { return Config{Pattern: -1, Palette: -1} }

var errParams = errors.New(`ebru: params must be "" or {"pattern":<enum>,"palette":<enum>} without spaces`)

func enumIndex(table []option, v string) int {
	if v == "Seeded" {
		return -1
	}
	for i, o := range table {
		if o.name == v {
			return i
		}
	}
	return -2
}

// ParseParams accepts "" or the canonical JSON Studio produces, nothing else.
func ParseParams(params string) (Config, error) {
	cfg := Defaults()
	if params == "" {
		return cfg, nil
	}
	const pre, mid, post = `{"pattern":"`, `","palette":"`, `"}`
	if !strings.HasPrefix(params, pre) || !strings.HasSuffix(params, post) || len(params) < len(pre)+len(mid)+len(post) {
		return cfg, errParams
	}
	body := params[len(pre) : len(params)-len(post)]
	i := strings.Index(body, mid)
	if i < 0 {
		return cfg, errParams
	}
	a, b := body[:i], body[i+len(mid):]
	if strings.IndexByte(a, '"') >= 0 || strings.IndexByte(b, '"') >= 0 {
		return cfg, errParams
	}
	cfg.Pattern, cfg.Palette = enumIndex(patternOpts, a), enumIndex(paletteOpts, b)
	if cfg.Pattern < -1 || cfg.Palette < -1 {
		return Defaults(), errParams
	}
	return cfg, nil
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
// renders: seven table draws.
func Traits(in engine.Input) []engine.Trait {
	t := TraitsOf(in.Seed, mustConfig(in.Params))
	return []engine.Trait{
		{Type: "Pattern", Value: t.Pattern},
		{Type: "Palette", Value: t.Palette},
		{Type: "Ground", Value: t.Ground},
		{Type: "Stones", Value: t.Stones},
		{Type: "Flow", Value: t.Flow},
		{Type: "Finish", Value: t.Finish},
		{Type: "Frame", Value: t.Frame},
		{Type: "Rarity", Value: t.Rarity},
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

func (r *rng) intn(n int) int {
	if n <= 0 {
		return 0
	}
	r.state += 0x9E3779B97F4A7C15
	z := r.state
	z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9
	z = (z ^ (z >> 27)) * 0x94D049BB133111EB
	return int((z ^ (z >> 31)) % uint64(n))
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

var patternOpts = []option{
	{"Battal", 24}, {"Gelgit", 18}, {"Taraklı", 15}, {"Şal", 13}, {"Hatip", 12}, {"Bülbül Yuvası", 10}, {"Çiçekli", 8},
}

const (
	pBattal = iota
	pGelgit
	pTarakli
	pSal
	pHatip
	pBulbul
	pCicekli
)

// palette: five paints in throwing order and the leaf paint for Çiçekli.
type palette struct {
	name   string
	weight int
	paints []string
	leaf   int
}

var palettes = []palette{
	{"Lahore & Ochre", 20, []string{"#2f4f8f", "#a63a2a", "#d9a63a", "#f2ece0", "#4f7a4a"}, 4},
	{"Spring", 16, []string{"#d98a9a", "#4f7a4a", "#e8c25a", "#f4efe4", "#8a6aa8"}, 1},
	{"Night", 14, []string{"#1f2d55", "#c9a24a", "#7a2a3a", "#e8e2d4", "#3f6a7a"}, 4},
	{"Earth", 14, []string{"#8a5a3a", "#c98a4a", "#3a4a3a", "#e9dcc4", "#a63a2a"}, 2},
	{"Sea", 13, []string{"#2a6a8a", "#7ab0c0", "#e0d2a8", "#1f3a4a", "#c96a4a"}, 3},
	{"Soot & Gold", 8, []string{"#2a2624", "#b8902f", "#f0e8d8", "#8a3a2a", "#5a5a5a"}, 4},
	{"Sinopia", 5, []string{"#b5432c", "#2e4a3a", "#e3b35a", "#efe4cc", "#6a3a5a"}, 1},
}

var paletteOpts = func() []option {
	o := make([]option, len(palettes))
	for i, p := range palettes {
		o[i] = option{p.name, p.weight}
	}
	return o
}()

const (
	palSoot    = 5
	palSinopia = 6
)

var groundOpts = []option{{"Cream", 40}, {"Celadon", 18}, {"Rose", 16}, {"Mustard", 14}, {"Indigo", 12}}
var groundColors = []string{"#efe6d2", "#cfe0d6", "#f0d8d4", "#d9b45a", "#22305a"}

const gIndigo = 4

var stoneOpts = []option{{"Large", 30}, {"Medium", 45}, {"Small", 25}}
var flowOpts = []option{{"Vertical", 60}, {"Horizontal", 40}}
var finishOpts = []option{{"Clean", 72}, {"Zerefşan", 14}, {"Neftli", 14}}

const (
	fZerefsan = 1
	fNeftli   = 2
)

var frameOpts = []option{{"Full Sheet", 72}, {"Cetvel", 18}, {"Kenar", 10}}

const (
	frCetvel = 1
	frKenar  = 2
)

var tiers = []string{"Common", "Uncommon", "Rare", "Legendary", "Mythic"}

type draw struct {
	pattern, palette, ground, stones, flow, finish, frame int
}

func derive(seed string, cfg Config) draw {
	r := newRNG(seed + "|traits")
	// Draw order is part of the contract: changing it changes every token.
	var d draw
	d.pattern = pick(r, patternOpts)
	d.palette = pick(r, paletteOpts)
	d.ground = pick(r, groundOpts)
	d.stones = pick(r, stoneOpts)
	d.flow = pick(r, flowOpts)
	d.finish = pick(r, finishOpts)
	d.frame = pick(r, frameOpts)
	// Params override after the draws, so the stream never shifts.
	if cfg.Pattern >= 0 {
		d.pattern = cfg.Pattern
	}
	if cfg.Palette >= 0 {
		d.palette = cfg.Palette
	}
	return d
}

// combed: patterns with a comb or stylus pass along the flow axis.
func combed(p int) bool { return p == pGelgit || p == pTarakli || p == pSal || p == pBulbul }

func rarity(d draw) int {
	s := 0
	switch d.pattern {
	case pBulbul, pCicekli:
		s += 3
	case pHatip:
		s += 2
	case pSal:
		s++
	}
	if d.palette == palSinopia {
		s += 3
	} else if d.palette == palSoot {
		s += 2
	}
	if d.ground == gIndigo {
		s++
	}
	if d.finish != 0 {
		s++
	}
	if d.frame == frKenar {
		s += 3
	} else if d.frame == frCetvel {
		s++
	}
	switch {
	case s >= 8:
		return 4
	case s >= 6:
		return 3
	case s >= 4:
		return 2
	case s >= 2:
		return 1
	}
	return 0
}

// TraitSet is one token's traits by name.
type TraitSet struct {
	Pattern, Palette, Ground, Stones, Flow, Finish, Frame, Rarity string
}

// TraitsOf returns the traits for seed under cfg.
func TraitsOf(seed string, cfg Config) TraitSet {
	d := derive(seed, cfg)
	flow := "Still"
	if combed(d.pattern) {
		flow = flowOpts[d.flow].name
	}
	return TraitSet{
		Pattern: patternOpts[d.pattern].name,
		Palette: paletteOpts[d.palette].name,
		Ground:  groundOpts[d.ground].name,
		Stones:  stoneOpts[d.stones].name,
		Flow:    flow,
		Finish:  finishOpts[d.finish].name,
		Frame:   frameOpts[d.frame].name,
		Rarity:  tiers[rarity(d)],
	}
}

// ---------------------------------------------------------------------------
// Integer helpers (Go's truncating / everywhere; the TS twin uses Math.trunc).
// ---------------------------------------------------------------------------

// isqrt is floor(sqrt(n)) for 0 <= n < 2^46, bit by bit.
func isqrt(n int) int {
	if n <= 0 {
		return 0
	}
	res, bit := 0, 1<<44
	for bit > n {
		bit >>= 2
	}
	for bit != 0 {
		if n >= res+bit {
			n -= res + bit
			res = res>>1 + bit
		} else {
			res >>= 1
		}
		bit >>= 2
	}
	return res
}

// sinT is a 256-step sine table, Q10, from the quarter wave every Sinopia
// engine uses.
var sinT = func() []int {
	q := []int{
		0, 25, 50, 75, 100, 125, 150, 175, 200, 224, 249, 273, 297, 321, 345, 369, 392, 415, 438, 460, 483, 505, 526, 548,
		569, 590, 610, 630, 650, 669, 688, 706, 724, 742, 759, 775, 792, 807, 822, 837, 851, 865, 878, 891, 903, 915, 926,
		936, 946, 955, 964, 972, 980, 987, 993, 999, 1004, 1009, 1013, 1016, 1019, 1021, 1023, 1024, 1024,
	}
	t := make([]int, 256)
	for i := 0; i < 256; i++ {
		j := i & 127
		v := 0
		if j <= 64 {
			v = q[j]
		} else {
			v = q[128-j]
		}
		if i >= 128 {
			v = -v
		}
		t[i] = v
	}
	return t
}()

// flut is the drop factor table, Q12: flut[t] = sqrt(1024 / (t + 1/2)) for
// the bucket t = floor(1024 * d^2 / (d^2 + r^2)), i.e. the stretch
// sqrt(1 + r^2/d^2) at the bucket's middle. Below bucket 32 (points near the
// drop's centre) the drop uses exact square roots.
var flut = func() []int {
	t := make([]int, 1024)
	for i := 0; i < 1024; i++ {
		t[i] = isqrt((1 << 35) / (2*i + 1))
	}
	return t
}()

// ---------------------------------------------------------------------------
// The bath
// ---------------------------------------------------------------------------

const (
	q8  = 8   // sub-pixel scale of the simulation (coordinates are px * q8)
	sw  = 600 // sheet width, px
	sh  = 800 // sheet height, px
	mg  = 160 // points this far outside the sheet (px) are pruned in runs
	maxPoints = 2800 // point budget (also bounds the SVG size)
)

type bath struct {
	xs, ys         [][]int
	cols           []string
	x0, x1, y0, y1 []int // per-polygon boxes: a superset after drops, exact after bounds
	fresh          bool
	total, limit   int
}

// bounds recomputes every bounding box (after a pass that moved points
// without tracking them).
func (b *bath) bounds() {
	n := len(b.xs)
	b.x0, b.x1, b.y0, b.y1 = make([]int, n), make([]int, n), make([]int, n), make([]int, n)
	for p, xs := range b.xs {
		ys := b.ys[p]
		x0, x1, y0, y1 := xs[0], xs[0], ys[0], ys[0]
		for i, x := range xs {
			if x < x0 {
				x0 = x
			} else if x > x1 {
				x1 = x
			}
			if y := ys[i]; y < y0 {
				y0 = y
			} else if y > y1 {
				y1 = y
			}
		}
		b.x0[p], b.x1[p], b.y0[p], b.y1[p] = x0, x1, y0, y1
	}
	b.fresh = true
}

// drop lays a drop of radius rp px at (cxp, cyp). It pushes every boundary
// within 3r out (the area-preserving stretch up to 1.5r, tapered to nothing
// at 3r so far paint stays in place), refines the edges within 1.5r inside the
// point budget, then floats a circle of n points.
func (b *bath) drop(cxp, cyp, rp int, col string, n, rot int) {
	if !b.fresh {
		b.bounds()
	}
	cx, cy, r := cxp*q8, cyp*q8, rp*q8
	r2 := r * r
	far, far2, near2 := 3*r, 9*r2, 9*r2/4
	taper := far2 - near2
	lim := 6 * q8
	if r/2 > lim {
		lim = r / 2
	}
	total, limit := b.total, b.limit
	for p, xs := range b.xs {
		x0, x1, y0, y1 := b.x0[p], b.x1[p], b.y0[p], b.y1[p]
		if x1 < cx-far || x0 > cx+far || y1 < cy-far || y0 > cy+far {
			continue
		}
		ys := b.ys[p]
		ln := len(xs)
		fx, fy := xs[0], ys[0]
		var mids []int
		for i, x := range xs {
			dx, dy := x-cx, ys[i]-cy
			d2 := dx*dx + dy*dy
			if d2 >= far2 || d2 == 0 {
				continue
			}
			t := d2 * 1024 / (d2 + r2)
			if t < 709 && total < limit {
				y := cy + dy
				ex, ey := fx-x, fy-y
				if i+1 < ln {
					ex, ey = xs[i+1]-x, ys[i+1]-y
				}
				if absi(ex)+absi(ey) > lim {
					mx, my := pushed(x+ex/2, y+ey/2, cx, cy, r2)
					mids = append(mids, i, mx, my)
					if mx < x0 {
						x0 = mx
					} else if mx > x1 {
						x1 = mx
					}
					if my < y0 {
						y0 = my
					} else if my > y1 {
						y1 = my
					}
					total++
				}
			}
			var y int
			if t < 32 {
				s, q := isqrt(d2+r2), isqrt(d2)
				x, y = cx+dx*s/q, cy+dy*s/q
			} else {
				f := flut[t] - 4096
				if d2 > near2 {
					f = f * (far2 - d2) / taper
				}
				x, y = x+dx*f/4096, cy+dy+dy*f/4096
			}
			xs[i], ys[i] = x, y
			if x < x0 {
				x0 = x
			} else if x > x1 {
				x1 = x
			}
			if y < y0 {
				y0 = y
			} else if y > y1 {
				y1 = y
			}
		}
		if len(mids) > 0 {
			nx := make([]int, 0, ln+len(mids)/3)
			ny := make([]int, 0, ln+len(mids)/3)
			k := 0
			for i, x := range xs {
				nx = append(nx, x)
				ny = append(ny, ys[i])
				if k < len(mids) && mids[k] == i {
					nx = append(nx, mids[k+1])
					ny = append(ny, mids[k+2])
					k += 3
				}
			}
			b.xs[p], b.ys[p] = nx, ny
		}
		b.x0[p], b.x1[p], b.y0[p], b.y1[p] = x0, x1, y0, y1
	}
	xs, ys := make([]int, n), make([]int, n)
	for k := 0; k < n; k++ {
		a := (rot + k*256/n) & 255
		xs[k] = cx + r*sinT[(a+64)&255]/1024
		ys[k] = cy + r*sinT[a]/1024
	}
	b.xs = append(b.xs, xs)
	b.ys = append(b.ys, ys)
	b.cols = append(b.cols, col)
	b.x0, b.x1 = append(b.x0, cx-r), append(b.x1, cx+r)
	b.y0, b.y1 = append(b.y0, cy-r), append(b.y1, cy+r)
	b.total = total + n
}

// pushed is one point pushed by a drop (the refinement midpoints), as in
// drop.
func pushed(x, y, cx, cy, r2 int) (int, int) {
	dx, dy := x-cx, y-cy
	d2 := dx*dx + dy*dy
	if d2 >= 9*r2 || d2 == 0 {
		return x, y
	}
	t := d2 * 1024 / (d2 + r2)
	if t < 32 {
		s, q := isqrt(d2+r2), isqrt(d2)
		return cx + dx*s/q, cy + dy*s/q
	}
	f := flut[t] - 4096
	if near2 := 9 * r2 / 4; d2 > near2 {
		f = f * (9*r2 - d2) / (9*r2 - near2)
	}
	return x + dx*f/4096, y + dy*f/4096
}

func zone(x, y int) int {
	switch {
	case x < -mg*q8:
		return 1
	case x > (sw+mg)*q8:
		return 2
	case y < -mg*q8:
		return 3
	case y > (sh+mg)*q8:
		return 4
	}
	return 0
}

func absi(v int) int {
	if v < 0 {
		return -v
	}
	return v
}

// resample prunes the inside of every run of points beyond one edge of the
// margin (exact for what the sheet shows: no later operation brings them
// back) and halves the edges longer than maxLen px that touch the margin
// box, within the point budget. Polygons left with fewer than 3 points are
// dropped. (zone() is inlined here and in pathOf: a call costs more than the
// comparisons in GnoVM.)
func (b *bath) resample(maxLen int) {
	m := maxLen * q8
	lo, hx, hy := -mg*q8, (sw+mg)*q8, (sh+mg)*q8
	oxs := make([][]int, 0, len(b.xs))
	oys := make([][]int, 0, len(b.xs))
	ocols := make([]string, 0, len(b.xs))
	total, limit := b.total, b.limit
	for p, xs := range b.xs {
		ys := b.ys[p]
		ln := len(xs)
		zs := make([]int, ln)
		for i, x := range xs {
			if x < lo {
				zs[i] = 1
			} else if x > hx {
				zs[i] = 2
			} else if y := ys[i]; y < lo {
				zs[i] = 3
			} else if y > hy {
				zs[i] = 4
			}
		}
		nx, ny := make([]int, 2*ln), make([]int, 2*ln)
		k, h := 0, zs[ln-1]
		for i, x := range xs {
			z, j := zs[i], i+1
			if j == ln {
				j = 0
			}
			zj := zs[j]
			if z != 0 && h == z && zj == z {
				total--
				continue
			}
			h = z
			y := ys[i]
			nx[k], ny[k] = x, y
			k++
			if total < limit && (z == 0 || zj == 0) {
				ex, ey := xs[j]-x, ys[j]-y
				ax, ay := ex, ey
				if ax < 0 {
					ax = -ax
				}
				if ay < 0 {
					ay = -ay
				}
				if ax+ay > m {
					nx[k], ny[k] = x+ex/2, y+ey/2
					k++
					total++
				}
			}
		}
		if k < 3 {
			total -= k
			continue
		}
		oxs = append(oxs, nx[:k])
		oys = append(oys, ny[:k])
		ocols = append(ocols, b.cols[p])
	}
	b.xs, b.ys, b.cols, b.total = oxs, oys, ocols, total
	b.fresh = false
}

// combTable is the summed drag of tines at pos (px along the cross axis),
// each moving the paint by z px with fall-off lam px, tapered to 0 at rr px.
// Index = px + mg; values in q8 units.
func combTable(size int, pos, dirs []int, z, lam, rr int) []int {
	t := make([]int, size+2*mg)
	for k := 0; k < len(pos); k++ {
		for d := -rr; d <= rr; d++ {
			idx := pos[k] + d + mg
			if idx < 0 || idx >= len(t) {
				continue
			}
			ad := absi(d)
			t[idx] += dirs[k] * (z * q8 * lam * (rr - ad) / ((ad + lam) * rr))
		}
	}
	return t
}

// comb applies a comb table: horizontal false moves y by t[x] (vertical
// tines), true moves x by t[y]. wave (optional, indexed by the moved axis)
// bends the tines into a serpentine.
func (b *bath) comb(t []int, horizontal bool, wave []int) {
	b.fresh = false
	top := len(t) - 1
	for p := 0; p < len(b.xs); p++ {
		along, moved := b.xs[p], b.ys[p]
		if horizontal {
			along, moved = b.ys[p], b.xs[p]
		}
		for i := 0; i < len(along); i++ {
			a := along[i]
			if wave != nil {
				w := moved[i]/q8 + mg
				if w < 0 {
					w = 0
				} else if w >= len(wave) {
					w = len(wave) - 1
				}
				a -= wave[w]
			}
			idx := a/q8 + mg
			if idx < 0 {
				idx = 0
			} else if idx > top {
				idx = top
			}
			moved[i] += t[idx]
		}
	}
}

// stroke drags a stylus along the y axis (x when horizontal) at cross
// position c from a to e (px): points near the line move by z px towards e,
// fading with the distance (fall-off lam, cut at 6 lam) and at both ends.
// Polygons whose box misses the stroke's reach are skipped (exact: none of
// their points could move); the boxes of the others grow with their points.
func (b *bath) stroke(c, a, e, z, lam int, horizontal bool) {
	if !b.fresh {
		b.bounds()
	}
	dir, lo, hi := 1, a*q8, e*q8
	if e < a {
		dir, lo, hi = -1, e*q8, a*q8
	}
	cq, lamQ, zq := c*q8, lam*q8, z*q8
	rq := 6 * lamQ
	ramp := 3 * lamQ
	if zq+lamQ > ramp {
		ramp = zq + lamQ
	}
	for p := range b.xs {
		ac0, ac1, al0, al1 := b.x0[p], b.x1[p], b.y0[p], b.y1[p]
		across, along := b.xs[p], b.ys[p]
		if horizontal {
			ac0, ac1, al0, al1 = b.y0[p], b.y1[p], b.x0[p], b.x1[p]
			across, along = b.ys[p], b.xs[p]
		}
		if ac1 <= cq-rq || ac0 >= cq+rq || al1 <= lo-ramp || al0 >= hi+ramp {
			continue
		}
		for i, v := range along {
			d := across[i] - cq
			if d < 0 {
				d = -d
			}
			if d >= rq || v <= lo-ramp || v >= hi+ramp {
				continue
			}
			w := 256
			if v < lo {
				w = (v - lo + ramp) * 256 / ramp
			} else if v > hi {
				w = (hi + ramp - v) * 256 / ramp
			}
			v += dir * (zq * lamQ * (rq - d) / ((d + lamQ) * rq) * w / 256)
			along[i] = v
			if v < al0 {
				al0 = v
			} else if v > al1 {
				al1 = v
			}
		}
		if horizontal {
			b.x0[p], b.x1[p] = al0, al1
		} else {
			b.y0[p], b.y1[p] = al0, al1
		}
	}
}

// nestGrid is the bülbül yuvası grid: centres (px), columns, cell size
// (px) and the squared disc radius (q8 units). Every disc lies inside its
// cell.
type nestGrid struct {
	cx, cy           []int
	cols, cw, ch, r2 int
}

// at returns the nest whose disc holds (x, y) (q8 units), or -1.
func (n *nestGrid) at(x, y int) int {
	if x < 0 || y < 0 {
		return -1
	}
	ci := x / (n.cw * q8)
	k := y/(n.ch*q8)*n.cols + ci
	if ci >= n.cols || k >= len(n.cx) {
		return -1
	}
	dx, dy := x-n.cx[k]*q8, y-n.cy[k]*q8
	if dx*dx+dy*dy < n.r2 {
		return k
	}
	return -1
}

// nests are bülbül yuvası: stylus spirals; each turns the paint by
// turns*(1-d^2/R^2)^2 (256 = one turn).
func (b *bath) nests(n *nestGrid, turns []int) {
	b.fresh = false
	r2 := n.r2
	for p, xs := range b.xs {
		ys := b.ys[p]
		for i, x := range xs {
			y := ys[i]
			k := n.at(x, y)
			if k < 0 {
				continue
			}
			kx, ky := n.cx[k]*q8, n.cy[k]*q8
			dx, dy := x-kx, y-ky
			u := (r2 - dx*dx - dy*dy) * 256 / r2
			a := (turns[k] * u * u / 65536) & 255
			c, s := sinT[(a+64)&255], sinT[a]
			xs[i] = kx + (dx*c-dy*s)/1024
			ys[i] = ky + (dx*s+dy*c)/1024
		}
	}
}

// refineDiscs splits the edges inside the nests' discs before they turn. A
// first pass measures them, so the piece length (at least minLen px) spreads
// the remaining point budget evenly over every disc.
func (b *bath) refineDiscs(n *nestGrid, minLen int) {
	b.fresh = false
	sum := 0
	for p, xs := range b.xs {
		ys := b.ys[p]
		ln := len(xs)
		for i, x := range xs {
			j := i + 1
			if j == ln {
				j = 0
			}
			ex, ey := xs[j]-x, ys[j]-ys[i]
			if n.at(x+ex/2, ys[i]+ey/2) >= 0 {
				sum += absi(ex) + absi(ey)
			}
		}
	}
	budget := b.limit - b.total
	if budget <= 0 {
		return
	}
	m := sum/budget + 1
	if minLen*q8 > m {
		m = minLen * q8
	}
	total, limit := b.total, b.limit
	for p, xs := range b.xs {
		ys := b.ys[p]
		ln := len(xs)
		nx := make([]int, 0, ln+8)
		ny := make([]int, 0, ln+8)
		for i, x := range xs {
			j := i + 1
			if j == ln {
				j = 0
			}
			y := ys[i]
			nx = append(nx, x)
			ny = append(ny, y)
			ex, ey := xs[j]-x, ys[j]-y
			l := absi(ex) + absi(ey)
			if l <= m || n.at(x+ex/2, y+ey/2) < 0 {
				continue
			}
			pieces := l/m + 1
			for q := 1; q < pieces && total < limit; q++ {
				nx = append(nx, x+ex*q/pieces)
				ny = append(ny, y+ey*q/pieces)
				total++
			}
		}
		b.xs[p], b.ys[p] = nx, ny
	}
	b.total = total
}

// ---------------------------------------------------------------------------
// Composition
// ---------------------------------------------------------------------------

// stoneSizes: radius lo, hi and the count of the first layer, per Stones.
var stoneSizes = [][3]int{{110, 150, 14}, {84, 118, 20}, {60, 90, 24}}

type painter struct {
	R   *rng
	pal []string
	ci  int
}

func (pt *painter) next() string {
	c := pt.pal[pt.ci%5]
	pt.ci++
	return c
}

// stones is the stone layer: big drops, then smaller ones in between
// (battal).
func (b *bath) stones(pt *painter, size int, light bool) {
	R, sr := pt.R, stoneSizes[size]
	n1 := sr[2]
	if light {
		n1 = sr[2] * 2 / 3
	}
	for k := 0; k < n1; k++ {
		r := R.between(sr[0], sr[1])
		x := R.between(0, sw)
		y := R.between(0, sh)
		col := pt.next()
		b.drop(x, y, r, col, r/4, R.intn(256))
	}
	b.resample(12)
	n2 := n1 / 2
	for k := 0; k < n2; k++ {
		r := R.between(sr[0]/2, sr[1]/2)
		x := R.between(10, sw-10)
		y := R.between(10, sh-10)
		col := pt.next()
		b.drop(x, y, r, col, r/3, R.intn(256))
	}
	b.resample(12)
}

// gelgit is a stylus drawn back and forth along lines sp px apart, in two
// half strokes; more = another comb follows.
func (b *bath) gelgit(R *rng, horizontal bool, sp, z int, more bool) {
	size := sw
	if horizontal {
		size = sh
	}
	var pos, dirs []int
	dir := -1
	if R.intn(2) == 1 {
		dir = 1
	}
	for x := R.between(4, sp); x < size; x += sp {
		pos = append(pos, x)
		dirs = append(dirs, dir)
		dir = -dir
	}
	t := combTable(size, pos, dirs, z/2, 12, 3*sp)
	b.comb(t, horizontal, nil)
	b.resample(10)
	b.comb(t, horizontal, nil)
	if more { // only when another comb follows
		b.resample(12)
	}
}

// teeth are the positions of a one-way comb, sp px apart.
func teeth(R *rng, size, sp int) ([]int, []int) {
	var pos, dirs []int
	for y := R.between(2, sp); y < size; y += sp {
		pos = append(pos, y)
		dirs = append(dirs, 1)
	}
	return pos, dirs
}

// SVG renders seed under cfg.
func SVG(seed string, cfg Config) string {
	d := derive(seed, cfg)
	R := newRNG(seed + "|art") // separate stream: trait draws never shift the art
	pal := palettes[d.palette]
	pt := &painter{R: R, pal: pal.paints}
	pt.ci = R.intn(5)
	b := &bath{limit: maxPoints}
	hz := d.flow == 1

	switch d.pattern {
	case pBattal:
		b.stones(pt, d.stones, false)
		n3 := R.between(5, 8)
		for k := 0; k < n3; k++ {
			x := R.between(10, sw-10)
			y := R.between(10, sh-10)
			r := R.between(14, 26)
			col := pt.next()
			b.drop(x, y, r, col, 20, R.intn(256))
		}
	case pGelgit:
		b.stones(pt, d.stones, false)
		sp := R.between(34, 46)
		b.gelgit(R, hz, sp, R.between(110, 150), false)
	case pTarakli:
		b.stones(pt, d.stones, false)
		sp := R.between(40, 52)
		b.gelgit(R, hz, sp, R.between(100, 130), true)
		size := sh
		if hz {
			size = sw
		}
		sp = R.between(22, 28)
		pos, dirs := teeth(R, size, sp)
		b.comb(combTable(size, pos, dirs, 18, 7, 2*sp), !hz, nil)
	case pSal:
		b.stones(pt, d.stones, false)
		sp := R.between(40, 52)
		b.gelgit(R, hz, sp, R.between(100, 130), true)
		size, other := sh, sw
		if hz {
			size, other = sw, sh
		}
		sp = R.between(44, 56)
		amp := R.between(16, 26)
		per := R.between(70, 110)
		pos, dirs := teeth(R, size, sp)
		wave := make([]int, other+2*mg)
		for i := range wave {
			wave[i] = amp * q8 * sinT[((i-mg)*256/per)&255] / 1024
		}
		b.comb(combTable(size, pos, dirs, 30, 16, 2*sp), !hz, wave)
	case pHatip:
		b.stones(pt, d.stones, true)
		cols := R.between(2, 3)
		rows := 3
		var cx, cy, rr []int
		for j := 0; j < rows; j++ {
			for i := 0; i < cols; i++ {
				x := sw*(2*i+1)/(2*cols) + R.between(-12, 12)
				y := sh*(2*j+1)/(2*rows) + R.between(-12, 12)
				r := R.between(34, 48)
				cx, cy, rr = append(cx, x), append(cy, y), append(rr, r)
				for k := 0; k < 4; k++ {
					col := pt.next()
					b.drop(x, y, r*(4-k)/4, col, 36-6*k, R.intn(256))
				}
			}
		}
		b.resample(10)
		down := R.intn(2) == 1
		for k := range cx {
			r := rr[k]
			if down {
				b.stroke(cx[k], cy[k]-r*3/2, cy[k]+r*3/2, r*4/5, r/7, false)
			} else {
				b.stroke(cx[k], cy[k]+r*3/2, cy[k]-r*3/2, r*4/5, r/7, false)
			}
		}
	case pBulbul:
		b.limit = maxPoints - 1400 // the nests need points of their own
		b.stones(pt, d.stones, false)
		sp := R.between(36, 46)
		b.gelgit(R, hz, sp, R.between(90, 120), false)
		b.limit = maxPoints
		n := &nestGrid{cols: 3, cw: sw / 3, ch: sh / 4}
		rad := n.cw * 7 / 20
		if n.ch < n.cw {
			rad = n.ch * 7 / 20
		}
		n.r2 = rad * rad * q8 * q8
		var turns []int
		spin := -1
		if R.intn(2) == 1 {
			spin = 1
		}
		for j := 0; j < 4; j++ {
			for i := 0; i < 3; i++ {
				x := i*n.cw + n.cw/2 + R.between(-6, 6)
				y := j*n.ch + n.ch/2 + R.between(-6, 6)
				n.cx, n.cy = append(n.cx, x), append(n.cy, y)
				turns = append(turns, spin*R.between(150, 230))
			}
		}
		b.refineDiscs(n, 3)
		b.nests(n, turns)
	case pCicekli:
		b.stones(pt, d.stones, true)
		leaf := pal.paints[pal.leaf]
		n := R.between(3, 4)
		var fx, fy, fr []int
		for k := 0; k < n; k++ {
			x := sw*(2*k+1)/(2*n) + R.between(-10, 10)
			y := R.between(250, 430) + (k%2)*90
			r := R.between(40, 52)
			fx, fy, fr = append(fx, x), append(fy, y), append(fr, r)
			// stem and leaves first: the cup floats on top of them
			b.drop(x, y+r*5/3, r/4, leaf, 16, 0)
			b.drop(x-r*3/4, y+r*5/2, r/3, leaf, 20, 0)
			b.drop(x+r*3/4, y+r*5/2, r/3, leaf, 20, 0)
			petal := pt.next()
			b.drop(x, y, r, petal, 40, 0)
			b.drop(x, y+r/6, r*3/5, pt.next(), 32, 0)
			b.drop(x, y+r/4, r/4, petal, 20, 0)
		}
		b.resample(8)
		for k := 0; k < n; k++ {
			x, y, r := fx[k], fy[k], fr[k]
			// three petal tips: the stylus pulled up through the cup
			b.stroke(x-r*2/5, y+r/3, y-r*3/2, r*3/5, r/8, false)
			b.stroke(x+r*2/5, y+r/3, y-r*3/2, r*3/5, r/8, false)
			b.stroke(x, y, y-r*7/4, r*4/5, r/8, false)
			// stem pulled down, leaves pulled up and out
			b.stroke(x, y+r*3/2, y+r*9/2, r*5/2, r/10, false)
			b.stroke(x-r*3/4, y+r*3, y+r*3/2, r*3/2, r/8, false)
			b.stroke(x+r*3/4, y+r*3, y+r*3/2, r*3/2, r/8, false)
		}
	}
	return b.svg(R, d, groundColors[d.ground])
}

// ---------------------------------------------------------------------------
// Output
// ---------------------------------------------------------------------------

// nums holds the decimal strings of -127..127: 99.99 % of the path steps
// (strconv.Itoa is the dearest primitive an SVG writer has in GnoVM, and a
// bigger table costs storage for every deploy).
var nums = func() []string {
	t := make([]string, 255)
	for i := range t {
		t[i] = strconv.Itoa(i - 127)
	}
	return t
}()

func num(v int) string {
	if v >= -127 && v <= 127 {
		return nums[v+127]
	}
	return strconv.Itoa(v)
}

// pathOf is the path of one polygon: rounded to px, runs beyond the margin
// pruned, steps under 2 px merged.
func pathOf(xs, ys []int) string {
	ln := len(xs)
	lo, hx, hy := -mg*q8, (sw+mg)*q8, (sh+mg)*q8
	zs := make([]int, ln)
	inside := false
	for i, x := range xs {
		if x < lo {
			zs[i] = 1
		} else if x > hx {
			zs[i] = 2
		} else if y := ys[i]; y < lo {
			zs[i] = 3
		} else if y > hy {
			zs[i] = 4
		} else {
			inside = true
		}
	}
	if !inside {
		// a polygon fully beyond the margin is drawn only when it may cover the sheet
		x0, x1, y0, y1 := xs[0], xs[0], ys[0], ys[0]
		for i, x := range xs {
			if x < x0 {
				x0 = x
			} else if x > x1 {
				x1 = x
			}
			if y := ys[i]; y < y0 {
				y0 = y
			} else if y > y1 {
				y1 = y
			}
		}
		if x1 < 0 || x0 > sw*q8 || y1 < 0 || y0 > sh*q8 {
			return ""
		}
	}
	d := ""
	px, py, cnt, h := 0, 0, 0, zs[ln-1]
	for i, x := range xs {
		z, j := zs[i], i+1
		if j == ln {
			j = 0
		}
		if z != 0 && h == z && zs[j] == z {
			continue
		}
		h = z
		y := ys[i]
		if x < 0 {
			x = (x - 4) / q8
		} else {
			x = (x + 4) / q8
		}
		if y < 0 {
			y = (y - 4) / q8
		} else {
			y = (y + 4) / q8
		}
		if cnt == 0 {
			d = "M" + num(x) + " " + num(y) + "l"
			px, py, cnt = x, y, 1
			continue
		}
		dx, dy := x-px, y-py
		ax, ay := dx, dy
		if ax < 0 {
			ax = -ax
		}
		if ay < 0 {
			ay = -ay
		}
		if ax+ay < 2 {
			continue
		}
		sx, sy := "", ""
		if ax < 128 {
			sx = nums[dx+127]
		} else {
			sx = strconv.Itoa(dx)
		}
		if ay < 128 {
			sy = nums[dy+127]
		} else {
			sy = strconv.Itoa(dy)
		}
		if dy >= 0 {
			sy = " " + sy
		}
		if cnt > 1 && dx >= 0 {
			d += " " + sx + sy
		} else {
			d += sx + sy
		}
		px, py = x, y
		cnt++
	}
	if cnt < 3 {
		return ""
	}
	return d + "z"
}

func (b *bath) svg(R *rng, d draw, ground string) string {
	s1 := R.between(1, 900)
	s2 := R.between(1, 900)
	body := ""
	for p := 0; p < len(b.xs); p++ {
		path := pathOf(b.xs[p], b.ys[p])
		if path != "" {
			body += `<path fill="` + b.cols[p] + `" d="` + path + `"/>`
		}
	}
	defs := `<filter id="o" x="0" y="0" width="1" height="1"><feTurbulence type="fractalNoise" baseFrequency=".02" numOctaves="2" seed="` +
		num(s1) + `"/>` +
		`<feDisplacementMap in="SourceGraphic" scale="5" xChannelSelector="R" yChannelSelector="G"/></filter>` +
		`<filter id="p" x="0" y="0" width="1" height="1"><feTurbulence type="fractalNoise" baseFrequency=".7" numOctaves="2" seed="` +
		num(s2) + `"/>` +
		`<feColorMatrix values="0 0 0 0 .3 0 0 0 0 .25 0 0 0 0 .2 0 0 0 -1.6 .78"/></filter>`
	paint := `<g filter="url(#o)" stroke="#1a1410" stroke-opacity=".14" stroke-width="1.2">` + body + `</g>`
	if d.finish == fNeftli {
		// turpentine: the paint breaks into small cells that show the bath
		defs += `<filter id="n" x="0" y="0" width="1" height="1"><feTurbulence type="fractalNoise" baseFrequency=".09" numOctaves="1" seed="` +
			num(R.between(1, 900)) + `"/>` +
			`<feColorMatrix values="0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 12 0 0 0 -3.3"/><feComposite in="SourceGraphic" operator="in"/></filter>`
		paint = `<g filter="url(#n)">` + paint + `</g>`
	}
	over := ""
	if d.finish == fZerefsan {
		// gold dust shaken over the sheet
		a := R.between(0, 89)
		c := R.between(0, 89)
		defs += `<pattern id="z" width="37" height="41" patternUnits="userSpaceOnUse" patternTransform="rotate(` + num(a) + `)">` +
			`<circle cx="5" cy="9" r="1.3"/><circle cx="23" cy="4" r=".8"/><circle cx="17" cy="27" r="1.6"/><circle cx="31" cy="33" r=".9"/></pattern>` +
			`<pattern id="y" width="53" height="47" patternUnits="userSpaceOnUse" patternTransform="rotate(` + num(c) + `)">` +
			`<circle cx="11" cy="20" r="1.1"/><circle cx="40" cy="12" r="1.8"/><circle cx="29" cy="41" r=".7"/></pattern>`
		over = `<g fill="#c9a24a" opacity=".85"><rect width="600" height="800" fill="url(#z)"/><rect width="600" height="800" fill="url(#y)"/></g>`
	}
	frame := ""
	switch d.frame {
	case frCetvel:
		frame = `<g fill="none" stroke="#c9a24a"><rect x="16" y="16" width="568" height="768" stroke-width="3"/>` +
			`<rect x="23" y="23" width="554" height="754" stroke-width="1"/></g>`
	case frKenar:
		// the sheet as the margin (kenar) of a calligraphy panel: a plain field ruled in gold, with gilt corner pieces
		defs += `<path id="k" d="M0 0h58q-30 26-58 58z" fill="#c9a24a"/>`
		frame = `<rect x="120" y="160" width="360" height="480" fill="#f4ecda"/>` +
			`<use href="#k" transform="translate(128 168)"/><use href="#k" transform="translate(472 168) scale(-1 1)"/>` +
			`<use href="#k" transform="translate(128 632) scale(1 -1)"/><use href="#k" transform="translate(472 632) scale(-1 -1)"/>` +
			`<g fill="none" stroke="#c9a24a"><rect x="120" y="160" width="360" height="480" stroke-width="4"/>` +
			`<rect x="128" y="168" width="344" height="464" stroke-width="1"/>` +
			`<rect x="112" y="152" width="376" height="496" stroke="#1a1410" stroke-opacity=".5" stroke-width="1"/></g>`
	}
	return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 600 800"><defs>` + defs + `</defs>` +
		`<rect width="600" height="800" fill="` + ground + `"/>` + paint + over +
		`<rect width="600" height="800" filter="url(#p)" opacity=".35"/>` + frame + `</svg>`
}
