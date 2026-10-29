package engine

// Victory point awards (rule 15), for showdowns where each character is a
// side of its own: there are no allies (no "Ally killed"), and no special
// rule captures or kills anyone.
const (
	VPSurvive   = "survive"         // +2: conscious and unsurrendered at the end (15.62)
	VPHoldField = "hold_field"      // +2: the only side with survivors (15.63)
	VPSurrender = "surrender"       // -2 (15.41)
	VPCaptured  = "captured"        // -4: passed out or surrendered when the enemy holds the field (15.63, 15.7)
	VPKilled    = "killed"          // -8 (15.2)
	VPKill      = "kill_enemy"      // +2: the enemy who killed him (15.2)
	VPKnockOut  = "knock_out_enemy" // +1: the enemy who crossed off most of his endurance boxes (15.3, 15.41)
	VPRunAway   = "run_away"        // -2: moved off the map (15.5); no end-of-showdown points (15.6)
)

// VPPoints is what each award is worth (the VICTORY POINTS schedule, 15.11).
// Passing out is worth 0 and makes no award.
var VPPoints = map[string]int{
	VPSurvive:   2,
	VPHoldField: 2,
	VPSurrender: -2,
	VPCaptured:  -4,
	VPKilled:    -8,
	VPKill:      2,
	VPKnockOut:  1,
	VPRunAway:   -2,
}

// VPSharedKill is what each enemy gets when several KILLs land in the same
// segment: 15.2 shares the "Kill enemy" points, kept whole here.
const VPSharedKill = 1

// Award is victory points a character earns (Points > 0) or loses.
type Award struct {
	Player int
	Reason string // one of the VP* names
	Points int
}

// TurnVictoryPoints scores what a turn did, from the characters before and
// after it: a character killed loses the "Killed" points and the enemy
// whose hit killed it gets "Kill enemy" (15.2, Character.Killers), or,
// when several enemies share the kill, 1 point each (kept whole); one
// who passed out gets nothing and the enemy who crossed off most of its
// endurance boxes "Knock out enemy" (15.3, Character.Hurt). A character
// who is not up cannot be hit, so a knocked-out one is never killed
// afterwards.
func TurnVictoryPoints(before, after State) []Award {
	var out []Award
	for p, c := range after.Chars {
		if p >= len(before.Chars) || before.Chars[p].Status != Alive {
			continue
		}
		switch c.Status {
		case Killed:
			out = append(out, award(p, VPKilled))
			var killers []int
			for q, k := range c.Killers {
				if k && q != p && q < len(after.Chars) {
					killers = append(killers, q)
				}
			}
			for _, q := range killers {
				if len(killers) == 1 {
					out = append(out, award(q, VPKill))
				} else {
					out = append(out, Award{Player: q, Reason: VPKill, Points: VPSharedKill})
				}
			}
		case PassedOut:
			if k := knockedOutBy(c); k >= 0 {
				out = append(out, award(k, VPKnockOut))
			}
		case RanAway:
			out = append(out, award(p, VPRunAway))
		}
	}
	return out
}

// knockedOutBy is the enemy who crossed off most of the character's
// endurance boxes (15.3): the first in seat order when two did as much,
// NoSeat when nobody did.
func knockedOutBy(c Character) int {
	best, most := NoSeat, 0
	for q, n := range c.Hurt {
		if n > most {
			best, most = q, n
		}
	}
	return best
}

// EndVictoryPoints scores the end of the showdown (15.6): a character still
// up survives, and holds the field when it is the only one (15.62, 15.63);
// Out stands for a surrendered character, who loses the "Surrender" points
// and, like passing out, gives "Knock out enemy" to the enemy who crossed
// off most of its endurance boxes (15.41); passed out or surrendered, a
// character is captured when an enemy holds the field (15.63, 15.7).
func EndVictoryPoints(s State) []Award {
	var out []Award
	survivors := AliveCount(s)
	for p, c := range s.Chars {
		holds := survivors == 1 && c.Status != Alive // someone else holds the field
		switch c.Status {
		case Alive:
			out = append(out, award(p, VPSurvive))
			if survivors == 1 {
				out = append(out, award(p, VPHoldField))
			}
		case Out:
			out = append(out, award(p, VPSurrender))
			if k := knockedOutBy(c); k >= 0 {
				out = append(out, award(k, VPKnockOut))
			}
			if holds {
				out = append(out, award(p, VPCaptured))
			}
		case PassedOut:
			if holds {
				out = append(out, award(p, VPCaptured))
			}
		}
	}
	return out
}

func award(p int, reason string) Award {
	return Award{Player: p, Reason: reason, Points: VPPoints[reason]}
}

// VPEvents are the awards as end-of-turn events of the turn's log.
func VPEvents(awards []Award) []Event {
	evs := make([]Event, 0, len(awards))
	for _, a := range awards {
		evs = append(evs, Event{Seg: EndOfTurn, Player: a.Player, Kind: EvVP, N: a.Points, Reason: a.Reason})
	}
	return evs
}

// VPTotals adds the awards up per seat, for n seats.
func VPTotals(awards []Award, n int) []int {
	t := make([]int, n)
	for _, a := range awards {
		if a.Player >= 0 && a.Player < n {
			t[a.Player] += a.Points
		}
	}
	return t
}
