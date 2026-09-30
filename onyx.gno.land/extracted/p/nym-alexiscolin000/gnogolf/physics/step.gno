package physics

import (
	"math"
	"strings"
)

// G is gravity, in board units per substep squared: a hill's Vec is G·sin θ.
const G = 1.0

// The calibration of Rolling, fitted by least squares to the course's
// strokes: keep = min((Friction+keepBonus)·Scale, maxKeep), then
// Crr = ((1−keep)·RollSpeed + RollDrag/Scale) / G.
const (
	RollSpeed = 1.8
	RollDrag  = 0.08
	keepBonus = 0.05
	maxKeep   = 0.98
)

// Rolling is the rolling-resistance coefficient Crr of a green of the given
// Friction under a Surface of the given Scale (1 is plain grass). A Scale of
// 0 or less is an infinite Crr: the ball stays where it is.
func Rolling(friction, scale float64) float64 {
	if !(scale > 0) {
		return math.Inf(1)
	}
	keep := (friction + keepBonus) * scale
	if keep > maxKeep {
		keep = maxKeep
	}
	return ((1-keep)*RollSpeed + RollDrag/scale) / G
}

// The contact rules for walls and posts.
const (
	// WallFriction is the Coulomb µ between the ball and a wall or post:
	// the tangential impulse is at most µ times the normal one.
	WallFriction = 0.05
	// TangentMass caps the tangential impulse, per unit mass and speed:
	// 2/7 is what stops a solid ball's contact point from slipping.
	TangentMass = 2.0 / 7
	// RestSpeed is the speed into a surface, per substep, under which a
	// contact is resting: no restitution, no bounce counted. At least what
	// the steepest hill adds in a substep, so a ball a hill presses into a
	// rail slides along it instead of jittering.
	RestSpeed = 0.35
	// MaxBounce is the most restitution a passive piece plays: a Bounce
	// above it is played at it.
	MaxBounce = 0.75
	// MaxKick is the most restitution a bumper (a Bounce above 1 on a skin
	// that Kicks) plays, and the most course.Decode accepts. The ball stays
	// under SpeedCap.
	MaxKick = 1.5
)

// The flight rules: a ball takes off over a hill's crest (its uphill edge)
// when v² > G·CrestRadius, v its speed up the hill, flies a ballistic arc and
// lands at the height it took off from.
const (
	// CrestRadius is the radius of a hill's lip, in board units: a ball
	// needs sqrt(G·CrestRadius), 0.71 per substep, to take off.
	CrestRadius = 0.5
	// MinRamp is the gentlest hill (|Vec|) that launches.
	MinRamp = 0.12
	// GroundBounce is the restitution of the ground when a ball lands.
	GroundBounce = 0.4
	// LandFriction is the Coulomb µ between a landing ball and the ground.
	LandFriction = 0.3
	// HopSpeed is the vertical speed, per substep, under which a landing
	// ball stays down.
	HopSpeed = 0.25
	// MaxSin is the steepest grade a hill plays, sin θ (about 72°), so tan θ
	// and a flight stay bounded; course.Decode holds |Vec| to G·MaxSin.
	MaxSin = 0.95
)

// MaxRollOn caps the substeps a ball may roll on past its stroke's own while
// a slope keeps it moving or it is still in the air.
const MaxRollOn = 120

// pinCheck and pinMove: a ball rolling on that moves less than pinMove in
// pinCheck substeps is pinned, and stops.
const (
	pinCheck = 8
	pinMove  = 0.1
)

// MaxWork caps what one stroke may cost, whatever the field, in work units
// of about a thousand gas each (Shot.Work): a stroke that reaches it ends
// where the ball is. A Field's Cap lowers it for one stroke.
const MaxWork = 1000000

