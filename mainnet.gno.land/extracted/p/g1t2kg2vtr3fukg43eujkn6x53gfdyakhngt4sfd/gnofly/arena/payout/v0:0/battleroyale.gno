package payout

// BattleRoyale is the winner-takes-all rule. The pot is every stake; the fee is
// taken from it, and the rest goes to:
//
//   - the last player in;
//   - when the clock ran out with several in, the one of them with the most
//     kills, and players still in with as many kills share it equally;
//   - and when everyone is out, the player who went out last.
//
// It is won by staying in the air, not by scoring: the kill target is
// ignored, and the arena realm refuses a battle-royale spec that has one.
//
// What the split leaves over goes to the fee.
type BattleRoyale struct{}

var _ Rule = BattleRoyale{}

func (BattleRoyale) Mode() string { return ModeBattleRoyale }

func (BattleRoyale) Settle(g Game, players []address, deaths []Death) (Result, error) {
	t, err := check(g, players, deaths)
	if err != nil {
		return Result{}, err
	}
	// The most kills among the players still in.
	best := int64(-1)
	for i := range players {
		if !t.out(i, g.Lives) && t.kills[i] > best {
			best = t.kills[i]
		}
	}
	won := make([]bool, len(players))
	winners := int64(0)
	for i := range players {
		if !t.out(i, g.Lives) && t.kills[i] == best {
			won[i] = true
			winners++
		}
	}
	if winners == 0 {
		won[t.lastOut] = true
		winners = 1
	}

	pot := g.Stake * int64(len(players))
	share := afterFee(pot, g.FeeBps) / winners
	res := Result{Fee: pot - share*winners}
	if share == 0 {
		return res, nil // a pot too small to split: nobody is paid
	}
	for i, p := range players {
		if won[i] {
			res.Payouts = append(res.Payouts, Payout{Address: p, Amount: share})
		}
	}
	return res, nil
}
