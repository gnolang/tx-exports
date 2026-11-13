package poker

import (
	"strconv"

	"gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/poker/cards"
	"gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/poker/holdem"
)

// Hand phases.
const (
	phShuffle = iota
	phRekey
	phDealHole
	phPreflop
	phDealFlop
	phFlop
	phDealTurn
	phTurn
	phDealRiver
	phRiver
	phReveal
	phChallenge
	phDone
)

var phaseNames = []string{
	"shuffle", "rekey", "deal_hole", "preflop", "deal_flop", "flop",
	"deal_turn", "turn", "deal_river", "river", "reveal", "challenge", "done",
}

// HandPlayer is a seat's participation in one hand.
type HandPlayer struct {
	Seat     int
	Owner    address
	Commit   string         // hex
	Seed     string         // hex, after reveal
	Keys     map[int]string // position -> hex card key
	Revealed bool
	Accepted bool
}

// ChallengeRecord is one resolved challenge.
type ChallengeRecord struct {
	Challenger int
	Accused    int
	Kind       string
	Index      int
	Guilty     bool
}

// Result is the outcome of a hand. Credits are what settlement adds to each
// hand player's stack (winnings, or refund plus penalty share on abort).
type Result struct {
	Aborted    bool
	Convicted  []int
	Stallers   []int
	Credits    []int64
	Scores     []int
	Challenges []ChallengeRecord
}

// Hand is the state of the current or last hand of a table.
type Hand struct {
	No       uint64
	Phase    int
	Players  []*HandPlayer
	Bet      *holdem.Betting
	Roots    []string // hex root per accepted deck pass
	Owing    []bool   // per player, for deal steps
	Deadline int64
	Cards    []int // official card per position, after reveal
	Result   *Result
	Settled  bool // contributions have been paid out or refunded
}

// maxSeats is the largest table; per-player buffers are sized by it.
const maxSeats = holdem.MaxPlayers

// n is the number of players in the hand, at most maxSeats.
func (h *Hand) n() int { return len(h.Players) }

func (h *Hand) playerIndex(seat int) int {
	for j, p := range h.Players {
		if p.Seat == seat {
			return j
		}
	}
	return -1
}

func isBettingPhase(ph int) bool {
	return ph == phPreflop || ph == phFlop || ph == phTurn || ph == phRiver
}

func isDealPhase(ph int) bool {
	return ph == phDealHole || ph == phDealFlop || ph == phDealTurn || ph == phDealRiver
}

// turnIndex is the player expected to act in an in-turn phase, else -1.
func (h *Hand) turnIndex() int {
	switch {
	case h.Phase == phShuffle:
		return len(h.Roots)
	case h.Phase == phRekey:
		return len(h.Roots) - h.n()
	case isBettingPhase(h.Phase):
		return h.Bet.Turn
	}
	return -1
}

// owedPositions lists the positions player j must share keys for in the
// current deal step, ascending.
func (h *Hand) owedPositions(j int) []int {
	n := h.n()
	out := []int{}
	switch h.Phase {
	case phDealHole:
		for i := 0; i < 2*n; i++ {
			if i/2 != j {
				out = append(out, i)
			}
		}
	case phDealFlop:
		out = append(out, 2*n, 2*n+1, 2*n+2)
	case phDealTurn:
		out = append(out, 2*n+3)
	case phDealRiver:
		out = append(out, 2*n+4)
	}
	return out
}

func (t *Table) eligible(i int) bool {
	s := t.Seats[i]
	return s != nil && !s.SittingOut && !s.Leaving && s.Stack >= t.BigBlind
}

// StartHand moves the button, posts blinds and opens the shuffle.
func StartHand(cur realm, tableID uint64) {
	assertNoSend(cur)
	ctx := newCtx(cur)
	t := getTable(tableID)
	t.authSeat(ctx.caller)
	if t.Hand != nil && t.Hand.Phase != phDone {
		panic("a hand is in progress")
	}
	m := t.MaxPlayers
	seats := []int{}
	for k := 1; k <= m; k++ {
		i := (t.Button + k + m) % m
		if t.eligible(i) {
			seats = append(seats, i)
		}
	}
	if len(seats) < 2 {
		panic("need at least 2 active players with a stack of at least the big blind")
	}
	// seats starts with the new button.
	button := seats[0]
	order := []int{}
	if len(seats) == 2 {
		order = append(order, seats[0], seats[1])
	} else {
		order = append(order, seats[1:]...)
		order = append(order, button)
	}
	t.Button = button
	t.HandNo++
	for _, s := range t.Seats {
		if s != nil {
			s.Waiting = false
		}
	}
	if len(order) > maxSeats {
		panic("too many players")
	}
	var stackBuf [maxSeats]int64
	stacks := stackBuf[:len(order):len(order)]
	players := make([]*HandPlayer, len(order))
	for j, si := range order {
		stacks[j] = t.Seats[si].Stack
		players[j] = &HandPlayer{Seat: si, Owner: t.Seats[si].Owner, Keys: map[int]string{}}
	}
	h := &Hand{
		No:       t.HandNo,
		Phase:    phShuffle,
		Players:  players,
		Bet:      holdem.NewBetting(stacks, t.SmallBlind, t.BigBlind),
		Deadline: ctx.height + t.ActionTimeout,
	}
	t.Hand = h
	t.syncStacks()
}

