package engine

// LegalPlans lists every plan side can play from deck in state s: costs summing to 3,
// basics any number of times, each unspent special of deck at most once. Plans come in
// card order, depth first.
func (rs *Ruleset) LegalPlans(s State, side Side, deck uint64) []Plan {
	var buf [beatsPerRound]CardID
	return rs.extendPlans(nil, buf[:0], 0, deck&^s.Gnomes[side].Spent, 0)
}

func (rs *Ruleset) extendPlans(out []Plan, plan Plan, beats int, available, used uint64) []Plan {
	if beats == beatsPerRound {
		done := make(Plan, len(plan))
		copy(done, plan)
		return append(out, done)
	}
	for i := range rs.Cards {
		c := &rs.Cards[i]
		if beats+c.Cost > beatsPerRound {
			continue
		}
		bit := uint64(1) << uint(i)
		if c.Special && (available&bit == 0 || used&bit != 0) {
			continue
		}
		out = rs.extendPlans(out, append(plan, CardID(i)), beats+c.Cost, available, used|bit)
	}
	return out
}
