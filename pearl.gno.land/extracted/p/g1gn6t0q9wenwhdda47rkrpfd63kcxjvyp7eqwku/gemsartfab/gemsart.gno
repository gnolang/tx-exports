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
package gemsartfab

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
func fnum(v float64) string {
	neg := v < 0
	if neg {
		v = -v
	}
	scaled := int64(v*100 + 0.5)
	whole := scaled / 100
	frac := scaled % 100
	fracStr := ufmt.Sprintf("%d", frac)
	if frac < 10 {
		fracStr = "0" + fracStr
	}
	s := ufmt.Sprintf("%d.%s", whole, fracStr)
	if neg {
		return "-" + s
	}
	return s
}

// fnum1 is fnum at one decimal -- for keyframe percentages, where the
// second decimal is a fraction of a frame and only costs bytes (the
// keyframe CSS is the largest slice of every token).
func fnum1(v float64) string {
	neg := v < 0
	if neg {
		v = -v
	}
	scaled := int64(v*10 + 0.5)
	s := ufmt.Sprintf("%d.%d", scaled/10, scaled%10)
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
	material := ufmt.Sprintf("%s:%d", p.seed, p.n)
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
// Each cut's geometry is unchanged from gemsart2 (same vertices, same
// facet counts, same draw order -- applyCascade depends on that order).
// What changed for the "fab" look is only how a facet is PAINTED: a flat
// per-facet shade at 55% opacity over a near-black background was exactly
// what read as matte. Every facet now takes one of three shared,
// per-token directional gradients (facetStyle) and sits on a glowing
// body layer (renderGemBody). Cuts with a table get the table's soft
// radial highlight for free; cuts without one hand that same highlight
// to the single facet nearest the light (litFacet), so every stone has
// one surface visibly catching it. All of it is plain gradients and
// paths -- no SVG <filter>, no mask, no clip, no strokes -- for the
// same WebKit reasons documented on renderRing and stonePalettes.

// Painting is deliberately cheap to rasterize. Safari re-rasterizes a
// whole animated SVG image every frame, so a tile's cost is its total
// paint work -- and a gradient fill costs WebKit far more than a solid
// one. An earlier fab pass gave every facet and every flash overlay a
// gradient fill (~50 gradient fills per stone per frame, versus none in
// gemsart2) and a page of them was measurably jittery in Safari where
// gemsart2 was smooth. So: every directional and spectral gradient is
// SAMPLED here, once, at the facet's centroid, and shipped as a plain
// solid fill. Only the body glow and the table stay real gradients --
// two gradient fills per stone. The within-facet shading now comes from
// the body glow showing through translucent solid facets.

// gstop/gramp describe a linear colour ramp in absolute coordinates,
// sampled by projection -- the same maths an SVG linearGradient with
// gradientUnits="userSpaceOnUse" would do in the browser.
type gstop struct {
	pct   float64
	color string
	op    float64
}

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

// facetStyle carries what a gem_* function paints its facets with: the
// three directional ramps (cycled so two adjacent facets never share
// one -- a shared one would erase the edge between them; the fourth is
// a deep, barely-lit interior tone, because a real stone has near-black
// facets right next to near-white ones and that contrast is its sparkle), the spectral
// flash ramp, and the table gradient id. ringCent records each ring
// facet's centroid in draw order so applyCascade can colour that
// facet's flash without parsing path data back out of the markup.
type facetStyle struct {
	dir      [4]gramp // lit from top-left / top-right / from below / deep interior
	flash    gramp
	table    string // the one static center element (table/backing)
	ringCent []pt
	prof     fireProfile
	zone     *prng // per-facet hue drift, seeded per token
}

// fireProfile is how a stone's optics differ by what it is. Dispersion
// (fire) is a property of the material: diamond-like colourless stones
// throw strong spectral flashes, sapphire much less, topaz less still;
// so the colourless palette entries (Sapphire "White", Topaz
// "Colorless", both in Not Set) flash saturated colour and often, while
// coloured stones flash mostly white with a faint tint. shadow is what
// a facet darkens toward: black for coloured stones, a cold blue-grey
// for colourless ones, which would otherwise darken into smoky brown.
type fireProfile struct {
	sat, hit  float64
	pinpoints int
	shadow    string
	// bodyMix pulls the stone's working base colour toward shadow before
	// any ramp is built. A colourless stone has no colour of its own: its
	// body is the dark environment it reflects, with only a few facets
	// catching the light -- which is what makes a diamond read as diamond
	// and not as frosted glass. Its palette hex is near-white, so
	// lightening it does nothing and every facet came out white; mixing
	// it halfway to shadow first gives a mid-grey body, white tips and
	// near-black depths. Coloured stones keep 0.
	bodyMix float64
	// neutral, when set, replaces the palette hex as the working base
	// before bodyMix: Topaz "Colorless" is a warm cream in the palette,
	// and cream mixed toward a cold shadow lands on a muddy brown-grey.
	// A colourless stone has no warmth to keep.
	neutral string
}

func fireProfileFor(stone, colorName string) fireProfile {
	// Colorless (Topaz, Not Set) is the diamond: a grey body built from
	// the dark ground it reflects, near-black depths, full-spectrum fire.
	// White (Sapphire, Not Set) is a WHITE stone, not a colourless one:
	// it keeps its bright body, its shadows only go to a cool light grey,
	// and its fire is strong but a notch under the diamond's.
	if colorName == "Colorless" {
		return fireProfile{1.0, 0.7, 4, "#141a2c", 0.55, "#dfe4ee"}
	}
	if colorName == "White" {
		return fireProfile{0.85, 0.6, 3, "#7d86a0", 0, ""}
	}
	// Crystal sits between the two in body: the Colorless recipe
	// (neutral base, cold shadow) with the base pulled only a third of
	// the way to shadow instead of over half, so it reads lighter and
	// clearer than the diamond but well short of the White stone. Its
	// fire is the strongest of any stone -- full spectrum, more facets
	// per sweep than the diamond -- because it is the clearest stone in
	// the collection and a lighter body needs more to read as intense.
	// (A first pass gave it less fire than Colorless on the grounds that
	// glass disperses less than diamond; rejected in review.) Edge-only
	// treatments (hairlines, empty facets, grazing-angle rims) were tried
	// for it and rejected: on this ground they read as wireframe.
	if colorName == "Crystal" {
		return fireProfile{1.0, 0.78, 4, "#141a2c", 0.3, "#e4e9f2"}
	}
	if stone == "Topaz" {
		return fireProfile{0.5, 0.5, 3, "#000000", 0, ""}
	}
	return fireProfile{0.7, 0.5, 3, "#000000", 0, ""}
}

// fireZoneDeg bounds the per-facet hue drift, degrees either way.
const fireZoneDeg = 7.0

// facetOps are the per-facet translucencies, cycled out of step with the
// ramp cycle so ramp/opacity pairings vary around a ring. A real cut
// stone shows light through some facets and not others; one shared
// opacity (the previous pass) read as a solid, painted surface.
var facetOps = []string{"0.5", "0.82", "0.4", "0.7"}

// path emits one ring facet: solid fill sampled from its directional
// ramp at its centroid. class="f" is the marker scanFacetSpans keys on
// -- gemsart2 keyed on the literal opacity="0.55" instead, which is how
// Rose Cut silently lost its cascade; an explicit class can't drift.
func (fs *facetStyle) path(k int, poly []pt) string {
	cx, cy := centroid(poly)
	c, _ := fs.dir[k%4].sample(cx, cy)
	if fs.zone != nil {
		c = hueRotate(c, fs.zone.floatIn(-fireZoneDeg, fireZoneDeg))
	}
	fs.ringCent = append(fs.ringCent, pt{cx, cy})
	return `<path d="` + polyPath(poly) + `" fill="` + c + `" fill-opacity="` + facetOps[(k*3+1)%4] + `" class="f"/>`
}

// lit emits a ring facet that carries the table highlight instead of a
// directional tone -- still class="f", so it still flashes.
func (fs *facetStyle) lit(poly []pt) string {
	cx, cy := centroid(poly)
	fs.ringCent = append(fs.ringCent, pt{cx, cy})
	return `<path d="` + polyPath(poly) + `" fill="url(#` + fs.table + `)" fill-opacity="0.85" class="f"/>`
}

// center closes the one non-ring element each cut draws (table, or the
// hexagon backing on Rose Cut) -- no class, so the cascade skips it.
func (fs *facetStyle) center() string {
	return `" fill="url(#` + fs.table + `)"/>`
}

// litFacet picks which facet of a tableless cut carries the table's soft
// highlight: the one whose centroid sits furthest toward the light
// (up-left, the direction every ramp in this file assumes). The table
// gradient is bounding-box relative, so on a triangle it lands as a
// soft glow inside that one facet -- the same "blurred window" a Round
// or Emerald shows in its table.
func litFacet(facets [][]pt) int {
	best, bestDot := 0, -1e9
	for i, f := range facets {
		cx, cy := centroid(f)
		d := (cx-subjX)*-0.574 + (cy-subjY)*-0.819
		if d > bestDot {
			bestDot, best = d, i
		}
	}
	return best
}

// emitFacets writes a cut's ring facets in order. k0 is the ramp index
// of the first one (cuts that draw a backing first pass 1 so the
// cycling stays identical to before); lit is the index in facets that
// takes the table highlight, or -1 for cuts that have a real table.
func emitFacets(fs *facetStyle, facets [][]pt, k0, lit int) string {
	out := ""
	for i, f := range facets {
		if i == lit {
			out += fs.lit(f)
		} else {
			out += fs.path(k0+i, f)
		}
	}
	return out
}

// darken blends hex toward the stone's shadow tone by amt (0-1) --
// lighten's counterpart, used for the deep end of every facet ramp.
func darken(hex, shadow string, amt float64) string {
	if amt > 0.95 {
		amt = 0.95
	}
	return mixHex(hex, shadow, amt)
}

// prismFlash selects the cascade flash's colour ramp. false: plain
// white fading to faint. true: a spectral ramp -- white at the light,
// then red through violet -- so as the cascade chases across the stone
// each facet flashes a different band of the spectrum and the flash
// reads as dispersion passing through the stone, the way a cut diamond
// throws fire. Each facet's flash is one solid colour sampled from the
// ramp at its centroid (see the note at the top of this section).
const prismFlash = true

func flashRamp(ext, sat float64) gramp {
	r := gramp{x1: subjX - ext, y1: subjY - ext, x2: subjX + ext, y2: subjY + ext}
	if !prismFlash {
		r.stops = []gstop{{0, "#ffffff", 1}, {100, "#ffffff", 0.25}}
		return r
	}
	// Bands are ~7 units wide across the 50-unit stone, so adjacent
	// facets flash visibly different hues. Opacity tails off toward
	// violet so the far end of the stone flashes softer than the lit end.
	// Fully saturated spectral colours: a pastel ramp (the previous pass)
	// disappeared into the stone's own tone and read as pale.
	// sat (fireProfile) pulls every band toward white: a diamond-like
	// stone keeps the full spectrum, a topaz flashes nearly white.
	r.stops = []gstop{
		{0, "#ffffff", 1}, {14, "#ff4040", 0.95}, {28, "#ff9a1f", 0.95}, {42, "#ffe81f", 0.9},
		{56, "#35ff7a", 0.85}, {70, "#22ccff", 0.8}, {84, "#5566ff", 0.75}, {100, "#c04dff", 0.7},
	}
	for i := range r.stops {
		r.stops[i].color = mixHex(r.stops[i].color, "#ffffff", 1-sat)
	}
	return r
}

// gemFacetDefs fills in fs's ramps for base and returns the only two
// gradient <defs> a faceted stone ships: the table and the body glow. Ids are salted per token like every other gradient in this file
// (many tokens share one page).
func gemFacetDefs(base, salt string, fs *facetStyle) string {
	const ext = 25.0
	sh := fs.prof.shadow
	if fs.prof.neutral != "" {
		base = fs.prof.neutral
	}
	base = mixHex(base, sh, fs.prof.bodyMix)
	dk := func(amt float64) string { return darken(base, sh, amt) }
	fs.table = "fT" + salt
	// Lit from top-left: the main light. Near-white at the tip, a real
	// hue band in the middle, deep shadow at the far end.
	fs.dir[0] = gramp{subjX - ext, subjY - ext, subjX + ext, subjY + ext,
		[]gstop{{0, lighten(base, 0.92), 1}, {25, lighten(base, 0.45), 1}, {55, base, 1}, {100, dk(0.75), 1}}}
	// Lit from top-right: a secondary, dimmer reflection.
	fs.dir[1] = gramp{subjX + ext, subjY - ext, subjX - ext, subjY + ext,
		[]gstop{{0, lighten(base, 0.35), 1}, {45, dk(0.25), 1}, {100, dk(0.8), 1}}}
	// Lit from below: internal reflection -- the pavilion bouncing
	// light back up, so the deepest color sits at the top.
	fs.dir[2] = gramp{subjX, subjY + ext, subjX, subjY - ext,
		[]gstop{{0, lighten(base, 0.15), 1}, {50, dk(0.45), 1}, {100, dk(0.85), 1}}}
	// Deep interior: a facet angled away from every light, seen straight
	// into the stone's depth.
	fs.dir[3] = gramp{subjX + ext, subjY + ext, subjX - ext, subjY - ext,
		[]gstop{{0, dk(0.25), 1}, {50, dk(0.6), 1}, {100, dk(0.9), 1}}}
	fs.flash = flashRamp(ext, fs.prof.sat)

	st := func(pct float64, color string) string {
		return `<stop offset="` + fnum(pct) + `%" stop-color="` + color + `"/>`
	}
	return `<defs>` +
		// Table: the soft "window" straight down into the stone. Kept
		// deliberately diffuse -- a low peak and a long, many-stop falloff
		// over a wide radius -- so it reads as light caught inside the
		// surface, with no visible bright disc (an earlier, brighter
		// version read as incandescent).
		`<radialGradient id="` + fs.table + `" cx="42%" cy="38%" r="78%">` +
		st(0, lighten(base, 0.36)) + st(25, lighten(base, 0.24)) + st(50, lighten(base, 0.11)) + st(75, base) + st(100, dk(0.14)) + `</radialGradient>` +
		// Body glow: light trapped inside the stone, bright off-center,
		// deep and saturated at the girdle. Facets are translucent solid
		// fills over this, so it is also what shades each facet from one
		// side to the other.
		`<radialGradient id="bd` + salt + `" cx="40%" cy="35%" r="72%">` +
		st(0, lighten(base, 0.55)) + st(40, lighten(base, 0.12)) + st(78, dk(0.2)) + st(100, dk(0.7)) + `</radialGradient>` +
		`</defs>`
}

// renderGemRim is the one stroke a stone gets: its outer silhouette in a
// lighter tone of its OWN colour, faint -- a glass edge catching light.
// Deliberately not white and not on every facet (that earlier pass read
// as a wireframe).
func renderGemRim(outline []pt, base string) string {
	return `<path d="` + polyPath(outline) + `" fill="none" stroke="` + lighten(base, 0.5) + `" stroke-opacity="0.35" stroke-width="0.6" stroke-linejoin="round"/>`
}

// renderGemBody draws the stone's silhouette filled with the body glow,
// underneath the facets. The facets are translucent, so this is what
// makes the stone read as lit from within rather than painted on.
func renderGemBody(outline []pt, salt string) string {
	return `<path d="` + polyPath(outline) + `" fill="url(#bd` + salt + `)"/>`
}

// roundSpiralN/roundSpiralTwist parameterize gemRound's "spiral twist" cut
// -- the outer crown ring is rotated against the inner table-to-crown ring
// by roundSpiralTwist of a facet-step, so the two rings read as a pinwheel
// instead of sitting in static radial alignment. Picked after a live
// side-by-side comparison of six alternative Round Brilliant facet
// layouts (the previous cut's 8-facet ring pair, offset by a plain static
// half-step, read as an odd seam at this size).
const (
	roundSpiralN     = 10
	roundSpiralTwist = 0.35
)

// roundOutline returns the roundSpiralN outer-girdle vertices of gemRound's
// twisted crown ring at radius r -- the SAME points gemRound itself
// computes inline for its outer facet loop, shared with gemOutline so the
// body/specular layers can never drift from the rendered silhouette.
func roundOutline(r float64) []pt {
	n := roundSpiralN
	pts := make([]pt, n)
	for k := 0; k < n; k++ {
		a := 2*math.Pi*float64(k)/float64(n) - math.Pi/2 + math.Pi/float64(n)*(1+roundSpiralTwist)
		pts[k] = pt{subjX + r*math.Cos(a), subjY + r*math.Sin(a)}
	}
	return pts
}

func gemRound(fs *facetStyle) string {
	tableR, crownR, r := 20.0*0.3, 20.0*0.62, 20.0
	n := roundSpiralN
	twistStep := roundSpiralTwist * math.Pi / float64(n)
	outerPts := roundOutline(r)
	out := ""
	for k := 0; k < n; k++ {
		a1 := 2*math.Pi*float64(k)/float64(n) - math.Pi/2
		a2 := 2*math.Pi*float64(k+1)/float64(n) - math.Pi/2 + twistStep
		p1i := pt{subjX + tableR*math.Cos(a1), subjY + tableR*math.Sin(a1)}
		p2i := pt{subjX + tableR*math.Cos(a2), subjY + tableR*math.Sin(a2)}
		p1o := pt{subjX + crownR*math.Cos(a1+twistStep*0.5), subjY + crownR*math.Sin(a1+twistStep*0.5)}
		p2o := pt{subjX + crownR*math.Cos(a2+twistStep*0.5), subjY + crownR*math.Sin(a2+twistStep*0.5)}
		out += fs.path(k, []pt{p1i, p1o, p2o, p2i})
	}
	for k := 0; k < n; k++ {
		a1 := 2*math.Pi*float64(k)/float64(n) - math.Pi/2 + math.Pi/float64(n)
		p1i := pt{subjX + crownR*math.Cos(a1), subjY + crownR*math.Sin(a1)}
		p2i := pt{subjX + crownR*math.Cos(a1+2*math.Pi/float64(n)), subjY + crownR*math.Sin(a1+2*math.Pi/float64(n))}
		p1o := outerPts[k]
		p2o := outerPts[(k+1)%n]
		out += fs.path(k+1, []pt{p1i, p1o, p2o, p2i})
	}
	out += `<circle cx="` + fnum(subjX) + `" cy="` + fnum(subjY) + `" r="` + fnum(tableR) + fs.center()
	return out
}

func emeraldOutline() []pt {
	hw, hh := 17.0, 22.0
	return []pt{
		{subjX - hw, subjY - hh + 7}, {subjX - hw + 7, subjY - hh}, {subjX + hw - 7, subjY - hh}, {subjX + hw, subjY - hh + 7},
		{subjX + hw, subjY + hh - 7}, {subjX + hw - 7, subjY + hh}, {subjX - hw + 7, subjY + hh}, {subjX - hw, subjY + hh - 7},
	}
}

func gemEmerald(fs *facetStyle) string {
	outer := emeraldOutline()
	inner := make([]pt, len(outer))
	for i, p := range outer {
		inner[i] = pt{p.x*0.55 + subjX*0.45, p.y*0.55 + subjY*0.45}
	}
	out := fs.path(0, outer)
	for i := range outer {
		a, b := outer[i], outer[(i+1)%len(outer)]
		ia, ib := inner[i], inner[(i+1)%len(inner)]
		out += fs.path(i+1, []pt{a, b, ib, ia})
	}
	out += `<path d="` + polyPath(inner) + fs.center()
	return out
}

func princessOutline() []pt {
	half := 19.0
	return []pt{{subjX - half, subjY - half}, {subjX + half, subjY - half}, {subjX + half, subjY + half}, {subjX - half, subjY + half}}
}

func gemPrincess(fs *facetStyle) string {
	pts := princessOutline()
	mid := pt{subjX, subjY}
	var facets [][]pt
	for i := 0; i < 4; i++ {
		a, b := pts[i], pts[(i+1)%4]
		m := pt{(a.x + b.x) / 2, (a.y + b.y) / 2}
		facets = append(facets, []pt{mid, a, m}, []pt{mid, m, b})
	}
	return emitFacets(fs, facets, 0, litFacet(facets))
}

// gemRaw's jitter uses a FIXED seed (not per-piece) -- same as the Python
// original, where every Raw Crystal piece shares the identical silhouette
// (just a different base color), rather than each token getting its own
// random outline.
func rawCrystalPoints(r float64) []pt {
	rnd := newPRNG("gem-raw-fixed-seed-3")
	n := 9
	pts := make([]pt, n)
	for k := 0; k < n; k++ {
		a := 2 * math.Pi * float64(k) / float64(n)
		rr := r * (0.7 + 0.5*rnd.floatIn(0, 1))
		pts[k] = pt{subjX + rr*math.Cos(a), subjY + rr*math.Sin(a)}
	}
	return pts
}

func gemRaw(fs *facetStyle) string {
	pts := rawCrystalPoints(22)
	mid := pt{subjX, subjY}
	var facets [][]pt
	for i := range pts {
		facets = append(facets, []pt{mid, pts[i], pts[(i+1)%len(pts)]})
	}
	return emitFacets(fs, facets, 0, litFacet(facets))
}

func pearOutline() []pt {
	w, h := 19.0, 29.0
	return []pt{
		{subjX, subjY - h*0.5}, {subjX - w*0.55, subjY - h*0.1}, {subjX - w*0.35, subjY + h*0.35},
		{subjX, subjY + h*0.55}, {subjX + w*0.35, subjY + h*0.35}, {subjX + w*0.55, subjY - h*0.1},
	}
}

// crownFacets splits an outline into a crown ring of quads plus inner
// pavilion triangles meeting at the centre -- twice the facets of the
// old pie-slice cuts, so Trillion, Pear and Heart sparkle like the rest
// instead of reading flat. inner is the crown/pavilion boundary as a
// fraction of the outline's radius.
func crownFacets(outer []pt, inner float64) [][]pt {
	n := len(outer)
	in := make([]pt, n)
	for i, p := range outer {
		in[i] = pt{subjX + (p.x-subjX)*inner, subjY + (p.y-subjY)*inner}
	}
	mid := pt{subjX, subjY}
	var f [][]pt
	for i := 0; i < n; i++ {
		j := (i + 1) % n
		f = append(f, []pt{outer[i], outer[j], in[j], in[i]})
	}
	for i := 0; i < n; i++ {
		j := (i + 1) % n
		f = append(f, []pt{mid, in[i], in[j]})
	}
	return f
}

// withMidpoints inserts each edge's midpoint, doubling a polygon's
// vertex count without changing its silhouette.
func withMidpoints(pts []pt) []pt {
	n := len(pts)
	out := make([]pt, 0, 2*n)
	for i, p := range pts {
		q := pts[(i+1)%n]
		out = append(out, p, pt{(p.x + q.x) / 2, (p.y + q.y) / 2})
	}
	return out
}

func gemPear(fs *facetStyle) string {
	facets := crownFacets(pearOutline(), 0.5)
	return emitFacets(fs, facets, 0, litFacet(facets))
}

func heartOutline() []pt {
	s := 24.0
	return []pt{
		{subjX, subjY + s*0.6}, {subjX - s*0.55, subjY - s*0.05}, {subjX - s*0.28, subjY - s*0.5},
		{subjX, subjY - s*0.15}, {subjX + s*0.28, subjY - s*0.5}, {subjX + s*0.55, subjY - s*0.05},
	}
}

func gemHeart(fs *facetStyle) string {
	facets := crownFacets(heartOutline(), 0.5)
	return emitFacets(fs, facets, 0, litFacet(facets))
}

func trillionOutline(r float64) []pt {
	angles := []float64{0, 2 * math.Pi / 3, 4 * math.Pi / 3}
	pts := make([]pt, 3)
	for i, a := range angles {
		pts[i] = pt{subjX + r*math.Cos(a-math.Pi/2), subjY + r*math.Sin(a-math.Pi/2)}
	}
	return pts
}

func gemTrillion(fs *facetStyle) string {
	facets := crownFacets(withMidpoints(trillionOutline(23)), 0.5)
	return emitFacets(fs, facets, 0, litFacet(facets))
}

// ellipseArcAngles returns n angles (starting straight up, going
// clockwise) spaced at equal ARC-LENGTH steps around an rx,ry ellipse,
// found by numeric integration over a fine sample of the curve. Equal
// ANGLE steps (the simpler approach) bunch up unevenly on a true ellipse
// -- narrower near the pointed ends, wider near the sides -- which is
// what made the old Oval cut's facets look lopsided.
func ellipseArcAngles(rx, ry float64, n int) []float64 {
	const steps = 720
	cum := make([]float64, steps+1)
	prevX, prevY := rx*math.Cos(-math.Pi/2), ry*math.Sin(-math.Pi/2)
	for i := 1; i <= steps; i++ {
		a := -math.Pi/2 + 2*math.Pi*float64(i)/float64(steps)
		x, y := rx*math.Cos(a), ry*math.Sin(a)
		dx, dy := x-prevX, y-prevY
		cum[i] = cum[i-1] + math.Sqrt(dx*dx+dy*dy)
		prevX, prevY = x, y
	}
	total := cum[steps]
	angles := make([]float64, n)
	ti := 0
	for k := 0; k < n; k++ {
		target := total * float64(k) / float64(n)
		for ti < steps && cum[ti+1] < target {
			ti++
		}
		angles[k] = -math.Pi/2 + 2*math.Pi*float64(ti)/float64(steps)
	}
	return angles
}

// ovalOutline returns the 10 points gemOval's girdle actually sits on --
// arc-length spaced (see ellipseArcAngles), so the rendered silhouette is
// a true evenly-spaced polygon, not one with wider facets near the sides
// and narrower ones near the tips.
func ovalOutline(rx, ry float64) []pt {
	n := 10
	angles := ellipseArcAngles(rx, ry, n)
	pts := make([]pt, n)
	for k, a := range angles {
		pts[k] = pt{subjX + rx*math.Cos(a), subjY + ry*math.Sin(a)}
	}
	return pts
}

// gemOval draws a "cross-girdle" cut -- an outer and inner arc-length-
// spaced oval ring with straight cross-facets between them, plus a
// filled center -- borrowed from the Radiant cut's cleaner anatomy
// instead of the old cut's pie slices converging on a single center
// point (which is what read as odd once the ellipse stopped being a
// circle).
func gemOval(fs *facetStyle) string {
	rx, ry := 17.0, 23.0
	innerRx, innerRy := rx*0.5, ry*0.5
	n := 10
	angles := ellipseArcAngles(rx, ry, n)
	outerPts := make([]pt, n)
	innerPts := make([]pt, n)
	for k, a := range angles {
		outerPts[k] = pt{subjX + rx*math.Cos(a), subjY + ry*math.Sin(a)}
		innerPts[k] = pt{subjX + innerRx*math.Cos(a), subjY + innerRy*math.Sin(a)}
	}
	out := fs.path(0, outerPts)
	for k := 0; k < n; k++ {
		a, b := outerPts[k], outerPts[(k+1)%n]
		ia, ib := innerPts[k], innerPts[(k+1)%n]
		out += fs.path(k+1, []pt{a, b, ib, ia})
	}
	out += `<path d="` + polyPath(innerPts) + fs.center()
	return out
}

func asscherOutline(half float64) []pt {
	c := half * 0.4
	return []pt{
		{subjX - half + c, subjY - half}, {subjX + half - c, subjY - half}, {subjX + half, subjY - half + c}, {subjX + half, subjY + half - c},
		{subjX + half - c, subjY + half}, {subjX - half + c, subjY + half}, {subjX - half, subjY + half - c}, {subjX - half, subjY - half + c},
	}
}

func gemAsscher(fs *facetStyle) string {
	outer := asscherOutline(19)
	inner := make([]pt, len(outer))
	for i, p := range outer {
		inner[i] = pt{p.x*0.5 + subjX*0.5, p.y*0.5 + subjY*0.5}
	}
	out := fs.path(0, outer)
	for i := range outer {
		a, b := outer[i], outer[(i+1)%len(outer)]
		ia, ib := inner[i], inner[(i+1)%len(inner)]
		out += fs.path(i+1, []pt{a, b, ib, ia})
	}
	out += `<path d="` + polyPath(inner) + fs.center()
	return out
}

func radiantOutline(hw, hh, c float64) []pt {
	return []pt{
		{subjX - hw + c, subjY - hh}, {subjX + hw - c, subjY - hh}, {subjX + hw, subjY - hh + c}, {subjX + hw, subjY + hh - c},
		{subjX + hw - c, subjY + hh}, {subjX - hw + c, subjY + hh}, {subjX - hw, subjY + hh - c}, {subjX - hw, subjY - hh + c},
	}
}

func gemRadiant(fs *facetStyle) string {
	outer := radiantOutline(21, 17, 6)
	inner := make([]pt, len(outer))
	for i, p := range outer {
		inner[i] = pt{p.x*0.5 + subjX*0.5, p.y*0.5 + subjY*0.5}
	}
	out := fs.path(0, outer)
	for i := range outer {
		a, b := outer[i], outer[(i+1)%len(outer)]
		ia, ib := inner[i], inner[(i+1)%len(inner)]
		out += fs.path(i+1, []pt{a, b, ib, ia})
	}
	out += `<path d="` + polyPath(inner) + fs.center()
	return out
}

// roseOutline returns gemRose's 6 hexagon vertices at radius r -- the
// actual rendered silhouette of the "hexagonal" cut, matching a real
// antique hexagonal rose cut's flat-edged outline instead of a round
// girdle.
func roseOutline(r float64) []pt {
	n := 6
	pts := make([]pt, n)
	for k := 0; k < n; k++ {
		a := 2*math.Pi*float64(k)/float64(n) - math.Pi/2
		pts[k] = pt{subjX + r*math.Cos(a), subjY + r*math.Sin(a)}
	}
	return pts
}

// gemRose draws a hexagonal-silhouette rose cut -- a flat hexagon base
// with 6 facets converging on an off-center apex -- picked over the
// previous round cut's mismatched 6-inner/12-outer facet rings (their
// edges never lined up, reading as uneven). The hexagon backing is the
// center element (static, outside the cascade), the 6 triangles are the
// ring -- and since they cover the backing completely, this counts as a
// tableless cut for litFacet.
func gemRose(fs *facetStyle) string {
	r := 23.0
	hexPts := roseOutline(r)
	apex := pt{subjX, subjY - r*0.1}
	var facets [][]pt
	for k := 0; k < 6; k++ {
		facets = append(facets, []pt{apex, hexPts[k], hexPts[(k+1)%6]})
	}
	return `<polygon points="` + polygonPoints(hexPts) + fs.center() + emitFacets(fs, facets, 0, litFacet(facets))
}

// ShapeNames mirrors the Python SHAPE_NAMES list exactly, same order, so
// a stored ShapeIdx means the same cut on both sides.
// Cabochon (a smooth, unfaceted dome cut) was removed from the trait
// pool per request -- indices above it are unchanged (Rose Cut still
// falls through to the switch's default case, same as before).
var ShapeNames = []string{
	"Round Brilliant", "Emerald Cut", "Princess Cut", "Raw Crystal", "Pear", "Heart",
	"Trillion", "Oval", "Asscher", "Radiant", "Rose Cut",
}

// gemOutline returns the rendered silhouette of a cut -- the exact
// vertices its gem_* function draws its girdle on -- for the body and
// specular layers. Same index mapping as renderGem.
func gemOutline(shapeIdx int) []pt {
	switch shapeIdx {
	case 0:
		return roundOutline(20)
	case 1:
		return emeraldOutline()
	case 2:
		return princessOutline()
	case 3:
		return rawCrystalPoints(22)
	case 4:
		return pearOutline()
	case 5:
		return heartOutline()
	case 6:
		return trillionOutline(23)
	case 7:
		return ovalOutline(17, 23)
	case 8:
		return asscherOutline(19)
	case 9:
		return radiantOutline(21, 17, 6)
	default:
		return roseOutline(23)
	}
}

// renderGem dispatches to the right gem_* function by index.
func renderGem(shapeIdx int, fs *facetStyle) string {
	switch shapeIdx {
	case 0:
		return gemRound(fs)
	case 1:
		return gemEmerald(fs)
	case 2:
		return gemPrincess(fs)
	case 3:
		return gemRaw(fs)
	case 4:
		return gemPear(fs)
	case 5:
		return gemHeart(fs)
	case 6:
		return gemTrillion(fs)
	case 7:
		return gemOval(fs)
	case 8:
		return gemAsscher(fs)
	case 9:
		return gemRadiant(fs)
	default:
		return gemRose(fs)
	}
}

/* ------------------------------------ pearl shapes ------------------------------------ */
// Pearls are organic gems -- they grow into a form, they are never cut or
// faceted the way a crystal is. So unlike the cut vocabulary above
// (ShapeNames/renderGem), everything here draws a smooth, continuous
// surface: one radial luster gradient plus a soft diagonal highlight band
// (a pearl's real "orient" sheen), no straight-edged facet triangles.

// pearlLusterGradient returns a radial gradient (id=gid) approximating a
// pearl's nacre sheen: a bright off-center highlight fading through the
// body color to a slightly deeper rim tone.
func pearlLusterGradient(gid, base string) string {
	// Nacre is glossy, not matte: a small, bright specular core (the
	// reflection of the light itself), a fast fall-off into the soft
	// body, a darker terminator toward the rim, and the rim itself lifted
	// again by bounce light. The old three-stop version read as a flat
	// white blob.
	return `<radialGradient id="` + gid + `" cx="36%" cy="30%" r="78%">` +
		`<stop offset="0%" stop-color="` + lighten(base, 0.9) + `"/>` +
		`<stop offset="9%" stop-color="` + lighten(base, 0.55) + `"/>` +
		`<stop offset="30%" stop-color="` + lighten(base, 0.12) + `"/>` +
		`<stop offset="62%" stop-color="` + base + `"/>` +
		`<stop offset="88%" stop-color="` + mixHex(base, "#000000", 0.3) + `"/>` +
		`<stop offset="100%" stop-color="` + mixHex(base, "#000000", 0.14) + `"/></radialGradient>` +
		// Overtone: the resting iridescence of nacre -- a faint rose tint
		// over the body and a faint green toward the rim, the two
		// interference colours real pearls show most. Drawn as a second
		// copy of the body shape (pearlOvertone) at low opacity.
		`<radialGradient id="` + gid + `o" cx="42%" cy="40%" r="72%">` +
		`<stop offset="0%" stop-color="#ffffff" stop-opacity="0"/>` +
		`<stop offset="45%" stop-color="#ffb8d0" stop-opacity="0.22"/>` +
		`<stop offset="78%" stop-color="#b8ffd8" stop-opacity="0.18"/>` +
		`<stop offset="100%" stop-color="#c8d8ff" stop-opacity="0.1"/></radialGradient>`
}

// pearlOvertone re-emits a pearl's body shape filled with its overtone
// gradient (see pearlLusterGradient). shape is the full self-closing
// element with its fill attribute; only the fill is swapped.
func pearlOvertone(shape, gid string) string {
	i := strings.Index(shape, ` fill="`)
	if i < 0 {
		return ""
	}
	return shape[:i] + ` fill="url(#` + gid + `o)"/>`
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
		return 1.2
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
			`<rect x="` + fnum(subjX-w*1.3) + `" y="` + fnum(subjY-h*0.95) + `" width="` + fnum(w*2.6) + `" height="` + fnum(h*1.9) + `" fill="url(#` + gradID + `)" style="mix-blend-mode:screen;animation:` + kf + ` ` + fnum(total) + `s linear infinite"/>` +
			`</g>`)
	}
	marks.WriteString(`</g>`)
	defs.WriteString(`</defs>`)
	return defs.String() + marks.String()
}

