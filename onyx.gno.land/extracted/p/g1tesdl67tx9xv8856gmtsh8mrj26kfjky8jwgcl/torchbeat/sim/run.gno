package sim

// Result is the verdict of replaying a log.
type Result struct {
	Cleared   bool
	Beats     uint16
	Damage    uint8
	Kills     uint8
	Chest     bool
	RouteHash uint32
	FailBeat  uint16
	Reason    string
}

// Run replays log (one char '0'..'8' per beat) on m. FailBeat is the number of
// beats elapsed when the run failed (the Beat counter after the failing step).
func Run(m *Map, relic uint8, log string) Result {
	return RunFrom(m, relic, 0, log)
}

// RunFrom is Run starting at hp (see NewGameFrom). HP left after a clear is
// hp - int8(Result.Damage).
func RunFrom(m *Map, relic uint8, hp int8, log string) Result {
	if len(log) == 0 {
		return Result{Reason: "empty"}
	}
	if len(log) > MaxBeats {
		return Result{Reason: "long"}
	}
	n := len(log)
	for i := 0; i < n; i++ {
		if c := log[i]; c < '0' || c > '8' {
			return Result{Reason: "char"}
		}
	}
	g := NewGameFrom(m, relic, hp)
	reason := "unfinished"
	for i := 0; i < n; i++ {
		g.Step(log[i] - '0')
		if g.Dead || g.Won {
			switch {
			case g.Dead:
				reason = "dead"
			case i == n-1:
				reason = "ok"
			default:
				reason = "trailing"
			}
			break
		}
	}
	r := Result{
		Beats:     g.Beat,
		Damage:    g.Damage,
		Kills:     g.Kills,
		Chest:     g.Chest,
		RouteHash: g.Route,
		Reason:    reason,
	}
	if reason == "ok" {
		r.Cleared = true
	} else {
		r.FailBeat = g.Beat
	}
	return r
}
