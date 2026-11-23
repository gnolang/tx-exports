package questboard

import (
	"chain"
	"chain/banker"
	"strings"
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
	"gno.land/p/nt/urequire/v0"
)

var (
	realmAddr = chain.PackageAddress("gno.land/r/g1rwxskhs8tm98yxcj5tuehwplwnqzacuqsqgrtq/questboard")
	alice     = testutils.TestAddress("alice")   // poster
	bob       = testutils.TestAddress("bob")     // hunter
	carol     = testutils.TestAddress("carol")   // hunter
	dave      = testutils.TestAddress("dave")    // funder
	judge     = testutils.TestAddress("arbiter") // arbiter
)

func ugnot(n int64) chain.Coins { return chain.Coins{{Denom: "ugnot", Amount: n}} }

func balance(_ realm, a address) int64 {
	return banker.NewReadonlyBanker().GetCoins(a).AmountOf("ugnot")
}

// deposit simulates the bank moving -send coins into the realm.
func deposit(n int64) { testing.IssueCoins(realmAddr, ugnot(n)) }

func reset() {
	nextID = 0
	quests = avlTree()
	open = avlTree()
	closed = nil
	profiles = avlTree()
	openCount, escrowed, paidOut, refunded, completed = 0, 0, 0, 0, 0
}

func post(cur realm, who address, amount int64, arbiter string) int {
	testing.SetRealm(testing.NewUserRealm(who))
	testing.SetOriginSend(ugnot(amount))
	deposit(amount)
	return PostQuest(cross(cur), "Write a GRC20 airdrop script", "Needs tests.\n\nMIT license.", 7, arbiter)
}

func TestPostSubmitAward(cur realm, t *testing.T) {
	reset()
	id := post(cur, alice, 1_000_000, "")
	uassert.Equal(t, 1, id)

	testing.SetRealm(testing.NewUserRealm(dave))
	testing.SetOriginSend(ugnot(500_000))
	deposit(500_000)
	Fund(cross(cur), id)

	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(nil)
	Submit(cross(cur), id, "https://gitlab.com/bob/airdrop/-/merge_requests/1", "done, with tests")
	testing.SetRealm(testing.NewUserRealm(carol))
	testing.SetOriginSend(nil)
	Submit(cross(cur), id, "https://example.com/carol", "")

	r, st := RewardOf(id)
	uassert.Equal(t, int64(1_500_000), r)
	uassert.Equal(t, "open", st)

	// Only poster/arbiter can award.
	testing.SetRealm(testing.NewUserRealm(carol))
	testing.SetOriginSend(nil)
	uassert.AbortsWithMessage(t, cur, "only the poster or arbiter can award a quest", func() { Award(cross(cur), id, bob.String()) })

	before := balance(cur, bob)
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	Award(cross(cur), id, bob.String())
	uassert.Equal(t, int64(1_500_000), balance(cur, bob)-before)

	q := mustGet(id)
	uassert.Equal(t, StatusAwarded.String(), q.Status.String())
	uassert.Equal(t, bob.String(), q.Winner.String())
	o, esc, paid, done := Stats()
	uassert.Equal(t, 0, o)
	uassert.Equal(t, int64(0), esc)
	uassert.Equal(t, int64(1_500_000), paid)
	uassert.Equal(t, 1, done)

	pa := peekProfile(alice)
	uassert.Equal(t, 1, pa.Posted)
	uassert.Equal(t, 1, pa.Completed)
	uassert.Equal(t, int64(1_500_000), pa.Paid)
	pb := peekProfile(bob)
	uassert.Equal(t, 1, pb.Won)
	uassert.Equal(t, int64(1_500_000), pb.Earned)
	uassert.Equal(t, int64(500_000), peekProfile(dave).Funded)

	// Closed quests reject everything.
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	uassert.AbortsWithMessage(t, cur, "quest is awarded", func() { Cancel(cross(cur), id) })
	testing.SetRealm(testing.NewUserRealm(carol))
	testing.SetOriginSend(nil)
	uassert.AbortsWithMessage(t, cur, "quest is awarded", func() { Submit(cross(cur), id, "https://x.y", "") })
}

func TestCancelRefundsEveryone(cur realm, t *testing.T) {
	reset()
	id := post(cur, alice, 2_000_000, "")
	testing.SetRealm(testing.NewUserRealm(dave))
	testing.SetOriginSend(ugnot(300_000))
	deposit(300_000)
	Fund(cross(cur), id)
	testing.SetRealm(testing.NewUserRealm(dave))
	testing.SetOriginSend(ugnot(200_000))
	deposit(200_000)
	Fund(cross(cur), id) // same funder aggregates
	urequire.Equal(t, 2, len(mustGet(id).Contribs))

	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(nil)
	Submit(cross(cur), id, "https://example.com/bob", "")

	a0, d0 := balance(cur, alice), balance(cur, dave)
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(nil)
	uassert.AbortsWithMessage(t, cur, "only the poster or arbiter can cancel a quest", func() { Cancel(cross(cur), id) })
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	Cancel(cross(cur), id)
	uassert.Equal(t, int64(2_000_000), balance(cur, alice)-a0)
	uassert.Equal(t, int64(500_000), balance(cur, dave)-d0)
	uassert.Equal(t, StatusCancelled.String(), mustGet(id).Status.String())
	// Cancelled with live work counts against the poster.
	uassert.Equal(t, 1, peekProfile(alice).Cancelled)
}

