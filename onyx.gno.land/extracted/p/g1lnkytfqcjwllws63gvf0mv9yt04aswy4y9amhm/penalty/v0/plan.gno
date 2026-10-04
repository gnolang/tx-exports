package penalty

// Mode is what kind of move a keeper plan describes.
type Mode uint8

const (
	ModeStar Mode = iota + 1 // spread into a star jump
	ModeRead                 // hold and react to the shot
	ModeDive                 // commit to a dive
)

func (m Mode) String() string {
	switch m {
	case ModeStar:
		return "star jump"
	case ModeRead:
		return "wait and read"
	case ModeDive:
		return "committed dive"
	}
	return "unknown"
}

// Plan is a KeeperPlan decoded with a game's constants.
type Plan struct {
	Mode     Mode
	Heading  int64 // deci-degrees: 0 = along the line to the taker's right, 1800 = to the left, 900 = straight out
	Speed    int64 // mm/s along the ground (0 for a read)
	Jump     int64 // mm/s upwards (negative = collapse low)
	Reaction int64 // ms after contact before moving
}

// Dive headings stay within ForwardMax of the line, except for the middle
// CentreShare of the direction range, which sweeps the headings in between.
const (
	ForwardMax  = 220 // deci-degrees
	CentreShare = 60  // per-mille of the direction range
	StarMaxSpd  = 1150
)

// DecodePlan maps the four uint16 of a keeper plan onto a move:
//
//	direction  monotonic 0..65535 -> heading 0°..180°
//	speed      lowest StarShare -> star jump, next ReadShare -> wait and read,
//	           the rest -> dive at DiveMin..DiveMax
//	jump       JumpMin..JumpMax
//	reaction   ReactionMin..ReactionMax
//
// For a read plan the direction and jump are unused: the keeper decides them
// from the ball.
func DecodePlan(p KeeperPlan, c Config) Plan {
	out := Plan{
		Heading:  heading(p.Direction),
		Jump:     span(p.Jump, c.JumpMin, c.JumpMax),
		Reaction: span(p.Reaction, c.ReactionMin, c.ReactionMax),
	}
	u := int64(p.Speed)
	starEdge := 65535 * c.StarShare / 1000
	readEdge := 65535 * (c.StarShare + c.ReadShare) / 1000
	switch {
	case u < starEdge:
		out.Mode = ModeStar
		out.Speed = StarMaxSpd * u / starEdge
	case u < readEdge:
		out.Mode = ModeRead
	default:
		out.Mode = ModeDive
		out.Speed = c.DiveMin + (c.DiveMax-c.DiveMin)*(u-readEdge)/maxI(1, 65535-readEdge)
	}
	return out
}

func heading(d uint16) int64 {
	s := 2*int64(d) - 65535 // -65535 (right) .. 65535 (left)
	c := int64(65535 * CentreShare / 1000)
	switch {
	case s <= -c:
		return ForwardMax * (65535 + s) / (65535 - c)
	case s >= c:
		return 1800 - ForwardMax*(65535-s)/(65535-c)
	}
	return 900 + (900-ForwardMax)*s/c
}

// cosPermille approximates cos(heading) × 1000 (Bhaskara I), heading in
// deci-degrees within 0..1800. Integer-only, accurate to about 0.2%.
func cosPermille(h int64) int64 {
	sign := int64(1)
	if h > 900 {
		h = 1800 - h
		sign = -1
	}
	d2 := h * h // (deci-degrees)²
	return sign * 1000 * (3240000 - 4*d2) / (3240000 + d2)
}

func maxI(a, b int64) int64 {
	if a > b {
		return a
	}
	return b
}

func minI(a, b int64) int64 {
	if a < b {
		return a
	}
	return b
}

func absI(a int64) int64 {
	if a < 0 {
		return -a
	}
	return a
}

func clampI(x, lo, hi int64) int64 {
	if x < lo {
		return lo
	}
	if x > hi {
		return hi
	}
	return x
}
