package physics

import "math"

// Outcomes.
const (
	Goal = 1
	Save = 2
	Miss = 3
	Post = 4
)

// Woodwork parts.
const (
	LeftPost  = 1
	RightPost = 2
	Crossbar  = 3
)

// Shot is the taker's input in the browser engine's units.
type Shot struct {
	AimX, AimY         float64 // m, point on the goal plane the swing heads for
	ContactX, ContactY float64 // ball radii
	Power              float64 // 0..1
	Mishit             [24]byte
	HasMishit          bool
}

// Launch is the ball as it leaves the boot.
type Launch struct {
	Vel, Spin          [3]float64
	Speed              float64
	FuzzX, FuzzY       float64 // contact error the mishit seed added, ball radii
	ContactX, ContactY float64 // where the boot actually met the ball
}

// Contact is one keeper touch, decided at its first contact.
type Contact struct {
	Step    int
	Part    int // index into PartNames
	Catch   bool
	GaveWay bool
}

// Result is a decided kick.
type Result struct {
	Outcome     int
	DecidedStep int     // the 1 kHz step it was decided in
	DecidedAt   float64 // s after contact
	Launch      Launch
	Touch       int // first part to touch the ball, -1 for none
	TouchStep   int
	Woodwork    int // first frame part it hit, 0 for none
	Caught      bool
	Pounced     bool // decided by the keeper pouncing on a loose ball
	Contacts    []Contact
	Commits     []Commit
	Misread     [4]float64 // the keeper's four normal draws (x, y, vx, jump)
	// Where the ball's centre first reached the goal line (rounded to the
	// millimetre, as the browser reports it), if it did.
	LineCross           bool
	LineT, LineX, LineY float64
	// Where it was when the whole ball was over the whole line, if it was.
	Crossing               bool
	CrossT, CrossX, CrossY float64
	EndX, EndY             float64 // the ball when the kick was decided, m
	Steps                  int
	Trace                  uint32 // see Options.Trace
}

// Options are for tests and analysis.
type Options struct {
	NoKeeper  bool // an empty goal
	NoMisread bool // a keeper that reads perfectly
	// Trace folds the state into Result.Trace every TraceEvery steps and at
	// the deciding step, for comparing with the browser engine bit for bit.
	Trace      bool
	TraceEvery int
}

type ball struct {
	p, v, w  vec
	grounded bool
	inGoal   bool
	held     bool
	sp       float64 // speed at the last drag evaluation (see ballSpeed)
}

// engine holds the constants derived from a game's Params.
type engine struct {
	p         Params
	body      [2]sideK
	headX     float64
	headY     float64
	headR     float64
	headH     float64
	zeroZ     float64
	scale     float64
	maxReach  float64
	standHipY float64
	netSideX  float64
	netRoofY  float64
	frame     [3]capsule

	// Per-game products the keeper's steps use, worked out once with the
	// browser's operations.
	shXL, shXR    float64 // kShoulderX * side * S, left and right
	shY           float64 // kShoulderY * S
	aimDZ, aimDZ2 float64 // 0.25 * S and its square: trackArms' forward offset
	gloveReachS   float64 // kGloveReach * S
	misT1, misTd  float64 // kMisreadT[1] and kMisreadT[1] - kMisreadT[0]
	misX0, misXd  float64 // lerpRange(kMisreadX, f) = misX0 + misXd*f
	misY0, misYd  float64
}

func newEngine(p Params) *engine {
	e := &engine{p: p, scale: p.KeeperScale}
	e.standHipY = kHipFactor * p.KeeperScale
	e.initBody()
	e.netSideX = p.GoalHalfWidth + postR
	e.netRoofY = p.GoalHeight + postR
	S := p.KeeperScale
	e.shXL, e.shXR = kShoulderX*-1.0*S, kShoulderX*1.0*S
	e.shY = kShoulderY * S
	e.aimDZ = 0.25 * S
	e.aimDZ2 = e.aimDZ * e.aimDZ
	e.gloveReachS = kGloveReach * S
	e.misT1, e.misTd = kMisreadT[1], kMisreadT[1]-kMisreadT[0]
	e.misX0, e.misXd = kMisreadX[0], kMisreadX[1]-kMisreadX[0]
	e.misY0, e.misYd = kMisreadY[0], kMisreadY[1]-kMisreadY[0]
	// The most any part reaches, plus the ball and a centimetre: the
	// thickest part's collision radius, slow-ball reaction and late hands.
	e.maxReach = ballR + jsMax(jsMax(0.14*p.KeeperScale+kMarginTorso, 0.08*p.KeeperScale+kMarginLeg),
		jsMax(kGloveR+kMarginGlove, 0.12*p.KeeperScale+kMarginHead)) + kReactReach + kHandLateMax + 0.01
	px := p.GoalHalfWidth + postR
	top := p.GoalHeight + postR
	e.frame = [3]capsule{
		{a: vec{-px, 0, goalZ}, b: vec{-px, top, goalZ}, r: postR, part: LeftPost},
		{a: vec{px, 0, goalZ}, b: vec{px, top, goalZ}, r: postR, part: RightPost},
		{a: vec{-px, top, goalZ}, b: vec{px, top, goalZ}, r: postR, part: Crossbar},
	}
	return e
}