// The work weights, in units, measured on the GnoVM with probes that add one
// kind of piece at a time, so that a unit costs at most 0.87K gas.
const (
	substepWork  = 700
	moveWork     = 15
	barWork      = 12
	broadWork    = 18
	wallTestWork = 130
	postTestWork = 50
	zoneWork     = 20
	inWork       = 25
	edgeWork     = 14
	roundWork    = 12
	pushWork     = 50
	rootWork     = 200
	unstickWork  = 5
)

// MaxWorkStep is the most a stroke's Work passes its limit (MaxWork, or a
// lower Cap) by on a Decode-limited field: the most between two checks.
// Golf holds a shot to its limit plus this (shotBound).
const MaxWorkStep = 225000

// limit is the work the stroke may cost: MaxWork, or the field's Cap under it.
func (f *Field) limit() int {
	if f.Cap > 0 && f.Cap < MaxWork {
		return f.Cap
	}
	return MaxWork
}

// maxHits is the most contacts one move resolves (a corner meets two).
const maxHits = 4

// Shot is everything a stroke did: where the ball was at every substep, and
// how many walls and posts it met. A renderer replays Path and never
// simulates; two consecutive points far apart are a tunnel, not a line to
// interpolate.
type Shot struct {
	Path    []Vec2
	Bounces int
	// Air marks the path points where the ball is off the ground (no zone
	// acts, no cup takes it). Same length as Path.
	Air []bool
	// Cause says, per path point, what most acted on the ball in the substep
	// that ended there: 'b' a bounce, 's' a hill, 'w' wind or a gust, 'i' a
	// slippery surface, '-' nothing but friction. Same length as Path.
	Cause []byte
	why   byte // this substep's cause so far
	// Work is what the stroke cost, in MaxWork's units.
	Work int
	// start is where the stroke was played from, where a hazard sends it.
	start Vec2
}

func (s *Shot) add(p Vec2, air bool) {
	s.Path = append(s.Path, p)
	s.Air = append(s.Air, air)
	s.Cause = append(s.Cause, '-')
}

// mark records c as this substep's cause if it outranks what is there.
func (s *Shot) mark(c byte) {
	if strings.IndexByte(causes, c) > strings.IndexByte(causes, s.why) {
		s.why = c
	}
}

// causes is the Cause letters, weakest first.
const causes = "-iwsb"

// The loop's mouth: a ball heading in within 45° (loopIn, cos 45°) enters,
// one more than 25° off straight (loopStraight, cos 25°) is set down loopDrop
// in front, loopFront outside the mouth; one too slow rolls back out at
// loopBack of its speed.
const (
	loopIn       = 0.7071
	loopStraight = 0.9063
	loopFront    = 0.01
	loopDrop     = 1.5
	loopBack     = 0.5
)

// Rest is where the ball stopped.
func (s Shot) Rest() Vec2 {
	if len(s.Path) == 0 {
		return Vec2{}
	}
	return s.Path[len(s.Path)-1]
}

// MaxMove is the longest single move inside a substep. Zones are sampled once
// per move, so a zone must be at least this deep along the way a ball crosses
// it, or a fast ball can step over it unseen.
const MaxMove = 1.5

// SpeedCap is the fastest a ball may go, in board units per substep, held at
// the start of every substep and after every bounce: it bounds a substep to
// 6 moves, even between two bumpers or down a slope on ice.
const SpeedCap = 8

