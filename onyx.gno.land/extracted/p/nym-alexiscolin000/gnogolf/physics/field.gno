package physics

// Wall is a straight barrier. Bounce overrides the field's restitution (0
// keeps it); Mark and Skin are for whoever draws it, except that only a
// bumper's skin kicks (Kicks).
type Wall struct {
	Seg    Segment
	Bounce float64 // 0 = use the field default
	Mark   rune
	Skin   string
	// Every > 0 times the wall within a stroke: it stands in substep i only
	// when (i+Tick+Phase) mod Every is below On.
	Every, On, Phase int
}

// There is the timing rule walls, zones and course pulses share (sign-safe
// mod, so a negative phase works): on at i when (i+phase) mod every is below
// on; every <= 0 is always there.
func There(i, every, on, phase int) bool {
	return every <= 0 || ((i+phase)%every+every)%every < on
}

// WithTick is the field with its clock moved on by tick substeps. It may
// return f itself (tick 0): do not mutate what it returns.
func WithTick(f *Field, tick int) *Field {
	if tick == 0 {
		return f
	}
	g := *f
	g.Tick = f.Tick + tick
	return &g
}

// Post is a round obstacle. Bounce is the contact's restitution, played at
// MaxBounce at most; above 1 with a bumper's skin (Kicks) it kicks the ball
// back faster than it came (at most MaxKick times).
type Post struct {
	Circle
	Bounce float64 // 0 = use the field default; played at MaxBounce at most; above 1 a bumper, if Kicks(Skin)
	Mark   rune
	Skin   string
}

// ZoneKind is what a zone does to a ball inside it.
type ZoneKind int

// The zone kinds, each named in its own line.
const (
	Surface ZoneKind = iota // Scale sets the rolling resistance (Rolling): sand holds, ice frees
	Slope                   // a hill: Vec, gravity along it, is added to velocity each substep
	Tunnel                  // the ball is moved to Vec, keeping its velocity
	Hazard                  // the ball goes back where the stroke was played from: water, a pit, the void
	// Loop is a tube's mouth (Min..Max): a ball heading in within 25° at
	// Scale or faster comes out at Vec, else it falls back or off the side.
	// The mouth must be at least MaxMove deep, or a fast ball steps over it.
	Loop
)

// LoopKeep is the share of its speed a ball keeps once round a loop.
const LoopKeep = 0.8

// Zone is an area of the board that changes how the ball moves: the rectangle
// Min..Max, or the ellipse inside it (Round), or a polygon (Poly), or all of it
// but a polygon (Outside). Vec and Scale mean what the kind says.
type Zone struct {
	Kind     ZoneKind
	Min, Max Vec2
	Vec      Vec2    // Slope: acceleration (G·sin θ downhill). Tunnel: destination. Loop: where it comes down. Hazard: unused.
	Scale    float64 // Surface: its rolling resistance (Rolling). Loop: the speed to go round.
	Mark     rune
	Skin     string
	// Round makes the zone the ellipse inscribed in Min..Max.
	Round bool
	// Poly (3 points or more) makes the zone that polygon, within Min..Max;
	// Outside makes it everything in Min..Max but the polygon.
	Poly    []Vec2
	Outside bool
	// Every, On, Phase time the zone within a stroke, as for a Wall.
	Every, On, Phase int
	// Air makes a Slope moving air: it pushes the ball but is no hill, and
	// hides none under it. Capped air never speeds the ball up.
	Air, Capped bool
}

// Contains says whether p is in the zone, by its shape.
func (z Zone) Contains(p Vec2) bool { return z.contains(p) }

// contains is Contains through a pointer: a Zone is too big to copy per move.
func (z *Zone) contains(p Vec2) bool {
	if p.X < z.Min.X || p.X >= z.Max.X || p.Y < z.Min.Y || p.Y >= z.Max.Y {
		return false
	}
	if len(z.Poly) >= 3 {
		return inPoly(z.Poly, p) != z.Outside
	}
	if !z.Round {
		return true
	}
	hx, hy := (z.Max.X-z.Min.X)/2, (z.Max.Y-z.Min.Y)/2
	dx, dy := (p.X-z.Min.X-hx)/hx, (p.Y-z.Min.Y-hy)/hy
	return dx*dx+dy*dy < 1
}

// Field is everything a ball rolls through: walls, posts and zones.
type Field struct {
	Walls    []Wall
	Posts    []Post
	Zones    []Zone
	Friction float64 // the green's rolling resistance, as Rolling maps it: 0.87 is Crr 0.224
	Bounce   float64 // default restitution of barriers
	// Radius of the ball (0 plays it as a point).
	Radius float64
	// Tick is where the stroke starts on the clock of timed walls and zones.
	Tick int
	// Cap, above 0 and under MaxWork, replaces MaxWork for this stroke.
	Cap int
	// prep is the walls' offsets, worked out once (Prepare).
	prep []float64
}

// String is the kind's name as clients read it: "surface", "slope", ...
func (k ZoneKind) String() string {
	switch k {
	case Surface:
		return "surface"
	case Slope:
		return "slope"
	case Tunnel:
		return "tunnel"
	case Hazard:
		return "hazard"
	case Loop:
		return "loop"
	}
	return "unknown"
}

// inPoly is the even-odd point-in-polygon test.
func inPoly(pts []Vec2, p Vec2) bool {
	in := false
	for i := range pts {
		a, b := pts[i], pts[(i+1)%len(pts)]
		if (a.Y > p.Y) != (b.Y > p.Y) && p.X < a.X+(p.Y-a.Y)*(b.X-a.X)/(b.Y-a.Y) {
			in = !in
		}
	}
	return in
}
