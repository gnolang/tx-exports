// Package physics is the Spot Kick penalty engine: a port of the browser
// game's gno-shots/src/physics.js that produces bit-identical results.
//
// The JavaScript engine uses only + - * /, square roots, comparisons and
// 32-bit integer mixing inside its simulation, all of which IEEE-754 rounds
// exactly; gno does float64 arithmetic in software with the same rounding,
// and its math.Sqrt is correctly rounded. So the same inputs give the same
// bits here as in any browser, provided every operation happens in the same
// order. That is the rule this file follows, line by line:
//
//   - every float constant is a variable, never a Go constant: constant
//     expressions are folded at arbitrary precision, JavaScript rounds after
//     each operation;
//   - expressions keep the JavaScript order and grouping;
//   - JavaScript's Math.min, Math.max and Math.round are reproduced exactly
//     (jsMin, jsMax, jsRound), down to the sign of zero.
//
// Unlike the browser, which keeps simulating for the replay, Simulate stops
// as soon as the kick is decided; nothing after that can change the verdict.
package physics

import "math"

// ---------------------------------------------------------------- constants

var (
	negInf  = math.Inf(-1)
	negZero = math.Copysign(0, -1)

	simDT   = 0.001
	simMaxT = 2.5
	simG    = 9.81

	ballR         = 0.11
	ballM         = 0.43
	ballEGround   = 0.55
	ballGroundKep = 0.85
	ballMinBounce = 1.0
	ballRollDecel = 1.2
	ballSpinDecay = 0.05
	ballI         float64

	airRho  = 1.2
	airCD   = 0.25
	airCL   = 1.0
	area    float64
	dragK   float64
	magnusK float64

	goalZ       = -11.0
	postR       = 0.06
	goalDepth   = 2.0
	ePost       = 0.7
	netKs       = 2500.0
	netCs       = 40.0
	netRecoil   = 0.1
	netFriction = 3.0
	boardsZ     = -16.0
	boardsH     = 1.0
	boardsHW    = 30.0
	netBackZ    float64

	kickNormalMix = 0.18
	kickSideSpin  = 0.6
	kickBackSpin  = 0.25
	kickMaxSpin   = 110.0
	kickMaxStrike = 0.8
	kickAimX      = 6.0
	kickAimY      = 4.0

	kLineOffset    = 0.25
	kHipFactor     = 0.93
	kPushTime      = 0.12
	kLeanRate      = 8.0
	kArmRate       = 10.0
	kLeanBias      = -0.3
	kLeanMin       = 0.15
	kSlideDecel    = 8.0
	kStarSpeed     = 1.2
	kEGlove        = 0.25
	kEBody         = 0.45
	kFriction      = 0.3
	kShoulderX     = 0.24
	kShoulderY     = 0.5
	kArmLen        = 0.62
	kGloveReach    = 0.73
	kGloveR        = 0.125
	kReachPivot    = 1.8
	kReachSpan     = 2.6
	kPerceive      = 0.16
	kArmTrackRate  = 12.0
	kReadEvery     = 20
	kReadBase      = 0.16
	kReadReach     = 0.75
	kReadHeightGn  = 2.2
	kReadShuffleT  = 0.45
	kMisreadX      = [2]float64{0.05, 1.2}
	kMisreadY      = [2]float64{0.04, 0.5}
	kMisreadT      = [2]float64{0.18, 0.28}
	kMisjudgeVX    = [2]float64{0.12, 0.6}
	kMisjudgeJump  = [2]float64{0.12, 0.6}
	kPlantExtra    = 0.08
	kPlantStretch  = 1.15
	kRecoverDelay  = 0.08
	kHoldDownT     = 0.3
	kRecoverLeanRt = 9.0
	kRecoverSpeed  = 2.6
	kRecoverAccel  = 9.0
	kRediveWindow  = 0.38
	kRediveMinDX   = 0.45
	kMaxCommits    = 2
	kCatchMin      = 9.0
	kCatchMax      = 25.0
	kHandsGap      = 0.14
	kHandsSpan     = 0.32
	kBodyNear      = 0.25
	kBodyFar       = 0.8
	kHandsWeight   = 0.65
	kHoldPull      = 25.0
	kTouchGap      = 0.08
	kMarginGlove   = 0.03
	kMarginArm     = 0.02
	kMarginTorso   = 0.02
	kMarginLeg     = 0.02
	kMarginHead    = 0.01
	kReactSpeed    = 12.0
	kReactReach    = 0.12
	kGatherSpeed   = 7.5
	kOneHandMax    = 13.0
	kLowDropSpeed  = 1.8
	kGiveHands     = 36.0
	kGiveGlove     = 31.0
	kGiveArm       = 14.0
	kGiveTorso     = 30.0
	kGiveHead      = 30.0
	kGiveLeg       = 32.0
	kGiveLegInAir  = 26.0
	kReflexBody    = 0.25
	kFingertipGive = 0.75
	kParryControl  = 16.0
	kParryOut      = 3.0
	kParryWide     = 2.0
	kHandLateMax   = 0.07
	kHandLateRate  = 0.25
	kPounceSpeed   = 3.0
	kPounceReach   = 1.8
	kPounceHeight  = 2.2
	kPounceDelay   = 0.2
	kPounceNear    = 0.9
	kPounceMove    = 3.0

	planForwardMax  = 22.0
	planCentreShare = 0.06
	planStarMaxSpd  = 1.15

	halfPi = 1.5707963267948966
	pi     = 3.141592653589793
	twoPi  = 6.283185307179586
	sqrt2  = 1.4142135623730951

	armsReady, armsStar, armsHold armPair
	zeroVec                       vec
	upVec                         vec
)

