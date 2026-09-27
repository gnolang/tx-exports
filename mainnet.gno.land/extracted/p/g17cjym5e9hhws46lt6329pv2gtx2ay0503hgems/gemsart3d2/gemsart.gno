// Package gemsartfab: on-chain SVG generator for the "gem in a ring"
// collection -- the "fab" iteration of gemsart2, re-lit to read as a
// transparent, polished crystal instead of a flat matte cutout. Same
// geometry, same traits, same cascade schedule; what changed is only
// how a faceted stone is painted (see the gem shapes section). Two hard
// constraints shaped every choice there: bytes per token (a token is
// re-rendered on every TokenURI/Render read and shipped inline) and
// WebKit rendering cost -- this project has twice fixed real Safari
// slowdowns by removing SVG <filter>s and SMIL, so the new look uses
// only static gradients, paths, one inherited stroke, and CSS opacity
// keyframes. Nothing else.
//
// Originally ported from the Python prototype used to design and
// approve the first look. Every function here is pure — no state reads
// beyond its own stone/color tables — so a token's full image can be
// recomputed on any read (TokenURI/Render) instead of being stored as a
// precomputed blob.
//
// A separate deploy from the nftminter realm that imports it (not one
// combined package as originally designed) -- gnomcp's own gno_addpkg
// tool hardcodes a 10,000,000 ugnot max-deposit ceiling per deploy call
// with no override, and the combined source (~175KB) needs ~17.6M. Each
// half fits under that ceiling deployed separately. The public surface
// below (ShapeNames/MetalNames/RenderTokenSVG/StoneForChain/
// ColorPaletteSize, plus SetStoneForChain/AddStoneColor/StoneNamesCSV/
// ColorPaletteCSV/MetalToneHex) exists specifically so nftminter.gno can
// still reach everything it needs across that package boundary.
//
// This is the architecture change requested explicitly, back when this
// was still one file: instead of the owner precomputing and storing a
// full ~7.6KB image string per token, this package's shared generator
// code is stored ONCE, and each token only needs a handful of small
// trait selections (see traitPreset in nftminter.gno) — the image is
// assembled from those on demand. Storage cost stops scaling with token
// count; it's dominated by this package's own one-time deployment cost
// instead.
package gemsart3d2

import (
	"crypto/sha256"
	"math"
	"strings"

	"gno.land/p/nt/ufmt/v0"
)

const (
	canvasW, canvasH = 170.0, 170.0
	subjX, subjY     = 85.0, 78.0
)

/* ------------------------------ number/color formatting ------------------------------ */

// fnum formats a float to 2 decimal places without depending on ufmt
// supporting %f/%g (uncertain in this environment) — plain integer math
// and %d instead. Zero-pads the fraction manually rather than via
// "%02d": ufmt.Sprintf does NOT implement width/zero-pad flags (confirmed
// empirically -- Sprintf("%d.%02d", 1, 9) returns "1.9", not "1.09"), so
// relying on "%02d" silently corrupted any value whose hundredths digit
// rounded to 1-9 (e.g. 1.09 rendered as "1.9", a ~10x error) throughout
// this whole file, since every coordinate/radius/angle goes through this
// one function.
// itoa writes a non-negative integer's digits. Every number in a token
// goes through here: ufmt.Sprintf is general-purpose and, on-chain, most
// of a render's gas went to formatting coordinates with it.
func itoa(v int64) string {
	if v == 0 {
		return "0"
	}
	neg := v < 0
	if neg {
		v = -v
	}
	var b [20]byte
	i := len(b)
	for v > 0 {
		i--
		b[i] = byte('0' + v%10)
		v /= 10
	}
	if neg {
		i--
		b[i] = '-'
	}
	return string(b[i:])
}

// fnum is the compact form every emitter uses: two decimals at most,
// trailing zeros and a leading "0" dropped ("85.00" -> "85", "0.45" ->
// ".45"). Valid in SVG attributes and CSS alike; a quarter of a token's
// bytes were padding before this.
func fnum(v float64) string { return cnum(v) }

func fnumPad(v float64) string {
	neg := v < 0
	if neg {
		v = -v
	}
	scaled := int64(v*100 + 0.5)
	whole := scaled / 100
	frac := scaled % 100
	fracStr := itoa(frac)
	if frac < 10 {
		fracStr = "0" + fracStr
	}
	s := itoa(whole) + "." + fracStr
	if neg {
		return "-" + s
	}
	return s
}

// fnum1 is fnum at one decimal -- for keyframe percentages, where the
// second decimal is a fraction of a frame and only costs bytes (the
// keyframe CSS is the largest slice of every token).
// cnum is fnum without padding: trailing zeros and a leading "0" before
// the point are dropped ("0.45" -> ".45", "85.00" -> "85"). Used by the
// ring and plate markup, which is emitted on every token read.
func cnum(v float64) string {
	s := fnumPad(v)
	if strings.Contains(s, ".") {
		s = strings.TrimRight(strings.TrimRight(s, "0"), ".")
	}
	if strings.HasPrefix(s, "0.") {
		s = s[1:]
	} else if strings.HasPrefix(s, "-0.") {
		s = "-" + s[2:]
	}
	return s
}

func fnum1(v float64) string {
	neg := v < 0
	if neg {
		v = -v
	}
	scaled := int64(v*10 + 0.5)
	s := itoa(scaled/10) + "." + itoa(scaled%10)
	if neg {
		return "-" + s
	}
	return s
}

// pctnum formats a float already meant as a percentage (2 decimals, no
// clamping — callers clamp first where it matters).
func pctnum(v float64) string { return fnum(v) }

func hexToRGB(hex string) (int, int, int) {
	h := hex
	if len(h) > 0 && h[0] == '#' {
		h = h[1:]
	}
	r := hexByte(h[0:2])
	g := hexByte(h[2:4])
	b := hexByte(h[4:6])
	return r, g, b
}

func hexByte(s string) int {
	v := 0
	for i := 0; i < len(s); i++ {
		c := s[i]
		var d int
		switch {
		case c >= '0' && c <= '9':
			d = int(c - '0')
		case c >= 'a' && c <= 'f':
			d = int(c-'a') + 10
		case c >= 'A' && c <= 'F':
			d = int(c-'A') + 10
		}
		v = v*16 + d
	}
	return v
}

func rgbToHex(r, g, b int) string {
	return "#" + hexDigit2(r) + hexDigit2(g) + hexDigit2(b)
}

func hexDigit2(v int) string {
	if v < 0 {
		v = 0
	}
	if v > 255 {
		v = 255
	}
	const digits = "0123456789abcdef"
	return string(digits[v/16]) + string(digits[v%16])
}

func clampByte(v float64) int {
	iv := int(v)
	if iv < 0 {
		return 0
	}
	if iv > 255 {
		return 255
	}
	return iv
}

// lighten blends hex toward white by amt (0-1) — used so a neon glow's
// core reads as genuinely brighter than its own base color, not just a
// higher-opacity version of the same tone.
func lighten(hex string, amt float64) string {
	r, g, b := hexToRGB(hex)
	nr := clampByte(float64(r) + (255-float64(r))*amt)
	ng := clampByte(float64(g) + (255-float64(g))*amt)
	nb := clampByte(float64(b) + (255-float64(b))*amt)
	return rgbToHex(nr, ng, nb)
}

// mixHex blends hex toward target by amt (0-1) — used to soften a hard
// two-color gradient stop into an in-between tone, e.g. the label bar's
// muted echo of the ring's own multi-band highlight/shadow swing.
func mixHex(hex, target string, amt float64) string {
	r1, g1, b1 := hexToRGB(hex)
	r2, g2, b2 := hexToRGB(target)
	nr := clampByte(float64(r1) + float64(r2-r1)*amt)
	ng := clampByte(float64(g1) + float64(g2-g1)*amt)
	nb := clampByte(float64(b1) + float64(b2-b1)*amt)
	return rgbToHex(nr, ng, nb)
}

// hueRotate turns hex's hue by deg degrees -- the exact matrix SVG's
// feColorMatrix type="hueRotate" applies, done here once at render so
// no live filter is ever needed. Used for colour zoning: a real crystal
// is not one hue, it drifts a few degrees from facet to facet.
func hueRotate(hex string, deg float64) string {
	c, sn := math.Cos(deg*math.Pi/180), math.Sin(deg*math.Pi/180)
	r, g, b := hexToRGB(hex)
	fr, fg, fb := float64(r), float64(g), float64(b)
	nr := (0.213+c*0.787-sn*0.213)*fr + (0.715-c*0.715-sn*0.715)*fg + (0.072-c*0.072+sn*0.928)*fb
	ng := (0.213-c*0.213+sn*0.143)*fr + (0.715+c*0.285+sn*0.140)*fg + (0.072-c*0.072-sn*0.283)*fb
	nb := (0.213-c*0.213-sn*0.787)*fr + (0.715-c*0.715+sn*0.715)*fg + (0.072+c*0.928+sn*0.072)*fb
	return rgbToHex(clampByte(nr), clampByte(ng), clampByte(nb))
}

// shadeSeries returns n shades of hex scaled between lo and hi brightness
// — the palette a faceted gem's individual facets pick from so adjacent
// triangles/quads read as catching light differently.
func shadeSeries(hex string, n int, lo, hi float64) []string {
	r, g, b := hexToRGB(hex)
	out := make([]string, n)
	for i := 0; i < n; i++ {
		t := lo
		if n > 1 {
			t = lo + (hi-lo)*float64(i)/float64(n-1)
		}
		out[i] = rgbToHex(clampByte(float64(r)*t), clampByte(float64(g)*t), clampByte(float64(b)*t))
	}
	return out
}

/* --------------------------------- tiny deterministic PRNG --------------------------------- */

// prng is a small deterministic generator seeded from a string, used only
// for per-piece COSMETIC animation timing (glow phase/duration, motion
// phases/rotation degree) — never for which trait combination a piece
// has (that's traitPreset, randomly assembled by nftminter.gno's own
// separate PRNG in randomTraitPreset, not curated and not this one).
// Determinism here doesn't weaken the anti-sniping design at all: knowing
// in advance that a glow pulses at 2.1s instead of 1.9s isn't a trait
// anyone would snipe for.
type prng struct {
	seed string
	n    int
}

func newPRNG(seed string) *prng { return &prng{seed: seed} }

func (p *prng) next() uint64 {
	p.n++
	material := p.seed + ":" + itoa(int64(p.n)) // same bytes as "%s:%d"
	sum := sha256.Sum256([]byte(material))
	var v uint64
	for i := 0; i < 8; i++ {
		v = v<<8 | uint64(sum[i])
	}
	return v
}

func (p *prng) floatIn(lo, hi float64) float64 {
	frac := float64(p.next()%1000000) / 1000000.0
	return lo + frac*(hi-lo)
}

func (p *prng) intn(n int) int {
	if n <= 1 {
		return 0
	}
	return int(p.next() % uint64(n))
}

/* ------------------------------------ path helpers ------------------------------------ */

type pt struct{ x, y float64 }

func polyPath(pts []pt) string {
	s := "M"
	for i, p := range pts {
		if i > 0 {
			s += " L"
		}
		s += fnum(p.x) + "," + fnum(p.y)
	}
	return s + " Z"
}

func polygonPoints(pts []pt) string {
	s := ""
	for i, p := range pts {
		if i > 0 {
			s += " "
		}
		s += fnum(p.x) + "," + fnum(p.y)
	}
	return s
}

/* ------------------------------------ gem shapes ------------------------------------ */
// Stones are real 3D cuts, not flat diagrams. Each cut is a small solid
// (table, crown break, girdle, pavilion, culet) built from rings of
// vertices on the cut's own outline, tilted toward the viewer and
// projected. Every facet is shaded from its actual surface normal under
// one light, the pavilion's back facets are drawn first and show through
// the front ones, and the table is a window onto them -- which is what
// finally makes the stone read as transparent: there is now something
// behind it to see. Everything is still flat solid fills (one body-glow
// gradient per stone): the realism comes from geometry and normals, not
// from paint effects, so Safari pays nothing extra for it.
//
// Bytes are budgeted, this runs on every token read: relative path
// coordinates at one decimal, 3-digit hex colours (a facet is one flat
// tone, 12 bits is plenty), shared attributes hoisted onto groups, the
// girdle as ONE stroke, hidden crown back-faces never emitted, and the
// fire capped at ~14 overlays per stone however many facets a cut has.

type gstop struct {
	pct   float64
	color string
	op    float64
}

// gramp is a linear colour ramp in absolute coordinates, sampled by
// projection -- used for the spectral fire so each facet flashes the
// band of the spectrum it sits in.
type gramp struct {
	x1, y1, x2, y2 float64
	stops          []gstop
}

func (g gramp) sample(px, py float64) (string, float64) {
	dx, dy := g.x2-g.x1, g.y2-g.y1
	t := ((px-g.x1)*dx + (py-g.y1)*dy) / (dx*dx + dy*dy) * 100
	if t < 0 {
		t = 0
	}
	if t > 100 {
		t = 100
	}
	for i := 1; i < len(g.stops); i++ {
		if t <= g.stops[i].pct {
			a, b := g.stops[i-1], g.stops[i]
			f := (t - a.pct) / (b.pct - a.pct)
			return mixHex(a.color, b.color, f), a.op + (b.op-a.op)*f
		}
	}
	last := g.stops[len(g.stops)-1]
	return last.color, last.op
}

func centroid(poly []pt) (float64, float64) {
	cx, cy := 0.0, 0.0
	for _, p := range poly {
		cx += p.x
		cy += p.y
	}
	return cx / float64(len(poly)), cy / float64(len(poly))
}

// facetStyle is what the fire needs from the stone: each lit-capable
// facet's 2D centroid in draw order, the spectral ramp, and the stone's
// optical profile.
type facetStyle struct {
	flash    gramp
	ringCent []pt
	prof     fireProfile
	zone     *prng // per-facet hue drift and shade jitter, seeded per token
	stone    string // which crystal habit a Raw Crystal takes
	// thumb: a list thumbnail -- skips what does not read at thumbnail
	// size (fire flashes, rock relighting, table reflections) to cut
	// render gas. The stone, its facets and colours are identical.
	thumb bool
	// glints: star sparkles applyCascade builds, drawn above everything
	// else on the stone (after the table reflections) so nothing dims them.
	glints string
}

// fireProfile is how a stone's optics differ by what it is. Dispersion
// is a property of the material: colourless stones throw strong
// spectral fire, sapphire much less, topaz less still. shadow is what a
// facet darkens toward; bodyMix/neutral rebuild the working base for
// stones whose palette hex is near-white (see fireProfileFor).
type fireProfile struct {
	sat, hit  float64
	pinpoints int
	shadow    string
	bodyMix   float64
	neutral   string
}

func fireProfileFor(stone, colorName string) fireProfile {
	if stone == "Diamond" {
		// dispersion 0.044, the highest of any stone here: every colour
		// throws strong spectral fire, the colourless one most of all.
		// Black diamond is opaque: shine only, almost no fire.
		switch colorName {
		case "Colorless":
			// a light body mix: a diamond is a contrast of near-white
			// and near-black facets, not a mid-grey (0.5 read as slate)
			return fireProfile{1.0, 0.85, 5, "#0d1222", 0.12, "#f4f7fc"}
		case "Black":
			return fireProfile{0.15, 0.35, 1, "#000000", 0, ""}
		}
		return fireProfile{0.95, 0.7, 4, "#0b0d18", 0, ""}
	}
	if stone == "Quartz" {
		// dispersion 0.013, the lowest here: faint fire, mostly glassy shine
		if colorName == "Rock Crystal" {
			return fireProfile{0.4, 0.6, 3, "#141a2c", 0.25, "#e8edf4"}
		}
		return fireProfile{0.35, 0.5, 3, "#000000", 0, ""}
	}
	if colorName == "Colorless" {
		return fireProfile{1.0, 0.7, 4, "#141a2c", 0.55, "#dfe4ee"}
	}
	if colorName == "White" {
		return fireProfile{0.85, 0.6, 3, "#7d86a0", 0, ""}
	}
	if colorName == "Crystal" {
		return fireProfile{1.0, 0.78, 4, "#141a2c", 0.3, "#e4e9f2"}
	}
	if stone == "Topaz" {
		return fireProfile{0.5, 0.5, 3, "#000000", 0, ""}
	}
	return fireProfile{0.7, 0.5, 3, "#000000", 0, ""}
}

const fireZoneDeg = 7.0

// rgbI is a colour as three 0-255 ints. The facet shading works on these
// instead of "#rrggbb" strings: parsing and re-formatting a hex string at
// every mix was a large share of a render's gas. Each op rounds exactly
// as its hex-string twin does (clampByte per channel), so the output is
// byte-identical.
type rgbI struct{ r, g, b int }

func toRGBI(hex string) rgbI { r, g, b := hexToRGB(hex); return rgbI{r, g, b} }

func (c rgbI) hex() string { return rgbToHex(c.r, c.g, c.b) }

func mixI(a, b rgbI, amt float64) rgbI {
	return rgbI{
		clampByte(float64(a.r) + float64(b.r-a.r)*amt),
		clampByte(float64(a.g) + float64(b.g-a.g)*amt),
		clampByte(float64(a.b) + float64(b.b-a.b)*amt),
	}
}

