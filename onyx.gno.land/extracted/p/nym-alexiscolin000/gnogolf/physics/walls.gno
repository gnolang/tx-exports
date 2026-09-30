package physics

import "math"

// offset is what Step needs of a wall: its two offset lines (where the
// ball's centre meets it), their normals, the wall's start, normal and
// length, its bounce and timing, and its broad-phase box.
type offset struct {
	plus, minus      Segment
	pn, mn           Vec2 // plus.Normal(), minus.Normal()
	a, n             Vec2
	length, bounce   float64
	every, on, phase int
	lo, hi           Vec2
}

// unstickGap is how far clear of a piece UnstickIn sets a ball down.
const unstickGap = 0.02

// boxPad grows every broad-phase box: more than the half skin of Step's near
// test, and far more than rounding.
const boxPad = 1e-6

// lines works out a wall's offset lines for a ball of radius r: the segment
// pushed r to each side and lengthened by r at each end. Same bits as Normal
// and that push, with 3 square roots instead of 8.
func lines(s Segment, r float64, o *offset) {
	d := s.B.Sub(s.A)
	l := d.Len()
	o.a, o.length = s.A, l
	if l == 0 {
		o.plus, o.minus, o.n, o.pn, o.mn = s, s, Vec2{}, Vec2{}, Vec2{}
	} else {
		n := Vec2{-d.Y / l, d.X / l}
		toward := func(p Vec2) Segment {
			m := n
			if p.Sub(s.A).Dot(m) < 0 {
				m = m.Scale(-1)
			}
			e, off := d.Scale(r/l), m.Scale(r)
			return Segment{A: s.A.Sub(e).Add(off), B: s.B.Add(e).Add(off)}
		}
		o.n = n
		o.plus, o.minus = toward(s.A.Add(n)), toward(s.A.Sub(n))
		o.pn, o.mn = o.plus.Normal(), o.minus.Normal()
	}
	o.lo, o.hi = o.plus.A, o.plus.A
	for _, p := range []Vec2{o.plus.B, o.minus.A, o.minus.B} {
		if p.X < o.lo.X {
			o.lo.X = p.X
		} else if p.X > o.hi.X {
			o.hi.X = p.X
		}
		if p.Y < o.lo.Y {
			o.lo.Y = p.Y
		} else if p.Y > o.hi.Y {
			o.hi.Y = p.Y
		}
	}
	o.lo, o.hi = o.lo.Sub(Vec2{boxPad, boxPad}), o.hi.Add(Vec2{boxPad, boxPad})
}

// stride is the floats per wall in Field.prep: the wall's ends (to know the
// entry is still that wall's), then plus, minus, pn, mn, n, length, lo, hi.
const stride = 23

// Prepare works out the field's wall offsets once, for every shot to reuse.
// Call it once the walls are where they stay: Step works out again any wall
// that no longer matches its entry.
func Prepare(f *Field) {
	p := make([]float64, 1, 1+stride*len(f.Walls))
	p[0] = f.Radius
	var o offset
	for j := range f.Walls {
		s := f.Walls[j].Seg
		lines(s, f.Radius, &o)
		p = appendPrep(p, s, &o)
	}
	f.prep = p
}

func appendPrep(p []float64, s Segment, o *offset) []float64 {
	return append(p, s.A.X, s.A.Y, s.B.X, s.B.Y,
		o.plus.A.X, o.plus.A.Y, o.plus.B.X, o.plus.B.Y,
		o.minus.A.X, o.minus.A.Y, o.minus.B.X, o.minus.B.Y,
		o.pn.X, o.pn.Y, o.mn.X, o.mn.Y, o.n.X, o.n.Y, o.length,
		o.lo.X, o.lo.Y, o.hi.X, o.hi.Y)
}

// Lengths is the three square roots Prepare takes for a wall and a ball of
// radius r: the wall's length, then its plus and minus offset lines'.
func Lengths(s Segment, r float64) (l, lp, lm float64) {
	var o offset
	lines(s, r, &o)
	return o.length, o.plus.B.Sub(o.plus.A).Len(), o.minus.B.Sub(o.minus.A).Len()
}

// PrepareWith is Prepare with each wall's Lengths given, three per wall in
// wall order: the same prep, bit for bit, when they are the walls' own. It
// does not check them; whoever stored them must have. With the wrong count
// it is Prepare.
func PrepareWith(f *Field, lens []float64) {
	if len(lens) != 3*len(f.Walls) {
		Prepare(f)
		return
	}
	p := make([]float64, 1, 1+stride*len(f.Walls))
	p[0] = f.Radius
	var o offset
	for j := range f.Walls {
		s := f.Walls[j].Seg
		linesWith(s, f.Radius, &o, lens[3*j], lens[3*j+1], lens[3*j+2])
		p = appendPrep(p, s, &o)
	}
	f.prep = p
}