func init() {
	two, three := 2.0, 3.0
	ballI = (two / three) * ballM * ballR * ballR
	area = pi * ballR * ballR
	dragK = (0.5 * airRho * airCD * area) / ballM
	magnusK = (0.5 * airRho * airCL * area * ballR) / ballM
	netBackZ = goalZ - goalDepth
	upVec = vec{0, 1, 0}
	armsReady = armPair{norm(vec{-0.55, -0.45, 0.7}), norm(vec{0.55, -0.45, 0.7})}
	armsStar = armPair{norm(vec{-0.9, 0.6, 0.15}), norm(vec{0.9, 0.6, 0.15})}
	armsHold = armPair{norm(vec{0.18, 0.12, 0.95}), norm(vec{-0.18, 0.12, 0.95})}
}

// Params are the constants a game may change (penalty.Config, in SI units).
// DefaultParams are the browser engine's.
type Params struct {
	GoalHalfWidth float64 // m
	GoalHeight    float64 // m
	KeeperScale   float64
	ReactionMin   float64 // s
	ReactionMax   float64
	StarShare     float64 // of the speed range
	ReadShare     float64
	DiveMin       float64 // m/s
	DiveMax       float64
	JumpMin       float64 // m/s
	JumpMax       float64
	BallMinSpeed  float64 // m/s
	BallMaxSpeed  float64
	FuzzBase      float64 // ball radii
	FuzzPower     float64
	MaxContact    float64 // ball radii
}

// DefaultParams returns the constants of the browser engine.
func DefaultParams() Params {
	return Params{
		GoalHalfWidth: 3.2775, GoalHeight: 2.424, KeeperScale: 1.176,
		ReactionMin: 0.02, ReactionMax: 0.12, StarShare: 0.06, ReadShare: 0.24,
		DiveMin: 2.6, DiveMax: 5.2, JumpMin: -1.4, JumpMax: 4.0,
		BallMinSpeed: 10, BallMaxSpeed: 34, FuzzBase: 0.03, FuzzPower: 0.1, MaxContact: 0.5,
	}
}

// ------------------------------------------------------------- vector maths

type vec struct{ x, y, z float64 }

type armPair struct{ l, r vec }

func add(a, b vec) vec           { return vec{a.x + b.x, a.y + b.y, a.z + b.z} }
func sub(a, b vec) vec           { return vec{a.x - b.x, a.y - b.y, a.z - b.z} }
func scale(a vec, s float64) vec { return vec{a.x * s, a.y * s, a.z * s} }
func dot(a, b vec) float64       { return a.x*b.x + a.y*b.y + a.z*b.z }
func crossVec(a, b vec) vec {
	return vec{a.y*b.z - a.z*b.y, a.z*b.x - a.x*b.z, a.x*b.y - a.y*b.x}
}
func length(a vec) float64 { return fsqrt(dot(a, a)) }
func norm(a vec) vec {
	l := length(a)
	if l > 0 {
		return scale(a, 1/l)
	}
	return vec{0, 0, 0}
}

func clamp(x, lo, hi float64) float64 {
	if x < lo {
		return lo
	}
	if x > hi {
		return hi
	}
	return x
}

// jsMin and jsMax are Math.min and Math.max for two non-NaN numbers: of two
// zeros, min prefers -0 and max prefers +0.
func jsMin(a, b float64) float64 {
	if a < b {
		return a
	}
	if b < a {
		return b
	}
	if math.Signbit(b) {
		return b
	}
	return a
}