func hueRotateI(x rgbI, deg float64) rgbI {
	c, sn := math.Cos(deg*math.Pi/180), math.Sin(deg*math.Pi/180)
	fr, fg, fb := float64(x.r), float64(x.g), float64(x.b)
	nr := (0.213+c*0.787-sn*0.213)*fr + (0.715-c*0.715-sn*0.715)*fg + (0.072-c*0.072+sn*0.928)*fb
	ng := (0.213-c*0.213+sn*0.143)*fr + (0.715+c*0.285+sn*0.140)*fg + (0.072-c*0.072-sn*0.283)*fb
	nb := (0.213-c*0.213-sn*0.787)*fr + (0.715-c*0.715+sn*0.715)*fg + (0.072+c*0.928+sn*0.072)*fb
	return rgbI{clampByte(nr), clampByte(ng), clampByte(nb)}
}

func hex3I(x rgbI) string {
	d := "0123456789abcdef"
	q := func(v int) byte { return d[(v+8)*15/255%16] }
	return "#" + string([]byte{q(x.r), q(x.g), q(x.b)})
}

var whiteI = rgbI{255, 255, 255}

func darken(hex, shadow string, amt float64) string {
	if amt > 0.95 {
		amt = 0.95
	}
	return mixHex(hex, shadow, amt)
}

const prismFlash = true

func flashRamp(ext, sat float64) gramp {
	r := gramp{x1: subjX - ext, y1: subjY - ext, x2: subjX + ext, y2: subjY + ext}
	if !prismFlash {
		r.stops = []gstop{{0, "#ffffff", 1}, {100, "#ffffff", 0.25}}
		return r
	}
	r.stops = []gstop{
		{0, "#ffffff", 1}, {14, "#ff4040", 0.95}, {28, "#ff9a1f", 0.95}, {42, "#ffe81f", 0.9},
		{56, "#35ff7a", 0.85}, {70, "#22ccff", 0.8}, {84, "#5566ff", 0.75}, {100, "#c04dff", 0.7},
	}
	for i := range r.stops {
		r.stops[i].color = mixHex(r.stops[i].color, "#ffffff", 1-sat)
	}
	return r
}

/* ---- tiny vector maths ---- */

type v3 struct{ x, y, z float64 }

func vsub(a, b v3) v3       { return v3{a.x - b.x, a.y - b.y, a.z - b.z} }
func vdot(a, b v3) float64  { return a.x*b.x + a.y*b.y + a.z*b.z }
func vcross(a, b v3) v3     { return v3{a.y*b.z - a.z*b.y, a.z*b.x - a.x*b.z, a.x*b.y - a.y*b.x} }
func vscale(a v3, k float64) v3 { return v3{a.x * k, a.y * k, a.z * k} }
func vnorm(a v3) v3 {
	l := math.Sqrt(vdot(a, a))
	if l == 0 {
		return a
	}
	return v3{a.x / l, a.y / l, a.z / l}
}

func sgnPow(v, e float64) float64 {
	if v < 0 {
		return -math.Pow(-v, e)
	}
	return math.Pow(v, e)
}

/* ---- outlines: a closed curve t in [0,1) -> (x, y) in [-1,1] ---- */

type outlineFn func(t float64) (float64, float64)

func circleOutline(t float64) (float64, float64) {
	a := 2 * math.Pi * t
	return math.Cos(a), math.Sin(a)
}

// superOutline is a superellipse: p=2 is an ellipse, higher p squares
// the shoulders -- a cushion.
func superOutline(p float64) outlineFn {
	return func(t float64) (float64, float64) {
		a := 2 * math.Pi * t
		return sgnPow(math.Cos(a), 2/p), sgnPow(math.Sin(a), 2/p)
	}
}

// polyOutline walks a polygon by vertex index: t=k/len lands exactly on
// vertex k, so step cuts keep their true corners at any ring size.
func polyOutline(vs []pt) outlineFn {
	return func(t float64) (float64, float64) {
		n := len(vs)
		f := t * float64(n)
		k := int(math.Floor(f))
		fr := f - float64(k)
		a := vs[((k%n)+n)%n]
		b := vs[(((k+1)%n)+n)%n]
		return a.x + (b.x-a.x)*fr, a.y + (b.y-a.y)*fr
	}
}

// octagon is a rectangle hw x hh with its corners cut by c.
func octagon(hw, hh, c float64) []pt {
	return []pt{
		{hw - c, hh}, {-hw + c, hh}, {-hw, hh - c}, {-hw, -hh + c},
		{-hw + c, -hh}, {hw - c, -hh}, {hw, -hh + c}, {hw, hh - c},
	}
}

func pearOutline(t float64) (float64, float64) {
	a := 2 * math.Pi * t
	c := math.Cos(a)
	return c*0.92 + 0.08, 0.7 * math.Sin(a) * (1 - 0.46*c)
}

func marquiseOutline(t float64) (float64, float64) {
	a := 2 * math.Pi * t
	return math.Cos(a), 0.52 * sgnPow(math.Sin(a), 1.35)
}

// heartOutline is a heart CUT, not a valentine: full rounded lobes, a
// shallow notch (~14% of the length; the valentine curve's 24% read as a
// drawing), gently convex sides and a clean point, as a heart-cut
// diamond is. Notch at t=0 (far side, +y), point at t=.5 (near side),
// normalised to [-1,1]; the cut's rx/ry set its width-to-length ratio
// (real heart cuts run 0.9-1.1).
func heartOutline(t float64) (float64, float64) {
	a := 2 * math.Pi * t
	sn := math.Sin(a)
	y := (13*math.Cos(a) - 4*math.Cos(2*a) - 1.4*math.Cos(3*a) - 0.5*math.Cos(4*a)) / 17
	return 0.88*sn*sn*sn + 0.12*sn, (y + 0.1576) / 0.7894
}

func trillionOutline(t float64) (float64, float64) {
	vs := []pt{{0, 1}, {-0.866, -0.5}, {0.866, -0.5}}
	f := t * 3
	k := int(math.Floor(f))
	fr := f - float64(k)
	a, b := vs[((k%3)+3)%3], vs[(((k+1)%3)+3)%3]
	bulge := 1 + 0.16*math.Sin(math.Pi*fr)
	return (a.x + (b.x-a.x)*fr) * bulge, (a.y + (b.y-a.y)*fr) * bulge
}

/* ---- the cuts ---- */

// cutSpec is one cut: its outline, how many table vertices it has, and
// whether it is a brilliant (triangular/kite facets radiating from the
// table, girdle at twice the table's vertex count) or a step cut
// (concentric rows of long rectangular facets).
type cutSpec struct {
	n         int
	brilliant bool
	outline   outlineFn
	rx, ry    float64
}

// ShapeNames is the faceted-cut vocabulary, in index order. Heart, Rose
// Cut and Raw Crystal were dropped from the first 3D pass and are back
// (appended, so the first ten keep their indexes), each only on the
// stones that are really sold that way -- see CutsForStone. Raw Crystal
// is the stone's own natural crystal, not a cut: an octahedron for
// diamond, a hexagonal barrel for sapphire, a prism with a pyramid tip
// and a flat cleavage break for topaz (buildRaw).
var ShapeNames = []string{
	"Round Brilliant", "Oval", "Cushion", "Emerald Cut", "Asscher",
	"Radiant", "Princess Cut", "Pear", "Marquise", "Trillion",
	"Heart", "Rose Cut", "Raw Crystal",
}

const (
	shapeHeart = 10
	shapeRose  = 11
	shapeRaw   = 12
)

// stoneScale enlarges every stone and pearl inside the ring opening:
// 1.22 (the first gemsart3d2 pass) crowded the ring; 0.98 was 4/5 of
// that, and 0.78 is 4/5 again (2026-09-26, per request). Then 1.02 with
// the ring drawn 10% larger, and finally 1.21 with the ring 16% larger
// (size "D+" of the size trials, chosen 2026-09-26; see ringScale).
const stoneScale = 1.21

func cutFor(shapeIdx int) cutSpec {
	c := cutForUnscaled(shapeIdx)
	c.rx, c.ry = c.rx*stoneScale, c.ry*stoneScale
	return c
}

func cutForUnscaled(shapeIdx int) cutSpec {
	switch shapeIdx {
	case 1:
		return cutSpec{8, true, circleOutline, 30, 21.5}
	case 2:
		return cutSpec{8, true, superOutline(3.4), 27, 24}
	case 3:
		// Emerald Cut: 10% smaller than the other cuts' scale (was 30 x 21);
		// its long step-cut outline read larger than the rest at 1.21
		return cutSpec{8, false, polyOutline(octagon(1, 1, 0.3)), 27, 18.9}
	case 4:
		return cutSpec{8, false, polyOutline(octagon(1, 1, 0.36)), 25, 25}
	case 5:
		return cutSpec{8, true, polyOutline(octagon(1, 1, 0.3)), 29, 22.5}
	case 6:
		return cutSpec{8, true, polyOutline([]pt{{1, 1}, {0, 1}, {-1, 1}, {-1, 0}, {-1, -1}, {0, -1}, {1, -1}, {1, 0}}), 23.5, 23.5}
	case 7:
		return cutSpec{8, true, pearOutline, 31, 27}
	case 8:
		return cutSpec{8, true, marquiseOutline, 33, 30}
	case 9:
		return cutSpec{9, true, trillionOutline, 27, 27}
	case shapeHeart:
		return cutSpec{10, true, heartOutline, 29, 28}
	case shapeRose:
		return cutSpec{6, true, circleOutline, 27, 27}
	case shapeRaw:
		return cutSpec{0, false, circleOutline, 27, 27} // sized per stone in buildRaw
	}
	return cutSpec{8, true, circleOutline, 27, 27}
}

// CutsForStone is which cuts a stone is really sold in -- the cuts the
// trade actually produces for it in quantity, not every cut that has
// ever been tried. A mint picks shapeIdx from this slice.
//   Diamond: every cut here; brilliance cuts (Radiant, Princess, Asscher)
//     were invented for it, Rose Cut is its oldest faceted form, and raw
//     octahedra are set in jewellery as they come from the mine.
//   Sapphire: rough favours ovals and cushions (weight retention), then
//     rounds, emerald cuts, pears, hearts, marquises, trillions (side
//     stones), princess (calibrated squares), rose cuts, raw barrels.
//     Asscher and Radiant are diamond-optimised and rare in sapphire.
//   Topaz: crystals are long prisms, so emerald cuts, ovals, pears,
//     cushions, marquises, then rounds, trillions, hearts, princess, and
//     raw crystals (topaz is one of the classic collector crystals).
//   Quartz (every chain without its own stone): cut in every style (it
//     is the lapidary's everyday stone), rose-cut amethyst is a classic,
//     and the hexagonal quartz point is THE raw crystal.
func CutsForStone(stone string) []int {
	switch stone {
	case "Diamond":
		return []int{0, 1, 2, 3, 4, 5, 6, 7, 8, 9, shapeHeart, shapeRose, shapeRaw}
	case "Sapphire":
		return []int{1, 2, 0, 3, 7, shapeHeart, 8, 9, 6, shapeRose, shapeRaw}
	case "Topaz":
		return []int{3, 1, 7, 2, 8, 0, 9, shapeHeart, 6, shapeRaw}
	}
	return []int{0, 1, 2, 3, 4, 5, 6, 7, 8, 9, shapeHeart, shapeRose, shapeRaw}
}

const (
	kCrown = iota
	kTable
	kPav
)

type face struct {
	p    []v3
	kind int
}

func ringPts(c cutSpec, n int, scale, z, off float64) []v3 {
	out := make([]v3, n)
	for k := 0; k < n; k++ {
		x, y := c.outline((float64(k) + off) / float64(n))
		out[k] = v3{x * c.rx * scale, y * c.ry * scale, z}
	}
	return out
}

// buildCut returns the solid's faces plus its girdle ring (drawn as one
// stroke, not as faces). Proportions follow a real stone: table ~56% of
// the width, crown ~1/3 as tall as the pavilion is deep.
func buildCut(c cutSpec) (faces []face, girdle []v3) {
	base := c.rx
	if c.ry < base {
		base = c.ry
	}
	hc, hp := 0.34*base, 0.9*base
	n := c.n
	if c.brilliant {
		T := ringPts(c, n, 0.56, hc, 0)
		B := ringPts(c, n, 0.8, hc*0.46, 0.5)
		G := ringPts(c, 2*n, 1, 0, 0)
		culet := v3{0, 0, -hp}
		faces = append(faces, face{T, kTable})
		for k := 0; k < n; k++ {
			k1 := (k + 1) % n
			// star, then the kite as one quad down to the girdle
			faces = append(faces, face{[]v3{T[k], B[k], T[k1]}, kCrown})
			faces = append(faces, face{[]v3{T[k1], B[k], G[(2*k+2)%(2*n)], B[k1]}, kCrown})
			// the two upper-girdle facets under this break vertex
			faces = append(faces, face{[]v3{B[k], G[2*k], G[2*k+1]}, kCrown})
			faces = append(faces, face{[]v3{B[k], G[2*k+1], G[(2*k+2)%(2*n)]}, kCrown})
			// pavilion main, spanning two girdle segments
			faces = append(faces, face{[]v3{G[2*k], G[2*k+1], G[(2*k+2)%(2*n)], culet}, kPav})
		}
		return faces, G
	}
	T := ringPts(c, n, 0.54, hc, 0)
	S := ringPts(c, n, 0.78, hc*0.5, 0)
	G := ringPts(c, n, 1, 0, 0)
	P1 := ringPts(c, n, 0.7, -hp*0.42, 0)
	P2 := ringPts(c, n, 0.38, -hp*0.78, 0)
	K := ringPts(c, n, 0.1, -hp, 0)
	faces = append(faces, face{T, kTable})
	rows := [][2][]v3{{T, S}, {S, G}}
	for _, r := range rows {
		for k := 0; k < n; k++ {
			k1 := (k + 1) % n
			faces = append(faces, face{[]v3{r[0][k], r[0][k1], r[1][k1], r[1][k]}, kCrown})
		}
	}
	prow := [][2][]v3{{G, P1}, {P1, P2}, {P2, K}}
	for _, r := range prow {
		for k := 0; k < n; k++ {
			k1 := (k + 1) % n
			faces = append(faces, face{[]v3{r[0][k], r[0][k1], r[1][k1], r[1][k]}, kPav})
		}
	}
	return faces, G
}

// buildRose is a rose cut: a flat base and a dome of triangular facets
// rising to a point -- six at the top, twelve around the edge. No table,
// no pavilion; the flat back is the one pavilion face.
func buildRose(c cutSpec) (faces []face, girdle []v3) {
	n := c.n
	base := math.Min(c.rx, c.ry)
	h := 0.62 * base
	apex := v3{0, 0, h}
	R := ringPts(c, n, 0.55, h*0.62, 0.5)
	G := ringPts(c, 2*n, 1, 0, 0)
	for k := 0; k < n; k++ {
		k1 := (k + 1) % n
		faces = append(faces, face{[]v3{apex, R[k], R[k1]}, kCrown})
		faces = append(faces, face{[]v3{G[2*k], G[2*k+1], R[k]}, kCrown})
		faces = append(faces, face{[]v3{G[2*k+1], G[(2*k+2)%(2*n)], R[k]}, kCrown})
		faces = append(faces, face{[]v3{R[k], G[(2*k+2)%(2*n)], R[k1]}, kCrown})
	}
	back := make([]v3, len(G))
	for i := range G {
		back[len(G)-1-i] = G[i]
	}
	faces = append(faces, face{back, kPav})
	return faces, G
}

// ringX is a ring of n points around the x axis at position x.
func ringX(n int, x, ry, rz, phase float64) []v3 {
	out := make([]v3, n)
	for k := 0; k < n; k++ {
		a := 2*math.Pi*(float64(k)+phase)/float64(n) + math.Pi/2
		out[k] = v3{x, ry * math.Cos(a), rz * math.Sin(a)}
	}
	return out
}

// bandX joins two rings of equal size with quads.
func bandX(a, b []v3) []face {
	var fs []face
	for k := range a {
		k1 := (k + 1) % len(a)
		fs = append(fs, face{[]v3{a[k], a[k1], b[k1], b[k]}, kCrown})
	}
	return fs
}

// capX closes a ring with one flat face (a pinacoid or a cleavage break).
func capX(r []v3) face { return face{r, kCrown} }

// turnFaces rotates every vertex about x by ax, then about z by az
// (radians): a rough crystal is set at an angle that shows several of its
// faces, not square-on to the viewer.
func turnFaces(fs []face, ax, az float64) []face {
	cx, sx, cz, sz := math.Cos(ax), math.Sin(ax), math.Cos(az), math.Sin(az)
	for i := range fs {
		// A rough crystal is translucent: lit from inside like a
		// pavilion, and its far faces show through the near ones
		// (renderGem3D draws back-facing kPav faces).
		fs[i].kind = kPav
		for j, p := range fs[i].p {
			y, z := p.y*cx-p.z*sx, p.y*sx+p.z*cx
			fs[i].p[j] = v3{p.x*cz - y*sz, p.x*sz + y*cz, z}
		}
	}
	return fs
}

