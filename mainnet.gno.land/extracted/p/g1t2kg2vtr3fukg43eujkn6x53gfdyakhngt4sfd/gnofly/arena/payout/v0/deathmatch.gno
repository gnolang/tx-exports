package payout

// rankWeights are the shares of the top three by kills, in basis points.
var rankWeights = [3]int64{6000, 3000, 1000}

// Deathmatch pays the most kills. The pot is every stake; the fee is taken from
// it, and the rest goes to the top three by kills: 60%, 30% and 10%.
//
//   - Only players with at least one kill are ranked. With fewer than three
//     of them, the shares of the ranks they fill are rescaled to the whole:
//     one killer takes everything, two take 2/3 and 1/3.
//   - Players with as many kills share the ranks they hold: two tied first
//     split 60% + 30%, and the next one is third.
//   - When nobody killed anybody, every player gets their stake back and the
//     house takes nothing.
//
// Deaths cost nothing here beyond the lives they take. What rounding leaves
// over goes to the fee.
type Deathmatch struct{}

var _ Rule = Deathmatch{}

func (Deathmatch) Mode() string { return ModeDeathmatch }

func (Deathmatch) Settle(g Game, players []address, deaths []Death) (Result, error) {
	t, err := check(g, players, deaths)
	if err != nil {
		return Result{}, err
	}
	pot := g.Stake * int64(len(players))

	// Killers, most kills first; equal kills keep the order of the players.
	var ranked []int
	for i := range players {
		if t.kills[i] == 0 {
			continue
		}
		at := len(ranked)
		for at > 0 && t.kills[ranked[at-1]] < t.kills[i] {
			at--
		}
		ranked = append(ranked, 0)
		copy(ranked[at+1:], ranked[at:])
		ranked[at] = i
	}
	if len(ranked) == 0 {
		res := Result{}
		for _, p := range players {
			res.Payouts = append(res.Payouts, Payout{Address: p, Amount: g.Stake})
		}
		return res, nil
	}

	filled := len(ranked)
	if filled > len(rankWeights) {
		filled = len(rankWeights)
	}
	whole := int64(0)
	for _, w := range rankWeights[:filled] {
		whole += w
	}

	prize := afterFee(pot, g.FeeBps)
	amounts := make([]int64, len(players))
	for pos := 0; pos < filled; {
		end := pos + 1
		for end < len(ranked) && t.kills[ranked[end]] == t.kills[ranked[pos]] {
			end++
		}
		weight := int64(0)
		for r := pos; r < end && r < filled; r++ {
			weight += rankWeights[r]
		}
		group := int64(end - pos)
		// prize <= 8e12 and weight <= 1e4: the product stays far below 2^63.
		each := prize * weight / (whole * group)
		for _, i := range ranked[pos:end] {
			amounts[i] = each
		}
		pos = end
	}

	res := Result{Fee: pot}
	for i, p := range players {
		if amounts[i] > 0 {
			res.Payouts = append(res.Payouts, Payout{Address: p, Amount: amounts[i]})
			res.Fee -= amounts[i]
		}
	}
	return res, nil
}
