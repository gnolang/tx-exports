// Package g9 (this file): on-chain SVG generator for the "gem in a
// ring" collection, ported from the Python prototype used to design and
// approve the final look. Every function here is pure — no state reads or
// writes — so a token's full image can be recomputed on any read
// (TokenURI/Render) instead of being stored as a precomputed blob.
//
// This is the architecture change requested explicitly: instead of the
// owner precomputing and storing a full ~7.6KB image string per token via
// AddPresetToken (kept intact in g9.gno for reuse on a future
// collection), this file's shared generator code is stored ONCE, and each
// token only needs a handful of small trait selections (see traitPreset in
// g9.gno) — the image is assembled from those on demand. Storage
// cost stops scaling with token count; it's dominated by this file's own
// one-time deployment cost instead.
package g9

import (
	"crypto/sha256"
	"math"

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
// phases/rotation degree) — never for
// which trait combination a piece has (that's the owner-curated
// traitPreset, picked from the pool via the existing pickRandomIndex).
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

/* -------------------------------- facet opacity constant -------------------------------- */

const facetOp = 0.55       // "Option B: translucent facets" — light shows through
const facetOpCenter = 0.5 // facetOp * 0.9, rounded

/* ------------------------------------ gem shapes ------------------------------------ */
// Each takes a base hex color (+ a salt string, used only by the one shape
// that needs a unique gradient id) and returns SVG fragment markup. Ported
// directly from the approved Python generator — same anatomy, same shade
// ratios, same facet counts.

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
// computes inline for its outer facet loop. Shared with shapeClip case 0
// so the shimmer's mask can never silently drift away from the actual
// rendered outline.
func roundOutline(r float64) []pt {
	n := roundSpiralN
	pts := make([]pt, n)
	for k := 0; k < n; k++ {
		a := 2*math.Pi*float64(k)/float64(n) - math.Pi/2 + math.Pi/float64(n)*(1+roundSpiralTwist)
		pts[k] = pt{subjX + r*math.Cos(a), subjY + r*math.Sin(a)}
	}
	return pts
}

func gemRound(base string) string {
	shades := shadeSeries(base, 12, 0.55, 1.35)
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
		out += `<path d="` + polyPath([]pt{p1i, p1o, p2o, p2i}) + `" fill="` + shades[k%len(shades)] + `" opacity="0.55"/>`
	}
	for k := 0; k < n; k++ {
		a1 := 2*math.Pi*float64(k)/float64(n) - math.Pi/2 + math.Pi/float64(n)
		p1i := pt{subjX + crownR*math.Cos(a1), subjY + crownR*math.Sin(a1)}
		p2i := pt{subjX + crownR*math.Cos(a1+2*math.Pi/float64(n)), subjY + crownR*math.Sin(a1+2*math.Pi/float64(n))}
		p1o := outerPts[k]
		p2o := outerPts[(k+1)%n]
		out += `<path d="` + polyPath([]pt{p1i, p1o, p2o, p2i}) + `" fill="` + shades[(k+5)%len(shades)] + `" opacity="0.55"/>`
	}
	out += `<circle cx="` + fnum(subjX) + `" cy="` + fnum(subjY) + `" r="` + fnum(tableR) + `" fill="` + shades[len(shades)-1] + `" opacity="0.5"/>`
	return out
}

