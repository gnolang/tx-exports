package arena

import (
	"chain"
	"strings"

	"gno.land/p/g1t2kg2vtr3fukg43eujkn6x53gfdyakhngt4sfd/gnofly/arena/payout/v0"
)

// round is the started game of an arena. Its players are fixed at start, and
// each of them has one stake in it.
type round struct {
	startedAt int64     // block time, Unix seconds
	players   []address // in the order they entered
}

// A game ends in exactly one of three ways: SettleRound, CancelRound or
// RefundRound. Each of them deletes the arena before anything else, so a
// second one finds no arena and aborts.

// StartRound starts the game of an arena with every player of its lobby.
// Referee only. The lobby must hold at least minSeats players; it holds at
// most maxSeats, Enter sees to that. No coin moves: the stakes that were
// owed to the lobby are now owed to the round. It returns how many play.
func StartRound(cur realm, id string) int64 {
	referee := assertReferee(0, cur)
	a := mustArena(id)
	if a.round != nil {
		panic(errRoundRunning)
	}
	if int64(len(a.lobby)) < a.minSeats {
		panic(errTooFewPlayers)
	}
	a.round = &round{startedAt: now(), players: a.lobby}
	a.lobby = nil
	a.tickets = nil

	chain.Emit("RoundStarted",
		"arena", id,
		"players", joinAddrs(a.round.players),
		"startedAt", itoa(a.round.startedAt),
		"referee", referee.String(),
	)
	return int64(len(a.round.players))
}

// SettleRound closes the game of an arena: it applies the rule of its mode
// to what happened, pays the players, and pays the fee to the treasury.
// Referee only.
//
// deaths is "victim:killer" entries separated by ";", in the order they
// happened, "victim:" when nobody shot the victim down, and the empty
// string when nobody died. A player dies at most as often as the arena has
// lives.
//
// The referee is trusted for these facts and for nothing else. The rule
// refuses a victim or a killer who is not a player of the round, and decides
// the amounts. The realm then checks them (see settle) before it pays.
func SettleRound(cur realm, id string, deaths string) {
	referee := assertReferee(0, cur)
	a := runningArena(id)
	list, err := payout.ParseDeaths(deaths)
	if err != nil {
		panic(err)
	}
	rule := payout.Lookup(a.mode)
	if rule == nil {
		panic(errInvalidMode) // cannot happen: parseSpec checked the mode
	}
	// The rule gets a copy of the players: the list the realm pays from is
	// not one a rule can touch.
	players := make([]address, len(a.round.players))
	copy(players, a.round.players)
	g := payout.Game{Stake: a.stake, Lives: a.lives, KillTarget: a.killTarget, FeeBps: feeBps}
	res, err := rule.Settle(g, players, list)
	if err != nil {
		panic(err)
	}
	settle(0, cur, id, a, res, referee)
}

// settle closes the game of an arena with the result of its rule.
//
// It trusts nothing about the result. Before a counter or a coin moves,
// checkResult verifies that only players of the round are paid and that the
// payouts and the fee add up to the pot, to the ugnot.
func settle(_ int, rlm realm, id string, a *arena, res payout.Result, referee address) {
	r := a.round
	pot := a.stake * int64(len(r.players))
	checkResult(pot, r.players, res)

	// The fee goes to the treasury of the game realm as it is now. If that
	// is not an address the realm can pay, the fee goes back to the players
	// instead: shared by the order of the round, the remainder to the first.
	fee := res.Fee
	payouts := res.Payouts
	treasury := roles.Treasury()
	if fee > 0 && (!validAddress(treasury) || treasury == rlm.Address()) {
		payouts = withFeeShared(r.players, payouts, fee)
		fee = 0
	}

	// State first: the arena is gone and its pot is off the books before the
	// first coin leaves.
	arenas.Remove(id)
	release(pot)
	record(id, result{
		mode:     a.mode,
		stake:    a.stake,
		outcome:  outcomeSettled,
		players:  int64(len(r.players)),
		pot:      pot,
		fee:      fee,
		closedAt: now(),
		payouts:  payouts,
	})
	creditRound(a.stake, r.players, payouts)

	// The winnings stay in the realm until each player claims them: a
	// settlement sends no coin to a player, so it cannot fail on one.
	for _, p := range payouts {
		credit(p.Address, id, p.Amount)
	}
	if fee > 0 {
		pay(0, rlm, treasury, fee)
	}
	assertSolvent(0, rlm)

	chain.Emit("RoundSettled",
		"arena", id,
		"players", itoa(int64(len(r.players))),
		"pot", itoa(pot),
		"fee", itoa(fee),
		"payouts", joinPayouts(payouts),
		"treasury", treasury.String(),
		"referee", referee.String(),
	)
}