// buildRaw is the stone's natural crystal, lying on its side as it would
// in a raw-crystal setting. Rough crystals have no table and no girdle,
// and none is perfectly regular: each habit is stretched a little on one
// axis.
func buildRaw(stone string) (faces []face, girdle []v3) {
	deg := math.Pi / 180
	switch stone {
	case "Diamond":
		// the octahedron, diamond's commonest habit, tipped so four or five
		// of its eight faces show
		a, b, h := 25.0*stoneScale, 22.0*stoneScale, 23.0*stoneScale
		v := []v3{{a, 0, 0}, {0, b, 0}, {-a, 0, 0}, {0, -b, 0}}
		top, bot := v3{0, 0, h}, v3{0, 0, -h}
		for k := 0; k < 4; k++ {
			k1 := (k + 1) % 4
			faces = append(faces, face{[]v3{top, v[k], v[k1]}, kCrown})
			faces = append(faces, face{[]v3{bot, v[k1], v[k]}, kCrown})
		}
		return turnFaces(faces, -38*deg, 28*deg), nil
	case "Sapphire":
		// corundum's barrel: a hexagonal prism swelling in the middle,
		// tapering to flat hexagonal ends
		L, R := 26.0*stoneScale, 16.0*stoneScale
		r0 := ringX(6, -L, R*0.42, R*0.42, 0)
		r1 := ringX(6, -L*0.3, R, R*0.94, 0)
		r2 := ringX(6, L*0.3, R, R*0.94, 0)
		r3 := ringX(6, L, R*0.42, R*0.42, 0)
		faces = append(faces, bandX(r0, r1)...)
		faces = append(faces, bandX(r1, r2)...)
		faces = append(faces, bandX(r2, r3)...)
		faces = append(faces, capX(r3))
		rev := make([]v3, 6)
		for i := range r0 {
			rev[5-i] = r0[i]
		}
		faces = append(faces, capX(rev))
		return turnFaces(faces, -30*deg, -14*deg), nil
	}
	if stone == "Quartz" {
		// the quartz point: a six-sided prism ending in a six-faced
		// pyramid, the far end broken off where it grew from the matrix
		L, R := 27.0*stoneScale, 12.5*stoneScale
		r0 := ringX(6, -L, R*1.04, R, 0)
		r1 := ringX(6, L*0.4, R, R*0.96, 0)
		point := v3{L, 0, 0}
		faces = append(faces, bandX(r0, r1)...)
		for k := 0; k < 6; k++ {
			faces = append(faces, face{[]v3{r1[k], r1[(k+1)%6], point}, kCrown})
		}
		rev := make([]v3, 6)
		for i := range r0 {
			rev[5-i] = r0[i]
		}
		faces = append(faces, capX(rev))
		return turnFaces(faces, -32*deg, 16*deg), nil
	}
	// topaz: an eight-sided prism (rhombic prism with bevelled edges),
	// a four-faced pyramid at one end, and the flat break of topaz's
	// perfect basal cleavage at the other
	L, ry, rz := 26.0*stoneScale, 16.0*stoneScale, 13.0*stoneScale
	r0 := ringX(8, -L, ry, rz, 0.5)
	r1 := ringX(8, L*0.5, ry, rz, 0.5)
	tip := ringX(8, L*0.82, ry*0.45, rz*0.45, 0.5)
	point := v3{L, 0, 0}
	faces = append(faces, bandX(r0, r1)...)
	faces = append(faces, bandX(r1, tip)...)
	for k := 0; k < 8; k++ {
		faces = append(faces, face{[]v3{tip[k], tip[(k+1)%8], point}, kCrown})
	}
	rev := make([]v3, 8)
	for i := range r0 {
		rev[7-i] = r0[i]
	}
	faces = append(faces, capX(rev))
	return turnFaces(faces, -30*deg, 12*deg), nil
}

/* ---- view, light, paint ---- */

// gemTilt is degrees from a straight-down view: 61 is enough to see under
// the girdle (the saved "oblique" view; the "profile" review set is the
// same code rendered with 76).
const gemTilt = 61.0

const (
	// Optically centred: the pavilion (the lower half) is dark and melts
	// into the ground, so a stone centred by geometry reads high; measured
	// on still renders, its visible part sat ~1.5 units above the ring
	// centre. Pearls are evenly lit and use subjY as is. (Was subjY-1.)
	gemCY   = subjY + 1.5
)

// n1 formats to one decimal as compactly as SVG allows: no trailing
// ".0", no leading "0".
func n1(v float64) string {
	neg := v < 0
	if neg {
		v = -v
	}
	t := int64(v*10 + 0.5)
	w, f := t/10, t%10
	s := ""
	if f == 0 {
		s = itoa(w)
	} else if w == 0 {
		s = "." + string(byte('0'+f))
	} else {
		s = itoa(w) + "." + string(byte('0'+f))
	}
	if neg && t != 0 {
		return "-" + s
	}
	return s
}

// relPath writes a closed polygon with relative coordinates; a negative
// number needs no separator before it, which is where the bytes go.
func relPath(ps []pt) string {
	s := "M" + n1(ps[0].x) + " " + n1(ps[0].y) + "l"
	px, py := math.Round(ps[0].x*10)/10, math.Round(ps[0].y*10)/10
	for i := 1; i < len(ps); i++ {
		qx, qy := math.Round(ps[i].x*10)/10, math.Round(ps[i].y*10)/10
		dx, dy := n1(qx-px), n1(qy-py)
		if i > 1 && dx[0] != '-' {
			s += " "
		}
		s += dx
		if dy[0] != '-' {
			s += " "
		}
		s += dy
		px, py = qx, qy
	}
	return s + "z"
}

// hex3 quantises #rrggbb to #rgb.
func hex3(h string) string {
	r, g, b := hexToRGB(h)
	d := "0123456789abcdef"
	q := func(v int) byte { return d[(v+8)*15/255%16] }
	return "#" + string([]byte{q(r), q(g), q(b)})
}

func convexHull(ps []pt) []pt {
	n := len(ps)
	idx := make([]int, n)
	for i := range idx {
		idx[i] = i
	}
	// bottom-up merge sort by (x, y): the body hull takes every projected
	// vertex of the stone (hundreds), where an insertion sort's n^2
	// comparisons were a real share of a render's gas
	less := func(a, b int) bool {
		return ps[a].x < ps[b].x || (ps[a].x == ps[b].x && ps[a].y < ps[b].y)
	}
	tmp := make([]int, n)
	for w := 1; w < n; w *= 2 {
		for lo := 0; lo < n; lo += 2 * w {
			mid, hi := lo+w, lo+2*w
			if mid > n {
				mid = n
			}
			if hi > n {
				hi = n
			}
			i, j, k := lo, mid, lo
			for i < mid && j < hi {
				if less(idx[j], idx[i]) {
					tmp[k] = idx[j]
					j++
				} else {
					tmp[k] = idx[i]
					i++
				}
				k++
			}
			for i < mid {
				tmp[k] = idx[i]
				i++
				k++
			}
			for j < hi {
				tmp[k] = idx[j]
				j++
				k++
			}
		}
		idx, tmp = tmp, idx
	}
	cr := func(o, a, b pt) float64 { return (a.x-o.x)*(b.y-o.y) - (a.y-o.y)*(b.x-o.x) }
	var h []pt
	for pass := 0; pass < 2; pass++ {
		start := len(h)
		for i := 0; i < n; i++ {
			p := ps[idx[i]]
			if pass == 1 {
				p = ps[idx[n-1-i]]
			}
			for len(h) >= start+2 && cr(h[len(h)-2], h[len(h)-1], p) <= 0 {
				h = h[:len(h)-1]
			}
			h = append(h, p)
		}
		h = h[:len(h)-1]
	}
	return h
}

/* ---- polygon helpers for the realism passes ---- */

// polyArea is twice the signed area; sign tells winding.
func polyArea(ps []pt) float64 {
	a := 0.0
	for i := range ps {
		j := (i + 1) % len(ps)
		a += ps[i].x*ps[j].y - ps[j].x*ps[i].y
	}
	if a < 0 {
		return -a / 2
	}
	return a / 2
}

// clipHalf is one Sutherland-Hodgman pass: keeps the part of ps on the
// inner side of the line through (ox,oy) with outward normal (nx,ny).
func clipHalf(ps []pt, ox, oy, nx, ny float64) []pt {
	if len(ps) == 0 {
		return ps
	}
	d := func(q pt) float64 { return (q.x-ox)*nx + (q.y-oy)*ny }
	var out []pt
	for i := range ps {
		a, b := ps[i], ps[(i+1)%len(ps)]
		da, db := d(a), d(b)
		if da <= 0 {
			out = append(out, a)
		}
		if (da < 0 && db > 0) || (da > 0 && db < 0) {
			t := da / (da - db)
			out = append(out, pt{a.x + (b.x-a.x)*t, a.y + (b.y-a.y)*t})
		}
	}
	return out
}

// clipToConvex keeps the part of ps inside the convex window win.
func clipToConvex(ps, win []pt) []pt {
	// win from convexHull is counter-clockwise in screen coords; the
	// outward normal of edge (a,b) is (dy,-dx) rotated to point away.
	for i := range win {
		a, b := win[i], win[(i+1)%len(win)]
		nx, ny := b.y-a.y, a.x-b.x
		mid := pt{(a.x + b.x) / 2, (a.y + b.y) / 2}
		// make the normal point outward: away from the window centre
		cx, cy := centroid(win)
		if (mid.x-cx)*nx+(mid.y-cy)*ny < 0 {
			nx, ny = -nx, -ny
		}
		ps = clipHalf(ps, a.x, a.y, nx, ny)
		if len(ps) < 3 {
			return nil
		}
	}
	return ps
}

// splitPoly cuts ps in two along the line through its centroid at ang.
func splitPoly(ps []pt, ang float64) ([]pt, []pt) {
	cx, cy := centroid(ps)
	nx, ny := math.Cos(ang), math.Sin(ang)
	return clipHalf(ps, cx, cy, nx, ny), clipHalf(ps, cx, cy, -nx, -ny)
}