func gemEmerald(base string) string {
	shades := shadeSeries(base, 6, 0.55, 1.35)
	hw, hh := 17.0, 22.0
	outer := []pt{
		{subjX - hw, subjY - hh + 7}, {subjX - hw + 7, subjY - hh}, {subjX + hw - 7, subjY - hh}, {subjX + hw, subjY - hh + 7},
		{subjX + hw, subjY + hh - 7}, {subjX + hw - 7, subjY + hh}, {subjX - hw + 7, subjY + hh}, {subjX - hw, subjY + hh - 7},
	}
	inner := make([]pt, len(outer))
	for i, p := range outer {
		inner[i] = pt{p.x*0.55 + subjX*0.45, p.y*0.55 + subjY*0.45}
	}
	out := `<path d="` + polyPath(outer) + `" fill="` + shades[1] + `" opacity="0.55"/>`
	for i := range outer {
		a, b := outer[i], outer[(i+1)%len(outer)]
		ia, ib := inner[i], inner[(i+1)%len(inner)]
		out += `<path d="` + polyPath([]pt{a, b, ib, ia}) + `" fill="` + shades[i%len(shades)] + `" opacity="0.55"/>`
	}
	out += `<path d="` + polyPath(inner) + `" fill="` + shades[len(shades)-1] + `" opacity="0.5"/>`
	return out
}

func gemPrincess(base string) string {
	shades := shadeSeries(base, 8, 0.55, 1.35)
	half := 19.0
	pts := []pt{{subjX - half, subjY - half}, {subjX + half, subjY - half}, {subjX + half, subjY + half}, {subjX - half, subjY + half}}
	mid := pt{subjX, subjY}
	out := ""
	for i := 0; i < 4; i++ {
		a, b := pts[i], pts[(i+1)%4]
		m := pt{(a.x + b.x) / 2, (a.y + b.y) / 2}
		out += `<path d="` + polyPath([]pt{mid, a, m}) + `" fill="` + shades[i*2] + `" opacity="0.55"/>`
		out += `<path d="` + polyPath([]pt{mid, m, b}) + `" fill="` + shades[i*2+1] + `" opacity="0.55"/>`
	}
	return out
}

// gemRaw's jitter uses a FIXED seed (not per-piece) — same as the Python
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

func gemRaw(base string) string {
	shades := shadeSeries(base, 7, 0.4, 1.1)
	pts := rawCrystalPoints(22)
	mid := pt{subjX, subjY}
	out := ""
	for i := range pts {
		a, b := pts[i], pts[(i+1)%len(pts)]
		out += `<path d="` + polyPath([]pt{mid, a, b}) + `" fill="` + shades[i%len(shades)] + `" opacity="0.55"/>`
	}
	return out
}

func gemPear(base string) string {
	shades := shadeSeries(base, 6, 0.55, 1.35)
	w, h := 19.0, 29.0
	pts := []pt{
		{subjX, subjY - h*0.5}, {subjX - w*0.55, subjY - h*0.1}, {subjX - w*0.35, subjY + h*0.35},
		{subjX, subjY + h*0.55}, {subjX + w*0.35, subjY + h*0.35}, {subjX + w*0.55, subjY - h*0.1},
	}
	mid := pt{subjX, subjY}
	out := `<path d="` + polyPath(pts) + `" fill="` + shades[1] + `" opacity="0.55"/>`
	for i := range pts {
		a, b := pts[i], pts[(i+1)%len(pts)]
		out += `<path d="` + polyPath([]pt{mid, a, b}) + `" fill="` + shades[(i*2)%len(shades)] + `" opacity="0.55"/>`
	}
	return out
}

func gemHeart(base string) string {
	shades := shadeSeries(base, 6, 0.55, 1.35)
	s := 24.0
	pts := []pt{
		{subjX, subjY + s*0.6}, {subjX - s*0.55, subjY - s*0.05}, {subjX - s*0.28, subjY - s*0.5},
		{subjX, subjY - s*0.15}, {subjX + s*0.28, subjY - s*0.5}, {subjX + s*0.55, subjY - s*0.05},
	}
	mid := pt{subjX, subjY}
	out := `<path d="` + polyPath(pts) + `" fill="` + shades[1] + `" opacity="0.55"/>`
	for i := range pts {
		a, b := pts[i], pts[(i+1)%len(pts)]
		out += `<path d="` + polyPath([]pt{mid, a, b}) + `" fill="` + shades[(i*2+1)%len(shades)] + `" opacity="0.55"/>`
	}
	return out
}

