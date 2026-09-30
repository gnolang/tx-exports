package course

import (
	"errors"
	"math"

	"gno.land/p/nym-alexiscolin000/gnogolf/physics"
)

// Magic starts GG1, a hole as one little-endian binary string, frozen with
// this package: magic, header, field, skin table (str = u8 len + bytes),
// walls (style runs, then segments and, outside pulses, their Lengths),
// posts, zones, pulses; each list a count first. Encode is the layout.
const Magic = "GG1"

// The frozen limits Decode holds a hole to, pulses included.
const (
	MaxWalls     = 160
	MaxPosts     = 32
	MaxZones     = 32
	MaxPoly      = 64  // points in one polygon
	MaxPolyTotal = 512 // points in all of them
	MaxPulses    = 16
	MaxSkins     = 64
	MaxSubsteps  = 60
	MaxTiming    = 4096
	MaxOrder     = 999
	MaxWorld     = 16
)

const (
	flagRound = 1 << iota
	flagOutside
	flagAir
	flagCapped
)

// Encode is the hole as GG1. It stores what it is given: call it on a hole
// after Fit, with its walls prepared.
func Encode(h *Simple) string {
	e := &encoder{}
	f := h.Course
	if f == nil {
		f = &physics.Field{}
	}
	skins := map[string]int{}
	var table []string
	skin := func(s string) {
		if _, ok := skins[s]; !ok {
			skins[s] = len(table)
			table = append(table, s)
		}
	}
	pieces := func(ws []physics.Wall, ps []physics.Post, zs []physics.Zone) {
		for _, w := range ws {
			skin(w.Skin)
		}
		for _, p := range ps {
			skin(p.Skin)
		}
		for _, z := range zs {
			skin(z.Skin)
		}
	}
	pieces(f.Walls, f.Posts, f.Zones)
	for _, p := range h.Pulses {
		pieces(p.Walls, p.Posts, p.Zones)
	}

	e.b = append(e.b, Magic...)
	e.u16(h.W)
	e.u16(h.H)
	e.u8(h.Strokes)
	e.u16(h.Substeps)
	e.str(h.World)
	e.f64(h.Order)
	e.str(h.Title)
	e.vec(h.Tee)
	e.vec(h.Pin)
	e.f64(h.CupRadius)
	e.f64(h.Shelter)
	e.f64(f.Friction)
	e.f64(f.Bounce)
	e.f64(f.Radius)
	e.u16(len(table))
	for _, s := range table {
		e.str(s)
	}
	e.walls(f.Walls, skins, f.Radius, true)
	e.posts(f.Posts, skins)
	e.zones(f.Zones, skins)
	e.u8(len(h.Pulses))
	for _, p := range h.Pulses {
		e.i32(p.Every)
		e.i32(p.On)
		e.i32(p.Phase)
		e.walls(p.Walls, skins, f.Radius, false)
		e.posts(p.Posts, skins)
		e.zones(p.Zones, skins)
	}
	return string(e.b)
}

type encoder struct{ b []byte }

func (e *encoder) u8(n int)  { e.b = append(e.b, byte(n)) }
func (e *encoder) u16(n int) { e.b = append(e.b, byte(n), byte(n>>8)) }
func (e *encoder) i32(n int) {
	u := uint32(int32(n))
	e.b = append(e.b, byte(u), byte(u>>8), byte(u>>16), byte(u>>24))
}

func (e *encoder) f64(x float64) {
	u := math.Float64bits(x)
	e.b = append(e.b, byte(u), byte(u>>8), byte(u>>16), byte(u>>24), byte(u>>32), byte(u>>40), byte(u>>48), byte(u>>56))
}

func (e *encoder) vec(v physics.Vec2) {
	e.f64(v.X)
	e.f64(v.Y)
}

func (e *encoder) str(s string) {
	e.u8(len(s))
	e.b = append(e.b, s[:len(s)&0xff]...)
}

// sameStyle is whether two walls share everything but their segment.
func sameStyle(a, b *physics.Wall) bool {
	return math.Float64bits(a.Bounce) == math.Float64bits(b.Bounce) && a.Mark == b.Mark && a.Skin == b.Skin &&
		a.Every == b.Every && a.On == b.On && a.Phase == b.Phase
}

