package standings

import (
	"gno.land/p/nt/avl/v0"
	"gno.land/r/sys/users"
)

const maxPage = 50

// Standing is one player's place on the ladder. Rank is 1 for the highest rating and
// equal ratings share it; Rank is 0 and Rating 1000 for a player with no rated match.
// Name is the player's gno.land name, "" without one. MainClan is "" until their
// first rated match with a counted clan.
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

// Result is one logged result. Seq is its place in the log, 1 first; Writer is the path
// of the realm that reported it. Result is "a" when the challenger won, "b" when the
// acceptor did, and "draw"; Time is the block's Unix seconds.
type Result struct {
	Seq                          int
	Writer                       string
	Challenger, Acceptor         string
	ChallengerClan, AcceptorClan string
	Result                       string
	Time                         int64
}

// Leaderboard lists rated players, highest rating first: limit of them after skipping offset.
func Leaderboard(offset, limit int) []Standing {
	checkPage(offset, limit)
	list := []Standing{}
	ladder.TraverseByOffset(offset, limit, true, true, func(n *avl.Node) bool {
		s := standingOf(address(n.Key()[2:]))
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
	s := standingOf(player)
	if s.Wins+s.Losses+s.Draws > 0 {
		s.Rank = rankOf(s.Rating)
	}
	return s
}

// RatedPlayers counts the players on the ladder.
func RatedPlayers() int {
	return ladder.Size()
}

// ClanStandings lists every clan with a rated cross-clan match, highest rating first;
// equal ratings keep first-seen order and share a rank. Clans with no such match are left
// out: they stand at 1000 and 0-0-0.
func ClanStandings() []ClanStanding {
	list := []ClanStanding{}
	for _, c := range clans {
		if c.wins+c.losses+c.draws == 0 {
			continue
		}
		list = append(list, ClanStanding{Clan: c.name, Rating: c.rating, Wins: c.wins, Losses: c.losses, Draws: c.draws})
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

// Results lists logged results, oldest first: limit of them after skipping offset.
func Results(offset, limit int) []Result {
	checkPage(offset, limit)
	list := []Result{}
	n := resultCount()
	if offset >= n {
		return list
	}
	end := offset + limit
	if end > n {
		end = n
	}
	for seq := offset + 1; seq <= end; seq++ {
		e := resultAt(seq)
		list = append(list, Result{
			Seq:            seq,
			Writer:         writerPaths[e.writer-1],
			Challenger:     e.challenger.String(),
			Acceptor:       e.acceptor.String(),
			ChallengerClan: clanName(e.clans[0]),
			AcceptorClan:   clanName(e.clans[1]),
			Result:         resultName(e.result),
			Time:           e.time,
		})
	}
	return list
}

// ResultCount counts the logged results.
func ResultCount() int {
	return resultCount()
}

// standingOf is player's standing without its rank.
func standingOf(player address) Standing {
	s := Standing{Player: player.String(), Name: nameOf(player), Rating: startRating}
	st := loadStanding(player)
	if st == nil {
		return s
	}
	s.MainClan = clanName(st.mainClan())
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

// clanName is the name of clan number n, "" for 0, no clan.
func clanName(n int) string {
	if n == 0 {
		return ""
	}
	return clans[n-1].name
}

func resultName(b byte) string {
	if b == 'd' {
		return "draw"
	}
	return string(b)
}

func checkPage(offset, limit int) {
	if offset < 0 {
		panic("offset must not be negative")
	}
	if limit < 1 || limit > maxPage {
		panic("limit must be 1 to 50")
	}
}
