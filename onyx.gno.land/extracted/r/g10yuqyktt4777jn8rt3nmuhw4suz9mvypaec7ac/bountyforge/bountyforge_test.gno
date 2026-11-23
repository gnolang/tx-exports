package bountyforge

import (
	"chain"
	"chain/banker"
	"strings"
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

var (
	realmAddr = chain.PackageAddress("gno.land/r/g10yuqyktt4777jn8rt3nmuhw4suz9mvypaec7ac/bountyforge")
	creator   = testutils.TestAddress("creator")
	sponsor   = testutils.TestAddress("sponsor")
	alice     = testutils.TestAddress("alice")
	bob       = testutils.TestAddress("bob")
	arbiter   = testutils.TestAddress("arbiter")
)

func depositToEscrow(ugnot int64) {
	coins := chain.Coins{chain.NewCoin("ugnot", ugnot)}
	testing.IssueCoins(realmAddr, coins)
	testing.SetOriginSend(coins)
}

func TestFullLifecycleApproveAndReputation(cur realm, t *testing.T) {
	resetState()

	// Creator funds a 5 GNOT bounty.
	depositToEscrow(5_000_000)
	testing.SetRealm(testing.NewUserRealm(creator))
	id := CreateBounty(
		cross(cur),
		"Build Gno Indexer",
		"Deliver deterministic ABCI indexer with unit tests",
		"gno,indexer",
		arbiter.String(),
		100,
	)
	uassert.Equal(t, uint64(1), id)
	uassert.Equal(t, int64(5_000_000), TotalEscrowed())

	// Sponsor tops up with +1.5 GNOT.
	depositToEscrow(1_500_000)
	testing.SetRealm(testing.NewUserRealm(sponsor))
	newTotal := TopUpBounty(cross(cur), id)
	uassert.Equal(t, int64(6_500_000), newTotal)
	uassert.Equal(t, int64(6_500_000), TotalEscrowed())

	// Alice submits work, then updates her proof URL cleanly without duplicating.
	testing.SetOriginSend(nil)
	testing.SetRealm(testing.NewUserRealm(alice))
	idx1 := SubmitWork(cross(cur), id, "https://github.com/LHorTL/bountyforge/pull/1", "Draft")
	idx2 := SubmitWork(cross(cur), id, "https://github.com/LHorTL/bountyforge/pull/2", "All tests passing")
	uassert.Equal(t, 0, idx1)
	uassert.Equal(t, 0, idx2)

	// Creator approves and pays Alice 100% of 6.5 GNOT.
	b := banker.NewReadonlyBanker()
	beforeAlice := b.GetCoin(alice, "ugnot")

	testing.SetRealm(testing.NewUserRealm(creator))
	ApproveAndPay(cross(cur), id, 0)

	afterAlice := b.GetCoin(alice, "ugnot")
	uassert.Equal(t, int64(6_500_000), afterAlice-beforeAlice)
	uassert.Equal(t, int64(0), TotalEscrowed())
	uassert.Equal(t, int64(6_500_000), TotalPaidOut())
	uassert.True(t, BuilderXP(alice) > 100, "alice should earn XP")

	// Verify gnoweb routes render cleanly.
	home := Render("")
	uassert.True(t, strings.Contains(home, "Build Gno Indexer"), "home should list bounty")
	detail := Render("bounty/1")
	uassert.True(t, strings.Contains(detail, "6.5 GNOT"), "detail should show reward")
	uassert.True(t, strings.Contains(detail, "On-Chain Settlement"), "detail should show settlement")
	lb := Render("leaderboard")
	uassert.True(t, strings.Contains(lb, alice.String()), "leaderboard should include alice")
	prof := Render("builder/" + alice.String())
	uassert.True(t, strings.Contains(prof, "Apprentice"), "profile should show tier")
	stats := Render("stats")
	uassert.True(t, strings.Contains(stats, "Cumulative Paid Out"), "stats should render")
}

func TestSplitAndPayZeroDustConservation(cur realm, t *testing.T) {
	resetState()

	// Odd ugnot amount that does not divide evenly into 6667 / 3333 bps.
	depositToEscrow(1_000_003)
	testing.SetRealm(testing.NewUserRealm(creator))
	id := CreateBounty(cross(cur), "Co-Authored Package", "Split across two builders", "gno,split", "", 0)

	testing.SetOriginSend(nil)
	testing.SetRealm(testing.NewUserRealm(alice))
	SubmitWork(cross(cur), id, "https://example.com/alice", "Core module")
	testing.SetRealm(testing.NewUserRealm(bob))
	SubmitWork(cross(cur), id, "https://example.com/bob", "Test suite")

	b := banker.NewReadonlyBanker()
	aBefore := b.GetCoin(alice, "ugnot")
	bBefore := b.GetCoin(bob, "ugnot")

	testing.SetRealm(testing.NewUserRealm(creator))
	SplitAndPay(cross(cur), id, "0,1", "6667,3333")

	aGot := b.GetCoin(alice, "ugnot") - aBefore
	bGot := b.GetCoin(bob, "ugnot") - bBefore
	uassert.Equal(t, int64(1_000_003), aGot+bGot)
	uassert.True(t, aGot > bGot, "alice gets majority + dust")
	uassert.Equal(t, int64(0), TotalEscrowed())
	uassert.True(t, BuilderXP(alice) > 0 && BuilderXP(bob) > 0, "both builders earn XP")
}

func TestDisputeAndArbiterResolution(cur realm, t *testing.T) {
	resetState()

	depositToEscrow(2_000_000)
	testing.SetRealm(testing.NewUserRealm(creator))
	id := CreateBounty(cross(cur), "Audit Realm", "Review escrow math", "security", arbiter.String(), 50)

	testing.SetOriginSend(nil)
	testing.SetRealm(testing.NewUserRealm(alice))
	SubmitWork(cross(cur), id, "https://example.com/audit", "Found 3 edge cases")

	// Alice opens dispute because creator stalled.
	OpenDispute(cross(cur), id, "Deliverable complete, awaiting release")

	b := banker.NewReadonlyBanker()
	aBefore := b.GetCoin(alice, "ugnot")
	cBefore := b.GetCoin(creator, "ugnot")

	// Arbiter awards 75% to Alice, 25% refund to creator.
	testing.SetRealm(testing.NewUserRealm(arbiter))
	ResolveDispute(cross(cur), id, 0, 7500)

	uassert.Equal(t, int64(1_500_000), b.GetCoin(alice, "ugnot")-aBefore)
	uassert.Equal(t, int64(500_000), b.GetCoin(creator, "ugnot")-cBefore)
	uassert.Equal(t, int64(0), TotalEscrowed())
}

func TestCancelAndRefundRules(cur realm, t *testing.T) {
	resetState()

	depositToEscrow(3_000_000)
	testing.SetRealm(testing.NewUserRealm(creator))
	id := CreateBounty(cross(cur), "Unused Quest", "Can be cancelled with zero submissions", "misc", "", 10)

	b := banker.NewReadonlyBanker()
	cBefore := b.GetCoin(creator, "ugnot")

	testing.SetOriginSend(nil)
	testing.SetRealm(testing.NewUserRealm(creator))
	CancelAndRefund(cross(cur), id)

	uassert.Equal(t, int64(3_000_000), b.GetCoin(creator, "ugnot")-cBefore)
	uassert.Equal(t, int64(0), TotalEscrowed())
}

func TestSecurityGuardsPanicOnUnauthorizedCalls(cur realm, t *testing.T) {
	resetState()

	depositToEscrow(1_000_000)
	testing.SetRealm(testing.NewUserRealm(creator))
	id := CreateBounty(cross(cur), "Guarded Quest", "Check authorization panics", "sec", arbiter.String(), 100)

	// Creator cannot submit to own bounty.
	testing.SetOriginSend(nil)
	testing.SetRealm(testing.NewUserRealm(creator))
	uassert.AbortsWithMessage(t, cur, "bountyforge: bounty creator cannot submit work to their own bounty", func() {
		SubmitWork(cross(cur), id, "https://example.com/self", "nope")
	})

	testing.SetRealm(testing.NewUserRealm(alice))
	SubmitWork(cross(cur), id, "https://example.com/alice", "valid")

	// Non-creator cannot approve payout.
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsWithMessage(t, cur, "bountyforge: only the bounty creator can approve payout", func() {
		ApproveAndPay(cross(cur), id, 0)
	})

	// Creator cannot cancel while submissions exist before deadline.
	testing.SetRealm(testing.NewUserRealm(creator))
	uassert.AbortsWithMessage(t, cur, "bountyforge: cannot cancel while submissions exist before deadline", func() {
		CancelAndRefund(cross(cur), id)
	})

	// Non-arbiter cannot resolve dispute.
	testing.SetRealm(testing.NewUserRealm(alice))
	OpenDispute(cross(cur), id, "dispute test")
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsWithMessage(t, cur, "bountyforge: only the designated arbiter can resolve disputes", func() {
		ResolveDispute(cross(cur), id, 0, 5000)
	})
}