func (e *encoder) walls(ws []physics.Wall, skins map[string]int, r float64, lengths bool) {
	e.u16(len(ws))
	for i := 0; i < len(ws); {
		j := i + 1
		for j < len(ws) && sameStyle(&ws[i], &ws[j]) {
			j++
		}
		w := &ws[i]
		e.u16(j - i)
		e.f64(w.Bounce)
		e.i32(int(w.Mark))
		e.u16(skins[w.Skin])
		e.i32(w.Every)
		e.i32(w.On)
		e.i32(w.Phase)
		i = j
	}
	for _, w := range ws {
		e.vec(w.Seg.A)
		e.vec(w.Seg.B)
		if lengths {
			l, lp, lm := physics.Lengths(w.Seg, r)
			e.f64(l)
			e.f64(lp)
			e.f64(lm)
		}
	}
}

func (e *encoder) posts(ps []physics.Post, skins map[string]int) {
	e.u16(len(ps))
	for _, p := range ps {
		e.vec(p.C)
		e.f64(p.R)
		e.f64(p.Bounce)
		e.i32(int(p.Mark))
		e.u16(skins[p.Skin])
	}
}

func (e *encoder) zones(zs []physics.Zone, skins map[string]int) {
	e.u16(len(zs))
	for _, z := range zs {
		e.u8(int(z.Kind))
		flags := 0
		if z.Round {
			flags |= flagRound
		}
		if z.Outside {
			flags |= flagOutside
		}
		if z.Air {
			flags |= flagAir
		}
		if z.Capped {
			flags |= flagCapped
		}
		e.u8(flags)
		e.vec(z.Min)
		e.vec(z.Max)
		e.vec(z.Vec)
		e.f64(z.Scale)
		e.i32(int(z.Mark))
		e.u16(skins[z.Skin])
		e.i32(z.Every)
		e.i32(z.On)
		e.i32(z.Phase)
		e.u16(len(z.Poly))
		for _, p := range z.Poly {
			e.vec(p)
		}
	}
}

// Decode reads a GG1 hole; anything outside the format, its limits or its
// value bounds is an error, with nothing returned. It prepares the walls from
// the stored lengths (physics.PrepareWith) and trusts them: check them once
// with Exact, or use DecodeChecked, before accepting data from anyone.
func Decode(s string) (*Simple, error) {
	d := &decoder{s: s}
	if len(s) < len(Magic) || s[:len(Magic)] != Magic {
		return nil, errors.New("course: not GG1 data")
	}
	d.i = len(Magic)
	h := &Simple{}
	h.W, h.H = d.u16(), d.u16()
	h.Strokes = d.u8()
	h.Substeps = d.u16()
	h.World = d.str()
	h.Order = d.f64()
	h.Title = d.str()
	if d.err != "" {
		return nil, errors.New(d.err)
	}
	if h.W < 1 || h.W > MaxBoard || h.H < 1 || h.H > MaxBoard {
		return nil, errors.New("course: the board is 1 to 96 a side")
	}
	if h.Strokes > 19 {
		return nil, errors.New("course: par is at most 19")
	}
	if h.Substeps < 1 || h.Substeps > MaxSubsteps {
		return nil, errors.New("course: substeps are 1 to 60")
	}
	if !IsWorld(h.World) {
		return nil, errors.New("course: a world is 1 to 16 letters a-z")
	}
	if !(h.Order >= 0 && h.Order <= MaxOrder) {
		return nil, errors.New("course: order is 0 to 999")
	}
	d.w, d.h = float64(h.W), float64(h.H)
	h.Tee, h.Pin = d.point(), d.point()
	h.CupRadius, h.Shelter = d.f64(), d.f64()
	f := &physics.Field{}
	f.Friction, f.Bounce, f.Radius = d.f64(), d.f64(), d.f64()
	if d.err == "" {
		switch {
		case !(h.CupRadius > 0 && h.CupRadius <= 2):
			d.fail("the cup's radius is above 0 and at most 2")
		case !(h.Shelter >= 0 && h.Shelter <= 1):
			d.fail("shelter is 0 to 1")
		case !(f.Friction >= 0 && f.Friction < 1):
			d.fail("friction is 0 to below 1")
		case !bounce(f.Bounce):
			d.fail("a bounce is 0 to 1.5")
		case !(f.Radius >= 0 && f.Radius <= 1):
			d.fail("the ball's radius is 0 to 1")
		}
	}
	n := d.u16()
	if n > MaxSkins {
		d.fail("too many skins")
	}
	if d.err != "" {
		return nil, errors.New(d.err)
	}
	d.skins = make([]string, n)
	for i := range d.skins {
		d.skins[i] = d.str()
	}
	var lens []float64
	f.Walls, lens = d.walls(true)
	f.Posts = d.posts()
	f.Zones = d.zones()
	np := d.u8()
	if np > MaxPulses {
		d.fail("too many pulses")
	}
	if d.err != "" {
		return nil, errors.New(d.err)
	}
	if np > 0 {
		h.Pulses = make([]Pulse, np)
	}
	for i := range h.Pulses {
		p := &h.Pulses[i]
		p.Every, p.On, p.Phase = d.i32(), d.i32(), d.i32()
		if !timing(p.Every, p.On, p.Phase) {
			d.fail("a pulse's timing is out of bounds")
		}
		p.Walls, _ = d.walls(false)
		p.Posts = d.posts()
		p.Zones = d.zones()
		if d.err != "" {
			return nil, errors.New(d.err)
		}
	}
	if d.err != "" {
		return nil, errors.New(d.err)
	}
	if d.i != len(s) {
		return nil, errors.New("course: trailing bytes after the hole")
	}
	physics.PrepareWith(f, lens)
	h.Course = f
	return h, nil
}

