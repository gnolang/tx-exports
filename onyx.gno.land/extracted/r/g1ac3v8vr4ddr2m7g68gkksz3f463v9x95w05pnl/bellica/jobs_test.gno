package bellica

import (
	"chain"
	"strings"
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

func postJob(cur realm, by address, pay int64, mode, agent, arbiter string, minTier int, splits string, fee int64) int {
	testing.IssueCoins(pkgAddr, coins(pay))
	testing.SetRealm(testing.NewUserRealm(by))
	testing.SetOriginSend(coins(pay))
	id := PostJob(cross(cur), "Logo for a tavern", "https://example.com/brief", "design", mode, 60, 30, agent, arbiter, minTier, splits, fee)
	testing.SetOriginSend(nil)
	return id
}



func apply(cur realm, a address, id int) {
	testing.SetRealm(testing.NewUserRealm(a))
	Apply(cross(cur), id, "I draw fast clean logos", "https://example.com/portfolio")
}

func deliver(cur realm, a address, id int) {
	testing.SetRealm(testing.NewUserRealm(a))
	Deliver(cross(cur), id, "image", "ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi/logo.png", "", "", "v1")
}

func TestJobDirectHappyPath(cur realm, t *testing.T) {
	gv, ag := testutils.TestAddress("jd-giver"), testutils.TestAddress("jd-agent")
	register(cur, ag, "jd-agent")
	id := postJob(cur, gv, 5_000_000, "", "", "", 0, "", 0)
	uassert.Equal(t, "open", JobPhase(id))
	apply(cur, ag, id)
	testing.SetRealm(testing.NewUserRealm(ag))
	uassert.AbortsWithMessage(t, cur, "only the job creator can do this", func() { Hire(cross(cur), id, ag.String()) })
	testing.SetRealm(testing.NewUserRealm(gv))
	uassert.AbortsWithMessage(t, cur, "that address has not applied", func() { Hire(cross(cur), id, alice.String()) })
	Hire(cross(cur), id, ag.String())
	uassert.Equal(t, "active", JobPhase(id))
	testing.SetRealm(testing.NewUserRealm(gv))
	uassert.AbortsWithMessage(t, cur, "only the hired agent can deliver an active job", func() {
		Deliver(cross(cur), id, "link", "https://example.com/x", "", "", "")
	})
	deliver(cur, ag, id)
	before := bal(cur, ag)
	testing.SetRealm(testing.NewUserRealm(gv))
	Approve(cross(cur), id)
	uassert.Equal(t, before+5_000_000, bal(cur, ag))
	uassert.Equal(t, "paid", JobPhase(id))
	uassert.AbortsWithMessage(t, cur, "nothing to approve", func() { Approve(cross(cur), id) })
	r := repOf(gv)
	uassert.Equal(t, 1, r.Posted)
	uassert.Equal(t, 1, r.Approved)
	uassert.Equal(t, 1, r.FastApprovals)
	uassert.Equal(t, int64(5_000_000), r.PaidOut)
	uassert.Equal(t, 1, repOf(ag).WorkApproved)
	uassert.Equal(t, 1, tierOf(ag)) // Gladiator after one approved job
	js := Render("json/job/" + itoa(id))
	uassert.True(t, strings.Contains(js, `"mode":"direct"`), js)
	uassert.True(t, strings.Contains(js, `"category":"design"`), js)
	uassert.True(t, strings.Contains(Render("json/jobs"), `"id":`+itoa(id)))
	page := Render("job/" + itoa(id))
	uassert.True(t, strings.Contains(page, "🎯 direct"), page)
	uassert.True(t, strings.Contains(page, "https://ipfs.io/ipfs/bafy"), page)
}

func TestJobNamedAgentSilentCreatorRelease(cur realm, t *testing.T) {
	gv, ag := testutils.TestAddress("jn-giver"), testutils.TestAddress("jn-agent")
	id := postJob(cur, gv, 2_000_000, "direct", ag.String(), "", 0, "", 0)
	uassert.Equal(t, "offered", JobPhase(id))
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsWithMessage(t, cur, "only the named agent can accept an offered job", func() { Accept(cross(cur), id) })
	testing.SetRealm(testing.NewUserRealm(ag))
	Accept(cross(cur), id)
	deliver(cur, ag, id)
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsWithMessage(t, cur, "nothing to release yet", func() { Release(cross(cur), id) })
	minutes(31)
	uassert.Equal(t, "releasable", JobPhase(id))
	testing.SetRealm(testing.NewUserRealm(gv))
	uassert.AbortsWithMessage(t, cur, "the review window is over; the agent can be paid with Release", func() { Reject(cross(cur), id, "too late to reject") })
	before := bal(cur, ag)
	testing.SetRealm(testing.NewUserRealm(bob)) // anyone
	Release(cross(cur), id)
	uassert.Equal(t, before+2_000_000, bal(cur, ag))
	uassert.Equal(t, 1, repOf(gv).AutoReleased)
	uassert.True(t, strings.Contains(strings.Join(giverBadges(repOf(gv)), ","), "Often silent"))
	uassert.AbortsWithMessage(t, cur, "nothing to release yet", func() { Release(cross(cur), id) })
}

func TestJobRejectRedoThenRefund(cur realm, t *testing.T) {
	gv, ag := testutils.TestAddress("jr-giver"), testutils.TestAddress("jr-agent")
	id := postJob(cur, gv, 3_000_000, "direct", ag.String(), "", 0, "", 0)
	testing.SetRealm(testing.NewUserRealm(ag))
	Accept(cross(cur), id)
	deliver(cur, ag, id)
	testing.SetRealm(testing.NewUserRealm(gv))
	uassert.AbortsWithMessage(t, cur, "reason must be 3-280 characters", func() { Reject(cross(cur), id, "") })
	Reject(cross(cur), id, "colours are off-brief")
	uassert.Equal(t, "active", JobPhase(id)) // one redo
	deliver(cur, ag, id)
	c0 := bal(cur, gv)
	testing.SetRealm(testing.NewUserRealm(gv))
	Reject(cross(cur), id, "still off-brief")
	uassert.Equal(t, "refunded", JobPhase(id))
	uassert.Equal(t, c0+3_000_000, bal(cur, gv))
	uassert.Equal(t, 2, repOf(gv).RejectsIssued)
	uassert.Equal(t, 2, repOf(ag).WorkRejected)
}

func TestJobArbiterResolveAndSilence(cur realm, t *testing.T) {
	gv, ag, arb := testutils.TestAddress("ja-giver"), testutils.TestAddress("ja-agent"), testutils.TestAddress("ja-arb")
	id := postJob(cur, gv, 10_000_000, "direct", ag.String(), arb.String(), 0, "", 0)
	testing.SetRealm(testing.NewUserRealm(ag))
	Accept(cross(cur), id)
	deliver(cur, ag, id)
	testing.SetRealm(testing.NewUserRealm(gv))
	Reject(cross(cur), id, "not what we asked")
	uassert.Equal(t, "disputed", JobPhase(id))
	testing.SetRealm(testing.NewUserRealm(gv))
	uassert.AbortsWithMessage(t, cur, "only the arbiter can resolve a disputed job", func() { Resolve(cross(cur), id, 0) })
	testing.SetRealm(testing.NewUserRealm(arb))
	uassert.AbortsWithMessage(t, cur, "agentPct must be 0-100", func() { Resolve(cross(cur), id, 101) })
	a0, c0 := bal(cur, ag), bal(cur, gv)
	Resolve(cross(cur), id, 70)
	uassert.Equal(t, a0+7_000_000, bal(cur, ag))
	uassert.Equal(t, c0+3_000_000, bal(cur, gv))
	uassert.Equal(t, "split", JobPhase(id))
	uassert.Equal(t, 1, repOf(gv).DisputesLost)
	uassert.True(t, strings.Contains(strings.Join(giverBadges(repOf(gv)), ","), "Disputed"))

	// arbiter silent → anyone releases 50/50
	id2 := postJob(cur, gv, 4_000_000, "direct", ag.String(), arb.String(), 0, "", 0)
	testing.SetRealm(testing.NewUserRealm(ag))
	Accept(cross(cur), id2)
	deliver(cur, ag, id2)
	testing.SetRealm(testing.NewUserRealm(gv))
	Reject(cross(cur), id2, "not what we asked")
	minutes(31)
	a0, c0 = bal(cur, ag), bal(cur, gv)
	testing.SetRealm(testing.NewUserRealm(carol))
	Release(cross(cur), id2)
	uassert.Equal(t, a0+2_000_000, bal(cur, ag))
	uassert.Equal(t, c0+2_000_000, bal(cur, gv))
}

func TestJobNoDeliveryRefundAndCancel(cur realm, t *testing.T) {
	gv, ag := testutils.TestAddress("jx-giver"), testutils.TestAddress("jx-agent")
	register(cur, ag, "jx-agent")
	id := postJob(cur, gv, 1_000_000, "", "", "", 0, "", 0)
	apply(cur, ag, id)
	testing.SetRealm(testing.NewUserRealm(gv))
	Hire(cross(cur), id, ag.String())
	uassert.AbortsWithMessage(t, cur, "cannot cancel: an agent is already working", func() { CancelJob(cross(cur), id) })
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsWithMessage(t, cur, "the deadline has not passed", func() { Refund(cross(cur), id) })
	minutes(61)
	testing.SetRealm(testing.NewUserRealm(ag))
	uassert.AbortsWithMessage(t, cur, "the job deadline has passed", func() {
		Deliver(cross(cur), id, "link", "https://example.com/late", "", "", "")
	})
	c0 := bal(cur, gv)
	testing.SetRealm(testing.NewUserRealm(bob))
	Refund(cross(cur), id)
	uassert.Equal(t, c0+1_000_000, bal(cur, gv))
	uassert.Equal(t, 1, repOf(ag).Missed)
	uassert.AbortsWithMessage(t, cur, "job cannot be refunded", func() { Refund(cross(cur), id) })

	// cancel before hiring
	id2 := postJob(cur, gv, 1_000_000, "", "", "", 0, "", 0)
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsWithMessage(t, cur, "only the job creator can do this", func() { CancelJob(cross(cur), id2) })
	c0 = bal(cur, gv)
	testing.SetRealm(testing.NewUserRealm(gv))
	CancelJob(cross(cur), id2)
	uassert.Equal(t, c0+1_000_000, bal(cur, gv))
	uassert.Equal(t, "cancelled", JobPhase(id2))
	uassert.AbortsWithMessage(t, cur, "cannot cancel: an agent is already working", func() { CancelJob(cross(cur), id2) })
}

func TestJobPostValidation(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(creator))
	mk := func(pay int64, mode, agent, arb string, minTier int, splits string, fee int64) func() {
		return func() {
			testing.SetOriginSend(coins(pay))
			PostJob(cross(cur), "Valid title", "", "code", mode, 60, 30, agent, arb, minTier, splits, fee)
		}
	}
	uassert.AbortsWithMessage(t, cur, "pay too small: send at least 1000000 ugnot", mk(10, "", "", "", 0, "", 0))
	uassert.AbortsWithMessage(t, cur, "mode must be direct or selection", mk(1_000_000, "auction", "", "", 0, "", 0))
	uassert.AbortsWithMessage(t, cur, "minTier must be 0-5 (0 = any)", mk(1_000_000, "", "", "", 6, "", 0))
	uassert.AbortsWithMessage(t, cur, "the arbiter must not be the creator", mk(1_000_000, "", "", creator.String(), 0, "", 0))
	uassert.AbortsWithMessage(t, cur, "the agent must not be the creator or the arbiter", mk(1_000_000, "", creator.String(), "", 0, "", 0))
	uassert.AbortsWithMessage(t, cur, "selection jobs take no named agent or arbiter", mk(1_000_000, "selection", alice.String(), "", 0, "", 0))
	uassert.AbortsWithMessage(t, cur, "splits and trialFee are for selection jobs", mk(1_000_000, "direct", "", "", 0, "70,30", 0))
	uassert.AbortsWithMessage(t, cur, "trialFee must be 0-125000 ugnot (all fees at most half the pay)", mk(1_000_000, "selection", "", "", 0, "100", 200_000))
	uassert.AbortsWithMessage(t, cur, "at most 5 winners", mk(1_000_000, "selection", "", "", 0, "30,20,20,10,10,10", 0))
	uassert.AbortsWithMessage(t, cur, "unknown category: use one of code, design, image, video, audio, writing, data, research, other", func() {
		testing.SetOriginSend(coins(1_000_000))
		PostJob(cross(cur), "Valid title", "", "crypto", "", 60, 30, "", "", 0, "", 0)
	})
	testing.SetOriginSend(nil)
}

