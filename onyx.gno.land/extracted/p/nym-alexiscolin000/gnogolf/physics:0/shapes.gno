package physics

import "math"

// Segment is a straight barrier from A to B.
type Segment struct{ A, B Vec2 }

// Normal is the unit left-normal of the segment.
func (s Segment) Normal() Vec2 {
	d := s.B.Sub(s.A)
	l := d.Len()
	if l == 0 {
		return Vec2{}
	}
	return Vec2{-d.Y / l, d.X / l}
}

// Crosses reports whether the motion p0->p1 crosses the segment, without
// working out the normal (and its square root).
func (s Segment) Crosses(p0, p1 Vec2) bool {
	_, _, ok := s.hitN(p0, p1, Vec2{})
	return ok
}

// hitN reports where the motion p0->p1 crosses the segment: the travel
// fraction in [0,1] and the given normal (precomputed, to save a square
// root per test), turned to face the motion.
func (s Segment) hitN(p0, p1, normal Vec2) (float64, Vec2, bool) {
	d := p1.Sub(p0)
	e := s.B.Sub(s.A)
	den := d.X*e.Y - d.Y*e.X
	if math.Abs(den) < 1e-12 {
		return 0, Vec2{}, false // parallel
	}
	f := s.A.Sub(p0)
	t := (f.X*e.Y - f.Y*e.X) / den // along the motion
	u := (f.X*d.Y - f.Y*d.X) / den // along the barrier
	if t < 0 || t > 1 || u < 0 || u > 1 {
		return 0, Vec2{}, false
	}
	n := normal
	if d.Dot(n) > 0 {
		n = n.Scale(-1)
	}
	return t, n, true
}

// Circle is a round barrier: a post, a bumper, the rim of a pond.
type Circle struct {
	C Vec2
	R float64
}

// hit is the swept point-vs-circle test, adding rootWork to *w per square
// root. A ball that starts inside reports no hit: a post never traps a ball.
func (c Circle) hit(p0, p1 Vec2, w *int) (float64, Vec2, bool) {
	d := p1.Sub(p0)
	a := d.Dot(d)
	if a < 1e-12 {
		return 0, Vec2{}, false
	}
	m := p0.Sub(c.C)
	if m.Dot(m) < c.R*c.R {
		return 0, Vec2{}, false // started inside
	}
	b := 2 * m.Dot(d)
	k := m.Dot(m) - c.R*c.R
	disc := b*b - 4*a*k
	if disc < 0 {
		return 0, Vec2{}, false
	}
	*w += rootWork
	t := (-b - math.Sqrt(disc)) / (2 * a)
	if t < 0 || t > 1 {
		return 0, Vec2{}, false
	}
	n := p0.Add(d.Scale(t)).Sub(c.C)
	*w += rootWork
	l := n.Len()
	if l == 0 {
		return 0, Vec2{}, false
	}
	return t, n.Scale(1 / l), true
}
