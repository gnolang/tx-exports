package standings

import (
	"math"
	"strconv"
	"testing"
	"time"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/uassert/v0"
	"gno.land/p/nt/urequire/v0"
)

func showStanding(s standing) string {
	out := strconv.Itoa(s.rating) + " " + strconv.Itoa(s.wins) + "-" + strconv.Itoa(s.losses) + "-" +
		strconv.Itoa(s.draws) + " last " + strconv.Itoa(s.lastClan) + " per"
	for _, n := range s.perClan {
		out += " " + strconv.Itoa(n)
	}
	return out
}

// seed gives a a standing at rating with one rated win as Pickers, clan 1, and its ladder
// key.
func seed(a address, rating int) {
	clanNumber("Pickers")
	saveStanding(a, &standing{rating: rating, wins: 1, lastClan: 1, perClan: []int{1}})
	ladder, _ = ladder.Set(ladderKey(rating, a), nil)
}

// ladderKeys lists the ladder's keys in order.
func ladderKeys() []string {
	var keys []string
	ladder.TraverseByOffset(0, ladder.Size(), true, true, func(n *avl.Node) bool {
		keys = append(keys, n.Key())
		return false
	})
	return keys
}

func TestExpectedTableMatchesFormula(t *testing.T) {
	for i, e := range expectedTable {
		d := float64(i * 25)
		uassert.Equal(t, int(math.Round(1000/(1+math.Pow(10, d/400)))), e)
	}
}

func TestExpected(t *testing.T) {
	uassert.Equal(t, 500, expected(1000, 1000))
	uassert.Equal(t, 500, expected(1000, 1012), "a gap of 12 rounds to 0")
	uassert.Equal(t, 464, expected(1000, 1013), "a gap of 13 rounds to 25")
	uassert.Equal(t, 360, expected(1000, 1100))
	uassert.Equal(t, 640, expected(1100, 1000))
	uassert.Equal(t, 91, expected(1000, 1500), "the gap is capped at 400")
	uassert.Equal(t, 909, expected(1500, 1000))
}

func TestEloChange(t *testing.T) {
	uassert.Equal(t, 16, eloChange(1000, 1000, 1000, playerK))
	uassert.Equal(t, 0, eloChange(1000, 1000, 500, playerK))
	uassert.Equal(t, 20, eloChange(1000, 1100, 1000, playerK))
	uassert.Equal(t, -12, eloChange(1000, 1100, 0, playerK))
	uassert.Equal(t, 4, eloChange(1000, 1100, 500, playerK))
	uassert.Equal(t, 12, eloChange(1100, 1000, 1000, playerK))
	uassert.Equal(t, -20, eloChange(1100, 1000, 0, playerK))
	uassert.Equal(t, 29, eloChange(1000, 1500, 1000, playerK))
	uassert.Equal(t, 8, eloChange(1000, 1000, 1000, clanK))
}

func TestApplyChangeClamps(t *testing.T) {
	a, b := applyChange(1000, 1000, 16)
	uassert.Equal(t, 1016, a)
	uassert.Equal(t, 984, b)
	a, b = applyChange(5, 5, -16)
	uassert.Equal(t, 0, a, "no rating goes below 0")
	uassert.Equal(t, 21, b)
	a, b = applyChange(65530, 900, 29)
	uassert.Equal(t, maxRating, a, "no rating goes above what the ladder key holds")
	uassert.Equal(t, 871, b)
}

func TestRateFirstMatch(cur realm, t *testing.T) {
	reset()
	testing.SetRealm(testing.NewCodeRealm(arenaV0))
	Record(cross(cur), alice, bob, "Pickers", "Ironhide", "a")

	a := loadStanding(alice)
	urequire.True(t, a != nil)
	uassert.Equal(t, "1016 1-0-0 last 1 per 1", showStanding(*a))
	uassert.Equal(t, 1, a.mainClan())
	b := loadStanding(bob)
	urequire.True(t, b != nil)
	uassert.Equal(t, "984 0-1-0 last 2 per 0 1", showStanding(*b))
	uassert.Equal(t, 2, b.mainClan())

	uassert.Equal(t, 2, ladder.Size())
	uassert.Equal(t, 1, rankOf(1016))
	uassert.Equal(t, 2, rankOf(984))
	urequire.Equal(t, 2, len(clans))
	uassert.True(t, clans[0] == clanRecord{"Pickers", 1008, 1, 0, 0})
	uassert.True(t, clans[1] == clanRecord{"Ironhide", 992, 0, 1, 0})
}

