package gemsart2trimmedfast1789459000

import (
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
	seed   string
	n      int
	state  uint64
	seeded bool
}

func newPRNG(seed string) *prng { return &prng{seed: seed} }

func fnv1a64(data []byte) uint64 {
	var h uint64 = 14695981039346656037
	for _, b := range data {
		h ^= uint64(b)
		h *= 1099511628211
	}
	return h
}

func (p *prng) next() uint64 {
	p.n++
	if !p.seeded {
		p.state = fnv1a64([]byte(p.seed))
		p.seeded = true
	}
	z := p.state + uint64(p.n)*0x9E3779B97F4A7C15
	z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9
	z = (z ^ (z >> 27)) * 0x94D049BB133111EB
	return z ^ (z >> 31)
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

const facetOp = 0.55
const facetOpCenter = 0.5

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

func roseOutline(r float64) []pt {
	n := 6
	pts := make([]pt, n)
	for k := 0; k < n; k++ {
		a := 2*math.Pi*float64(k)/float64(n) - math.Pi/2
		pts[k] = pt{subjX + r*math.Cos(a), subjY + r*math.Sin(a)}
	}
	return pts
}

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

var ShapeNames = []string{
	"Round Brilliant", "Emerald Cut", "Princess Cut", "Raw Crystal", "Pear", "Heart",
	"Trillion", "Oval", "Asscher", "Radiant", "Rose Cut",
}

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

func renderRing(metalHi, metalLo, salt string) string {
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

const (
	motionVDur, motionHDur, motionRDur, motionSDur = 3.4, 4.66, 5.81, 6.56
	motionRotMin, motionRotMax                     = 4.0, 8.0
	motionScale                                    = 1.09
)

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
	fill       string
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
		fill := attrValue(tag, `fill="`)
		if fill == "" {
			continue
		}
		spans = append(spans, facetSpan{start: start, end: end, fill: fill, ringMember: strings.Contains(tag, `opacity="0.55"`)})
	}
	return spans
}

func attrValue(tag, marker string) string {
	idx := strings.Index(tag, marker)
	if idx < 0 {
		return ""
	}
	rest := tag[idx+len(marker):]
	endIdx := strings.Index(rest, `"`)
	if endIdx < 0 {
		return ""
	}
	return rest[:endIdx]
}

func facetRings(spans []facetSpan) [][]int {
	var members []int
	for i, s := range spans {
		if s.ringMember {
			members = append(members, i)
		}
	}
	if len(members) == 20 {
		return [][]int{members[0:10], members[10:20]}
	}
	return [][]int{members}
}

const (
	cascadeEventCount     = 8
	cascadeCoverage       = 0.40
	cascadeFacetDurMin    = 0.7
	cascadeFacetDurMax    = 1.1
	cascadeStaggerMin     = 0.15
	cascadeStaggerMax     = 0.30
	cascadePauseMin       = 3.0
	cascadePauseMax       = 5.0
	cascadePeakLightenMin = 0.55
	cascadePeakLightenMax = 0.9
)

type cascadeEvent struct {
	phase    float64
	dir      float64
	facetDur float64
	stagger  float64
}

func buildCascadeSchedule(rnd *prng, refRingSize int) (events []cascadeEvent, starts []float64, period float64) {
	groupN := int(float64(refRingSize)*cascadeCoverage + 0.5)
	if groupN < 1 {
		groupN = 1
	}
	events = make([]cascadeEvent, cascadeEventCount)
	starts = make([]float64, cascadeEventCount)
	t := rnd.floatIn(cascadePauseMin, cascadePauseMax)
	for i := 0; i < cascadeEventCount; i++ {
		dir := 1.0
		if rnd.floatIn(0, 1) < 0.5 {
			dir = -1.0
		}
		facetDur := rnd.floatIn(cascadeFacetDurMin, cascadeFacetDurMax)
		stagger := rnd.floatIn(cascadeStaggerMin, cascadeStaggerMax)
		events[i] = cascadeEvent{phase: rnd.floatIn(0, 1), dir: dir, facetDur: facetDur, stagger: stagger}
		starts[i] = t
		eventTotal := float64(groupN-1)*stagger + facetDur
		t += eventTotal + rnd.floatIn(cascadePauseMin, cascadePauseMax)
	}
	period = t
	return events, starts, period
}

func wrapInt(a, n int) int {
	r := a % n
	if r < 0 {
		r += n
	}
	return r
}

type facetHit struct {
	enter, mid1, peak, mid2, exit float64
}