// renderGem3D builds the stone. Returns what goes under the facets
// (defs, body glow, the pavilion's back faces), the front facets as bare
// self-closing paths (applyCascade scans these), and what goes over
// (girdle stroke, rim).
func renderGem3D(shapeIdx int, base, salt string, fs *facetStyle) (under, facets, over string) {
	c := cutFor(shapeIdx)
	var faces []face
	var girdle []v3
	switch shapeIdx {
	case shapeRose:
		faces, girdle = buildRose(c)
	case shapeRaw:
		faces, girdle = buildRaw(fs.stone)
	default:
		faces, girdle = buildCut(c)
	}
	raw := shapeIdx == shapeRaw

	sh := fs.prof.shadow
	if fs.prof.neutral != "" {
		base = fs.prof.neutral
	}
	base = mixHex(base, sh, fs.prof.bodyMix)
	deep := darken(base, sh, 0.9)
	// Highlights stay in the stone's hue; only the specular goes to
	// white. Mixing facets most of the way to white is what read pastel.
	bright := lighten(base, 0.5)
	fs.flash = flashRamp(28, fs.prof.sat)
	deepI, baseI, brightI := toRGBI(deep), toRGBI(base), toRGBI(bright)
	toneI := func(lum float64) rgbI {
		if lum < 0 {
			lum = 0
		}
		if lum > 1 {
			lum = 1
		}
		if lum < 0.5 {
			return mixI(deepI, baseI, lum*2)
		}
		return mixI(baseI, brightI, (lum-0.5)*2)
	}
	tone := func(lum float64) string { return toneI(lum).hex() }

	// view: a small per-token yaw, then the tilt toward the viewer
	yaw := fs.zone.floatIn(-13, 13) * math.Pi / 180
	th := gemTilt * math.Pi / 180
	cy, sy := math.Cos(yaw), math.Sin(yaw)
	ct, stt := math.Cos(th), math.Sin(th)
	view := func(p v3) v3 {
		x1, y1 := p.x*cy-p.y*sy, p.x*sy+p.y*cy
		return v3{x1, y1*ct + p.z*stt, p.z*ct - y1*stt}
	}
	// Centre every stone on its own drawn extent, not on its geometric
	// origin: a rose cut is all dome and no pavilion, so centred on its
	// girdle it sat high in the ring; raw crystals and pears are lopsided
	// the same way. This shifts the drawing only; the rock still pivots
	// on the ring centre.
	ex0, ey0, ex1, ey1 := 1e9, 1e9, -1e9, -1e9
	for _, f := range faces {
		for _, p := range f.p {
			q := view(p)
			ex0, ey0 = math.Min(ex0, q.x), math.Min(ey0, q.y)
			ex1, ey1 = math.Max(ex1, q.x), math.Max(ey1, q.y)
		}
	}
	ox, oy := -(ex0+ex1)/2, -(ey0+ey1)/2
	scr := func(p v3) pt { return pt{subjX + p.x + ox, gemCY - (p.y + oy)} }
	light := vnorm(v3{-0.5, 0.62, 0.6})
	inside := v3{0, 0, -0.25 * c.ry}
	if raw {
		inside = v3{}
	} else if shapeIdx == shapeRose {
		inside = v3{0, 0, 0.15 * c.ry}
	}

	type drawn struct {
		pts   []pt
		depth float64
		fill  string
		kind  int
		lum   float64
		// what shadeFront needs to relight this facet for the rock
		nv                v3
		jit, drift, thick float64
		ext               bool
	}
	// shadeFront is the lighting of a facet seen from outside, for a
	// given light direction. Kept as one function so the rock states
	// (see lightStates below) are lit by exactly the same model.
	shadeFront := func(kind int, nv, L v3, jit, drift, thick float64, ext bool) (string, float64) {
		H := vnorm(v3{L.x, L.y, L.z + 1})
		// A real stone is a contrast pattern, not an evenly lit solid:
		// lambert with a gamma so mid facets stay deep and saturated,
		// plus the odd "extinction" facet that returns no light at all.
		lam := math.Max(0, vdot(nv, L))
		lum := 0.03 + 0.7*math.Pow(lam, 2.1) + jit
		if ext {
			lum *= 0.3
		}
		if kind == kTable {
			lum = 0.36 + 0.26*lam
		}
		if kind == kPav {
			// A pavilion facet seen from outside faces away from the
			// lamp, but it is where light that entered through the
			// crown LEAVES the stone: lit from its inner side.
			lum = 0.22 + 0.5*math.Max(0, vdot(vscale(nv, -1), L)) + jit
		}
		if raw {
			// A natural crystal face is not polished, but topaz, quartz,
			// sapphire and diamond rough all have a glassy (vitreous to
			// adamantine) lustre: faces toward the lamp shine from
			// outside as well as glowing from inside. Lit only from
			// inside, the crystals read as dull plastic.
			lum = 0.3 + 0.42*math.Pow(lam, 1.4) + 0.22*math.Max(0, vdot(vscale(nv, -1), L)) + jit*0.6
		}
		col := mixI(toneI(lum), deepI, 0.34*thick*thick)
		if sp := math.Pow(math.Max(0, vdot(nv, H)), 28); sp > 0.3 {
			col = mixI(col, whiteI, sp*0.85)
		}
		// Dispersion on the bright facets: white light split by the stone
		// leaves each facet in a slightly different spectral colour, set by
		// which way the facet faces (its azimuth), so neighbours differ
		// the way real fire does instead of every bright facet being one
		// lighter shade of the body. Scaled by the stone's own dispersion
		// (prof.sat: diamond most, topaz least) and only above mid
		// brightness; dark facets keep the body colour.
		if lum > 0.5 && kind != kTable {
			amt := math.Min(1, (lum-0.5)/0.4) * dispersionMix * fs.prof.sat
			t := math.Atan2(nv.y, nv.x)/math.Pi + drift/40
			col = mixI(col, spectrumAtI(t), amt)
		}
		return hex3I(hueRotateI(col, drift)), lum
	}
	var back, front, pav []drawn
	var all []pt
	for _, f := range faces {
		vp := make([]v3, len(f.p))
		ctr := v3{}
		for i, p := range f.p {
			vp[i] = view(p)
			ctr = v3{ctr.x + p.x, ctr.y + p.y, ctr.z + p.z}
		}
		ctr = vscale(ctr, 1/float64(len(f.p)))
		// Newell's normal, not a cross product of the first three points:
		// Princess Cut's table has three collinear corners there, which
		// gave a zero normal and dropped its table face entirely.
		nm := v3{}
		for i := range f.p {
			a, b := f.p[i], f.p[(i+1)%len(f.p)]
			nm = v3{nm.x + (a.y-b.y)*(a.z+b.z), nm.y + (a.z-b.z)*(a.x+b.x), nm.z + (a.x-b.x)*(a.y+b.y)}
		}
		nm = vnorm(nm)
		if vdot(nm, vsub(ctr, inside)) < 0 {
			nm = vscale(nm, -1)
		}
		nv := vnorm(view(nm))
		d := drawn{kind: f.kind}
		for _, p := range vp {
			d.pts = append(d.pts, scr(p))
			d.depth += p.z
			all = append(all, scr(p))
		}
		d.depth /= float64(len(vp))
		// How much stone the light crosses under this facet: the solid is
		// thickest over the axis and thins to nothing at the girdle, so a
		// facet near the centre shows more of the body colour (Beer-Lambert,
		// the reason a deep stone reads darker and more saturated than a
		// shallow one). Costs no extra markup -- it only shifts the fill.
		rN := math.Sqrt((ctr.x/c.rx)*(ctr.x/c.rx) + (ctr.y/c.ry)*(ctr.y/c.ry))
		if rN > 1 {
			rN = 1
		}
		thick := 1 - rN
		jit := fs.zone.floatIn(-0.13, 0.13)
		if nv.z > 0.02 {
			ext := f.kind == kCrown && fs.zone.floatIn(0, 1) < 0.28
			drift := fs.zone.floatIn(-fireZoneDeg, fireZoneDeg)
			d.nv, d.jit, d.drift, d.thick, d.ext = nv, jit, drift, thick, ext
			d.fill, d.lum = shadeFront(f.kind, nv, light, jit, drift, thick, ext)
			front = append(front, d)
			if f.kind == kPav {
				pav = append(pav, d)
			}
		} else if f.kind == kPav {
			// seen from inside through the crown: lit on its inner side
			inner := vscale(nv, -1)
			lum := 0.2 + 0.6*math.Max(0, vdot(inner, light)) + jit
			d.fill = hex3(mixHex(tone(lum), deep, 0.34*thick*thick))
			d.lum = lum
			back = append(back, d)
			pav = append(pav, d)
		}
	}
	sortDrawn := func(ds []drawn) {
		for i := 1; i < len(ds); i++ {
			for j := i; j > 0 && ds[j].depth < ds[j-1].depth; j-- {
				ds[j], ds[j-1] = ds[j-1], ds[j]
			}
		}
	}
	sortDrawn(back)
	sortDrawn(front)

	hull := convexHull(all)
	if shapeIdx == shapeHeart {
		// the notch: a hull would fill it; the girdle ring is the outline
		hull = nil
		for _, g := range girdle {
			hull = append(hull, scr(view(g)))
		}
	}
	// strings.Builder, not +=: appending to a growing string re-copies it
	// every time, and on-chain that copying was the bulk of a render's gas
	var underB, facetsB strings.Builder
	underB.WriteString(`<defs><radialGradient id="bd` + salt + `" cx=".4" cy=".35" r=".75">` +
		`<stop offset="0" stop-color="` + hex3(base) + `"/><stop offset=".5" stop-color="` + hex3(darken(base, sh, 0.25)) + `"/><stop offset="1" stop-color="` + hex3(darken(base, sh, 0.85)) + `"/></radialGradient></defs>` +
		`<path d="` + relPath(hull) + `" fill="url(#bd` + salt + `)" opacity=".7"/><g fill-opacity=".6">`)
	for _, d := range back {
		underB.WriteString(`<path d="` + relPath(d.pts) + `" fill="` + d.fill + `"/>`)
	}
	underB.WriteString(`</g>`)

	nCrown := 0
	for _, d := range front {
		if d.kind == kCrown {
			nCrown++
		}
	}
	candP := 1.0
	if nCrown > fireMaxFacets {
		candP = float64(fireMaxFacets) / float64(nCrown) * 1.25
	}
	nCand := 0
	nSplit := 0
	if raw || fs.thumb {
		// rough crystal: no fire flashes, no split facets -- a natural
		// face is one frosted plane. A thumbnail: no flashes either.
		candP = 0
	}
	for _, d := range front {
		if d.kind == kTable && shapeIdx == shapeHeart {
			// a non-convex window: skip the reflected mosaic, which is
			// clipped to a convex outline and would spill into the notch
			facetsB.WriteString(`<path d="` + relPath(d.pts) + `" fill="` + d.fill + `" fill-opacity=".46"/>`)
			continue
		}
		if d.kind == kTable {
			// The window. Through it you do not see the pavilion's own
			// faces straight on -- you see them mirrored back up at you off
			// the pavilion walls, small and inverted. That mosaic is what a
			// real table shows, so it is drawn here: each pavilion face mapped
			// into the table, flipped, and cut to the table's outline (a
			// Sutherland-Hodgman clip, no <clipPath>).
			facetsB.WriteString(`<path d="` + relPath(d.pts) + `" fill="` + d.fill + `" fill-opacity=".46"/>`)
			win := convexHull(d.pts)
			tx, ty := centroid(win)
			if len(pav) > 0 && !fs.thumb {
				bx0, by0, bx1, by1 := 1e9, 1e9, -1e9, -1e9
				for _, b := range pav {
					for _, q := range b.pts {
						bx0, by0 = math.Min(bx0, q.x), math.Min(by0, q.y)
						bx1, by1 = math.Max(bx1, q.x), math.Max(by1, q.y)
					}
				}
				wx0, wy0, wx1, wy1 := 1e9, 1e9, -1e9, -1e9
				for _, q := range win {
					wx0, wy0 = math.Min(wx0, q.x), math.Min(wy0, q.y)
					wx1, wy1 = math.Max(wx1, q.x), math.Max(wy1, q.y)
				}
				k := 0.92 * math.Min((wx1-wx0)/math.Max(1, bx1-bx0), (wy1-wy0)/math.Max(1, by1-by0))
				bx, by := (bx0+bx1)/2, (by0+by1)/2
				var mosB strings.Builder
				nRefl := 0
				for _, b := range pav {
					if nRefl >= 8 {
						break
					}
					mp := make([]pt, len(b.pts))
					for i, q := range b.pts {
						mp[i] = pt{tx + (q.x-bx)*k, ty - (q.y-by)*k}
					}
					cl := clipToConvex(mp, win)
					if len(cl) < 3 || polyArea(cl) < 4 {
						continue
					}
					nRefl++
					mosB.WriteString(`<path d="` + relPath(cl) + `" fill="` + hex3(tone(b.lum*0.95)) + `"/>`)
				}
				if mosB.Len() > 0 {
					facetsB.WriteString(`<g fill-opacity=".55">` + mosB.String() + `</g>`)
				}
			}
			continue
		}
		// Only some crown facets can flash (fireMaxFacets): every one that
		// can costs an overlay path, so the set is bounded per stone.
		if d.kind == kCrown && nCand < fireMaxFacets && fs.zone.floatIn(0, 1) < candP {
			nCand++
			cx, cyy := centroid(d.pts)
			fs.ringCent = append(fs.ringCent, pt{cx, cyy})
			facetsB.WriteString(`<path d="` + relPath(d.pts) + `" fill="` + d.fill + `" class="f"/>`)
			continue
		}
		// Two-tone facets: a real facet rarely reflects one thing. Part of
		// it catches the lamp, the rest catches the dark room, and the
		// boundary is a straight line across the facet. Split a bounded
		// number of the larger ones (each split costs one extra path).
		if !raw && nSplit < 6 && polyArea(d.pts) > 26 && fs.zone.floatIn(0, 1) < 0.5 {
			a, b := splitPoly(d.pts, fs.zone.floatIn(0, math.Pi))
			if len(a) >= 3 && len(b) >= 3 {
				nSplit++
				lo := hex3(mixHex(tone(math.Max(0, d.lum*0.6-0.04)), deep, 0.18))
				hi := hex3(tone(math.Min(1, d.lum*1.35+0.06)))
				facetsB.WriteString(`<path d="` + relPath(a) + `" fill="` + hi + `"/><path d="` + relPath(b) + `" fill="` + lo + `"/>`)
				continue
			}
		}
		facetsB.WriteString(`<path d="` + relPath(d.pts) + `" fill="` + d.fill + `"/>`)
	}

	// Lighting that follows the rock. The stone swings to -rot and +rot
	// (motionPhases); relative to the stone that turns the lamp the other
	// way, so every facet meets the light at a new angle and they all
	// change together. For each swing the facets that change most get a
	// copy in their new shade, grouped, and the group fades in with the
	// swing (gt-la / gt-lb in styleBlock, timed off the rock's own
	// duration and delay, which the group inherits from .gt-r). Only
	// group opacity animates -- no per-facet colour animation, which is
	// what keeps it smooth in Safari. The lamp turns lightSwing times the
	// rock angle: a real stone flashes hard on a tiny movement, and at 1x
	// a 4-8 degree rock barely moves the shading.
	_, _, _, _, rotDeg := motionPhases(salt)
	type cand struct {
		i     int
		fill  string
		delta float64
	}
	for si, sgn := range []float64{1, -1} {
		if fs.thumb {
			break
		}
		// rotate(-rot) in SVG (y down) is a visual counter-clockwise turn,
		// which in this y-up view space turns the stone +rot, i.e. the
		// lamp -rot relative to it
		a := -sgn * rotDeg * lightSwing * math.Pi / 180
		ca, sa := math.Cos(a), math.Sin(a)
		L := vnorm(v3{light.x*ca - light.y*sa, light.x*sa + light.y*ca, light.z})
		var cs []cand
		for i, d := range front {
			if d.kind == kTable {
				continue
			}
			f2, _ := shadeFront(d.kind, d.nv, L, d.jit, d.drift, d.thick, d.ext)
			if dl := lumaDelta(f2, d.fill); dl > 0.06 && polyArea(d.pts) > 3 {
				cs = append(cs, cand{i, f2, dl})
			}
		}
		// strongest changes first; insertion sort, the list is short
		for i := 1; i < len(cs); i++ {
			for j := i; j > 0 && cs[j].delta > cs[j-1].delta; j-- {
				cs[j], cs[j-1] = cs[j-1], cs[j]
			}
		}
		if len(cs) > lightMaxFacets {
			cs = cs[:lightMaxFacets]
		}
		if len(cs) == 0 {
			continue
		}
		cls := "gt-la"
		if si == 1 {
			cls = "gt-lb"
		}
		facetsB.WriteString(`<g class="` + cls + `" opacity="0">`)
		for _, c := range cs {
			facetsB.WriteString(`<path d="` + relPath(front[c.i].pts) + `" fill="` + c.fill + `"/>`)
		}
		facetsB.WriteString(`</g>`)
	}

	// girdle: the near half of the ring as one frosted stroke
	gd, lastG := "", ""
	for i := range girdle {
		a, b := view(girdle[i]), view(girdle[(i+1)%len(girdle)])
		mid := vscale(v3{girdle[i].x + girdle[(i+1)%len(girdle)].x, girdle[i].y + girdle[(i+1)%len(girdle)].y, 0}, 0.5)
		if view(vnorm(mid)).z-0 > -0.05 && view(mid).z >= view(v3{}).z-0.01 {
			pa, pb := scr(a), scr(b)
			// consecutive segments share an end point: continue the
			// polyline instead of a fresh M...L pair per segment
			sa := n1(pa.x) + " " + n1(pa.y)
			if sa != lastG {
				gd += "M" + sa
			}
			lastG = n1(pb.x) + " " + n1(pb.y)
			gd += " " + lastG
		}
	}
	// The girdle is a faint line in the stone's own tone, not a light
	// edge, and there is no outline stroke: a drawn rim reads as a
	// sticker border, real stones end where their facets end.
	over = `<path d="` + gd + `" fill="none" stroke="` + hex3(lighten(base, 0.18)) + `" stroke-width=".7" stroke-linecap="round" opacity=".4"/>`
	return underB.String(), facetsB.String(), over
}

// dispersionMix is the most a bright facet is tinted toward its spectral
// colour (for a stone with prof.sat 1, i.e. diamond).
const dispersionMix = 0.32

var spectrum = []string{"#ff4040", "#ff9a1f", "#ffe81f", "#35ff7a", "#22ccff", "#5566ff", "#c04dff"}

var spectrumI = func() []rgbI {
	out := make([]rgbI, len(spectrum))
	for i, h := range spectrum {
		out[i] = toRGBI(h)
	}
	return out
}()

func spectrumAtI(t float64) rgbI {
	t = t - math.Floor(t)
	f := t * float64(len(spectrumI))
	i := int(f)
	return mixI(spectrumI[i%len(spectrumI)], spectrumI[(i+1)%len(spectrumI)], f-float64(i))
}

// spectrumAt returns the spectral colour at t, wrapping every 1.0 (so
// facets facing opposite ways get the same hue, as a symmetric cut does).
func spectrumAt(t float64) string {
	t = t - math.Floor(t)
	f := t * float64(len(spectrum))
	i := int(f)
	return mixHex(spectrum[i%len(spectrum)], spectrum[(i+1)%len(spectrum)], f-float64(i))
}

// lightSwing is how far the lamp turns per degree of rock, and
// lightMaxFacets how many facets per swing get a relit copy (each costs
// one path, ~60 bytes).
const (
	lightSwing     = 2.2
	lightMaxFacets = 12
)

// lumaDelta is the perceived brightness difference of two hex colours,
// 0..1.
func lumaDelta(a, b string) float64 {
	// facet fills are #rgb (hex3); widen to #rrggbb for hexToRGB
	wide := func(h string) string {
		if len(h) == 4 {
			return "#" + h[1:2] + h[1:2] + h[2:3] + h[2:3] + h[3:4] + h[3:4]
		}
		return h
	}
	ar, ag, ab := hexToRGB(wide(a))
	br, bg, bb := hexToRGB(wide(b))
	d := (0.2126*float64(ar-br) + 0.7152*float64(ag-bg) + 0.0722*float64(ab-bb)) / 255
	if d < 0 {
		return -d
	}
	return d
}

// fireMaxFacets bounds how many facets of a stone can flash.
const fireMaxFacets = 12

// starfield toggles the background stars (see renderStars).
const starfield = true

// renderStars scatters a sparse starfield behind everything. The field
// itself is still: every star keeps its own fixed brightness (four levels,
// sizes to match), the way a night sky looks. Only a few stars twinkle,
// and each twinkler is its own element with its own period and phase,
// drawn per token, so no two ever blink together -- the old field had one
// whole group of stars fading in and out in unison. The ring band is kept
// clear. Seeded per token.
func renderStars(salt string) string {
	if !starfield {
		return ""
	}
	rnd := newPRNG("stars" + salt)
	type star struct{ x, y float64 }
	var byLevel [4][]star
	for i := 0; i < 36; i++ {
		x, y := rnd.floatIn(3, canvasW-3), rnd.floatIn(3, 127)
		k := rnd.intn(20)
		dx, dy := x-subjX, y-subjY
		if r := math.Sqrt(dx*dx + dy*dy); r > 43 && r < 58 {
			continue
		}
		lvl := 0 // most stars are faint; a few are bright
		switch {
		case k >= 18:
			lvl = 3
		case k >= 14:
			lvl = 2
		case k >= 8:
			lvl = 1
		}
		byLevel[lvl] = append(byLevel[lvl], star{x, y})
	}
	widths := [4]string{".45", ".6", ".85", "1.15"}
	ops := [4]string{".22", ".38", ".58", ".85"}
	var b strings.Builder
	b.WriteString(`<g stroke="#fff" stroke-linecap="round" fill="none">`)
	var tw []star
	for l := 0; l < 4; l++ {
		if len(byLevel[l]) == 0 {
			continue
		}
		d := ""
		for i, st := range byLevel[l] {
			// the twinklers come from the middle levels (visible, not the
			// brightest), at most three per token
			if l >= 1 && l <= 2 && len(tw) < 3 && i%3 == 0 {
				tw = append(tw, st)
				continue
			}
			d += "M" + n1(st.x) + " " + n1(st.y) + "h.01"
		}
		if d != "" {
			b.WriteString(`<path d="` + d + `" stroke-width="` + widths[l] + `" opacity="` + ops[l] + `"/>`)
		}
	}
	for _, st := range tw {
		// 5-12 s periods (irrational-ish ratios between them) and random
		// phases: each twinkles alone, briefly, now and then
		dur := rnd.floatIn(5, 12)
		b.WriteString(`<path d="M` + n1(st.x) + " " + n1(st.y) + `h.01" stroke-width=".9" opacity=".4" class="gt-tw" style="--d:` + fnum1(dur) + `s;--dl:-` + fnum1(rnd.floatIn(0, dur)) + `s"/>`)
	}
	b.WriteString(`</g>`)
	return b.String()
}

/* ------------------------------------ pearl shapes ------------------------------------ */
// Pearls are organic gems -- they grow into a form, they are never cut or
// faceted the way a crystal is. So unlike the cut vocabulary above
// (ShapeNames/renderGem), everything here draws a smooth, continuous
// surface: one radial luster gradient plus a soft diagonal highlight band
// (a pearl's real "orient" sheen), no straight-edged facet triangles.