func (t *Table) syncStacks() {
	for j, p := range t.Hand.Players {
		t.Seats[p.Seat].Stack = t.Hand.Bet.Players[j].Stack
	}
}

// handFor validates the table, hand number and caller, and returns the hand
// and the caller's hand index.
func handFor(cur realm, tableID, handNo uint64) (*Table, *Hand, int) {
	t := getTable(tableID)
	h := t.Hand
	if h == nil || h.No != handNo || handNo != t.HandNo {
		panic("stale or unknown hand number")
	}
	if h.Phase == phDone {
		panic("hand is over")
	}
	seat := t.authSeat(cur.Previous().Address())
	j := h.playerIndex(seat)
	if j < 0 {
		panic("caller is not in this hand")
	}
	return t, h, j
}

// SubmitShuffle records the caller's commitment and shuffled deck.
func SubmitShuffle(cur realm, tableID, handNo uint64, commitHex, deckB64 string) {
	assertNoSend(cur)
	ctx := newCtx(cur)
	t, h, j := handFor(cur, tableID, handNo)
	if h.Phase != phShuffle {
		panic("not in shuffle phase")
	}
	if j != h.turnIndex() {
		panic("not this player's turn to shuffle")
	}
	if _, err := cards.DecodeHex(commitHex, 32); err != nil {
		panic("commit: " + err.Error())
	}
	t.acceptDeck(h, deckB64)
	h.Players[j].Commit = commitHex
	h.Deadline = ctx.height + t.ActionTimeout
	if len(h.Roots) == h.n() {
		h.Phase = phRekey
	}
}

// SubmitRekey records the caller's re-keyed deck.
func SubmitRekey(cur realm, tableID, handNo uint64, deckB64 string) {
	assertNoSend(cur)
	ctx := newCtx(cur)
	t, h, j := handFor(cur, tableID, handNo)
	if h.Phase != phRekey {
		panic("not in rekey phase")
	}
	if j != h.turnIndex() {
		panic("not this player's turn to rekey")
	}
	t.acceptDeck(h, deckB64)
	h.Deadline = ctx.height + t.ActionTimeout
	if len(h.Roots) == 2*h.n() {
		h.startDeal(ctx, t, phDealHole)
	}
}

func (t *Table) acceptDeck(h *Hand, deckB64 string) {
	deck, root, err := cards.ParseDeck(deckB64)
	if err != nil {
		panic("deck: " + err.Error())
	}
	h.Roots = append(h.Roots, cards.EncodeHex(root))
	t.Deck = string(deck)
	t.DeckHand = h.No
}

func (h *Hand) startDeal(ctx *txCtx, t *Table, phase int) {
	h.Phase = phase
	var owing [maxSeats]bool
	h.Owing = owing[:h.n():h.n()]
	for j := range h.Owing {
		h.Owing[j] = true
	}
	h.Deadline = ctx.height + t.ActionTimeout
}

// ShareKeys publishes the caller's card keys for the current deal step.
func ShareKeys(cur realm, tableID, handNo uint64, keysHex string) {
	assertNoSend(cur)
	ctx := newCtx(cur)
	t, h, j := handFor(cur, tableID, handNo)
	if !isDealPhase(h.Phase) {
		panic("not in a deal phase")
	}
	if !h.Owing[j] {
		panic("keys already shared")
	}
	pos := h.owedPositions(j)
	if len(keysHex) != 64*len(pos) {
		panic("expected " + strconv.Itoa(len(pos)) + " keys")
	}
	if _, err := cards.DecodeHex(keysHex, 32*len(pos)); err != nil {
		panic("keys: " + err.Error())
	}
	p := h.Players[j]
	for k, i := range pos {
		p.Keys[i] = keysHex[64*k : 64*(k+1)]
	}
	h.Owing[j] = false
	for _, o := range h.Owing {
		if o {
			return
		}
	}
	h.Owing = nil
	switch h.Phase {
	case phDealHole:
		h.Phase = phPreflop
	case phDealFlop:
		h.Bet.NextStreet()
		h.Phase = phFlop
	case phDealTurn:
		h.Bet.NextStreet()
		h.Phase = phTurn
	case phDealRiver:
		h.Bet.NextStreet()
		h.Phase = phRiver
	}
	h.Deadline = ctx.height + t.ActionTimeout
	t.afterBetting(ctx)
}