func TestJobSelectionPickSplitAndTrialFee(cur realm, t *testing.T) {
	gv := testutils.TestAddress("js-giver")
	var ags []address
	for _, n := range []string{"js-a", "js-b", "js-c", "js-d", "js-e", "js-f"} {
		a := testutils.TestAddress(n)
		register(cur, a, n)
		ags = append(ags, a)
	}
	id := postJob(cur, gv, 10_000_000, "selection", "", "", 0, "70,30", 200_000)
	for _, a := range ags {
		apply(cur, a, id)
	}
	testing.SetRealm(testing.NewUserRealm(gv))
	for _, a := range ags[:5] {
		Shortlist(cross(cur), id, a.String())
	}
	uassert.AbortsWithMessage(t, cur, "shortlist is full (5)", func() { Shortlist(cross(cur), id, ags[5].String()) })
	uassert.AbortsWithMessage(t, cur, "only a shortlisted agent can deliver a trial", func() { deliver(cur, ags[5], id) })
	testing.SetRealm(testing.NewUserRealm(gv))
	uassert.AbortsWithMessage(t, cur, "cannot cancel: an agent is already working", func() { CancelJob(cross(cur), id) })
	// a, b, c deliver; d and e do not
	for _, a := range ags[:3] {
		deliver(cur, a, id)
	}
	testing.SetRealm(testing.NewUserRealm(gv))
	uassert.AbortsWithMessage(t, cur, "trials are still running (wait for the deadline)", func() { Pick(cross(cur), id, ags[0].String()) })
	minutes(61)
	uassert.Equal(t, "picking", JobPhase(id))
	testing.SetRealm(testing.NewUserRealm(gv))
	uassert.AbortsWithMessage(t, cur, "winner must be a shortlisted agent who delivered on time: "+ags[3].String(), func() { Pick(cross(cur), id, ags[3].String()) })
	uassert.AbortsWithMessage(t, cur, "duplicate winner", func() { Pick(cross(cur), id, ags[0].String()+","+ags[0].String()) })
	uassert.AbortsWithMessage(t, cur, "pick 1-2 winners", func() { Pick(cross(cur), id, ags[0].String()+","+ags[1].String()+","+ags[2].String()) })
	b := []int64{bal(cur, ags[0]), bal(cur, ags[1]), bal(cur, ags[2]), bal(cur, ags[3])}
	c0 := bal(cur, gv)
	Pick(cross(cur), id, ags[1].String()+","+ags[0].String())
	// fee for c (on time, not picked) = 0.2; 9.8 left → 70/30 = 6.86 / 2.94
	uassert.Equal(t, b[1]+6_860_000, bal(cur, ags[1]))
	uassert.Equal(t, b[0]+2_940_000, bal(cur, ags[0]))
	uassert.Equal(t, b[2]+200_000, bal(cur, ags[2]))
	uassert.Equal(t, b[3], bal(cur, ags[3]))
	uassert.Equal(t, c0, bal(cur, gv))
	uassert.Equal(t, "paid", JobPhase(id))
	uassert.AbortsWithMessage(t, cur, "not a selection job awaiting a pick", func() { Pick(cross(cur), id, ags[0].String()) })
	page := Render("job/" + itoa(id))
	uassert.True(t, strings.Contains(page, "Compare trials (5 shortlisted)"), page)
	uassert.True(t, strings.Contains(Render("json/jobs/"+itoa(id)), `"mode":"selection"`))
}

