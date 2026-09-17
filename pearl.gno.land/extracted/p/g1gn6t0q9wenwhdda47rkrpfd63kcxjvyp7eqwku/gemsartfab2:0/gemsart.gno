package gemsartfab2
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
func cnum(v float64) string {
	s := fnum(v)
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
	s := ufmt.Sprintf("%d.%d", scaled/10, scaled%10)
	if neg {
		return "-" + s
	}
	return s
}
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
func lighten(hex string, amt float64) string {
	r, g, b := hexToRGB(hex)
	nr := clampByte(float64(r) + (255-float64(r))*amt)
	ng := clampByte(float64(g) + (255-float64(g))*amt)
	nb := clampByte(float64(b) + (255-float64(b))*amt)
	return rgbToHex(nr, ng, nb)
}
func mixHex(hex, target string, amt float64) string {
	r1, g1, b1 := hexToRGB(hex)
	r2, g2, b2 := hexToRGB(target)
	nr := clampByte(float64(r1) + float64(r2-r1)*amt)
	ng := clampByte(float64(g1) + float64(g2-g1)*amt)
	nb := clampByte(float64(b1) + float64(b2-b1)*amt)
	return rgbToHex(nr, ng, nb)
}
func hueRotate(hex string, deg float64) string {
	c, sn := math.Cos(deg*math.Pi/180), math.Sin(deg*math.Pi/180)
	r, g, b := hexToRGB(hex)
	fr, fg, fb := float64(r), float64(g), float64(b)
	nr := (0.213+c*0.787-sn*0.213)*fr + (0.715-c*0.715-sn*0.715)*fg + (0.072-c*0.072+sn*0.928)*fb
	ng := (0.213-c*0.213+sn*0.143)*fr + (0.715+c*0.285+sn*0.140)*fg + (0.072-c*0.072-sn*0.283)*fb
	nb := (0.213-c*0.213-sn*0.787)*fr + (0.715-c*0.715+sn*0.715)*fg + (0.072+c*0.928+sn*0.072)*fb
	return rgbToHex(clampByte(nr), clampByte(ng), clampByte(nb))
}
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
type facetStyle struct {
	dir      [4]gramp // lit from top-left / top-right / from below / deep interior
	flash    gramp
	table    string // the one static center element (table/backing)
	ringCent []pt
	prof     fireProfile
	zone     *prng // per-facet hue drift, seeded per token
}
type fireProfile struct {
	sat, hit  float64
	pinpoints int
	shadow    string
	bodyMix float64
	neutral string
}
func fireProfileFor(stone, colorName string) fireProfile {
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
var facetOps = []string{"0.5", "0.82", "0.4", "0.7"}
func (fs *facetStyle) path(k int, poly []pt) string {
	cx, cy := centroid(poly)
	c, _ := fs.dir[k%4].sample(cx, cy)
	if fs.zone != nil {
		c = hueRotate(c, fs.zone.floatIn(-fireZoneDeg, fireZoneDeg))
	}
	fs.ringCent = append(fs.ringCent, pt{cx, cy})
	return `<path d="` + polyPath(poly) + `" fill="` + c + `" fill-opacity="` + facetOps[(k*3+1)%4] + `" class="f"/>`
}
func (fs *facetStyle) lit(poly []pt) string {
	cx, cy := centroid(poly)
	fs.ringCent = append(fs.ringCent, pt{cx, cy})
	return `<path d="` + polyPath(poly) + `" fill="url(#` + fs.table + `)" fill-opacity="0.85" class="f"/>`
}
func (fs *facetStyle) center() string {
	return `" fill="url(#` + fs.table + `)"/>`
}
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
func gemFacetDefs(base, salt string, fs *facetStyle) string {
	const ext = 25.0
	sh := fs.prof.shadow
	if fs.prof.neutral != "" {
		base = fs.prof.neutral
	}
	base = mixHex(base, sh, fs.prof.bodyMix)
	dk := func(amt float64) string { return darken(base, sh, amt) }
	fs.table = "fT" + salt
	fs.dir[0] = gramp{subjX - ext, subjY - ext, subjX + ext, subjY + ext,
		[]gstop{{0, lighten(base, 0.92), 1}, {25, lighten(base, 0.45), 1}, {55, base, 1}, {100, dk(0.75), 1}}}
	fs.dir[1] = gramp{subjX + ext, subjY - ext, subjX - ext, subjY + ext,
		[]gstop{{0, lighten(base, 0.35), 1}, {45, dk(0.25), 1}, {100, dk(0.8), 1}}}
	fs.dir[2] = gramp{subjX, subjY + ext, subjX, subjY - ext,
		[]gstop{{0, lighten(base, 0.15), 1}, {50, dk(0.45), 1}, {100, dk(0.85), 1}}}
	fs.dir[3] = gramp{subjX + ext, subjY + ext, subjX - ext, subjY - ext,
		[]gstop{{0, dk(0.25), 1}, {50, dk(0.6), 1}, {100, dk(0.9), 1}}}
	fs.flash = flashRamp(ext, fs.prof.sat)
	st := func(pct float64, color string) string {
		return `<stop offset="` + fnum(pct) + `%" stop-color="` + color + `"/>`
	}
	return `<defs>` +
		`<radialGradient id="` + fs.table + `" cx="42%" cy="38%" r="78%">` +
		st(0, lighten(base, 0.36)) + st(25, lighten(base, 0.24)) + st(50, lighten(base, 0.11)) + st(75, base) + st(100, dk(0.14)) + `</radialGradient>` +
		`<radialGradient id="bd` + salt + `" cx="40%" cy="35%" r="72%">` +
		st(0, lighten(base, 0.55)) + st(40, lighten(base, 0.12)) + st(78, dk(0.2)) + st(100, dk(0.7)) + `</radialGradient>` +
		`</defs>`
}
func renderGemRim(outline []pt, base string) string {
	return `<path d="` + polyPath(outline) + `" fill="none" stroke="` + lighten(base, 0.5) + `" stroke-opacity="0.35" stroke-width="0.6" stroke-linejoin="round"/>`
}
func renderGemBody(outline []pt, salt string) string {
	return `<path d="` + polyPath(outline) + `" fill="url(#bd` + salt + `)"/>`
}
const (
	roundSpiralN     = 10
	roundSpiralTwist = 0.35
)
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
func ovalOutline(rx, ry float64) []pt {
	n := 10
	angles := ellipseArcAngles(rx, ry, n)
	pts := make([]pt, n)
	for k, a := range angles {
		pts[k] = pt{subjX + rx*math.Cos(a), subjY + ry*math.Sin(a)}
	}
	return pts
}
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
func roseOutline(r float64) []pt {
	n := 6
	pts := make([]pt, n)
	for k := 0; k < n; k++ {
		a := 2*math.Pi*float64(k)/float64(n) - math.Pi/2
		pts[k] = pt{subjX + r*math.Cos(a), subjY + r*math.Sin(a)}
	}
	return pts
}
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
var ShapeNames = []string{
	"Round Brilliant", "Emerald Cut", "Princess Cut", "Raw Crystal", "Pear", "Heart",
	"Trillion", "Oval", "Asscher", "Radiant", "Rose Cut",
}
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
func pearlLusterGradient(gid, base string) string {
	return `<radialGradient id="` + gid + `" cx="36%" cy="30%" r="78%">` +
		`<stop offset="0%" stop-color="` + lighten(base, 0.9) + `"/>` +
		`<stop offset="9%" stop-color="` + lighten(base, 0.55) + `"/>` +
		`<stop offset="30%" stop-color="` + lighten(base, 0.12) + `"/>` +
		`<stop offset="62%" stop-color="` + base + `"/>` +
		`<stop offset="88%" stop-color="` + mixHex(base, "#000000", 0.3) + `"/>` +
		`<stop offset="100%" stop-color="` + mixHex(base, "#000000", 0.14) + `"/></radialGradient>` +
		`<radialGradient id="` + gid + `o" cx="42%" cy="40%" r="72%">` +
		`<stop offset="0%" stop-color="#ffffff" stop-opacity="0"/>` +
		`<stop offset="45%" stop-color="#ffb8d0" stop-opacity="0.22"/>` +
		`<stop offset="78%" stop-color="#b8ffd8" stop-opacity="0.18"/>` +
		`<stop offset="100%" stop-color="#c8d8ff" stop-opacity="0.1"/></radialGradient>`
}
func pearlOvertone(shape, gid string) string {
	i := strings.Index(shape, ` fill="`)
	if i < 0 {
		return ""
	}
	return shape[:i] + ` fill="url(#` + gid + `o)"/>`
}
func pearlSweepColorIntensity(base string) float64 {
	r, g, b := hexToRGB(base)
	lum := 0.2126*float64(r)/255 + 0.7152*float64(g)/255 + 0.0722*float64(b)/255
	if lum < 0.4 {
		return 1.2
	}
	return 2.0
}
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
func pearlButton(base, salt string) string {
	gid := "prl" + salt
	rx, ry := 25.0, 18.0
	body := `<ellipse cx="` + fnum(subjX) + `" cy="` + fnum(subjY) + `" rx="` + fnum(rx) + `" ry="` + fnum(ry) + `" fill="url(#` + gid + `)"/>`
	clipGeom := `<ellipse cx="` + fnum(subjX) + `" cy="` + fnum(subjY) + `" rx="` + fnum(rx) + `" ry="` + fnum(ry) + `"/>`
	sweep := pearlSweepOverlay(salt, base, clipGeom, rx*2, ry*2)
	return `<defs>` + pearlLusterGradient(gid, base) + `</defs>` + body + pearlOvertone(body, gid) + sweep
}
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
var PearlShapeNames = []string{"Round", "Oval", "Button", "Drop", "Baroque", "Circled"}
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
func renderRing(metalHi, metalLo, salt string) string {
	gid := "ring" + salt
	bright := lighten(metalHi, 0.45)
	deep := mixHex(metalLo, "#000000", 0.45)
	st := func(off, c string) string { return `<stop offset="` + off + `" stop-color="` + c + `"/>` }
	defs := `<linearGradient id="` + gid + `" x2="1" y2="1">` +
		st("0", bright) + st(".12", metalHi) + st(".26", deep) + st(".4", metalLo) + st(".52", bright) +
		st(".64", metalHi) + st(".78", deep) + st(".9", metalLo) + st("1", bright) + `</linearGradient>`
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
const (
	motionVDur, motionHDur, motionRDur, motionSDur = 3.4, 4.66, 5.81, 6.56
	motionRotMin, motionRotMax                     = 4.0, 8.0
	motionScale                                    = 1.09
)
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
const dotX, dotY = subjX + 50, subjY + 42
func renderStatusBadge(active bool) string {
	if active {
		return `<circle cx="` + fnum(dotX) + `" cy="` + fnum(dotY) + `" r="4" fill="#7fd88f"/>` +
			`<circle cx="` + fnum(dotX) + `" cy="` + fnum(dotY) + `" r="4" fill="none" stroke="#7fd88f" stroke-width="1.2" class="gt-badge-pulse" opacity="0.8"/>`
	}
	return `<circle cx="` + fnum(dotX) + `" cy="` + fnum(dotY) + `" r="4" fill="#5a5f6b"/>`
}
type facetSpan struct {
	start, end int
	ringMember bool
}
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
	fireFacetDurMin, fireFacetDurMax = 0.55, 0.85 // one facet's own flash, seconds
	fireStaggerMin, fireStaggerMax   = 0.1, 0.16  // between consecutive facets of a sweep
	fireSweepsPerPeriod              = 4          // one per mid-swing over two rock cycles
	fireSweepSkipChance              = 0.25       // ...but not every swing fires
	fireSweepAxis                    = -35.0 * math.Pi / 180
	fireSweepJitter                  = 0.3
	firePinpointDur                  = 0.45
	firePeakOpMin, firePeakOpMax     = 0.5, 0.85
)
type facetHit struct {
	enter, peak, mid, exit, peakOp float64
}
func mkHit(enter, dur, peakOp float64) facetHit {
	return facetHit{enter, enter + dur*0.3, enter + dur*0.6, enter + dur, peakOp}
}
func buildFireHits(rnd *prng, cent []pt, prof fireProfile) (hits [][]facetHit, period float64) {
	n := len(cent)
	hits = make([][]facetHit, n)
	period = 2 * motionRDur
	proj := make([]float64, n)
	order := make([]int, n)
	axis := fireSweepAxis + rnd.floatIn(-fireSweepJitter, fireSweepJitter)
	for e := 0; e < fireSweepsPerPeriod; e++ {
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
type cascadeStop struct {
	pct  float64
	body string
}
func sortCascadeStops(s []cascadeStop) {
	for i := 1; i < len(s); i++ {
		for j := i; j > 0 && s[j].pct < s[j-1].pct; j-- {
			s[j], s[j-1] = s[j-1], s[j]
		}
	}
}
func modPct(frac float64) float64 {
	for frac < 0 {
		frac += 1
	}
	for frac >= 1 {
		frac -= 1
	}
	return frac * 100
}
func applyCascade(markup, tidStr string, fs *facetStyle) (overlay string, css string) {
	spans := scanFacetSpans(markup)
	if fs == nil || len(fs.ringCent) == 0 {
		return "", ""
	}
	rnd := newPRNG("fire" + tidStr)
	hits, period := buildFireHits(rnd, fs.ringCent, fs.prof)
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
		tag := markup[span.start:span.end]
		geomEnd := strings.Index(tag, `" fill=`)
		if geomEnd < 0 {
			continue
		}
		out.WriteString(tag[:geomEnd] + `" fill="#fff" opacity="0" style="animation:` + kfName + ` ` + fnum(period) + `s linear infinite;animation-delay:-` + fnum(fireDelay) + `s"/>`)
	}
	return out.String(), keyframes.String()
}
func renderMetalLabelRect(metalHi, metalLo string, x, y, w, h, rx float64, salt string) string {
	gid := "lg" + salt
	bright := lighten(metalHi, 0.4)
	deep := mixHex(metalLo, "#000000", 0.5)
	st := func(off, c string) string { return `<stop offset="` + off + `" stop-color="` + c + `"/>` }
	defs := `<linearGradient id="` + gid + `">` +
		st("0", metalLo) + st(".22", metalHi) + st(".42", bright) + st(".62", metalHi) + st("1", metalLo) + `</linearGradient>`
	rect := `<rect x="` + cnum(x) + `" y="` + cnum(y) + `" width="` + cnum(w) + `" height="` + cnum(h) + `" rx="` + cnum(rx) + `" fill="url(#` + gid + `)" stroke="` + deep + `" stroke-width=".8"/>`
	const in_ = 0.9
	arc := ` a` + cnum(rx-in_) + ` ` + cnum(rx-in_) + ` 0 0 `
	d := cnum(rx - in_)
	edges := `<g fill="none" stroke-linecap="round">` +
		`<path d="M` + cnum(x+in_) + ` ` + cnum(y+rx) + arc + `1 ` + d + ` -` + d + `H` + cnum(x+w-rx) + arc + `1 ` + d + ` ` + d + `" stroke="` + lighten(metalHi, 0.45) + `" stroke-width=".45" opacity=".4"/>` +
		`<path d="M` + cnum(x+in_) + ` ` + cnum(y+h-rx) + arc + `0 ` + d + ` ` + d + `H` + cnum(x+w-rx) + arc + `0 ` + d + ` -` + d + `" stroke="` + deep + `" stroke-width=".5" opacity=".5"/></g>`
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
const (
	plateFont    = `'DIN Alternate',Bahnschrift,'Roboto Condensed',sans-serif`
	plateSize    = 8.6
	plateSpacing = 1.1
	plateMaxW    = 100.0
)
func renderPlateText(label, fill, metalHi string) string {
	g := `<g font-size="` + cnum(plateSize) + `" letter-spacing="` + cnum(plateSpacing) + `" text-anchor="middle" font-family="` + plateFont + `" font-weight="700"`
	if est := float64(len(label))*(plateSize*0.52+plateSpacing); est > plateMaxW {
		g += ` textLength="` + cnum(plateMaxW) + `" lengthAdjust="spacingAndGlyphs"`
	}
	x := cnum(subjX)
	return g + `><text x="` + x + `" y="144.9" fill="` + lighten(metalHi, 0.5) + `" opacity=".45">` + label + `</text>` +
		`<text x="` + x + `" y="144.4" fill="` + fill + `">` + label + `</text></g>`
}
func renderSerialText(tidStr, color string) string {
	return `<text x="` + fnum(subjX) + `" y="159.5" font-size="6.5" text-anchor="middle" fill="` + color + `" font-family="ui-monospace,monospace" opacity="0.85">#` + tidStr + `</text>`
}
type namedColor struct{ hex, name string }
var stoneByChain = map[string]string{
	"TOPAZ-1":    "Topaz",
	"SAPPHIRE-1": "Sapphire",
	"PEARL-1":    "Pearl",
}
var stonePalettes = map[string][]namedColor{
	"Sapphire": {
		{"#00b6ff", "Blue"}, {"#ff6ea4", "Pink"}, {"#ff8501", "Orange"}, {"#ffd500", "Yellow"},
		{"#02d66e", "Green"}, {"#a658ff", "Violet"}, {"#e6e9f8", "White"}, {"#ff732f", "Padparadscha"},
	},
	"Topaz": {
		{"#f5edd1", "Colorless"}, {"#ffa300", "Imperial"}, {"#ffd100", "Golden"},
		{"#ff6900", "Sherry Brown"}, {"#33b2ff", "Sky Blue"}, {"#ff96ba", "Pink"},
	},
	"Not Set": {
		{"#f45656", "Red"}, {"#00b6ff", "Blue"}, {"#02d66e", "Green"}, {"#ff6ea4", "Pink"},
		{"#ff8501", "Orange"}, {"#ffd500", "Yellow"}, {"#a658ff", "Violet"}, {"#e6e9f8", "White"},
		{"#ffd100", "Golden"}, {"#f5edd1", "Colorless"}, {"#dfe7f2", "Crystal"},
	},
	"Pearl": {
		{"#f8f6f0", "White"}, {"#f0e4c8", "Cream"}, {"#3a3a3c", "Black"}, {"#c8cdd4", "Silver"},
		{"#d4af6a", "Gold"}, {"#f0d4dc", "Pink"}, {"#f2c9a8", "Peach"}, {"#d8cbe0", "Lavender"},
	},
}
var stoneNames = []string{"Sapphire", "Topaz", "Pearl", "Not Set"}
func registerStoneName(stone string) {
	for _, s := range stoneNames {
		if s == stone {
			return
		}
	}
	stoneNames = append(stoneNames, stone)
}
func SetStoneForChain(chainName, stone string) {
	stoneByChain[chainName] = stone
	registerStoneName(stone)
}
func AddStoneColor(stone, hex, name string) {
	stonePalettes[stone] = append(stonePalettes[stone], namedColor{hex: hex, name: name})
	registerStoneName(stone)
}
func StoneNamesCSV() string {
	return strings.Join(stoneNames, ";")
}
func ColorPaletteCSV(stone string) string {
	palette := stonePalettes[stone]
	pairs := make([]string, len(palette))
	for i, c := range palette {
		pairs[i] = c.hex + ":" + c.name
	}
	return strings.Join(pairs, ";")
}
func MetalToneHex(metalName string) string {
	t, ok := metals[metalName]
	if !ok {
		return ""
	}
	return t.hi + ";" + t.lo
}
func StoneForChain(chain string) string {
	if s, ok := stoneByChain[chain]; ok {
		return s
	}
	return "Not Set"
}
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
func ColorPaletteSize(stone string) int {
	if n := len(stonePalettes[stone]); n > 0 {
		return n
	}
	return len(stonePalettes["Not Set"])
}
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
var metals = map[string]metalTone{
	"Gold":     {"#a48b3f", "#6a5117"},
	"Silver":   {"#95989c", "#5e646c"},
	"Bronze":   {"#865b34", "#52391d"},
	"Platinum": {"#c3c6c8", "#87909a"},
	"Obsidian": {"#3a3d47", "#0d0e12"},
}
var MetalNames = []string{"Gold", "Silver", "Bronze", "Platinum", "Obsidian"}
type metalLabelTone struct{ bg, text string }
var metalLabel = map[string]metalLabelTone{
	"Gold":     {"#f4d060", "#04121a"},
	"Silver":   {"#dfe4ea", "#04121a"},
	"Bronze":   {"#c9884f", "#04121a"},
	"Platinum": {"#eef2f5", "#04121a"},
	"Obsidian": {"#5a5f6b", "#e8e9f0"},
}
func RenderTokenSVG(chain, metal string, shapeIdx, colorIdx int, active bool, tidStr string) (svg string, stone string, colorHex string, colorName string) {
	var cascadeCSS string
	stone = StoneForChain(chain)
	nc := colorForStone(stone, colorIdx)
	colorHex, colorName = nc.hex, nc.name
	mt := metals[metal]
	ringEls := renderRing(mt.hi, mt.lo, tidStr)
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
		renderPlateText(chain+" CHAIN", labelText, mt.hi)
	svg = `<svg xmlns="http://www.w3.org/2000/svg" width="` + fnum(canvasW) + `" height="` + fnum(canvasH) + `" viewBox="0 0 ` + fnum(canvasW) + ` ` + fnum(canvasH) + `">` + styleBlock() +
		`<style>` + cascadeCSS + `</style>` + inner + `</svg>`
	return svg, stone, colorHex, colorName
}
func styleBlock() string {
	const easeInOut = "cubic-bezier(.45,0,.55,1)"
	const easeOut = "cubic-bezier(0,0,.3,1)"
	px, py := fnum(subjX)+"px", fnum(subjY)+"px"
	dpx, dpy := fnum(dotX)+"px", fnum(dotY)+"px"
	return `<style>` +
		`.gt-v{will-change:transform;animation:gt-kf-v var(--v-dur) ` + easeInOut + ` infinite;animation-delay:var(--v-delay)}` +
		`.gt-h{will-change:transform;animation:gt-kf-h var(--h-dur) ` + easeInOut + ` infinite;animation-delay:var(--h-delay)}` +
		`.gt-r{will-change:transform;animation:gt-kf-r var(--r-dur) ` + easeInOut + ` infinite;animation-delay:var(--r-delay);transform-box:view-box;transform-origin:` + px + ` ` + py + `}` +
		`.gt-s{will-change:transform;animation:gt-kf-s var(--s-dur) ` + easeInOut + ` infinite;animation-delay:var(--s-delay);transform-box:view-box;transform-origin:` + px + ` ` + py + `}` +
		`.gt-glow{animation:gt-kf-glow var(--glow-dur) ` + easeInOut + ` infinite;animation-delay:var(--glow-delay)}` +
		`.gt-badge-pulse{transform-box:view-box;transform-origin:` + dpx + ` ` + dpy + `;animation:gt-kf-badge-pulse 1.8s ` + easeOut + ` infinite}` +
		`@keyframes gt-kf-v{0%,100%{transform:translate(0,0)}50%{transform:translate(0,-5px)}}` +
		`@keyframes gt-kf-h{0%,100%{transform:translate(0,0)}50%{transform:translate(1.8px,0)}}` +
		`@keyframes gt-kf-r{0%,100%{transform:rotate(0deg)}25%{transform:rotate(calc(-1 * var(--rot-deg)))}50%{transform:rotate(0deg)}75%{transform:rotate(var(--rot-deg))}}` +
		`@keyframes gt-kf-s{0%,100%{transform:scale(1)}50%{transform:scale(` + fnum(motionScale) + `)}}` +
		`@keyframes gt-kf-glow{0%,100%{opacity:0}50%{opacity:1}}` +
		`@keyframes gt-kf-badge-pulse{from{transform:scale(1);opacity:.8}to{transform:scale(2.25);opacity:0}}` +
		`</style>`
}