// pearlLusterGradient returns the defs for a pearl's nacre, as four
// gradients the body shape is filled with in turn (pearlLayers):
//   gid    body: a sphere lit from the upper left -- lifted where the light
//          lands, the body colour through the middle, a real terminator
//          (the shadowed limb, lower right), and a thin bounce-lit rim.
//          The old version only lightened a white body, which cannot get
//          brighter, so white pearls read as flat discs.
//   gid+o  overtone: nacre's resting iridescence, rose over the body and
//          green toward the rim, the two interference colours pearls show.
//   gid+s  specular: the lamp itself, a small hot core with a soft skirt.
//          Nacre is glossy; the core is what says "pearl" at 200 px.
//   gid+w  window: the second, dimmer reflection of the room on the far
//          side, which is what makes a sphere read as a mirror, not paint.
// Shadow tones are warm for light bodies and neutral for dark ones: a
// white pearl shades toward grey-taupe, never toward black.
func pearlLusterGradient(gid, base, metal string) string {
	r, g, b := hexToRGB(base)
	lum := (0.2126*float64(r) + 0.7152*float64(g) + 0.0722*float64(b)) / 255
	shadow := "#4a4038"
	if lum < 0.4 {
		shadow = "#000000"
	}
	// The lit side is the body colour itself and everything else is
	// shaded down from it, so the specular (pure white) is the only thing
	// that brightest -- that contrast is what reads as gloss. Full 6-digit
	// hex here: #rgb quantising flattened the subtle pearl tones.
	hi := base
	// highlight strengths; a dark (Tahitian) pearl gets a smaller, softer
	// highlight: at full strength a white hot spot on a near-black body
	// read as a glare, not as nacre
	// A soft, wide sheen rather than a hot spot: a real pearl's lustre is
	// a broad glow with a gentle falloff (nacre scatters light), not a
	// pinpoint. Peak kept well below full white, spread over a larger
	// radius with an extra mid stop so there is no hard edge.
	sc, ss, sw := ".6", ".32", ".16"
	mo := ".3"
	if lum < 0.4 {
		mo = ".22"
		hi = mixHex(base, "#c9d2d8", 0.28)
		sc, ss, sw = ".34", ".16", ".07"
	}
	return `<radialGradient id="` + gid + `" cx=".4" cy=".36" r=".7" fx=".34" fy=".28">` +
		`<stop offset="0" stop-color="` + hi + `"/>` +
		`<stop offset=".4" stop-color="` + mixHex(base, shadow, 0.13) + `"/>` +
		`<stop offset=".76" stop-color="` + mixHex(base, shadow, 0.36) + `"/>` +
		`<stop offset=".93" stop-color="` + mixHex(base, shadow, 0.5) + `"/>` +
		`<stop offset="1" stop-color="` + mixHex(base, shadow, 0.3) + `"/></radialGradient>` +
		`<radialGradient id="` + gid + `o" cx=".45" cy=".44" r=".62">` +
		`<stop offset=".3" stop-color="#fff" stop-opacity="0"/>` +
		`<stop offset=".62" stop-color="#ffb3cf" stop-opacity=".2"/>` +
		`<stop offset=".88" stop-color="#b3ffd6" stop-opacity=".2"/>` +
		`<stop offset="1" stop-color="#c3d3ff" stop-opacity=".12"/></radialGradient>` +
		`<radialGradient id="` + gid + `s" cx=".36" cy=".3" r=".4">` +
		`<stop offset="0" stop-color="#fff" stop-opacity="` + sc + `"/>` +
		`<stop offset=".35" stop-color="#fff" stop-opacity="` + ss + `"/>` +
		`<stop offset=".7" stop-color="#fff" stop-opacity=".06"/>` +
		`<stop offset="1" stop-color="#fff" stop-opacity="0"/></radialGradient>` +
		// gid+m: the setting mirrored in the nacre -- a thin crescent of
		// the ring's metal along the lower limb, where a sphere reflects
		// what is beside and below it. A pearl in gold shows a warm edge,
		// in platinum a cool one: that is what makes it read as a mirror.
		`<radialGradient id="` + gid + `m" cx=".42" cy=".36" r=".68">` +
		`<stop offset=".78" stop-color="` + metal + `" stop-opacity="0"/>` +
		`<stop offset=".93" stop-color="` + metal + `" stop-opacity="` + mo + `"/>` +
		`<stop offset="1" stop-color="` + metal + `" stop-opacity="0"/></radialGradient>` +
		`<radialGradient id="` + gid + `w" cx=".66" cy=".73" r=".2">` +
		`<stop offset="0" stop-color="#fff" stop-opacity="` + sw + `"/>` +
		`<stop offset="1" stop-color="#fff" stop-opacity="0"/></radialGradient>`
}

// pearlLayers re-emits a pearl's body shape once per lustre layer (body,
// overtone, metal reflection, window, specular) (see
// pearlLusterGradient). shape is the full self-closing element with its
// fill attribute; only the fill is swapped. The rings of a Circled pearl
// go between the overtone and the highlights, so the highlight sits on
// top of the grooves as it would on a real surface.
func pearlLayers(shape, gid, between string) string {
	i := strings.Index(shape, ` fill="`)
	if i < 0 {
		return shape
	}
	cp := func(suffix string) string { return shape[:i] + ` fill="url(#` + gid + suffix + `)"/>` }
	return shape + cp("o") + cp("m") + between + cp("w") + cp("s")
}

// pearlSweepColorIntensity picks the sweep gradient's opacity multiplier
// off the base color's own luminance: a dark body (e.g. Black) already
// reads a screen-blended color band far more strongly than a light body
// does at the same opacity, so light bodies get a bigger boost off the
// shared baseline than dark ones do. Threshold/multipliers tuned by eye
// against the full 8-color palette, not derived from anything physical.
func pearlSweepColorIntensity(base string) float64 {
	r, g, b := hexToRGB(base)
	lum := 0.2126*float64(r)/255 + 0.7152*float64(g)/255 + 0.0722*float64(b)/255
	if lum < 0.4 {
		// was 1.2: on a black pearl the colour band read as a bright
		// stripe; nacre's orient on a dark body is subtle
		return 0.55
	}
	return 2.0
}

// pearlSweepGradient is the traveling band's own color: transparent at
// both ends, a soft pink/blue/green/gold spectrum in the middle -- an
// approximation of thin-film interference (the real source of nacre's
// iridescence) rather than a single flat highlight tone.
func pearlSweepGradient(gid, base string) string {
	mult := pearlSweepColorIntensity(base)
	o1, o2, o3 := fnum(0.3*mult), fnum(0.35*mult), fnum(0.3*mult)
	return `<linearGradient id="` + gid + `" x1="0%" y1="0%" x2="100%" y2="0%">` +
		`<stop offset="0%" stop-color="#ffffff" stop-opacity="0"/>` +
		`<stop offset="18%" stop-color="#ffd2e6" stop-opacity="` + o1 + `"/>` +
		`<stop offset="38%" stop-color="#cfe8ff" stop-opacity="` + o2 + `"/>` +
		`<stop offset="58%" stop-color="#d4ffe4" stop-opacity="` + o3 + `"/>` +
		`<stop offset="80%" stop-color="#fff0c2" stop-opacity="` + o3 + `"/>` +
		`<stop offset="100%" stop-color="#ffffff" stop-opacity="0"/>` +
		`</linearGradient>`
}

// pearlSweepOverlay replaces the old fixed pearlOrientSheen ellipse: a
// handful of slow, wide, translucent color bands that each cross the
// pearl's own silhouette once from a random angle, then wait, then cross
// again from a new random angle, on repeat. shapeGeom is that pearl's own
// outline (no fill needed -- only used inside a clipPath) so the color
// never spills past the gem's edge, the same way applyCascade's facet
// flashes are seeded per token off tidStr rather than being identical
// across every piece.
func pearlSweepOverlay(salt, base, shapeGeom string, w, h float64) string {
	rnd := newPRNG(salt + "-sweep")
	const passes = 3
	total := 15.0 + rnd.floatIn(0, 9)

	durs := make([]float64, passes)
	sumDur := 0.0
	for i := 0; i < passes; i++ {
		durs[i] = 2.4 + rnd.floatIn(0, 2.2)
		sumDur += durs[i]
	}
	gapTotal := total - sumDur
	if gapTotal < float64(passes)*0.5 {
		gapTotal = float64(passes) * 0.5
	}
	weights := make([]float64, passes)
	sumW := 0.0
	for i := 0; i < passes; i++ {
		weights[i] = 0.4 + rnd.floatIn(0, 1)
		sumW += weights[i]
	}
	gaps := make([]float64, passes)
	for i := 0; i < passes; i++ {
		gaps[i] = weights[i] / sumW * gapTotal
	}
	starts := make([]float64, passes)
	t := gaps[0]
	for i := 0; i < passes; i++ {
		starts[i] = t
		t += durs[i]
		if i < passes-1 {
			t += gaps[i+1]
		}
	}

	travel := w * 1.05
	clipID := "clp" + salt
	gradID := "swp" + salt
	off, on1, on2, out := fnum(-travel), fnum(-travel*0.5), fnum(travel*0.5), fnum(travel)

	var defs strings.Builder
	defs.WriteString(`<defs><clipPath id="` + clipID + `">` + shapeGeom + `</clipPath>`)
	defs.WriteString(pearlSweepGradient(gradID, base))

	var marks strings.Builder
	marks.WriteString(`<g clip-path="url(#` + clipID + `)">`)
	for i := 0; i < passes; i++ {
		angle := fnum(rnd.floatIn(0, 360))
		startPct := starts[i] / total * 100
		durPct := durs[i] / total * 100
		rampPct := durPct * 0.32
		if rampPct > 6 {
			rampPct = 6
		}
		p0, p1, p2, p3 := startPct, startPct+rampPct, startPct+durPct-rampPct, startPct+durPct
		kf := "swp" + salt + "_" + ufmt.Sprintf("%d", i)

		closing := ""
		if p3 < 99.999 {
			closing = `100%{transform:translate(` + off + `px,0);opacity:0}`
		}
		defs.WriteString(`<style>@keyframes ` + kf + `{` +
			`0%{transform:translate(` + off + `px,0);opacity:0}` +
			fnum(p0) + `%{transform:translate(` + off + `px,0);opacity:0}` +
			fnum(p1) + `%{transform:translate(` + on1 + `px,0);opacity:1}` +
			fnum(p2) + `%{transform:translate(` + on2 + `px,0);opacity:1}` +
			fnum(p3) + `%{transform:translate(` + out + `px,0);opacity:0}` +
			closing +
			`}</style>`)

		marks.WriteString(`<g transform="rotate(` + angle + ` ` + fnum(subjX) + ` ` + fnum(subjY) + `)">` +
			`<rect x="` + fnum(subjX-w*1.3) + `" y="` + fnum(subjY-h*0.95) + `" width="` + fnum(w*2.6) + `" height="` + fnum(h*1.9) + `" fill="url(#` + gradID + `)" opacity="0" style="mix-blend-mode:screen;animation:` + kf + ` ` + fnum(total) + `s linear infinite"/>` +
			`</g>`)
	}
	marks.WriteString(`</g>`)
	defs.WriteString(`</defs>`)
	return defs.String() + marks.String()
}

func pearlRound(base, metal, salt string) string {
	gid := "prl" + salt
	r := 24.0 * stoneScale
	body := `<circle cx="` + fnum(subjX) + `" cy="` + fnum(subjY) + `" r="` + fnum(r) + `" fill="url(#` + gid + `)"/>`
	clipGeom := `<circle cx="` + fnum(subjX) + `" cy="` + fnum(subjY) + `" r="` + fnum(r) + `"/>`
	sweep := pearlSweepOverlay(salt, base, clipGeom, r*2, r*2)
	return `<defs>` + pearlLusterGradient(gid, base, metal) + `</defs>` + pearlLayers(body, gid, "") + sweep
}

func pearlOval(base, metal, salt string) string {
	gid := "prl" + salt
	rx, ry := 18.0*stoneScale, 25.0*stoneScale
	body := `<ellipse cx="` + fnum(subjX) + `" cy="` + fnum(subjY) + `" rx="` + fnum(rx) + `" ry="` + fnum(ry) + `" fill="url(#` + gid + `)"/>`
	clipGeom := `<ellipse cx="` + fnum(subjX) + `" cy="` + fnum(subjY) + `" rx="` + fnum(rx) + `" ry="` + fnum(ry) + `"/>`
	sweep := pearlSweepOverlay(salt, base, clipGeom, rx*2, ry*2)
	return `<defs>` + pearlLusterGradient(gid, base, metal) + `</defs>` + pearlLayers(body, gid, "") + sweep
}

// pearlButton is flattened rather than round -- wider than tall, the
// real "button pearl" silhouette (as if gently pressed), popular in
// jewelry specifically because the flat back sits well against skin.
func pearlButton(base, metal, salt string) string {
	gid := "prl" + salt
	rx, ry := 25.0*stoneScale, 18.0*stoneScale
	body := `<ellipse cx="` + fnum(subjX) + `" cy="` + fnum(subjY) + `" rx="` + fnum(rx) + `" ry="` + fnum(ry) + `" fill="url(#` + gid + `)"/>`
	clipGeom := `<ellipse cx="` + fnum(subjX) + `" cy="` + fnum(subjY) + `" rx="` + fnum(rx) + `" ry="` + fnum(ry) + `"/>`
	sweep := pearlSweepOverlay(salt, base, clipGeom, rx*2, ry*2)
	return `<defs>` + pearlLusterGradient(gid, base, metal) + `</defs>` + pearlLayers(body, gid, "") + sweep
}

// pearlDrop is a smooth teardrop built from two Bezier arcs -- unlike
// gemPear's faceted polygon, a real drop pearl tapers continuously, with
// no straight edges anywhere on its surface.
func pearlDrop(base, metal, salt string) string {
	gid := "prl" + salt
	// wider and taller than the round's footprint suggests: a drop only
	// fills half its bounding box, and at 20x30 it read as a seed
	w, h := 32.0*stoneScale, 42.0*stoneScale
	path := `M ` + fnum(subjX) + ` ` + fnum(subjY-h*0.55) +
		` C ` + fnum(subjX+w*0.55) + ` ` + fnum(subjY-h*0.15) + ` ` + fnum(subjX+w*0.42) + ` ` + fnum(subjY+h*0.42) + ` ` + fnum(subjX) + ` ` + fnum(subjY+h*0.48) +
		` C ` + fnum(subjX-w*0.42) + ` ` + fnum(subjY+h*0.42) + ` ` + fnum(subjX-w*0.55) + ` ` + fnum(subjY-h*0.15) + ` ` + fnum(subjX) + ` ` + fnum(subjY-h*0.55) + ` Z`
	body := `<path d="` + path + `" fill="url(#` + gid + `)"/>`
	clipGeom := `<path d="` + path + `"/>`
	sweep := pearlSweepOverlay(salt, base, clipGeom, w*1.6, h*0.9)
	return `<defs>` + pearlLusterGradient(gid, base, metal) + `</defs>` + pearlLayers(body, gid, "") + sweep
}

// pearlBaroqueOutline draws an irregular, asymmetric silhouette -- a real
// baroque pearl has no symmetry at all, which is exactly what makes it a
// baroque pearl rather than a round one.
func pearlBaroqueOutline(seed string) []pt {
	rnd := newPRNG(seed)
	n := 10
	pts := make([]pt, n)
	for k := 0; k < n; k++ {
		a := 2 * math.Pi * float64(k) / float64(n)
		rr := 21.0 * stoneScale * (0.75 + 0.4*rnd.floatIn(0, 1))
		pts[k] = pt{subjX + rr*math.Cos(a)*1.1, subjY + rr*math.Sin(a)*0.9}
	}
	return pts
}

// pearlBaroqueSmoothPath threads a quadratic Bezier through the midpoint
// of every outline segment, so the irregular outline still reads as one
// continuous organic surface -- a straight-edged polygon here would read
// as a cut facet, which a baroque pearl's surface never has.
func pearlBaroqueSmoothPath(pts []pt) string {
	n := len(pts)
	mid := func(a, b pt) pt { return pt{(a.x + b.x) / 2, (a.y + b.y) / 2} }
	start := mid(pts[n-1], pts[0])
	path := "M " + fnum(start.x) + " " + fnum(start.y)
	for k := 0; k < n; k++ {
		next := pts[(k+1)%n]
		m := mid(pts[k], next)
		path += " Q " + fnum(pts[k].x) + " " + fnum(pts[k].y) + " " + fnum(m.x) + " " + fnum(m.y)
	}
	return path + " Z"
}

func pearlBaroque(base, metal, salt string) string {
	gid := "prl" + salt
	pathD := pearlBaroqueSmoothPath(pearlBaroqueOutline("baroque" + salt))
	body := `<path d="` + pathD + `" fill="url(#` + gid + `)"/>`
	clipGeom := `<path d="` + pathD + `"/>`
	sweep := pearlSweepOverlay(salt, base, clipGeom, 40*stoneScale, 30*stoneScale)
	return `<defs>` + pearlLusterGradient(gid, base, metal) + `</defs>` + pearlLayers(body, gid, "") + sweep
}

// pearlCircled draws thin concentric growth rings over a round body --
// the defining feature of a real "circled" (or "ringed") pearl, visible
// grooves left by its own growth, not a decorative pattern.
func pearlCircled(base, metal, salt string) string {
	gid := "prl" + salt
	r := 24.0 * stoneScale
	body := `<circle cx="` + fnum(subjX) + `" cy="` + fnum(subjY) + `" r="` + fnum(r) + `" fill="url(#` + gid + `)"/>`
	ringTone := mixHex(base, "#000000", 0.12)
	rings := ""
	for _, f := range []float64{0.42, 0.58, 0.74, 0.9} {
		rings += `<circle cx="` + fnum(subjX) + `" cy="` + fnum(subjY) + `" r="` + fnum(r*f) + `" fill="none" stroke="` + ringTone + `" stroke-width="0.9" opacity="0.35"/>`
	}
	clipGeom := `<circle cx="` + fnum(subjX) + `" cy="` + fnum(subjY) + `" r="` + fnum(r) + `"/>`
	sweep := pearlSweepOverlay(salt, base, clipGeom, r*2, r*2)
	return `<defs>` + pearlLusterGradient(gid, base, metal) + `</defs>` + pearlLayers(body, gid, rings) + sweep
}

// PearlShapeNames lists the real jewelry-trade pearl shape categories --
// deliberately NOT the faceted-cut vocabulary above (ShapeNames). Round
// is the rarest/most prized (perfectly spherical); Baroque is the least
// regular (freeform, no symmetry); Circled pearls show visible
// concentric growth grooves.
var PearlShapeNames = []string{"Round", "Oval", "Button", "Drop", "Baroque", "Circled"}

// renderPearlShape is PearlShapeNames' own counterpart to renderGem.
func renderPearlShape(shapeIdx int, base, metal, salt string) string {
	switch shapeIdx {
	case 0:
		return pearlRound(base, metal, salt)
	case 1:
		return pearlOval(base, metal, salt)
	case 2:
		return pearlButton(base, metal, salt)
	case 3:
		return pearlDrop(base, metal, salt)
	case 4:
		return pearlBaroque(base, metal, salt)
	default:
		return pearlCircled(base, metal, salt)
	}
}

/* -------------------------------------- ring -------------------------------------- */

