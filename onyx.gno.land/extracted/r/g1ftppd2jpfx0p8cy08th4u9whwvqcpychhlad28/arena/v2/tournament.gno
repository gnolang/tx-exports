package arena

import (
	"strconv"
	"strings"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
)

// Tournaments. Anyone can open a round-robin tournament; bot owners enter
// their bots; the creator starts it. Matches are then created one at a time
// and are ordinary matches, so a bot that crashes in a tournament game is
// handled exactly like anywhere else: step mode, then a forfeit. A
// tournament can therefore never get stuck on a broken bot.
//
// Scoring: 3 points for a win, 1 for a draw. Ties are broken by gold
// difference, then gold scored, then name.

const (
	minEntrants = 2
	maxEntrants = 8
)

// TournamentStatus of a tournament.
type TournamentStatus int

const (
	Open TournamentStatus = iota
	Running
	Done
)

func (s TournamentStatus) String() string {
	switch s {
	case Open:
		return "open for entries"
	case Running:
		return "running"
	}
	return "finished"
}

// Tournament is a round-robin between up to maxEntrants bots.
type Tournament struct {
	ID       int
	Name     string
	Creator  address
	Created  int64
	Capacity int
	Status   TournamentStatus
	Entrants []string
	Pairs    []string // "a|b", in play order, fixed at start
	MatchIDs []int    // match id for each pair once created
	Winner   string
}

var (
	tournaments = avl.NewTree() // padded id -> *Tournament
	lastTID     = 0
)

func mustTournament(id int) *Tournament {
	v := tournaments.Get(key(id))
	if v == nil {
		panic("unknown tournament: " + strconv.Itoa(id))
	}
	return v.(*Tournament)
}

// CreateTournament opens a round-robin for up to capacity bots (2 to 8).
func CreateTournament(cur realm, name string, capacity int) int {
	name = cleanText(name)
	if len(name) < 3 || len(name) > 48 {
		panic("tournament names must be 3 to 48 characters")
	}
	if capacity < minEntrants || capacity > maxEntrants {
		panic(ufmt.Sprintf("capacity must be %d to %d", minEntrants, maxEntrants))
	}
	lastTID++
	t := &Tournament{
		ID: lastTID, Name: name, Creator: cur.Previous().Address(),
		Created: height(), Capacity: capacity, Status: Open,
	}
	tournaments.Set(key(t.ID), t)
	emit("TournamentCreated", "id", strconv.Itoa(t.ID), "name", name)
	return t.ID
}

// JoinTournament enters a bot you own into an open tournament.
func JoinTournament(cur realm, id int, botName string) {
	t := mustTournament(id)
	b := mustOwn(cur, botName)
	if t.Status != Open {
		panic("tournament is not open for entries")
	}
	if b.Retired {
		panic(botName + " is retired")
	}
	if len(t.Entrants) >= t.Capacity {
		panic("tournament is full")
	}
	for _, e := range t.Entrants {
		if e == botName {
			panic(botName + " is already entered")
		}
	}
	t.Entrants = append(t.Entrants, botName)
	emit("TournamentJoined", "id", strconv.Itoa(id), "bot", botName)
}

// StartTournament closes entries and fixes the schedule. Only the creator
// can start it.
func StartTournament(cur realm, id int) {
	t := mustTournament(id)
	if cur.Previous().Address() != t.Creator {
		panic("only the creator can start this tournament")
	}
	if t.Status != Open {
		panic("tournament already started")
	}
	if len(t.Entrants) < minEntrants {
		panic("a tournament needs at least 2 bots")
	}
	t.Pairs = roundRobin(t.Entrants)
	t.MatchIDs = make([]int, len(t.Pairs))
	t.Status = Running
	emit("TournamentStarted", "id", strconv.Itoa(id), "matches", strconv.Itoa(len(t.Pairs)))
}

// roundRobin schedules every pair once, round by round (circle method), so
// no bot plays twice in a row more than it must. Sides alternate by round.
func roundRobin(entrants []string) []string {
	ps := append([]string{}, entrants...)
	if len(ps)%2 == 1 {
		ps = append(ps, "") // bye
	}
	n := len(ps)
	var out []string
	for round := 0; round < n-1; round++ {
		for i := 0; i < n/2; i++ {
			a, b := ps[i], ps[n-1-i]
			if a == "" || b == "" {
				continue
			}
			if round%2 == 1 {
				a, b = b, a
			}
			out = append(out, a+"|"+b)
		}
		// rotate everyone but the first
		last := ps[n-1]
		copy(ps[2:], ps[1:n-1])
		ps[1] = last
	}
	return out
}