func TestJobSelectionSilenceAutoSplit(cur realm, t *testing.T) {
	gv, a1, a2 := testutils.TestAddress("jq-giver"), testutils.TestAddress("jq-a"), testutils.TestAddress("jq-b")
	register(cur, a1, "jq-a")
	register(cur, a2, "jq-b")
	id := postJob(cur, gv, 4_000_001, "selection", "", "", 0, "100", 0)
	apply(cur, a1, id)
	apply(cur, a2, id)
	testing.SetRealm(testing.NewUserRealm(gv))
	Shortlist(cross(cur), id, a1.String())
	Shortlist(cross(cur), id, a2.String())
	deliver(cur, a1, id)
	deliver(cur, a2, id)
	minutes(61 + 31)
	uassert.Equal(t, "releasable", JobPhase(id))
	testing.SetRealm(testing.NewUserRealm(gv))
	uassert.AbortsWithMessage(t, cur, "the review window is over; anyone can Release", func() { Pick(cross(cur), id, a1.String()) })
	b1, b2 := bal(cur, a1), bal(cur, a2)
	testing.SetRealm(testing.NewUserRealm(carol))
	Release(cross(cur), id)
	uassert.Equal(t, b1+2_000_001, bal(cur, a1)) // dust to the first
	uassert.Equal(t, b2+2_000_000, bal(cur, a2))
	uassert.Equal(t, 1, repOf(gv).AutoReleased)
}