func pearlRound(base, salt string) string {
	gid := "prl" + salt
	r := 24.0
	body := `<circle cx="` + fnum(subjX) + `" cy="` + fnum(subjY) + `" r="` + fnum(r) + `" fill="url(#` + gid + `)"/>`
	clipGeom := `<circle cx="` + fnum(subjX) + `" cy="` + fnum(subjY) + `" r="` + fnum(r) + `"/>`
	sweep := pearlSweepOverlay(salt, base, clipGeom, r*2, r*2)
	return `<defs>` + pearlLusterGradient(gid, base) + `</defs>` + body + pearlOvertone(body, gid) + sweep
}

func pearlOval(base, salt string) string {
	gid := "prl" + salt
	rx, ry := 18.0, 25.0
	body := `<ellipse cx="` + fnum(subjX) + `" cy="` + fnum(subjY) + `" rx="` + fnum(rx) + `" ry="` + fnum(ry) + `" fill="url(#` + gid + `)"/>`
	clipGeom := `<ellipse cx="` + fnum(subjX) + `" cy="` + fnum(subjY) + `" rx="` + fnum(rx) + `" ry="` + fnum(ry) + `"/>`
	sweep := pearlSweepOverlay(salt, base, clipGeom, rx*2, ry*2)
	return `<defs>` + pearlLusterGradient(gid, base) + `</defs>` + body + pearlOvertone(body, gid) + sweep
}