func jsMax(a, b float64) float64 {
	if a > b {
		return a
	}
	if b > a {
		return b
	}
	if !math.Signbit(b) {
		return b
	}
	return a
}

// jsRound is Math.round: the nearest integer, halves rounded up, and -0
// for -0.5 <= x <= -0.
func jsRound(x float64) float64 {
	f := floor(x)
	if x-f >= 0.5 {
		f++
	}
	if f == 0 {
		if x < 0 {
			return negZero
		}
		if math.Float64bits(x)>>63 != 0 {
			return negZero
		}
	}
	return f
}

// floor is math.Floor (gno's is interpreted and dear): below 2^52 in
// magnitude by truncation, keeping -0; beyond that, and for infinities and
// NaN, x itself.
func floor(x float64) float64 {
	if x < 4503599627370496 {
		if x > -4503599627370496 {
			f := float64(int64(x))
			if f > x {
				return f - 1
			}
			if f == 0 {
				return x * 0
			}
			return f
		}
	}
	return x
}

// detSin is the JavaScript engine's sine: range reduction and a Taylor series.
func detSin(x float64) float64 {
	x -= twoPi * jsRound(x/twoPi)
	if x > halfPi {
		x = pi - x
	} else if x < -halfPi {
		x = -pi - x
	}
	x2 := x * x
	term := x
	sum := x
	for n := 1; n <= 9; n++ {
		term *= -x2 / (float64(2*n) * float64(2*n+1))
		sum += term
	}
	return sum
}

func detCos(x float64) float64 { return detSin(x + halfPi) }

// ------------------------------------------------------------ seeded random

type mulberry struct{ a uint32 }

func (m *mulberry) next() float64 {
	m.a += 0x6d2b79f5
	t := m.a
	t = (t ^ (t >> 15)) * (t | 1)
	t ^= t + (t^(t>>7))*(t|61)
	return float64(t^(t>>14)) / 4294967296
}

func fnvBytes(h uint32, b []byte) uint32 {
	for _, c := range b {
		h ^= uint32(c)
		h *= 0x01000193
	}
	return h
}

func u16(b []byte, i int) uint16 { return uint16(b[i])<<8 | uint16(b[i+1]) }

// ------------------------------------------------------------------- plans

// Plan modes.
const (
	ModeStar = 1
	ModeRead = 2
	ModeDive = 3
)

// Plan is a keeper plan decoded from its four uint16.
type Plan struct {
	Raw       [4]uint16
	Mode      int
	Direction float64 // degrees: 0 = along the line to the taker's right, 180 = left
	Speed     float64 // m/s
	Jump      float64 // m/s
	Reaction  float64 // s
}

// DecodePlan maps four uint16 onto a plan exactly as the browser does.
func DecodePlan(raw [4]uint16, p Params) Plan {
	d := float64(raw[0]) / 65535
	sp := float64(raw[1]) / 65535
	j := float64(raw[2]) / 65535
	r := float64(raw[3]) / 65535
	pl := Plan{Raw: raw}
	switch {
	case sp < p.StarShare:
		pl.Mode = ModeStar
	case sp < p.StarShare+p.ReadShare:
		pl.Mode = ModeRead
	default:
		pl.Mode = ModeDive
	}
	pl.Direction = planDirection(d)
	pl.Speed = planSpeed(sp, p)
	pl.Jump = lin(j, p.JumpMin, p.JumpMax)
	pl.Reaction = lin(r, p.ReactionMin, p.ReactionMax)
	return pl
}

func lin(vv, lo, hi float64) float64 { return lo + (hi-lo)*vv }

func planDirection(vv float64) float64 {
	s := 2*vv - 1
	c := planCentreShare
	F := planForwardMax
	if s <= -c {
		return (F * (1 + s)) / (1 - c)
	}
	if s >= c {
		return 180 - (F*(1-s))/(1-c)
	}
	return 90 + ((90-F)*s)/c
}

func planSpeed(vv float64, p Params) float64 {
	k := p.StarShare
	r := k + p.ReadShare
	if vv < k {
		return (planStarMaxSpd * vv) / k
	}
	if vv < r {
		return 0
	}
	return lin((vv-r)/(1-r), p.DiveMin, p.DiveMax)
}

func (pl *Plan) commitTime() float64 {
	if pl.Mode == ModeRead {
		return kReadBase + pl.Reaction
	}
	return pl.Reaction
}

func launchVelocity(pl *Plan) vec {
	a := pl.Direction * (pi / 180)
	return vec{pl.Speed * detCos(a), pl.Jump, pl.Speed * detSin(a)}
}