// next returns the index of the first pair without a finished match, and
// whether that pair already has a match in progress.
func (t *Tournament) next() (idx int, inProgress bool) {
	for i, id := range t.MatchIDs {
		if id == 0 {
			return i, false
		}
		if mustMatch(id).Status != Finished {
			return i, true
		}
	}
	return len(t.MatchIDs), false
}

// NextTournamentMatch creates the tournament's next match and returns its
// id. Play it with Play, or step mode if a bot keeps it from finishing.
// Anyone may call it.
func NextTournamentMatch(cur realm, id int) int {
	t := mustTournament(id)
	m := t.createNext(cur)
	m.save()
	return m.ID
}

// PlayTournament creates the next match and plays it in one transaction. If
// a bot makes it fail, nothing is recorded: use NextTournamentMatch, then
// Play or step mode. Anyone may call it.
func PlayTournament(cur realm, id int) string {
	t := mustTournament(id)
	m := t.createNext(cur)
	m.play()
	m.save()
	t.checkDone()
	return m.Summary()
}

func (t *Tournament) createNext(cur realm) *Match {
	if t.Status != Running {
		panic("tournament is " + t.Status.String())
	}
	idx, inProgress := t.next()
	if inProgress {
		panic(ufmt.Sprintf("match #%d is still being played: finish it with Play or step mode", t.MatchIDs[idx]))
	}
	if idx == len(t.Pairs) {
		t.checkDone()
		panic("all tournament matches are played")
	}
	ab := strings.Split(t.Pairs[idx], "|")
	m := newMatch(cur, ab[0], ab[1])
	m.Tournament = t.ID
	t.MatchIDs[idx] = m.ID
	return m
}

// checkDone finishes the tournament once every match is settled.
func (t *Tournament) checkDone() {
	if t.Status != Running {
		return
	}
	if idx, _ := t.next(); idx < len(t.Pairs) {
		return
	}
	t.Status = Done
	if st := t.Standings(); len(st) > 0 {
		t.Winner = st[0].Bot
	}
	emit("TournamentFinished", "id", strconv.Itoa(t.ID), "winner", t.Winner)
}

// CloseTournament marks a tournament finished once all its matches are
// settled (matches finished through step mode don't do it themselves).
// Anyone may call it.
func CloseTournament(cur realm, id int) {
	t := mustTournament(id)
	t.checkDone()
	if t.Status != Done {
		panic("tournament still has matches to play")
	}
}

// Standing is one bot's line in a tournament table.
type Standing struct {
	Bot                         string
	Played, Wins, Draws, Losses int
	GoldFor, GoldAgainst        int
	Points                      int
}

// Standings returns the tournament table, best first.
func (t *Tournament) Standings() []Standing {
	rows := map[string]*Standing{}
	for _, e := range t.Entrants {
		rows[e] = &Standing{Bot: e}
	}
	for _, id := range t.MatchIDs {
		if id == 0 {
			continue
		}
		m := mustMatch(id)
		if m.Status != Finished {
			continue
		}
		for side := 0; side < 2; side++ {
			r := rows[m.Bot(side)]
			r.Played++
			r.GoldFor += m.Game.Gold(side)
			r.GoldAgainst += m.Game.Gold(1 - side)
			switch m.Winner {
			case side:
				r.Wins++
				r.Points += 3
			case -1:
				r.Draws++
				r.Points++
			default:
				r.Losses++
			}
		}
	}
	out := make([]Standing, 0, len(rows))
	for _, e := range t.Entrants {
		out = append(out, *rows[e])
	}
	for i := 1; i < len(out); i++ {
		for j := i; j > 0 && aheadOf(out[j], out[j-1]); j-- {
			out[j], out[j-1] = out[j-1], out[j]
		}
	}
	return out
}

func aheadOf(a, b Standing) bool {
	if a.Points != b.Points {
		return a.Points > b.Points
	}
	if da, db := a.GoldFor-a.GoldAgainst, b.GoldFor-b.GoldAgainst; da != db {
		return da > db
	}
	if a.GoldFor != b.GoldFor {
		return a.GoldFor > b.GoldFor
	}
	return a.Bot < b.Bot
}

// TournamentCount is the number of tournaments ever created.
func TournamentCount() int { return lastTID }

// TournamentNext returns the next pairing still to be created, if any.
func TournamentNext(id int) (a, b string, ok bool) {
	t := mustTournament(id)
	idx, inProgress := t.next()
	if t.Status != Running || inProgress || idx >= len(t.Pairs) {
		return "", "", false
	}
	ab := strings.Split(t.Pairs[idx], "|")
	return ab[0], ab[1], true
}