// ---------------------------------------------------------------- the kick

type disc struct{ x, y float64 }

func clampDisc(x, y, max float64) disc {
	r2 := x*x + y*y
	if r2 <= max*max {
		return disc{x, y}
	}
	s := max / fsqrt(r2)
	return disc{x * s, y * s}
}

func mishitNormal(seed *[24]byte, offset int) float64 {
	sum := 0.0
	for i := 0; i < 6; i++ {
		sum += float64(u16(seed[:], offset+2*i)) / 65535
	}
	return (sum - 3) * sqrt2
}

const misreadSalt = 0x6b656570 // "keep"

func keeperMisread(seed *[24]byte) misread {
	m := mulberry{a: fnvBytes(0x811c9dc5^misreadSalt, seed[:])}
	normal := func() float64 {
		sum := 0.0
		for i := 0; i < 6; i++ {
			sum += m.next()
		}
		return (sum - 3) * sqrt2
	}
	x := normal()
	y := normal()
	vx := normal()
	jump := normal()
	return misread{on: true, x: x, y: y, vx: vx, jump: jump}
}

type launch struct {
	pos, vel, spin vec
	speed          float64
	fuzz           disc
	contact        disc
}

func (e *engine) computeLaunch(in *Shot) launch {
	pos := vec{0, ballR, 0}
	target := vec{clamp(in.AimX, -kickAimX, kickAimX), clamp(in.AimY, 0, kickAimY), goalZ}
	f := norm(sub(target, pos))
	right := norm(crossVec(f, upVec))
	up := crossVec(right, f)

	power := clamp(in.Power, 0, 1)
	intended := clampDisc(in.ContactX, in.ContactY, e.p.MaxContact)
	var fuzz disc
	if in.HasMishit {
		sigma := e.p.FuzzBase + e.p.FuzzPower*power
		fuzz.x = mishitNormal(&in.Mishit, 0) * sigma
		fuzz.y = mishitNormal(&in.Mishit, 12) * sigma
	}
	c := clampDisc(intended.x+fuzz.x, intended.y+fuzz.y, kickMaxStrike)
	cx, cy := c.x, c.y
	cz := fsqrt(1 - cx*cx - cy*cy)
	n := add(add(scale(right, cx), scale(up, cy)), scale(f, -cz))

	dir := norm(add(scale(f, 1-kickNormalMix), scale(n, -kickNormalMix)))
	quality := cz
	efficiency := 0.55 + 0.45*quality
	speed := (e.p.BallMinSpeed + (e.p.BallMaxSpeed-e.p.BallMinSpeed)*power) * efficiency
	vel := scale(dir, speed)

	rc := scale(n, ballR)
	dL := scale(crossVec(rc, scale(vel, ballM)), 1/ballI)
	side := dot(dL, up)
	backAxis := sub(dL, scale(up, side))
	spin := add(scale(up, side*kickSideSpin), scale(backAxis, kickBackSpin))
	sm := length(spin)
	if sm > kickMaxSpin {
		spin = scale(spin, kickMaxSpin/sm)
	}
	return launch{pos: pos, vel: vel, spin: spin, speed: speed, fuzz: fuzz, contact: c}
}

// ---------------------------------------------------------------- the ball

func rollingSpin(u vec) vec { return vec{u.z / ballR, 0, -u.x / ballR} }

func (e *engine) netAccel(b *ball) vec {
	p, u := b.p, b.v
	R := ballR
	K := netKs / ballM
	C := netCs / ballM
	ax, ay, az := 0.0, 0.0, 0.0
	touching := false
	panel := func(pen, vn float64) float64 {
		if pen <= 0 {
			return 0
		}
		touching = true
		k := K * netRecoil
		if vn < 0 {
			k = K
		}
		f := k*pen - C*vn
		if f > 0 {
			return f
		}
		return 0
	}
	az += panel(netBackZ-(p.z-R), u.z)
	ay -= panel(p.y+R-e.netRoofY, -u.y)
	sx := 1.0
	if p.x > 0 {
		sx = -1
	}
	ax += sx * panel(math.Abs(p.x)+R-e.netSideX, sx*u.x)
	if touching {
		ax -= netFriction * u.x
		ay -= netFriction * u.y
		az -= netFriction * u.z
	}
	return vec{ax, ay, az}
}

