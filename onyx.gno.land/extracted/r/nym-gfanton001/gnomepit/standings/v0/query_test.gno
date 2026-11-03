package standings

import (
	"strconv"
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
	"gno.land/p/nt/urequire/v0"
	"gno.land/r/sys/users"
)

// giveName registers name for a in r/sys/users, as the users realm's genesis controller
// does; the registry outlives reset, so a name given once stays.
func giveName(cur realm, a address, name string) {
	if !users.ResolveAddress(a).IsDeleted() {
		return
	}
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/sys/users/init"))
	if err := users.RegisterUser(cross(cur), name, a); err != nil {
		panic(err.Error())
	}
}

func ranks(list []Standing) string {
	out := ""
	for _, s := range list {
		out += strconv.Itoa(s.Rank) + " "
	}
	return out
}

func TestStandingOfUnrated(t *testing.T) {
	reset()
	s := StandingOf(carol)
	uassert.Equal(t, 0, s.Rank)
	uassert.Equal(t, carol.String(), s.Player)
	uassert.Equal(t, "", s.Name)
	uassert.Equal(t, "", s.MainClan)
	uassert.Equal(t, 1000, s.Rating)
	uassert.Equal(t, 0, s.Wins+s.Losses+s.Draws)
}

func TestStandingOfNamed(cur realm, t *testing.T) {
	reset()
	giveName(cur, alice, "alice")
	testing.SetRealm(testing.NewCodeRealm(arenaV0))
	Record(cross(cur), alice, bob, "Pickers", "Ironhide", "a")
	s := StandingOf(alice)
	uassert.Equal(t, "alice", s.Name)
	uassert.Equal(t, 1, s.Rank)
	uassert.Equal(t, "Pickers", s.MainClan)
	uassert.Equal(t, 1016, s.Rating)
	uassert.Equal(t, 1, s.Wins)
	uassert.Equal(t, "", StandingOf(bob).Name, "an address without a name has none")
	uassert.Equal(t, 2, StandingOf(bob).Rank)
}

func TestLeaderboardSharedRankAcrossPages(t *testing.T) {
	reset()
	seed(alice, 1016)
	seed(bob, 1016)
	seed(carol, 1016)
	seed(dave, 952)
	uassert.Equal(t, "1 1 ", ranks(Leaderboard(0, 2)))
	uassert.Equal(t, "1 4 ", ranks(Leaderboard(2, 2)), "a page that opens inside a tie keeps its shared rank")
	uassert.Equal(t, "1 1 1 4 ", ranks(Leaderboard(0, 50)))
}

func TestLeaderboardLimits(t *testing.T) {
	reset()
	uassert.PanicsWithMessage(t, nil, "limit must be 1 to 50", func() { Leaderboard(0, 0) })
	uassert.PanicsWithMessage(t, nil, "limit must be 1 to 50", func() { Leaderboard(0, 51) })
	uassert.PanicsWithMessage(t, nil, "offset must not be negative", func() { Leaderboard(-1, 10) })
	list := Leaderboard(0, 50)
	uassert.True(t, list != nil)
	uassert.Equal(t, 0, len(list))
}

func TestLeaderboardFiftyNamed(cur realm, t *testing.T) {
	reset()
	for i := 0; i < 50; i++ {
		a := testutils.TestAddress("player" + strconv.Itoa(i))
		giveName(cur, a, "player"+strconv.Itoa(i))
		seed(a, 1000+i)
	}
	list := Leaderboard(0, 50)
	urequire.Equal(t, 50, len(list))
	for i, s := range list {
		uassert.Equal(t, 1049-i, s.Rating)
		uassert.Equal(t, i+1, s.Rank)
		uassert.Equal(t, "player"+strconv.Itoa(49-i), s.Name)
	}
}

func TestRatedPlayers(cur realm, t *testing.T) {
	reset()
	uassert.Equal(t, 0, RatedPlayers())
	testing.SetRealm(testing.NewCodeRealm(arenaV0))
	Record(cross(cur), alice, bob, "Pickers", "Ironhide", "a")
	uassert.Equal(t, 2, RatedPlayers())
}

