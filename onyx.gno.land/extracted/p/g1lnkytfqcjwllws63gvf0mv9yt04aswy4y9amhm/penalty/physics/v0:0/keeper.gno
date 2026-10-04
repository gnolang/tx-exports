package physics

// Keeper phases.
const (
	phaseReady = iota
	phasePush
	phaseAir
	phaseGround
	phaseRecover
)

// Body parts, in the order the browser builds them. Both torso capsules are
// one part ("body"), as in the browser, where parts are keyed by name.
const (
	partLeftLeg = iota
	partBody
	partLeftArm
	partLeftGlove
	partRightLeg
	partRightArm
	partRightGlove
	partHead
	nParts
)

// PartNames are the browser's names for the parts.
var PartNames = [nParts]string{"left leg", "body", "left arm", "left glove", "right leg", "right arm", "right glove", "head"}

const (
	kindLeg = iota
	kindTorso
	kindArm
	kindGlove
	kindHead
)

const nCaps = 9

type capsule struct {
	a, b vec
	r    float64
	hit  float64
	kind int
	part int
}

type caps [nCaps]capsule

type plant struct {
	on      bool
	side    float64
	x, y, z float64
}

type lean2 struct{ s, c float64 }

// Commit is one move the keeper made: when, how fast sideways, how high.
type Commit struct {
	Step int
	T0   float64
	VX   float64
	Jump float64
	Star bool
	Read bool
}

type misread struct {
	on             bool
	x, y, vx, jump float64
}

type keeper struct {
	mis        misread
	phase      int
	pushT      float64
	groundT    float64
	pos, vel   vec
	lean       lean2
	arms       armPair
	launchVel  vec
	leanTarget lean2
	armsTarget armPair
	plant      plant
	plantUntil float64
	commits    []Commit
	holding    bool
	read       pred    // its latest read of where the ball will cross
	nextRead   int     // the step of its next read
	seen       ball    // the ball at a read not worked out yet (see keeperStep)
	seenZ      float64 // and the keeper's z, and the time, at that read
	seenT      float64
	pending    bool
	clr        float64
	clrS, clrC float64 // the lean clr was computed for
	clrOK      bool
}

type pred struct {
	ok   bool
	x, y float64
	tau  float64
}

func (e *engine) keeperInit(m misread) keeper {
	return keeper{
		mis:        m,
		phase:      phaseReady,
		pos:        vec{0, e.standHipY, goalZ + kLineOffset},
		lean:       lean2{0, 1},
		arms:       armsReady,
		leanTarget: lean2{0, 1},
		armsTarget: armsReady,
		nextRead:   1,
	}
}

func margin(kind int) float64 {
	switch kind {
	case kindGlove:
		return kMarginGlove
	case kindArm:
		return kMarginArm
	case kindTorso:
		return kMarginTorso
	case kindLeg:
		return kMarginLeg
	}
	return kMarginHead
}

// Fixed offsets of the body points, already scaled: what the browser's w()
// computes as x *= S, y *= S for each constant point, per side.
type sideK struct {
	side                        float64
	sx                          float64 // shoulder x, unscaled
	legX, legY, footX, footY    float64
	torX, torAY, torBY          float64
	armAX, armAY                float64
	legR, torR, armR, gloveR    float64
	legH, torH, armH, gloveH    float64
	legPart, armPart, glovePart int
}

func (e *engine) initBody() {
	S := e.scale
	zero := 0.0
	for i, side := range [2]float64{-1, 1} {
		k := sideK{side: side, sx: kShoulderX * side}
		k.legX, k.legY = 0.11*side*S, zero*S
		k.footX, k.footY = 0.15*side*S, -0.85*S
		k.torX, k.torAY, k.torBY = 0.09*side*S, 0.05*S, 0.46*S
		k.armAX, k.armAY = k.sx*S, kShoulderY*S
		k.legR, k.torR, k.armR, k.gloveR = 0.08*S, 0.14*S, 0.055*S, kGloveR
		k.legH, k.torH, k.armH, k.gloveH = k.legR+kMarginLeg, k.torR+kMarginTorso, k.armR+kMarginArm, k.gloveR+kMarginGlove
		if side < 0 {
			k.legPart, k.armPart, k.glovePart = partLeftLeg, partLeftArm, partLeftGlove
		} else {
			k.legPart, k.armPart, k.glovePart = partRightLeg, partRightArm, partRightGlove
		}
		e.body[i] = k
	}
	e.headX, e.headY = zero*S, 0.72*S
	e.headR = 0.12 * S
	e.headH = e.headR + kMarginHead
	e.zeroZ = zero * S
}