// Act applies a betting action by the player to act.
func Act(cur realm, tableID, handNo uint64, action string, amount int64) {
	assertNoSend(cur)
	ctx := newCtx(cur)
	t, h, j := handFor(cur, tableID, handNo)
	if !isBettingPhase(h.Phase) {
		panic("not in a betting phase")
	}
	t.applyAction(ctx, j, action, amount)
}

func (t *Table) applyAction(ctx *txCtx, j int, action string, amount int64) {
	h := t.Hand
	if err := h.Bet.Act(j, action, amount); err != nil {
		panic(err.Error())
	}
	t.syncStacks()
	h.Deadline = ctx.height + t.ActionTimeout
	t.afterBetting(ctx)
}

// afterBetting moves on once the street needs no more action.
func (t *Table) afterBetting(ctx *txCtx) {
	h := t.Hand
	if !isBettingPhase(h.Phase) || !h.Bet.StreetComplete() {
		return
	}
	if h.Bet.Closed() || h.Phase == phRiver {
		h.Phase = phReveal
		h.Deadline = ctx.height + t.ActionTimeout
		return
	}
	switch h.Phase {
	case phPreflop:
		h.startDeal(ctx, t, phDealFlop)
	case phFlop:
		h.startDeal(ctx, t, phDealTurn)
	case phTurn:
		h.startDeal(ctx, t, phDealRiver)
	}
}

// RevealSeed opens the caller's seed; published card keys are checked at once.
func RevealSeed(cur realm, tableID, handNo uint64, seedHex string) {
	assertNoSend(cur)
	ctx := newCtx(cur)
	t, h, j := handFor(cur, tableID, handNo)
	if h.Phase != phReveal {
		panic("not in reveal phase")
	}
	p := h.Players[j]
	if p.Revealed {
		panic("seed already revealed")
	}
	seed, err := cards.DecodeHex(seedHex, 32)
	if err != nil {
		panic("seed: " + err.Error())
	}
	if cards.EncodeHex(cards.Commit(seed)) != p.Commit {
		panic("seed does not match commitment")
	}
	p.Seed = seedHex
	p.Revealed = true
	for pos, key := range p.Keys {
		if cards.EncodeHex(cards.CardKey(seed, pos)) != key {
			t.abort(ctx, []int{j}, true)
			return
		}
	}
	for _, q := range h.Players {
		if !q.Revealed {
			return
		}
	}
	t.showdown(ctx)
}

func seedBytes(p *HandPlayer) []byte {
	b, err := cards.DecodeHex(p.Seed, 32)
	if err != nil {
		panic("seed missing")
	}
	return b
}

// showdown derives all cards from the seeds and computes the payouts.
func (t *Table) showdown(ctx *txCtx) {
	h := t.Hand
	n := h.n()
	perms := make([][]int, n)
	for j, p := range h.Players {
		perms[j] = cards.Permutation(seedBytes(p))
	}
	h.Cards = cards.OfficialCards(perms)
	board := h.Cards[2*n : 2*n+5]
	var contribBuf [maxSeats]int64
	var foldedBuf [maxSeats]bool
	var scoreBuf [maxSeats]int
	contrib, folded, scores := contribBuf[:n:n], foldedBuf[:n:n], scoreBuf[:n:n]
	for j, bp := range h.Bet.Players {
		contrib[j] = bp.Contributed
		folded[j] = bp.Folded
		if !bp.Folded {
			seven := []int{h.Cards[2*j], h.Cards[2*j+1]}
			seven = append(seven, board...)
			scores[j] = holdem.Evaluate(seven)
		} else {
			scores[j] = -1
		}
	}
	pots := holdem.BuildPots(contrib, folded)
	won := holdem.Distribute(pots, scores, holdem.OddChipOrder(n))
	h.Result = &Result{Credits: won, Scores: scores}
	if !challengesEnabled {
		t.finalize(ctx)
		return
	}
	h.Phase = phChallenge
	h.Deadline = ctx.height + t.ChallengeWindow
}