func TestJobSelectionRejectAll(cur realm, t *testing.T) {
	gv, a1, a2 := testutils.TestAddress("jz-giver"), testutils.TestAddress("jz-a"), testutils.TestAddress("jz-b")
	register(cur, a1, "jz-a")
	register(cur, a2, "jz-b")
	id := postJob(cur, gv, 2_000_000, "selection", "", "", 0, "", 100_000)
	apply(cur, a1, id)
	apply(cur, a2, id)
	testing.SetRealm(testing.NewUserRealm(gv))
	Shortlist(cross(cur), id, a1.String())
	Shortlist(cross(cur), id, a2.String())
	deliver(cur, a1, id) // a2 never delivers
	minutes(61)
	b1, c0 := bal(cur, a1), bal(cur, gv)
	testing.SetRealm(testing.NewUserRealm(gv))
	RejectAll(cross(cur), id, "none of these fit our brand")
	uassert.Equal(t, b1+100_000, bal(cur, a1)) // trial fee, no free labour
	uassert.Equal(t, c0+1_900_000, bal(cur, gv))
	uassert.Equal(t, "split", JobPhase(id))
	uassert.Equal(t, 1, repOf(gv).DQAll)
	uassert.True(t, strings.Contains(strings.Join(giverBadges(repOf(gv)), ","), "Rejected everyone"))
	uassert.True(t, strings.Contains(Render("job/"+itoa(id)), "rejected every trial"))
}

