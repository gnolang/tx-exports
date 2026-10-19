package arena

import (
	"encoding/base64"
	"strconv"
	"strings"
	"time"

	"gno.land/p/g1sl6fyq6mrc3wydt8xluhxx4aqsudpp9vhv6g2a/gnomepit/engine"
	"gno.land/p/nt/avl/v0"
	"gno.land/r/sys/users"
)

// MatchSummary is one match as a player's list shows it. Round is the round being
// played, or the last one resolved once the match is over. ToMove is the address that
// must move next, empty when none. Deadline is the end of the current move's 24 hours,
// or the expiry of an open challenge, in Unix seconds. Opponent is the address an open
// challenge is reserved for, "" when anyone can accept it and once accepted.
type MatchSummary struct {
	ID, Phase                    string
	Round                        int
	Challenger, Acceptor         string
	ChallengerClan, AcceptorClan string
	ToMove                       string
	Deadline                     int64
	Result, Reason               string
	Opponent                     string
}

// MatchView is everything one match screen needs. Plans holds [challenger, acceptor]
// for each resolved round, and for the round being played while the match runs, ""
// while a plan is sealed or not yet made; HP holds both sides' HP after each resolved
// round; Box is the challenger's encrypted pending plan, in base64.
type MatchView struct {
	MatchSummary
	ChallengerDeck, AcceptorDeck string
	Plans                        [][]string
	Box                          string
	HP                           [][]int
	DeadlinePassed               bool
}

// SessionLock binds the session key at address Session to the match whose id is Match.
// Expires is the session's expiry in Unix seconds, 0 for none.
type SessionLock struct {
	Session, Match string
	Expires        int64
}

// Standing is one player's place on the ladder. Rank is 1 for the highest rating and
// equal ratings share it; Rank is 0 and Rating 1000 for a player with no rated match.
// Name is the player's gno.land name, "" without one. MainClan is "" until their
// first rated match.
type Standing struct {
	Rank                   int
	Player, Name, MainClan string
	Rating                 int
	Wins, Losses, Draws    int
}

// ClanStanding is one clan's record across rated cross-clan matches.
type ClanStanding struct {
	Rank                int
	Clan                string
	Rating              int
	Wins, Losses, Draws int
}

// Leaderboard lists rated players, highest rating first: limit of them after skipping offset.
func Leaderboard(offset, limit int) []Standing {
	checkPage(offset, limit)
	rules := engine.ProofOfConcept()
	list := []Standing{}
	ladder.TraverseByOffset(offset, limit, true, true, func(n *avl.Node) bool {
		s := standingOf(rules, address(n.Key()[2:]))
		switch {
		case len(list) == 0:
			s.Rank = rankOf(s.Rating)
		case list[len(list)-1].Rating == s.Rating:
			s.Rank = list[len(list)-1].Rank
		default:
			s.Rank = offset + len(list) + 1
		}
		list = append(list, s)
		return false
	})
	return list
}

// StandingOf returns player's standing, rated or not.
func StandingOf(player address) Standing {
	s := standingOf(engine.ProofOfConcept(), player)
	if s.MainClan != "" {
		s.Rank = rankOf(s.Rating)
	}
	return s
}

// RatedPlayers counts the players on the ladder.
func RatedPlayers() int {
	return ladder.Size()
}

// ClanStandings lists every clan of the ruleset, highest rating first; equal ratings keep
// ruleset order and share a rank.
func ClanStandings() []ClanStanding {
	rules := engine.ProofOfConcept()
	list := []ClanStanding{}
	for i, c := range decodeClans(clanRecords, len(rules.Clans)) {
		list = append(list, ClanStanding{Clan: rules.Clans[i].Name, Rating: c.rating, Wins: c.wins, Losses: c.losses, Draws: c.draws})
	}
	for i := 1; i < len(list); i++ {
		for j := i; j > 0 && list[j].Rating > list[j-1].Rating; j-- {
			list[j], list[j-1] = list[j-1], list[j]
		}
	}
	for i := range list {
		if i > 0 && list[i].Rating == list[i-1].Rating {
			list[i].Rank = list[i-1].Rank
		} else {
			list[i].Rank = i + 1
		}
	}
	return list
}

