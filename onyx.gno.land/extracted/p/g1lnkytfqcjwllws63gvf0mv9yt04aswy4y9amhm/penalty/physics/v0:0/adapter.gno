package physics

import "gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/penalty/v0"

// ParamsOf converts a game's constants from the realm's integer units (mm,
// mm/s, ms, per-mille, milli-radii) to the engine's. The defaults convert to
// DefaultParams exactly: each division is correctly rounded, so 2424/1000 is
// the same double as the browser's literal 2.424.
func ParamsOf(c penalty.Config) Params {
	return Params{
		GoalHalfWidth: float64(c.GoalWidth) / 2000,
		GoalHeight:    float64(c.GoalHeight) / 1000,
		KeeperScale:   float64(c.KeeperScale) / 1000,
		ReactionMin:   float64(c.ReactionMin) / 1000,
		ReactionMax:   float64(c.ReactionMax) / 1000,
		StarShare:     float64(c.StarShare) / 1000,
		ReadShare:     float64(c.ReadShare) / 1000,
		DiveMin:       float64(c.DiveMin) / 1000,
		DiveMax:       float64(c.DiveMax) / 1000,
		JumpMin:       float64(c.JumpMin) / 1000,
		JumpMax:       float64(c.JumpMax) / 1000,
		BallMinSpeed:  float64(c.BallMinSpeed) / 1000,
		BallMaxSpeed:  float64(c.BallMaxSpeed) / 1000,
		FuzzBase:      float64(c.FuzzBase) / 1000,
		FuzzPower:     float64(c.FuzzPower) / 1000,
		MaxContact:    float64(c.MaxContact) / 1000,
	}
}

// ShotOf converts the taker's ten-input half (integer units plus the mishit
// seed) to the engine's units, as the web game does: each value / 1000.
func ShotOf(s penalty.ShotParams) Shot {
	return Shot{
		AimX:      float64(s.AimX) / 1000,
		AimY:      float64(s.AimY) / 1000,
		ContactX:  float64(s.ContactX) / 1000,
		ContactY:  float64(s.ContactY) / 1000,
		Power:     float64(s.Power) / 1000,
		Mishit:    s.Mishit,
		HasMishit: true,
	}
}

// SimulateShot is the realm's outcome function on this engine: the taker's
// six inputs and the keeper's four, under a game's constants.
func SimulateShot(shot penalty.ShotParams, plan penalty.KeeperPlan, cfg penalty.Config) penalty.Result {
	prm := ParamsOf(cfg)
	pl := DecodePlan([4]uint16{plan.Direction, plan.Speed, plan.Jump, plan.Reaction}, prm)
	r := Simulate(ShotOf(shot), pl, prm, Options{})
	return ResultOf(r, pl)
}

// ResultOf summarises a decided kick in the realm's integer units.
func ResultOf(r Result, pl Plan) penalty.Result {
	out := penalty.Result{
		BallSpeed: int64(jsRound(r.Launch.Speed * 1000)),
		MishitX:   int64(jsRound(r.Launch.FuzzX * 1000)),
		MishitY:   int64(jsRound(r.Launch.FuzzY * 1000)),
	}
	switch r.Outcome {
	case Goal:
		out.Outcome = penalty.OutcomeGoal
	case Save:
		out.Outcome = penalty.OutcomeSave
	case Miss:
		out.Outcome = penalty.OutcomeMiss
	case Post:
		out.Outcome = penalty.OutcomePost
	}
	switch pl.Mode {
	case ModeStar:
		out.Keeper = penalty.ModeStar
	case ModeRead:
		out.Keeper = penalty.ModeRead
	default:
		out.Keeper = penalty.ModeDive
	}
	// Where the ball reached the goal line, or failing that where it was
	// when the kick was decided (kept out before the line).
	if r.LineCross {
		out.X = int64(jsRound(r.LineX * 1000))
		out.Y = int64(jsRound(r.LineY * 1000))
		out.ArrivalMS = int64(jsRound(r.LineT * 1000))
	} else {
		out.X = int64(jsRound(r.EndX * 1000))
		out.Y = int64(jsRound(r.EndY * 1000))
		out.ArrivalMS = int64(jsRound(r.DecidedAt * 1000))
	}
	return out
}
