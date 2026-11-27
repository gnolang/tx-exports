package arena

import (
	"chain"
	"chain/runtime"
	"strconv"
	"strings"

	"gno.land/p/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/bot"
	"gno.land/p/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/game"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
)

const (
	// MoveTimeout is how many blocks a bot has to make its move in step mode
	// before anyone can claim a forfeit.
	MoveTimeout = 100
	// RatedCooldown is how many blocks must pass between two rated matches of
	// the same pair of bots. Rematches in between are friendlies, so nobody
	// can pump a rating by replaying the same opponent.
	RatedCooldown = 1000
)

// Status of a match.
type Status int

const (
	Pending  Status = iota // challenged, not played yet
	Stepping               // being played one move per transaction
	Finished
)

func (s Status) String() string {
	switch s {
	case Pending:
		return "pending"
	case Stepping:
		return "step mode"
	}
	return "finished"
}

// Match is one game between two bots. Side 0 is A, side 1 is B.
type Match struct {
	ID         int
	BotA, BotB string
	Status     Status
	Game       game.Game
	Challenger address
	Created    int64
	Rated      bool // decided when the match is created, see RatedCooldown
	Season     int  // season the match was created in
	Tournament int  // tournament id, 0 for a normal challenge

	// step mode
	Waiting  int        // side whose move is due
	Held     bot.Action // side 0's move for the current turn, once made
	Deadline int64      // block height by which Waiting must move

	// result
	Winner  int    // 0, 1, or -1 for a draw
	Forfeit bool   // the loser forfeited
	Reason  string // why, for forfeits
	Delta   int    // rating change for A (B gets the opposite)
	Settled int64  // block height
}

var (
	matches   = avl.NewTree() // padded bucket number -> encoded matches (see codec.gno)
	lastID    = 0
)

// claimRatedSlot reports whether a new match between a and b is rated, and
// if so starts the pair's cooldown. The cooldown is kept on the bot whose
// name sorts first, as a short "opponent@block," list that drops expired
// entries, so it costs a few bytes instead of a tree node per pair.
func claimRatedSlot(a, b string) bool {
	if b < a {
		a, b = b, a
	}
	keeper := mustBot(a)
	now := height()
	var kept []string
	rated := true
	for _, e := range strings.Split(keeper.recentRated, ",") {
		at := strings.LastIndex(e, "@")
		if at < 0 {
			continue
		}
		h, err := strconv.ParseInt(e[at+1:], 10, 64)
		if err != nil || now-h >= RatedCooldown {
			continue // expired
		}
		if e[:at] == b {
			rated = false
		}
		kept = append(kept, e)
	}
	if rated {
		kept = append(kept, b+"@"+strconv.FormatInt(now, 10))
	}
	keeper.recentRated = strings.Join(kept, ",")
	return rated
}

// Bot returns the name of the bot playing side.
func (m *Match) Bot(side int) string {
	if side == 0 {
		return m.BotA
	}
	return m.BotB
}

func key(id int) string {
	s := strconv.Itoa(id)
	for len(s) < 10 {
		s = "0" + s
	}
	return s
}

func height() int64 { return runtime.ChainHeight() }

func emit(typ string, attrs ...string) { chain.Emit(typ, attrs...) }

func mustMatch(id int) *Match {
	r, ok := record(id)
	if !ok {
		panic("unknown match: " + strconv.Itoa(id))
	}
	return decode(id, r)
}

// seedFor gives every match its own board. The pair is mixed in so two
// matches created back to back between different bots differ too.
func seedFor(id int, a, b string) int {
	h := uint32(2166136261)
	for _, s := range []string{a, "|", b} {
		for i := 0; i < len(s); i++ {
			h = (h ^ uint32(s[i])) * 16777619
		}
	}
	return int((h + uint32(id)*7919) % 1000003)
}

// Challenge records a new match between two registered bots and returns its
// id. It runs no bot code, so it always succeeds; play it with Play or, if
// that fails, with step mode.
func Challenge(cur realm, a, b string) int {
	m := newMatch(cur, a, b)
	m.save()
	return m.ID
}

func newMatch(cur realm, a, b string) *Match {
	if a == b {
		panic("a bot can't fight itself")
	}
	for _, name := range []string{a, b} {
		if mustBot(name).Retired {
			panic(name + " is retired")
		}
	}
	rollSeason()
	lastID++
	m := &Match{
		ID:         lastID,
		BotA:       a,
		BotB:       b,
		Status:     Pending,
		Game:       *game.New(seedFor(lastID, a, b)),
		Challenger: cur.Previous().Address(),
		Created:    height(),
		Rated:      claimRatedSlot(a, b),
		Season:     season,
		Winner:     -1,
	}
	emit("MatchCreated", "id", strconv.Itoa(m.ID), "a", a, "b", b)
	return m
}

// Play runs the rest of a match in this transaction. If a bot written in
// realm code crashes or runs out of gas, the whole transaction fails and the
// match stays as it was: switch it to step mode with StartStepMode.
func Play(cur realm, id int) string {
	m := mustMatch(id)
	if m.Status == Finished {
		panic("match already finished")
	}
	m.play()
	m.save()
	return m.Summary()
}

// Fight challenges and plays in one transaction, saving the match once. If
// it fails, nothing is recorded: use Challenge, then Play or step mode.
func Fight(cur realm, a, b string) string {
	m := newMatch(cur, a, b)
	m.play()
	m.save()
	return m.Summary()
}