// wpt is the browser's w() for a point already scaled: X = x*S, Y = y*S,
// Z = z*S.
func wpt(pos vec, ln lean2, X, Y, Z float64) vec {
	return vec{pos.x + X*ln.c + Y*ln.s, pos.y - X*ln.s + Y*ln.c, pos.z + Z}
}

// initCaps sets what never changes in the keeper's collision shapes: radii,
// kinds and parts, in the browser's order (left leg, body, left arm, left
// glove, the same on the right, head).
func (e *engine) initCaps(cs *caps) {
	for i := 0; i < 2; i++ {
		k := &e.body[i]
		j := 4 * i
		cs[j] = capsule{r: k.legR, hit: k.legH, kind: kindLeg, part: k.legPart}
		cs[j+1] = capsule{r: k.torR, hit: k.torH, kind: kindTorso, part: partBody}
		cs[j+2] = capsule{r: k.armR, hit: k.armH, kind: kindArm, part: k.armPart}
		cs[j+3] = capsule{r: k.gloveR, hit: k.gloveH, kind: kindGlove, part: k.glovePart}
	}
	cs[8] = capsule{r: e.headR, hit: e.headH, kind: kindHead, part: partHead}
}

// capsulesInto sets the end points of the shapes in cs (see initCaps) for a
// pose: the browser's keeperCapsules, each point wpt written out.
func (e *engine) capsulesInto(cs *caps, ps *pose) {
	S := e.scale
	px, py, pz := ps.pos.x, ps.pos.y, ps.pos.z
	s, c := ps.lean.s, ps.lean.c
	z0 := pz + e.zeroZ
	pl := &ps.plant
	for i := 0; i < 2; i++ {
		k := &e.body[i]
		arm := &ps.arms.r
		if k.side < 0 {
			arm = &ps.arms.l
		}
		ax, ay, az := arm.x, arm.y, arm.z
		j := 4 * i
		cp := &cs[j]
		X, Y := k.legX, k.legY
		cp.a = vec{px + X*c + Y*s, py - X*s + Y*c, z0}
		if pl.on && pl.side == k.side {
			cp.b = vec{pl.x, pl.y, pl.z}
		} else {
			X, Y = k.footX, k.footY
			cp.b = vec{px + X*c + Y*s, py - X*s + Y*c, z0}
		}
		cp = &cs[j+1]
		X, Y = k.torX, k.torAY
		cp.a = vec{px + X*c + Y*s, py - X*s + Y*c, z0}
		Y = k.torBY
		cp.b = vec{px + X*c + Y*s, py - X*s + Y*c, z0}
		cp = &cs[j+2]
		X, Y = k.armAX, k.armAY
		cp.a = vec{px + X*c + Y*s, py - X*s + Y*c, z0}
		X, Y = (k.sx+ax*kArmLen)*S, (kShoulderY+ay*kArmLen)*S
		cp.b = vec{px + X*c + Y*s, py - X*s + Y*c, pz + az*kArmLen*S}
		cp = &cs[j+3]
		X, Y = (k.sx+ax*kGloveReach)*S, (kShoulderY+ay*kGloveReach)*S
		g := vec{px + X*c + Y*s, py - X*s + Y*c, pz + az*kGloveReach*S}
		cp.a, cp.b = g, g
	}
	X, Y := e.headX, e.headY
	h := vec{px + X*c + Y*s, py - X*s + Y*c, z0}
	cs[8].a, cs[8].b = h, h
}

func (e *engine) keeperCaps(k *keeper) caps {
	var cs caps
	e.initCaps(&cs)
	ps := poseOf(k)
	e.capsulesInto(&cs, &ps)
	return cs
}