// renderRing draws the metal band (with bevel) plus the neon energy-field
// glow — fixed outer edge (never animates position), two static-geometry
// layers crossfaded via opacity only. No blur filter: an SVG <filter>
// wrapping an opacity-animated child is expensive to composite in
// WebKit specifically (confirmed via a live Safari test against a mock
// page with it removed — Chrome never showed the problem, masking it).
// The gradient's own multi-stop falloff carries the glow instead.
func renderRing(metalHi, metalLo, salt string) string {
	// Light-from-top-left tilt: instead of one smooth diagonal fade, the
	// gradient alternates hi/lo twice along the same diagonal axis, so
	// the band reads as catching more than one reflected highlight as it
	// curves — a real polished ring's "multi-band Fresnel" look, chosen
	// over a plain 2-stop fade after a live side-by-side comparison of
	// six alternative ring treatments. All three strokes (outer/main/
	// inner) reference this one gradient so the light direction is
	// consistent across the whole band, not just its center.
	gid := "ring" + salt
	// Wider tonal swing than the metal table's own hi/lo pair: the bright
	// bands lift toward white and the dark bands sink toward black, so
	// the band reads as polished metal turning through the light instead
	// of a flat painted hoop (the old hi/lo-only version read as matte).
	bright := lighten(metalHi, 0.45)
	deep := mixHex(metalLo, "#000000", 0.45)
	// Compact markup (same picture as the long form): stop offsets as
	// fractions, circles in one translated group so cx/cy/fill aren't
	// repeated -- this runs on every token read, bytes matter.
	st := func(off, c string) string { return `<stop offset="` + off + `" stop-color="` + c + `"/>` }
	defs := `<linearGradient id="` + gid + `" x2="1" y2="1">` +
		st("0", bright) + st(".12", metalHi) + st(".26", deep) + st(".4", metalLo) + st(".52", bright) +
		st(".64", metalHi) + st(".78", deep) + st(".9", metalLo) + st("1", bright) + `</linearGradient>`

	// Drop shadow under the band (grounds it), the band, then bevel edges:
	// a bright inner-top edge and a dark outer edge, the way a real
	// rounded band catches light on the side facing the lamp and falls
	// into shadow on the far side. No drawn specular arcs: they read as
	// cartoon highlights; the band gradient carries the light on its own.
	// All plain strokes, no filters.
	outer := `<g fill="none" transform="translate(` + cnum(subjX) + ` ` + cnum(subjY) + `)">` +
		`<circle r="52.6" stroke="#000" stroke-width="1.6" opacity=".45"/>` +
		`<circle r="50" stroke="url(#` + gid + `)" stroke-width="4.4"/>` +
		`<circle r="52.3" stroke="` + deep + `" stroke-width=".7" opacity=".8"/>` +
		`<circle r="47.7" stroke="` + deep + `" stroke-width=".6" opacity=".7"/>` +
		`<circle r="48.5" stroke="` + lighten(metalHi, 0.35) + `" stroke-width=".5" opacity=".45"/></g>`

	const rOut = 46.0
	const coreHalf = 0.6
	const outwardBloom = 0.9
	glowR := rOut + outwardBloom + 3
	pct := func(v float64) float64 {
		p := v / glowR * 100
		if p < 0 {
			p = 0
		}
		if p > 100 {
			p = 100
		}
		return p
	}
	// Core tinted in the metal's own tone rather than near-white, and the
	// animated layer peaks lower and breathes slower (see dur): next to a
	// realistic stone the old white neon pulse was the most stylised thing
	// on the canvas.
	coreColor := lighten(metalHi, 0.25)
	donutStops := func(inwardBloom, peakOp float64, gid string) string {
		bloomOp := peakOp * 0.35
		midOp := peakOp * 0.7
		return `<radialGradient id="` + gid + `" cx="50%" cy="50%" r="50%">` +
			`<stop offset="0%" stop-color="` + metalHi + `" stop-opacity="0"/>` +
			`<stop offset="` + pctnum(pct(rOut-inwardBloom-1.5)) + `%" stop-color="` + metalHi + `" stop-opacity="0"/>` +
			`<stop offset="` + pctnum(pct(rOut-inwardBloom)) + `%" stop-color="` + metalHi + `" stop-opacity="` + fnum(bloomOp) + `"/>` +
			`<stop offset="` + pctnum(pct(rOut-coreHalf)) + `%" stop-color="` + coreColor + `" stop-opacity="` + fnum(midOp) + `"/>` +
			`<stop offset="` + pctnum(pct(rOut)) + `%" stop-color="` + coreColor + `" stop-opacity="` + fnum(peakOp) + `"/>` +
			`<stop offset="` + pctnum(pct(rOut+coreHalf)) + `%" stop-color="` + coreColor + `" stop-opacity="` + fnum(midOp) + `"/>` +
			`<stop offset="` + pctnum(pct(rOut+outwardBloom)) + `%" stop-color="` + metalHi + `" stop-opacity="` + fnum(bloomOp) + `"/>` +
			`<stop offset="` + pctnum(pct(rOut+outwardBloom+1)) + `%" stop-color="` + metalHi + `" stop-opacity="0"/>` +
			`<stop offset="100%" stop-color="` + metalHi + `" stop-opacity="0"/></radialGradient>`
	}

	rnd := newPRNG("energy" + salt)
	gidA, gidB := "glowA"+salt, "glowB"+salt
	// 2.13-3.2 s: 75% of the original energy pulse's speed (gems.gno and
	// gemsart2 ran 1.6-2.4 s; gemsartfab had slowed it to 3.5-5.5 s)
	dur := rnd.floatIn(2.13, 3.2)
	phase := rnd.floatIn(0, dur)

	stopsA := donutStops(2.5*2.0/3.0*0.5, 0.4, gidA)
	stopsB := donutStops(8.0*2.0/3.0*0.5, 0.6, gidB)

	energy := `<defs>` + stopsA + stopsB + `</defs>` +
		`<g>` +
		`<circle cx="` + fnum(subjX) + `" cy="` + fnum(subjY) + `" r="` + fnum(glowR) + `" fill="url(#` + gidA + `)"/>` +
		`<circle cx="` + fnum(subjX) + `" cy="` + fnum(subjY) + `" r="` + fnum(glowR) + `" fill="url(#` + gidB + `)" opacity="0" class="gt-glow" style="--glow-dur:` + fnum(dur) + `s;--glow-delay:-` + fnum(phase) + `s"/>` +
		`</g>`

	return `<defs>` + defs + `</defs>` + outer + energy
}

/* ------------------------------------- motion ------------------------------------- */

const (
	motionVDur, motionHDur, motionRDur, motionSDur = 3.4, 4.66, 5.81, 6.56
	motionRotMin, motionRotMax                     = 4.0, 8.0
	motionScale                                    = 1.09
)

// applyMotion wraps content in the floating-holder animation (vertical
// float + sideways drift + left/right rock + scale pulse), each axis on
// its own independently-phased period so pieces never move in sync.
// CSS @keyframes (see styleBlock), not SMIL -- WebKit's SMIL engine
// scales badly with many concurrently-animated elements on one page,
// confirmed via a live cross-browser test. transform-origin:view-box
// on gt-r/gt-s replaces SMIL's manual translate-to-pivot/scale/
// translate-back trick, so this nests in fewer elements than before,
// not more.
// motionPhases draws a token's four motion phases and its rock angle.
// Shared with applyCascade so the fire can lock to the rock: a flash
// should happen when the stone tilts, not on a timer of its own.
func motionPhases(salt string) (vphase, hphase, rphase, sphase, rotDeg float64) {
	rnd := newPRNG("motion" + salt)
	vphase = rnd.floatIn(0, motionVDur)
	hphase = rnd.floatIn(0, motionHDur)
	rphase = rnd.floatIn(0, motionRDur)
	sphase = rnd.floatIn(0, motionSDur)
	rotDeg = rnd.floatIn(motionRotMin, motionRotMax)
	return
}

func applyMotion(content, salt string) string {
	vphase, hphase, rphase, sphase, rotDeg := motionPhases(salt)

	// The rock and the pulse pivot on the ring centre by geometry, not by
	// transform-box/transform-origin: the motion groups sit inside a group
	// already translated to (subjX, subjY), so their own origin IS the ring
	// centre, and the content is shifted back inside them. Safari has
	// mishandled transform-box inside <img> SVGs, which swings a stone
	// around the image corner instead of its centre.
	return `<g transform="translate(` + fnum(subjX) + ` ` + fnum(subjY) + `)">` +
		`<g class="gt-v" style="--v-dur:` + fnum(motionVDur) + `s;--v-delay:-` + fnum(vphase) + `s">` +
		`<g class="gt-h" style="--h-dur:` + fnum(motionHDur) + `s;--h-delay:-` + fnum(hphase) + `s">` +
		`<g class="gt-r" style="--r-dur:` + fnum(motionRDur) + `s;--r-delay:-` + fnum(rphase) + `s;--rot-deg:` + fnum(rotDeg) + `deg">` +
		`<g class="gt-s" style="--s-dur:` + fnum(motionSDur) + `s;--s-delay:-` + fnum(sphase) + `s">` +
		`<g transform="translate(-` + fnum(subjX) + ` -` + fnum(subjY) + `)">` +
		content + `</g></g></g></g></g></g>`
}

/* ------------------------------- ring and stone size ------------------------------- */
// Chosen 2026-09-26 from side-by-sides of several sizes (100 pieces each,
// all animated): the ring is drawn 16% larger and the stone at scale 1.21
// (was 0.78), so a bigger stone still keeps clear of the band. Both sit
// sizeLift units higher so the larger ring clears the chain plate (top at
// y 134), and the status dot moves out so it does not touch the band. The
// ring is scaled as one group around its own centre: its strokes, bevel
// and glow keep their proportions. Plain group transforms, no filters.
const (
	ringScale = 1.16
	sizeLift  = 6.0
)

func setRing(els string) string {
	return `<g transform="translate(` + fnum(subjX) + ` ` + fnum(subjY-sizeLift) + `) scale(` + fnum(ringScale) + `) translate(-` + fnum(subjX) + ` -` + fnum(subjY) + `)">` + els + `</g>`
}
func setStone(els string) string { return `<g transform="translate(0 -` + fnum(sizeLift) + `)">` + els + `</g>` }
func setBadge(els string) string { return `<g transform="translate(5 2)">` + els + `</g>` }

/* ---------------------------------- status badge ---------------------------------- */

const dotX, dotY = subjX + 50, subjY + 42

func renderStatusBadge(active bool) string {
	if active {
		return `<circle cx="` + fnum(dotX) + `" cy="` + fnum(dotY) + `" r="4" fill="#7fd88f"/>` +
			// r starts at 4 (the solid dot's own radius, so the ring
			// begins flush with its edge) and scales up via transform --
			// see styleBlock's gt-kf-badge-pulse comment for why not r.
			// pulse ring drawn at the origin of a translated group, so its
			// scale grows from the dot's own centre in every browser
			`<g transform="translate(` + fnum(dotX) + ` ` + fnum(dotY) + `)"><circle r="4" fill="none" stroke="#7fd88f" stroke-width="1.2" class="gt-badge-pulse" opacity="0.8"/></g>`
	}
	return `<circle cx="` + fnum(dotX) + `" cy="` + fnum(dotY) + `" r="4" fill="#5a5f6b"/>`
}

/* ------------------------------------ facet fire ------------------------------------ */
// The stone's sparkle, modelled on what a cut diamond does under a
// moving light rather than on a decorative shimmer:
//   - scintillation: a facet flashes on sharply and decays, in a third
//     of a second, not a slow symmetric fade;
//   - fire: the flash is white at its peak and takes on that facet's
//     spectral colour as it dies -- colour follows brilliance;
//   - sweep: a flash passes ACROSS the stone in one direction (facets
//     ordered by their projection along a random sweep axis), and only
//     about half of them light on any pass, so it stays sparse;
//   - motion-locked: the sweeps sit on the MID-swings of the rock
//     animation (see motionPhases and applyCascade's delay), where the
//     stone turns fastest and a real reflection moves fastest, and each
//     sweep travels the way the stone is turning at that moment -- one
//     way on the clockwise swing, the reverse on the way back -- along
//     the axis a fixed top-left light traces across a turning stone. So
//     the sparkle reads as caused by the motion. A few lone pinpoint
//     flashes at random times are the exception.
// Cost is unchanged from the old cascade: one solid-filled overlay path
// per lit facet, animated on opacity and fill only.

// facetSpan is one self-closing facet element found in renderGem's own
// markup, in the same left-to-right order it was drawn -- which is also
// each facet's real adjacency order around its ring, since every gem_*
// function draws its ring in one continuous angular sweep. ringMember
// distinguishes a real facet (class="f", set by facetStyle.facet) from
// the one non-ring table/center/backing element each shape draws
// without it -- that one stays static, outside the cascade.
type facetSpan struct {
	start, end int
	ringMember bool
}

// scanFacetSpans walks renderGem's own markup once, left to right, with
// plain string scanning rather than regexp -- this runs on every
// TokenURI/Render call, and CollectionSummary/WalletSummary's own
// pagination fix already established that anything unbounded or
// unnecessarily expensive in a per-token read path becomes a real "out
// of gas" failure at real collection sizes, not a theoretical concern.
func scanFacetSpans(markup string) []facetSpan {
	var spans []facetSpan
	i := 0
	for {
		rel := strings.Index(markup[i:], "<")
		if rel < 0 {
			break
		}
		start := i + rel
		relEnd := strings.Index(markup[start:], "/>")
		if relEnd < 0 {
			break
		}
		end := start + relEnd + 2
		tag := markup[start:end]
		i = end
		isFacetTag := strings.HasPrefix(tag, "<path") || strings.HasPrefix(tag, "<circle") || strings.HasPrefix(tag, "<polygon")
		if !isFacetTag {
			continue
		}
		spans = append(spans, facetSpan{start: start, end: end, ringMember: strings.Contains(tag, `class="f"`)})
	}
	return spans
}


// applyCascade is the stone's fire. Every flash-capable facet (class
// "f", chosen in renderGem3D) gets a duplicate of its path stacked above
// the facets, and ALL of them share two keyframe rules per stone instead
// of owning one each -- the per-facet keyframe blocks were several
// kilobytes of every token. What differs per facet rides on the element
// itself: --c its spectral colour, --o its peak strength, and an
// animation-delay that places it in the sweep.
//
// The flash shape is unchanged from the hand-scheduled version: white at
// the peak, the facet's own spectral colour on the decay, under a second.
// Rule A fires on the rock animation's clockwise mid-swing and sweeps
// along fireSweepAxis; rule B fires on the return swing and sweeps the
// other way. Facets are split between the two, so a stone sparkles
// forth and back in time with its own motion (period = two rock cycles,
// delays offset from the token's rock phase, see motionPhases).
const (
	fireSweepAxis = -35.0 * math.Pi / 180
	fireSweepSpan = 1.6 // seconds a sweep takes to cross the stone
)

func applyCascade(markup, tidStr string, fs *facetStyle) (overlay string, css string) {
	if fs == nil || len(fs.ringCent) == 0 {
		return "", ""
	}
	spans := scanFacetSpans(markup)
	rnd := newPRNG("fire" + tidStr)
	_, _, rphase, _, _ := motionPhases(tidStr)
	period := 2 * motionRDur
	axis := fireSweepAxis + rnd.floatIn(-0.3, 0.3)
	dx, dy := math.Cos(axis), math.Sin(axis)

	// flash: 0 -> white peak -> coloured decay -> 0, in the first ~8% of
	// the period (~0.9s); B is the same shape half a period later.
	ka, kb := "fa"+tidStr, "fb"+tidStr
	shape := func(at float64) string {
		return fnum1(at) + `%{opacity:0}` + fnum1(at+2) + `%{opacity:var(--o);fill:#fff}` +
			fnum1(at+4.5) + `%{opacity:.4;fill:var(--c)}` + fnum1(at+8) + `%{opacity:0}`
	}
	per := fnum(period)
	// opacity="0" rides on each overlay as an attribute, not only in this
	// CSS: a thumbnailer that ignores CSS animation (or CSS) must see the
	// resting state, not an unfilled (black) copy of every flash facet.
	css = `.` + ka + `{animation:` + ka + ` ` + per + `s linear infinite}.` + kb + `{animation:` + kb + ` ` + per + `s linear infinite}` +
		`@keyframes ` + ka + `{` + shape(12.5) + `100%{opacity:0}}` +
		`@keyframes ` + kb + `{` + shape(62.5) + `100%{opacity:0}}`

	var out strings.Builder
	type glintAt struct {
		x, y, delay float64
		rule        string
	}
	var cands []glintAt
	ringIdx := -1
	for _, span := range spans {
		if !span.ringMember {
			continue
		}
		ringIdx++
		if ringIdx >= len(fs.ringCent) {
			break
		}
		c := fs.ringCent[ringIdx]
		color, colorOp := fs.flash.sample(c.x, c.y)
		// position along the sweep axis, -1..1 across the stone
		pos := ((c.x-subjX)*dx + (c.y-gemCY)*dy) / (30 * stoneScale)
		name := ka
		if rnd.floatIn(0, 1) < 0.5 {
			name, pos = kb, -pos
		}
		// the rock runs at delay -rphase; the flash windows sit at 12.5%
		// and 62.5% of two rock cycles = the rock's two mid-swings
		delay := rphase - 0.25*motionRDur + period - pos*fireSweepSpan/2
		tag := markup[span.start:span.end]
		geomEnd := strings.Index(tag, `" fill=`)
		if geomEnd < 0 {
			continue
		}
		cands = append(cands, glintAt{c.x, c.y, delay, name})
		out.WriteString(tag[:geomEnd] + `" opacity="0" class="` + name + `" style="--o:` + fnum(math.Round(math.Min(1, rnd.floatIn(0.85, 1.05)*colorOp)*10)/10) + `;--c:` + hex3(color) +
			`;animation-delay:-` + fnum1(delay) + `s"/>`)
	}
	// Star glints: the brightest moment of a real diamond is a pinpoint that
	// throws four rays. Three facets (one on the forward sweep, two spread
	// out) each get a four-point star that pops at that facet's white peak
	// -- same delay as its flash, so it lands exactly as the facet goes
	// white -- scales up with a small twist and collapses. Plain paths on
	// transform + opacity only; opacity="0" rests them for thumbnailers.
	if len(cands) > 0 && fs.prof.sat >= 0.3 {
		n := 3
		if fs.prof.sat < 0.6 {
			n = 2 // quartz, topaz: less fire, fewer stars
		}
		ga, gb := "ga"+tidStr, "gb"+tidStr
		star := func(at float64) string {
			return fnum1(at+0.6) + `%{opacity:0;transform:scale(.2) rotate(0)}` +
				fnum1(at+2.2) + `%{opacity:1;transform:scale(1) rotate(25deg)}` +
				fnum1(at+4.4) + `%{opacity:0;transform:scale(.35) rotate(55deg)}`
		}
		css += `.` + ga + `,.` + gb + `{opacity:0}` +
			`.` + ga + `{animation:` + ga + ` ` + per + `s linear infinite}.` + gb + `{animation:` + gb + ` ` + per + `s linear infinite}` +
			`@keyframes ` + ga + `{0%{opacity:0}` + star(12.5) + `100%{opacity:0}}` +
			`@keyframes ` + gb + `{0%{opacity:0}` + star(62.5) + `100%{opacity:0}}`
		r := 7.5 * stoneScale
		w := 0.9 * stoneScale
		ray := `M0 -` + fnum1(r) + `L` + fnum1(w) + ` -` + fnum1(w) + `L` + fnum1(r) + ` 0L` + fnum1(w) + ` ` + fnum1(w) +
			`L0 ` + fnum1(r) + `L-` + fnum1(w) + ` ` + fnum1(w) + `L-` + fnum1(r) + ` 0L-` + fnum1(w) + ` -` + fnum1(w) + `Z`
		var g strings.Builder
		used := map[int]bool{}
		for k := 0; k < n && k < len(cands); k++ {
			i := rnd.intn(len(cands))
			for tries := 0; used[i] && tries < len(cands); tries++ {
				i = (i + 1) % len(cands)
			}
			used[i] = true
			c := cands[i]
			cls := "ga" + tidStr
			if c.rule == kb {
				cls = "gb" + tidStr
			}
			g.WriteString(`<g transform="translate(` + fnum1(c.x) + ` ` + fnum1(c.y) + `)"><g class="` + cls + `" opacity="0" style="animation-delay:-` + fnum1(c.delay) + `s">` +
				`<path d="` + ray + `" fill="#fff"/><circle r="` + fnum1(1.1*stoneScale) + `" fill="#fff"/></g></g>`)
		}
		fs.glints = g.String()
	}
	return out.String(), css
}

