// v0 - Unaudited: This is an initial version that has not yet been formally audited.
// Use in production at your own risk.
//
// Package payout defines how the stakes of a gnofly arena round are shared
// out once the round is over: a Rule turns what happened, who died and by
// whose hand, into who gets what.
//
// The package is pure: it holds no state, moves no coin and knows nothing
// about roles. A realm keeps the stakes, asks a rule for a Result and makes
// the payments itself:
//
//	players, err := payout.ParsePlayers("g1aaa...,g1bbb...,g1ccc...")
//	if err != nil {
//		panic(err)
//	}
//	deaths, err := payout.ParseDeaths("g1bbb...:g1aaa...;g1ccc...:")
//	if err != nil {
//		panic(err)
//	}
//	g := payout.Game{Stake: 10000000, Lives: 3, KillTarget: 0, FeeBps: 500}
//	res, err := payout.Lookup(payout.ModeDeathmatch).Settle(g, players, deaths)
//
// Two rules ship with the package, both stateless values with no field:
//
//   - BattleRoyale: the pot goes to the players still in at the end, or to
//     the last one out;
//   - Deathmatch: the pot goes to the top three by kills, 60%, 30% and 10%.
//
// Every rule conserves the pot. For any input a rule accepts,
//
//	sum(res.Payouts) + res.Fee == Stake * len(players)
//
// and nobody but a player of the round is ever paid. What is not paid to a
// player is the house's cut, the fee. Amounts are rounded down, and what
// rounding leaves over goes to the fee. A realm that pays out real coins
// should still check both properties on the Result it gets before it sends
// anything: that check is cheap, and it is what keeps a mistake in a rule
// from becoming a loss.
package payout