// DecodeChecked is Decode, then Exact: for data anyone wrote. It costs a
// Prepare more; data once checked can be read back with Decode.
func DecodeChecked(s string) (*Simple, error) {
	h, err := Decode(s)
	if err != nil {
		return nil, err
	}
	if !Exact(h) {
		return nil, errors.New("course: the stored wall lengths are not the walls' own")
	}
	return h, nil
}

// Exact reports whether a decoded hole's stored lengths are its walls' own,
// its prep bit for bit the one Prepare works out. Use it on a value fresh from
// Decode: it prepares a copy of the field, which can panic on a hole stored in
// another realm (the copy keeps that realm's read-only mark).
func Exact(h *Simple) bool {
	if h.Course == nil {
		return false
	}
	got := physics.Prepared(h.Course)
	g := *h.Course
	physics.Prepare(&g)
	want := physics.Prepared(&g)
	if len(got) != len(want) {
		return false
	}
	for i := range want {
		if math.Float64bits(got[i]) != math.Float64bits(want[i]) {
			return false
		}
	}
	return true
}

// decoder reads GG1 with every read bounds-checked: past the end it records
// the error and reads zeros. Counts are checked against the limits before
// anything is allocated for them.
type decoder struct {
	s                               string
	i                               int
	err                             string
	w, h                            float64 // the board, for the coordinate bounds
	skins                           []string
	nWalls, nPosts, nZones, nPoints int // running totals, pulses included
}

func (d *decoder) fail(why string) {
	if d.err == "" {
		d.err = "course: " + why
	}
}

func (d *decoder) need(n int) bool {
	if d.i+n > len(d.s) {
		d.fail("truncated data")
		d.i = len(d.s)
		return false
	}
	return true
}

func (d *decoder) u8() int {
	if !d.need(1) {
		return 0
	}
	d.i++
	return int(d.s[d.i-1])
}

func (d *decoder) u16() int {
	if !d.need(2) {
		return 0
	}
	s, i := d.s, d.i
	d.i += 2
	return int(s[i]) | int(s[i+1])<<8
}

func (d *decoder) i32() int {
	if !d.need(4) {
		return 0
	}
	s, i := d.s, d.i
	d.i += 4
	return int(int32(uint32(s[i]) | uint32(s[i+1])<<8 | uint32(s[i+2])<<16 | uint32(s[i+3])<<24))
}