func TestJobSwitchToSelection(cur realm, t *testing.T) {
	gv, ag := testutils.TestAddress("jw-giver"), testutils.TestAddress("jw-agent")
	register(cur, ag, "jw-agent")
	id := postJob(cur, gv, 2_000_000, "direct", "", "", 0, "", 0)
	testing.SetRealm(testing.NewUserRealm(gv))
	uassert.AbortsWithMessage(t, cur, "job is not open for shortlisting", func() { Shortlist(cross(cur), id, ag.String()) })
	SwitchToSelection(cross(cur), id, "100", 0)
	uassert.True(t, strings.Contains(Render("json/job/"+itoa(id)), `"mode":"selection"`))
	uassert.AbortsWithMessage(t, cur, "job is not open for hiring", func() { Hire(cross(cur), id, ag.String()) })
	uassert.AbortsWithMessage(t, cur, "only an open direct job with nobody hired can switch to selection", func() { SwitchToSelection(cross(cur), id, "100", 0) })

	id2 := postJob(cur, gv, 2_000_000, "direct", "", "", 0, "", 0)
	apply(cur, ag, id2)
	testing.SetRealm(testing.NewUserRealm(gv))
	Hire(cross(cur), id2, ag.String())
	uassert.AbortsWithMessage(t, cur, "only an open direct job with nobody hired can switch to selection", func() { SwitchToSelection(cross(cur), id2, "100", 0) })
	testing.SetRealm(testing.NewUserRealm(ag))
	uassert.AbortsWithMessage(t, cur, "only the job creator can do this", func() { SwitchToSelection(cross(cur), id2, "100", 0) })
}

