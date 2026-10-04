package penalty

// Outcome of a single kick.
type Outcome uint8

const (
	OutcomeGoal Outcome = iota + 1
	OutcomeSave
	OutcomeMiss
	OutcomePost
)

func (o Outcome) String() string {
	switch o {
	case OutcomeGoal:
		return "goal"
	case OutcomeSave:
		return "save"
	case OutcomeMiss:
		return "miss"
	case OutcomePost:
		return "woodwork"
	}
	return "unknown"
}

// Scored reports whether the kick counts as a goal.
func (o Outcome) Scored() bool { return o == OutcomeGoal }

// Result is what SimulateShot reports.
type Result struct {
	Outcome   Outcome
	X, Y      int64 // where the ball crosses (or would cross) the goal line, mm
	ArrivalMS int64 // time from contact to the line
	BallSpeed int64 // mm/s
	MishitX   int64 // contact error the mishit seed added, milli-radii
	MishitY   int64
	Keeper    Mode
}

// SimulateShot decides a kick from its ten inputs: the taker's six (five
// choices plus the mishit seed) and the keeper's four, played with the
// game's constants. It is a pure function: the same inputs give the same
// Result on every node, so anyone can re-run it to check a recorded kick.
//
// SUPERSEDED. This is the coarse integer model the realm used before the
// physics engine was ported (gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/penalty/physics/v0, which
// matches the browser game bit for bit and is what impl/v1 calls). It is kept
// so that kicks recorded under it can still be re-run.
func SimulateShot(shot ShotParams, plan KeeperPlan, c Config) Result {
	power := clampI(shot.Power, 0, 1000)

	// The boot lands off the chosen contact by a seeded, power-dependent error.
	sigma := c.FuzzBase + c.FuzzPower*power/1000
	mx := normalPermille(shot.Mishit, 0) * sigma / 1000
	my := normalPermille(shot.Mishit, 12) * sigma / 1000
	cx := clampI(shot.ContactX+mx, -800, 800)
	cy := clampI(shot.ContactY+my, -800, 800)

	// Glancing contact loses pace: about 1 - r²/2 of a centred strike.
	eff := 1000 - (cx*cx+cy*cy)*225/1000000
	speed := (c.BallMinSpeed + (c.BallMaxSpeed-c.BallMinSpeed)*power/1000) * eff / 1000
	t := Distance * 1000 / speed // ms to the line

	// Striking the right side sends the ball left and curls it further left;
	// hitting below centre lifts it, above centre dips it; gravity drops it.
	x := shot.AimX - cx*CurlPerMilliR/10
	drop := Gravity * t * t / 2 / 1000000
	y := shot.AimY - drop - cy*LiftPerMilliR/10
	if y < BallRadius {
		y = BallRadius
	}

	d := DecodePlan(plan, c)
	res := Result{X: x, Y: y, ArrivalMS: t, BallSpeed: speed, MishitX: mx, MishitY: my, Keeper: d.Mode}

	halfW := c.GoalWidth / 2
	ax := absI(x)
	inside := ax <= halfW-BallRadius && y <= c.GoalHeight-BallRadius
	clear := ax >= halfW+2*PostRadius+BallRadius || y >= c.GoalHeight+2*PostRadius+BallRadius
	switch {
	case clear:
		res.Outcome = OutcomeMiss
	case !inside:
		res.Outcome = OutcomePost
	case keeperCovers(d, c, shot, x, y, t, cx):
		res.Outcome = OutcomeSave
	default:
		res.Outcome = OutcomeGoal
	}
	return res
}

const (
	CurlPerMilliR = 45 // tenths of a mm of sideways travel per milli-radius of side contact
	LiftPerMilliR = 28 // tenths of a mm of lift per milli-radius below centre
	LaunchShare   = 20 // tenths of a mm of that sideways travel visible in the launch direction
)

// keeperCovers is the placeholder keeper: whether its body and hands reach
// (x, y) by the time the ball arrives (t ms after contact).
func keeperCovers(d Plan, c Config, shot ShotParams, x, y, t, cx int64) bool {
	s := c.KeeperScale
	reach := 900 * s / 1000 // hips to fingertips, sideways
	switch d.Mode {
	case ModeStar:
		// Spread wide in the middle of the goal, off the ground.
		return absI(x) <= 1100*s/1000 && y >= 450*s/1000
	case ModeRead:
		// Commits after seeing the ball: the slower the shot, the further it
		// gets. It reads the launch line, not the curl.
		commit := 160 + d.Reaction
		avail := t - commit
		if avail <= 0 {
			return absI(x) <= 350*s/1000 && y <= 1800*s/1000
		}
		predicted := shot.AimX - cx*LaunchShare/10
		cover := minI(reach+3500*avail/1000, c.GoalWidth/2+200)
		return absI(predicted) <= cover && absI(x-predicted) <= 450*s/1000
	}
	// Committed dive: the hips travel along the heading once the push-off
	// starts, the hands reach out from there, and the jump sets the height
	// band it covers.
	moving := t - d.Reaction - 60
	if moving < 0 {
		moving = 0
	}
	vx := d.Speed * cosPermille(d.Heading) / 1000
	hipX := clampI(vx*moving/1000, -2600*s/1000, 2600*s/1000)
	if absI(x) <= 300 && moving < 150 {
		return true // straight at a keeper that has barely left the spot
	}
	centre := 900 + d.Jump*450/1000
	band := 650 * s / 1000
	return absI(x-hipX) <= reach+150 && y >= centre-band && y <= centre+band
}

// normalPermille turns 12 bytes of a mishit seed into an approximately
// standard-normal value × 1000: six uint16 uniforms summed (Irwin-Hall,
// n = 6), centred and scaled.
func normalPermille(m [24]byte, offset int) int64 {
	var sum int64
	for i := 0; i < 6; i++ {
		sum += int64(u16(m[offset+2*i : offset+2*i+2]))
	}
	return (sum - 3*65535) * 1414 / 65535
}