// pearlButton is flattened rather than round -- wider than tall, the
// real "button pearl" silhouette (as if gently pressed), popular in
// jewelry specifically because the flat back sits well against skin.
func pearlButton(base, salt string) string {
	gid := "prl" + salt
	rx, ry := 25.0, 18.0
	body := `<ellipse cx="` + fnum(subjX) + `" cy="` + fnum(subjY) + `" rx="` + fnum(rx) + `" ry="` + fnum(ry) + `" fill="url(#` + gid + `)"/>`
	clipGeom := `<ellipse cx="` + fnum(subjX) + `" cy="` + fnum(subjY) + `" rx="` + fnum(rx) + `" ry="` + fnum(ry) + `"/>`
	sweep := pearlSweepOverlay(salt, base, clipGeom, rx*2, ry*2)
	return `<defs>` + pearlLusterGradient(gid, base) + `</defs>` + body + pearlOvertone(body, gid) + sweep
}

// pearlDrop is a smooth teardrop built from two Bezier arcs -- unlike
// gemPear's faceted polygon, a real drop pearl tapers continuously, with
// no straight edges anywhere on its surface.
func pearlDrop(base, salt string) string {
	gid := "prl" + salt
	w, h := 20.0, 30.0
	path := `M ` + fnum(subjX) + ` ` + fnum(subjY-h*0.55) +
		` C ` + fnum(subjX+w*0.55) + ` ` + fnum(subjY-h*0.15) + ` ` + fnum(subjX+w*0.42) + ` ` + fnum(subjY+h*0.42) + ` ` + fnum(subjX) + ` ` + fnum(subjY+h*0.48) +
		` C ` + fnum(subjX-w*0.42) + ` ` + fnum(subjY+h*0.42) + ` ` + fnum(subjX-w*0.55) + ` ` + fnum(subjY-h*0.15) + ` ` + fnum(subjX) + ` ` + fnum(subjY-h*0.55) + ` Z`
	body := `<path d="` + path + `" fill="url(#` + gid + `)"/>`
	clipGeom := `<path d="` + path + `"/>`
	sweep := pearlSweepOverlay(salt, base, clipGeom, w*1.6, h*0.9)
	return `<defs>` + pearlLusterGradient(gid, base) + `</defs>` + body + pearlOvertone(body, gid) + sweep
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
		rr := 21.0 * (0.75 + 0.4*rnd.floatIn(0, 1))
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

func pearlBaroque(base, salt string) string {
	gid := "prl" + salt
	pathD := pearlBaroqueSmoothPath(pearlBaroqueOutline("baroque" + salt))
	body := `<path d="` + pathD + `" fill="url(#` + gid + `)"/>`
	clipGeom := `<path d="` + pathD + `"/>`
	sweep := pearlSweepOverlay(salt, base, clipGeom, 40, 30)
	return `<defs>` + pearlLusterGradient(gid, base) + `</defs>` + body + pearlOvertone(body, gid) + sweep
}

// pearlCircled draws thin concentric growth rings over a round body --
// the defining feature of a real "circled" (or "ringed") pearl, visible
// grooves left by its own growth, not a decorative pattern.
func pearlCircled(base, salt string) string {
	gid := "prl" + salt
	r := 24.0
	body := `<circle cx="` + fnum(subjX) + `" cy="` + fnum(subjY) + `" r="` + fnum(r) + `" fill="url(#` + gid + `)"/>`
	ringTone := mixHex(base, "#000000", 0.12)
	rings := ""
	for _, f := range []float64{0.42, 0.58, 0.74, 0.9} {
		rings += `<circle cx="` + fnum(subjX) + `" cy="` + fnum(subjY) + `" r="` + fnum(r*f) + `" fill="none" stroke="` + ringTone + `" stroke-width="0.9" opacity="0.35"/>`
	}
	clipGeom := `<circle cx="` + fnum(subjX) + `" cy="` + fnum(subjY) + `" r="` + fnum(r) + `"/>`
	sweep := pearlSweepOverlay(salt, base, clipGeom, r*2, r*2)
	return `<defs>` + pearlLusterGradient(gid, base) + `</defs>` + body + pearlOvertone(body, gid) + rings + sweep
}

// PearlShapeNames lists the real jewelry-trade pearl shape categories --
// deliberately NOT the faceted-cut vocabulary above (ShapeNames). Round
// is the rarest/most prized (perfectly spherical); Baroque is the least
// regular (freeform, no symmetry); Circled pearls show visible
// concentric growth grooves.
var PearlShapeNames = []string{"Round", "Oval", "Button", "Drop", "Baroque", "Circled"}

// renderPearlShape is PearlShapeNames' own counterpart to renderGem.
func renderPearlShape(shapeIdx int, base, salt string) string {
	switch shapeIdx {
	case 0:
		return pearlRound(base, salt)
	case 1:
		return pearlOval(base, salt)
	case 2:
		return pearlButton(base, salt)
	case 3:
		return pearlDrop(base, salt)
	case 4:
		return pearlBaroque(base, salt)
	default:
		return pearlCircled(base, salt)
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
	defs := `<linearGradient id="` + gid + `" x1="0%" y1="0%" x2="100%" y2="100%">` +
		`<stop offset="0%" stop-color="` + metalHi + `"/><stop offset="22%" stop-color="` + metalLo + `"/>` +
		`<stop offset="50%" stop-color="` + metalHi + `"/><stop offset="78%" stop-color="` + metalLo + `"/>` +
		`<stop offset="100%" stop-color="` + metalHi + `"/></linearGradient>`

	outer := `<circle cx="` + fnum(subjX) + `" cy="` + fnum(subjY) + `" r="52.3" fill="none" stroke="url(#` + gid + `)" stroke-width="1" opacity="0.7"/>` +
		`<circle cx="` + fnum(subjX) + `" cy="` + fnum(subjY) + `" r="50" fill="none" stroke="url(#` + gid + `)" stroke-width="4"/>` +
		`<circle cx="` + fnum(subjX) + `" cy="` + fnum(subjY) + `" r="47.7" fill="none" stroke="url(#` + gid + `)" stroke-width="1" opacity="0.85"/>`

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
	dur := rnd.floatIn(3.5, 5.5)
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

	return `<g class="gt-v" style="--v-dur:` + fnum(motionVDur) + `s;--v-delay:-` + fnum(vphase) + `s">` +
		`<g class="gt-h" style="--h-dur:` + fnum(motionHDur) + `s;--h-delay:-` + fnum(hphase) + `s">` +
		`<g class="gt-r" style="--r-dur:` + fnum(motionRDur) + `s;--r-delay:-` + fnum(rphase) + `s;--rot-deg:` + fnum(rotDeg) + `deg">` +
		`<g class="gt-s" style="--s-dur:` + fnum(motionSDur) + `s;--s-delay:-` + fnum(sphase) + `s">` +
		content + `</g></g></g></g>`
}

/* ---------------------------------- status badge ---------------------------------- */

const dotX, dotY = subjX + 50, subjY + 42

func renderStatusBadge(active bool) string {
	if active {
		return `<circle cx="` + fnum(dotX) + `" cy="` + fnum(dotY) + `" r="4" fill="#7fd88f"/>` +
			// r starts at 4 (the solid dot's own radius, so the ring
			// begins flush with its edge) and scales up via transform --
			// see styleBlock's gt-kf-badge-pulse comment for why not r.
			`<circle cx="` + fnum(dotX) + `" cy="` + fnum(dotY) + `" r="4" fill="none" stroke="#7fd88f" stroke-width="1.2" class="gt-badge-pulse" opacity="0.8"/>`
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


const (
	// Timings roughly doubled from the first fire pass, which read as too
	// violent: a flash now takes ~0.7s and a sweep ~1.5-2.5s to cross the
	// stone, still asymmetric (quick rise, long decay) so it pops rather
	// than pulses.
	fireFacetDurMin, fireFacetDurMax = 0.55, 0.85 // one facet's own flash, seconds
	fireStaggerMin, fireStaggerMax   = 0.1, 0.16  // between consecutive facets of a sweep
	fireSweepsPerPeriod              = 4          // one per mid-swing over two rock cycles
	fireSweepSkipChance              = 0.25       // ...but not every swing fires
	// fireSweepAxis is the direction a reflection travels on the
	// clockwise swing under a light from -125 degrees (up-left): the
	// tangent to that, up-right. Reversed on the return swing, jittered
	// a little per token and per sweep.
	fireSweepAxis                    = -35.0 * math.Pi / 180
	fireSweepJitter                  = 0.3
	firePinpointDur                  = 0.45
	firePeakOpMin, firePeakOpMax     = 0.5, 0.85
)

// facetHit is one flash window on one facet: opacity 0 at enter, peak
// (white) a quarter of the way in, half-strength and fully coloured at
// mid, back to 0 at exit.
type facetHit struct {
	enter, peak, mid, exit, peakOp float64
}

func mkHit(enter, dur, peakOp float64) facetHit {
	return facetHit{enter, enter + dur*0.3, enter + dur*0.6, enter + dur, peakOp}
}

// buildFireHits schedules every flash window over one period (two rock
// cycles) for the ring facets whose centroids are cent, in draw order.
func buildFireHits(rnd *prng, cent []pt, prof fireProfile) (hits [][]facetHit, period float64) {
	n := len(cent)
	hits = make([][]facetHit, n)
	period = 2 * motionRDur
	proj := make([]float64, n)
	order := make([]int, n)
	axis := fireSweepAxis + rnd.floatIn(-fireSweepJitter, fireSweepJitter)
	for e := 0; e < fireSweepsPerPeriod; e++ {
		// Fire time runs a quarter rock-cycle behind rock time (see
		// applyCascade), so these slots -- 25%/75% of each cycle in fire
		// time -- are the rock's 50%/0% points: mid-swing. Even slots are
		// the clockwise swing (-rot toward +rot), odd the return.
		t0 := (0.25 + 0.5*float64(e)) * motionRDur
		if rnd.floatIn(0, 1) < fireSweepSkipChance {
			continue
		}
		theta := axis + rnd.floatIn(-fireSweepJitter, fireSweepJitter)
		if e%2 == 1 {
			theta += math.Pi
		}
		dx, dy := math.Cos(theta), math.Sin(theta)
		for i, c := range cent {
			proj[i] = (c.x-subjX)*dx + (c.y-subjY)*dy
			order[i] = i
		}
		for i := 1; i < n; i++ {
			for j := i; j > 0 && proj[order[j]] < proj[order[j-1]]; j-- {
				order[j], order[j-1] = order[j-1], order[j]
			}
		}
		stagger := rnd.floatIn(fireStaggerMin, fireStaggerMax)
		t := t0 - float64(n)*stagger/2 // centre the pass on the extreme
		for _, idx := range order {
			if rnd.floatIn(0, 1) < prof.hit {
				hits[idx] = append(hits[idx], mkHit(t, rnd.floatIn(fireFacetDurMin, fireFacetDurMax), rnd.floatIn(firePeakOpMin, firePeakOpMax)))
			}
			t += stagger
		}
	}
	for k := 0; k < prof.pinpoints; k++ {
		hits[rnd.intn(n)] = append(hits[rnd.intn(n)], mkHit(rnd.floatIn(0, period-firePinpointDur), firePinpointDur, 1))
	}
	return hits, period
}

// cascadeStop is one keyframe: its percent and its declaration body.
type cascadeStop struct {
	pct  float64
	body string
}

// sortCascadeStops is a plain insertion sort -- no sort package needed,
// and the lists here are a few dozen entries at most.
func sortCascadeStops(s []cascadeStop) {
	for i := 1; i < len(s); i++ {
		for j := i; j > 0 && s[j].pct < s[j-1].pct; j-- {
			s[j], s[j-1] = s[j-1], s[j]
		}
	}
}

// modPct maps a time fraction of the period onto 0-100, wrapping.
func modPct(frac float64) float64 {
	for frac < 0 {
		frac += 1
	}
	for frac >= 1 {
		frac -= 1
	}
	return frac * 100
}

// applyCascade emits, for every ring facet that gets at least one flash
// window, a duplicate of its path stacked above the ring with its own
// opacity+fill keyframes (white at peak, the facet's spectral colour on
// the decay), delayed off the token's rock phase so sweeps land on the
// mid-swings. Returns that overlay markup plus the CSS for the
// token's own <style> block. fs is nil for pearls, which have no
// facets and get nothing back.
func applyCascade(markup, tidStr string, fs *facetStyle) (overlay string, css string) {
	spans := scanFacetSpans(markup)
	if fs == nil || len(fs.ringCent) == 0 {
		return "", ""
	}
	rnd := newPRNG("fire" + tidStr)
	hits, period := buildFireHits(rnd, fs.ringCent, fs.prof)
	// The rock runs with delay -rphase, so at wall time t it is at rock
	// time t+rphase. The fire wants its own time c to sit a quarter cycle
	// behind rock time (c = r - 0.25R), so that buildFireHits' 25%/75%
	// slots land on the rock's 50%/0% mid-swings: delay = -(rphase -
	// 0.25R), pushed up by one period so it stays a plain negative delay.
	_, _, rphase, _, _ := motionPhases(tidStr)
	fireDelay := rphase - 0.25*motionRDur + period

	var keyframes strings.Builder
	var out strings.Builder
	ringIdx := -1
	for _, span := range spans {
		if !span.ringMember {
			continue
		}
		ringIdx++
		if ringIdx >= len(hits) || len(hits[ringIdx]) == 0 {
			continue
		}
		c := fs.ringCent[ringIdx]
		color, colorOp := fs.flash.sample(c.x, c.y)

		stops := []cascadeStop{{0, "opacity:0;fill:#fff"}, {100, "opacity:0;fill:#fff"}}
		for _, w := range hits[ringIdx] {
			stops = append(stops,
				cascadeStop{modPct(w.enter / period), "opacity:0;fill:#fff"},
				cascadeStop{modPct(w.peak / period), "opacity:" + fnum(w.peakOp) + ";fill:#fff"},
				cascadeStop{modPct(w.mid / period), "opacity:" + fnum(w.peakOp*0.5*colorOp) + ";fill:" + color},
				cascadeStop{modPct(w.exit / period), "opacity:0;fill:" + color},
			)
		}
		sortCascadeStops(stops)

		kfName := ufmt.Sprintf("fc%s_%d", tidStr, ringIdx)
		keyframes.WriteString("@keyframes " + kfName + "{")
		for _, st := range stops {
			keyframes.WriteString(fnum1(st.pct) + `%{` + st.body + `}`)
		}
		keyframes.WriteString("}")

		// Only the geometry attribute survives: the tag is re-emitted as a
		// plain shape (no class, no fill-opacity) so nothing else in it can
		// leak into the overlay.
		tag := markup[span.start:span.end]
		geomEnd := strings.Index(tag, `" fill=`)
		if geomEnd < 0 {
			continue
		}
		out.WriteString(tag[:geomEnd] + `" fill="#fff" opacity="0" style="animation:` + kfName + ` ` + fnum(period) + `s linear infinite;animation-delay:-` + fnum(fireDelay) + `s"/>`)
	}
	return out.String(), keyframes.String()
}

/* ---------------------------------- label + serial ---------------------------------- */

func renderMetalLabelRect(metalHi, metalLo string, x, y, w, h, rx float64, salt string) string {
	// Echoes the ring's multi-band tilt but heavily muted — a soft
	// two-step blend instead of the ring's hard alternating stops, so the
	// bar doesn't visually fight the chain-name text sitting on top of it.
	gid := "labelgrad" + salt
	defs := `<linearGradient id="` + gid + `" x1="0%" y1="0%" x2="100%" y2="100%">` +
		`<stop offset="0%" stop-color="` + metalHi + `"/>` +
		`<stop offset="30%" stop-color="` + mixHex(metalHi, metalLo, 0.3) + `"/>` +
		`<stop offset="55%" stop-color="` + mixHex(metalLo, metalHi, 0.3) + `"/>` +
		`<stop offset="100%" stop-color="` + metalLo + `"/></linearGradient>`
	rect := `<rect x="` + fnum(x) + `" y="` + fnum(y) + `" width="` + fnum(w) + `" height="` + fnum(h) + `" rx="` + fnum(rx) + `" fill="url(#` + gid + `)"/>`
	bevelTop := `<rect x="` + fnum(x+1.5) + `" y="` + fnum(y+0.6) + `" width="` + fnum(w-3) + `" height="1.1" rx="0.55" fill="url(#` + gid + `)" opacity="0.85"/>`
	bevelBottom := `<rect x="` + fnum(x+1.5) + `" y="` + fnum(y+h-1.7) + `" width="` + fnum(w-3) + `" height="1.1" rx="0.55" fill="url(#` + gid + `)" opacity="0.85"/>`
	return `<defs>` + defs + `</defs>` + rect + bevelTop + bevelBottom
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
	"Sapphire": {
		{"#00b6ff", "Blue"}, {"#ff6ea4", "Pink"}, {"#ff8501", "Orange"}, {"#ffd500", "Yellow"},
		{"#02d66e", "Green"}, {"#a658ff", "Violet"}, {"#e6e9f8", "White"}, {"#ff732f", "Padparadscha"},
	},
	"Topaz": {
		{"#f5edd1", "Colorless"}, {"#ffa300", "Imperial"}, {"#ffd100", "Golden"},
		{"#ff6900", "Sherry Brown"}, {"#33b2ff", "Sky Blue"}, {"#ff96ba", "Pink"},
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
	"Not Set": {
		{"#f45656", "Red"}, {"#00b6ff", "Blue"}, {"#02d66e", "Green"}, {"#ff6ea4", "Pink"},
		{"#ff8501", "Orange"}, {"#ffd500", "Yellow"}, {"#a658ff", "Violet"}, {"#e6e9f8", "White"},
		{"#ffd100", "Golden"}, {"#f5edd1", "Colorless"}, {"#dfe7f2", "Crystal"},
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
	"Pearl": {
		{"#f8f6f0", "White"}, {"#f0e4c8", "Cream"}, {"#3a3a3c", "Black"}, {"#c8cdd4", "Silver"},
		{"#d4af6a", "Gold"}, {"#f0d4dc", "Pink"}, {"#f2c9a8", "Peach"}, {"#d8cbe0", "Lavender"},
	},
}

// stoneNames tracks insertion order for deterministic listing (Go/Gno
// map iteration order is randomized) -- kept in sync with stonePalettes
// by registerStoneName, called from both AddStoneColor and
// SetStoneForChain (nftminter.gno).
var stoneNames = []string{"Sapphire", "Topaz", "Pearl", "Not Set"}

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
	return "Not Set"
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
		palette = stonePalettes["Not Set"]
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
	return len(stonePalettes["Not Set"])
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
		palette = stonePalettes["Not Set"]
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
func RenderTokenSVG(chain, metal string, shapeIdx, colorIdx int, active bool, tidStr string) (svg string, stone string, colorHex string, colorName string) {
	var cascadeCSS string
	stone = StoneForChain(chain)
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
		pearl := renderPearlShape(shapeIdx, colorHex, tidStr)
		overlay, css := applyCascade(pearl, tidStr, nil)
		gemMarkup, cascadeCSS = pearl+overlay, css
	} else {
		fs := &facetStyle{prof: fireProfileFor(stone, colorName), zone: newPRNG("zone" + tidStr)}
		defs := gemFacetDefs(colorHex, tidStr, fs)
		outline := gemOutline(shapeIdx)
		facets := renderGem(shapeIdx, fs)
		overlay, css := applyCascade(facets, tidStr, fs)
		cascadeCSS = css
		gemMarkup = defs + renderGemBody(outline, tidStr) +
			facets + overlay + renderGemRim(outline, colorHex)
	}
	floatingGem := applyMotion(gemMarkup, tidStr)
	status := renderStatusBadge(active)
	serial := renderSerialText(tidStr, mt.hi)
	labelText := metalLabel[metal].text
	labelRect := renderMetalLabelRect(mt.hi, mt.lo, 24, 134, 122, 15, 3, tidStr)

	inner := `<rect width="` + fnum(canvasW) + `" height="` + fnum(canvasH) + `" fill="#0a0b10"/>` +
		ringEls + floatingGem + status + serial + labelRect +
		`<text x="` + fnum(subjX) + `" y="144.5" font-size="9.5" text-anchor="middle" fill="` + labelText + `" font-family="ui-monospace,monospace" font-weight="700">` + chain + ` CHAIN</text>`

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
	const easeInOut = "cubic-bezier(.45,0,.55,1)"
	const easeOut = "cubic-bezier(0,0,.3,1)"
	px, py := fnum(subjX)+"px", fnum(subjY)+"px"
	dpx, dpy := fnum(dotX)+"px", fnum(dotY)+"px"
	return `<style>` +
		// will-change:transform on the motion chain is a compositing hint,
		// not a cosmetic tweak -- confirmed to matter for Safari
		// specifically. No live SVG <filter> sits under these anymore
		// (see saturate's own doc comment for why one used to, and why
		// that was the real cost -- a rendered gem is now plain
		// path/circle elements with their final fill colors already
		// baked in, nothing left for a filter to re-rasterize).
		`.gt-v{will-change:transform;animation:gt-kf-v var(--v-dur) ` + easeInOut + ` infinite;animation-delay:var(--v-delay)}` +
		`.gt-h{will-change:transform;animation:gt-kf-h var(--h-dur) ` + easeInOut + ` infinite;animation-delay:var(--h-delay)}` +
		`.gt-r{will-change:transform;animation:gt-kf-r var(--r-dur) ` + easeInOut + ` infinite;animation-delay:var(--r-delay);transform-box:view-box;transform-origin:` + px + ` ` + py + `}` +
		`.gt-s{will-change:transform;animation:gt-kf-s var(--s-dur) ` + easeInOut + ` infinite;animation-delay:var(--s-delay);transform-box:view-box;transform-origin:` + px + ` ` + py + `}` +
		`.gt-glow{animation:gt-kf-glow var(--glow-dur) ` + easeInOut + ` infinite;animation-delay:var(--glow-delay)}` +
		// Animates transform:scale()+opacity, not r -- r/cx/cy are SVG2
		// geometry properties promoted to CSS-animatable status much more
		// recently, and less consistently, than transform/opacity (which
		// every engine has animated reliably for years); the earlier
		// r-based version is the likely reason this pulse wasn't visibly
		// animating at all. transform-origin pinned to the badge's own
		// (fixed, non-per-token) center so it scales outward in place
		// instead of toward the SVG's default (0,0) origin.
		`.gt-badge-pulse{transform-box:view-box;transform-origin:` + dpx + ` ` + dpy + `;animation:gt-kf-badge-pulse 1.8s ` + easeOut + ` infinite}` +
		`@keyframes gt-kf-v{0%,100%{transform:translate(0,0)}50%{transform:translate(0,-5px)}}` +
		`@keyframes gt-kf-h{0%,100%{transform:translate(0,0)}50%{transform:translate(1.8px,0)}}` +
		`@keyframes gt-kf-r{0%,100%{transform:rotate(0deg)}25%{transform:rotate(calc(-1 * var(--rot-deg)))}50%{transform:rotate(0deg)}75%{transform:rotate(var(--rot-deg))}}` +
		`@keyframes gt-kf-s{0%,100%{transform:scale(1)}50%{transform:scale(` + fnum(motionScale) + `)}}` +
		`@keyframes gt-kf-glow{0%,100%{opacity:0}50%{opacity:1}}` +
		`@keyframes gt-kf-badge-pulse{from{transform:scale(1);opacity:.8}to{transform:scale(2.25);opacity:0}}` +
		`</style>`
}