func TestRateMovesLadderKeys(cur realm, t *testing.T) {
	reset()
	testing.SetRealm(testing.NewCodeRealm(arenaV0))
	Record(cross(cur), alice, bob, "Pickers", "Ironhide", "a")
	Record(cross(cur), alice, bob, "Pickers", "Ironhide", "a")
	a, b := loadStanding(alice), loadStanding(bob)
	keys := ladderKeys()
	urequire.Equal(t, 2, len(keys))
	uassert.Equal(t, ladderKey(a.rating, alice), keys[0])
	uassert.Equal(t, ladderKey(b.rating, bob), keys[1])
}

func TestRateDraw(cur realm, t *testing.T) {
	reset()
	testing.SetRealm(testing.NewCodeRealm(arenaV0))
	Record(cross(cur), alice, bob, "Pickers", "Ironhide", "draw")
	uassert.Equal(t, "1000 0-0-1 last 1 per 1", showStanding(*loadStanding(alice)))
	uassert.Equal(t, "1000 0-0-1 last 2 per 0 1", showStanding(*loadStanding(bob)))
}

func TestForfeitCountsForClans(cur realm, t *testing.T) {
	reset()
	testing.SetRealm(testing.NewCodeRealm(arenaV0))
	Record(cross(cur), alice, bob, "Pickers", "Ironhide", "b")
	uassert.Equal(t, 984, loadStanding(alice).rating)
	uassert.Equal(t, 1016, loadStanding(bob).rating)
	uassert.True(t, clans[0] == clanRecord{"Pickers", 992, 0, 1, 0}, "the clan that ran out of time loses")
	uassert.True(t, clans[1] == clanRecord{"Ironhide", 1008, 1, 0, 0})
}

func TestMirrorSkipsClans(cur realm, t *testing.T) {
	reset()
	testing.SetRealm(testing.NewCodeRealm(arenaV0))
	Record(cross(cur), alice, bob, "Pickers", "Pickers", "a")
	uassert.Equal(t, 1016, loadStanding(alice).rating)
	urequire.Equal(t, 1, len(clans))
	uassert.True(t, clans[0] == clanRecord{name: "Pickers", rating: startRating})
}

func TestSharedRank(t *testing.T) {
	reset()
	seed(alice, 1016)
	seed(bob, 1016)
	seed(carol, 984)
	uassert.Equal(t, 1, rankOf(1016))
	uassert.Equal(t, 3, rankOf(984))
}

func TestMainClanTie(t *testing.T) {
	uassert.Equal(t, 2, standing{lastClan: 2, perClan: []int{2, 2, 0}}.mainClan())
	uassert.Equal(t, 1, standing{lastClan: 1, perClan: []int{2, 2, 0}}.mainClan())
	uassert.Equal(t, 1, standing{lastClan: 3, perClan: []int{2, 2, 1}}.mainClan(), "a tie the last clan is not in goes to first-seen order")
	uassert.Equal(t, 0, standing{}.mainClan())
}

