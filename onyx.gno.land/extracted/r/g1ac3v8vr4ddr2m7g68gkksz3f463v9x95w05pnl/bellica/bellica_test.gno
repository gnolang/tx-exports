package bellica

import (
	"chain"
	"chain/banker"
	"strings"
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

var (
	pkgAddr = chain.PackageAddress("gno.land/r/g1ac3v8vr4ddr2m7g68gkksz3f463v9x95w05pnl/bellica")
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
	id := CreateBounty(cross(cur), "Fastest JSON parser", "https://example.com/spec", "ms per op", higher, splits, 60, 60, judgeAddr, "", 0)
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
	Disqualify(cross(cur), id, dave.String(), "10ms not reproducible") // dave's 10ms not reproducible

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

func TestUnfilledPlacesGoToCompetitors(cur realm, t *testing.T) {
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
	// only one place filled: the whole pot goes to alice, nothing back to the creator
	uassert.Equal(t, beforeAlice+3_000_001, bal(cur, alice))
	uassert.Equal(t, before, bal(cur, creator))
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
	uassert.Equal(t, "1.5 GNOT", gnot(1_500_000))
	uassert.Equal(t, "2 GNOT", gnot(2_000_000))
	uassert.Equal(t, `\[x\]\(javascript:\)`, esc("[x](javascript:)"))
	uassert.Equal(t, `evil\]\(x\)`, link("evil](x)"))
}

func itoa(i int) string {
	return strings.TrimLeft(key(i), "0")
}

// submit is a helper: agent a enters bounty id with a claimed score.
func submit(cur realm, a address, id int, score int64) {
	testing.SetRealm(testing.NewUserRealm(a))
	Submit(cross(cur), id, "https://github.com/x/"+a.String()[:6], "abc1234", "", score)
}


func TestTieBreakAndResubmit(cur realm, t *testing.T) {
	register(cur, alice, "alice-bot")
	register(cur, bob, "bob-bot")
	register(cur, carol, "carol-bot")
	id := newBounty(cur, 10_000_000, "70,30", true, judge.String())
	submit(cur, alice, id, 50)
	submit(cur, bob, id, 50)
	submit(cur, carol, id, 50)
	submit(cur, alice, id, 50) // alice resubmits: loses the tie-break edge
	minutes(61)
	testing.SetRealm(testing.NewUserRealm(judge))
	AcceptClaimed(cross(cur), id)
	a0, b0, c0 := bal(cur, alice), bal(cur, bob), bal(cur, carol)
	Finalize(cross(cur), id)
	// all tied at 50: order is bob, carol, alice
	uassert.Equal(t, b0+7_000_000, bal(cur, bob))
	uassert.Equal(t, c0+3_000_000, bal(cur, carol))
	uassert.Equal(t, a0, bal(cur, alice))
	uassert.Equal(t, 3, mustEntry(mustBounty(id), alice.String()).Rank)
}

func TestFinalizeNeedsEveryEntryJudged(cur realm, t *testing.T) {
	register(cur, alice, "alice-bot")
	register(cur, bob, "bob-bot")
	id := newBounty(cur, 2_000_000, "100", false, judge.String())
	submit(cur, alice, id, 10)
	submit(cur, bob, id, 20)
	minutes(61)
	testing.SetRealm(testing.NewUserRealm(judge))
	ScoreEntry(cross(cur), id, alice.String(), 11)
	// the judge cannot just skip bob
	uassert.AbortsWithMessage(t, cur, "score or disqualify every entry before Finalize (AcceptClaimed scores the rest)", func() { Finalize(cross(cur), id) })
	// a reason is mandatory to disqualify
	uassert.AbortsWithMessage(t, cur, "reason must be 3-280 characters", func() { Disqualify(cross(cur), id, bob.String(), "") })
	Disqualify(cross(cur), id, bob.String(), "commit not found")
	// re-scoring reinstates a DQ'd entry and clears the reason
	ScoreEntry(cross(cur), id, bob.String(), 5)
	e := mustEntry(mustBounty(id), bob.String())
	uassert.False(t, e.Disqualified)
	uassert.Equal(t, "", e.DQReason)
	uassert.AbortsWithMessage(t, cur, "entry not found", func() { ScoreEntry(cross(cur), id, carol.String(), 1) })
	b0 := bal(cur, bob)
	Finalize(cross(cur), id)
	uassert.Equal(t, b0+2_000_000, bal(cur, bob)) // lower is better: bob 5 beats alice 11
}

func TestAllDisqualifiedRefundsCreator(cur realm, t *testing.T) {
	register(cur, alice, "alice-bot")
	id := newBounty(cur, 1_000_000, "100", true, judge.String())
	submit(cur, alice, id, 99)
	minutes(61)
	testing.SetRealm(testing.NewUserRealm(judge))
	Disqualify(cross(cur), id, alice.String(), "plagiarized solution")
	c0 := bal(cur, creator)
	Finalize(cross(cur), id)
	uassert.Equal(t, c0+1_000_000, bal(cur, creator))
	uassert.Equal(t, "refunded", Phase(id))
	out := Render("bounty/" + itoa(id))
	uassert.True(t, strings.Contains(out, "plagiarized solution"), out)
}

func TestMoreEntriesThanPlaces(cur realm, t *testing.T) {
	for _, a := range []address{alice, bob, carol, dave} {
		register(cur, a, "bot-"+a.String()[:5])
	}
	id := newBounty(cur, 4_000_000, "75,25", true, "")
	submit(cur, alice, id, 1)
	submit(cur, bob, id, 4)
	submit(cur, carol, id, 3)
	submit(cur, dave, id, 2)
	minutes(61)
	testing.SetRealm(testing.NewUserRealm(creator))
	AcceptClaimed(cross(cur), id)
	c0, d0 := bal(cur, carol), bal(cur, dave)
	ranked0 := agentOf(dave).Ranked
	Finalize(cross(cur), id)
	b := mustBounty(id)
	uassert.Equal(t, 1, mustEntry(b, bob.String()).Rank)
	uassert.Equal(t, int64(3_000_000), mustEntry(b, bob.String()).Payout)
	uassert.Equal(t, c0+1_000_000, bal(cur, carol))
	uassert.Equal(t, 3, mustEntry(b, dave.String()).Rank) // ranked but unpaid
	uassert.Equal(t, d0, bal(cur, dave))
	uassert.Equal(t, ranked0+1, agentOf(dave).Ranked)
	uassert.Equal(t, int64(4_000_000), b.Paid)
}

func TestFallbackSkipsDQAndRefundsEmpty(cur realm, t *testing.T) {
	register(cur, alice, "alice-bot")
	register(cur, bob, "bob-bot")
	id := newBounty(cur, 3_000_000, "100", true, judge.String())
	submit(cur, alice, id, 1)
	submit(cur, bob, id, 2)
	minutes(61)
	testing.SetRealm(testing.NewUserRealm(judge))
	Disqualify(cross(cur), id, bob.String(), "timed out on the benchmark")
	minutes(61) // judge then goes silent
	a0, b0 := bal(cur, alice), bal(cur, bob)
	testing.SetRealm(testing.NewUserRealm(carol))
	Fallback(cross(cur), id)
	uassert.Equal(t, a0+3_000_000, bal(cur, alice))
	uassert.Equal(t, b0, bal(cur, bob))
	uassert.AbortsWithMessage(t, cur, "fallback only after the judging window, on an unfinalized bounty", func() { Fallback(cross(cur), id) })

	// an expired bounty with no entries: fallback refunds the creator
	id2 := newBounty(cur, 1_000_000, "100", true, "")
	minutes(122)
	c0 := bal(cur, creator)
	testing.SetRealm(testing.NewUserRealm(carol))
	Fallback(cross(cur), id2)
	uassert.Equal(t, c0+1_000_000, bal(cur, creator))
	uassert.Equal(t, "refunded", Phase(id2))
}

func TestCreateBountyValidation(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(creator))
	mk := func(pot int64, title, splits string, dur, jw int, j string) func() {
		return func() {
			testing.SetOriginSend(chain.Coins{{"ugnot", pot}})
			CreateBounty(cross(cur), title, "", "ms", false, splits, dur, jw, j, "", 0)
		}
	}
	uassert.AbortsWithMessage(t, cur, "pot too small: send at least 1000000 ugnot", mk(999_999, "Valid title", "100", 10, 10, ""))
	uassert.AbortsWithMessage(t, cur, "title must be 3-80 characters", mk(1_000_000, "ab", "100", 10, 10, ""))
	uassert.AbortsWithMessage(t, cur, "title must be a single line", mk(1_000_000, "two\nlines", "100", 10, 10, ""))
	uassert.AbortsWithMessage(t, cur, "durationMin out of range", mk(1_000_000, "Valid title", "100", 0, 10, ""))
	uassert.AbortsWithMessage(t, cur, "judgeWindowMin out of range", mk(1_000_000, "Valid title", "100", 10, MaxDuration+1, ""))
	uassert.AbortsWithMessage(t, cur, "invalid judge address", mk(1_000_000, "Valid title", "100", 10, 10, "not-an-address"))
	uassert.AbortsWithMessage(t, cur, "splits must sum to 100", mk(1_000_000, "Valid title", "60,30", 10, 10, ""))
	testing.SetOriginSend(nil)
	uassert.PanicsWithMessage(t, cur, "bounty not found", func() { Phase(99999) })
}

func TestRenderPages(cur realm, t *testing.T) {
	register(cur, alice, "alice-bot")
	testing.SetRealm(testing.NewUserRealm(bob))
	Register(cross(cur), "<script>x</script>", "javascript:alert(1)", "**bold** [x](y)")
	id := newBounty(cur, 5_000_000, "50,30,20", false, judge.String())
	testing.SetRealm(testing.NewUserRealm(bob))
	Submit(cross(cur), id, "https://github.com/b/p", "deadbeef", "my | note", 42)
	home := Render("")
	uassert.True(t, strings.Contains(home, "Live bounties"), home)
	uassert.True(t, strings.Contains(home, "<gno-columns>"), home)
	bp := Render("bounty/" + itoa(id) + "?tab=x")
	uassert.True(t, strings.Contains(bp, "Leaderboard (live"), bp)
	uassert.True(t, strings.Contains(bp, "**🟢 Open**"), bp)
	uassert.True(t, strings.Contains(bp, "2.5 GNOT"), bp) // 1st place prize
	uassert.True(t, strings.Contains(bp, "my \\| note"), bp)
	uassert.False(t, strings.Contains(bp, "<script>"), bp)
	ap := Render("agent/" + bob.String())
	uassert.True(t, strings.Contains(ap, "\\<script\\>"), ap)
	uassert.False(t, strings.Contains(ap, "](javascript:"), ap)
	uassert.True(t, strings.Contains(Render("help"), "Quickstart for agents"))
	uassert.Equal(t, Render("help"), Render("how"))
	uassert.True(t, strings.Contains(Render("agents"), "alice-bot"))
	uassert.True(t, strings.Contains(Render("stats"), "Held for unclosed bounties + jobs"), Render("stats"))
	uassert.True(t, strings.Contains(Render("nope/x"), "# 404"))
	uassert.True(t, strings.Contains(Render("bounty/abc"), "# 404"))
	uassert.True(t, strings.Contains(Render("agent/g1nobody"), "# 404"))
	minutes(61)
	uassert.True(t, strings.Contains(Render("bounty/"+itoa(id)), "Judging in progress"))
	minutes(61)
	uassert.True(t, strings.Contains(Render("bounty/"+itoa(id)), "Trigger fair split"))
}

func TestJSONEndpoints(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(alice))
	Register(cross(cur), "quote\"bot", "", "line\\back")
	id := newBounty(cur, 1_000_000, "100", true, "")
	testing.SetRealm(testing.NewUserRealm(alice))
	Submit(cross(cur), id, "https://github.com/a/j", "c0ffee", "say \"hi\"\t", 7)
	one := Render("json/bounty/" + itoa(id))
	uassert.True(t, strings.HasPrefix(one, `{"id":`), one)
	uassert.True(t, strings.Contains(one, `"note":"say \"hi\""`), one) // tab cleaned at input (AUDIT F1)
	uassert.Equal(t, `"a\u0009b\u001b"`, jq("a\tb\x1b"))                  // jq still escapes controls
	uassert.True(t, strings.Contains(one, `"name":"quote\"bot"`), one)
	uassert.True(t, strings.Contains(Render("json/bounties"), `"phase":"open"`))
	uassert.True(t, strings.Contains(Render("json/open"), `"id":`+itoa(id)))
	uassert.True(t, strings.Contains(Render("json/agent/"+alice.String()), `"bio":"line\\back"`))
	uassert.True(t, strings.HasPrefix(Render("json/agents"), `[{"address":`))
	uassert.True(t, strings.Contains(Render("json/stats"), `"invariant_ok":`), Render("json/stats"))
	uassert.Equal(t, `{"error":"bounty not found"}`, Render("json/bounty/424242"))
	uassert.True(t, strings.HasPrefix(Render("json/zzz"), `{"error":`))
	uassert.Equal(t, "\"\ufffd\"", jq(string([]byte{0xff})))
	uassert.Equal(t, OpenBountiesJSON(), Render("json/open"))
}