// Step rolls a ball through the field until it comes to rest or runs out of
// substeps (and past them while a slope keeps it rolling or it is still in
// the air, see MaxRollOn). With a Radius, the ball meets walls and posts with
// its edge. Cost is O(moves * (walls + posts + zones)), paid on every shot.
func (f *Field) Step(pos, vel Vec2, substeps int) Shot {
	out := Shot{Path: make([]Vec2, 0, substeps+2), Air: make([]bool, 0, substeps+2), start: pos}
	out.add(pos, false)
	air := 0.0 // substeps left in the air; 0 on the ground
	vz := 0.0  // the vertical speed the ball took off (or bounced) with
	hop := 0.0 // a landing's rebound, up again once the zones under it are met

	// wall offsets once per shot (or per hole, Prepare), never per move
	offs := f.offsets()
	bars := f.timedBars()
	slopes := f.groundSlopes()

	extra := 0 // substeps rolled on past the stroke's (MaxRollOn)
	// the hill being climbed, and how far up it the climb began
	var ramp *hill
	rampFrom, from := 0.0, pos
	// rolling on, a ball a slope pins against a wall only jitters: it stops
	// once it has not got anywhere in pinCheck substeps
	base, anchor := substeps, pos
	// the rolling deceleration the ball meets, per substep: where it starts,
	// then the last substep's
	drag := f.resistance(slopes, pos, f.Tick, &out.Work)
	limit := f.limit()
	for i := 0; i < substeps; i++ {
		tick := i + f.Tick
		if out.Work > limit {
			break // spent: the ball stops where the last substep left it
		}
		if i >= base && (i-base)%pinCheck == 0 {
			if i > base && air <= 0 && pos.Sub(anchor).Len() < pinMove {
				break
			}
			anchor = pos
		}
		if i == substeps-1 && f.rollsOn(extra, air, 0, slopes, pos, &out.Work) { // hop 0: the check at the substep's end sees a pending one
			substeps++
			extra++
		}
		// A timed bar that comes back (or stands, on the first substep) on
		// the ball pushes it out (UnstickIn). Every bar is pushed before the
		// work is checked, so a stroke never ends inside one.
		out.Work += barWork * len(bars)
		for _, j := range bars {
			w := &f.Walls[j]
			if There(tick, w.Every, w.On, w.Phase) && (i == 0 || !There(tick-1, w.Every, w.On, w.Phase)) {
				pos = UnstickIn(pos, f.Walls[j:j+4], nil, f.Radius, f.Walls)
				out.Work += 4 * unstickWork * len(f.Walls)
			}
		}
		spent := out.Work > limit
		if spent {
			if pos != out.Rest() {
				out.add(pos, false)
			}
			break
		}
		// moves of at most MaxMove, so a fast ball meets every zone and wall
		// it crosses; the path still gets one point per substep
		speed := vel.Len()
		if speed > SpeedCap {
			vel, speed = vel.Scale(SpeedCap/speed), SpeedCap
		}
		// Rolling resistance as two half-kicks around the moves (velocity
		// Verlet, so a ball rolls v²/2a), the first at the last substep's
		// deceleration. It never reverses the ball: it stops it.
		if air <= 0 && hop <= 0 {
			if dv := drag / 2; speed > dv {
				vel, speed = vel.Scale((speed-dv)/speed), speed-dv
			} else {
				vel, speed = Vec2{}, 0
				// at rest where no hill can move it, it stays (no creeping)
				if !f.rolls(slopes, pos, tick, &out.Work) {
					if pos != out.Rest() {
						out.add(pos, false) // where a timed bar put it
					}
					break
				}
			}
		}
		n := int(speed/MaxMove) + 1
		dt := 1 / float64(n)
		roll := 0.0 // the rolling deceleration, summed over the moves on the ground
		out.why = '-'
		for k := 0; k < n; k++ {
			if out.Work > limit {
				spent = true // the stroke has cost all it may: it ends here
				break
			}
			out.Work += moveWork
			// in the air no zone acts: the ball flies over water, sand, a
			// tunnel's mouth
			var up *hill
			if air <= 0 {
				// grass unless a zone under this move says otherwise
				surface := 1.0
				var under *hill
				if f.zonesAt(&pos, &vel, &surface, &under, slopes, n, tick, &out) {
					return out
				}
				if surface > 1 {
					out.mark('i')
				}
				if hop > 0 {
					// a landing's rebound, once the ground had its say
					// (water under it still catches it)
					vz, air, hop = hop, 2*hop/G, 0
				} else {
					c := 1.0
					if under != nil {
						c = under.cos
					}
					roll += Rolling(f.Friction, surface) * G * c
				}
				up = under
				if up != nil && vel.Dot(up.z.Vec) >= 0 {
					up = nil // on the hill, but not climbing it
				}
				if up != ramp {
					// a new climb counts from where the ball came onto the hill
					ramp = up
					if up != nil {
						rampFrom = up.along(from)
					}
				}
			}
			from = pos

			// contact to contact: a hit spends the rest of the move from there
			hit, left := false, 1.0
			for h := 0; h < maxHits && left > 0; h++ {
				if out.Work > limit {
					break // spent: the ball stops where it is
				}
				move := vel.Scale(left * dt)
				next := pos.Add(move)
				best, normal, bounce, ok := f.sweep(offs, pos, next, move, tick, &out)
				if !ok {
					pos = next
					break
				}
				const skin = 1e-6
				pos = pos.Add(move.Scale(best)).Add(normal.Scale(skin))
				var impact bool
				vel, impact = contact(vel, normal, bounce)
				out.Work += rootWork // contact's
				if vel.LenCmp(SpeedCap) > 0 {
					out.Work += rootWork
					vel = vel.Scale(SpeedCap / vel.Len()) // two bumpers facing each other
				}
				if impact {
					out.Bounces++
					out.mark('b')
				}
				hit = true
				left *= 1 - best
			}
			if air > 0 {
				if air -= dt; air <= 0 {
					// landing: restitution up, Coulomb friction along
					air = 0
					j := (1 + GroundBounce) * vz
					if l := vel.Len(); l > 0 {
						dv := LandFriction * j
						if s := TangentMass * l; dv > s {
							dv = s
						}
						vel = vel.Scale((l - dv) / l)
					}
					if vz *= GroundBounce; vz > HopSpeed {
						hop = vz
					}
				}
			} else if up != nil && !hit && !f.climbs(slopes, pos, vel, tick, &out.Work) && up.overTheTop(from, pos, rampFrom, &out.Work) {
				// over the crest faster than its curve holds: take off
				if vu := vel.Dot(up.u); vu > 0 && vu*vu > G*CrestRadius {
					vz = vu * up.tan
					air = 2 * vz / G
				}
			}
		}
		out.add(pos, air > 0)
		out.Cause[len(out.Cause)-1] = out.why
		if spent {
			break
		}
		// airborne, a landing to bounce, or onto a hill by now: go on too
		if i == substeps-1 && f.rollsOn(extra, air, hop, slopes, pos, &out.Work) {
			substeps++
			extra++
		}
		out.Work += substepWork
		if air > 0 || hop > 0 {
			drag = 0
			continue // no rolling resistance off the ground
		}

		// the second half-kick, at the moves' mean deceleration on the ground
		drag = roll * dt
		l := vel.Len()
		if dv := drag / 2; l > dv {
			vel = vel.Scale((l - dv) / l)
			continue
		}
		vel = Vec2{}
		// on a hill steeper than its resistance, it rolls back next substep
		if f.rolls(slopes, pos, tick+1, &out.Work) {
			continue
		}
		break
	}

	// a ball at rest is on the ground, whatever was left of its flight
	out.Air[len(out.Air)-1] = false
	// a ball at rest in water or a tunnel's mouth is resolved now
	var still Vec2
	surface := 1.0
	var under *hill
	if f.zonesAt(&pos, &still, &surface, &under, slopes, 1, substeps+f.Tick, &out) {
		return out
	}
	// a ball at rest in a timed hazard or tunnel meets it whatever the tick:
	// it would be there when it next comes on
	for j := range f.Zones {
		z := &f.Zones[j]
		out.Work += zoneWork
		if z.Every <= 0 || z.On <= 0 || (z.Kind != Hazard && z.Kind != Tunnel) || !z.in(pos, &out.Work) {
			continue
		}
		if z.Kind == Hazard {
			out.add(out.start, false)
			return out
		}
		pos = z.Vec
		out.add(pos, false)
	}
	return out
}