// clearance is keeperClearance: the hip height at which the lowest of the
// legs, torso and head touches the ground (the browser builds every shape at
// the origin; only these heights matter).
func (e *engine) clearance(k *keeper) float64 {
	s, c := k.lean.s, k.lean.c
	// The browser's Math.min over these heights, in its order, signed zeros
	// included: jsMin only when two are equal.
	l := &e.body[0]
	r := &e.body[1]
	m := 0 - l.legX*s + l.legY*c - l.legR
	if v := 0 - l.footX*s + l.footY*c - l.legR; v < m {
		m = v
	} else if v == m {
		m = jsMin(m, v)
	}
	if v := 0 - l.torX*s + l.torAY*c - l.torR; v < m {
		m = v
	} else if v == m {
		m = jsMin(m, v)
	}
	if v := 0 - l.torX*s + l.torBY*c - l.torR; v < m {
		m = v
	} else if v == m {
		m = jsMin(m, v)
	}
	if v := 0 - r.legX*s + r.legY*c - r.legR; v < m {
		m = v
	} else if v == m {
		m = jsMin(m, v)
	}
	if v := 0 - r.footX*s + r.footY*c - r.legR; v < m {
		m = v
	} else if v == m {
		m = jsMin(m, v)
	}
	if v := 0 - r.torX*s + r.torAY*c - r.torR; v < m {
		m = v
	} else if v == m {
		m = jsMin(m, v)
	}
	if v := 0 - r.torX*s + r.torBY*c - r.torR; v < m {
		m = v
	} else if v == m {
		m = jsMin(m, v)
	}
	if v := 0 - e.headX*s + e.headY*c - e.headR; v < m {
		m = v
	} else if v == m {
		m = jsMin(m, v)
	}
	return -m
}

func (e *engine) armsAboveGround(k *keeper) {
	s, c := k.lean.s, k.lean.c
	sy := e.shY
	reach := e.gloveReachS
	py := k.pos.y
	syc := sy * c
	// Left arm, then right, as the browser's loop over the sides.
	shoulderY := py - e.shXL*s + syc
	minDy := (kGloveR - shoulderY) / reach
	if minDy < 1 {
		arm := &k.arms.l
		if -arm.x*s+arm.y*c < minDy {
			liftArm(arm, minDy, s, c)
		}
	}
	shoulderY = py - e.shXR*s + syc
	minDy = (kGloveR - shoulderY) / reach
	if minDy < 1 {
		arm := &k.arms.r
		if -arm.x*s+arm.y*c < minDy {
			liftArm(arm, minDy, s, c)
		}
	}
}

// liftArm raises an arm (body frame) whose hand would be below the ground
// to world height minDy, keeping its direction across.
func liftArm(arm *vec, minDy, s, c float64) {
	wx := arm.x*c + arm.y*s
	h0 := fsqrt(wx*wx + arm.z*arm.z)
	h := fsqrt(1 - minDy*minDy)
	nx, nz := h, 0.0
	if h0 > 0 {
		nx = (wx * h) / h0
		nz = (arm.z * h) / h0
	}
	*arm = vec{nx*c - minDy*s, nx*s + minDy*c, nz}
}

// pose is what the keeper's shapes are built from.
type pose struct {
	pos   vec
	lean  lean2
	arms  armPair
	plant plant
}

func poseOf(k *keeper) pose { return pose{k.pos, k.lean, k.arms, k.plant} }

// blocks is the keeper's movement at 50 Hz: blocks of keeperBlock steps,
// each one keeper step of that length taken at the block's start, from pose
// A (the block's start) to pose B (its end). A block in which its plan
// commits is a single millisecond instead, so the reaction time keeps 1 ms
// precision. Within a block the shapes the ball meets are interpolated
// between A's and B's, one per millisecond, at the block's constant velocity.
type blocks struct {
	s0, n     int
	ia        int // pose[ia] is pose A (the block's start), pose[1-ia] pose B
	pose      [2]pose
	cbuf      [2]caps // the shapes of each pose
	ok        [2]bool // whether cbuf holds them
	vel       [nCaps][2]vec
	velOK     [nCaps]bool
	box       [nCaps][6]float64 // lo/hi x, y, z of each part's end points over the block
	boxOK     [nCaps]bool
	lastBox   [nCaps][6]float64 // the same for pose B alone (the block's last step)
	lastBoxOK [nCaps]bool
	body      [6]float64 // every part over the block, widened by maxReach
	bodyOK    bool
	cand      [nCaps]bool // parts that can reach a ball within candR of candP this block
	candP     vec
	candOK    bool
}

func blockLen(k *keeper, pl *Plan, step int) int {
	if k.phase != phaseReady {
		return keeperBlock
	}
	if k.holding {
		return keeperBlock
	}
	if pl.commitTime() <= float64(step+keeperBlock-1)*simDT {
		return 1
	}
	return keeperBlock
}