/* ---------------------------------- label + serial ---------------------------------- */

func renderMetalLabelRect(metalHi, metalLo string, x, y, w, h, rx float64, salt string) string {
	// Echoes the ring's multi-band tilt but heavily muted — a soft
	// two-step blend instead of the ring's hard alternating stops, so the
	// bar doesn't visually fight the chain-name text sitting on top of it.
	gid := "lg" + salt
	// A brushed metal plate rather than a flat bar: a horizontal sweep
	// with a bright band, a dark outline that seats it on the canvas, a
	// light top edge and dark bottom edge (bevel), and a rivet in each
	// corner. The chain text is drawn on top by RenderTokenSVG with an
	// engraved shadow (see there). Plain shapes, one gradient.
	bright := lighten(metalHi, 0.4)
	deep := mixHex(metalLo, "#000000", 0.5)
	st := func(off, c string) string { return `<stop offset="` + off + `" stop-color="` + c + `"/>` }
	defs := `<linearGradient id="` + gid + `">` +
		st("0", metalLo) + st(".22", metalHi) + st(".42", bright) + st(".62", metalHi) + st("1", metalLo) + `</linearGradient>`
	rect := `<rect x="` + cnum(x) + `" y="` + cnum(y) + `" width="` + cnum(w) + `" height="` + cnum(h) + `" rx="` + cnum(rx) + `" fill="url(#` + gid + `)" stroke="` + deep + `" stroke-width=".8"/>`
	// Bevel edges follow the plate's own rounded outline, inset a hair:
	// a thin soft highlight along the top chamfer, a thin shade along the
	// bottom one -- low contrast, the way a real machined edge reads.
	const in_ = 0.9
	arc := ` a` + cnum(rx-in_) + ` ` + cnum(rx-in_) + ` 0 0 `
	d := cnum(rx - in_)
	edges := `<g fill="none" stroke-linecap="round">` +
		`<path d="M` + cnum(x+in_) + ` ` + cnum(y+rx) + arc + `1 ` + d + ` -` + d + `H` + cnum(x+w-rx) + arc + `1 ` + d + ` ` + d + `" stroke="` + lighten(metalHi, 0.45) + `" stroke-width=".45" opacity=".4"/>` +
		`<path d="M` + cnum(x+in_) + ` ` + cnum(y+h-rx) + arc + `0 ` + d + ` ` + d + `H` + cnum(x+w-rx) + arc + `0 ` + d + ` -` + d + `" stroke="` + deep + `" stroke-width=".5" opacity=".5"/></g>`
	// Slotted screws: a shadowed countersink, a head a shade off the plate
	// tone with a soft sheen up-left, and a slot at a different angle per
	// screw (and per token). The head is defined once and placed with
	// <use>; all four slots are one path -- bytes matter on every read.
	sid := "sh" + salt
	defs += `<g id="` + sid + `"><circle cx=".15" cy=".2" r="1.6" fill="` + deep + `" opacity=".55"/>` +
		`<circle r="1.3" fill="` + mixHex(metalLo, metalHi, 0.4) + `" stroke="` + deep + `" stroke-width=".25"/>` +
		`<circle cx="-.4" cy="-.4" r=".75" fill="` + lighten(metalHi, 0.3) + `" opacity=".35"/></g>`
	seed := 0
	for k := 0; k < len(salt); k++ {
		seed += int(salt[k])
	}
	heads, slots := "", ""
	n := 0
	for _, px := range []float64{x + 4.2, x + w - 4.2} {
		for _, py := range []float64{y + 3.7, y + h - 3.7} {
			heads += `<use href="#` + sid + `" x="` + cnum(px) + `" y="` + cnum(py) + `"/>`
			ang := float64((seed*37+n*71)%180) * math.Pi / 180
			dx, dy := 0.9*math.Cos(ang), 0.9*math.Sin(ang)
			slots += `M` + cnum(px-dx) + ` ` + cnum(py-dy) + `l` + cnum(2*dx) + ` ` + cnum(2*dy)
			n++
		}
	}
	rivets := heads + `<path d="` + slots + `" stroke="` + deep + `" stroke-width=".45" stroke-linecap="round"/>`
	return `<defs>` + defs + `</defs>` + rect + edges + rivets
}

// Plate lettering. SVGs shown as <img> can't load web fonts, so this is a
// system-font stack: DIN-style engineering capitals where the OS has one
// (DIN Alternate on Apple, Bahnschrift on Windows, Roboto Condensed on
// Android), tracked out like stamped nameplate type. Engraved rather than
// embossed: the letters sit in the plate and their lower lip catches the
// light, so the highlight copy goes a hair BELOW the fill.
const (
	plateFont    = `'DIN Alternate',Bahnschrift,'Roboto Condensed',sans-serif`
	plateSize    = 8.6
	plateSpacing = 1.1
	plateMaxW    = 100.0
)

func renderPlateText(label, fill, metalHi string) string {
	g := `<g font-size="` + cnum(plateSize) + `" letter-spacing="` + cnum(plateSpacing) + `" text-anchor="middle" font-family="` + plateFont + `" font-weight="700"`
	// Rough width estimate (condensed caps ~0.52em plus tracking); only a
	// label that would run into the screws gets squeezed to fit.
	if est := float64(len(label))*(plateSize*0.52+plateSpacing); est > plateMaxW {
		g += ` textLength="` + cnum(plateMaxW) + `" lengthAdjust="spacingAndGlyphs"`
	}
	x := cnum(subjX)
	return g + `><text x="` + x + `" y="144.9" fill="` + lighten(metalHi, 0.5) + `" opacity=".45">` + label + `</text>` +
		`<text x="` + x + `" y="144.4" fill="` + fill + `">` + label + `</text></g>`
}

// renderSerialText uses the token's REAL assigned ID (already the exact
// Crockford-base32 seqid format gno.land itself produces) — no lookup
// table or reimplemented encoding needed, unlike the Python prototype
// which had to hardcode a verified sample of real IDs since it couldn't
// call the real package directly.
func renderSerialText(tidStr, color string) string {
	return `<text x="` + fnum(subjX) + `" y="159.5" font-size="6.5" text-anchor="middle" fill="` + color + `" font-family="ui-monospace,monospace" opacity="0.85">#` + tidStr + `</text>`
}

/* ------------------------------- stone / color / metal tables ------------------------------- */

type namedColor struct{ hex, name string }

// stoneByChain, stonePalettes, and stoneNames are mutable, not const --
// a deliberate departure from this file's "pure functions, no state"
// design (see the package doc comment). Originally hardcoded switch
// statements covering only Topaz-1/Sapphire-1, seeded here with the
// same real gemology research, but now editable via SetStoneForChain/
// AddStoneColor (nftminter.gno) so a FUTURE gno.land testnet generation
// that gets a real gem codename can be recognized without a contract
// redeploy — the whole point of putting this data in state instead of
// source.
var stoneByChain = map[string]string{
	"TOPAZ-1":    "Topaz",
	"SAPPHIRE-1": "Sapphire",
	"PEARL-1":    "Pearl",
	// Mainnet. Diamond: the hardest, most-dispersive stone for the chain
	// that is final, and the one gem every collector reads at a glance.
	"GNOLAND-1": "Diamond",
}

// All hex values here (except Red, see "Not Set" below) are the original
// palette run through the exact CSS/SVG feColorMatrix type="saturate"
// formula at s=1.5 (150%) -- confirmed against a live side-by-side
// comparison (three saturation levels, same six real minted pieces)
// before choosing this one, "the enhanced saturation" over both the
// original 100% and a more extreme 200% option. Not a hand-picked
// repaint -- every value is the deterministic output of that one matrix,
// so hues stay true, only intensity increases.
//
// Baked directly into these constants rather than applied via a live
// <filter> (or an equivalent Go function called on every render): a
// live filter under several CSS-animated ancestors, times potentially
// dozens of gems rendered on one page at once, was a real, confirmed
// Safari motion-jitter source in this project (same category of fix
// already applied once before, to the rings' glow effect). Precomputing
// the target color once, here, and shipping it as an ordinary static
// fill value removes that cost entirely -- nothing left for any browser
// to re-rasterize. The matrix itself, if a future palette addition ever
// needs to reproduce it by hand:
//   a=.213+.787s  b=.715-.715s  c=.072-.072s
//   d=.213-.213s  e=.715+.285s  f=.072-.072s
//   g=.213-.213s  h=.715-.715s  i=.072+.928s
//   R'=a*R+b*G+c*B  G'=d*R+e*G+f*B  B'=g*R+h*G+i*B  (s=1.5 here)
var stonePalettes = map[string][]namedColor{
	// Accuracy pass (2026-09-25), five hand-set exceptions to the matrix
	// rule, each because the boosted value named the wrong stone: blue
	// sapphire is royal/cornflower blue, not cyan (#00b6ff read as
	// aquamarine); green sapphire is teal-green, not emerald green;
	// padparadscha is by definition pinkish-orange (lotus), not orange-
	// red; natural blue topaz is pale sky blue (saturated blue topaz is
	// irradiated); sherry topaz is yellowish/reddish brown, not orange.
	"Sapphire": {
		{"#2a5fe0", "Blue"}, {"#ff6ea4", "Pink"}, {"#ff8501", "Orange"}, {"#ffd500", "Yellow"},
		{"#1aa88a", "Green"}, {"#a658ff", "Violet"}, {"#e6e9f8", "White"}, {"#ff8f72", "Padparadscha"},
	},
	"Topaz": {
		{"#f5edd1", "Colorless"}, {"#ffa300", "Imperial"}, {"#ffd100", "Golden"},
		{"#c96a28", "Sherry Brown"}, {"#86cdf2", "Sky Blue"}, {"#ff96ba", "Pink"},
	},
	// Not Set was originally a muted, deliberately non-gem palette (dull
	// grays), reasoning that a chain with no assigned stone shouldn't get
	// gem-like colors. Replaced per request -- these read as dull/boring
	// in practice, and this stone accounts for the large majority of
	// chains (every testnet except Topaz-1/Sapphire-1), so it now gets
	// the full generic gem-color spectrum instead: every hue already used
	// by Sapphire/Topaz (this is intentional reuse, not new hex values --
	// a "Not Set" piece can land on any color a real gem might), plus Red,
	// which neither Sapphire nor Topaz can use (Sapphire excludes it
	// because red corundum is classified as ruby, a separate gem name).
	// Red is the one deliberate exception to this file's "every hex is
	// the s=1.5 matrix output" rule above -- the matrix-derived #ff4b4b
	// read too saturated in practice, so it's hand-tuned ~12.5% less
	// saturated (#f45656) instead, per request.
	// Crystal (appended last, so every earlier index keeps its meaning)
	// is the clearest stone in the pool. Not called Transparent: in
	// gemology transparency is diaphaneity, a separate axis from colour,
	// and this is a colour list. See fireProfileFor for how it is
	// painted -- the hex here is only what the metadata reports and
	// what the rim stroke lightens from.
	// Quartz (2026-09-25) replaces "Not Set" for every chain without its
	// own codename (TEST-1..13, BETANET, any future one): a generic
	// "Red Asscher" was not a real gem, and quartz is the one gem family
	// whose natural varieties cover the range. Hand-set real colours:
	// Rock Crystal (colourless), Amethyst (purple), Citrine (yellow to
	// orange-yellow), Rose Quartz (pale, slightly milky pink), Smoky
	// Quartz (grey-brown), Prasiolite (pale leek green; mostly heated
	// amethyst, rare in nature). Weighted in colorWeights.
	"Quartz": {
		{"#eef2f7", "Rock Crystal"}, {"#9b59d6", "Amethyst"}, {"#f2b01e", "Citrine"},
		{"#f5b9ca", "Rose Quartz"}, {"#7d6250", "Smoky Quartz"}, {"#a9d9a2", "Prasiolite"},
	},
	// Pearl (PEARL-1, added for the Pearl testnet generation) is the one
	// deliberate exception to this file's "every hex is the s=1.5 matrix
	// output" rule above, for a real gemological reason rather than a
	// stylistic one: pearls are organic gems with a soft nacre sheen, not
	// faceted crystals -- the same saturation boost that makes Sapphire/
	// Topaz read as vivid gemstones would misrepresent what a pearl
	// actually looks like. These 8 are real naturally-occurring pearl
	// body colors (not dyed), sourced from gemological references, hand-
	// tuned to a muted/pearly range instead of the boosted-saturation one:
	// white (Akoya), cream, black (Tahitian -- reads as a very dark grey/
	// green, never true black), silver, gold (South Sea), pink and peach
	// (freshwater), and lavender (freshwater, one of the rarer natural
	// overtones).
	// Diamond (GNOLAND-1) is hand-picked like Pearl, not the s=1.5 matrix:
	// real diamond colour grades. Colorless first (D-F, the classic stone),
	// then the natural "fancy" colours in the trade's own names, including
	// the browns sold as Champagne and Cognac, and Black (opaque, a metallic
	// shine and no fire -- fireProfileFor paints it separately).
	"Diamond": {
		{"#f3f6fc", "Colorless"}, {"#ffc400", "Fancy Yellow"}, {"#ff4f9a", "Fancy Pink"},
		{"#1f8fff", "Fancy Blue"}, {"#14c46e", "Fancy Green"}, {"#d9a560", "Champagne"},
		{"#b4561a", "Cognac"}, {"#2b2d34", "Black"},
		// appended 2026-09-25, so every earlier index keeps its meaning;
		// red diamonds are purplish-red in life, purple ones are mostly
		// violet-purple
		{"#e0243a", "Red"}, {"#ff7a1a", "Orange"}, {"#9b4fd6", "Purple"},
	},
	"Pearl": {
		{"#f8f6f0", "White"}, {"#f0e4c8", "Cream"}, {"#3a3a3c", "Black"}, {"#c8cdd4", "Silver"},
		{"#d4af6a", "Gold"}, {"#f0d4dc", "Pink"}, {"#f2c9a8", "Peach"}, {"#d8cbe0", "Lavender"},
	},
}

// colorWeights is how often each palette entry is drawn at mint, in
// parts per 100 by palette index. Diamond and Quartz are weighted, in the order
// of real-world rarity: colourless and the yellows and browns are what
// the mines mostly give, pink/blue/green are rare, red is the rarest
// diamond there is. Every other stone draws its colours evenly. A colour
// appended later (AddStoneColor) with no weight here gets
// defaultColorWeight.
var colorWeights = map[string][]int{
	//            Colorless Yellow Pink Blue Green Champagne Cognac Black Red Orange Purple
	"Diamond": {30, 18, 5, 4, 3, 14, 12, 8, 1, 3, 2},
	// Rock Crystal and Amethyst are the commonest quartz, Citrine and Smoky
	// next, Rose Quartz is rarely clear enough to facet, Prasiolite rare.
	"Quartz": {25, 25, 18, 9, 18, 5},
}