// f64 reads a float and refuses NaN and the infinities; -0 is kept.
func (d *decoder) f64() float64 {
	s, i := d.s, d.i
	if i+8 > len(s) {
		d.need(8)
		return 0
	}
	d.i = i + 8
	x := math.Float64frombits(uint64(s[i]) | uint64(s[i+1])<<8 | uint64(s[i+2])<<16 | uint64(s[i+3])<<24 |
		uint64(s[i+4])<<32 | uint64(s[i+5])<<40 | uint64(s[i+6])<<48 | uint64(s[i+7])<<56)
	if x-x != 0 { // NaN or an infinity
		d.fail("a number is not finite")
		return 0
	}
	return x
}

func (d *decoder) str() string {
	n := d.u8()
	if !d.need(n) {
		return ""
	}
	d.i += n
	return d.s[d.i-n : d.i]
}

// point reads a position, which must lie on the board or within 1 of it.
func (d *decoder) point() physics.Vec2 {
	x, y := d.f64(), d.f64()
	if !(x >= -1 && x <= d.w+1 && y >= -1 && y <= d.h+1) {
		d.fail("a point lies off the board")
	}
	return physics.Vec2{X: x, Y: y}
}

// corner reads a corner of a zone's box, which may lie up to MaxBoard off the
// board: Fit keeps a round or polygon zone's box whole.
func (d *decoder) corner() physics.Vec2 {
	x, y := d.f64(), d.f64()
	if !(x >= -MaxBoard && x <= d.w+MaxBoard && y >= -MaxBoard && y <= d.h+MaxBoard) {
		d.fail("a zone's box lies far off the board")
	}
	return physics.Vec2{X: x, Y: y}
}

func (d *decoder) skin() string {
	k := d.u16()
	if k >= len(d.skins) {
		d.fail("a skin index is out of range")
		return ""
	}
	return d.skins[k]
}

func bounce(b float64) bool { return b >= 0 && b <= 1.5 }

// timing is the bounds of Every/On/Phase: untimed is all zeros; timed, on at
// most every and phase below it.
func timing(every, on, phase int) bool {
	if every == 0 {
		return on == 0 && phase == 0
	}
	return every > 0 && every <= MaxTiming && on >= 0 && on <= every && phase >= 0 && phase < every
}

// IsWorld is whether w can name a world: 1 to MaxWorld letters a-z, as Decode
// holds data to.
func IsWorld(w string) bool {
	if len(w) < 1 || len(w) > MaxWorld {
		return false
	}
	for i := 0; i < len(w); i++ {
		if w[i] < 'a' || w[i] > 'z' {
			return false
		}
	}
	return true
}

// walls reads a wall list: its style runs, then its segments (and, with
// lengths, each wall's three Lengths).
func (d *decoder) walls(lengths bool) ([]physics.Wall, []float64) {
	n := d.u16()
	if d.nWalls += n; d.nWalls > MaxWalls {
		d.fail("too many walls")
	}
	if d.err != "" {
		return nil, nil
	}
	ws := make([]physics.Wall, n)
	for i := 0; i < n && d.err == ""; {
		count := d.u16()
		if count < 1 || count > n-i {
			d.fail("a wall style run does not fit the walls")
			break
		}
		w := physics.Wall{Bounce: d.f64(), Mark: rune(d.i32()), Skin: d.skin(), Every: d.i32(), On: d.i32(), Phase: d.i32()}
		if !bounce(w.Bounce) {
			d.fail("a bounce is 0 to 1.5")
		}
		if !timing(w.Every, w.On, w.Phase) {
			d.fail("a wall's timing is out of bounds")
		}
		for k := 0; k < count; k++ {
			ws[i+k] = w
		}
		i += count
	}
	// one bounds check, then le per float: most of a hole's floats are here
	size := 32
	if lengths {
		size = 56
	}
	if d.err != "" || !d.need(n*size) {
		return nil, nil
	}
	var lens []float64
	if lengths {
		lens = make([]float64, 3*n)
	}
	s, i := d.s, d.i
	for k := range ws {
		ax, ay, bx, by := le(s, i), le(s, i+8), le(s, i+16), le(s, i+24)
		if !(ax >= -1 && ax <= d.w+1 && ay >= -1 && ay <= d.h+1 && bx >= -1 && bx <= d.w+1 && by >= -1 && by <= d.h+1) {
			d.fail("a point lies off the board")
			return nil, nil
		}
		ws[k].Seg = physics.Segment{A: physics.Vec2{X: ax, Y: ay}, B: physics.Vec2{X: bx, Y: by}}
		if lengths {
			l, lp, lm := le(s, i+32), le(s, i+40), le(s, i+48)
			if l-l != 0 || lp-lp != 0 || lm-lm != 0 {
				d.fail("a number is not finite")
				return nil, nil
			}
			lens[3*k], lens[3*k+1], lens[3*k+2] = l, lp, lm
		}
		i += size
	}
	d.i = i
	return ws, lens
}