// standingOf is player's standing without its rank.
func standingOf(rules *engine.Ruleset, player address) Standing {
	s := Standing{Player: player.String(), Name: nameOf(player), Rating: startRating}
	st := loadStanding(player)
	if st == nil {
		return s
	}
	s.MainClan = clanName(rules, st.mainClan())
	s.Rating, s.Wins, s.Losses, s.Draws = st.rating, st.wins, st.losses, st.draws
	return s
}

// nameOf is player's gno.land name, "" when they have none.
func nameOf(player address) string {
	u := users.ResolveAddress(player)
	if u.IsDeleted() {
		return ""
	}
	return u.Name()
}

// Locks lists player's session locks. It can include locks whose session has expired.
func Locks(player address) []SessionLock {
	list := []SessionLock{}
	for _, l := range loadPlayer(player).locks {
		list = append(list, SessionLock{Session: l.session.String(), Match: strconv.Itoa(l.id), Expires: l.expires})
	}
	return list
}

// Matches lists player's matches, newest first: limit of them after skipping offset.
func Matches(player address, offset, limit int) []MatchSummary {
	checkPage(offset, limit)
	rules := engine.ProofOfConcept()
	now := time.Now().Unix()
	list := []MatchSummary{}
	for _, id := range loadPlayer(player).newest(offset, limit) {
		m, ok := loadMatch(rules, id)
		if !ok {
			continue
		}
		list = append(list, m.summary(rules, id, now))
	}
	return list
}

// Match returns the view of match id.
func Match(id string) MatchView {
	rules := engine.ProofOfConcept()
	n, m := find(rules, id)
	return m.view(rules, n, time.Now().Unix())
}

func (m record) view(rules *engine.Ruleset, id int, now int64) MatchView {
	v := MatchView{
		MatchSummary:   m.summary(rules, id, now),
		ChallengerDeck: deckText(rules, m.decks[0]),
		AcceptorDeck:   deckText(rules, m.decks[1]),
		Plans:          [][]string{},
		Box:            base64.StdEncoding.EncodeToString([]byte(m.box)),
		HP:             [][]int{},
		DeadlinePassed: m.running() && now > m.deadline,
	}
	resolved := plansMade(m.plans[0])
	rounds := resolved
	if m.running() {
		rounds++
	}
	for r := 1; r <= rounds; r++ {
		a := planText(rules, planAt(m.plans[0], r))
		b := planText(rules, planAt(m.plans[1], r))
		v.Plans = append(v.Plans, []string{a, b})
	}
	for r := 0; r < resolved; r++ {
		v.HP = append(v.HP, []int{m.hp[r][0], m.hp[r][1]})
	}
	return v
}

func (m record) summary(rules *engine.Ruleset, id int, now int64) MatchSummary {
	resolved := plansMade(m.plans[0])
	s := MatchSummary{
		ID:             strconv.Itoa(id),
		Phase:          m.phase,
		Round:          resolved + 1,
		Challenger:     m.challenger.String(),
		Acceptor:       m.acceptor.String(),
		ChallengerClan: clanName(rules, m.clans[0]),
		AcceptorClan:   clanName(rules, m.clans[1]),
		Result:         m.result,
		Reason:         m.reason,
		Opponent:       m.opponent.String(),
	}
	switch m.phase {
	case phaseOpen:
		s.Deadline = m.deadline
		if m.expired(now) {
			s.Phase = phaseExpired
		}
	case phaseReveal:
		s.ToMove = s.Challenger
		s.Deadline = m.deadline
	case phasePlay:
		s.ToMove = s.Acceptor
		s.Deadline = m.deadline
	case phaseEnded:
		if resolved > 0 {
			s.Round = resolved
		}
	}
	return s
}

func (m record) running() bool {
	return m.phase == phaseReveal || m.phase == phasePlay
}

// deckText names the cards of deck in card id order.
func deckText(rules *engine.Ruleset, deck uint64) string {
	var names []string
	for i := range rules.Cards {
		if deck&(uint64(1)<<uint(i)) != 0 {
			names = append(names, rules.Cards[i].Name)
		}
	}
	return strings.Join(names, ",")
}

// planText names the cards of p in play order.
func planText(rules *engine.Ruleset, p engine.Plan) string {
	names := make([]string, len(p))
	for i, id := range p {
		names[i] = rules.Cards[id].Name
	}
	return strings.Join(names, ",")
}