func (e *engine) keeperBlock(k *keeper, pl *Plan, step int, b *ball, kb *blocks) {
	kb.s0 = step
	kb.n = blockLen(k, pl, step)
	kb.ia = 1 - kb.ia // B becomes A, with its shapes
	kb.velOK = [nCaps]bool{}
	kb.boxOK = [nCaps]bool{}
	kb.lastBoxOK = [nCaps]bool{}
	kb.bodyOK = false
	kb.candOK = false
	end := step + kb.n - 1
	e.keeperStep(k, pl, end, float64(end)*simDT, float64(kb.n)*simDT, b)
	kb.pose[1-kb.ia] = poseOf(k)
	kb.ok[1-kb.ia] = false
}

func (e *engine) blockCapsA(kb *blocks) *caps {
	i := kb.ia
	if !kb.ok[i] {
		e.capsulesInto(&kb.cbuf[i], &kb.pose[i])
		kb.ok[i] = true
	}
	return &kb.cbuf[i]
}

func (e *engine) blockCapsB(kb *blocks) *caps {
	i := 1 - kb.ia
	if !kb.ok[i] {
		e.capsulesInto(&kb.cbuf[i], &kb.pose[i])
		kb.ok[i] = true
	}
	return &kb.cbuf[i]
}

// blockCap is shape i num steps into the block (num = n is pose B).
func (e *engine) blockCap(kb *blocks, i, num int) capsule {
	b := e.blockCapsB(kb)[i]
	if num == kb.n {
		return b
	}
	a := &e.blockCapsA(kb)[i]
	f := float64(num) / float64(kb.n)
	b.a = lerpV(a.a, b.a, f)
	b.b = lerpV(a.b, b.b, f)
	return b
}

func (e *engine) blockCaps(kb *blocks, num int) caps {
	if num == kb.n {
		return *e.blockCapsB(kb)
	}
	var cs caps
	for i := range cs {
		cs[i] = e.blockCap(kb, i, num)
	}
	return cs
}

// blockVel is the velocity of shape i's end points during the block.
func (e *engine) blockVel(kb *blocks, i int) (vec, vec) {
	if !kb.velOK[i] {
		a := &e.blockCapsA(kb)[i]
		b := &e.blockCapsB(kb)[i]
		inv := 1 / (float64(kb.n) * simDT)
		kb.vel[i] = [2]vec{scale(sub(b.a, a.a), inv), scale(sub(b.b, a.b), inv)}
		kb.velOK[i] = true
	}
	return kb.vel[i][0], kb.vel[i][1]
}

// blockBox bounds part i over the rest of the block: its end points at the
// block's start and end (every interpolated position lies between them), or
// at the end alone on the block's last step, as the browser's outsideBox4.
func (e *engine) blockBox(kb *blocks, i, num int) *[6]float64 {
	if num == kb.n {
		if !kb.lastBoxOK[i] {
			c := &e.blockCapsB(kb)[i]
			boxInto(&kb.lastBox[i], c, c)
			kb.lastBoxOK[i] = true
		}
		return &kb.lastBox[i]
	}
	if !kb.boxOK[i] {
		boxInto(&kb.box[i], &e.blockCapsA(kb)[i], &e.blockCapsB(kb)[i])
		kb.boxOK[i] = true
	}
	return &kb.box[i]
}

// candSlack is how far the ball may move before the candidate parts are
// worked out again.
var candSlack = 0.1

// blockCands lists the parts whose swept box over the block, widened by the
// most that part can reach (collision radius, slow-ball reaction, late
// hands, the ball, a centimetre), comes within candSlack of the ball: no
// other part can pass the per-part test while the ball stays within
// candSlack of where the list was made, so the list is reused until then.
func (e *engine) blockCands(kb *blocks, p vec) *[nCaps]bool {
	if kb.candOK {
		q := kb.candP
		if p.x-q.x >= candSlack {
		} else if q.x-p.x >= candSlack {
		} else if p.y-q.y >= candSlack {
		} else if q.y-p.y >= candSlack {
		} else if p.z-q.z >= candSlack {
		} else if q.z-p.z >= candSlack {
		} else {
			return &kb.cand
		}
	}
	cb := e.blockCapsB(kb)
	px, py, pz := p.x, p.y, p.z
	for i := 0; i < nCaps; i++ {
		bx := e.blockBox(kb, i, 0) // start and end poses: covers the last step's box too
		c := &cb[i]
		m := ballR + c.hit + kReactReach + 0.01 + candSlack
		if c.kind == kindGlove {
			m += kHandLateMax
		}
		in := false
		if px < bx[0]-m {
		} else if px > bx[1]+m {
		} else if py < bx[2]-m {
		} else if py > bx[3]+m {
		} else if pz < bx[4]-m {
		} else if pz > bx[5]+m {
		} else {
			in = true
		}
		kb.cand[i] = in
	}
	kb.candP = p
	kb.candOK = true
	return &kb.cand
}