// ballSpeed is the ball's speed for drag: one Newton step from the speed of
// the previous evaluation while the speed has changed by under half a per
// cent, otherwise (the first step, after an impact) a square root.
func ballSpeed(b *ball, u vec) float64 {
	s2 := u.x*u.x + u.y*u.y + u.z*u.z
	s := b.sp
	d := s2 - s*s
	if s > 0 && d <= 0.01*s2 && d >= -0.01*s2 {
		return 0.5 * (s + s2/s)
	}
	return fsqrt(s2)
}

// heunBall is a free-flight step of dt (second-order Runge-Kutta), as the
// browser's: ballSpeed and airAccel written out.
func heunBall(b *ball, dt float64) {
	ux, uy, uz := b.v.x, b.v.y, b.v.z
	wx, wy, wz := b.w.x, b.w.y, b.w.z
	s2 := ux*ux + uy*uy + uz*uz
	sp := b.sp
	if q := sp; !(q > 0) {
		sp = fsqrt(s2)
	} else if d, lim := s2-q*q, 0.01*s2; d > lim {
		sp = fsqrt(s2)
	} else if d < -lim {
		sp = fsqrt(s2)
	} else {
		sp = 0.5 * (q + s2/q)
	}
	nk := -dragK * sp
	a1x := nk*ux + (wy*uz-wz*uy)*magnusK
	a1y := nk*uy - simG + (wz*ux-wx*uz)*magnusK
	a1z := nk*uz + (wx*uy-wy*ux)*magnusK
	vx, vy, vz := ux+a1x*dt, uy+a1y*dt, uz+a1z*dt
	f := 1 - ballSpinDecay*dt
	wx, wy, wz = wx*f, wy*f, wz*f
	s2 = vx*vx + vy*vy + vz*vz
	if q := sp; !(q > 0) {
		sp = fsqrt(s2)
	} else if d, lim := s2-q*q, 0.01*s2; d > lim {
		sp = fsqrt(s2)
	} else if d < -lim {
		sp = fsqrt(s2)
	} else {
		sp = 0.5 * (q + s2/q)
	}
	b.sp = sp
	nk = -dragK * sp
	a2x := nk*vx + (wy*vz-wz*vy)*magnusK
	a2y := nk*vy - simG + (wz*vx-wx*vz)*magnusK
	a2z := nk*vz + (wx*vy-wy*vx)*magnusK
	h := 0.5 * dt
	p := &b.p
	p.x += (ux + vx) * h
	p.y += (uy + vy) * h
	p.z += (uz + vz) * h
	b.v = vec{ux + (a1x+a2x)*h, uy + (a1y+a2y)*h, uz + (a1z+a2z)*h}
	b.w = vec{wx, wy, wz}
}

// integrateBall is the browser's semi-implicit Euler step, written out.
// (x += e rounds exactly as x = x + e, and is cheaper in gno.)
func (e *engine) integrateBall(b *ball, dt float64) {
	v := &b.v
	ux, uy, uz := v.x, v.y, v.z
	s2 := ux*ux + uy*uy + uz*uz
	sp := b.sp
	if q := sp; !(q > 0) {
		sp = fsqrt(s2)
	} else if d, lim := s2-q*q, 0.01*s2; d > lim {
		sp = fsqrt(s2)
	} else if d < -lim {
		sp = fsqrt(s2)
	} else {
		sp = 0.5 * (q + s2/q)
	}
	b.sp = sp
	nk := -dragK * sp
	ax, ay, az := nk*ux, nk*uy-simG, nk*uz
	grounded := b.grounded
	w := &b.w
	if !grounded {
		wx, wy, wz := w.x, w.y, w.z
		ax += (wy*uz - wz*uy) * magnusK
		ay += (wz*ux - wx*uz) * magnusK
		az += (wx*uy - wy*ux) * magnusK
	}
	if b.inGoal {
		n := e.netAccel(b)
		ax, ay, az = ax+n.x, ay+n.y, az+n.z
	}
	if grounded {
		if ay < 0 {
			ay = 0
		}
		if h := fsqrt(ux*ux + uz*uz); h > 0 {
			d := ballRollDecel // jsMin(ballRollDecel, h/dt), both positive
			if q := h / dt; q < d {
				d = q
			}
			ax -= (d * ux) / h
			az -= (d * uz) / h
		}
	}
	vx, vy, vz := ux+ax*dt, uy+ay*dt, uz+az*dt
	v.x, v.y, v.z = vx, vy, vz
	p := &b.p
	p.x += vx * dt
	p.y += vy * dt
	p.z += vz * dt
	if grounded {
		w.x, w.y, w.z = vz/ballR, w.y*(1-2*dt), -vx/ballR
	} else {
		f := 1 - ballSpinDecay*dt
		w.x *= f
		w.y *= f
		w.z *= f
	}
}

