package podium

import (
	"chain"
	"chain/banker"
	"strings"
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

var (
	pkgAddr = chain.PackageAddress("gno.land/r/g1ac3v8vr4ddr2m7g68gkksz3f463v9x95w05pnl/podium")
	creator = testutils.TestAddress("creator")
	judge   = testutils.TestAddress("judge")
	alice   = testutils.TestAddress("alice")
	bob     = testutils.TestAddress("bob")
	carol   = testutils.TestAddress("carol")
	dave    = testutils.TestAddress("dave")
)

func minutes(n int64) { testing.SkipHeights(n * 12) } // 5s blocks

func bal(cur realm, a address) int64 {
	return int64(banker.NewReadonlyBanker().GetCoins(a).AmountOf("ugnot"))
}

func newBounty(cur realm, pot int64, splits string, higher bool, judgeAddr string) int {
	testing.IssueCoins(pkgAddr, chain.Coins{{"ugnot", pot}})
	testing.SetRealm(testing.NewUserRealm(creator))
	testing.SetOriginSend(chain.Coins{{"ugnot", pot}})
	id := CreateBounty(cross(cur), "Fastest JSON parser", "https://example.com/spec", "ms per op", higher, splits, 60, 60, judgeAddr)
	testing.SetOriginSend(nil)
	return id
}

func register(cur realm, a address, name string) {
	testing.SetRealm(testing.NewUserRealm(a))
	Register(cross(cur), name, "https://example.com/"+name+"/agent.json", "an agent")
}

func TestRankedPayout(cur realm, t *testing.T) {
	for _, a := range []address{alice, bob, carol, dave} {
		register(cur, a, strings.ToUpper(a.String()[:4]))
	}
	register(cur, alice, "alice-bot")
	id := newBounty(cur, 10_000_000, "50,30,20", false, judge.String())
	uassert.Equal(t, "open", Phase(id))

	testing.SetRealm(testing.NewUserRealm(alice))
	Submit(cross(cur), id, "https://github.com/a/p", "abc1234", "simd", 120)
	testing.SetRealm(testing.NewUserRealm(bob))
	Submit(cross(cur), id, "https://github.com/b/p", "def5678", "", 90)
	testing.SetRealm(testing.NewUserRealm(carol))
	Submit(cross(cur), id, "https://github.com/c/p", "aaa0001", "", 150)
	testing.SetRealm(testing.NewUserRealm(dave))
	Submit(cross(cur), id, "https://github.com/d/p", "bbb0002", "", 10)

	// judge cannot act before the deadline
	testing.SetRealm(testing.NewUserRealm(judge))
	uassert.AbortsWithMessage(t, cur, "bounty is not in judging (wait for the deadline)", func() { Finalize(cross(cur), id) })

	minutes(61)
	uassert.Equal(t, "judging", Phase(id))
	// late submissions are rejected
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsWithMessage(t, cur, "submissions are closed", func() { Submit(cross(cur), id, "https://github.com/b/p", "zzz9999", "", 1) })
	// only the judge can score
	uassert.AbortsWithMessage(t, cur, "only the judge can do this", func() { ScoreEntry(cross(cur), id, bob.String(), 1) })

	testing.SetRealm(testing.NewUserRealm(judge))
	n := AcceptClaimed(cross(cur), id)
	uassert.Equal(t, 4, n)
	ScoreEntry(cross(cur), id, bob.String(), 95) // judge re-measured bob
	Disqualify(cross(cur), id, dave.String())    // dave's 10ms not reproducible

	before := bal(cur, creator)
	Finalize(cross(cur), id)
	uassert.Equal(t, "paid", Phase(id))

	// lower is better: bob 95 (1st), alice 120 (2nd), carol 150 (3rd)
	uassert.Equal(t, int64(5_000_000), bal(cur, bob))
	uassert.Equal(t, int64(3_000_000), bal(cur, alice))
	uassert.Equal(t, int64(2_000_000), bal(cur, carol))
	uassert.Equal(t, int64(0), bal(cur, dave))
	uassert.Equal(t, before, bal(cur, creator))
	uassert.Equal(t, 1, agentOf(bob).Wins)
	uassert.Equal(t, int64(3_000_000), agentOf(alice).Earned)

	out := Render("bounty/" + itoa(id))
	uassert.True(t, strings.Contains(out, "🥇 1st"), out)
	uassert.True(t, strings.Contains(out, "🚫 DQ"), out)
	uassert.True(t, strings.Contains(Render(""), "Fastest JSON parser"))
	uassert.True(t, strings.Contains(BountyJSON(id), `"phase":"paid"`))

	// cannot finalize twice
	uassert.AbortsWithMessage(t, cur, "bounty is not in judging (wait for the deadline)", func() { Finalize(cross(cur), id) })
}

func TestUnfilledPlacesReturnToCreator(cur realm, t *testing.T) {
	register(cur, alice, "alice-bot")
	id := newBounty(cur, 3_000_001, "50,30,20", true, "")
	testing.SetRealm(testing.NewUserRealm(alice))
	Submit(cross(cur), id, "https://github.com/a/q", "c0ffee1", "", 7)
	minutes(61)
	before := bal(cur, creator)
	beforeAlice := bal(cur, alice)
	testing.SetRealm(testing.NewUserRealm(creator)) // creator judges when judge is empty
	AcceptClaimed(cross(cur), id)
	Finalize(cross(cur), id)
	// 50% + rounding dust (1) to alice, the other 50% back to the creator
	uassert.Equal(t, beforeAlice+1_500_001, bal(cur, alice))
	uassert.Equal(t, before+1_500_000, bal(cur, creator))
}

func TestFallbackWhenJudgeSilent(cur realm, t *testing.T) {
	register(cur, alice, "alice-bot")
	register(cur, bob, "bob-bot")
	id := newBounty(cur, 2_000_001, "100", true, judge.String())
	testing.SetRealm(testing.NewUserRealm(alice))
	Submit(cross(cur), id, "https://github.com/a/r", "1111111", "", 1)
	testing.SetRealm(testing.NewUserRealm(bob))
	Submit(cross(cur), id, "https://github.com/b/r", "2222222", "", 2)

	minutes(61)
	testing.SetRealm(testing.NewUserRealm(carol))
	uassert.AbortsWithMessage(t, cur, "fallback only after the judging window, on an unfinalized bounty", func() { Fallback(cross(cur), id) })
	minutes(61)
	uassert.Equal(t, "awaiting-fallback", Phase(id))
	// judge is too late now
	testing.SetRealm(testing.NewUserRealm(judge))
	uassert.AbortsWithMessage(t, cur, "judging window is over; use Fallback", func() { Finalize(cross(cur), id) })

	a0, b0 := bal(cur, alice), bal(cur, bob)
	testing.SetRealm(testing.NewUserRealm(carol)) // anyone can trigger it
	Fallback(cross(cur), id)
	uassert.Equal(t, a0+1_000_001, bal(cur, alice)) // first submitter gets the dust
	uassert.Equal(t, b0+1_000_000, bal(cur, bob))
	uassert.Equal(t, "fallback", Phase(id))
}

func TestCancelAndRules(cur realm, t *testing.T) {
	register(cur, alice, "alice-bot")
	id := newBounty(cur, 1_000_000, "60,40", true, "")
	// non-creator cannot cancel
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsWithMessage(t, cur, "only the creator can cancel", func() { Cancel(cross(cur), id) })
	// creator cannot enter own bounty
	register(cur, creator, "creator-bot")
	uassert.AbortsWithMessage(t, cur, "creator and judge cannot compete in their own bounty", func() {
		Submit(cross(cur), id, "https://github.com/x/y", "abcdef0", "", 1)
	})
	before := bal(cur, creator)
	testing.SetRealm(testing.NewUserRealm(creator))
	Cancel(cross(cur), id)
	uassert.Equal(t, before+1_000_000, bal(cur, creator))
	uassert.Equal(t, "cancelled", Phase(id))

	// unregistered agents cannot submit
	id2 := newBounty(cur, 1_000_000, "100", true, "")
	testing.SetRealm(testing.NewUserRealm(testutils.TestAddress("stranger")))
	uassert.AbortsWithMessage(t, cur, "register your agent first (Register)", func() {
		Submit(cross(cur), id2, "https://github.com/x/y", "abcdef0", "", 1)
	})
	// creator cannot cancel once an entry exists
	testing.SetRealm(testing.NewUserRealm(alice))
	Submit(cross(cur), id2, "https://github.com/a/z", "abcdef0", "", 1)
	testing.SetRealm(testing.NewUserRealm(creator))
	uassert.AbortsWithMessage(t, cur, "cannot cancel: bounty has entries or is closed", func() { Cancel(cross(cur), id2) })
}

func TestValidation(cur realm, t *testing.T) {
	uassert.PanicsWithMessage(t, cur, "splits must sum to 100", func() { parseSplits("50,30") })
	uassert.PanicsWithMessage(t, cur, "splits: a lower place cannot pay more than a higher one", func() { parseSplits("30,70") })
	uassert.PanicsWithMessage(t, cur, "splits: each place must be a positive integer percent", func() { parseSplits("50,x,50") })
	uassert.Equal(t, 3, len(parseSplits("50, 30, 20")))
	uassert.Equal(t, "1.5 GNOT", gnot(1_500_000))
	uassert.Equal(t, "2 GNOT", gnot(2_000_000))
	uassert.Equal(t, `\[x\]\(javascript:\)`, esc("[x](javascript:)"))
	uassert.Equal(t, `evil\]\(x\)`, link("evil](x)"))
}

func itoa(i int) string {
	return strings.TrimLeft(key(i), "0")
}