func TestCancelWithoutSubmissionsIsClean(cur realm, t *testing.T) {
	reset()
	id := post(cur, alice, 1_000_000, "")
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	Cancel(cross(cur), id)
	uassert.Equal(t, 0, peekProfile(alice).Cancelled)
}

func TestRejectAndResubmit(cur realm, t *testing.T) {
	reset()
	id := post(cur, alice, 1_000_000, "")
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(nil)
	Submit(cross(cur), id, "https://example.com/v1", "first try")
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(nil)
	uassert.AbortsWithMessage(t, cur, "only the poster or arbiter can reject submissions", func() { Reject(cross(cur), id, bob.String(), "no") })
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	Reject(cross(cur), id, bob.String(), "tests missing")
	uassert.AbortsWithMessage(t, cur, "that submission was rejected", func() { Award(cross(cur), id, bob.String()) })

	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(nil)
	Submit(cross(cur), id, "https://example.com/v2", "added tests")
	q := mustGet(id)
	urequire.Equal(t, 1, len(q.Subs))
	uassert.False(t, q.Subs[0].Rejected)
	uassert.Equal(t, "https://example.com/v2", q.Subs[0].Link)
	uassert.Equal(t, 1, peekProfile(bob).Submitted) // update, not a new submission

	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	Award(cross(cur), id, bob.String())
	uassert.Equal(t, StatusAwarded.String(), mustGet(id).Status.String())
}

func TestArbiter(cur realm, t *testing.T) {
	reset()
	id := post(cur, alice, 1_000_000, judge.String())
	testing.SetRealm(testing.NewUserRealm(judge))
	testing.SetOriginSend(nil)
	uassert.AbortsWithMessage(t, cur, "the poster or arbiter cannot submit to their own quest", func() {
		Submit(cross(cur), id, "https://example.com", "")
	})
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(nil)
	Submit(cross(cur), id, "https://example.com/bob", "")
	b0 := balance(cur, bob)
	testing.SetRealm(testing.NewUserRealm(judge))
	testing.SetOriginSend(nil)
	Award(cross(cur), id, bob.String())
	uassert.Equal(t, int64(1_000_000), balance(cur, bob)-b0)

	// arbiter cancelling does not mark the poster
	id2 := post(cur, alice, 1_000_000, judge.String())
	testing.SetRealm(testing.NewUserRealm(carol))
	testing.SetOriginSend(nil)
	Submit(cross(cur), id2, "https://example.com/carol", "")
	testing.SetRealm(testing.NewUserRealm(judge))
	testing.SetOriginSend(nil)
	Cancel(cross(cur), id2)
	uassert.Equal(t, 0, peekProfile(alice).Cancelled)

	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(ugnot(1_000_000))
	uassert.AbortsWithMessage(t, cur, "arbiter must be someone other than the poster", func() {
		PostQuest(cross(cur), "t", "", 3, alice.String())
	})
	uassert.AbortsWithMessage(t, cur, "invalid arbiter address", func() {
		PostQuest(cross(cur), "t", "", 3, "notanaddress")
	})
}

func TestDeadlineAndExpire(cur realm, t *testing.T) {
	reset()
	id := post(cur, alice, 1_000_000, "")
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(nil)
	Submit(cross(cur), id, "https://example.com/bob", "")

	testing.SetRealm(testing.NewUserRealm(carol))
	testing.SetOriginSend(nil)
	uassert.AbortsWithMessage(t, cur, "quest can only expire 168h0m0s after its deadline", func() { Expire(cross(cur), id) })

	// 8 days later: submissions closed, still inside grace period.
	testing.SkipHeights(8 * 24 * 720)
	testing.SetRealm(testing.NewUserRealm(carol))
	testing.SetOriginSend(nil)
	uassert.AbortsWithMessage(t, cur, "quest deadline has passed", func() { Submit(cross(cur), id, "https://late.example", "") })
	uassert.AbortsWithMessage(t, cur, "quest can only expire 168h0m0s after its deadline", func() { Expire(cross(cur), id) })
	uassert.True(t, strings.Contains(Render("quest/1"), "until refundable"))

	// 15 days after posting: anyone can expire, poster is marked as ghosting.
	testing.SkipHeights(7 * 24 * 720)
	a0 := balance(cur, alice)
	testing.SetRealm(testing.NewUserRealm(carol))
	testing.SetOriginSend(nil)
	Expire(cross(cur), id)
	uassert.Equal(t, int64(1_000_000), balance(cur, alice)-a0)
	uassert.Equal(t, StatusExpired.String(), mustGet(id).Status.String())
	uassert.Equal(t, 1, peekProfile(alice).Ghosted)
}