// blockBody bounds every part over the block (start and end poses), widened
// by the most any part reaches (e.maxReach).
func (e *engine) blockBody(kb *blocks) *[6]float64 {
	if !kb.bodyOK {
		bx := *e.blockBox(kb, 0, 0)
		for i := 1; i < nCaps; i++ {
			o := e.blockBox(kb, i, 0)
			if o[0] < bx[0] {
				bx[0] = o[0]
			}
			if o[1] > bx[1] {
				bx[1] = o[1]
			}
			if o[2] < bx[2] {
				bx[2] = o[2]
			}
			if o[3] > bx[3] {
				bx[3] = o[3]
			}
			if o[4] < bx[4] {
				bx[4] = o[4]
			}
			if o[5] > bx[5] {
				bx[5] = o[5]
			}
		}
		m := e.maxReach
		kb.body = [6]float64{bx[0] - m, bx[1] + m, bx[2] - m, bx[3] + m, bx[4] - m, bx[5] + m}
		kb.bodyOK = true
	}
	return &kb.body
}

// boxInto sets bx to the box of c0's and c1's end points: per axis the
// least and greatest of the four, found in pairs. (The browser keeps a
// running min and max; the two differ at most in the sign of a zero, which
// no comparison against the box can see.)
func boxInto(bx *[6]float64, c0, c1 *capsule) {
	a, b, c, d := c0.a, c0.b, c1.a, c1.b
	lo, hi := a.x, b.x
	if hi < lo {
		lo, hi = hi, lo
	}
	l2, h2 := c.x, d.x
	if h2 < l2 {
		l2, h2 = h2, l2
	}
	if l2 < lo {
		lo = l2
	}
	if h2 > hi {
		hi = h2
	}
	bx[0], bx[1] = lo, hi
	lo, hi = a.y, b.y
	if hi < lo {
		lo, hi = hi, lo
	}
	l2, h2 = c.y, d.y
	if h2 < l2 {
		l2, h2 = h2, l2
	}
	if l2 < lo {
		lo = l2
	}
	if h2 > hi {
		hi = h2
	}
	bx[2], bx[3] = lo, hi
	lo, hi = a.z, b.z
	if hi < lo {
		lo, hi = hi, lo
	}
	l2, h2 = c.z, d.z
	if h2 < l2 {
		l2, h2 = h2, l2
	}
	if l2 < lo {
		lo = l2
	}
	if h2 > hi {
		hi = h2
	}
	bx[4], bx[5] = lo, hi
}

func lerpV(p, q vec, f float64) vec {
	return vec{p.x + (q.x-p.x)*f, p.y + (q.y-p.y)*f, p.z + (q.z-p.z)*f}
}

// predictCrossing: where the keeper expects the ball to cross z = zk.
// (ballSpeed written out.)
func predictCrossing(b *ball, zk float64) pred {
	ux, uz := b.v.x, b.v.z
	if uz >= -0.5 {
		return pred{}
	}
	dz := zk - b.p.z
	if dz >= 0 {
		return pred{}
	}
	uy := b.v.y
	sh := fsqrt(ux*ux + uz*uz)
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
	dist := (dz / uz) * sh
	grounded := b.grounded
	roll := 0.0
	if grounded {
		roll = ballRollDecel
	}
	decel := dragK*sp*sh + roll
	tau := dist / sh
	if decel > 1e-9 {
		disc := sh*sh - 2*decel*dist
		if disc <= 0 {
			return pred{}
		}
		tau = (sh - fsqrt(disc)) / decel
	}
	y := ballR
	if !grounded {
		if y = b.p.y + uy*tau - 0.5*simG*tau*tau; y < ballR {
			y = ballR
		}
	}
	return pred{ok: true, x: b.p.x + (ux/sh)*dist, y: y, tau: tau}
}

func (e *engine) readLaunch(k *keeper, pr pred) vec {
	S := e.scale
	dx := pr.x - k.pos.x
	sgn := 1.0
	ax := dx
	if dx < 0 {
		sgn = -1
		ax = -dx
	}
	T := jsMax(0.15, pr.tau-kPushTime*0.5)
	need := jsMax(0, ax-kReadReach*S)
	vx := jsMin(e.p.DiveMax, need/T)
	if pr.y < 0.6*S && ax > 0.2 {
		vx = jsMax(vx, kLowDropSpeed)
	}
	jump := clamp((pr.y-0.9*S)*kReadHeightGn, e.p.JumpMin, e.p.JumpMax)
	return vec{sgn * vx, jump, 0.12 * vx}
}

