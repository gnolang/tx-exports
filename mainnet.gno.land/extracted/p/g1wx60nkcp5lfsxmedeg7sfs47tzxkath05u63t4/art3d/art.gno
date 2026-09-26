package art3d

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
	flash    gramp
	ringCent []pt
	prof     fireProfile
	zone     *prng // per-facet hue drift and shade jitter, seeded per token
	stone    string // which crystal habit a Raw Crystal takes
	thumb bool
}

type fireProfile struct {
	sat, hit  float64
	pinpoints int
	shadow    string
	bodyMix   float64
	neutral   string
}

func fireProfileFor(stone, colorName string) fireProfile {
	if stone == "Diamond" {
		switch colorName {
		case "Colorless":
			return fireProfile{1.0, 0.85, 5, "#0d1222", 0.12, "#f4f7fc"}
		case "Black":
			return fireProfile{0.15, 0.35, 1, "#000000", 0, ""}
		}
		return fireProfile{0.95, 0.7, 4, "#0b0d18", 0, ""}
	}
	if stone == "Quartz" {
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

type outlineFn func(t float64) (float64, float64)

func circleOutline(t float64) (float64, float64) {
	a := 2 * math.Pi * t
	return math.Cos(a), math.Sin(a)
}

func superOutline(p float64) outlineFn {
	return func(t float64) (float64, float64) {
		a := 2 * math.Pi * t
		return sgnPow(math.Cos(a), 2/p), sgnPow(math.Sin(a), 2/p)
	}
}

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

type cutSpec struct {
	n         int
	brilliant bool
	outline   outlineFn
	rx, ry    float64
}

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

const stoneScale = 0.78

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
		return cutSpec{8, false, polyOutline(octagon(1, 1, 0.3)), 30, 21}
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
			faces = append(faces, face{[]v3{T[k], B[k], T[k1]}, kCrown})
			faces = append(faces, face{[]v3{T[k1], B[k], G[(2*k+2)%(2*n)], B[k1]}, kCrown})
			faces = append(faces, face{[]v3{B[k], G[2*k], G[2*k+1]}, kCrown})
			faces = append(faces, face{[]v3{B[k], G[2*k+1], G[(2*k+2)%(2*n)]}, kCrown})
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

func ringX(n int, x, ry, rz, phase float64) []v3 {
	out := make([]v3, n)
	for k := 0; k < n; k++ {
		a := 2*math.Pi*(float64(k)+phase)/float64(n) + math.Pi/2
		out[k] = v3{x, ry * math.Cos(a), rz * math.Sin(a)}
	}
	return out
}

func bandX(a, b []v3) []face {
	var fs []face
	for k := range a {
		k1 := (k + 1) % len(a)
		fs = append(fs, face{[]v3{a[k], a[k1], b[k1], b[k]}, kCrown})
	}
	return fs
}

func capX(r []v3) face { return face{r, kCrown} }

func turnFaces(fs []face, ax, az float64) []face {
	cx, sx, cz, sz := math.Cos(ax), math.Sin(ax), math.Cos(az), math.Sin(az)
	for i := range fs {
		fs[i].kind = kPav
		for j, p := range fs[i].p {
			y, z := p.y*cx-p.z*sx, p.y*sx+p.z*cx
			fs[i].p[j] = v3{p.x*cz - y*sz, p.x*sz + y*cz, z}
		}
	}
	return fs
}

func buildRaw(stone string) (faces []face, girdle []v3) {
	deg := math.Pi / 180
	switch stone {
	case "Diamond":
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

const viewTilt = 61.0

const (
	pieceCY   = subjY + 1.5
)

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

func clipToConvex(ps, win []pt) []pt {
	for i := range win {
		a, b := win[i], win[(i+1)%len(win)]
		nx, ny := b.y-a.y, a.x-b.x
		mid := pt{(a.x + b.x) / 2, (a.y + b.y) / 2}
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

func splitPoly(ps []pt, ang float64) ([]pt, []pt) {
	cx, cy := centroid(ps)
	nx, ny := math.Cos(ang), math.Sin(ang)
	return clipHalf(ps, cx, cy, nx, ny), clipHalf(ps, cx, cy, -nx, -ny)
}

func renderSolid3D(shapeIdx int, base, salt string, fs *facetStyle) (under, facets, over string) {
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

	yaw := fs.zone.floatIn(-13, 13) * math.Pi / 180
	th := viewTilt * math.Pi / 180
	cy, sy := math.Cos(yaw), math.Sin(yaw)
	ct, stt := math.Cos(th), math.Sin(th)
	view := func(p v3) v3 {
		x1, y1 := p.x*cy-p.y*sy, p.x*sy+p.y*cy
		return v3{x1, y1*ct + p.z*stt, p.z*ct - y1*stt}
	}
	ex0, ey0, ex1, ey1 := 1e9, 1e9, -1e9, -1e9
	for _, f := range faces {
		for _, p := range f.p {
			q := view(p)
			ex0, ey0 = math.Min(ex0, q.x), math.Min(ey0, q.y)
			ex1, ey1 = math.Max(ex1, q.x), math.Max(ey1, q.y)
		}
	}
	ox, oy := -(ex0+ex1)/2, -(ey0+ey1)/2
	scr := func(p v3) pt { return pt{subjX + p.x + ox, pieceCY - (p.y + oy)} }
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
		nv                v3
		jit, drift, thick float64
		ext               bool
	}
	shadeFront := func(kind int, nv, L v3, jit, drift, thick float64, ext bool) (string, float64) {
		H := vnorm(v3{L.x, L.y, L.z + 1})
		lam := math.Max(0, vdot(nv, L))
		lum := 0.03 + 0.7*math.Pow(lam, 2.1) + jit
		if ext {
			lum *= 0.3
		}
		if kind == kTable {
			lum = 0.36 + 0.26*lam
		}
		if kind == kPav {
			lum = 0.22 + 0.5*math.Max(0, vdot(vscale(nv, -1), L)) + jit
		}
		if raw {
			lum = 0.3 + 0.42*math.Pow(lam, 1.4) + 0.22*math.Max(0, vdot(vscale(nv, -1), L)) + jit*0.6
		}
		col := mixI(toneI(lum), deepI, 0.34*thick*thick)
		if sp := math.Pow(math.Max(0, vdot(nv, H)), 28); sp > 0.3 {
			col = mixI(col, whiteI, sp*0.85)
		}
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
		hull = nil
		for _, g := range girdle {
			hull = append(hull, scr(view(g)))
		}
	}
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
		candP = 0
	}
	for _, d := range front {
		if d.kind == kTable && shapeIdx == shapeHeart {
			facetsB.WriteString(`<path d="` + relPath(d.pts) + `" fill="` + d.fill + `" fill-opacity=".46"/>`)
			continue
		}
		if d.kind == kTable {
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
		if d.kind == kCrown && nCand < fireMaxFacets && fs.zone.floatIn(0, 1) < candP {
			nCand++
			cx, cyy := centroid(d.pts)
			fs.ringCent = append(fs.ringCent, pt{cx, cyy})
			facetsB.WriteString(`<path d="` + relPath(d.pts) + `" fill="` + d.fill + `" class="f"/>`)
			continue
		}
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

	gd, lastG := "", ""
	for i := range girdle {
		a, b := view(girdle[i]), view(girdle[(i+1)%len(girdle)])
		mid := vscale(v3{girdle[i].x + girdle[(i+1)%len(girdle)].x, girdle[i].y + girdle[(i+1)%len(girdle)].y, 0}, 0.5)
		if view(vnorm(mid)).z-0 > -0.05 && view(mid).z >= view(v3{}).z-0.01 {
			pa, pb := scr(a), scr(b)
			sa := n1(pa.x) + " " + n1(pa.y)
			if sa != lastG {
				gd += "M" + sa
			}
			lastG = n1(pb.x) + " " + n1(pb.y)
			gd += " " + lastG
		}
	}
	over = `<path d="` + gd + `" fill="none" stroke="` + hex3(lighten(base, 0.18)) + `" stroke-width=".7" stroke-linecap="round" opacity=".4"/>`
	return underB.String(), facetsB.String(), over
}

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

func spectrumAt(t float64) string {
	t = t - math.Floor(t)
	f := t * float64(len(spectrum))
	i := int(f)
	return mixHex(spectrum[i%len(spectrum)], spectrum[(i+1)%len(spectrum)], f-float64(i))
}

const (
	lightSwing     = 2.2
	lightMaxFacets = 12
)

func lumaDelta(a, b string) float64 {
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

const fireMaxFacets = 12

const starfield = true

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
		dur := rnd.floatIn(5, 12)
		b.WriteString(`<path d="M` + n1(st.x) + " " + n1(st.y) + `h.01" stroke-width=".9" opacity=".4" class="gt-tw" style="--d:` + fnum1(dur) + `s;--dl:-` + fnum1(rnd.floatIn(0, dur)) + `s"/>`)
	}
	b.WriteString(`</g>`)
	return b.String()
}

func pearlLusterGradient(gid, base, metal string) string {
	r, g, b := hexToRGB(base)
	lum := (0.2126*float64(r) + 0.7152*float64(g) + 0.0722*float64(b)) / 255
	shadow := "#4a4038"
	if lum < 0.4 {
		shadow = "#000000"
	}
	hi := base
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
		`<radialGradient id="` + gid + `m" cx=".42" cy=".36" r=".68">` +
		`<stop offset=".78" stop-color="` + metal + `" stop-opacity="0"/>` +
		`<stop offset=".93" stop-color="` + metal + `" stop-opacity="` + mo + `"/>` +
		`<stop offset="1" stop-color="` + metal + `" stop-opacity="0"/></radialGradient>` +
		`<radialGradient id="` + gid + `w" cx=".66" cy=".73" r=".2">` +
		`<stop offset="0" stop-color="#fff" stop-opacity="` + sw + `"/>` +
		`<stop offset="1" stop-color="#fff" stop-opacity="0"/></radialGradient>`
}

func pearlLayers(shape, gid, between string) string {
	i := strings.Index(shape, ` fill="`)
	if i < 0 {
		return shape
	}
	cp := func(suffix string) string { return shape[:i] + ` fill="url(#` + gid + suffix + `)"/>` }
	return shape + cp("o") + cp("m") + between + cp("w") + cp("s")
}

func pearlSweepColorIntensity(base string) float64 {
	r, g, b := hexToRGB(base)
	lum := 0.2126*float64(r)/255 + 0.7152*float64(g)/255 + 0.0722*float64(b)/255
	if lum < 0.4 {
		return 0.55
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

func pearlButton(base, metal, salt string) string {
	gid := "prl" + salt
	rx, ry := 25.0*stoneScale, 18.0*stoneScale
	body := `<ellipse cx="` + fnum(subjX) + `" cy="` + fnum(subjY) + `" rx="` + fnum(rx) + `" ry="` + fnum(ry) + `" fill="url(#` + gid + `)"/>`
	clipGeom := `<ellipse cx="` + fnum(subjX) + `" cy="` + fnum(subjY) + `" rx="` + fnum(rx) + `" ry="` + fnum(ry) + `"/>`
	sweep := pearlSweepOverlay(salt, base, clipGeom, rx*2, ry*2)
	return `<defs>` + pearlLusterGradient(gid, base, metal) + `</defs>` + pearlLayers(body, gid, "") + sweep
}

func pearlDrop(base, metal, salt string) string {
	gid := "prl" + salt
	w, h := 32.0*stoneScale, 42.0*stoneScale
	path := `M ` + fnum(subjX) + ` ` + fnum(subjY-h*0.55) +
		` C ` + fnum(subjX+w*0.55) + ` ` + fnum(subjY-h*0.15) + ` ` + fnum(subjX+w*0.42) + ` ` + fnum(subjY+h*0.42) + ` ` + fnum(subjX) + ` ` + fnum(subjY+h*0.48) +
		` C ` + fnum(subjX-w*0.42) + ` ` + fnum(subjY+h*0.42) + ` ` + fnum(subjX-w*0.55) + ` ` + fnum(subjY-h*0.15) + ` ` + fnum(subjX) + ` ` + fnum(subjY-h*0.55) + ` Z`
	body := `<path d="` + path + `" fill="url(#` + gid + `)"/>`
	clipGeom := `<path d="` + path + `"/>`
	sweep := pearlSweepOverlay(salt, base, clipGeom, w*1.6, h*0.9)
	return `<defs>` + pearlLusterGradient(gid, base, metal) + `</defs>` + pearlLayers(body, gid, "") + sweep
}

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

var PearlShapeNames = []string{"Round", "Oval", "Button", "Drop", "Baroque", "Circled"}

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

	return `<g transform="translate(` + fnum(subjX) + ` ` + fnum(subjY) + `)">` +
		`<g class="gt-v" style="--v-dur:` + fnum(motionVDur) + `s;--v-delay:-` + fnum(vphase) + `s">` +
		`<g class="gt-h" style="--h-dur:` + fnum(motionHDur) + `s;--h-delay:-` + fnum(hphase) + `s">` +
		`<g class="gt-r" style="--r-dur:` + fnum(motionRDur) + `s;--r-delay:-` + fnum(rphase) + `s;--rot-deg:` + fnum(rotDeg) + `deg">` +
		`<g class="gt-s" style="--s-dur:` + fnum(motionSDur) + `s;--s-delay:-` + fnum(sphase) + `s">` +
		`<g transform="translate(-` + fnum(subjX) + ` -` + fnum(subjY) + `)">` +
		content + `</g></g></g></g></g></g>`
}

const dotX, dotY = subjX + 50, subjY + 42

func renderStatusBadge(active bool) string {
	if active {
		return `<circle cx="` + fnum(dotX) + `" cy="` + fnum(dotY) + `" r="4" fill="#7fd88f"/>` +
			`<g transform="translate(` + fnum(dotX) + ` ` + fnum(dotY) + `)"><circle r="4" fill="none" stroke="#7fd88f" stroke-width="1.2" class="gt-badge-pulse" opacity="0.8"/></g>`
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

	ka, kb := "fa"+tidStr, "fb"+tidStr
	shape := func(at float64) string {
		return fnum1(at) + `%{opacity:0}` + fnum1(at+2) + `%{opacity:var(--o);fill:#fff}` +
			fnum1(at+4.5) + `%{opacity:.4;fill:var(--c)}` + fnum1(at+8) + `%{opacity:0}`
	}
	per := fnum(period)
	css = `.` + ka + `{animation:` + ka + ` ` + per + `s linear infinite}.` + kb + `{animation:` + kb + ` ` + per + `s linear infinite}` +
		`@keyframes ` + ka + `{` + shape(12.5) + `100%{opacity:0}}` +
		`@keyframes ` + kb + `{` + shape(62.5) + `100%{opacity:0}}`

	var out strings.Builder
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
		pos := ((c.x-subjX)*dx + (c.y-pieceCY)*dy) / (30 * stoneScale)
		name := ka
		if rnd.floatIn(0, 1) < 0.5 {
			name, pos = kb, -pos
		}
		delay := rphase - 0.25*motionRDur + period - pos*fireSweepSpan/2
		tag := markup[span.start:span.end]
		geomEnd := strings.Index(tag, `" fill=`)
		if geomEnd < 0 {
			continue
		}
		out.WriteString(tag[:geomEnd] + `" opacity="0" class="` + name + `" style="--o:` + fnum(math.Round(rnd.floatIn(0.55, 0.9)*colorOp*10)/10) + `;--c:` + hex3(color) +
			`;animation-delay:-` + fnum1(delay) + `s"/>`)
	}
	return out.String(), css
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
	"GNOLAND-1": "Diamond",
}

var stonePalettes = map[string][]namedColor{
	"Sapphire": {
		{"#2a5fe0", "Blue"}, {"#ff6ea4", "Pink"}, {"#ff8501", "Orange"}, {"#ffd500", "Yellow"},
		{"#1aa88a", "Green"}, {"#a658ff", "Violet"}, {"#e6e9f8", "White"}, {"#ff8f72", "Padparadscha"},
	},
	"Topaz": {
		{"#f5edd1", "Colorless"}, {"#ffa300", "Imperial"}, {"#ffd100", "Golden"},
		{"#c96a28", "Sherry Brown"}, {"#86cdf2", "Sky Blue"}, {"#ff96ba", "Pink"},
	},
	"Quartz": {
		{"#eef2f7", "Rock Crystal"}, {"#9b59d6", "Amethyst"}, {"#f2b01e", "Citrine"},
		{"#f5b9ca", "Rose Quartz"}, {"#7d6250", "Smoky Quartz"}, {"#a9d9a2", "Prasiolite"},
	},
	"Diamond": {
		{"#f3f6fc", "Colorless"}, {"#ffc400", "Fancy Yellow"}, {"#ff4f9a", "Fancy Pink"},
		{"#1f8fff", "Fancy Blue"}, {"#14c46e", "Fancy Green"}, {"#d9a560", "Champagne"},
		{"#b4561a", "Cognac"}, {"#2b2d34", "Black"},
		{"#e0243a", "Red"}, {"#ff7a1a", "Orange"}, {"#9b4fd6", "Purple"},
	},
	"Pearl": {
		{"#f8f6f0", "White"}, {"#f0e4c8", "Cream"}, {"#3a3a3c", "Black"}, {"#c8cdd4", "Silver"},
		{"#d4af6a", "Gold"}, {"#f0d4dc", "Pink"}, {"#f2c9a8", "Peach"}, {"#d8cbe0", "Lavender"},
	},
}

var colorWeights = map[string][]int{
	"Diamond": {30, 18, 5, 4, 3, 14, 12, 8, 1, 3, 2},
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

func ColorProbability(stone string, idx int) float64 {
	n := ColorPaletteSize(stone)
	total := 0
	for i := 0; i < n; i++ {
		total += colorWeight(stone, i)
	}
	return float64(colorWeight(stone, idx)) / float64(total)
}

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

func ChainAlwaysActive(chain string) bool { return chain == "GNOLAND-1" }

var stoneNames = []string{"Sapphire", "Topaz", "Pearl", "Diamond", "Quartz"}

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
	return "Quartz"
}

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

func ColorPaletteSize(stone string) int {
	if n := len(stonePalettes[stone]); n > 0 {
		return n
	}
	return len(stonePalettes["Quartz"])
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
	var pieceMarkup string
	if stone == "Pearl" {
		pearl := renderPearlShape(shapeIdx, colorHex, mt.hi, tidStr)
		overlay, css := applyCascade(pearl, tidStr, nil)
		pieceMarkup, cascadeCSS = pearl+overlay, css
	} else {
		fs := &facetStyle{prof: fireProfileFor(stone, colorName), zone: newPRNG("zone" + tidStr), stone: stone, thumb: thumb}
		under, facets, over := renderSolid3D(shapeIdx, colorHex, tidStr, fs)
		overlay, css := applyCascade(facets, tidStr, fs)
		cascadeCSS = css
		pieceMarkup = under + `<g fill-opacity=".9">` + facets + `</g>` + overlay + over
	}
	floatingPiece := applyMotion(pieceMarkup, tidStr)
	status := renderStatusBadge(active)
	serial := renderSerialText(tidStr, mt.hi)
	labelText := metalLabel[metal].text
	labelRect := renderMetalLabelRect(mt.hi, mt.lo, 24, 134, 122, 15, 3, tidStr)

	inner := `<rect width="` + fnum(canvasW) + `" height="` + fnum(canvasH) + `" fill="#0a0b10"/>` +
		renderStars(tidStr) + ringEls + floatingPiece + status + serial + labelRect +
		renderPlateText(chain+" CHAIN", labelText, mt.hi)

	svg = `<svg xmlns="http://www.w3.org/2000/svg" width="` + fnum(canvasW) + `" height="` + fnum(canvasH) + `" viewBox="0 0 ` + fnum(canvasW) + ` ` + fnum(canvasH) + `">` + styleBlock() +
		`<style>` + cascadeCSS + `</style>` + inner + `</svg>`
	return svg, stone, colorHex, colorName
}

func styleBlock() string {
	const easeOut = "cubic-bezier(0,0,.3,1)"
	return `<style>.gt-v,.gt-h,.gt-r,.gt-s{will-change:transform}` +

		`.gt-v{animation:gt-v var(--v-dur) ease-in-out var(--v-delay) infinite}` +
		`.gt-h{animation:gt-h var(--h-dur) ease-in-out var(--h-delay) infinite}` +
		`.gt-r{animation:gt-r var(--r-dur) ease-in-out var(--r-delay) infinite}` +
		`.gt-s{animation:gt-s var(--s-dur) ease-in-out var(--s-delay) infinite}` +
		`.gt-glow{animation:gt-glow var(--glow-dur) ease-in-out var(--glow-delay) infinite}` +
		`.gt-la{animation:gt-la var(--r-dur) ease-in-out var(--r-delay) infinite}` +
		`.gt-lb{animation:gt-lb var(--r-dur) ease-in-out var(--r-delay) infinite}` +
		`@keyframes gt-la{0%,50%,100%{opacity:0}25%{opacity:1}}` +
		`@keyframes gt-lb{0%,50%,100%{opacity:0}75%{opacity:1}}` +
		`.gt-badge-pulse{animation:gt-bp 1.8s ` + easeOut + ` infinite}` +
		`@keyframes gt-v{0%,100%{transform:translateY(2.5px)}50%{transform:translateY(-2.5px)}}` +
		`@keyframes gt-h{50%{transform:translateX(1.8px)}}` +
		`@keyframes gt-r{25%{transform:rotate(calc(-1*var(--rot-deg)))}75%{transform:rotate(var(--rot-deg))}}` +
		`@keyframes gt-s{50%{transform:scale(` + fnum(motionScale) + `)}}` +
		`.gt-tw{animation:gt-tw var(--d) ease-in-out var(--dl) infinite}@keyframes gt-tw{0%,84%,100%{opacity:.4}90%{opacity:1}94%{opacity:.2}}` +
		`@keyframes gt-glow{50%{opacity:1}}` +
		`@keyframes gt-bp{from{transform:scale(1);opacity:.8}to{transform:scale(2.25);opacity:0}}` +
		`</style>`
}