func groundContact(b *ball) float64 {
	if b.p.y >= ballR {
		return 0
	}
	b.p = vec{b.p.x, ballR, b.p.z}
	if b.v.y >= 0 {
		return 0
	}
	vy := -b.v.y
	if !b.grounded && vy > ballMinBounce {
		k := ballGroundKep
		b.v = vec{b.v.x * k, vy * ballEGround, b.v.z * k}
		b.w = add(scale(b.w, 0.5), scale(rollingSpin(b.v), 0.5))
		return vy
	}
	b.v = vec{b.v.x, 0, b.v.z}
	b.grounded = true
	return 0
}

type probe struct {
	ok       bool
	relSpeed float64
	dist     float64
}

func probeCapsule(b *ball, a, bb vec, r float64, va, vb vec) probe {
	ab := sub(bb, a)
	abab := dot(ab, ab)
	s := 0.0
	if abab > 0 {
		s = clamp(dot(sub(b.p, a), ab)/abab, 0, 1)
	}
	d := sub(b.p, add(a, scale(ab, s)))
	minD := ballR + r
	d2 := dot(d, d)
	if d2 >= minD*minD {
		return probe{}
	}
	dist := fsqrt(d2)
	n := vec{0, 0, 1}
	if dist > 1e-9 {
		n = scale(d, 1/dist)
	}
	sv := add(va, scale(sub(vb, va), s))
	rel := sub(b.v, sv)
	vn := dot(rel, n)
	if vn >= 0 {
		return probe{}
	}
	return probe{ok: true, relSpeed: length(rel), dist: dist}
}

type hit struct {
	ok          bool
	impactSpeed float64
	gaveWay     bool
}

// collideCapsule resolves the ball against a capsule moving with end
// velocities va, vb (nil in the browser for the goal frame: still). give < 0
// means the part never gives way (Infinity in the browser).
func collideCapsule(b *ball, a, bb vec, r float64, moving bool, va, vb vec, e, mu, spinKeep, give float64) hit {
	ab := sub(bb, a)
	abab := dot(ab, ab)
	s := 0.0
	if abab > 0 {
		s = clamp(dot(sub(b.p, a), ab)/abab, 0, 1)
	}
	q := add(a, scale(ab, s))
	d := sub(b.p, q)
	d2 := dot(d, d)
	minD := ballR + r
	if d2 >= minD*minD {
		return hit{}
	}
	dist := fsqrt(d2)
	n := vec{0, 0, 1}
	if dist > 1e-9 {
		n = scale(d, 1/dist)
	}
	sv := vec{0, 0, 0}
	if moving {
		sv = add(va, scale(sub(vb, va), s))
	}
	rel := sub(b.v, sv)
	vn := dot(rel, n)
	if vn >= 0 {
		b.p = add(q, scale(n, minD))
		return hit{}
	}
	relN := scale(n, vn)
	relT := sub(rel, relN)
	needed := -(1 + e) * vn
	if give >= 0 && needed > give {
		b.v = add(sv, add(scale(relT, 1-mu), scale(n, vn+give)))
		b.w = scale(b.w, spinKeep)
		return hit{ok: true, impactSpeed: -vn, gaveWay: true}
	}
	b.p = add(q, scale(n, minD))
	b.v = add(sv, sub(scale(relT, 1-mu), scale(relN, e)))
	b.w = scale(b.w, spinKeep)
	return hit{ok: true, impactSpeed: -vn}
}

// slowerThan is length(v) < s, taking the root only when it could be true.
func slowerThan(v vec, s float64) bool {
	d := v.x*v.x + v.y*v.y + v.z*v.z
	if d > s*s*1.01 {
		return false
	}
	return fsqrt(d) < s
}

// pounces reports whether the keeper gets to a loose ball before it is
// wholly over the line: slower than kPounceSpeed, within kPounceReach of the
// hips and below kPounceHeight, the keeper not mid-dive, and the ball needing
// longer to cross than the keeper needs to go down on it.
func pounces(k *keeper, b *ball) bool {
	if k.holding || k.phase == phasePush || k.phase == phaseAir || b.p.y > kPounceHeight {
		return false
	}
	dx, dy, dz := b.p.x-k.pos.x, b.p.y-k.pos.y, b.p.z-k.pos.z
	d2 := dx*dx + dy*dy + dz*dz
	if d2 >= kPounceReach*kPounceReach {
		return false
	}
	u := b.v
	if u.x*u.x+u.y*u.y+u.z*u.z >= kPounceSpeed*kPounceSpeed {
		return false
	}
	if u.z >= 0 {
		return true
	}
	// The keeper needs kPounceDelay plus the distance beyond kPounceNear at
	// kPounceMove: compared squared, as the browser does.
	over := goalZ - postR - ballR
	spare := (b.p.z-over)/-u.z - kPounceDelay
	if spare <= 0 {
		return false
	}
	reach := kPounceNear + spare*kPounceMove
	return d2 < reach*reach
}