// Prepared is a copy of the field's prep, to compare bit for bit.
func Prepared(f *Field) []float64 {
	out := make([]float64, len(f.prep))
	copy(out, f.prep)
	return out
}

// linesWith is lines with its square roots given (Lengths): the same
// operations in the same order, so the same bits, written out by hand to
// save lines' calls. Keep the two in step.
func linesWith(s Segment, r float64, o *offset, l, lp, lm float64) {
	dx, dy := s.B.X-s.A.X, s.B.Y-s.A.Y
	o.a, o.length = s.A, l
	if l == 0 {
		o.plus, o.minus, o.n, o.pn, o.mn = s, s, Vec2{}, Vec2{}, Vec2{}
	} else {
		nx, ny := -dy/l, dx/l
		q := r / l
		ex, ey := dx*q, dy*q
		o.n = Vec2{nx, ny}
		o.plus = towardWith(s, nx, ny, ex, ey, r, s.A.X+nx, s.A.Y+ny)
		o.minus = towardWith(s, nx, ny, ex, ey, r, s.A.X-nx, s.A.Y-ny)
		o.pn = normalWith(o.plus, lp)
		o.mn = normalWith(o.minus, lm)
	}
	lo, hi := o.plus.A, o.plus.A
	if p := o.plus.B; p.X < lo.X {
		lo.X = p.X
	} else if p.X > hi.X {
		hi.X = p.X
	}
	if p := o.plus.B; p.Y < lo.Y {
		lo.Y = p.Y
	} else if p.Y > hi.Y {
		hi.Y = p.Y
	}
	if p := o.minus.A; p.X < lo.X {
		lo.X = p.X
	} else if p.X > hi.X {
		hi.X = p.X
	}
	if p := o.minus.A; p.Y < lo.Y {
		lo.Y = p.Y
	} else if p.Y > hi.Y {
		hi.Y = p.Y
	}
	if p := o.minus.B; p.X < lo.X {
		lo.X = p.X
	} else if p.X > hi.X {
		hi.X = p.X
	}
	if p := o.minus.B; p.Y < lo.Y {
		lo.Y = p.Y
	} else if p.Y > hi.Y {
		hi.Y = p.Y
	}
	o.lo, o.hi = Vec2{lo.X - boxPad, lo.Y - boxPad}, Vec2{hi.X + boxPad, hi.Y + boxPad}
}

// towardWith is lines' toward: the offset line on (px, py)'s side.
func towardWith(s Segment, nx, ny, ex, ey, r, px, py float64) Segment {
	mx, my := nx, ny
	if (px-s.A.X)*mx+(py-s.A.Y)*my < 0 {
		mx, my = mx*-1, my*-1
	}
	ox, oy := mx*r, my*r
	return Segment{A: Vec2{(s.A.X - ex) + ox, (s.A.Y - ey) + oy}, B: Vec2{(s.B.X + ex) + ox, (s.B.Y + ey) + oy}}
}

// normalWith is Segment.Normal with the length given.
func normalWith(s Segment, l float64) Vec2 {
	if l == 0 {
		return Vec2{}
	}
	return Vec2{-(s.B.Y - s.A.Y) / l, (s.B.X - s.A.X) / l}
}

// offsets is every wall's offset for this shot: from the prep where it still
// matches the wall, worked out otherwise.
func (f *Field) offsets() []offset {
	offs := make([]offset, len(f.Walls))
	p := f.prep
	if len(p) == 0 || p[0] != f.Radius {
		p = nil
	}
	for j := range f.Walls {
		w := &f.Walls[j]
		o := &offs[j]
		if k := 1 + j*stride; k+stride <= len(p) && p[k] == w.Seg.A.X && p[k+1] == w.Seg.A.Y && p[k+2] == w.Seg.B.X && p[k+3] == w.Seg.B.Y {
			o.plus = Segment{Vec2{p[k+4], p[k+5]}, Vec2{p[k+6], p[k+7]}}
			o.minus = Segment{Vec2{p[k+8], p[k+9]}, Vec2{p[k+10], p[k+11]}}
			o.pn, o.mn, o.n = Vec2{p[k+12], p[k+13]}, Vec2{p[k+14], p[k+15]}, Vec2{p[k+16], p[k+17]}
			o.a, o.length = w.Seg.A, p[k+18]
			o.lo, o.hi = Vec2{p[k+19], p[k+20]}, Vec2{p[k+21], p[k+22]}
		} else {
			lines(w.Seg, f.Radius, o)
		}
		o.bounce = bounceOf(w.Bounce, f.Bounce, w.Skin)
		o.every, o.on, o.phase = w.Every, w.On, w.Phase
	}
	return offs
}