const defaultColorWeight = 5

func colorWeight(stone string, idx int) int {
	w, ok := colorWeights[stone]
	if !ok {
		return 1
	}
	if idx < len(w) {
		return w[idx]
	}
	return defaultColorWeight
}

// PickColorIndex maps a uniform random roll to a palette index for stone,
// honouring colorWeights. The mint realm calls this instead of an even
// intn(ColorPaletteSize(stone)).
func PickColorIndex(stone string, roll uint64) int {
	n := ColorPaletteSize(stone)
	total := 0
	for i := 0; i < n; i++ {
		total += colorWeight(stone, i)
	}
	r := int(roll % uint64(total))
	for i := 0; i < n; i++ {
		r -= colorWeight(stone, i)
		if r < 0 {
			return i
		}
	}
	return n - 1
}

// ColorProbability is the chance (0..1) that a mint of stone draws colour
// idx -- the same weights PickColorIndex uses. The mint realm multiplies
// it into a piece's Rarity tier.
func ColorProbability(stone string, idx int) float64 {
	n := ColorPaletteSize(stone)
	total := 0
	for i := 0; i < n; i++ {
		total += colorWeight(stone, i)
	}
	return float64(colorWeight(stone, idx)) / float64(total)
}

// ColorRarityCSV lists "name:percent" for every colour of stone, e.g. for
// a mint page's odds table. Percent has one decimal.
func ColorRarityCSV(stone string) string {
	n := ColorPaletteSize(stone)
	total := 0
	for i := 0; i < n; i++ {
		total += colorWeight(stone, i)
	}
	out := make([]string, n)
	for i := 0; i < n; i++ {
		pm := colorWeight(stone, i) * 1000 / total
		out[i] = colorForStone(stone, i).name + ":" + ufmt.Sprintf("%d.%d", pm/10, pm%10)
	}
	return strings.Join(out, ";")
}

// ChainAlwaysActive: mainnet never sunsets, so a GNOLAND-1 piece always
// shows the green active light. RenderTokenSVG forces it; the mint realm
// should record Active=true for it too so the metadata agrees.
func ChainAlwaysActive(chain string) bool { return chain == "GNOLAND-1" }

// stoneNames tracks insertion order for deterministic listing (Go/Gno
// map iteration order is randomized) -- kept in sync with stonePalettes
// by registerStoneName, called from both AddStoneColor and
// SetStoneForChain (nftminter.gno).
var stoneNames = []string{"Sapphire", "Topaz", "Pearl", "Diamond", "Quartz"}

func registerStoneName(stone string) {
	for _, s := range stoneNames {
		if s == stone {
			return
		}
	}
	stoneNames = append(stoneNames, stone)
}

// SetStoneForChain and AddStoneColor live here (not in nftminter.gno's own
// wrapper functions of the same purpose) because they mutate this
// package's own private maps -- stoneByChain/stonePalettes/stoneNames
// aren't visible outside this package once gemsart is its own separate
// deploy, unlike when this was one combined realm. nftminter.gno's
// SetStoneForChain/AddStoneColor now just assertOwner() then delegate here.
func SetStoneForChain(chainName, stone string) {
	stoneByChain[chainName] = stone
	registerStoneName(stone)
}

func AddStoneColor(stone, hex, name string) {
	stonePalettes[stone] = append(stonePalettes[stone], namedColor{hex: hex, name: name})
	registerStoneName(stone)
}

// StoneNamesCSV lists every registered stone name, semicolon-separated,
// in the order each was first introduced.
func StoneNamesCSV() string {
	return strings.Join(stoneNames, ";")
}

// ColorPaletteCSV lists stone's full color palette as "hex:name;...", in
// colorIdx order. Implemented here rather than in nftminter.gno since it
// needs namedColor's own unexported hex/name fields.
func ColorPaletteCSV(stone string) string {
	palette := stonePalettes[stone]
	pairs := make([]string, len(palette))
	for i, c := range palette {
		pairs[i] = c.hex + ":" + c.name
	}
	return strings.Join(pairs, ";")
}

// MetalToneHex reports metalName's hi/lo gradient tones as "hi;lo", or ""
// if unrecognized. Implemented here for the same reason as
// ColorPaletteCSV -- needs metalTone's own unexported hi/lo fields.
func MetalToneHex(metalName string) string {
	t, ok := metals[metalName]
	if !ok {
		return ""
	}
	return t.hi + ";" + t.lo
}

// StoneForChain: only gno.land testnet generations that were actually
// given a gemstone codename (Topaz-1, Sapphire-1 at launch) get one —
// every other/future chain is "Not Set" rather than a guessed mineral
// name, unless the owner explicitly assigns one via SetStoneForChain.
func StoneForChain(chain string) string {
	if s, ok := stoneByChain[chain]; ok {
		return s
	}
	return "Quartz"
}

// colorForStone looks up colorIdx in the palette matching stone,
// clamping out-of-range indices instead of panicking — AddTraitPreset
// validates at write time, this is just defense in depth for read time.
// A stone with no palette yet (registered via SetStoneForChain but
// never given a color via AddStoneColor) falls back to "Not Set"'s
// palette rather than indexing into an empty slice.
func colorForStone(stone string, colorIdx int) namedColor {
	palette := stonePalettes[stone]
	if len(palette) == 0 {
		palette = stonePalettes["Quartz"]
	}
	if colorIdx < 0 {
		colorIdx = 0
	}
	if colorIdx >= len(palette) {
		colorIdx = len(palette) - 1
	}
	return palette[colorIdx]
}

// ColorPaletteSize reports how many colors are valid for stone, so
// AddTraitPreset can validate a caller-supplied colorIdx. Same
// empty-palette fallback as colorForStone, for the same reason.
func ColorPaletteSize(stone string) int {
	if n := len(stonePalettes[stone]); n > 0 {
		return n
	}
	return len(stonePalettes["Quartz"])
}

// FindShapeIndex reverse-maps a rendered "Shape" trait value (e.g.
// "Oval") back to its index into ShapeNames. A source realm for a
// migration only ever exposes the rendered trait STRING (via
// CollectionSummary), never the raw index a migrated token would need
// to regenerate its own art instead of storing a full copy of it — this
// closes that gap for the migration tooling (see
// AddMigrationSnapshotEntry). ok is false if name doesn't match any
// current shape (not expected for anything this realm's own gems.gno
// produced, but a caller should treat that as "unrecognized," not guess).
// FindShapeIndex takes stone (from StoneForChain) since Pearl draws
// shapeIdx from a completely different list (PearlShapeNames, not
// ShapeNames) -- a rendered "Baroque" only resolves against the right
// one.
func FindShapeIndex(stone, name string) (idx int, ok bool) {
	names := ShapeNames
	if stone == "Pearl" {
		names = PearlShapeNames
	}
	for i, s := range names {
		if s == name {
			return i, true
		}
	}
	return -1, false
}

// FindColorIndex reverse-maps a rendered "Color" trait value back to
// its index in chain's own stone palette — colorIdx is only meaningful
// relative to a specific stone (derived from chain via StoneForChain),
// not a single global color list, so this needs the chain too. Same
// migration-tooling purpose as FindShapeIndex.
func FindColorIndex(chain, colorName string) (idx int, ok bool) {
	stone := StoneForChain(chain)
	palette := stonePalettes[stone]
	if len(palette) == 0 {
		palette = stonePalettes["Quartz"]
	}
	for i, c := range palette {
		if c.name == colorName {
			return i, true
		}
	}
	return -1, false
}

type metalTone struct{ hi, lo string }

// metals holds each metal's ring/label gradient tones. A var rather than
// a const purely because Gno doesn't allow map literals as consts, not
// because it's meant to be mutable -- no exported function reassigns it
// (nftminter.gno's MetalToneHex is read-only), so a minted piece's ring
// color is fixed the moment it's revealed, same as every other trait.
// Gold/Silver/Bronze are two darkening
// passes down from their original brighter values; Platinum stays at
// ONE pass (not two) and Obsidian is unchanged. Verified byte-for-byte
// against all 100 pieces of the confirmed "Latest iteration, all
// hundred (mask applied)" reference batch -- every non-Platinum ring
// matched the two-pass tone exactly, but every Platinum ring in that
// same confirmed batch used the one-pass tone, not two; a later commit
// had mistakenly carried Platinum through the second darkening pass
// too. Reverted just that one entry to match the confirmed reference.
var metals = map[string]metalTone{
	"Gold":     {"#a48b3f", "#6a5117"},
	"Silver":   {"#95989c", "#5e646c"},
	"Bronze":   {"#865b34", "#52391d"},
	"Platinum": {"#c3c6c8", "#87909a"},
	"Obsidian": {"#3a3d47", "#0d0e12"},
}

// MetalNames is an ordered counterpart to metals -- Go/Gno map iteration
// order is randomized, so on-the-fly random trait assembly (MintAssembled,
// nftminter.gno) needs an indexable slice to pick a random metal from.
var MetalNames = []string{"Gold", "Silver", "Bronze", "Platinum", "Obsidian"}

type metalLabelTone struct{ bg, text string }

var metalLabel = map[string]metalLabelTone{
	"Gold":     {"#f4d060", "#04121a"},
	"Silver":   {"#dfe4ea", "#04121a"},
	"Bronze":   {"#c9884f", "#04121a"},
	"Platinum": {"#eef2f5", "#04121a"},
	"Obsidian": {"#5a5f6b", "#e8e9f0"},
}

/* --------------------------------- full assembly --------------------------------- */

// RenderTokenSVG assembles one token's complete SVG from its small trait
// selection, mirroring badge() in the Python prototype exactly (same
// element order, same layout constants). `salt` seeds every per-piece
// animation timing and every gradient id — the token's own real ID
// (tidStr), so nothing here is computed before mint assigns one.
// RenderTokenThumbSVG is RenderTokenSVG for a list thumbnail (a gnoweb
// collection table row): the same piece, minus the fire flashes, the rock
// relighting and the table reflections, which do not read at thumbnail
// size, for roughly a third less gas, so a page fits more rows under a
// query's gas ceiling.
func RenderTokenThumbSVG(chain, metal string, shapeIdx, colorIdx int, active bool, tidStr string) string {
	svg, _, _, _ := renderToken(chain, metal, shapeIdx, colorIdx, active, tidStr, true)
	return svg
}

func RenderTokenSVG(chain, metal string, shapeIdx, colorIdx int, active bool, tidStr string) (svg string, stone string, colorHex string, colorName string) {
	return renderToken(chain, metal, shapeIdx, colorIdx, active, tidStr, false)
}

func renderToken(chain, metal string, shapeIdx, colorIdx int, active bool, tidStr string, thumb bool) (svg string, stone string, colorHex string, colorName string) {
	var cascadeCSS string
	stone = StoneForChain(chain)
	if ChainAlwaysActive(chain) {
		active = true
	}
	nc := colorForStone(stone, colorIdx)
	colorHex, colorName = nc.hex, nc.name
	mt := metals[metal]

	ringEls := renderRing(mt.hi, mt.lo, tidStr)
	// colorHex is already the boosted value -- stonePalettes' own hex
	// constants ARE the s=1.5 saturate output (see stonePalettes' comment
	// for the formula, and for which entry is deliberately excluded: Red).
	//
	// Pearl draws from renderPearlShape (smooth luster gradient, no
	// facets) instead of the faceted pipeline -- a real pearl is never
	// cut. applyCascade still runs on it rather than being skipped:
	// scanFacetSpans finds no class="f" facets in pearl markup and
	// returns nothing, so it stays a no-op there without its own branch.
	//
	// Faceted stones stack, bottom to top: body glow (silhouette), the
	// facets themselves (translucent solid fills at varying opacity, so
	// the glow shows through some more than others), the cascade's flash
	// overlays, then one faint rim stroke. A caustic pool under the stone
	// and a pavilion silhouette behind it were tried and dropped: on a
	// flat dark ground they read as a second layer, not as depth. All static gradients and paths -- no <filter>, no mask.
	// An earlier iteration also drew hairline facet edges and two white
	// specular hot spots; both read as cartoonish and were dropped.
	var gemMarkup string
	if stone == "Pearl" {
		pearl := renderPearlShape(shapeIdx, colorHex, mt.hi, tidStr)
		overlay, css := applyCascade(pearl, tidStr, nil)
		gemMarkup, cascadeCSS = pearl+overlay, css
	} else {
		fs := &facetStyle{prof: fireProfileFor(stone, colorName), zone: newPRNG("zone" + tidStr), stone: stone, thumb: thumb}
		under, facets, over := renderGem3D(shapeIdx, colorHex, tidStr, fs)
		overlay, css := applyCascade(facets, tidStr, fs)
		cascadeCSS = css
		gemMarkup = under + `<g fill-opacity=".9">` + facets + `</g>` + overlay + over + fs.glints
	}
	floatingGem := applyMotion(gemMarkup, tidStr)
	status := renderStatusBadge(active)
	serial := renderSerialText(tidStr, mt.hi)
	labelText := metalLabel[metal].text
	labelRect := renderMetalLabelRect(mt.hi, mt.lo, 24, 134, 122, 15, 3, tidStr)

	inner := `<rect width="` + fnum(canvasW) + `" height="` + fnum(canvasH) + `" fill="#0a0b10"/>` +
		renderStars(tidStr) + setRing(ringEls) + setStone(floatingGem) + setBadge(status) + serial + labelRect +
		renderPlateText(chain+" CHAIN", labelText, mt.hi)

	// width/height on the root <svg>, not just viewBox -- without them the
	// image has no definite intrinsic size as an <img> resource, and
	// gnoweb's own CSS (anchors wrapping embedded thumbnails are
	// `display: inline-block; text-wrap: balance`) collapses an
	// ambiguous-size image down to 2x2px. Confirmed live against a real
	// deployed collection (gno-tools' nft-minter tool hit the exact same
	// bug); see ~/gno-land-dev-notes.md.
	// cascadeCSS is a second, separate <style> block rather than folded
	// into styleBlock() -- every rule in it (keyframe names, timings) is
	// unique to THIS token, unlike styleBlock()'s shared, fixed rules
	// reused across every token that's ever rendered.
	svg = `<svg xmlns="http://www.w3.org/2000/svg" width="` + fnum(canvasW) + `" height="` + fnum(canvasH) + `" viewBox="0 0 ` + fnum(canvasW) + ` ` + fnum(canvasH) + `">` + styleBlock() +
		`<style>` + cascadeCSS + `</style>` + inner + `</svg>`
	return svg, stone, colorHex, colorName
}

// styleBlock is embedded once per token's own SVG (a real NFT image is a
// fully self-contained document -- this can't live in a page-level
// stylesheet). Drives every animated piece via CSS @keyframes instead
// of SMIL <animate>/<animateTransform>: each token's own randomized
// timing/angles are set as custom properties in a small inline style=""
// per element, against these shared, fixed keyframe rules.
func styleBlock() string {
	const easeOut = "cubic-bezier(0,0,.3,1)"
	// Compact form (gemsart3d2): shared selectors, animation shorthand with
	// the delay inline, ease-in-out in place of the near-identical
	// cubic-bezier(.45,0,.55,1). Same motion, ~40% fewer bytes. The
	// will-change hint stays: it mattered for Safari.
	return `<style>.gt-v,.gt-h,.gt-r,.gt-s{will-change:transform}` +

		`.gt-v{animation:gt-v var(--v-dur) ease-in-out var(--v-delay) infinite}` +
		`.gt-h{animation:gt-h var(--h-dur) ease-in-out var(--h-delay) infinite}` +
		`.gt-r{animation:gt-r var(--r-dur) ease-in-out var(--r-delay) infinite}` +
		`.gt-s{animation:gt-s var(--s-dur) ease-in-out var(--s-delay) infinite}` +
		`.gt-glow{animation:gt-glow var(--glow-dur) ease-in-out var(--glow-delay) infinite}` +
		// rock-synced lighting: same duration, delay and easing as .gt-r,
		// peaking at its two extremes (25% and 75%)
		`.gt-la{animation:gt-la var(--r-dur) ease-in-out var(--r-delay) infinite}` +
		`.gt-lb{animation:gt-lb var(--r-dur) ease-in-out var(--r-delay) infinite}` +
		`@keyframes gt-la{0%,50%,100%{opacity:0}25%{opacity:1}}` +
		`@keyframes gt-lb{0%,50%,100%{opacity:0}75%{opacity:1}}` +
		`.gt-badge-pulse{animation:gt-bp 1.8s ` + easeOut + ` infinite}` +
		// the float is balanced around the ring centre (+2.5 to -2.5); it
		// used to rise 0 to -5 only, which sat every stone 2.5 high on average
		`@keyframes gt-v{0%,100%{transform:translateY(2.5px)}50%{transform:translateY(-2.5px)}}` +
		`@keyframes gt-h{50%{transform:translateX(1.8px)}}` +
		`@keyframes gt-r{25%{transform:rotate(calc(-1*var(--rot-deg)))}75%{transform:rotate(var(--rot-deg))}}` +
		`@keyframes gt-s{50%{transform:scale(` + fnum(motionScale) + `)}}` +
		// a twinkle is a brief flare from the star's resting brightness,
		// once per its own period (see renderStars)
		`.gt-tw{animation:gt-tw var(--d) ease-in-out var(--dl) infinite}@keyframes gt-tw{0%,84%,100%{opacity:.4}90%{opacity:1}94%{opacity:.2}}` +
		`@keyframes gt-glow{50%{opacity:1}}` +
		`@keyframes gt-bp{from{transform:scale(1);opacity:.8}to{transform:scale(2.25);opacity:0}}` +
		`</style>`
}