// ------------------------------------------------------------ catch or parry

func segDist(p, a, b vec) float64 {
	ab := sub(b, a)
	abab := dot(ab, ab)
	s := 0.0
	if abab > 0 {
		s = clamp(dot(sub(p, a), ab)/abab, 0, 1)
	}
	return length(sub(p, add(a, scale(ab, s))))
}

func clamp01(x float64) float64 {
	if x < 0 {
		return 0
	}
	if x > 1 {
		return 1
	}
	return x
}

type decision struct {
	held   bool
	hands  float64
	toBody float64
}

func (e *engine) catchDecision(cs *caps, part *capsule, relSpeed float64, ballP vec) decision {
	S := e.scale
	gl := cs[3].a
	gr := cs[7].a
	mid := scale(add(gl, gr), 0.5)
	hx := ballP.x - mid.x
	hy := ballP.y - mid.y
	hands := 1 - clamp01((fsqrt(hx*hx+hy*hy)-kHandsGap*S)/((kHandsSpan-kHandsGap)*S))
	toBody := math.Inf(1)
	for i := range cs {
		if cs[i].kind == kindTorso {
			toBody = jsMin(toBody, segDist(ballP, cs[i].a, cs[i].b)-cs[i].r)
		}
	}
	body := 1 - clamp01((toBody-kBodyNear*S)/((kBodyFar-kBodyNear)*S))
	quality := kHandsWeight*hands + (1-kHandsWeight)*body
	limit := kCatchMin + (kCatchMax-kCatchMin)*quality
	if part.kind == kindGlove && hands < 0.5 {
		limit = jsMin(limit, kOneHandMax)
	}
	catchable := part.kind == kindGlove || part.kind == kindTorso
	if part.kind == kindLeg || part.kind == kindArm {
		catchable = true
		limit = kGatherSpeed
	} else if catchable && relSpeed <= kGatherSpeed && ballP.y < 0.6 {
		limit = jsMax(limit, kGatherSpeed)
	}
	return decision{held: catchable && relSpeed <= limit, hands: hands, toBody: toBody}
}

func (e *engine) holdPoint(cs *caps) vec {
	gl := cs[3].a
	gr := cs[7].a
	p := add(scale(add(gl, gr), 0.5), vec{0, 0, 0.06 * e.scale})
	return vec{p.x, jsMax(ballR, p.y), p.z}
}

// r3 is the browser's millimetre rounding: Math.round(x * 1000) / 1000.
func r3(x float64) float64 {
	return jsRound(x*1000) / 1000
}

// ---------------------------------------------------------------- simulate

// Work done only near the keeper or the goal frame (the browser engine has
// the same ZONES). A keeper part at full reach can touch the ball only
// within 1.97 m of the hip: the farthest part is a glove, 1.29 x scale from
// it, plus 0.35 m of collision margin, reaction reach and late hand reach,
// plus the ball's radius; the hip used is the keeper block's end pose, at
// most 14 cm from the interpolated one. Contacts are checked from probeZone
// out, posts and bar only within a centimetre of reach (nearFrame). Skipping checks that would find
// nothing leaves every result unchanged.
var (
	probeZone   = 2.2
	keeperBlock = 20 // steps per keeper step: it moves at 50 Hz
	ballBlock   = 5  // steps per ball step in free flight
)

