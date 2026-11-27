// Package pafta is a Sinopia engine: a collection of 256 map sheets that
// together form one large survey map (16 x 16 sheets). The terrain is one
// global field, so the edges of neighbouring sheets join exactly; every
// token is one sheet, with its own settlement, landmark and place name.
//
// Fairness. The map and every token's sheet are fixed by the collection's
// final salt (core commit-reveal), which exists only after the sale closed
// and both secrets were revealed:
//
//	mapSeed   = sha256hex("art|pafta|map|v1|" + cid + "|" + salt)
//	permKey   = sha256hex("art|pafta|perm|v1|" + cid + "|" + salt)
//	tile(tid) = media.Permute(permKey, 256, tid-1)
//
// The token's own seed (core's safe.Seed(cid, tid, salt)) only chooses what
// is drawn on its sheet. Before Final nobody, the creator included, can tell
// which sheet a token will be or what the map looks like. Without a
// collection (core.RenderWith, Studio, the registration sample) a seed renders
// a "standalone" sheet of its own map (Standalone).
//
// The adapter (r/…/engines/pafta) decides which of the two a call gets: only
// core's real TokenURI/TokenTraits call for a Final commit-reveal collection
// of this engine is placed.
//
// frontend/src/engines/pafta.ts is a byte-identical TypeScript twin;
// pafta_test.gno and pafta.test.ts pin the same golden vectors. Pure integer
// maths: no floats, no time, no block data.
package pafta

import (
	"errors"
	"strconv"
	"strings"

	"gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia4/engine/v2"
	"gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia4/media/v2"
	"gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia4/safe/v2"
)

// TraitTypes in the order Traits returns them.
var traitTypes = []string{"Sheet", "Terrain", "Relief", "Settlement", "Landmark", "Palette", "Landform", "Rarity"}

// MaxSVGBytes: see the size table in docs/engines/pafta.md.
const MaxSVGBytes = 28672

// Side is the number of sheets per map side; a collection is exactly Sheets
// tokens (CheckLaunch in the adapter).
const (
	Side   = 16
	Sheets = 256
)

// The map face of every sheet: a composite view crops each token's SVG to
// the box (MapX, MapY, MapSize) of the Width x Height sheet and lays the
// boxes edge to edge on the 16 x 16 grid.
const (
	Width   = 560
	Height  = 660
	MapX    = 40
	MapY    = 96
	MapSize = 480
)

// Hash domains of the post-reveal map seed and sheet permutation.
const (
	MapDomain  = "art|pafta|map|v1|"
	PermDomain = "art|pafta|perm|v1|"
)

// ParamsSchema is the Studio form. Studio sends JSON.stringify of the values
// in this property order; ValidateParams accepts exactly that or "".
const ParamsSchema = `{"type":"object","properties":{` +
	`"palette":{"type":"string","title":"Palette","enum":["Seeded","Survey","Atlas","Admiralty","Antique"],"default":"Seeded"},` +
	`"landform":{"type":"string","title":"Landform","enum":["Seeded","Island","Archipelago","Mainland Coast","Inland Sea"],` +
	`"default":"Seeded"}}}`

// DefaultParams is the canonical form of the defaults; it renders exactly
// like "".
const DefaultParams = `{"palette":"Seeded","landform":"Seeded"}`