// finalize pays the recorded result and ends the hand.
func (t *Table) finalize(ctx *txCtx) {
	h := t.Hand
	for j, p := range h.Players {
		t.Seats[p.Seat].Stack += h.Result.Credits[j]
	}
	h.Settled = true
	h.Phase = phDone
	t.cleanupSeats(ctx)
}

// cleanupSeats pays out and frees seats marked leaving.
func (t *Table) cleanupSeats(ctx *txCtx) {
	for i, s := range t.Seats {
		if s != nil && s.Leaving {
			t.removeSeat(ctx, i)
		}
	}
}

// abort ends the hand without a showdown: all contributions are refunded and
// each penalized player's whole stack is split equally among the other hand
// players (remainder to the lowest hand index), then the penalized players
// are removed from the table.
func (t *Table) abort(ctx *txCtx, penalized []int, convicted bool) {
	h := t.Hand
	n := h.n()
	var creditBuf [maxSeats]int64
	credits := creditBuf[:n:n]
	if !h.Settled {
		for j, p := range h.Players {
			c := h.Bet.Players[j].Contributed
			t.Seats[p.Seat].Stack += c
			credits[j] = c
		}
	}
	var penBuf [maxSeats]bool
	isPen := penBuf[:n:n]
	for _, j := range penalized {
		isPen[j] = true
	}
	recipients := []int{}
	for j := 0; j < n; j++ {
		if !isPen[j] {
			recipients = append(recipients, j)
		}
	}
	if len(recipients) > 0 {
		for _, j := range penalized {
			s := t.Seats[h.Players[j].Seat]
			amount := s.Stack
			s.Stack = 0
			credits[j] = 0
			share := amount / int64(len(recipients))
			rem := amount - share*int64(len(recipients))
			for k, r := range recipients {
				add := share
				if k == 0 {
					add += rem
				}
				t.Seats[h.Players[r].Seat].Stack += add
				credits[r] += add
			}
		}
	}
	res := &Result{Aborted: true, Credits: credits}
	if h.Result != nil {
		res.Challenges = h.Result.Challenges
	}
	if convicted {
		res.Convicted = penalized
	} else {
		res.Stallers = penalized
	}
	h.Result = res
	h.Settled = true
	h.Phase = phDone
	for _, j := range penalized {
		t.removeSeat(ctx, h.Players[j].Seat)
	}
	t.cleanupSeats(ctx)
}

// Accept agrees with the result; when all hand players accept, the hand is
// finalized without waiting for the window.
func Accept(cur realm, tableID, handNo uint64) {
	assertNoSend(cur)
	ctx := newCtx(cur)
	t, h, j := handFor(cur, tableID, handNo)
	if h.Phase != phChallenge {
		panic("not in challenge window")
	}
	h.Players[j].Accepted = true
	for _, p := range h.Players {
		if !p.Accepted {
			return
		}
	}
	t.finalize(ctx)
}

// Finalize settles the hand once the challenge window has passed.
func Finalize(cur realm, tableID uint64) {
	assertNoSend(cur)
	ctx := newCtx(cur)
	t := getTable(tableID)
	h := t.Hand
	if h == nil || h.Phase != phChallenge {
		panic("no hand in challenge window")
	}
	if ctx.height <= h.Deadline {
		panic("challenge window still open")
	}
	t.finalize(ctx)
}

// Timeout applies the stall rules once the current deadline has passed.
func Timeout(cur realm, tableID uint64) {
	assertNoSend(cur)
	ctx := newCtx(cur)
	t := getTable(tableID)
	h := t.Hand
	if h == nil || h.Phase == phDone {
		panic("no hand in progress")
	}
	if ctx.height <= h.Deadline {
		panic("deadline not reached")
	}
	switch {
	case isBettingPhase(h.Phase):
		j := h.Bet.Turn
		if h.Bet.CanCheck(j) {
			t.applyAction(ctx, j, "check", 0)
		} else {
			t.applyAction(ctx, j, "fold", 0)
		}
	case h.Phase == phShuffle || h.Phase == phRekey:
		t.abort(ctx, []int{h.turnIndex()}, false)
	case isDealPhase(h.Phase):
		stallers := []int{}
		for j, o := range h.Owing {
			if o {
				stallers = append(stallers, j)
			}
		}
		t.abort(ctx, stallers, false)
	case h.Phase == phReveal:
		stallers := []int{}
		for j, p := range h.Players {
			if !p.Revealed {
				stallers = append(stallers, j)
			}
		}
		t.abort(ctx, stallers, false)
	case h.Phase == phChallenge:
		t.finalize(ctx)
	}
}