func TestClanNumbersFollowFirstSeen(cur realm, t *testing.T) {
	reset()
	testing.SetRealm(testing.NewCodeRealm(arenaV0))
	Record(cross(cur), alice, bob, "Ironhide", "Delvers", "a")
	first := showStanding(*loadStanding(alice))
	Record(cross(cur), carol, dave, "Pickers", "Ironhide", "a")

	urequire.Equal(t, 3, len(clans))
	uassert.Equal(t, "Ironhide", clans[0].name)
	uassert.Equal(t, "Delvers", clans[1].name)
	uassert.Equal(t, "Pickers", clans[2].name)
	uassert.Equal(t, "1016 1-0-0 last 1 per 1", first)
	uassert.Equal(t, first, showStanding(*loadStanding(alice)), "a new clan moves no earlier count")
	uassert.Equal(t, "1016 1-0-0 last 3 per 0 0 1", showStanding(*loadStanding(carol)))
	uassert.Equal(t, "984 0-1-0 last 1 per 1", showStanding(*loadStanding(dave)))
}

func TestCountersSaturate(cur realm, t *testing.T) {
	reset()
	clanNumber("Pickers")
	clanNumber("Ironhide")
	saveStanding(alice, &standing{rating: startRating, wins: 65535, lastClan: 1, perClan: []int{65535, 0}})
	clans[1].losses = 4294967295

	testing.SetRealm(testing.NewCodeRealm(arenaV0))
	Record(cross(cur), alice, bob, "Pickers", "Ironhide", "a")
	a := loadStanding(alice)
	uassert.Equal(t, 65535, a.wins)
	uassert.Equal(t, 65535, a.perClan[0])
	uassert.Equal(t, 4294967295, clans[1].losses)
}

func TestResultsLogEachRecord(cur realm, t *testing.T) {
	reset()
	testing.SetRealm(testing.NewCodeRealm(arenaV0))
	Record(cross(cur), alice, bob, "Pickers", "Ironhide", "a")
	Record(cross(cur), bob, alice, "Ironhide", "Ironhide", "draw")

	urequire.Equal(t, 2, resultCount())
	now := time.Now().Unix()
	first := resultAt(1)
	uassert.True(t, first == resultEntry{writer: 1, challenger: alice, acceptor: bob, clans: [2]int{1, 2}, result: 'a', time: now})
	second := resultAt(2)
	uassert.True(t, second == resultEntry{writer: 1, challenger: bob, acceptor: alice, clans: [2]int{2, 2}, result: 'd', time: now})
}

// TestResultsShareChunks checks that a new log entry grows a chunk string instead of adding
// tree nodes, which would cost a rated ending far more storage.
func TestResultsShareChunks(cur realm, t *testing.T) {
	reset()
	testing.SetRealm(testing.NewCodeRealm(arenaV0))
	for i := 0; i < 65; i++ {
		Record(cross(cur), alice, bob, "Pickers", "Ironhide", "a")
	}
	uassert.Equal(t, 2, results.Size(), "64 results to a chunk")
	uassert.Equal(t, 65, resultCount())
	uassert.True(t, resultAt(65) == resultEntry{writer: 1, challenger: alice, acceptor: bob, clans: [2]int{1, 2}, result: 'a', time: time.Now().Unix()})
}

// TestClanPastTheTableCountsForNone checks that a writer filling the clan table cannot stop
// another writer's endings: a clan past the table rates its players and counts for no clan.
func TestClanPastTheTableCountsForNone(cur realm, t *testing.T) {
	reset()
	for i := 1; i <= 255; i++ {
		clanNumber("c" + strconv.Itoa(i))
	}
	testing.SetRealm(testing.NewCodeRealm(arenaV0))
	Record(cross(cur), alice, bob, "c1", "c256", "a")

	uassert.Equal(t, 255, len(clans))
	uassert.True(t, clans[0] == clanRecord{name: "c1", rating: startRating}, "a clan's record moves only against another counted clan")
	uassert.Equal(t, "1016 1-0-0 last 1 per 1", showStanding(*loadStanding(alice)))
	uassert.Equal(t, "984 0-1-0 last 0 per", showStanding(*loadStanding(bob)))
	uassert.Equal(t, 2, StandingOf(bob).Rank, "a player rated with no counted clan still has a rank")
	uassert.Equal(t, "", StandingOf(bob).MainClan)
	r := Results(0, 1)[0]
	uassert.Equal(t, "c1", r.ChallengerClan)
	uassert.Equal(t, "", r.AcceptorClan)
}