// le is the little-endian float at s[i:i+8]; the caller checked the length.
// f64 has it inline: a call more per float is gas on every decode.
func le(s string, i int) float64 {
	return math.Float64frombits(uint64(s[i]) | uint64(s[i+1])<<8 | uint64(s[i+2])<<16 | uint64(s[i+3])<<24 |
		uint64(s[i+4])<<32 | uint64(s[i+5])<<40 | uint64(s[i+6])<<48 | uint64(s[i+7])<<56)
}

func (d *decoder) posts() []physics.Post {
	n := d.u16()
	if d.nPosts += n; d.nPosts > MaxPosts {
		d.fail("too many posts")
	}
	if d.err != "" {
		return nil
	}
	ps := make([]physics.Post, n)
	for i := 0; i < n && d.err == ""; i++ {
		p := &ps[i]
		p.C = d.point()
		p.R, p.Bounce = d.f64(), d.f64()
		p.Mark, p.Skin = rune(d.i32()), d.skin()
		if !(p.R > 0 && p.R <= 8) {
			d.fail("a post's radius is above 0 and at most 8")
		}
		if !bounce(p.Bounce) {
			d.fail("a bounce is 0 to 1.5")
		}
	}
	return ps
}

func (d *decoder) zones() []physics.Zone {
	n := d.u16()
	if d.nZones += n; d.nZones > MaxZones {
		d.fail("too many zones")
	}
	if d.err != "" {
		return nil
	}
	zs := make([]physics.Zone, n)
	for i := 0; i < n && d.err == ""; i++ {
		z := &zs[i]
		kind, flags := d.u8(), d.u8()
		if kind > int(physics.Loop) {
			d.fail("a zone's kind is unknown")
		}
		if flags&^(flagRound|flagOutside|flagAir|flagCapped) != 0 {
			d.fail("a zone has unknown flags")
		}
		z.Kind = physics.ZoneKind(kind)
		z.Round, z.Outside, z.Air, z.Capped = flags&flagRound != 0, flags&flagOutside != 0, flags&flagAir != 0, flags&flagCapped != 0
		z.Min, z.Max = d.corner(), d.corner()
		switch z.Kind {
		case physics.Tunnel, physics.Hazard, physics.Loop:
			z.Vec = d.point() // a place on the board
		default:
			z.Vec = physics.Vec2{X: d.f64(), Y: d.f64()} // a push
			// no steeper than MaxSin (squared: no root; a NaN fails it)
			if max := physics.G * physics.MaxSin; !(z.Vec.X*z.Vec.X+z.Vec.Y*z.Vec.Y <= max*max) {
				d.fail("a slope pushes at most G·MaxSin (0.95)")
			}
		}
		z.Scale = d.f64()
		if !(z.Scale >= 0 && z.Scale <= 8) {
			d.fail("a zone's scale is 0 to 8")
		}
		z.Mark, z.Skin = rune(d.i32()), d.skin()
		z.Every, z.On, z.Phase = d.i32(), d.i32(), d.i32()
		if !timing(z.Every, z.On, z.Phase) {
			d.fail("a zone's timing is out of bounds")
		}
		np := d.u16()
		if np == 1 || np == 2 || np > MaxPoly {
			d.fail("a polygon has 3 to 64 points")
		}
		if d.nPoints += np; d.nPoints > MaxPolyTotal {
			d.fail("too many polygon points")
		}
		if d.err != "" {
			break
		}
		if np > 0 {
			z.Poly = make([]physics.Vec2, np)
			for k := range z.Poly {
				z.Poly[k] = d.point()
			}
		}
	}
	return zs
}