// contact applies the contact impulse to vel against a surface of unit
// normal n (toward the ball): restitution along n, Coulomb friction along
// the surface. It reports an impact (not a resting contact).
func contact(vel, n Vec2, bounce float64) (Vec2, bool) {
	vn := vel.Dot(n)
	if !(vn < 0) {
		return vel, false // not moving into it
	}
	e := bounce
	if e > 1 {
		if e > MaxKick {
			e = MaxKick
		}
	} else if e > MaxBounce {
		e = MaxBounce
	}
	impact := -vn >= RestSpeed
	if !impact {
		e = 0
	}
	jn := -(1 + e) * vn // the normal impulse, per unit mass
	vt := vel.Sub(n.Scale(vn))
	if lt := vt.Len(); lt > 0 {
		jt := WallFriction * jn
		if s := TangentMass * lt; jt > s {
			jt = s
		}
		vt = vt.Scale((lt - jt) / lt)
	}
	return vt.Add(n.Scale(-e * vn)), impact
}

// sweep is the first wall or post the move pos→next meets: how far along it
// (0 to 1), the surface's normal there (toward the ball), and its bounce.
func (f *Field) sweep(offs []offset, pos, next, move Vec2, tick int, out *Shot) (float64, Vec2, float64, bool) {
	const skin = 1e-6
	out.Work += broadWork * (len(offs) + len(f.Posts))
	// broad phase: skip a wall or post whose box the move's box misses
	lo, hi := pos, next
	if lo.X > hi.X {
		lo.X, hi.X = hi.X, lo.X
	}
	if lo.Y > hi.Y {
		lo.Y, hi.Y = hi.Y, lo.Y
	}
	best, normal, restitution, hit := 1.0, Vec2{}, f.Bounce, false
	for j := range offs {
		o := &offs[j]
		if o.hi.X < lo.X || o.lo.X > hi.X || o.hi.Y < lo.Y || o.lo.Y > hi.Y {
			continue
		}
		if !There(tick, o.every, o.on, o.phase) {
			continue // a timed wall that is not there this substep
		}
		out.Work += wallTestWork
		side := pos.Sub(o.a).Dot(o.n)
		seg, sn, facing := o.plus, o.pn, o.n
		if side < 0 {
			seg, sn, facing = o.minus, o.mn, o.n.Scale(-1)
		}
		// Already within the radius (a corner, a wall that moved onto the
		// ball): the offset line is behind it, so meet the wall now.
		if f.Radius > 0 {
			d := side
			if d < 0 {
				d = -d
			}
			if d <= f.Radius+skin/2 {
				along := Vec2{o.n.Y, -o.n.X}
				u := pos.Sub(o.a).Dot(along) // along the wall, from A toward B
				if u >= 0 && u <= o.length {
					if move.Dot(facing) < 0 {
						best, normal, hit = 0, facing, true
						restitution = o.bounce
					}
					continue
				}
				// past an end, the ball meets the end point, not the face
				// (whose normal points across a corner's next wall):
				// touching it, push back from it; else sweep it as a cap
				end := o.a
				if u > o.length {
					end = o.a.Add(along.Scale(o.length))
				}
				rv := pos.Sub(end)
				out.Work += rootWork
				if l := rv.Len(); l > 0 && l <= f.Radius+skin/2 {
					if nrm := rv.Scale(1 / l); move.Dot(nrm) < 0 {
						best, normal, hit = 0, nrm, true
						restitution = o.bounce
					}
				} else if t, nn, ok := (Circle{C: end, R: f.Radius}).hit(pos, next, &out.Work); ok && t < best {
					best, normal, hit = t, nn, true
					restitution = o.bounce
				}
				continue
			}
		}
		if t, nn, ok := seg.hitN(pos, next, sn); ok && t < best {
			best, normal, hit = t, nn, true
			restitution = o.bounce
		}
		// the offset lines' square ends leave a gap at an acute corner's
		// tip: sweep both ends as round caps too (inside the square ones)
		if f.Radius > 0 && o.length > 0 {
			along := Vec2{o.n.Y, -o.n.X}
			for _, end := range [2]Vec2{o.a, o.a.Add(along.Scale(o.length))} {
				if t, nn, ok := (Circle{C: end, R: f.Radius}).hit(pos, next, &out.Work); ok && t < best {
					best, normal, hit = t, nn, true
					restitution = o.bounce
				}
			}
		}
	}
	for j := range f.Posts {
		p := &f.Posts[j]
		c := p.Circle
		c.R += f.Radius
		if reach := c.R + boxPad; c.C.X+reach < lo.X || c.C.X-reach > hi.X || c.C.Y+reach < lo.Y || c.C.Y-reach > hi.Y {
			continue
		}
		out.Work += postTestWork
		if t, nn, ok := c.hit(pos, next, &out.Work); ok && t < best {
			best, normal, hit = t, nn, true
			restitution = bounceOf(p.Bounce, f.Bounce, p.Skin)
		}
	}
	return best, normal, restitution, hit
}