// play runs the match to the end in memory.
func (m *Match) play() {
	players := [2]*Bot{mustBot(m.BotA), mustBot(m.BotB)}
	for !m.Game.Over() {
		var acts [2]bot.Action
		for side := 0; side < 2; side++ {
			if m.Status == Stepping && side == 0 && m.Waiting == 1 {
				acts[0] = m.Held // already made in step mode
				continue
			}
			a, crashed := players[side].ask(m.view(side))
			if crashed {
				m.forfeit(side, "crashed on turn "+strconv.Itoa(m.Game.Turn+1))
				return
			}
			acts[side] = a
		}
		m.Game.Step(acts[0], acts[1])
		m.Waiting = 0
	}
	m.finish()
}

// StartStepMode switches a pending match to one move per transaction.
// Anyone may call it.
func StartStepMode(cur realm, id int) {
	m := mustMatch(id)
	if m.Status != Pending {
		panic("only a pending match can switch to step mode")
	}
	defer m.save()
	m.Status = Stepping
	m.Waiting = 0
	m.Deadline = height() + MoveTimeout
	emit("StepModeStarted", "id", strconv.Itoa(id))
}

// SubmitMove asks the bot whose turn it is for its move and records it. The
// move comes from the bot's own code, so nobody can submit a fake one.
// Anyone may call it.
func SubmitMove(cur realm, id int) string {
	m := mustMatch(id)
	if m.Status != Stepping {
		panic("match is not in step mode")
	}
	defer m.save()
	side := m.Waiting
	a, crashed := mustBot(m.Bot(side)).ask(m.view(side))
	if crashed {
		m.forfeit(side, "crashed on turn "+strconv.Itoa(m.Game.Turn+1))
		return m.Summary()
	}
	if side == 0 {
		m.Held = a
		m.Waiting = 1
	} else {
		m.Game.Step(m.Held, a)
		m.Waiting = 0
	}
	m.Deadline = height() + MoveTimeout
	if m.Game.Over() {
		m.finish()
	}
	return m.Summary()
}

// ClaimForfeit ends a step-mode match whose waiting bot missed its deadline.
// Anyone may call it.
func ClaimForfeit(cur realm, id int) string {
	m := mustMatch(id)
	if m.Status != Stepping {
		panic("match is not in step mode")
	}
	if height() <= m.Deadline {
		panic(ufmt.Sprintf("%s still has until block %d to move", m.Bot(m.Waiting), m.Deadline))
	}
	defer m.save()
	m.forfeit(m.Waiting, "missed its move deadline on turn "+strconv.Itoa(m.Game.Turn+1))
	return m.Summary()
}

// view is what side's bot sees this turn.
func (m *Match) view(side int) bot.State {
	s := m.Game.View(m.ID, side)
	s.EnemyBot = m.Bot(1 - side)
	return s
}

func (m *Match) finish() {
	m.Winner = m.Game.Winner()
	m.settle()
}

func (m *Match) forfeit(loser int, reason string) {
	m.Winner = 1 - loser
	m.Forfeit = true
	m.Reason = m.Bot(loser) + " " + reason
	m.settle()
}

func (m *Match) settle() {
	rollSeason()
	m.Status = Finished
	m.Settled = height()
	a, b := mustBot(m.BotA), mustBot(m.BotB)
	if m.Rated {
		m.Delta = rate(a, b, m.Winner)
	}
	switch m.Winner {
	case 0:
		a.Wins++
		a.SeasonWins++
		b.Losses++
		b.SeasonLosses++
		if m.Forfeit {
			b.Forfeits++
		}
	case 1:
		b.Wins++
		b.SeasonWins++
		a.Losses++
		a.SeasonLosses++
		if m.Forfeit {
			a.Forfeits++
		}
	default:
		a.Draws++
		a.SeasonDraws++
		b.Draws++
		b.SeasonDraws++
	}
	winner := "draw"
	if m.Winner >= 0 {
		winner = m.Bot(m.Winner)
	}
	emit("MatchFinished", "id", strconv.Itoa(m.ID), "winner", winner,
		"gold", ufmt.Sprintf("%d-%d", m.Game.GoldA, m.Game.GoldB))
}

// Summary is a one-line description of the match.
func (m *Match) Summary() string {
	g := &m.Game
	score := ufmt.Sprintf("%s %d - %d %s", m.Bot(0), g.GoldA, g.GoldB, m.Bot(1))
	switch {
	case m.Status != Finished:
		return ufmt.Sprintf("#%d %s (%s, turn %d of %d)", m.ID, score, m.Status.String(), g.Turn, bot.Turns)
	case m.Forfeit:
		return ufmt.Sprintf("#%d %s wins by forfeit: %s%s", m.ID, m.Bot(m.Winner), m.Reason, m.friendlyNote())
	case m.Winner < 0:
		return ufmt.Sprintf("#%d %s, draw%s", m.ID, score, m.friendlyNote())
	}
	return ufmt.Sprintf("#%d %s, %s wins%s", m.ID, score, m.Bot(m.Winner), m.friendlyNote())
}

func (m *Match) friendlyNote() string {
	if m.Rated {
		return ""
	}
	return " (friendly)"
}

// MatchSummary returns the summary of a match, for other realms and tools.
func MatchSummary(id int) string { return mustMatch(id).Summary() }

// MatchCount is the number of matches ever created.
func MatchCount() int { return lastID }