// Simulate plays a kick to its verdict. plan is ignored with opt.NoKeeper.
func Simulate(in Shot, pl Plan, prm Params, opt Options) Result {
	e := newEngine(prm)
	withKeeper := !opt.NoKeeper
	ln := e.computeLaunch(&in)
	b := ball{p: ln.pos, v: ln.vel, w: ln.spin}
	res := Result{
		Touch: -1,
		Launch: Launch{
			Vel:   [3]float64{ln.vel.x, ln.vel.y, ln.vel.z},
			Spin:  [3]float64{ln.spin.x, ln.spin.y, ln.spin.z},
			Speed: ln.speed, FuzzX: ln.fuzz.x, FuzzY: ln.fuzz.y,
			ContactX: ln.contact.x, ContactY: ln.contact.y,
		},
	}
	var k keeper
	var kb blocks
	if withKeeper {
		var m misread
		if in.HasMishit && !opt.NoMisread {
			m = keeperMisread(&in.Mishit)
			res.Misread = [4]float64{m.x, m.y, m.vx, m.jump}
		}
		k = e.keeperInit(m)
		e.initCaps(&kb.cbuf[0])
		e.initCaps(&kb.cbuf[1])
		kb.pose[1] = poseOf(&k)
	}
	every := opt.TraceEvery
	if every <= 0 {
		every = 25
	}
	trace := uint32(0x811c9dc5)

	step := 0
	t := 0.0
	verdict := 0
	lastContact := -1.0
	var gaveWay [nParts]float64
	for i := range gaveWay {
		gaveWay[i] = negInf
	}
	woodworkSet := false
	touched := false // res.Touch >= 0 || woodworkSet
	tracing := opt.Trace

	// The bounds the loop tests against, worked out once with the same
	// operations as the browser's checks.
	near2 := probeZone * probeZone
	far := probeZone + 0.3
	far2 := far * far
	lowY := ballR + 0.15
	fr25 := ballR + postR + 0.25 // nearFrame(p, 0.25)
	nfr25 := -fr25
	fr01 := ballR + postR + 0.01 // nearFrame(p, 0.01)
	nfr01 := -fr01
	sideX, roofY := e.netSideX, e.netRoofY
	side25 := sideX + fr25
	side01 := sideX + fr01
	boardsIn := boardsZ - 0.3
	netZ := goalZ - postR
	netZ2 := goalZ - postR - 0.5
	crossZ := goalZ - postR - ballR
	awayZ := goalZ + 0.8
	wideX := sideX + ballR
	liftY := ballR + 0.005

	for verdict == 0 {
		if tracing && step%every == 0 {
			trace = foldState(trace, &b, withKeeper, &k)
		}
		px, py, pz := b.p.x, b.p.y, b.p.z
		// In free flight the ball moves in steps of ballBlock; this pass then
		// covers steps first..step. The browser's freeFlight, written out:
		// nothing the ball can touch within reach during the step, and the
		// step inside one keeper block.
		adv := 1
		if !b.held && !b.inGoal {
			// Comparisons are kept in if conditions: as operands of && and ||
			// gno converts each to bool at a cost.
			ff := true
			if withKeeper {
				dx, dy, dz := px-k.pos.x, py-k.pos.y, pz-k.pos.z
				if dx*dx+dy*dy+dz*dz < far2 {
					ff = false
				}
			}
			if !ff {
			} else if b.grounded {
			} else if py < lowY {
				ff = false
			}
			if !ff {
			} else if dz := pz - goalZ; dz > fr25 {
			} else if dz < nfr25 {
			} else {
				ax := px
				if px < 0 {
					ax = -px
				}
				if dx := ax - sideX; dx < fr25 {
					if dx > nfr25 {
						ff = false
					}
				}
				if !ff {
				} else if dy := py - roofY; dy < fr25 {
					if dy > nfr25 {
						if ax < side25 {
							ff = false
						}
					}
				}
			}
			if !ff {
			} else if withKeeper {
				first := step + 1
				end := kb.s0 + kb.n - 1
				if first >= kb.s0+kb.n {
					end = first + blockLen(&k, &pl, first) - 1
				}
				ff = first+ballBlock-1 <= end
			}
			if ff {
				adv = ballBlock
			}
		}
		first := step + 1
		step += adv
		t = float64(step) * simDT

		// The keeper moves in 50 Hz blocks; its shapes are only needed once
		// the ball is within reach (probeZone).
		near := false
		num := 0 // steps into the keeper's current block
		if withKeeper {
			if first >= kb.s0+kb.n {
				e.keeperBlock(&k, &pl, first, &b, &kb)
			}
			num = step - kb.s0 + 1
			dx, dy, dz := px-k.pos.x, py-k.pos.y, pz-k.pos.z
			if dx*dx+dy*dy+dz*dz < near2 {
				near = true
			}
		}

		if b.held {
			all := e.blockCaps(&kb, num)
			target := e.holdPoint(&all)
			f := jsMin(1, kHoldPull*simDT)
			np := add(b.p, scale(sub(target, b.p), f))
			b.v = scale(sub(np, b.p), 1/simDT)
			b.p = vec{np.x, jsMax(ballR, np.y), np.z}
			b.w = scale(b.w, jsMax(0, 1-20*simDT))
			continue
		}

		if adv == 1 {
			e.integrateBall(&b, simDT)
		} else if b.grounded {
			e.integrateBall(&b, float64(adv)*simDT)
		} else {
			heunBall(&b, float64(adv)*simDT)
		}
		if b.p.y < ballR {
			groundContact(&b)
		}
		px, py, pz = b.p.x, b.p.y, b.p.z

		// Posts and bar: only near them (nearFrame(p, 0.01), written out).
		frameNear := false
		if dz := pz - goalZ; dz > fr01 {
		} else if dz < nfr01 {
		} else {
			ax := px
			if px < 0 {
				ax = -px
			}
			if dx := ax - sideX; dx < fr01 {
				if dx > nfr01 {
					frameNear = true
				}
			}
			if frameNear {
			} else if dy := py - roofY; dy < fr01 {
				if dy > nfr01 {
					if ax < side01 {
						frameNear = true
					}
				}
			}
		}
		if frameNear {
			for i := range e.frame {
				c := &e.frame[i]
				h := collideCapsule(&b, c.a, c.b, c.r, false, vec{}, vec{}, ePost, 0.1, 0.7, -1)
				if h.ok && h.impactSpeed > 0.5 && !woodworkSet {
					woodworkSet = true
					touched = true
					res.Woodwork = c.part
				}
			}
			px, py, pz = b.p.x, b.p.y, b.p.z
		}

		near0 := near // within probeZone of the hips; pouncing needs kPounceReach, less
		// Clear of the whole body over the block, at any part's full reach:
		// every per-part check below would find nothing.
		if near {
			bd := e.blockBody(&kb)
			if px < bd[0] {
				near = false
			} else if px > bd[1] {
				near = false
			} else if py < bd[2] {
				near = false
			} else if py > bd[3] {
				near = false
			} else if pz < bd[4] {
				near = false
			} else if pz > bd[5] {
				near = false
			}
		}
		if near {
			sp := ballSpeed(&b, b.v)
			react := 0.0
			if t >= kPerceive && sp < kReactSpeed {
				react = kReactReach * (kReactSpeed - sp) / kReactSpeed
			}
			late := jsMin(kHandLateMax, kHandLateRate*jsMax(0, t-kPerceive-0.1))
			inAir := k.phase == phaseAir
			capsB := e.blockCapsB(&kb)
			cand := e.blockCands(&kb, b.p)
			for i := 0; i < nCaps; i++ {
				if !cand[i] {
					continue
				}
				cb := &capsB[i]
				if gaveWay[cb.part] > t {
					continue
				}
				// The browser adds 0 for the parts without the extra reach,
				// which leaves the (positive) radius as it is.
				reach := cb.hit
				if cb.kind != kindHead {
					reach += react
				}
				if cb.kind == kindGlove {
					reach += late
				}
				// Outside the box of the part's positions over the block by
				// more than the contact distance (plus a centimetre against
				// rounding) on any axis: the probe could only find nothing.
				bx := e.blockBox(&kb, i, num)
				m := ballR + reach + 0.01
				if px < bx[0]-m {
					continue
				} else if px > bx[1]+m {
					continue
				} else if py < bx[2]-m {
					continue
				} else if py > bx[3]+m {
					continue
				} else if pz < bx[4]-m {
					continue
				} else if pz > bx[5]+m {
					continue
				}
				cc := e.blockCap(&kb, i, num)
				c := &cc
				va, vb := e.blockVel(&kb, i)
				pr := probeCapsule(&b, c.a, c.b, reach, va, vb)
				if !pr.ok {
					continue
				}
				if res.Touch < 0 {
					res.Touch = c.part
					res.TouchStep = step
					touched = true
				}
				newTouch := t-lastContact > kTouchGap
				lastContact = t
				all := e.blockCaps(&kb, num)
				d := e.catchDecision(&all, c, pr.relSpeed, b.p)
				if newTouch && d.held && verdict == 0 && pz >= crossZ {
					res.Contacts = append(res.Contacts, Contact{Step: step, Part: c.part, Catch: true})
					res.Caught = true
					b.held = true
					b.grounded = false
					k.holding = true
					verdict, res.DecidedStep, res.DecidedAt = Save, step, t
					break
				}
				var give float64
				switch c.kind {
				case kindGlove:
					give = kGiveGlove
					if d.hands >= 0.5 {
						give = kGiveHands
					}
				case kindLeg:
					give = kGiveLeg
					if inAir {
						give = kGiveLegInAir
					}
				case kindArm:
					give = kGiveArm
				case kindTorso:
					give = kGiveTorso
				default:
					give = kGiveHead
				}
				if pr.dist > ballR+c.r {
					give *= kFingertipGive
				}
				if c.kind == kindGlove && d.toBody < kReflexBody*e.scale {
					give = jsMax(give, kGiveTorso)
				}
				el := kEBody
				if c.kind == kindGlove {
					el = kEGlove
				}
				h := collideCapsule(&b, c.a, c.b, reach, true, va, vb, el, kFriction, 0.4, give)
				px, py, pz = b.p.x, b.p.y, b.p.z
				if !h.ok {
					continue
				}
				if h.gaveWay {
					gaveWay[c.part] = t + kTouchGap
				}
				if !h.gaveWay && c.kind == kindGlove && pr.relSpeed < kParryControl && b.v.z < kParryOut {
					wide := -1.0
					if px >= k.pos.x {
						wide = 1
					}
					b.v = vec{b.v.x + wide*kParryWide, b.v.y, kParryOut}
				}
				if newTouch {
					res.Contacts = append(res.Contacts, Contact{Step: step, Part: c.part, GaveWay: h.gaveWay})
				}
			}
			if b.held {
				continue
			}
		}

		// The boards, the line and the net all lie at or behind the goal line.
		x, y, z := px, py, pz
		ax := x
		if x < 0 {
			ax = -x
		}
		if z <= goalZ {
			if z-ballR < boardsZ && z > boardsIn && b.v.z < 0 && y-ballR < boardsH && ax < boardsHW {
				b.p = vec{x, y, boardsZ + ballR}
				b.v = vec{b.v.x * 0.7, b.v.y * 0.7, -0.3 * b.v.z}
				z = b.p.z
			}
		}

		if b.grounded {
			if b.v.y > 0.3 {
				b.grounded = false
			} else if y > liftY {
				b.grounded = false
			}
		}

		if z <= goalZ {
			if !res.LineCross {
				res.LineCross = true
				res.LineT, res.LineX, res.LineY = r3(t), r3(x), r3(y)
			}
			if !b.inGoal && z < netZ && z > netZ2 && ax < sideX && y < roofY {
				b.inGoal = true
			}
			if !res.Crossing && z < crossZ {
				res.Crossing = true
				res.CrossT, res.CrossX, res.CrossY = r3(t), r3(x), r3(y)
				if b.inGoal {
					verdict = Goal
				} else if res.Touch >= 0 {
					verdict = Save
				} else if woodworkSet {
					verdict = Post
				} else {
					verdict = Miss
				}
				res.DecidedStep, res.DecidedAt = step, t
			}
		}

		if verdict == 0 {
			kept := false // decided without crossing the line
			if touched {
				if b.v.z > 0 {
					if z > awayZ {
						kept = true // parried away
					}
				}
			}
			if kept {
			} else if b.grounded && slowerThan(b.v, 0.15) {
				kept = true
			} else if ax > wideX {
				if x*b.v.x >= 0 {
					kept = true // outside a post and moving away from it
				}
			}
			if kept {
			} else if touched && withKeeper && near0 && pounces(&k, &b) {
				// The keeper pounces on the loose ball.
				verdict, res.DecidedStep, res.DecidedAt = Save, step, t
				b.v = vec{0, 0, 0}
				b.w = vec{0, 0, 0}
				res.Pounced = true
			} else if t >= simMaxT {
				kept = true
			}
			if kept {
				if res.Touch >= 0 {
					verdict = Save
				} else if woodworkSet {
					verdict = Post
				} else {
					verdict = Miss
				}
				res.DecidedStep, res.DecidedAt = step, t
			}
		}
	}
	if opt.Trace {
		trace = foldState(trace, &b, withKeeper, &k)
	}
	res.Outcome = verdict
	res.EndX, res.EndY = b.p.x, b.p.y
	res.Steps = step
	res.Trace = trace
	if withKeeper {
		res.Commits = k.commits
	}
	return res
}

// foldState hashes the ball and keeper state (FNV-1a over the float64 bits,
// big-endian), as the browser-side test harness does.
func foldState(h uint32, b *ball, withKeeper bool, k *keeper) uint32 {
	h = foldVec(h, b.p)
	h = foldVec(h, b.v)
	h = foldVec(h, b.w)
	if withKeeper {
		h = foldVec(h, k.pos)
		h = foldVec(h, k.vel)
		h = foldFloat(h, k.lean.s)
		h = foldFloat(h, k.lean.c)
		h = foldVec(h, k.arms.l)
		h = foldVec(h, k.arms.r)
	}
	return h
}

func foldVec(h uint32, v vec) uint32 {
	h = foldFloat(h, v.x)
	h = foldFloat(h, v.y)
	return foldFloat(h, v.z)
}

func foldFloat(h uint32, f float64) uint32 {
	u := math.Float64bits(f)
	for i := 0; i < 8; i++ {
		h ^= uint32(byte(u >> (56 - 8*uint(i))))
		h *= 0x01000193
	}
	return h
}