// zonesAt applies the zones the ball is in, and reports whether one ended
// the shot. The first ground Slope there is the hill (left in *under);
// moving air pushes on top of it.
func (f *Field) zonesAt(pos, vel *Vec2, surface *float64, under **hill, slopes []hill, n, tick int, out *Shot) bool {
	*under = nil
	hk := 0 // the next hill of slopes, in field order
	for j := range f.Zones {
		z := &f.Zones[j]
		ground := z.Kind == Slope && !z.Air
		var h *hill
		if ground {
			if hk < len(slopes) {
				h = &slopes[hk]
			}
			hk++
		}
		out.Work += zoneWork
		if !There(tick, z.Every, z.On, z.Phase) || !z.in(*pos, &out.Work) {
			continue
		}
		switch z.Kind {
		case Surface:
			*surface = z.Scale // the surface under this move (the last listed wins)
		case Slope:
			if ground {
				if *under != nil || h == nil {
					continue // already on a hill: the first one is the ground
				}
				*under = h
				out.mark('s')
				out.Work += pushWork
				*vel = vel.Add(z.Vec.Scale(1 / float64(n)))
				continue
			}
			out.mark('w')
			out.Work += pushWork
			wind := z.Capped
			v2 := 0.0
			if wind {
				v2 = vel.Dot(*vel)
			}
			*vel = vel.Add(z.Vec.Scale(1 / float64(n)))
			// capped wind never speeds the ball up (on ice it would keep a
			// ball drifting); squared first, rooted only when it did
			if l2 := vel.Dot(*vel); wind && l2 > v2 {
				out.Work += 2 * rootWork // two roots
				if v0, l := math.Sqrt(v2), math.Sqrt(l2); l > v0 {
					if v0 == 0 {
						*vel = Vec2{}
					} else {
						*vel = vel.Scale(v0 / l)
					}
				}
			}
		case Tunnel:
			*pos = z.Vec
			out.add(*pos, false)
		case Hazard:
			out.add(out.start, false) // back where the stroke was played from
			return true
		case Loop:
			// decided at once: the ball is put out of the mouth, so it never
			// has to remember being inside
			axis, sign := Vec2{1, 0}, 1.0
			mid := z.Min.Add(z.Max).Scale(0.5)
			if math.Abs(z.Vec.Y-mid.Y) > math.Abs(z.Vec.X-mid.X) {
				axis = Vec2{0, 1}
			}
			if z.Vec.Dot(axis) < mid.Dot(axis) {
				sign = -1
			}
			in := axis.Scale(sign) // the way into the loop
			out.Work += rootWork
			sp := vel.Len()
			if vel.Dot(in) <= sp*loopIn {
				continue // not heading into the mouth: it rolls across
			}
			// more than 25° off straight
			slanted := vel.Dot(in) <= sp*loopStraight
			front := z.Min.Dot(axis) - loopFront
			if sign < 0 {
				front = z.Max.Dot(axis) + loopFront
			}
			side := pos.Sub(axis.Scale(pos.Dot(axis)))
			switch {
			case slanted:
				// off the side of the track: down in front of the mouth, still
				*pos = mid.Sub(axis.Scale(mid.Dot(axis))).Add(axis.Scale(front - sign*loopDrop))
				out.add(*pos, false)
				return true
			case sp >= z.Scale:
				*pos = z.Vec
				*vel = in.Scale(sp * LoopKeep)
			default:
				*pos = side.Add(axis.Scale(front))
				*vel = vel.Scale(-loopBack)
			}
			out.add(*pos, false)
		}
	}
	return false
}