func TestAwardAfterDeadlineAllowed(cur realm, t *testing.T) {
	reset()
	id := post(cur, alice, 1_000_000, "")
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(nil)
	Submit(cross(cur), id, "https://example.com/bob", "")
	testing.SkipHeights(10 * 24 * 720)
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	Award(cross(cur), id, bob.String())
	uassert.Equal(t, StatusAwarded.String(), mustGet(id).Status.String())
}

func TestInputValidation(cur realm, t *testing.T) {
	reset()
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(ugnot(99_999))
	uassert.AbortsWithMessage(t, cur, "send at least 100000ugnot", func() { PostQuest(cross(cur), "t", "", 7, "") })
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: 1_000_000}, {Denom: "foo", Amount: 1}})
	uassert.AbortsWithMessage(t, cur, "send exactly one coin type: ugnot", func() { PostQuest(cross(cur), "t", "", 7, "") })
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	uassert.AbortsWithMessage(t, cur, "send exactly one coin type: ugnot", func() { PostQuest(cross(cur), "t", "", 7, "") })
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(ugnot(1_000_000))
	uassert.AbortsWithMessage(t, cur, "title is required", func() { PostQuest(cross(cur), "  ", "", 7, "") })
	uassert.AbortsWithMessage(t, cur, "days must be between 1 and 90", func() { PostQuest(cross(cur), "t", "", 0, "") })
	uassert.AbortsWithMessage(t, cur, "days must be between 1 and 90", func() { PostQuest(cross(cur), "t", "", 91, "") })
	uassert.AbortsWithMessage(t, cur, "title too long (max 80 bytes)", func() { PostQuest(cross(cur), strings.Repeat("x", 81), "", 7, "") })

	id := post(cur, alice, 1_000_000, "")
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	uassert.AbortsWithMessage(t, cur, "the poster or arbiter cannot submit to their own quest", func() { Submit(cross(cur), id, "https://a.b", "") })
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(nil)
	uassert.AbortsWithMessage(t, cur, "link must start with https:// or http://", func() { Submit(cross(cur), id, "javascript:alert(1)", "") })
	uassert.AbortsWithMessage(t, cur, "quest not found", func() { Submit(cross(cur), 99, "https://a.b", "") })
	testing.SetRealm(testing.NewUserRealm(dave))
	testing.SetOriginSend(ugnot(9_999))
	uassert.AbortsWithMessage(t, cur, "send at least 10000ugnot", func() { Fund(cross(cur), id) })
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	uassert.AbortsWithMessage(t, cur, "no submission from that address", func() { Award(cross(cur), id, carol.String()) })
}

func TestRender(cur realm, t *testing.T) {
	reset()
	uassert.True(t, strings.Contains(Render(""), "No open quests yet"))

	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(ugnot(1_250_000))
	deposit(1_250_000)
	id := PostQuest(cross(cur), "Fix | pipes *and* [links](javascript:x)", "# not a heading\n\nbody", 7, "")
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(nil)
	Submit(cross(cur), id, "https://example.com/pr/1", "see PR")

	home := Render("")
	uassert.True(t, strings.Contains(home, "**1** open quests"))
	uassert.True(t, strings.Contains(home, "1.25 GNOT"))
	uassert.True(t, strings.Contains(home, `Fix \| pipes`)) // table-safe title
	uassert.True(t, strings.Contains(home, "$help&func=PostQuest"))

	page := Render("quest/1")
	uassert.True(t, strings.Contains(page, "## Submissions (1)"))
	uassert.True(t, strings.Contains(page, "[link](https://example.com/pr/1)"))
	uassert.True(t, strings.Contains(page, "func=Submit&id=1"))
	uassert.False(t, strings.Contains(page, "\n# not a heading")) // body cannot inject headings

	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	Award(cross(cur), id, bob.String())
	uassert.True(t, strings.Contains(Render(""), "Recently closed"))
	uassert.True(t, strings.Contains(Render("quest/1"), "**winner**"))

	prof := Render("u/" + alice.String())
	uassert.True(t, strings.Contains(prof, "Paid out: **1** quests, **1.25 GNOT**"))
	uassert.True(t, strings.Contains(Render("u/"+carol.String()), "No activity"))
	uassert.True(t, strings.Contains(Render("quest/42"), "Quest not found"))
	uassert.True(t, strings.Contains(Render("nope"), "404"))
}

func TestGnotFormat(t *testing.T) {
	uassert.Equal(t, "0 GNOT", gnot(0))
	uassert.Equal(t, "1 GNOT", gnot(1_000_000))
	uassert.Equal(t, "0.1 GNOT", gnot(100_000))
	uassert.Equal(t, "2.000001 GNOT", gnot(2_000_001))
}