func TestClanStandings(cur realm, t *testing.T) {
	reset()
	list := ClanStandings()
	uassert.True(t, list != nil)
	uassert.Equal(t, 0, len(list))

	testing.SetRealm(testing.NewCodeRealm(arenaV0))
	Record(cross(cur), alice, bob, "Pickers", "Ironhide", "a")
	Record(cross(cur), carol, dave, "Delvers", "Delvers", "a")
	list = ClanStandings()
	urequire.Equal(t, 2, len(list), "a clan with only mirror matches is not listed")
	uassert.Equal(t, "Pickers", list[0].Clan)
	uassert.Equal(t, 1, list[0].Rank)
	uassert.Equal(t, 1008, list[0].Rating)
	uassert.Equal(t, 1, list[0].Wins)
	uassert.Equal(t, "Ironhide", list[1].Clan)
	uassert.Equal(t, 2, list[1].Rank)
	uassert.Equal(t, 992, list[1].Rating)
	uassert.Equal(t, 1, list[1].Losses)
}

func TestResultsPageAcrossChunks(cur realm, t *testing.T) {
	reset()
	testing.SetRealm(testing.NewCodeRealm(arenaV0))
	for i := 0; i < 65; i++ {
		Record(cross(cur), alice, bob, "Pickers", "Ironhide", "a")
	}
	page := Results(62, 5)
	urequire.Equal(t, 3, len(page))
	for i, r := range page {
		uassert.Equal(t, 63+i, r.Seq)
	}
	uassert.Equal(t, 65, ResultCount())
}

func TestLeaderboardAndStandingOfAgree(cur realm, t *testing.T) {
	reset()
	testing.SetRealm(testing.NewCodeRealm(arenaV0))
	Record(cross(cur), alice, bob, "Pickers", "Ironhide", "a")
	Record(cross(cur), carol, dave, "Delvers", "Pickers", "draw")
	Record(cross(cur), carol, alice, "Delvers", "Pickers", "a")
	Record(cross(cur), dave, bob, "Ironhide", "Ironhide", "b")
	Record(cross(cur), bob, carol, "Ironhide", "Delvers", "a")
	erin, frank, gina := testutils.TestAddress("erin"), testutils.TestAddress("frank"), testutils.TestAddress("gina")
	Record(cross(cur), erin, alice, "Pickers", "Pickers", "a")
	Record(cross(cur), frank, gina, "Delvers", "Ironhide", "draw")

	board := Leaderboard(0, 50)
	urequire.Equal(t, 7, len(board))
	for _, s := range board {
		uassert.Equal(t, s.Rank, StandingOf(address(s.Player)).Rank, s.Player)
	}
	for off := 0; off < len(board); off += 2 {
		for i, s := range Leaderboard(off, 2) {
			uassert.Equal(t, board[off+i].Rank, s.Rank, "the page at offset "+strconv.Itoa(off))
		}
	}
	tied := StandingOf(frank).Rank
	uassert.True(t, tied > 1, "frank and gina tie below first place")
	uassert.Equal(t, tied, StandingOf(gina).Rank)
}

func TestResultsPage(cur realm, t *testing.T) {
	reset()
	testing.SetRealm(testing.NewCodeRealm(arenaV0))
	Record(cross(cur), alice, bob, "Pickers", "Ironhide", "a")
	Record(cross(cur), bob, carol, "Ironhide", "Delvers", "b")
	Record(cross(cur), carol, alice, "Delvers", "Pickers", "draw")

	uassert.Equal(t, 3, ResultCount())
	page := Results(1, 2)
	urequire.Equal(t, 2, len(page))
	uassert.Equal(t, 2, page[0].Seq)
	uassert.Equal(t, arenaV0, page[0].Writer)
	uassert.Equal(t, bob.String(), page[0].Challenger)
	uassert.Equal(t, carol.String(), page[0].Acceptor)
	uassert.Equal(t, "Ironhide", page[0].ChallengerClan)
	uassert.Equal(t, "Delvers", page[0].AcceptorClan)
	uassert.Equal(t, "b", page[0].Result)
	uassert.Equal(t, 3, page[1].Seq)
	uassert.Equal(t, "draw", page[1].Result)
	uassert.Equal(t, "Pickers", page[1].AcceptorClan)
	uassert.Equal(t, 0, len(Results(3, 10)), "a page past the log is empty")
	uassert.PanicsWithMessage(t, nil, "limit must be 1 to 50", func() { Results(0, 51) })
	uassert.PanicsWithMessage(t, nil, "offset must not be negative", func() { Results(-1, 10) })
}