// Manifest describes the engine. Author and FeeBps are set by the adapter.
func Manifest() engine.Manifest {
	return engine.Manifest{
		Name:    "Pafta",
		Version: "1.0.0",
		Description: "One map in 256 sheets. Every token is a survey sheet of a single island world whose edges " +
			"join its neighbours exactly; the map and each token's place are fixed only at the reveal.",
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
	Palette  int // -1: from the map seed
	Landform int // -1: from the map seed
}

// Defaults is the showcase look (params "").
func Defaults() Config { return Config{Palette: -1, Landform: -1} }

var errParams = errors.New(`pafta: params must be "" or {"palette":<enum>,"landform":<enum>} without spaces`)

// ParseParams accepts "" or the canonical JSON Studio produces, nothing else.
func ParseParams(params string) (Config, error) {
	cfg := Defaults()
	if params == "" {
		return cfg, nil
	}
	const p1, p2, p3 = `{"palette":"`, `","landform":"`, `"}`
	if len(params) < len(p1)+len(p3) || !strings.HasPrefix(params, p1) || !strings.HasSuffix(params, p3) {
		return cfg, errParams
	}
	body := params[len(p1) : len(params)-len(p3)]
	k := strings.Index(body, p2)
	if k < 0 {
		return cfg, errParams
	}
	pv, lv := body[:k], body[k+len(p2):]
	if strings.IndexByte(pv, '"') >= 0 || strings.IndexByte(lv, '"') >= 0 {
		return cfg, errParams
	}
	ok := false
	if cfg.Palette, ok = enumIndex(pv, paletteOpts()); !ok {
		return cfg, errParams
	}
	if cfg.Landform, ok = enumIndex(lv, landforms); !ok {
		return cfg, errParams
	}
	return cfg, nil
}

// enumIndex maps "Seeded" to -1 and a table name to its index.
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

// Place is where a token lies: the map it belongs to and its sheet
// (0..255, row-major).
type Place struct {
	MapSeed string
	Tile    int
}

// MapSeed is collection cid's map seed for its final salt.
func MapSeed(cid, salt string) string { return safe.Sha256Hex(MapDomain + cid + "|" + salt) }

// PermKey is collection cid's sheet permutation key for its final salt.
func PermKey(cid, salt string) string { return safe.Sha256Hex(PermDomain + cid + "|" + salt) }

// Placement is token tid (1..256) of a Final collection with salt salt.
func Placement(cid string, tid int64, salt string) Place {
	if tid < 1 || tid > Sheets {
		panic("pafta: token id must be 1..256")
	}
	return Place{MapSeed: MapSeed(cid, salt), Tile: int(media.Permute(PermKey(cid, salt), Sheets, tid-1))}
}

// Standalone is the placement of a seed without a collection: a sheet of the
// seed's own map, drawn among the sheets with land at their centre (any sheet when
// the map has none).
func Standalone(seed string, cfg Config) Place {
	p, _ := standalone(seed, cfg)
	return p
}

// standalone is Standalone plus the map's landMask (the index map reuses it).
func standalone(seed string, cfg Config) (Place, []bool) {
	mask := landMask(mapInfoOf(seed, cfg))
	tiles := []int{}
	for t := 0; t < Sheets; t++ {
		if mask[t] {
			tiles = append(tiles, t)
		}
	}
	v := newRNG(seed + "|place").next()
	if len(tiles) == 0 {
		return Place{MapSeed: seed, Tile: reduce(v, Sheets)}, mask
	}
	return Place{MapSeed: seed, Tile: tiles[reduce(v, len(tiles))]}, mask
}

// SheetCode is "A1" … "P16": row letter + column number.
func SheetCode(tile int) string {
	return string(rune('A'+tile/Side)) + strconv.Itoa(tile%Side+1)
}

// Traits returns the eight traits of a standalone sheet of in.Seed.
func Traits(in engine.Input) []engine.Trait {
	cfg := mustConfig(in.Params)
	return SheetTraits(in.Seed, cfg, Standalone(in.Seed, cfg))
}

// Render returns the SVG of a standalone sheet of in.Seed.
func Render(in engine.Input) string {
	cfg := mustConfig(in.Params)
	p, mask := standalone(in.Seed, cfg)
	return sheetSVG(in.Seed, cfg, p, mask)
}

// SheetTraits are the traits of token seed at place p, in TraitTypes order.
// It never renders.
func SheetTraits(seed string, cfg Config, p Place) []engine.Trait {
	s := survey(seed, cfg, p)
	return []engine.Trait{
		{Type: "Sheet", Value: SheetCode(s.tile)},
		{Type: "Terrain", Value: s.terrain},
		{Type: "Relief", Value: s.relief},
		{Type: "Settlement", Value: s.settleKind},
		{Type: "Landmark", Value: landmarks[s.mark].name},
		{Type: "Palette", Value: palettes[s.mi.palette].name},
		{Type: "Landform", Value: landforms[s.mi.landform].name},
		{Type: "Rarity", Value: s.rarity},
	}
}

// ---------------------------------------------------------------------------
// Deterministic randomness: FNV-1a over the seed, then splitmix64 (the stream
// of every Sinopia engine).
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

func (r *rng) u32() uint32 { return uint32(r.next()) }

func (r *rng) intn(n int) int {
	if n <= 0 {
		return 0
	}
	return int(r.next() % uint64(n))
}

func (r *rng) between(a, b int) int { return a + r.intn(b-a+1) }

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

// reduce maps a draw that was always taken onto [0, n); -1 when n <= 0.
func reduce(v uint64, n int) int {
	if n <= 0 {
		return -1
	}
	return int(v % uint64(n))
}

// numTbl holds the decimal form of -520..520: every path number of a sheet.
// Formatting numbers is the dearest part of a render in the VM; a lookup and
// plain string concatenation cost a fraction of strconv and a Builder.
const numOff = 520

var numTbl = func() []string {
	out := make([]string, 2*numOff+1)
	for k := range out {
		out[k] = strconv.Itoa(k - numOff)
	}
	return out
}()

// num is strconv.Itoa(v).
func num(v int) string {
	if v >= -numOff && v <= numOff {
		return numTbl[v+numOff]
	}
	return strconv.Itoa(v)
}

// fdiv is floor division (b > 0).
func fdiv(a, b int) int {
	q := a / b
	if a%b != 0 && a < 0 {
		q--
	}
	return q
}

// ---------------------------------------------------------------------------
// Geometry and tables
// ---------------------------------------------------------------------------

const (
	cG    = 24          // lattice cells per sheet side
	cC    = 20          // px per cell
	cM    = cG * cC     // 480
	span  = cG + 3      // lattice points per side incl. a one-cell margin (-1 .. G+1)
	world = Side * cG   // 384
	off   = 96          // noise coordinates are offset to stay positive
	hn    = (span - 1) * span
)

type palette struct {
	name                                         string
	weight                                       int
	paper, ink, ink2, sea, deep, wl, coast, bathy string
	t0, t1, t2, t3, contour, index, hatch         string
	forest, tree, red, grid                       string
}

var palettes = []palette{
	{"Survey", 35, "#f4efe2", "#2a2420", "#6a5d50", "#bcdbe6", "#a2c6d8", "#d6eaf0", "#2f5a78", "#7ea6bd",
		"#eef0d6", "#efe3bb", "#e6cfa4", "#d8b78c", "#b08458", "#8a5a32", "#7a5634", "#dce7bf", "#7a9a58", "#b5452f", "#34404a"},
	{"Atlas", 25, "#f6f3ea", "#1f2a30", "#5a6670", "#93c6e4", "#6aa6d3", "#b4daf0", "#1d4f7a", "#4f86b8",
		"#bcdb9c", "#e4e4a2", "#e3c184", "#c9966c", "#8f6c40", "#6e4c28", "#f6efe4", "#a3cc88", "#3f7a3a", "#c0392b", "#20303a"},
	{"Admiralty", 25, "#f3eee0", "#1c2633", "#5b6577", "#cfe3ee", "#f8f6ef", "#a9cde2", "#1c2633", "#6f93ad",
		"#eedfb6", "#e7d3a2", "#dcc290", "#ceb07c", "#a08050", "#7a5a30", "#8b6b40", "#e3dcae", "#8a8a50", "#b03070", "#1c2633"},
	{"Antique", 15, "#efe2c4", "#3b2a1a", "#7a6040", "#cdd4bf", "#bcc6b0", "#dde0cb", "#5a4024", "#9a8660",
		"#efe2c0", "#e7d3a9", "#dcc191", "#cdaa77", "#9a7448", "#6e4a28", "#6e4a28", "#e0d3a7", "#7a6a3a", "#9a3020", "#3b2a1a"},
}

func paletteOpts() []option {
	out := make([]option, len(palettes))
	for i, p := range palettes {
		out[i] = option{p.name, p.weight}
	}
	return out
}

var landforms = []option{{"Island", 40}, {"Archipelago", 25}, {"Mainland Coast", 20}, {"Inland Sea", 15}}

const (
	lfIsland      = 0
	lfArchipelago = 1
	lfCoast       = 2 // 3: Inland Sea
)

var settleKinds = []option{{"Hamlet", 40}, {"Village", 38}, {"Town", 22}}

const sHamlet = 0

var landmarks = []option{
	{"None", 60}, {"Lighthouse", 9}, {"Wreck", 8}, {"Castle", 8}, {"Ruins", 7}, {"Windmill", 5}, {"Treasure", 3},
}

const (
	lmNone       = 0
	lmLighthouse = 1
	lmWreck      = 2
	lmCastle     = 3
	lmRuins      = 4
	lmWindmill   = 5
	lmTreasure   = 6
)

// Place-name parts: lower, upper (Turkish casing).
var nameA = [][2]string{
	{"Kara", "KARA"}, {"Ak", "AK"}, {"Kızıl", "KIZIL"}, {"Gök", "GÖK"}, {"Yel", "YEL"}, {"Tuz", "TUZ"},
	{"Mercan", "MERCAN"}, {"Sakız", "SAKIZ"}, {"Ilgın", "ILGIN"}, {"Defne", "DEFNE"}, {"Martı", "MARTI"},
	{"Lodos", "LODOS"}, {"Poyraz", "POYRAZ"}, {"Sünger", "SÜNGER"}, {"İnci", "İNCİ"}, {"Kum", "KUM"},
}

var nameB = [][2]string{
	{"ada", "ADA"}, {"burun", "BURUN"}, {"koy", "KOY"}, {"liman", "LİMAN"}, {"kaya", "KAYA"}, {"yalı", "YALI"},
	{"tepe", "TEPE"}, {"köy", "KÖY"}, {"pınar", "PINAR"}, {"dere", "DERE"}, {"ova", "OVA"}, {"kale", "KALE"},
}

// ---------------------------------------------------------------------------
// The map
// ---------------------------------------------------------------------------

type mapInfo struct {
	sh, sh2                     uint32
	palette, landform, dir      int
	nameA, nameB                int
}

func mapInfoOf(mapSeed string, cfg Config) mapInfo {
	r := newRNG(mapSeed + "|map")
	// Draw order is part of the contract; params override after the draws.
	var mi mapInfo
	mi.sh = r.u32()
	mi.sh2 = r.u32()
	mi.palette = pick(r, paletteOpts())
	mi.landform = pick(r, landforms)
	mi.dir = r.intn(4)
	mi.nameA = r.intn(len(nameA))
	mi.nameB = r.intn(len(nameB))
	if cfg.Palette >= 0 {
		mi.palette = cfg.Palette
	}
	if cfg.Landform >= 0 {
		mi.landform = cfg.Landform
	}
	return mi
}

func hash32(sh uint32, o, ix, iy int) uint32 {
	h := uint32(ix)*374761393 + uint32(iy)*668265263 + uint32(o+1)*1442695041
	h ^= sh
	h = (h ^ (h >> 13)) * 1274126177
	h ^= h >> 16
	return h
}

// oct is an octave: cell size, amplitude, octave id.
type oct struct{ s, amp, o int }

var reliefOcts = []oct{{96, 1000, 0}, {48, 640, 1}, {24, 420, 2}, {12, 240, 3}, {6, 110, 4}, {3, 45, 8}}
var moistOcts = []oct{{32, 1000, 5}, {16, 500, 6}, {8, 220, 7}}

// noiseGrid is value noise (smoothstep, Q10) summed over octaves at the
// points (x0 + i*step, y0 + j*step), i < nx, j < ny; coordinates >= 0. Node
// values are scaled by the octave's amplitude first; the bilinear blend is
// separable (each node row is blended along x once).
func noiseGrid(sh uint32, octs []oct, x0, y0, step, nx, ny int) []int {
	out := make([]int, nx*ny)
	xi := make([]int, nx)
	xs := make([]int, nx)
	for _, oc := range octs {
		S, amp, o := oc.s, oc.amp, oc.o
		lx, ly := x0/S, y0/S
		w := (x0+(nx-1)*step)/S - lx + 2
		h := (y0+(ny-1)*step)/S - ly + 2
		for i := 0; i < nx; i++ {
			g := x0 + i*step
			ix := g / S
			t := (g - ix*S) * 1024 / S
			xi[i] = ix - lx
			xs[i] = t * t * (3072 - 2*t) / 1048576
		}
		// rows[r*nx+i]: node row r blended along x at column i (Q10)
		rows := make([]int, h*nx)
		node := make([]int, w)
		for r := 0; r < h; r++ {
			for k := 0; k < w; k++ {
				node[k] = fdiv((int(hash32(sh, o, lx+k, ly+r)%2001)-1000)*amp, 1000)
			}
			base := r * nx
			for i := 0; i < nx; i++ {
				a := node[xi[i]]
				rows[base+i] = a*1024 + (node[xi[i]+1]-a)*xs[i]
			}
		}
		for j := 0; j < ny; j++ {
			g := y0 + j*step
			iy := g / S
			t := (g - iy*S) * 1024 / S
			sy := t * t * (3072 - 2*t) / 1048576
			b0 := (iy - ly) * nx
			b1 := b0 + nx
			oj := j * nx
			for i := 0; i < nx; i++ {
				a0 := rows[b0+i]
				out[oj+i] += (a0*1024 + (rows[b1+i]-a0)*sy) >> 20
			}
		}
	}
	return out
}

// falloff is the landform's large-scale shape at world lattice point (gx, gy).
func falloff(mi mapInfo, gx, gy int) int {
	dx := gx - world/2
	dy := gy - world/2
	d2 := dx*dx + dy*dy
	switch mi.landform {
	case lfIsland:
		return 700 - d2*1400/36864
	case lfArchipelago:
		return 60 - d2*700/36864
	case lfCoast:
		t, u := gx, gy
		if mi.dir == 1 {
			t = world - gx
		}
		if mi.dir == 2 {
			t, u = gy, gx
		}
		if mi.dir == 3 {
			t, u = world-gy, gx
		}
		du := u - world/2
		return 1000 - fdiv(t*2000, world) - du*du*500/36864
	default:
		return -850 + d2*1500/36864
	}
}

// relief is the elevation lattice of sheet (sx, sy): span x span points,
// i, j in -1 .. G+1.
func relief(mi mapInfo, sx, sy int) []int {
	gx0, gy0 := sx*cG-1, sy*cG-1
	e := noiseGrid(mi.sh, reliefOcts, gx0+off, gy0+off, 1, span, span)
	for j := 0; j < span; j++ {
		for i := 0; i < span; i++ {
			e[j*span+i] += falloff(mi, gx0+i, gy0+j)
		}
	}
	return e
}

// woodland is the forest field: >= 0 inside woodland (moist ground between
// 40 and 1100 m).
func woodland(mi mapInfo, sx, sy int, e []int) []int {
	m := noiseGrid(mi.sh2, moistOcts, sx*cG-1+off, sy*cG-1+off, 1, span, span)
	f := make([]int, span*span)
	for k := 0; k < span*span; k++ {
		v := e[k]
		x := m[k] - 220
		if v-40 < x {
			x = v - 40
		}
		if 1100-v < x {
			x = 1100 - v
		}
		f[k] = x
	}
	return f
}

func at(i, j int) int { return (j+1)*span + i + 1 }

// hillShade is the hill-shading field (light from the north-west): >= 0 on
// land whose slope turns away from the light. A central difference over the
// global lattice, so it joins across sheets.
func hillShade(e []int) []int {
	f := make([]int, span*span)
	for k := range f {
		f[k] = -1
	}
	for j := 0; j <= cG; j++ {
		k := (j+1)*span + 1
		for i := 0; i <= cG; i++ {
			d := e[k-span-1] - e[k+span+1] - 70
			v := e[k]
			if d < v {
				f[k] = d
			} else {
				f[k] = v
			}
			k++
		}
	}
	return f
}

// landMask is land (true) or sea at the centre of each of the 256 sheets
// (the index map; row-major like the tiles), from the three coarsest octaves.
func landMask(mi mapInfo) []bool {
	n := noiseGrid(mi.sh, reliefOcts[:3], cG/2+off, cG/2+off, cG, Side, Side)
	out := make([]bool, Sheets)
	for t := 0; t < Sheets; t++ {
		out[t] = n[t]+falloff(mi, cG/2+(t%Side)*cG, cG/2+(t/Side)*cG) >= 0
	}
	return out
}

// ---------------------------------------------------------------------------
// Sheet analysis (traits)
// ---------------------------------------------------------------------------

type surveyed struct {
	mi                       mapInfo
	tile, sx, sy             int
	e                        []int
	terrain, relief          string
	peak                     int // lattice index of the highest interior point, -1 below 300 m
	settle                   int // -1: none
	settleKind               string
	mark, markAt             int // landmark kind; -1: none
	rarity                   string
}

func coastal(e []int, i, j int) bool {
	return e[at(i-1, j)] < 0 || e[at(i+1, j)] < 0 || e[at(i, j-1)] < 0 || e[at(i, j+1)] < 0
}

func survey(seed string, cfg Config, p Place) *surveyed {
	if p.Tile < 0 || p.Tile >= Sheets {
		panic("pafta: tile must be 0..255")
	}
	s := &surveyed{mi: mapInfoOf(p.MapSeed, cfg), tile: p.Tile, sx: p.Tile % Side, sy: p.Tile / Side}
	e := relief(s.mi, s.sx, s.sy)
	s.e = e
	emin, emax := 1<<30, -(1 << 30)
	borderLand, borderSea := false, false
	for j := 0; j <= cG; j++ {
		for i := 0; i <= cG; i++ {
			v := e[at(i, j)]
			if v < emin {
				emin = v
			}
			if v > emax {
				emax = v
			}
			if i == 0 || j == 0 || i == cG || j == cG {
				if v >= 0 {
					borderLand = true
				} else {
					borderSea = true
				}
			}
		}
	}
	s.terrain = "Coast"
	switch {
	case emax < 0:
		s.terrain = "Open Sea"
	case emin >= 0:
		s.terrain = "Inland"
	case !borderLand:
		s.terrain = "Islet"
	case !borderSea:
		s.terrain = "Lake"
	}
	s.relief = "High Peaks"
	switch {
	case emax < -600:
		s.relief = "Deep Water"
	case emax < -150:
		s.relief = "Open Water"
	case emax < 0:
		s.relief = "Shoals"
	case emax < 300:
		s.relief = "Lowland"
	case emax < 800:
		s.relief = "Hills"
	case emax < 1200:
		s.relief = "Uplands"
	case emax < 1800:
		s.relief = "Mountains"
	}

	// highest interior point (labels stay inside the sheet)
	s.peak = -1
	pv := 300
	for j := 2; j <= cG-2; j++ {
		for i := 2; i <= cG-2; i++ {
			if e[at(i, j)] > pv {
				pv = e[at(i, j)]
				s.peak = at(i, j)
			}
		}
	}

	T := newRNG(seed + "|traits")
	// Draw order is part of the contract: every draw is taken, used or not.
	kind := pick(T, settleKinds)
	sPick := T.next()
	mark := pick(T, landmarks)
	mPick := T.next()

	towns := []int{}
	for j := 2; j <= cG-2; j++ {
		for i := 2; i <= cG-2; i++ {
			v := e[at(i, j)]
			if v >= 20 && v <= 300 {
				towns = append(towns, at(i, j))
			}
		}
	}
	s.settle = -1
	s.settleKind = "None"
	if si := reduce(sPick, len(towns)); si >= 0 {
		s.settle = towns[si]
		s.settleKind = settleKinds[kind].name
		if kind != sHamlet && coastal(e, s.settle%span-1, s.settle/span-1) {
			s.settleKind = "Port"
		}
	}

	s.markAt = -1
	s.mark = lmNone
	if mark != lmNone {
		cands := []int{}
		for j := 2; j <= cG-2; j++ {
			for i := 2; i <= cG-2; i++ {
				k := at(i, j)
				v := e[k]
				if s.settle >= 0 {
					di := i - (s.settle%span - 1)
					dj := j - (s.settle/span - 1)
					if dj >= -2 && dj <= 2 && di >= -8 && di <= 8 {
						continue
					}
				}
				if s.peak >= 0 {
					di := i - (s.peak%span - 1)
					dj := j - (s.peak/span - 1)
					if dj >= -1 && dj <= 1 && di >= -2 && di <= 4 {
						continue
					}
				}
				ok := false
				switch mark {
				case lmLighthouse:
					ok = v >= 0 && v <= 150 && coastal(e, i, j)
				case lmWreck:
					ok = v < -120
				case lmCastle:
					ok = v >= 250
				case lmRuins:
					ok = v >= 0 && v <= 800
				case lmWindmill:
					ok = v >= 30 && v <= 500
				default:
					ok = v >= 0
				}
				if ok {
					cands = append(cands, k)
				}
			}
		}
		if mi2 := reduce(mPick, len(cands)); mi2 >= 0 {
			s.markAt = cands[mi2]
			s.mark = mark
		}
	}

	score := 0
	switch s.terrain {
	case "Islet", "Lake":
		score += 4
	case "Open Sea", "Coast":
		score++
	}
	switch s.relief {
	case "High Peaks":
		score += 3
	case "Mountains":
		score += 2
	case "Uplands", "Deep Water":
		score++
	}
	switch s.mark {
	case lmTreasure:
		score += 5
	case lmLighthouse, lmWreck, lmCastle:
		score += 3
	case lmNone:
	default:
		score += 2
	}
	if s.settleKind == "Port" || s.settleKind == "Town" {
		score++
	}
	s.rarity = "Common"
	switch {
	case score >= 9:
		s.rarity = "Mythic"
	case score >= 7:
		s.rarity = "Legendary"
	case score >= 5:
		s.rarity = "Rare"
	case score >= 3:
		s.rarity = "Uncommon"
	}
	return s
}

// ---------------------------------------------------------------------------
// Marching squares
// ---------------------------------------------------------------------------

// edgeCut is the offset (1..C-1) of level T's crossing on the edge from
// value a to value b. It never lands on a corner: a crossing rounded onto a
// cell corner would put a sliver of one sheet's polygon on the shared edge
// where its neighbour has none.
func edgeCut(a, b, T int) int {
	num := (T - a) * cC
	den := b - a
	if den < 0 {
		num, den = -num, -den
	}
	r := (2*num + den) / (2 * den)
	if r < 1 {
		return 1
	}
	if r > cC-1 {
		return cC - 1
	}
	return r
}

// relPath appends a polyline (or a fill polygon) of n points in relative
// form to d; zero moves are dropped.
func relPath(d *string, xs, ys []int, n int) {
	px, py := xs[0], ys[0]
	out := "M" + num(px) + " " + num(py)
	sep := "l"
	for k := 1; k < n; k++ {
		dx, dy := xs[k]-px, ys[k]-py
		if dx == 0 && dy == 0 {
			continue
		}
		out += sep + num(dx) + " " + num(dy)
		sep = " "
		px, py = xs[k], ys[k]
	}
	*d += out
}

// region is the area where e >= T (above) or e < T (below) on the sheet's own
// cells: row runs of full cells plus one polygon per partial cell, all
// clockwise, in one path. Crossing points are computed from the edge's
// canonical end, so neighbouring cells (and neighbouring sheets) put them in
// the same place.
func region(e []int, T int, above bool) string {
	sb := ""
	var xs, ys [6]int
	for j := 0; j < cG; j++ {
		run := -1
		r0 := (j+1)*span + 1 // lattice index of (0, j)
		r1 := r0 + span      // (0, j+1)
		for i := 0; i <= cG; i++ {
			full := false
			c0, c1, c2, c3 := false, false, false, false
			if i < cG {
				c0 = (e[r0+i] >= T) == above
				c1 = (e[r0+i+1] >= T) == above
				c2 = (e[r1+i+1] >= T) == above
				c3 = (e[r1+i] >= T) == above
				full = c0 && c1 && c2 && c3
			}
			if full && run < 0 {
				run = i
			}
			if !full && run >= 0 {
				sb += "M" + num(run*cC) + " " + num(j*cC) + "h" + num((i-run)*cC) + "v20h" + num((run-i)*cC)
				run = -1
			}
			if i < cG && !full && (c0 || c1 || c2 || c3) {
				cellPoly(&sb, xs[:], ys[:], e[r0+i], e[r0+i+1], e[r1+i+1], e[r1+i], T, above, i, j, c0, c1, c2, c3)
			}
		}
	}
	return sb
}

// regions is region for several levels of one field in one pass: the first
// level is a "below" area (e < T), the others "above" (e >= T).
func regions(e []int, ts []int) []string {
	nt := len(ts)
	sbs := make([]string, nt)
	runs := make([]int, nt)
	var xs, ys [6]int
	for j := 0; j < cG; j++ {
		for q := range runs {
			runs[q] = -1
		}
		r0 := (j+1)*span + 1
		r1 := r0 + span
		for i := 0; i <= cG; i++ {
			var v0, v1, v2, v3, lo, hi int
			if i < cG {
				v0, v1, v2, v3 = e[r0+i], e[r0+i+1], e[r1+i+1], e[r1+i]
				lo, hi = v0, v0
				if v1 < lo {
					lo = v1
				} else if v1 > hi {
					hi = v1
				}
				if v2 < lo {
					lo = v2
				} else if v2 > hi {
					hi = v2
				}
				if v3 < lo {
					lo = v3
				} else if v3 > hi {
					hi = v3
				}
			}
			for q := 0; q < nt; q++ {
				T := ts[q]
				above := q > 0
				full, empty := false, true
				if i < cG {
					if above {
						full, empty = lo >= T, hi < T
					} else {
						full, empty = hi < T, lo >= T
					}
				}
				if full && runs[q] < 0 {
					runs[q] = i
				}
				if !full && runs[q] >= 0 {
					run := runs[q]
					sbs[q] += "M" + num(run*cC) + " " + num(j*cC) + "h" + num((i-run)*cC) + "v20h" + num((run-i)*cC)
					runs[q] = -1
				}
				if i < cG && !full && !empty {
					cellPoly(&sbs[q], xs[:], ys[:], v0, v1, v2, v3, T, above, i, j,
						(v0 >= T) == above, (v1 >= T) == above, (v2 >= T) == above, (v3 >= T) == above)
				}
			}
		}
	}
	return sbs
}

// cellPoly writes the inside part of one partial cell with corner values
// v0..v3 (clockwise from top-left).
func cellPoly(sb *string, xs, ys []int, v0, v1, v2, v3, T int, above bool, i, j int, c0, c1, c2, c3 bool) {
	x, y := i*cC, j*cC
	// edge crossings X0..X3 (top, right, bottom, left), only where the
	// inside test changes along the edge
	x0, y1, x2, y3 := x, y, x, y
	if c0 != c1 {
		x0 += edgeCut(v0, v1, T)
	}
	if c1 != c2 {
		y1 += edgeCut(v1, v2, T)
	}
	if c3 != c2 {
		x2 += edgeCut(v3, v2, T)
	}
	if c0 != c3 {
		y3 += edgeCut(v0, v3, T)
	}
	if (c0 && c2 && !c1 && !c3) || (c1 && c3 && !c0 && !c2) {
		sum := v0 + v1 + v2 + v3
		if (sum >= 4*T) != above {
			// saddle with the centre outside: two corner triangles
			if c0 {
				xs[0], ys[0], xs[1], ys[1], xs[2], ys[2] = x, y, x0, y, x, y3
				relPath(sb, xs, ys, 3)
				xs[0], ys[0], xs[1], ys[1], xs[2], ys[2] = x+cC, y1, x+cC, y+cC, x2, y+cC
				relPath(sb, xs, ys, 3)
				return
			}
			xs[0], ys[0], xs[1], ys[1], xs[2], ys[2] = x0, y, x+cC, y, x+cC, y1
			relPath(sb, xs, ys, 3)
			xs[0], ys[0], xs[1], ys[1], xs[2], ys[2] = x2, y+cC, x, y+cC, x, y3
			relPath(sb, xs, ys, 3)
			return
		}
	}
	n := 0
	if c0 {
		xs[n], ys[n] = x, y
		n++
	}
	if c0 != c1 {
		xs[n], ys[n] = x0, y
		n++
	}
	if c1 {
		xs[n], ys[n] = x+cC, y
		n++
	}
	if c1 != c2 {
		xs[n], ys[n] = x+cC, y1
		n++
	}
	if c2 {
		xs[n], ys[n] = x+cC, y+cC
		n++
	}
	if c2 != c3 {
		xs[n], ys[n] = x2, y+cC
		n++
	}
	if c3 {
		xs[n], ys[n] = x, y+cC
		n++
	}
	if c3 != c0 {
		xs[n], ys[n] = x, y3
		n++
	}
	if n >= 3 {
		relPath(sb, xs, ys, n)
	}
}

// Contour levels: L = lvMin + lvStep*k, k < lvN (-1500 .. 2900 m).
const (
	lvMin  = -1500
	lvStep = 100
	lvN    = 45
)

// isoLines are the chained iso-lines of every drawn level over the sheet and
// its one-cell margin (so strokes that cross an edge are drawn identically by
// both sheets): coast (0 m), bathymetry (every 300 m below 0), minor and
// index (every 500 m) contours. One pass over the cells collects the
// segments of every level a cell spans, in row-major order per level.
func isoLines(e []int) (coast, bathy, minor, major string) {
	type segs struct{ a, b, ax, ay, bx, by []int }
	lv := make([]*segs, lvN)
	for lj := 0; lj < span-1; lj++ {
		for li := 0; li < span-1; li++ {
			k := lj*span + li
			v0, v1, v2, v3 := e[k], e[k+1], e[k+span+1], e[k+span]
			lo, hi := v0, v0
			if v1 < lo {
				lo = v1
			} else if v1 > hi {
				hi = v1
			}
			if v2 < lo {
				lo = v2
			} else if v2 > hi {
				hi = v2
			}
			if v3 < lo {
				lo = v3
			} else if v3 > hi {
				hi = v3
			}
			if hi < lvMin {
				continue
			}
			// levels L with lo < L <= hi
			k0 := lo + 1 - lvMin
			if k0 <= 0 {
				k0 = 0
			} else {
				k0 = (k0 + lvStep - 1) / lvStep
			}
			k1 := (hi - lvMin) / lvStep
			if k1 > lvN-1 {
				k1 = lvN - 1
			}
			x, y := (li-1)*cC, (lj-1)*cC
			id0 := lj*(span-1) + li
			id1 := hn + lj*span + li + 1
			id2 := (lj+1)*(span-1) + li
			id3 := hn + lj*span + li
			for q := k0; q <= k1; q++ {
				T := lvMin + q*lvStep
				if T < 0 && T%300 != 0 {
					continue
				}
				c0, c1, c2, c3 := v0 >= T, v1 >= T, v2 >= T, v3 >= T
				var ids, xs, ys [4]int
				n := 0
				if c0 != c1 {
					ids[n], xs[n], ys[n] = id0, x+edgeCut(v0, v1, T), y
					n++
				}
				if c1 != c2 {
					ids[n], xs[n], ys[n] = id1, x+cC, y+edgeCut(v1, v2, T)
					n++
				}
				if c2 != c3 {
					ids[n], xs[n], ys[n] = id2, x+edgeCut(v3, v2, T), y+cC
					n++
				}
				if c3 != c0 {
					ids[n], xs[n], ys[n] = id3, x, y+edgeCut(v0, v3, T)
					n++
				}
				sg := lv[q]
				if sg == nil {
					sg = &segs{}
					lv[q] = sg
				}
				if n == 2 {
					sg.a, sg.ax, sg.ay = append(sg.a, ids[0]), append(sg.ax, xs[0]), append(sg.ay, ys[0])
					sg.b, sg.bx, sg.by = append(sg.b, ids[1]), append(sg.bx, xs[1]), append(sg.by, ys[1])
					continue
				}
				// saddle: the centre decides which corners are joined (as region)
				if c0 == (v0+v1+v2+v3 >= 4*T) {
					// (top, right) and (bottom, left)
					sg.a, sg.ax, sg.ay = append(sg.a, ids[0], ids[2]), append(sg.ax, xs[0], xs[2]), append(sg.ay, ys[0], ys[2])
					sg.b, sg.bx, sg.by = append(sg.b, ids[1], ids[3]), append(sg.bx, xs[1], xs[3]), append(sg.by, ys[1], ys[3])
				} else {
					// (left, top) and (right, bottom)
					sg.a, sg.ax, sg.ay = append(sg.a, ids[3], ids[1]), append(sg.ax, xs[3], xs[1]), append(sg.ay, ys[3], ys[1])
					sg.b, sg.bx, sg.by = append(sg.b, ids[0], ids[2]), append(sg.bx, xs[0], xs[2]), append(sg.by, ys[0], ys[2])
				}
			}
		}
	}
	ex := make([]int, 2*hn)
	ey := make([]int, 2*hn)
	adj1 := make([]int, 2*hn)
	adj2 := make([]int, 2*hn)
	for k := range adj1 {
		adj1[k], adj2[k] = -1, -1
	}
	var cb, bb, nb, jb string
	for q := 0; q < lvN; q++ {
		sg := lv[q]
		if sg == nil {
			continue
		}
		T := lvMin + q*lvStep
		out := &nb
		switch {
		case T == 0:
			out = &cb
		case T < 0:
			out = &bb
		case T%500 == 0:
			out = &jb
		}
		chain(out, sg.a, sg.b, sg.ax, sg.ay, sg.bx, sg.by, ex, ey, adj1, adj2)
	}
	return cb, bb, nb, jb
}

// chain joins one level's segments (edge ids a[s]-b[s]) into polylines.
func chain(sb *string, a, b, ax, ay, bx, by, ex, ey, adj1, adj2 []int) {
	ns := len(a)
	for s := 0; s < ns; s++ {
		ex[a[s]], ey[a[s]] = ax[s], ay[s]
		ex[b[s]], ey[b[s]] = bx[s], by[s]
		for _, id := range [2]int{a[s], b[s]} {
			if adj1[id] == -1 {
				adj1[id] = s
			} else {
				adj2[id] = s
			}
		}
	}
	used := make([]bool, ns)
	next := func(id int) int {
		if t := adj1[id]; t >= 0 && !used[t] {
			return t
		}
		if t := adj2[id]; t >= 0 && !used[t] {
			return t
		}
		return -1
	}
	xs := make([]int, 0, 64)
	ys := make([]int, 0, 64)
	fwd := make([]int, 0, 64)
	back := make([]int, 0, 64)
	walk := func(cur int, list []int) []int {
		for {
			t := next(cur)
			if t < 0 {
				return list
			}
			used[t] = true
			if a[t] == cur {
				cur = b[t]
			} else {
				cur = a[t]
			}
			list = append(list, cur)
		}
	}
	for s := 0; s < ns; s++ {
		if used[s] {
			continue
		}
		used[s] = true
		// forward from b first (a closed ring is taken whole here), then back
		fwd = walk(b[s], append(fwd[:0], a[s], b[s]))
		back = walk(a[s], back[:0])
		xs, ys = xs[:0], ys[:0]
		for k := len(back) - 1; k >= 0; k-- {
			xs = append(xs, ex[back[k]])
			ys = append(ys, ey[back[k]])
		}
		for _, id := range fwd {
			xs = append(xs, ex[id])
			ys = append(ys, ey[id])
		}
		relPath(sb, xs, ys, len(xs))
	}
	for s := 0; s < ns; s++ {
		adj1[a[s]], adj2[a[s]] = -1, -1
		adj1[b[s]], adj2[b[s]] = -1, -1
	}
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

func nameOf(a, b int) string { return nameA[a][0] + nameB[b][0] }

// gridNo is the grid number of line k (0..4) of sheet column or row c.
func gridNo(c, k int) string { return num(10 + c*4 + k) }

func neighbour(sx, sy int) string {
	if sx < 0 || sy < 0 || sx >= Side || sy >= Side {
		return "—"
	}
	return SheetCode(sy*Side + sx)
}

// SheetSVG is the full sheet of token seed at place p.
func SheetSVG(seed string, cfg Config, p Place) string {
	return sheetSVG(seed, cfg, p, nil)
}

// sheetSVG draws the sheet; mask is the map's landMask when the caller
// already has it (nil: computed here).
func sheetSVG(seed string, cfg Config, p Place, mask []bool) string {
	n := num
	s := survey(seed, cfg, p)
	mi := s.mi
	P := palettes[mi.palette]
	e := s.e
	R := newRNG(seed + "|art") // separate stream: art draws never shift the traits
	na := R.intn(len(nameA))
	nb := R.intn(len(nameB))

	// --- map layers
	emin, emax := 1<<30, -(1 << 30)
	for _, v := range e {
		if v < emin {
			emin = v
		}
		if v > emax {
			emax = v
		}
	}
	bands := regions(e, []int{-300, 0, 500, 1000, 1500})
	deep, land, t1, t2, t3 := bands[0], bands[1], bands[2], bands[3], bands[4]
	coast, bathyS, minorS, majorS := isoLines(e)
	forest := ""
	if emax >= 40 {
		forest = region(woodland(mi, s.sx, s.sy, e), 0, true)
	}

	sb := ""
	sb += (`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 560 660">`)
	sb += (`<defs><clipPath id="mc"><rect width="480" height="480"/></clipPath>` +
		`<filter id="pg" x="0" y="0" width="1" height="1"><feTurbulence type="fractalNoise" baseFrequency=".8" numOctaves="2" seed="` +
		n(s.tile+1) + `"/><feColorMatrix values="0 0 0 0 .35 0 0 0 0 .28 0 0 0 0 .2 0 0 0 -1.6 .78"/></filter>`)
	if t3 != "" {
		sb += (`<pattern id="ph" width="8" height="8" patternUnits="userSpaceOnUse"><path d="M-2 2l4-4M0 8l8-8M6 10l4-4" stroke="` +
			P.hatch + `" stroke-width=".8"/></pattern><path id="hi" d="` + t3 + `"/>`)
	}
	if forest != "" {
		sb += (`<pattern id="pf" width="12" height="12" patternUnits="userSpaceOnUse"><rect width="12" height="12" fill="` +
			P.forest + `"/><path d="M3 2.4a1.8 1.8 0 1 0 .1 0M9 8.4a1.8 1.8 0 1 0 .1 0" fill="` + P.tree + `"/></pattern>`)
	}
	if coast != "" {
		sb += (`<path id="k" d="` + coast + `"/>`)
	}
	sb += (`</defs>`)
	sb += (`<rect width="560" height="660" fill="` + P.paper + `"/><rect width="560" height="660" filter="url(#pg)"/>` +
		`<g transform="translate(40 96)" clip-path="url(#mc)">`)

	// map face
	sb += (`<rect width="480" height="480" fill="` + P.sea + `"/>`)
	if deep != "" {
		sb += (`<path d="` + deep + `" fill="` + P.deep + `"/>`)
	}
	if coast != "" {
		sb += (`<use href="#k" fill="none" stroke="` + P.wl + `" stroke-width="13"/>` +
			`<use href="#k" fill="none" stroke="` + P.sea + `" stroke-width="10"/>` +
			`<use href="#k" fill="none" stroke="` + P.wl + `" stroke-width="6"/>`)
	}
	if land != "" {
		sb += (`<path d="` + land + `" fill="` + P.t0 + `"/>`)
	}
	if forest != "" {
		sb += (`<path d="` + forest + `" fill="url(#pf)"/>`)
	}
	if t1 != "" {
		sb += (`<path d="` + t1 + `" fill="` + P.t1 + `"/>`)
	}
	if t2 != "" {
		sb += (`<path d="` + t2 + `" fill="` + P.t2 + `"/>`)
	}
	if t3 != "" {
		sb += (`<use href="#hi" fill="` + P.t3 + `"/><use href="#hi" fill="url(#ph)"/>`)
	}
	if emax >= 0 {
		dark := region(hillShade(e), 0, true)
		if dark != "" {
			sb += (`<path d="` + dark + `" fill="` + P.ink + `" fill-opacity=".11"/>`)
		}
	}
	if bathyS != "" {
		sb += (`<path d="` + bathyS + `" fill="none" stroke="` + P.bathy + `" stroke-width=".7"/>`)
	}
	if minorS != "" {
		sb += (`<path d="` + minorS + `" fill="none" stroke="` + P.contour + `" stroke-width=".6"/>`)
	}
	if majorS != "" {
		sb += (`<path d="` + majorS + `" fill="none" stroke="` + P.index + `" stroke-width="1.3"/>`)
	}
	if coast != "" {
		sb += (`<use href="#k" fill="none" stroke="` + P.coast + `" stroke-width="1.6"/>`)
	}
	sb += (`<path d="M120 0V480M240 0V480M360 0V480M0 120H480M0 240H480M0 360H480" stroke="` + P.grid +
		`" stroke-opacity=".22" stroke-width=".7"/>`)

	// soundings: a global choice, so they never depend on the token
	snd := ""
	for j := 2; j <= cG-2; j++ {
		for i := 2; i <= cG-2; i++ {
			v := e[at(i, j)]
			if v < -80 && hash32(mi.sh, 9, s.sx*cG+i+off, s.sy*cG+j+off)%29 == 0 {
				snd += (`<text x="` + n(i*cC) + `" y="` + n(j*cC+3) + `">` + n(-v) + `</text>`)
			}
		}
	}
	if snd != "" {
		sb += (`<g font-family="Georgia, serif" font-size="8" font-style="italic" text-anchor="middle" fill="` + P.bathy + `">` +
			snd + `</g>`)
	}

	// token marks
	marks := ""
	if s.peak >= 0 {
		x, y := (s.peak%span-1)*cC, (s.peak/span-1)*cC
		marks += `<path d="M` + n(x) + " " + n(y-6) + `l6 10h-12z" fill="` + P.ink + `"/><text x="` + n(x+9) + `" y="` + n(y+4) +
			`" font-size="10">` + n(e[s.peak]) + `</text>`
	}
	sheetName := ""
	if s.settle >= 0 {
		i, j := s.settle%span-1, s.settle/span-1
		x, y := i*cC, j*cC
		sheetName = nameOf(na, nb)
		cnt := 2
		switch s.settleKind {
		case "Village":
			cnt = 4
		case "Port":
			cnt = 5
		case "Town":
			cnt = 7
		}
		blocks := ""
		for k := 0; k < cnt; k++ {
			bx := x + R.between(-9, 5)
			by := y + R.between(-8, 4)
			w := R.between(3, 6)
			blocks += "M" + n(bx) + " " + n(by) + "h" + n(w) + "v" + n(w) + "h" + n(-w)
		}
		if s.settleKind == "Port" {
			// pier towards the first neighbouring sea point (E, S, W, N)
			dx, dy := 0, -1
			if e[at(i+1, j)] < 0 {
				dx, dy = 1, 0
			} else if e[at(i, j+1)] < 0 {
				dy = 1
			} else if e[at(i-1, j)] < 0 {
				dx, dy = -1, 0
			}
			marks += `<path d="M` + n(x) + " " + n(y) + "l" + n(dx*16) + " " + n(dy*16) + "m" + n(dy*5) + " " + n(dx*5) + "l" +
				n(-dy*10) + " " + n(-dx*10) + `" fill="none" stroke="` + P.ink + `" stroke-width="1.6"/>`
		}
		if s.settleKind == "Town" {
			marks += `<circle cx="` + n(x) + `" cy="` + n(y) + `" r="15" fill="none" stroke="` + P.red +
				`" stroke-width=".8" stroke-dasharray="2 2"/>`
		}
		marks += `<path d="` + blocks + `" fill="` + P.red + `"/>`
		if x <= 330 {
			marks += `<text x="` + n(x+13) + `" y="` + n(y+4) + `" font-size="12" font-style="italic">` + sheetName + `</text>`
		} else {
			marks += `<text x="` + n(x-13) + `" y="` + n(y+4) + `" font-size="12" font-style="italic" text-anchor="end">` + sheetName + `</text>`
		}
	} else if s.terrain == "Open Sea" {
		sheetName = nameA[na][0] + " Denizi"
	} else {
		sheetName = nameOf(na, nb) + " Dağları"
	}
	if s.markAt >= 0 {
		x, y := (s.markAt%span-1)*cC, (s.markAt/span-1)*cC
		switch s.mark {
		case lmLighthouse:
			marks += `<path d="M` + n(x) + " " + n(y-15) + "v30M" + n(x-15) + " " + n(y) + "h30M" + n(x-10) + " " + n(y-10) + "l20 20M" +
				n(x+10) + " " + n(y-10) + `l-20 20" stroke="` + P.red + `" stroke-opacity=".7"/><circle cx="` + n(x) + `" cy="` + n(y) +
				`" r="4" fill="` + P.red + `" stroke="` + P.paper + `"/>`
		case lmWreck:
			marks += `<path d="M` + n(x-12) + " " + n(y) + "h24M" + n(x) + " " + n(y-8) + "v16M" + n(x-6) + " " + n(y-5) + "v10M" +
				n(x+6) + " " + n(y-5) + `v10" stroke="` + P.ink + `" stroke-width="1.6"/>`
		case lmCastle:
			marks += `<path d="M` + n(x-9) + " " + n(y+7) + `v-12h4v4h3v-4h4v4h3v-4h4v12z" fill="` + P.ink + `"/>`
		case lmRuins:
			marks += `<path d="M` + n(x-7) + " " + n(y+6) + "h14M" + n(x-5) + " " + n(y+6) + "v-9M" + n(x) + " " + n(y+6) + "v-12M" +
				n(x+5) + " " + n(y+6) + `v-6" stroke="` + P.ink + `" stroke-width="1.4" stroke-dasharray="3 1"/>`
		case lmWindmill:
			marks += `<path d="M` + n(x-7) + " " + n(y-7) + "l14 14M" + n(x+7) + " " + n(y-7) + `l-14 14" stroke="` + P.ink +
				`" stroke-width="1.4"/><circle cx="` + n(x) + `" cy="` + n(y) + `" r="2.6" fill="` + P.paper + `" stroke="` + P.ink + `"/>`
		default:
			if s.settle >= 0 {
				marks += `<path d="M` + n((s.settle%span-1)*cC) + " " + n((s.settle/span-1)*cC) + "L" + n(x) + " " + n(y) +
					`" fill="none" stroke="` + P.red + `" stroke-width="1.2" stroke-dasharray="4 4"/>`
			}
			marks += `<path d="M` + n(x-7) + " " + n(y-7) + "l14 14M" + n(x+7) + " " + n(y-7) + `l-14 14" stroke="` + P.red +
				`" stroke-width="3" stroke-linecap="round"/>`
		}
	}
	if s.terrain == "Open Sea" && R.intn(3) == 0 {
		// a compass rose on some of the empty water
		x := R.between(6, 18) * cC
		y := R.between(6, 18) * cC
		marks += `<g transform="translate(` + n(x) + " " + n(y) + `)" fill="` + P.ink2 + `" fill-opacity=".45"><circle r="22" fill="none" stroke="` +
			P.ink2 + `" stroke-opacity=".6"/><path d="M0-34l3 27 11-21-7 18 27 10-27 3 21 11-18-7-10 27-3-27-11 21 7-18-27-10 27-3-21-11 18 7z"/></g>`
	}
	if marks != "" {
		sb += (`<g font-family="Georgia, serif" fill="` + P.ink + `">` + marks + `</g>`)
	}
	sb += (`</g>`)

	// --- the sheet: neatline and the alternating kilometre border
	sb += (`<path d="M40 92.5h120m120 0h120M523.5 96v120m0 120v120M40 579.5h120m120 0h120M36.5 96v120m0 120v120" stroke="` + P.ink +
		`" stroke-width="5"/><rect x="33.5" y="89.5" width="493" height="493" fill="none" stroke="` + P.ink + `" stroke-width=".8"/>` +
		`<rect x="39.5" y="95.5" width="481" height="481" fill="none" stroke="` + P.ink + `" stroke-width=".8"/>`)
	sx, sy := s.sx, s.sy
	gridNos := ""
	for k := 0; k <= 4; k++ {
		if k == 2 {
			continue
		}
		q := k * 120
		gridNos += `<text x="` + n(MapX+q) + `" y="` + n(MapY-10) + `">` + gridNo(sx, k) + `</text>` +
			`<text x="` + n(MapX+q) + `" y="` + n(MapY+cM+17) + `">` + gridNo(sx, k) + `</text>` +
			`<text x="` + n(MapX-10) + `" y="` + n(MapY+q+3) + `" text-anchor="end">` + gridNo(Side-1-sy, 4-k) + `</text>` +
			`<text x="` + n(MapX+cM+10) + `" y="` + n(MapY+q+3) + `" text-anchor="start">` + gridNo(Side-1-sy, 4-k) + `</text>`
	}
	sb += (`<g font-family="Georgia, serif" fill="` + P.ink + `">` +
		`<text x="40" y="42" font-size="19" letter-spacing="3">` + nameA[mi.nameA][1] + nameB[mi.nameB][1] + `</text>` +
		`<text x="40" y="64" font-size="12" fill="` + P.ink2 + `">` + sheetName + ` · 1:25.000</text>` +
		`<text x="444" y="66" font-size="28" text-anchor="end">` + SheetCode(s.tile) + `</text>` +
		`<g font-size="10" text-anchor="middle"><text x="280" y="` + n(MapY-10) + `">` + neighbour(sx, sy-1) + `</text>` +
		`<text x="280" y="` + n(MapY+cM+17) + `">` + neighbour(sx, sy+1) + `</text>` +
		`<text x="` + n(MapX-17) + `" y="` + n(MapY+243) + `">` + neighbour(sx-1, sy) + `</text>` +
		`<text x="` + n(MapX+cM+17) + `" y="` + n(MapY+243) + `">` + neighbour(sx+1, sy) + `</text></g>` +
		`<g font-size="8" fill="` + P.ink2 + `" text-anchor="middle">` + gridNos + `</g>`)
	// legend: hypsometric steps, contour interval, scale and north
	sb += (`<g transform="translate(40 604)"><rect width="22" height="8" fill="` + P.deep + `"/><rect x="22" width="22" height="8" fill="` +
		P.sea + `"/><rect x="44" width="22" height="8" fill="` + P.t0 + `"/><rect x="66" width="22" height="8" fill="` + P.t1 +
		`"/><rect x="88" width="22" height="8" fill="` + P.t2 + `"/><rect x="110" width="22" height="8" fill="` + P.t3 +
		`"/><rect width="132" height="8" fill="none" stroke="` + P.ink + `" stroke-width=".6"/>` +
		`<g font-size="7" text-anchor="middle" fill="` + P.ink2 + `"><text x="22" y="18">-300</text><text x="44" y="18">0</text>` +
		`<text x="66" y="18">500</text><text x="88" y="18">1000</text><text x="110" y="18">1500 m</text></g>` +
		`<text y="38" font-size="9" fill="` + P.ink2 + `">Eş yükselti aralığı 100 m · kalın eğri 500 m</text></g>` +
		`<g transform="translate(400 604)"><path d="M0 0h30v6h-30zM60 0h30v6h-30z" fill="` + P.ink + `"/><rect width="120" height="6" fill="none" stroke="` +
		P.ink + `" stroke-width=".8"/><g font-size="8" text-anchor="middle"><text y="18">0</text><text x="60" y="18">500</text>` +
		`<text x="120" y="18">1 km</text></g></g>` +
		`<g transform="translate(330 620)"><path d="M0-18l7 20-7-6-7 6z"/><text y="14" font-size="10" text-anchor="middle">K</text></g></g>`)

	// index map: the whole collection, one sample per sheet, this sheet in red
	if mask == nil {
		mask = landMask(mi)
	}
	md := ""
	for b := 0; b < Side; b++ {
		run := -1
		for a := 0; a <= Side; a++ {
			ld := a < Side && mask[b*Side+a]
			if ld && run < 0 {
				run = a
			}
			if !ld && run >= 0 {
				md += ("M" + n(run*4) + " " + n(b*4) + "h" + n((a-run)*4) + "v4h" + n((run-a)*4))
				run = -1
			}
		}
	}
	sb += (`<g transform="translate(456 14)"><rect width="64" height="64" fill="` + P.sea + `"/>`)
	if md != "" {
		sb += (`<path d="` + md + `" fill="` + P.t1 + `"/>`)
	}
	sb += (`<rect x="` + n(sx*4) + `" y="` + n(sy*4) + `" width="4" height="4" fill="` + P.red +
		`"/><rect width="64" height="64" fill="none" stroke="` + P.ink + `" stroke-width=".8"/></g>`)
	sb += (`</svg>`)
	return sb
}