func diveArms(side float64, jump float64, ln lean2) armPair {
	toBody := func(wx, wy float64) vec {
		return norm(vec{wx*ln.c - wy*ln.s, wx*ln.s + wy*ln.c, 0.1})
	}
	reach := (jump - kReachPivot) / kReachSpan
	lead := toBody(side, reach)
	trail := toBody(side, reach+0.45)
	if side > 0 {
		return armPair{trail, lead}
	}
	return armPair{lead, trail}
}

func (e *engine) commitLaunch(k *keeper, step int, t float64, lv vec, read bool) {
	k.phase = phasePush
	k.pushT = 0
	k.groundT = 0
	k.launchVel = lv
	lx := lv.x
	ly := jsMax(kLeanMin, lv.y+kLeanBias)
	l := fsqrt(lx*lx + ly*ly)
	k.leanTarget = lean2{lx / l, ly / l}
	ax := lx
	if lx < 0 {
		ax = -lx
	}
	star := ax < kStarSpeed && lv.y > 0.5
	if star {
		k.armsTarget = armsStar
	} else {
		side := -1.0
		if lx > 0 {
			side = 1
		}
		k.armsTarget = diveArms(side, lv.y, k.leanTarget)
	}
	k.commits = append(k.commits, Commit{Step: int(jsRound(t / simDT)), T0: t, VX: lx, Jump: lv.y, Star: star, Read: read})
	if ax >= kStarSpeed {
		side := 1.0
		bk := &e.body[1]
		if lx > 0 {
			side = -1
			bk = &e.body[0]
		}
		// That side's foot, as the browser takes it from keeperCapsules.
		foot := wpt(k.pos, k.lean, bk.footX, bk.footY, e.zeroZ)
		k.plant = plant{on: true, side: side, x: foot.x, y: foot.y, z: foot.z}
		k.plantUntil = t + kPushTime + kPlantExtra
	}
}

// trackArms steers both hands at the predicted crossing (body frame). The
// arithmetic is the browser's aim() and norm(), written out.
func (e *engine) trackArms(k *keeper, pr pred) {
	s, c := k.lean.s, k.lean.c
	sy := e.shY
	dz, dz2 := e.aimDZ, e.aimDZ2
	px, py := k.pos.x, k.pos.y
	sys, syc := sy*s, sy*c
	// Left hand, then right.
	sx := e.shXL
	wx := pr.x - (px + sx*c + sys)
	wy := pr.y - (py - sx*s + syc)
	var dx, dy, dd float64
	if l := fsqrt(wx*wx + wy*wy + dz2); l > 0 {
		inv := 1 / l
		dx, dy, dd = wx*inv, wy*inv, dz*inv
	}
	k.armsTarget.l = vec{dx*c - dy*s, dx*s + dy*c, dd}
	sx = e.shXR
	wx = pr.x - (px + sx*c + sys)
	wy = pr.y - (py - sx*s + syc)
	dx, dy, dd = 0, 0, 0
	if l := fsqrt(wx*wx + wy*wy + dz2); l > 0 {
		inv := 1 / l
		dx, dy, dd = wx*inv, wy*inv, dz*inv
	}
	k.armsTarget.r = vec{dx*c - dy*s, dx*s + dy*c, dd}
}

func lerpRange(r [2]float64, f float64) float64 { return r[0] + (r[1]-r[0])*f }

func (e *engine) diveEarliness(reaction float64) float64 {
	return clamp((e.p.ReactionMax-reaction)/(e.p.ReactionMax-e.p.ReactionMin), 0, 1)
}

func (e *engine) misjudge(k *keeper, lv vec, reaction float64) vec {
	if !k.mis.on {
		return lv
	}
	f := e.diveEarliness(reaction)
	vx := clamp(lv.x+k.mis.vx*lerpRange(kMisjudgeVX, f), -e.p.DiveMax, e.p.DiveMax)
	jump := clamp(lv.y+k.mis.jump*lerpRange(kMisjudgeJump, f), e.p.JumpMin, e.p.JumpMax)
	return vec{vx, jump, lv.z}
}