type cascadeStop struct {
	pct float64
	val string
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

func applyCascade(markup, tidStr string) (string, string) {
	spans := scanFacetSpans(markup)
	rings := facetRings(spans)
	if len(rings) == 0 || len(rings[0]) == 0 {
		return markup, ""
	}

	rnd := newPRNG("cascade" + tidStr)
	events, starts, period := buildCascadeSchedule(rnd, len(rings[0]))

	hits := make([][]facetHit, len(spans))
	for _, ring := range rings {
		m := len(ring)
		if m == 0 {
			continue
		}
		groupN := int(float64(m)*cascadeCoverage + 0.5)
		if groupN < 1 {
			groupN = 1
		}
		for ei, ev := range events {
			startIdx := wrapInt(int(ev.phase*float64(m)+0.5), m)
			localStart := starts[ei]
			for step := 0; step < groupN; step++ {
				ridx := wrapInt(startIdx+int(float64(step)*ev.dir), m)
				spanIdx := ring[ridx]
				enter := localStart
				exit := enter + ev.facetDur
				peak := (enter + exit) / 2
				mid1 := enter + (peak-enter)*0.5
				mid2 := peak + (exit-peak)*0.5
				hits[spanIdx] = append(hits[spanIdx], facetHit{enter: enter, mid1: mid1, peak: peak, mid2: mid2, exit: exit})
				localStart += ev.stagger
			}
		}
	}

	var keyframes strings.Builder
	var out strings.Builder
	cursor := 0
	for i, span := range spans {
		windows := hits[i]
		if len(windows) == 0 {
			continue
		}
		out.WriteString(markup[cursor:span.start])

		peakAmt := rnd.floatIn(cascadePeakLightenMin, cascadePeakLightenMax)
		lit := lighten(span.fill, peakAmt)
		mi := mixHex(span.fill, lit, 0.5)

		stops := []cascadeStop{{0, span.fill}, {100, span.fill}}
		for _, w := range windows {
			stops = append(stops,
				cascadeStop{modPct(w.enter / period), span.fill},
				cascadeStop{modPct(w.mid1 / period), mi},
				cascadeStop{modPct(w.peak / period), lit},
				cascadeStop{modPct(w.mid2 / period), mi},
				cascadeStop{modPct(w.exit / period), span.fill},
			)
		}
		sortCascadeStops(stops)

		kfName := ufmt.Sprintf("fc%s_%d", tidStr, i)
		keyframes.WriteString("@keyframes " + kfName + "{")
		for _, s := range stops {
			keyframes.WriteString(fnum(s.pct) + `%{fill:` + s.val + `}`)
		}
		keyframes.WriteString("}")

		tag := markup[span.start:span.end]
		out.WriteString(tag[:len(tag)-2] + ` style="animation:` + kfName + ` ` + fnum(period) + `s ease-in-out infinite"/>`)
		cursor = span.end
	}
	out.WriteString(markup[cursor:])

	return out.String(), keyframes.String()
}

func renderMetalLabelRect(metalHi, metalLo string, x, y, w, h, rx float64, salt string) string {
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
		{"#ffd100", "Golden"}, {"#f5edd1", "Colorless"},
	},
	"Pearl": {
		{"#f8f6f0", "White"}, {"#f0e4c8", "Cream"}, {"#3a3a3c", "Black"}, {"#c8cdd4", "Silver"},
		{"#d4af6a", "Gold"}, {"#f0d4dc", "Pink"}, {"#f2c9a8", "Peach"}, {"#d8cbe0", "Lavender"},
	},
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
	stone = StoneForChain(chain)
	nc := colorForStone(stone, colorIdx)
	colorHex, colorName = nc.hex, nc.name
	mt := metals[metal]

	ringEls := renderRing(mt.hi, mt.lo, tidStr)
	rawGem := renderGem(shapeIdx, colorHex)
	gemMarkup, cascadeCSS := applyCascade(rawGem, tidStr)
	floatingGem := applyMotion(gemMarkup, tidStr)
	status := renderStatusBadge(active)
	serial := renderSerialText(tidStr, mt.hi)
	labelText := metalLabel[metal].text
	labelRect := renderMetalLabelRect(mt.hi, mt.lo, 24, 134, 122, 15, 3, tidStr)

	inner := `<rect width="` + fnum(canvasW) + `" height="` + fnum(canvasH) + `" fill="#0a0b10"/>` +
		ringEls + floatingGem + status + serial + labelRect +
		`<text x="` + fnum(subjX) + `" y="144.5" font-size="9.5" text-anchor="middle" fill="` + labelText + `" font-family="ui-monospace,monospace" font-weight="700">` + chain + ` CHAIN</text>`

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