// bounceOf is the Bounce a piece plays: its own, or the field's (def), and
// above 1 only for a bumper (Kicks); any other plays MaxBounce.
func bounceOf(b, def float64, skin string) float64 {
	if b = orDefault(b, def); b > 1 && !Kicks(skin) {
		return MaxBounce
	}
	return b
}

// Kicks reports whether a piece of this skin may kick the ball back faster
// than it came (a Bounce above 1). Every other piece is passive.
func Kicks(skin string) bool {
	return strings.Contains(skin, "bumper") || strings.Contains(skin, "pinball") || strings.Contains(skin, "mushroom")
}

func orDefault(v, def float64) float64 {
	if v == 0 {
		return def
	}
	return v
}

// hill is a ground slope: its steepness g = |Vec| (G·sin θ), cos θ, tan θ,
// u the unit uphill, and its crest, the zone's edge u mostly points at.
type hill struct {
	z        *Zone
	g        float64
	cos, tan float64
	u        Vec2
	onX      bool    // the crest is an edge across X (u mostly along X)
	crest    float64 // where it is, on that axis
	foot     float64 // the opposite edge, where a climb starts
	depth    float64 // foot to crest
	upward   float64 // +1 when uphill runs toward +X (or +Y), -1 the other way
}

func newHill(z *Zone) hill {
	h := hill{z: z, g: z.Vec.Len(), cos: 1}
	if h.g == 0 {
		return h // decor: never climbed
	}
	sin := h.g / G
	if sin > MaxSin {
		sin = MaxSin
	}
	h.cos = math.Sqrt(1 - sin*sin)
	h.tan = sin / h.cos
	h.u = z.Vec.Scale(-1 / h.g)
	h.onX = math.Abs(h.u.X) >= math.Abs(h.u.Y)
	lo, hi, dir := z.Min.Y, z.Max.Y, h.u.Y
	if h.onX {
		lo, hi, dir = z.Min.X, z.Max.X, h.u.X
	}
	h.crest, h.foot, h.upward = hi, lo, 1
	if dir < 0 {
		h.crest, h.foot, h.upward = lo, hi, -1
	}
	h.depth = hi - lo
	return h
}