// readIdle reports whether nothing in a keeper step at t can act on the
// keeper's read: before kPerceive the hands do not track it, a keeper
// waiting to dive or diving does not use it, and one waiting to read uses it
// only from kReadBase + its reaction.
func readIdle(k *keeper, pl *Plan, t float64) bool {
	if t >= kPerceive {
		return false
	}
	switch k.phase {
	case phaseReady:
		return pl.Mode != ModeRead || t < kReadBase+pl.Reaction
	case phasePush, phaseAir:
		return true
	}
	return false
}

// perceive is the keeper's read of a predicted crossing at t: off by its
// misread, more the earlier it reads.
func (e *engine) perceive(k *keeper, pr pred, t float64) pred {
	if !pr.ok || !k.mis.on {
		return pr
	}
	f := clamp((e.misT1-t)/e.misTd, 0, 1)
	y := pr.y + k.mis.y*(e.misY0+e.misYd*f)
	if y < ballR {
		y = ballR
	}
	return pred{ok: true, x: pr.x + k.mis.x*(e.misX0+e.misXd*f), y: y, tau: pr.tau}
}

func (e *engine) keeperStep(k *keeper, pl *Plan, step int, t, dt float64, b *ball) {
	// It reads the ball every kReadEvery steps and acts on its latest read
	// in between; once it holds the ball it stops reading.
	fresh := false
	if !k.holding && step >= k.nextRead {
		k.nextRead = step + kReadEvery
		fresh = true
		if readIdle(k, pl, t) {
			// Nothing acts on this read before the next one (see readIdle):
			// keep what the keeper saw, worked out only if something does.
			k.seen, k.seenZ, k.seenT, k.pending = *b, k.pos.z, t, true
		} else {
			k.read = e.perceive(k, predictCrossing(b, k.pos.z), t)
			k.pending = false
		}
	}
	var pr pred
	if !k.holding {
		if k.pending && !readIdle(k, pl, t) {
			k.read = e.perceive(k, predictCrossing(&k.seen, k.seenZ), k.seenT)
			k.pending = false
		}
		pr = k.read
	} else {
		k.armsTarget = armsHold
	}

	if k.phase == phaseReady && !k.holding {
		if pl.Mode == ModeRead {
			if t >= kReadBase+pl.Reaction {
				if pr.ok && pr.tau <= kReadShuffleT {
					e.commitLaunch(k, step, t, e.readLaunch(k, pr), true)
				} else {
					k.phase = phaseRecover
				}
			}
		} else if t >= pl.Reaction {
			e.commitLaunch(k, step, t, e.misjudge(k, launchVelocity(pl), pl.Reaction), false)
		}
	}
	if fresh && t >= kPerceive && pr.ok {
		e.trackArms(k, pr)
	}

	leanRate := kLeanRate
	switch k.phase {
	case phasePush:
		k.pushT += dt
		f := jsMin(1, k.pushT/kPushTime)
		lv := k.launchVel
		k.vel = vec{lv.x * f, lv.y*f - simG*k.pushT, lv.z * f}
		if f >= 1 {
			k.phase = phaseAir
		}
	case phaseAir:
		k.vel.y -= simG * dt
	case phaseGround:
		sp := fsqrt(k.vel.x*k.vel.x + k.vel.z*k.vel.z)
		sc := 0.0
		if sp > 0 {
			sc = jsMax(0, sp-kSlideDecel*dt) / sp
		}
		k.vel = vec{k.vel.x * sc, 0, k.vel.z * sc}
		k.groundT += dt
		if k.groundT >= kRecoverDelay && !(pr.ok && pr.tau < kHoldDownT) {
			k.phase = phaseRecover
			k.leanTarget = lean2{0, 1}
		}
	case phaseRecover:
		leanRate = kRecoverLeanRt
		vx := k.vel.x
		vz := 0.0
		if k.lean.c > 0.35 {
			tx := k.pos.x
			if pr.ok {
				tx = clamp(pr.x, -e.p.GoalHalfWidth, e.p.GoalHalfWidth)
			}
			top := kRecoverSpeed * k.lean.c
			want := clamp((tx-k.pos.x)*5, -top, top)
			vx += clamp(want-vx, -kRecoverAccel*dt, kRecoverAccel*dt)
			vz = clamp((goalZ+kLineOffset-k.pos.z)*3, -1.5, 1.5)
		} else {
			vx = 0
		}
		k.vel = vec{vx, 0, vz}
		if len(k.commits) < kMaxCommits && k.lean.c > 0.55 && pr.ok && pr.tau < kRediveWindow {
			dx := pr.x - k.pos.x
			if dx > kRediveMinDX || dx < -kRediveMinDX || pr.y < 0.45 || pr.y > 1.9 {
				e.commitLaunch(k, step, t, e.readLaunch(k, pr), true)
			}
		}
	}
	kp, kv := &k.pos, &k.vel
	kp.x += kv.x * dt
	kp.y += kv.y * dt
	kp.z += kv.z * dt
	fl := leanRate * dt
	if fl >= 1 {
		fl = 1 // jsMin(1, fl) for a positive rate
	}
	ln, lt := &k.lean, &k.leanTarget
	ls, lc := ln.s+(lt.s-ln.s)*fl, ln.c+(lt.c-ln.c)*fl
	// nlerp2: three Newton steps towards unit length, as the browser.
	g := 1.5 - 0.5*(ls*ls+lc*lc)
	ls, lc = ls*g, lc*g
	g = 1.5 - 0.5*(ls*ls+lc*lc)
	ls, lc = ls*g, lc*g
	g = 1.5 - 0.5*(ls*ls+lc*lc)
	ln.s, ln.c = ls*g, lc*g
	rate := kArmRate
	if t >= kPerceive {
		rate = kArmTrackRate
	}
	fa := rate * dt
	if fa >= 1 {
		fa = 1
	}
	// blendUnit for each arm, written out. Each arm is replaced whole, not
	// updated field by field: the arms start as copies of armsReady, and a
	// gno struct copy shares its nested structs, so writing a.x in place
	// would write to this package's armsReady (which a realm may not do).
	a, b2 := &k.arms.l, &k.armsTarget.l
	x, y, z := a.x+(b2.x-a.x)*fa, a.y+(b2.y-a.y)*fa, a.z+(b2.z-a.z)*fa
	g = 1.5 - 0.5*(x*x+y*y+z*z)
	x, y, z = x*g, y*g, z*g
	g = 1.5 - 0.5*(x*x+y*y+z*z)
	x, y, z = x*g, y*g, z*g
	g = 1.5 - 0.5*(x*x+y*y+z*z)
	*a = vec{x * g, y * g, z * g}
	a, b2 = &k.arms.r, &k.armsTarget.r
	x, y, z = a.x+(b2.x-a.x)*fa, a.y+(b2.y-a.y)*fa, a.z+(b2.z-a.z)*fa
	g = 1.5 - 0.5*(x*x+y*y+z*z)
	x, y, z = x*g, y*g, z*g
	g = 1.5 - 0.5*(x*x+y*y+z*z)
	x, y, z = x*g, y*g, z*g
	g = 1.5 - 0.5*(x*x+y*y+z*z)
	*a = vec{x * g, y * g, z * g}

	// The clearance depends on the lean alone (cached), and no lean puts it
	// above the keeper's scale: with the hips higher than that it cannot
	// matter.
	grounded := false
	if k.phase == phaseGround {
		grounded = true
	} else if k.phase == phaseRecover {
		grounded = true
	}
	clr := negInf
	if grounded || k.pos.y <= e.scale {
		stale := true
		if !k.clrOK {
		} else if k.clrS != k.lean.s {
		} else if k.clrC != k.lean.c {
		} else {
			stale = false
		}
		if stale {
			k.clr = e.clearance(k)
			k.clrS, k.clrC, k.clrOK = k.lean.s, k.lean.c, true
		}
		clr = k.clr
	}
	if grounded || k.pos.y < clr {
		k.pos = vec{k.pos.x, clr, k.pos.z}
		if k.phase == phaseAir {
			if k.vel.y <= 0 {
				k.phase = phaseGround
				k.groundT = 0
			}
		}
		if grounded {
			k.vel = vec{k.vel.x, 0, k.vel.z}
		} else if k.vel.y < 0 {
			k.vel = vec{k.vel.x, 0, k.vel.z}
		}
	}
	e.armsAboveGround(k)

	if k.plant.on {
		S := e.scale
		hx := k.pos.x + 0.11*k.plant.side*S*k.lean.c
		hy := k.pos.y - 0.11*k.plant.side*S*k.lean.s
		dx := k.plant.x - hx
		dy := k.plant.y - hy
		maxL := 0.85 * S * kPlantStretch
		if t > k.plantUntil || dx*dx+dy*dy > maxL*maxL {
			k.plant = plant{}
		}
	}
}