func TestEscrowAccounting(cur realm, t *testing.T) {
	// every bounty created in these tests is closed or open; escrowed must equal
	// the sum of pots of the bounties still open, and the realm must hold it.
	sum := int64(0)
	bounties.Iterate("", "", func(_ string, v any) bool {
		if b := v.(*Bounty); b.Status == StatusOpen {
			sum += b.Pot
		} else {
			uassert.True(t, b.Paid == b.Pot || b.Paid == 0, "a closed bounty pays all or nothing")
		}
		return false
	})
	uassert.Equal(t, sum, escrowed)
}

// Within one test the banker is consistent, so the audit must hold end to end.
func TestEscrowInvariantLive(cur realm, t *testing.T) {
	register(cur, alice, "alice-bot")
	base := escrowed
	id := newBounty(cur, 2_000_000, "100", true, "")
	uassert.Equal(t, base+2_000_000, escrowed)
	uassert.True(t, realmBalance() >= 2_000_000)
	submit(cur, alice, id, 3)
	minutes(61)
	testing.SetRealm(testing.NewUserRealm(creator))
	AcceptClaimed(cross(cur), id)
	Finalize(cross(cur), id)
	uassert.Equal(t, base, escrowed)
	uassert.Equal(t, int64(0), realmBalance())
}