// withFeeShared returns payouts with fee added, shared between every player
// of the round, in their order: the remainder goes to the first.
func withFeeShared(players []address, payouts []payout.Payout, fee int64) []payout.Payout {
	each := fee / int64(len(players))
	extra := fee - each*int64(len(players))
	out := make([]payout.Payout, 0, len(players))
	for i, p := range players {
		amount := each
		if i == 0 {
			amount += extra
		}
		for _, q := range payouts {
			if q.Address == p {
				amount += q.Amount
			}
		}
		if amount > 0 {
			out = append(out, payout.Payout{Address: p, Amount: amount})
		}
	}
	return out
}

// checkResult panics unless a result can be paid out of a pot: every payout
// goes to a player of the round, a player is paid at most once and never
// zero or less, the fee is not negative, and all of it adds up to the pot
// exactly.
//
// The built-in rules guarantee all of this. The check is here so that the
// realm does not depend on it: whatever a rule returns, the realm never
// sends more than the pot, and never to a stranger.
func checkResult(pot int64, players []address, res payout.Result) {
	// Every amount is bounded by the pot before it is added, so the sum
	// cannot overflow: at most 9 terms of at most 8e9.
	if res.Fee < 0 || res.Fee > pot {
		panic(errNotConserved)
	}
	sum := res.Fee
	paid := make([]bool, len(players))
	for _, p := range res.Payouts {
		seat := indexOfAddr(players, p.Address)
		if seat < 0 || paid[seat] || p.Amount <= 0 {
			panic(errBadSettlement)
		}
		if p.Amount > pot {
			panic(errNotConserved)
		}
		paid[seat] = true
		sum += p.Amount
	}
	if sum != pot {
		panic(errNotConserved)
	}
}

// CancelRound closes the game of an arena without a result: every player
// gets their stake back in full. Referee only.
//
// The game server uses it for a game it cannot referee, for example one it
// finds running when it starts.
func CancelRound(cur realm, id string) {
	referee := assertReferee(0, cur)
	a := runningArena(id)
	refund(0, cur, id, a, outcomeCancelled, "RoundCancelled", referee)
}

// RefundRound closes the game of an arena without a result, like
// CancelRound, and can be called by anyone, once
//
//	startedAt + seconds + RefundDelay()
//
// has passed on the block clock. It is the players' way out when the
// referee never settles: no stake depends on a server staying up.
func RefundRound(cur realm, id string) {
	caller := callerOf(0, cur)
	a := runningArena(id)
	if now() < a.round.startedAt+a.seconds+refundDelay {
		panic(errRefundTooEarly)
	}
	refund(0, cur, id, a, outcomeRefunded, "RoundRefunded", caller)
}

// refund closes the game of an arena and sends every player their stake
// back. No fee is taken.
func refund(_ int, rlm realm, id string, a *arena, outcome, event string, caller address) {
	r := a.round
	pot := a.stake * int64(len(r.players))
	payouts := make([]payout.Payout, len(r.players))
	for i, p := range r.players {
		payouts[i] = payout.Payout{Address: p, Amount: a.stake}
	}

	// State first, as in settle.
	arenas.Remove(id)
	release(pot)
	record(id, result{
		mode:     a.mode,
		stake:    a.stake,
		outcome:  outcome,
		players:  int64(len(r.players)),
		pot:      pot,
		closedAt: now(),
		payouts:  payouts,
	})

	for _, p := range r.players {
		pay(0, rlm, p, a.stake)
	}
	assertSolvent(0, rlm)

	chain.Emit(event,
		"arena", id,
		"players", itoa(int64(len(r.players))),
		"pot", itoa(pot),
		"caller", caller.String(),
	)
}

// runningArena returns an arena whose game is running. It panics for an
// unknown arena and for one whose game has not started.
func runningArena(id string) *arena {
	a := mustArena(id)
	if a.round == nil {
		panic(errNoRound)
	}
	return a
}

// Refund delay bounds, in seconds.
const (
	minRefundDelay = 60
	maxRefundDelay = 86400
)

// SetRefundDelay sets how long after a game's time limit anyone may refund
// it. Admin only.
func SetRefundDelay(cur realm, seconds int64) {
	assertAdmin(0, cur)
	if seconds < minRefundDelay || seconds > maxRefundDelay {
		panic(errInvalidRefundDelay)
	}
	refundDelay = seconds
	version++
	chain.Emit("RefundDelaySet", "seconds", itoa(seconds))
}

// RefundDelay returns the refund delay, in seconds.
func RefundDelay() int64 {
	return refundDelay
}

// joinAddrs writes addresses separated by commas, for an event.
func joinAddrs(list []address) string {
	var b strings.Builder
	for i, a := range list {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString(a.String())
	}
	return b.String()
}

// joinPayouts writes payouts as "address:amount" separated by commas, for
// an event and for the stored results.
func joinPayouts(list []payout.Payout) string {
	var b strings.Builder
	for i, p := range list {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString(p.Address.String())
		b.WriteByte(':')
		b.WriteString(itoa(p.Amount))
	}
	return b.String()
}