// timedBars is where each timed bar starts in f.Walls: four timed walls in a
// row, one timing, closing on themselves (build.Timed(build.Bar(…))).
func (f *Field) timedBars() []int {
	var out []int
	ws := f.Walls
	for j := 0; j+3 < len(ws); j++ {
		a := &ws[j]
		if a.Every <= 0 {
			continue
		}
		closed := true
		for k := 0; k < 4; k++ {
			w, next := &ws[j+k], &ws[j+(k+1)%4]
			if w.Every != a.Every || w.On != a.On || w.Phase != a.Phase || w.Seg.B != next.Seg.A {
				closed = false
				break
			}
		}
		if closed {
			out = append(out, j)
			j += 3
		}
	}
	return out
}

// UnstickIn moves a ball of radius r out of pieces that appeared on top of
// it. walls are read in bars of four (build.Bar): a ball inside one leaves
// through the nearest side it can; one closer than r to a bar or a post is
// pushed off it. No push crosses an untimed wall of stays: out of a bar the
// ball tries the next side, else it stays; any other such push is not made.
func UnstickIn(ball Vec2, walls []Wall, posts []Post, r float64, stays []Wall) Vec2 {
	for i := 0; i+3 < len(walls); i += 4 {
		q := walls[i : i+4]
		c := q[0].Seg.A.Add(q[1].Seg.A).Add(q[2].Seg.A).Add(q[3].Seg.A).Scale(0.25)
		inside := true
		for _, w := range q {
			if side(w.Seg, ball) != side(w.Seg, c) {
				inside = false
			}
		}
		if inside {
			// nearest side first, along its outward normal
			var tried [4]bool
			for range q {
				k, best, bestD := -1, Vec2{}, math.Inf(1)
				for j, w := range q {
					if p := w.Seg.Closest(ball); !tried[j] {
						if d := p.Sub(ball).Len(); d < bestD {
							k, best, bestD = j, p, d
						}
					}
				}
				if k < 0 {
					break // a NaN ball: no side is nearest
				}
				tried[k] = true
				n := q[k].Seg.Normal()
				if n.Dot(best.Sub(c)) < 0 {
					n = n.Scale(-1)
				}
				if to := best.Add(n.Scale(r + unstickGap)); !crossesAny(stays, ball, to) {
					ball = to
					break
				}
			}
			continue
		}
		best, bestD := Vec2{}, math.Inf(1)
		for _, w := range q {
			p := w.Seg.Closest(ball)
			if d := p.Sub(ball).Len(); d < bestD {
				best, bestD = p, d
			}
		}
		if bestD < r {
			out := ball.Sub(best)
			if l := out.Len(); l > 0 {
				if to := best.Add(out.Scale((r + unstickGap) / l)); !crossesAny(stays, ball, to) {
					ball = to
				}
			}
		}
	}
	for _, p := range posts {
		d := ball.Sub(p.C)
		if l := d.Len(); l < p.R+r {
			if l == 0 {
				d, l = Vec2{X: 1}, 1
			}
			if to := p.C.Add(d.Scale((p.R + r + unstickGap) / l)); !crossesAny(stays, ball, to) {
				ball = to
			}
		}
	}
	return ball
}

// crossesAny reports whether the move a->b crosses one of the untimed walls.
func crossesAny(walls []Wall, a, b Vec2) bool {
	for j := range walls {
		if walls[j].Every <= 0 && walls[j].Seg.Crosses(a, b) {
			return true
		}
	}
	return false
}

func side(s Segment, p Vec2) bool {
	return s.B.Sub(s.A).X*(p.Y-s.A.Y)-s.B.Sub(s.A).Y*(p.X-s.A.X) > 0
}

// Closest is the point of the segment nearest p.
func (s Segment) Closest(p Vec2) Vec2 {
	d := s.B.Sub(s.A)
	l := d.Dot(d)
	if l == 0 {
		return s.A
	}
	t := p.Sub(s.A).Dot(d) / l
	if t < 0 {
		t = 0
	} else if t > 1 {
		t = 1
	}
	return s.A.Add(d.Scale(t))
}
