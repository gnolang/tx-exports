// Package physics is a 2D rolling-ball engine: it answers where a ball goes,
// never what that means.
//
// +X is right, +Y is down, 1.0 is one board unit, angles are in radians.
// Deterministic: float64 only, no map iteration, no clock, no randomness.
//
// Inputs must be finite: a NaN or an infinity gives no panic and no endless
// loop, but no meaningful answer either. Callers check them.
package physics

import "math"

// Vec2 is a point or a displacement on the board, in board units.
type Vec2 struct{ X, Y float64 }

// V is Vec2{x, y}, short so a course's coordinates read as coordinates.
func V(x, y float64) Vec2 { return Vec2{X: x, Y: y} }

// Add is a+b.
func (a Vec2) Add(b Vec2) Vec2 { return Vec2{a.X + b.X, a.Y + b.Y} }

// Sub is a-b.
func (a Vec2) Sub(b Vec2) Vec2 { return Vec2{a.X - b.X, a.Y - b.Y} }

// Scale is a times s.
func (a Vec2) Scale(s float64) Vec2 { return Vec2{a.X * s, a.Y * s} }

// Dot is the dot product of a and b.
func (a Vec2) Dot(b Vec2) float64 { return a.X*b.X + a.Y*b.Y }

// Len is the length of a.
func (a Vec2) Len() float64 { return math.Sqrt(a.Dot(a)) }

// LenCmp compares a.Len() with r: -1 shorter, 0 equal, 1 longer, exactly as
// comparing a.Len() would. It takes the costly square root only within 1e-12
// of r², where a.Dot(a) alone could round the other way. For board-scale r.
func (a Vec2) LenCmp(r float64) int {
	d2, r2 := a.Dot(a), r*r
	switch {
	case r < 0 || d2 > r2*(1+1e-12):
		return 1
	case d2 < r2*(1-1e-12):
		return -1
	}
	l := math.Sqrt(d2)
	if l < r {
		return -1
	}
	if l > r {
		return 1
	}
	return 0
}

// FromPolar builds a vector of length r pointing at angle (radians).
func FromPolar(angle, r float64) Vec2 {
	return Vec2{r * math.Cos(angle), r * math.Sin(angle)}
}
