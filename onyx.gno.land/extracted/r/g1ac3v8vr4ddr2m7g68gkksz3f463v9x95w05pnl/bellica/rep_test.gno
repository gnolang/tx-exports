package bellica

import (
	"strings"
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

const longText = "The creator rejected a delivery that matched the brief exactly"

// finishedJob: a direct job delivered and closed by approve (or left for release).
func finishedJob(cur realm, gv, ag address, approve bool) int {
	id := postJob(cur, gv, 2_000_000, "direct", ag.String(), "", 0, "", 0)
	testing.SetRealm(testing.NewUserRealm(ag))
	Accept(cross(cur), id)
	deliver(cur, ag, id)
	if approve {
		testing.SetRealm(testing.NewUserRealm(gv))
		Approve(cross(cur), id)
	}
	return id
}

func TestRateRules(cur realm, t *testing.T) {
	gv, ag, outsider := testutils.TestAddress("rt-giver"), testutils.TestAddress("rt-agent"), testutils.TestAddress("rt-x")
	id := postJob(cur, gv, 2_000_000, "direct", ag.String(), "", 0, "", 0)
	testing.SetRealm(testing.NewUserRealm(gv))
	uassert.AbortsWithMessage(t, cur, "only finished jobs can be rated or reported", func() { Rate(cross(cur), "job", id, ag.String(), 5, "") })
	testing.SetRealm(testing.NewUserRealm(ag))
	Accept(cross(cur), id)
	deliver(cur, ag, id)
	testing.SetRealm(testing.NewUserRealm(gv))
	Approve(cross(cur), id)

	testing.SetRealm(testing.NewUserRealm(outsider))
	uassert.AbortsWithMessage(t, cur, "only counterparties of this item can rate or report each other", func() { Rate(cross(cur), "job", id, ag.String(), 1, "") })
	testing.SetRealm(testing.NewUserRealm(gv))
	uassert.AbortsWithMessage(t, cur, "you cannot rate or report yourself", func() { Rate(cross(cur), "job", id, gv.String(), 5, "") })
	uassert.AbortsWithMessage(t, cur, "score must be 1-5", func() { Rate(cross(cur), "job", id, ag.String(), 6, "") })
	uassert.AbortsWithMessage(t, cur, "kind must be job or bounty", func() { Rate(cross(cur), "gig", id, ag.String(), 5, "") })
	uassert.AbortsWithMessage(t, cur, "comment must be a single line", func() { Rate(cross(cur), "job", id, ag.String(), 5, "a\nb") })
	Rate(cross(cur), "job", id, ag.String(), 5, "great **work** <b>")
	uassert.AbortsWithMessage(t, cur, "you already rated this counterparty for this item", func() { Rate(cross(cur), "job", id, ag.String(), 1, "") })
	testing.SetRealm(testing.NewUserRealm(ag))
	Rate(cross(cur), "job", id, gv.String(), 4, "paid fast")
	uassert.Equal(t, 1, repOf(ag).AgentRatingN)
	uassert.Equal(t, 5, repOf(ag).AgentRatingSum)
	uassert.Equal(t, 4, repOf(gv).GiverRatingSum)
	p := Render("profile/" + ag.String())
	uassert.True(t, strings.Contains(p, "great \\*\\*work\\*\\* \\<b\\>"), p)
	uassert.True(t, strings.Contains(Render("json/profile/"+gv.String()), `"rating_x10":40`))
}

func TestReportRules(cur realm, t *testing.T) {
	gv, ag, outsider := testutils.TestAddress("rp-giver"), testutils.TestAddress("rp-agent"), testutils.TestAddress("rp-x")
	id := finishedJob(cur, gv, ag, false)
	minutes(31)
	testing.SetRealm(testing.NewUserRealm(outsider))
	Release(cross(cur), id) // creator went silent

	testing.SetRealm(testing.NewUserRealm(ag))
	ev := "https://example.com/chat.png"
	uassert.AbortsWithMessage(t, cur, "reason must be one of non_payment_attempt, unfair_reject, unfair_dq, spam, plagiarism, other", func() {
		Report(cross(cur), "job", id, gv.String(), "rude", longText, ev)
	})
	uassert.AbortsWithMessage(t, cur, "text must be 30-500 characters", func() { Report(cross(cur), "job", id, gv.String(), "other", "too short", ev) })
	uassert.AbortsWithMessage(t, cur, "text must be 30-500 characters", func() { Report(cross(cur), "job", id, gv.String(), "other", "                                   ", ev) })
	uassert.AbortsWithMessage(t, cur, "text must explain what happened (not repeated characters)", func() {
		Report(cross(cur), "job", id, gv.String(), "other", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "")
	})
	uassert.AbortsWithMessage(t, cur, "text must explain what happened (not repeated characters)", func() {
		Report(cross(cur), "job", id, gv.String(), "other", "abababababababababababababababab", "")
	})
	uassert.AbortsWithMessage(t, cur, "an evidence link (https or ipfs) is required for unfair_reject", func() {
		Report(cross(cur), "job", id, gv.String(), "unfair_reject", longText, "")
	})
	uassert.AbortsWithMessage(t, cur, "evidence must start with https:// or ipfs://", func() {
		Report(cross(cur), "job", id, gv.String(), "unfair_reject", longText, "javascript:alert1//x")
	})
	testing.SetRealm(testing.NewUserRealm(outsider))
	uassert.AbortsWithMessage(t, cur, "only counterparties of this item can rate or report each other", func() {
		Report(cross(cur), "job", id, gv.String(), "spam", longText, "")
	})
	testing.SetRealm(testing.NewUserRealm(ag))
	rid := Report(cross(cur), "job", id, gv.String(), "non_payment_attempt", longText, ev)
	uassert.AbortsWithMessage(t, cur, "you already reported this counterparty for this item", func() {
		Report(cross(cur), "job", id, gv.String(), "other", longText, ev)
	})
	r := reports.Get(key(rid)).(*ReportRec)
	uassert.True(t, r.Upheld) // creator silence is an on-chain fact
	uassert.True(t, strings.Contains(r.Facts, "auto-release"), r.Facts)
	uassert.Equal(t, 1, repOf(gv).UpheldAgainst)

	// response: only the reported party, once
	uassert.AbortsWithMessage(t, cur, "only the reported party can respond", func() { Respond(cross(cur), rid, "I was on holiday that whole week, sorry") })
	testing.SetRealm(testing.NewUserRealm(gv))
	Respond(cross(cur), rid, "I was on holiday that whole week, sorry")
	uassert.AbortsWithMessage(t, cur, "already responded", func() { Respond(cross(cur), rid, "I was on holiday that whole week, sorry") })
	page := Render("report/" + itoa(rid))
	uassert.True(t, strings.Contains(page, "On-chain facts"), page)
	uassert.True(t, strings.Contains(page, "Upheld"), page)
	uassert.True(t, strings.Contains(Render("job/"+itoa(id)), "Reports on this job"))

	// a report without confirming facts is shown but not upheld
	id2 := finishedJob(cur, gv, ag, true)
	testing.SetRealm(testing.NewUserRealm(ag))
	rid2 := Report(cross(cur), "job", id2, gv.String(), "spam", "The creator keeps sending me unrelated offers", "")
	uassert.False(t, reports.Get(key(rid2)).(*ReportRec).Upheld)
	uassert.Equal(t, 1, repOf(gv).UpheldAgainst)
	uassert.Equal(t, 2, repOf(gv).ReportsAgainst)
}

func TestBountyReputationDQAllAndBoards(cur realm, t *testing.T) {
	host, e1, e2 := testutils.TestAddress("rb-host"), testutils.TestAddress("rb-e1"), testutils.TestAddress("rb-e2")
	register(cur, e1, "rb-e1")
	register(cur, e2, "rb-e2")
	testing.IssueCoins(pkgAddr, coins(3_000_000))
	testing.SetRealm(testing.NewUserRealm(host))
	testing.SetOriginSend(coins(3_000_000))
	id := CreateBounty(cross(cur), "Poster for the tavern", "", "judge score 0-100", true, "100", 60, 60, "", "design", 0)
	testing.SetOriginSend(nil)
	testing.SetRealm(testing.NewUserRealm(e1))
	SubmitWork(cross(cur), id, "image", "ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi", "", "", "", 80)
	testing.SetRealm(testing.NewUserRealm(e2))
	SubmitWork(cross(cur), id, "image", "https://example.com/p.png", "", "", "", 70)
	minutes(61)
	testing.SetRealm(testing.NewUserRealm(host))
	Disqualify(cross(cur), id, e1.String(), "not original")
	Disqualify(cross(cur), id, e2.String(), "not original")
	Finalize(cross(cur), id)
	uassert.True(t, mustBounty(id).DQAll)
	uassert.Equal(t, 1, repOf(host).DQAll)
	testing.SetRealm(testing.NewUserRealm(e1))
	rid := Report(cross(cur), "bounty", id, host.String(), "unfair_dq", "My poster is original, here are the source files", "https://example.com/psd")
	uassert.True(t, reports.Get(key(rid)).(*ReportRec).Upheld)
	Rate(cross(cur), "bounty", id, host.String(), 1, "disqualified everyone")
	uassert.True(t, strings.Contains(Render("bounty/"+itoa(id)), "Rejected everyone"))
	uassert.True(t, strings.Contains(Render("bounty/"+itoa(id)), "judge-scored"))

	// a fair host climbs the givers board, its winner the agents board
	host2 := testutils.TestAddress("rb-host2")
	testing.IssueCoins(pkgAddr, coins(5_000_000))
	testing.SetRealm(testing.NewUserRealm(host2))
	testing.SetOriginSend(coins(5_000_000))
	id2 := CreateBounty(cross(cur), "Fast CSV parser", "", "ms", false, "100", 60, 60, "", "code", 0)
	testing.SetOriginSend(nil)
	testing.SetRealm(testing.NewUserRealm(e2))
	Submit(cross(cur), id2, "https://github.com/e2/csv", "abcd123", "", 40)
	minutes(61)
	testing.SetRealm(testing.NewUserRealm(host2))
	AcceptClaimed(cross(cur), id2)
	Finalize(cross(cur), id2)
	Rate(cross(cur), "bounty", id2, e2.String(), 5, "")
	uassert.Equal(t, int64(5_000_000), repOf(host2).PaidOut)
	uassert.Equal(t, 1, repOf(e2).Wins)
	gb := Render("json/leaderboard/givers")
	uassert.True(t, strings.Contains(gb, host2.String()), gb)
	uassert.False(t, strings.Contains(gb, host.String()), gb) // paid nothing
	uassert.True(t, strings.Contains(Render("json/leaderboard/agents"), e2.String()))
	uassert.True(t, strings.Contains(Render("leaderboard/givers"), "Top givers"))
	// score formula: 5,000,000/1000 × 30 (unrated) × 100 / 5000 = 3000
	uassert.Equal(t, int64(3000), giverScore(repOf(host2)))
}