// along is how far up the hill p is from its foot (0 at the foot or below).
func (h *hill) along(p Vec2) float64 {
	c := p.Y
	if h.onX {
		c = p.X
	}
	if d := (c - h.foot) * h.upward; d > 0 {
		return d
	}
	return 0
}

// JumpRun is the share of a hill's depth a ball must have climbed to take off
// at its top: one that only clipped the hill near its crest has not ridden it.
const JumpRun = 0.5

// overTheTop reports whether the move a→b left the hill through its crest
// (not a side or its foot) after climbing at least JumpRun of it from
// rampFrom. A hill no steeper than MinRamp launches nothing.
func (h *hill) overTheTop(a, b Vec2, rampFrom float64, w *int) bool {
	if h.g <= MinRamp || h.z.in(b, w) {
		return false
	}
	ac, bc, oa, ob := a.Y, b.Y, a.X, b.X
	lo, hi := h.z.Min.X, h.z.Max.X
	if h.onX {
		ac, bc, oa, ob = a.X, b.X, a.Y, b.Y
		lo, hi = h.z.Min.Y, h.z.Max.Y
	}
	if (bc-h.crest)*h.upward < 0 || ac == bc {
		return false // it did not get past the crest's line
	}
	// where the move crosses the crest's line must be on the crest
	if o := oa + (h.crest-ac)/(bc-ac)*(ob-oa); o < lo || o >= hi {
		return false
	}
	return h.depth-rampFrom >= JumpRun*h.depth
}