func TestMinTierGating(cur realm, t *testing.T) {
	gv, rookie, vet := testutils.TestAddress("mt-giver"), testutils.TestAddress("mt-rookie"), testutils.TestAddress("mt-vet")
	register(cur, rookie, "mt-rookie")
	register(cur, vet, "mt-vet")
	// vet earns Gladiator with one approved job
	id0 := postJob(cur, gv, 1_000_000, "direct", vet.String(), "", 0, "", 0)
	testing.SetRealm(testing.NewUserRealm(vet))
	Accept(cross(cur), id0)
	deliver(cur, vet, id0)
	testing.SetRealm(testing.NewUserRealm(gv))
	Approve(cross(cur), id0)
	uassert.Equal(t, 1, tierOf(vet))
	uassert.Equal(t, 0, tierOf(rookie))

	id := postJob(cur, gv, 1_000_000, "direct", "", "", 1, "", 0)
	testing.SetRealm(testing.NewUserRealm(rookie))
	uassert.AbortsWithMessage(t, cur, "this requires tier Gladiator or higher; yours is Tiro", func() {
		Apply(cross(cur), id, "let me try please", "")
	})
	apply(cur, vet, id) // ok
	// H9: a tier drop after applying is re-checked at Hire
	repChange(vet, func(r *Rep) { r.Missed += 2 })
	uassert.Equal(t, 0, tierOf(vet))
	testing.SetRealm(testing.NewUserRealm(gv))
	uassert.AbortsWithMessage(t, cur, "this requires tier Gladiator or higher; yours is Tiro", func() { Hire(cross(cur), id, vet.String()) })
	repChange(vet, func(r *Rep) { r.Missed -= 2 })
	// named agent below the tier cannot accept
	id2 := postJob(cur, gv, 1_000_000, "direct", rookie.String(), "", 1, "", 0)
	testing.SetRealm(testing.NewUserRealm(rookie))
	uassert.AbortsWithMessage(t, cur, "this requires tier Gladiator or higher; yours is Tiro", func() { Accept(cross(cur), id2) })
	// bounty gating
	testing.IssueCoins(pkgAddr, coins(1_000_000))
	testing.SetRealm(testing.NewUserRealm(gv))
	testing.SetOriginSend(coins(1_000_000))
	bid := CreateBounty(cross(cur), "Gated contest", "", "ms", false, "100", 60, 60, "", "code", 1)
	testing.SetOriginSend(nil)
	testing.SetRealm(testing.NewUserRealm(rookie))
	uassert.AbortsWithMessage(t, cur, "this requires tier Gladiator or higher; yours is Tiro", func() {
		Submit(cross(cur), bid, "https://github.com/r/x", "abcd123", "", 5)
	})
	testing.SetRealm(testing.NewUserRealm(vet))
	Submit(cross(cur), bid, "https://github.com/v/x", "abcd123", "", 5)
}

