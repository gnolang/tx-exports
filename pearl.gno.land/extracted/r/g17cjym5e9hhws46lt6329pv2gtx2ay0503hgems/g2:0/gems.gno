// Package nftminter (this file): on-chain SVG generator for the "gem in a
// ring" collection, ported from the Python prototype used to design and
// approve the final look. Every function here is pure — no state reads or
// writes — so a token's full image can be recomputed on any read
// (TokenURI/Render) instead of being stored as a precomputed blob.
//
// This is the architecture change requested explicitly: instead of the
// owner precomputing and storing a full ~7.6KB image string per token via
// AddPresetToken (kept intact in nftminter.gno for reuse on a future
// collection), this file's shared generator code is stored ONCE, and each
// token only needs a handful of small trait selections (see traitPreset in
// nftminter.gno) — the image is assembled from those on demand. Storage
// cost stops scaling with token count; it's dominated by this file's own
// one-time deployment cost instead.
package g2

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
// and %d instead.
func fnum(v float64) string {
	neg := v < 0
	if neg {
		v = -v
	}
	scaled := int64(v*100 + 0.5)
	whole := scaled / 100
	frac := scaled % 100
	s := ufmt.Sprintf("%d.%02d", whole, frac)
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
// phases/rotation degree, glint corner/direction/duration) — never for
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

// roundOutline returns the 8 true outer-girdle vertices of gemRound's
// facet ring at radius r -- the SAME points gemRound itself computes
// inline for its outer facet loop (offset by one half-step, +pi/n, from
// the inner table-to-crown ring). Shared with shapeClip case 0 so the
// glint's clip-path can never silently drift away from the actual
// rendered outline again -- it previously used a plain circle, which is
// visibly larger than this octagon between vertices, letting an
// outward-reaching glint spill past the real gem edge into the gap
// before the ring.
func roundOutline(r float64) []pt {
	n := 8
	pts := make([]pt, n)
	for k := 0; k < n; k++ {
		a := 2*math.Pi*float64(k)/float64(n) - math.Pi/2 + math.Pi/float64(n)
		pts[k] = pt{subjX + r*math.Cos(a), subjY + r*math.Sin(a)}
	}
	return pts
}

func gemRound(base string) string {
	shades := shadeSeries(base, 10, 0.55, 1.35)
	tableR, crownR, r := 20.0*0.32, 20.0*0.62, 20.0
	n := 8
	outerPts := roundOutline(r)
	out := ""
	for k := 0; k < n; k++ {
		a1 := 2*math.Pi*float64(k)/float64(n) - math.Pi/2
		a2 := 2*math.Pi*float64(k+1)/float64(n) - math.Pi/2
		p1i := pt{subjX + tableR*math.Cos(a1), subjY + tableR*math.Sin(a1)}
		p2i := pt{subjX + tableR*math.Cos(a2), subjY + tableR*math.Sin(a2)}
		p1o := pt{subjX + crownR*math.Cos(a1), subjY + crownR*math.Sin(a1)}
		p2o := pt{subjX + crownR*math.Cos(a2), subjY + crownR*math.Sin(a2)}
		out += `<path d="` + polyPath([]pt{p1i, p1o, p2o, p2i}) + `" fill="` + shades[k%len(shades)] + `" opacity="0.55"/>`
	}
	for k := 0; k < n; k++ {
		a1 := 2*math.Pi*float64(k)/float64(n) - math.Pi/2 + math.Pi/float64(n)
		p1i := pt{subjX + crownR*math.Cos(a1), subjY + crownR*math.Sin(a1)}
		p2i := pt{subjX + crownR*math.Cos(a1+2*math.Pi/float64(n)), subjY + crownR*math.Sin(a1+2*math.Pi/float64(n))}
		p1o := outerPts[k]
		p2o := outerPts[(k+1)%n]
		out += `<path d="` + polyPath([]pt{p1i, p1o, p2o, p2i}) + `" fill="` + shades[(k+4)%len(shades)] + `" opacity="0.55"/>`
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

// ovalOutline returns the 8 points gemOval fans its facets between --
// straight chords across a true ellipse, so the actual rendered
// silhouette is this polygon, slightly inscribed inside the smooth
// ellipse curve, not the smooth curve itself. Shared with shapeClip
// case 7 for the same reason as roundOutline: a smooth-ellipse clip is
// visibly larger than this polygon between vertices.
func ovalOutline(rx, ry float64) []pt {
	n := 8
	pts := make([]pt, n)
	for k := 0; k < n; k++ {
		a := 2*math.Pi*float64(k)/float64(n) - math.Pi/2
		pts[k] = pt{subjX + rx*math.Cos(a), subjY + ry*math.Sin(a)}
	}
	return pts
}

func gemOval(base string) string {
	shades := shadeSeries(base, 8, 0.55, 1.35)
	rx, ry := 17.0, 23.0
	n := 8
	outerPts := ovalOutline(rx, ry)
	out := ""
	for k := 0; k < n; k++ {
		p1 := outerPts[k]
		p2 := outerPts[(k+1)%n]
		out += `<path d="` + polyPath([]pt{{subjX, subjY}, p1, p2}) + `" fill="` + shades[k] + `" opacity="0.55"/>`
	}
	out += `<ellipse cx="` + fnum(subjX) + `" cy="` + fnum(subjY) + `" rx="` + fnum(rx*0.4) + `" ry="` + fnum(ry*0.3) + `" fill="` + shades[len(shades)-1] + `" opacity="0.5"/>`
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

func gemRose(base string) string {
	shades := shadeSeries(base, 10, 0.55, 1.35)
	r := 23.0
	out := `<circle cx="` + fnum(subjX) + `" cy="` + fnum(subjY) + `" r="` + fnum(r) + `" fill="` + shades[0] + `" opacity="0.55"/>`
	apex := pt{subjX, subjY - r*0.15}
	innerR := r * 0.55
	for k := 0; k < 6; k++ {
		a1 := 2 * math.Pi * float64(k) / 6
		a2 := 2 * math.Pi * float64(k+1) / 6
		p1 := pt{subjX + innerR*math.Cos(a1), subjY + innerR*math.Sin(a1)}
		p2 := pt{subjX + innerR*math.Cos(a2), subjY + innerR*math.Sin(a2)}
		out += `<path d="` + polyPath([]pt{apex, p1, p2}) + `" fill="` + shades[2+k] + `" opacity="0.55"/>`
	}
	for k := 0; k < 12; k++ {
		a1 := 2 * math.Pi * float64(k) / 12
		a2 := 2 * math.Pi * float64(k+1) / 12
		p1i := pt{subjX + innerR*math.Cos(a1), subjY + innerR*math.Sin(a1)}
		p2i := pt{subjX + innerR*math.Cos(a2), subjY + innerR*math.Sin(a2)}
		p1o := pt{subjX + r*math.Cos(a1), subjY + r*math.Sin(a1)}
		p2o := pt{subjX + r*math.Cos(a2), subjY + r*math.Sin(a2)}
		out += `<path d="` + polyPath([]pt{p1i, p1o, p2o, p2i}) + `" fill="` + shades[(k+4)%len(shades)] + `" opacity="0.55"/>`
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

// shapeClip returns the <circle>/<ellipse>/<polygon> markup used inside a
// <clipPath> to constrain the glint highlight to the gem's own silhouette
// — same outline formulas each gem_* function itself draws with.
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
		return `<circle cx="` + fnum(subjX) + `" cy="` + fnum(subjY) + `" r="23"/>`
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
	gid := "ring" + salt
	defs := `<linearGradient id="` + gid + `" x1="0%" y1="0%" x2="100%" y2="100%">` +
		`<stop offset="0%" stop-color="` + metalHi + `"/><stop offset="100%" stop-color="` + metalLo + `"/></linearGradient>`

	outer := `<circle cx="` + fnum(subjX) + `" cy="` + fnum(subjY) + `" r="52.3" fill="none" stroke="` + metalHi + `" stroke-width="1" opacity="0.55"/>` +
		`<circle cx="` + fnum(subjX) + `" cy="` + fnum(subjY) + `" r="50" fill="none" stroke="url(#` + gid + `)" stroke-width="4"/>` +
		`<circle cx="` + fnum(subjX) + `" cy="` + fnum(subjY) + `" r="47.7" fill="none" stroke="` + metalLo + `" stroke-width="1" opacity="0.5"/>`

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

/* ------------------------------------- glint ------------------------------------- */

func renderGlint(shapeIdx int, colorHex, salt string) string {
	r := shapeR[shapeIdx]
	rnd := newPRNG("glint" + salt)
	dur := rnd.floatIn(3.0, 5.0)
	hw := r * 0.11
	if hw < 1.6 {
		hw = 1.6
	}
	// The ellipse's radial span (hy +/- hh, before rotation) needs to
	// overflow past the gem's real edge -- rely on the clip-path (which
	// now exactly matches every shape's true rendered silhouette, see
	// roundOutline/ovalOutline above) to terminate it precisely at the
	// edge, rather than the ellipse's own geometry ever falling short.
	// Never extend the INNER edge closer to center, only the outer.
	// Overflow factor 1.5x covers the tightest real case (Princess's
	// diagonal corner sits at 1.41x its own shapeR) with a small margin,
	// without extending so far that a shape with a genuinely sharp
	// vertex (Trillion) leaves only the ellipse's near-zero-width pole
	// overlapping it -- see Trillion's own dedicated anchor below, which
	// hit exactly that failure mode when it briefly reused this same
	// generous-overflow formula.
	const innerFrac, outerFrac = 0.18, 1.5
	hh := r * (outerFrac - innerFrac) / 2
	centerDist := r * (outerFrac + innerFrac) / 2

	corners := []float64{315, 45, 225, 135} // top-left, top-right, bottom-left, bottom-right
	clockwise := rnd.floatIn(0, 1) < 0.5

	var hy, peakAngle float64
	if shapeIdx == 6 {
		// Trillion: always the top vertex, never a random corner. Its
		// clip is an exact triangle with a genuine zero-width tip at
		// r -- the generic overflow above (whose ellipse CENTER lands
		// well past the tip) would leave only that ellipse's tapering
		// pole intersecting the triangle, reading as no glint at all.
		// Its own tighter anchor (already a confirmed-good tuning) is
		// kept close to the tip instead: inner 0.83r, outer 1.27r --
		// modest overflow past the true r=1.0 vertex, comfortable width
		// throughout.
		hy = subjY - shapeR[shapeIdx]*1.05
		hh = r * 0.22
		// peakAngle 0 (identity rotation) lands the ellipse back exactly
		// where it starts pre-rotation -- straight up, which is precisely
		// where trillionOutline's own vertex 0 sits. The previous value
		// (315, "top-left") rotated the peak-opacity instant 45 degrees
		// away from the actual vertex, onto a point on the triangle's
		// edge only ~12 units from center -- well short of where this
		// ellipse starts (19.09) -- so at the exact brightest moment the
		// ellipse never overlapped the clip at all. It only ever
		// (partially, dimly) showed during animation because the
		// rotation sweep happens to pass near the true vertex slightly
		// LATER in the visible window, as opacity is already fading.
		peakAngle = 0
	} else {
		hy = subjY - centerDist
		peakAngle = corners[rnd.intn(len(corners))]
	}

	var fromAngle, toAngle float64
	if clockwise {
		fromAngle = modf(peakAngle-180, 360)
		toAngle = fromAngle + 360
	} else {
		fromAngle = modf(peakAngle+180, 360)
		toAngle = fromAngle - 360
	}

	clipID := "clip" + salt
	clip := shapeClip(shapeIdx)

	// A tiny bit of the gem's own hue mixed into the highlight -- still
	// reads as white, but no longer a flat, colorless cutout -- so it
	// looks like light reflecting off this specific stone rather than a
	// generic white shape laid on top of it.
	glintColor := lighten(colorHex, 0.82)

	return `<defs><clipPath id="` + clipID + `">` + clip + `</clipPath></defs>` +
		`<g clip-path="url(#` + clipID + `)">` +
		`<g class="gt-glint-rot" style="--glint-dur:` + fnum(dur) + `s;--glint-delay:0s;--from-a:` + fnum(fromAngle) + `deg;--to-a:` + fnum(toAngle) + `deg">` +
		`<ellipse cx="` + fnum(subjX) + `" cy="` + fnum(hy) + `" rx="` + fnum(hw) + `" ry="` + fnum(hh) + `" fill="` + glintColor + `" class="gt-glint-op" style="--glint-dur:` + fnum(dur) + `s;--glint-delay:0s"/>` +
		`</g></g>`
}

func modf(v, m float64) float64 {
	r := v
	for r < 0 {
		r += m
	}
	for r >= m {
		r -= m
	}
	return r
}

/* ---------------------------------- label + serial ---------------------------------- */

func renderMetalLabelRect(metalHi, metalLo string, x, y, w, h, rx float64, salt string) string {
	gid := "labelgrad" + salt
	defs := `<linearGradient id="` + gid + `" x1="0%" y1="0%" x2="100%" y2="100%">` +
		`<stop offset="0%" stop-color="` + metalHi + `"/><stop offset="100%" stop-color="` + metalLo + `"/></linearGradient>`
	rect := `<rect x="` + fnum(x) + `" y="` + fnum(y) + `" width="` + fnum(w) + `" height="` + fnum(h) + `" rx="` + fnum(rx) + `" fill="url(#` + gid + `)"/>`
	bevelTop := `<rect x="` + fnum(x+1.5) + `" y="` + fnum(y+0.6) + `" width="` + fnum(w-3) + `" height="1.1" rx="0.55" fill="` + metalHi + `" opacity="0.65"/>`
	bevelBottom := `<rect x="` + fnum(x+1.5) + `" y="` + fnum(y+h-1.7) + `" width="` + fnum(w-3) + `" height="1.1" rx="0.55" fill="` + metalLo + `" opacity="0.6"/>`
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
}

var stonePalettes = map[string][]namedColor{
	"Sapphire": {
		{"#4fa3c7", "Blue"}, {"#e888a0", "Pink"}, {"#e8955a", "Orange"}, {"#e8d05a", "Yellow"},
		{"#5ab88a", "Green"}, {"#8e6be6", "Violet"}, {"#e8e9f0", "White"}, {"#e8886a", "Padparadscha"},
	},
	"Topaz": {
		{"#f0ede0", "Colorless"}, {"#e0a838", "Imperial"}, {"#f4d060", "Golden"},
		{"#c97a4a", "Sherry Brown"}, {"#6fa8dc", "Sky Blue"}, {"#e8a8b8", "Pink"},
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
		{"#e85a5a", "Red"}, {"#4fa3c7", "Blue"}, {"#5ab88a", "Green"}, {"#e888a0", "Pink"},
		{"#e8955a", "Orange"}, {"#e8d05a", "Yellow"}, {"#8e6be6", "Violet"}, {"#e8e9f0", "White"},
		{"#f4d060", "Golden"}, {"#f0ede0", "Colorless"},
	},
}

// stoneNames tracks insertion order for deterministic listing (Go/Gno
// map iteration order is randomized) -- kept in sync with stonePalettes
// by registerStoneName, called from both AddStoneColor and
// SetStoneForChain (nftminter.gno).
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

type metalTone struct{ hi, lo string }

var metals = map[string]metalTone{
	"Gold":     {"#f4d060", "#8a6a1f"},
	"Silver":   {"#dfe4ea", "#7a828c"},
	"Bronze":   {"#c9884f", "#6b4a26"},
	"Platinum": {"#eef2f5", "#9aa4b0"},
	"Obsidian": {"#3a3d47", "#0d0e12"},
}

// metalNames is an ordered counterpart to metals -- Go/Gno map iteration
// order is randomized, so on-the-fly random trait assembly (MintAssembled,
// nftminter.gno) needs an indexable slice to pick a random metal from.
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
	gemEls := renderGem(shapeIdx, colorHex)
	glint := renderGlint(shapeIdx, colorHex, tidStr)
	floatingGem := applyMotion(gemEls+glint, tidStr)
	status := renderStatusBadge(active)
	serial := renderSerialText(tidStr, mt.hi)
	labelText := metalLabel[metal].text
	labelRect := renderMetalLabelRect(mt.hi, mt.lo, 24, 134, 122, 15, 3, tidStr)

	inner := `<rect width="` + fnum(canvasW) + `" height="` + fnum(canvasH) + `" fill="#0a0b10"/>` +
		ringEls + floatingGem + status + serial + labelRect +
		`<text x="` + fnum(subjX) + `" y="144.5" font-size="9.5" text-anchor="middle" fill="` + labelText + `" font-family="ui-monospace,monospace" font-weight="700">` + chain + `</text>`

	svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ` + fnum(canvasW) + ` ` + fnum(canvasH) + `">` + styleBlock() + inner + `</svg>`
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
		`.gt-glint-rot{animation:gt-kf-glint-rot var(--glint-dur) linear infinite;animation-delay:var(--glint-delay);transform-box:view-box;transform-origin:` + px + ` ` + py + `}` +
		`.gt-glint-op{animation:gt-kf-glint-op var(--glint-dur) linear infinite;animation-delay:var(--glint-delay)}` +
		`.gt-badge-pulse{animation:gt-kf-badge-pulse 1.8s ` + easeOut + ` infinite}` +
		`@keyframes gt-kf-v{0%,100%{transform:translate(0,0)}50%{transform:translate(0,-5px)}}` +
		`@keyframes gt-kf-h{0%,100%{transform:translate(0,0)}50%{transform:translate(1.8px,0)}}` +
		`@keyframes gt-kf-r{0%,100%{transform:rotate(0deg)}25%{transform:rotate(calc(-1 * var(--rot-deg)))}50%{transform:rotate(0deg)}75%{transform:rotate(var(--rot-deg))}}` +
		`@keyframes gt-kf-s{0%,100%{transform:scale(1)}50%{transform:scale(` + fnum(motionScale) + `)}}` +
		`@keyframes gt-kf-glow{0%,100%{opacity:0}50%{opacity:1}}` +
		`@keyframes gt-kf-glint-rot{from{transform:rotate(var(--from-a))}to{transform:rotate(var(--to-a))}}` +
		`@keyframes gt-kf-glint-op{0%,35%,65%,100%{opacity:0}50%{opacity:.7}}` +
		`@keyframes gt-kf-badge-pulse{from{r:1;opacity:.8}to{r:9;opacity:0}}` +
		`</style>`
}