// groundSlopes is the field's hills, in field order, measured once per shot.
func (f *Field) groundSlopes() []hill {
	var out []hill
	for j := range f.Zones {
		// air is no hill; a timed hill counts while it is there
		if z := &f.Zones[j]; z.Kind == Slope && !z.Air {
			out = append(out, newHill(z))
		}
	}
	return out
}

// ground is the hill under the ball at tick, as zonesAt has it; nil off
// every hill. A tick below 0 asks for the untimed hills only.
func (f *Field) ground(slopes []hill, pos Vec2, tick int, w *int) *hill {
	for j := range slopes {
		s := &slopes[j]
		*w += zoneWork
		if (tick < 0 && s.z.Every > 0) || (tick >= 0 && !There(tick, s.z.Every, s.z.On, s.z.Phase)) {
			continue
		}
		if s.z.in(pos, w) {
			return s
		}
	}
	return nil
}

// climbs reports whether the ball is moving up the hill under it.
func (f *Field) climbs(slopes []hill, pos, vel Vec2, tick int, w *int) bool {
	h := f.ground(slopes, pos, tick, w)
	return h != nil && vel.Dot(h.z.Vec) < 0
}

// resistance is the rolling deceleration Crr·G·cos θ at pos at tick. A tick
// below 0 asks for the untimed zones only.
func (f *Field) resistance(slopes []hill, pos Vec2, tick int, w *int) float64 {
	t := tick
	if t < 0 {
		t = 0
	}
	surface := 1.0
	for j := range f.Zones {
		*w += zoneWork
		if z := &f.Zones[j]; z.Kind == Surface && (tick >= 0 || z.Every <= 0) && There(t, z.Every, z.On, z.Phase) && z.in(pos, w) {
			surface = z.Scale
		}
	}
	c := 1.0
	if h := f.ground(slopes, pos, tick, w); h != nil {
		c = h.cos
	}
	return Rolling(f.Friction, surface) * G * c
}

// rollsOn says whether a stroke on its last substep goes on for one more:
// in the air, a landing to bounce (hop), or on a hill that rolls it.
func (f *Field) rollsOn(extra int, air, hop float64, slopes []hill, pos Vec2, w *int) bool {
	return extra < MaxRollOn && (air > 0 || hop > 0 || f.rolls(slopes, pos, -1, w))
}

// rolls reports whether a ball at rest at pos rolls away at tick (G·sin θ
// above Crr·G·cos θ). A tick below 0 asks for the untimed hills only: a
// rocking plank would roll a ball on for all MaxRollOn substeps.
func (f *Field) rolls(slopes []hill, pos Vec2, tick int, w *int) bool {
	h := f.ground(slopes, pos, tick, w)
	return h != nil && h.g > f.resistance(slopes, pos, tick, w)
}

// in is contains, adding what the test costs to *w (zoneWork is the
// caller's); every polygon edge is charged as if it straddled p.
func (z *Zone) in(p Vec2, w *int) bool {
	if p.X < z.Min.X || p.X >= z.Max.X || p.Y < z.Min.Y || p.Y >= z.Max.Y {
		return false
	}
	*w += inWork
	if len(z.Poly) >= 3 {
		*w += edgeWork * len(z.Poly)
	} else if z.Round {
		*w += roundWork
	}
	return z.contains(p)
}