func trillionOutline(r float64) []pt {
	angles := []float64{0, 2 * math.Pi / 3, 4 * math.Pi / 3}
	pts := make([]pt, 3)
	for i, a := range angles {
		pts[i] = pt{subjX + r*math.Cos(a-math.Pi/2), subjY + r*math.Sin(a-math.Pi/2)}
	}
	return pts
}

func gemTrillion(base string) string {
	shades := shadeSeries(base, 6, 0.55, 1.35)
	pts := trillionOutline(23)
	mid := pt{subjX, subjY}
	out := `<path d="` + polyPath(pts) + `" fill="` + shades[1] + `" opacity="0.55"/>`
	for i := 0; i < 3; i++ {
		a, b := pts[i], pts[(i+1)%3]
		out += `<path d="` + polyPath([]pt{mid, a, b}) + `" fill="` + shades[(i*2)%len(shades)] + `" opacity="0.55"/>`
	}
	return out
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
// and narrower ones near the tips. Shared with shapeClip case 7 for the
// same reason as roundOutline: a smooth-ellipse clip is visibly larger
// than this polygon between vertices.
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
func gemOval(base string) string {
	shades := shadeSeries(base, 6, 0.55, 1.35)
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
	out := `<path d="` + polyPath(outerPts) + `" fill="` + shades[1] + `" opacity="0.55"/>`
	for k := 0; k < n; k++ {
		a, b := outerPts[k], outerPts[(k+1)%n]
		ia, ib := innerPts[k], innerPts[(k+1)%n]
		out += `<path d="` + polyPath([]pt{a, b, ib, ia}) + `" fill="` + shades[k%len(shades)] + `" opacity="0.55"/>`
	}
	out += `<path d="` + polyPath(innerPts) + `" fill="` + shades[len(shades)-1] + `" opacity="0.5"/>`
	return out
}

func asscherOutline(half float64) []pt {
	c := half * 0.4
	return []pt{
		{subjX - half + c, subjY - half}, {subjX + half - c, subjY - half}, {subjX + half, subjY - half + c}, {subjX + half, subjY + half - c},
		{subjX + half - c, subjY + half}, {subjX - half + c, subjY + half}, {subjX - half, subjY + half - c}, {subjX - half, subjY - half + c},
	}
}

func gemAsscher(base string) string {
	shades := shadeSeries(base, 6, 0.55, 1.35)
	outer := asscherOutline(19)
	inner := make([]pt, len(outer))
	for i, p := range outer {
		inner[i] = pt{p.x*0.5 + subjX*0.5, p.y*0.5 + subjY*0.5}
	}
	out := `<path d="` + polyPath(outer) + `" fill="` + shades[1] + `" opacity="0.55"/>`
	for i := range outer {
		a, b := outer[i], outer[(i+1)%len(outer)]
		ia, ib := inner[i], inner[(i+1)%len(inner)]
		out += `<path d="` + polyPath([]pt{a, b, ib, ia}) + `" fill="` + shades[i%len(shades)] + `" opacity="0.55"/>`
	}
	out += `<path d="` + polyPath(inner) + `" fill="` + shades[len(shades)-1] + `" opacity="0.5"/>`
	return out
}

func radiantOutline(hw, hh, c float64) []pt {
	return []pt{
		{subjX - hw + c, subjY - hh}, {subjX + hw - c, subjY - hh}, {subjX + hw, subjY - hh + c}, {subjX + hw, subjY + hh - c},
		{subjX + hw - c, subjY + hh}, {subjX - hw + c, subjY + hh}, {subjX - hw, subjY + hh - c}, {subjX - hw, subjY - hh + c},
	}
}

func gemRadiant(base string) string {
	shades := shadeSeries(base, 6, 0.55, 1.35)
	outer := radiantOutline(21, 17, 6)
	inner := make([]pt, len(outer))
	for i, p := range outer {
		inner[i] = pt{p.x*0.5 + subjX*0.5, p.y*0.5 + subjY*0.5}
	}
	out := `<path d="` + polyPath(outer) + `" fill="` + shades[1] + `" opacity="0.55"/>`
	for i := range outer {
		a, b := outer[i], outer[(i+1)%len(outer)]
		ia, ib := inner[i], inner[(i+1)%len(inner)]
		out += `<path d="` + polyPath([]pt{a, b, ib, ia}) + `" fill="` + shades[(i+2)%len(shades)] + `" opacity="0.55"/>`
	}
	out += `<path d="` + polyPath(inner) + `" fill="` + shades[len(shades)-1] + `" opacity="0.5"/>`
	return out
}

// roseOutline returns gemRose's 6 hexagon vertices at radius r -- the
// actual rendered silhouette of the "hexagonal" cut, matching a real
// antique hexagonal rose cut's flat-edged outline instead of a round
// girdle. Shared with shapeClip's default case for the same reason as
// roundOutline/ovalOutline.
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
// edges never lined up, reading as uneven).
func gemRose(base string) string {
	shades := shadeSeries(base, 8, 0.5, 1.4)
	r := 23.0
	hexPts := roseOutline(r)
	apex := pt{subjX, subjY - r*0.1}
	out := `<polygon points="` + polygonPoints(hexPts) + `" fill="` + shades[0] + `" opacity="0.5"/>`
	for k := 0; k < 6; k++ {
		p1, p2 := hexPts[k], hexPts[(k+1)%6]
		out += `<path d="` + polyPath([]pt{apex, p1, p2}) + `" fill="` + shades[2+k] + `" opacity="0.6"/>`
	}
	return out
}

// shapeNames/shapeR mirror the Python SHAPES/SHAPE_NAMES/SHAPE_R lists
// exactly, same order, so a stored ShapeIdx means the same cut on both
// sides.
// Cabochon (a smooth, unfaceted dome cut) was removed from the trait
// pool per request -- indices above it are unchanged (Rose Cut still
// falls through to the switch's default case, same as before).
var shapeNames = []string{
	"Round Brilliant", "Emerald Cut", "Princess Cut", "Raw Crystal", "Pear", "Heart",
	"Trillion", "Oval", "Asscher", "Radiant", "Rose Cut",
}
var shapeR = []float64{20, 20, 19, 22, 20, 22, 23, 20, 19, 20, 23}

// renderGem dispatches to the right gem_* function by index.
func renderGem(shapeIdx int, base string) string {
	switch shapeIdx {
	case 0:
		return gemRound(base)
	case 1:
		return gemEmerald(base)
	case 2:
		return gemPrincess(base)
	case 3:
		return gemRaw(base)
	case 4:
		return gemPear(base)
	case 5:
		return gemHeart(base)
	case 6:
		return gemTrillion(base)
	case 7:
		return gemOval(base)
	case 8:
		return gemAsscher(base)
	case 9:
		return gemRadiant(base)
	default:
		return gemRose(base)
	}
}

// shapeClip returns the <circle>/<ellipse>/<polygon> markup used as the
// shimmer's <mask> shape (see renderShimmer) to constrain the highlight
// to the gem's own silhouette — same outline formulas each gem_*
// function itself draws with.
func shapeClip(shapeIdx int) string {
	switch shapeIdx {
	case 0:
		return `<polygon points="` + polygonPoints(roundOutline(20)) + `"/>`
	case 1:
		return `<polygon points="` + polygonPoints([]pt{
			{subjX - 17, subjY - 22 + 7}, {subjX - 17 + 7, subjY - 22}, {subjX + 17 - 7, subjY - 22}, {subjX + 17, subjY - 22 + 7},
			{subjX + 17, subjY + 22 - 7}, {subjX + 17 - 7, subjY + 22}, {subjX - 17 + 7, subjY + 22}, {subjX - 17, subjY + 22 - 7},
		}) + `"/>`
	case 2:
		return `<polygon points="` + polygonPoints([]pt{{subjX - 19, subjY - 19}, {subjX + 19, subjY - 19}, {subjX + 19, subjY + 19}, {subjX - 19, subjY + 19}}) + `"/>`
	case 3:
		return `<polygon points="` + polygonPoints(rawCrystalPoints(22)) + `"/>`
	case 4:
		return `<polygon points="` + polygonPoints([]pt{
			{subjX, subjY - 29*0.5}, {subjX - 19*0.55, subjY - 29*0.1}, {subjX - 19*0.35, subjY + 29*0.35},
			{subjX, subjY + 29*0.55}, {subjX + 19*0.35, subjY + 29*0.35}, {subjX + 19*0.55, subjY - 29*0.1},
		}) + `"/>`
	case 5:
		return `<polygon points="` + polygonPoints([]pt{
			{subjX, subjY + 24*0.6}, {subjX - 24*0.55, subjY - 24*0.05}, {subjX - 24*0.28, subjY - 24*0.5},
			{subjX, subjY - 24*0.15}, {subjX + 24*0.28, subjY - 24*0.5}, {subjX + 24*0.55, subjY - 24*0.05},
		}) + `"/>`
	case 6:
		return `<polygon points="` + polygonPoints(trillionOutline(23)) + `"/>`
	case 7:
		return `<polygon points="` + polygonPoints(ovalOutline(17, 23)) + `"/>`
	case 8:
		return `<polygon points="` + polygonPoints(asscherOutline(19)) + `"/>`
	case 9:
		return `<polygon points="` + polygonPoints(radiantOutline(21, 17, 6)) + `"/>`
	default:
		return `<polygon points="` + polygonPoints(roseOutline(23)) + `"/>`
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
	coreColor := lighten(metalHi, 0.55)
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
	dur := rnd.floatIn(1.6, 2.4)
	phase := rnd.floatIn(0, dur)

	stopsA := donutStops(2.5*2.0/3.0*0.5, 0.4, gidA)
	stopsB := donutStops(8.0*2.0/3.0*0.5, 1.0, gidB)

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
func applyMotion(content, salt string) string {
	rnd := newPRNG("motion" + salt)
	vphase := rnd.floatIn(0, motionVDur)
	hphase := rnd.floatIn(0, motionHDur)
	rphase := rnd.floatIn(0, motionRDur)
	sphase := rnd.floatIn(0, motionSDur)
	rotDeg := rnd.floatIn(motionRotMin, motionRotMax)

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
			`<circle cx="` + fnum(dotX) + `" cy="` + fnum(dotY) + `" r="1" fill="none" stroke="#7fd88f" stroke-width="1.2" class="gt-badge-pulse" opacity="0.8"/>`
	}
	return `<circle cx="` + fnum(dotX) + `" cy="` + fnum(dotY) + `" r="4" fill="#5a5f6b"/>`
}

/* ------------------------------------ shimmer ------------------------------------ */

// renderShimmer replaces the old rotating glint with a soft iridescent
// sheen clipped to the gem's own silhouette -- confirmed live across the
// whole collection (a hundred-plus real pieces, then narrowed through
// several side-by-side comparisons of brightness and color range) before
// becoming the real default.
//
// Built via <foreignObject> embedding the confirmed CSS technique
// verbatim (a 260%-oversized linear-gradient background swept via
// background-position, color-dodge blended) rather than an SVG-native
// <linearGradient>+<mask>+translating <rect> -- an earlier from-scratch
// SVG port of the same idea LOOKED similar at a glance but produced a
// completely different result once checked against the same base gem
// side-by-side: objectBoundingBox gradient stops are rigidly tied to
// whatever rect currently holds them, so translating that rect (no
// matter how large) can never sweep genuinely different stops across a
// small fixed silhouette the way CSS background-position does across an
// oversized background. foreignObject sidesteps re-deriving that math by
// running the actual confirmed CSS. Same tradeoff the rest of this
// file's CSS-driven motion already accepts: an SVG viewer with no CSS
// engine won't show the sweep (or the float/rotate/hue-cycle on every
// other piece), but the artwork itself stays intact.
func renderShimmer(shapeIdx int, salt string) string {
	clipID := "shimclip" + salt
	clip := shapeClip(shapeIdx)

	return `<defs><clipPath id="` + clipID + `">` + clip + `</clipPath></defs>` +
		`<foreignObject x="0" y="0" width="` + fnum(canvasW) + `" height="` + fnum(canvasH) + `" clip-path="url(#` + clipID + `)">` +
		`<div xmlns="http://www.w3.org/1999/xhtml" class="gt-shimmer-wrap"><div class="gt-shimmer"></div></div>` +
		`</foreignObject>`
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
// AddStoneColor (g9.gno) so a FUTURE gno.land testnet generation
// that gets a real gem codename can be recognized without a contract
// redeploy — the whole point of putting this data in state instead of
// source.
var stoneByChain = map[string]string{
	"TOPAZ-1":    "Topaz",
	"SAPPHIRE-1": "Sapphire",
}

// All hex values here are the original palette run through the exact
// CSS/SVG feColorMatrix type="saturate" formula at s=1.5 (150%) --
// confirmed against a live side-by-side comparison (three saturation
// levels, same six real minted pieces) before choosing this one, "the
// enhanced saturation" over both the original 100% and a more extreme
// 200% option. Not a hand-picked repaint -- every value is the
// deterministic output of that one matrix, so hues stay true, only
// intensity increases.
var stonePalettes = map[string][]namedColor{
	"Sapphire": {
		{"#2dabe1", "Blue"}, {"#ff7da1", "Pink"}, {"#ff8e36", "Orange"}, {"#f6d221", "Yellow"},
		{"#37c47f", "Green"}, {"#9763ff", "Violet"}, {"#e7e9f3", "White"}, {"#ff7f52", "Padparadscha"},
	},
	"Topaz": {
		{"#f2edda", "Colorless"}, {"#faa600", "Imperial"}, {"#ffd028", "Golden"},
		{"#ea732b", "Sherry Brown"}, {"#57acfa", "Sky Blue"}, {"#ffa1b9", "Pink"},
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
	"Not Set": {
		{"#ff4b4b", "Red"}, {"#2dabe1", "Blue"}, {"#37c47f", "Green"}, {"#ff7da1", "Pink"},
		{"#ff8e36", "Orange"}, {"#f6d221", "Yellow"}, {"#9763ff", "Violet"}, {"#e7e9f3", "White"},
		{"#ffd028", "Golden"}, {"#f2edda", "Colorless"},
	},
}

// stoneNames tracks insertion order for deterministic listing (Go/Gno
// map iteration order is randomized) -- kept in sync with stonePalettes
// by registerStoneName, called from both AddStoneColor and
// SetStoneForChain (g9.gno).
var stoneNames = []string{"Sapphire", "Topaz", "Not Set"}

func registerStoneName(stone string) {
	for _, s := range stoneNames {
		if s == stone {
			return
		}
	}
	stoneNames = append(stoneNames, stone)
}

// stoneForChain: only gno.land testnet generations that were actually
// given a gemstone codename (Topaz-1, Sapphire-1 at launch) get one —
// every other/future chain is "Not Set" rather than a guessed mineral
// name, unless the owner explicitly assigns one via SetStoneForChain.
func stoneForChain(chain string) string {
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

// colorPaletteSize reports how many colors are valid for stone, so
// AddTraitPreset can validate a caller-supplied colorIdx. Same
// empty-palette fallback as colorForStone, for the same reason.
func colorPaletteSize(stone string) int {
	if n := len(stonePalettes[stone]); n > 0 {
		return n
	}
	return len(stonePalettes["Not Set"])
}

// FindShapeIndex reverse-maps a rendered "Shape" trait value (e.g.
// "Oval") back to its index into shapeNames. A source realm for a
// migration only ever exposes the rendered trait STRING (via
// CollectionSummary), never the raw index a migrated token would need
// to regenerate its own art instead of storing a full copy of it — this
// closes that gap for the migration tooling (see
// AddMigrationSnapshotEntry). ok is false if name doesn't match any
// current shape (not expected for anything this realm's own gems.gno
// produced, but a caller should treat that as "unrecognized," not guess).
func FindShapeIndex(name string) (idx int, ok bool) {
	for i, s := range shapeNames {
		if s == name {
			return i, true
		}
	}
	return -1, false
}

// FindColorIndex reverse-maps a rendered "Color" trait value back to
// its index in chain's own stone palette — colorIdx is only meaningful
// relative to a specific stone (derived from chain via stoneForChain),
// not a single global color list, so this needs the chain too. Same
// migration-tooling purpose as FindShapeIndex.
func FindColorIndex(chain, colorName string) (idx int, ok bool) {
	stone := stoneForChain(chain)
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

// metals holds each metal's ring/label gradient tones. Mutable on-chain
// state, not hardcoded source (see SetMetalTone in g9.gno) --
// same reasoning as stonePalettes/stoneByChain: lets tuning continue
// after deploy without a redeploy. These starting values are the g8
// launch tones -- Gold/Silver/Bronze/Platinum each two darkening passes
// down from their original brighter values (Obsidian unchanged),
// confirmed via live side-by-side comparison batches before landing
// here.
var metals = map[string]metalTone{
	"Gold":     {"#a48b3f", "#6a5117"},
	"Silver":   {"#95989c", "#5e646c"},
	"Bronze":   {"#865b34", "#52391d"},
	"Platinum": {"#9fa2a4", "#767e87"},
	"Obsidian": {"#3a3d47", "#0d0e12"},
}

// metalNames is an ordered counterpart to metals -- Go/Gno map iteration
// order is randomized, so on-the-fly random trait assembly (MintAssembled,
// g9.gno) needs an indexable slice to pick a random metal from.
var metalNames = []string{"Gold", "Silver", "Bronze", "Platinum", "Obsidian"}

type metalLabelTone struct{ bg, text string }

var metalLabel = map[string]metalLabelTone{
	"Gold":     {"#f4d060", "#04121a"},
	"Silver":   {"#dfe4ea", "#04121a"},
	"Bronze":   {"#c9884f", "#04121a"},
	"Platinum": {"#eef2f5", "#04121a"},
	"Obsidian": {"#5a5f6b", "#e8e9f0"},
}

/* --------------------------------- full assembly --------------------------------- */

// renderTokenSVG assembles one token's complete SVG from its small trait
// selection, mirroring badge() in the Python prototype exactly (same
// element order, same layout constants). `salt` seeds every per-piece
// animation timing and every gradient id — the token's own real ID
// (tidStr), so nothing here is computed before mint assigns one.
func renderTokenSVG(chain, metal string, shapeIdx, colorIdx int, active bool, tidStr string) (svg string, stone string, colorHex string, colorName string) {
	stone = stoneForChain(chain)
	nc := colorForStone(stone, colorIdx)
	colorHex, colorName = nc.hex, nc.name
	mt := metals[metal]

	ringEls := renderRing(mt.hi, mt.lo, tidStr)
	// The confirmed shimmer recipe (the "Gem Shimmer Batch" comparison
	// artifact, batch 1 -- verified byte-for-byte against that artifact's
	// own source: identical gradient stops, identical mask/color-dodge
	// technique) applied a 1.5x saturation boost to the base gem image
	// (".gem-img{filter:saturate(1.5)}") *before* layering the shimmer on
	// top. That boost was preview-only CSS and never made it into this
	// real SVG -- side-by-side at matching scale, the two show the SAME
	// hue distribution (confirming the shimmer gradient itself was ported
	// correctly), the real version is just far less vivid without this.
	// feColorMatrix (SVG-native), not a CSS filter property, for
	// compatibility with NFT viewers that render SVG without a full CSS
	// engine. Gem facets only -- the shimmer stays unsaturated, exactly
	// matching how the confirmed preview's .fx-iri-sheen was never part
	// of .gem-img.
	gemEls := `<g filter="url(#gemsat)">` + renderGem(shapeIdx, colorHex) + `</g>`
	shimmer := renderShimmer(shapeIdx, tidStr)
	floatingGem := applyMotion(gemEls+shimmer, tidStr)
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
	svg = `<svg xmlns="http://www.w3.org/2000/svg" width="` + fnum(canvasW) + `" height="` + fnum(canvasH) + `" viewBox="0 0 ` + fnum(canvasW) + ` ` + fnum(canvasH) + `">` + styleBlock() +
		`<defs><filter id="gemsat"><feColorMatrix type="saturate" values="1.5"/></filter></defs>` + inner + `</svg>`
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
	return `<style>` +
		`.gt-v{animation:gt-kf-v var(--v-dur) ` + easeInOut + ` infinite;animation-delay:var(--v-delay)}` +
		`.gt-h{animation:gt-kf-h var(--h-dur) ` + easeInOut + ` infinite;animation-delay:var(--h-delay)}` +
		`.gt-r{animation:gt-kf-r var(--r-dur) ` + easeInOut + ` infinite;animation-delay:var(--r-delay);transform-box:view-box;transform-origin:` + px + ` ` + py + `}` +
		`.gt-s{animation:gt-kf-s var(--s-dur) ` + easeInOut + ` infinite;animation-delay:var(--s-delay);transform-box:view-box;transform-origin:` + px + ` ` + py + `}` +
		`.gt-glow{animation:gt-kf-glow var(--glow-dur) ` + easeInOut + ` infinite;animation-delay:var(--glow-delay)}` +
		`.gt-shimmer-wrap{width:` + fnum(canvasW) + `px;height:` + fnum(canvasH) + `px;position:relative;overflow:hidden}` +
		`.gt-shimmer{position:absolute;inset:0;background:linear-gradient(115deg,hsla(280,90%,70%,0) 12%,hsla(200,90%,65%,.6) 32%,hsla(140,85%,60%,.55) 48%,hsla(50,90%,65%,.6) 64%,hsla(320,90%,68%,0) 84%);background-size:260% 260%;mix-blend-mode:color-dodge;animation:gt-kf-shimmer 6s ease-in-out infinite}` +
		`.gt-badge-pulse{animation:gt-kf-badge-pulse 1.8s ` + easeOut + ` infinite}` +
		`@keyframes gt-kf-v{0%,100%{transform:translate(0,0)}50%{transform:translate(0,-5px)}}` +
		`@keyframes gt-kf-h{0%,100%{transform:translate(0,0)}50%{transform:translate(1.8px,0)}}` +
		`@keyframes gt-kf-r{0%,100%{transform:rotate(0deg)}25%{transform:rotate(calc(-1 * var(--rot-deg)))}50%{transform:rotate(0deg)}75%{transform:rotate(var(--rot-deg))}}` +
		`@keyframes gt-kf-s{0%,100%{transform:scale(1)}50%{transform:scale(` + fnum(motionScale) + `)}}` +
		`@keyframes gt-kf-glow{0%,100%{opacity:0}50%{opacity:1}}` +
		`@keyframes gt-kf-shimmer{0%,100%{background-position:0% 50%}50%{background-position:100% 50%}}` +
		`@keyframes gt-kf-badge-pulse{from{r:1;opacity:.8}to{r:9;opacity:0}}` +
		`</style>`
}