func TestTierTableAndDemotion(cur realm, t *testing.T) {
	g := func(r *Rep) int { return agentTier(r) }
	uassert.Equal(t, 0, g(&Rep{}))
	uassert.Equal(t, 1, g(&Rep{WorkApproved: 1}))
	uassert.Equal(t, 1, g(&Rep{Podiums: 3, Earned: 4_999_999}))           // earned too low for Veteran
	uassert.Equal(t, 2, g(&Rep{WorkApproved: 2, Podiums: 1, Earned: 5_000_000})) // Veteran, unrated ok
	uassert.Equal(t, 1, g(&Rep{WorkApproved: 3, Earned: 5_000_000, AgentRatingSum: 6, AgentRatingN: 2}))
	uassert.Equal(t, 2, g(&Rep{WorkApproved: 10, Earned: 25_000_000})) // Centurion needs 3 ratings
	uassert.Equal(t, 3, g(&Rep{WorkApproved: 10, Earned: 25_000_000, AgentRatingSum: 12, AgentRatingN: 3}))
	uassert.Equal(t, 5, g(&Rep{WorkApproved: 50, Earned: 500_000_000, AgentRatingSum: 125, AgentRatingN: 25}))
	// demotion: one tier per 2 strikes (upheld reports + missed deadlines)
	uassert.Equal(t, 4, g(&Rep{WorkApproved: 50, Earned: 500_000_000, AgentRatingSum: 125, AgentRatingN: 25, Missed: 1, UpheldAgainst: 1}))
	uassert.Equal(t, 0, g(&Rep{WorkApproved: 1, Missed: 2}))
	uassert.Equal(t, "👑 Rudiarius", tierLabel(5))
	uassert.Equal(t, 1, patronLevel(&Rep{PaidItems: 1, PaidOut: 1}))
	uassert.Equal(t, 2, patronLevel(&Rep{PaidItems: 5, PaidOut: 10_000_000}))
	uassert.Equal(t, 1, patronLevel(&Rep{PaidItems: 5, PaidOut: 10_000_000, AutoReleased: 2}))
	uassert.Equal(t, 3, patronLevel(&Rep{PaidItems: 20, PaidOut: 100_000_000, GiverRatingSum: 20, GiverRatingN: 5}))
}

func TestJobsKeepEscrowInvariant(cur realm, t *testing.T) {
	// bank state is per test in the runner, realm globals persist: check the
	// accounting identity escrowed == sum of unclosed bounties + jobs instead.
	open := int64(0)
	openJobs.Iterate("", "", func(_ string, v any) bool {
		open += v.(*Job).Pay
		return false
	})
	openBounties.Iterate("", "", func(_ string, v any) bool {
		open += v.(*Bounty).Pot
		return false
	})
	uassert.Equal(t, open, escrowed)
	_ = chain.Coins{}
}

func TestSelectionNoTrialsRefundNoLockedFunds(cur realm, t *testing.T) {
	gv, a1 := testutils.TestAddress("jn2-giver"), testutils.TestAddress("jn2-a")
	register(cur, a1, "jn2-a")
	id := postJob(cur, gv, 1_000_000, "selection", "", "", 0, "100", 0)
	apply(cur, a1, id)
	testing.SetRealm(testing.NewUserRealm(gv))
	Shortlist(cross(cur), id, a1.String())
	minutes(61 + 31)
	uassert.Equal(t, "expired", JobPhase(id))
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsWithMessage(t, cur, "nothing to release yet", func() { Release(cross(cur), id) })
	c0 := bal(cur, gv)
	Refund(cross(cur), id)
	uassert.Equal(t, c0+1_000_000, bal(cur, gv))
	uassert.Equal(t, 1, repOf(a1).Missed)
	uassert.AbortsWithMessage(t, cur, "job cannot be refunded", func() { Refund(cross(cur), id) })
	testing.SetRealm(testing.NewUserRealm(a1))
	uassert.AbortsWithMessage(t, cur, "only a shortlisted agent can deliver a trial", func() { deliver(cur, a1, id) })
}
