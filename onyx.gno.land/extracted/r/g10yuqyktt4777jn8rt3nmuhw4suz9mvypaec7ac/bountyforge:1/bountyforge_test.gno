package bountyforge

import (
	"chain"
	"chain/banker"
	"math"
	"strconv"
	"strings"
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

var (
	realmAddr = chain.PackageAddress("gno.land/r/g10yuqyktt4777jn8rt3nmuhw4suz9mvypaec7ac/bountyforge")
	creator   = testutils.TestAddress("creator")
	sponsor   = testutils.TestAddress("sponsor")
	sponsor2  = testutils.TestAddress("sponsor2")
	alice     = testutils.TestAddress("alice")
	bob       = testutils.TestAddress("bob")
	carol     = testutils.TestAddress("carol")
	arbiter   = testutils.TestAddress("arbiter")
)

func depositToEscrow(ugnot int64) {
	coins := chain.Coins{chain.NewCoin("ugnot", ugnot)}
	testing.IssueCoins(realmAddr, coins)
	testing.SetOriginSend(coins)
}

type fakeBanker struct{}

func (fakeBanker) GetCoins(address) chain.Coins            { return nil }
func (fakeBanker) GetCoin(address, string) int64           { return 1_000_000_000 }
func (fakeBanker) SendCoins(address, address, chain.Coins) {}
func (fakeBanker) TotalCoin(string) int64                  { return 0 }
func (fakeBanker) IssueCoin(address, string, int64)        {}
func (fakeBanker) RemoveCoin(address, string, int64)       {}

func Test01_FullLifecycleApproveAndReputation(cur realm, t *testing.T) {
	resetState()

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

	b := banker.NewReadonlyBanker()
	beforeAlice := b.GetCoin(alice, "ugnot")

	testing.SetRealm(testing.NewUserRealm(creator))
	ApproveAndPay(cross(cur), id, 0)

	afterAlice := b.GetCoin(alice, "ugnot")
	uassert.Equal(t, int64(6_500_000), afterAlice-beforeAlice)
	uassert.Equal(t, int64(0), TotalEscrowed())
	uassert.Equal(t, int64(6_500_000), TotalPaidOut())
	uassert.True(t, BuilderXP(alice) >= 100, "alice should earn Apprentice XP on 6.5 GNOT")

	// Verify all gnoweb routes render cleanly with valid /r/...: links (ZERO leading-colon links!).
	home := Render("")
	uassert.True(t, strings.Contains(home, "Build Gno Indexer"), "home should list bounty")
	uassert.True(t, strings.Contains(home, "<gno-columns>"), "home should use gno-columns KPIs")
	uassert.True(t, strings.Contains(home, "<gno-button "), "home should include gno-button CTAs")
	uassert.False(t, strings.Contains(home, "](:"), "must NEVER emit broken leading-colon links")

	detail := Render("bounty/1")
	uassert.True(t, strings.Contains(detail, "6.5 GNOT"), "detail should show reward")
	uassert.True(t, strings.Contains(detail, "On-Chain Settlement"), "detail should show settlement")
	uassert.True(t, strings.Contains(detail, "Crowdfund Escrow Ledger"), "detail should show sponsor ledger")
	uassert.False(t, strings.Contains(detail, "](:"), "detail must NEVER emit leading-colon links")

	lb := Render("leaderboard")
	uassert.True(t, strings.Contains(lb, alice.String()), "leaderboard should include alice")
	uassert.False(t, strings.Contains(lb, "](:"), "leaderboard must NEVER emit leading-colon links")

	prof := Render("builder/" + alice.String())
	uassert.True(t, strings.Contains(prof, "Apprentice"), "profile should show Apprentice tier")
	uassert.True(t, strings.Contains(prof, "data:image/svg+xml;base64,"), "profile should embed on-chain SVG badge")

	stats := Render("stats")
	uassert.True(t, strings.Contains(stats, "Cumulative Paid"), "stats should render")

	createForm := Render("new")
	uassert.True(t, strings.Contains(createForm, `<gno-form exec="CreateBounty">`), "new route should render gno-form")
}

func Test02_SplitAndPayZeroDustAndSVGChart(cur realm, t *testing.T) {
	resetState()

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

	detail := Render("bounty/1")
	uassert.True(t, strings.Contains(detail, "66.67%"), "pure integer FormatBPS")
	uassert.True(t, strings.Contains(detail, "data:image/svg+xml;base64,"), "multi-contributor split renders SVG chart")
}

func Test03_CriticalRegression_SplitWraparoundOverflowBlocked(cur realm, t *testing.T) {
	resetState()

	depositToEscrow(100_000_000)
	testing.SetRealm(testing.NewUserRealm(sponsor))
	CreateBounty(cross(cur), "Victim Treasury", "Protected escrow pool", "sec", "", 0)

	depositToEscrow(20_000)
	testing.SetRealm(testing.NewUserRealm(creator))
	attID := CreateBounty(cross(cur), "Tiny Bounty", "Attempt wraparound drain", "sec", "", 0)

	testing.SetOriginSend(nil)
	testing.SetRealm(testing.NewUserRealm(alice))
	SubmitWork(cross(cur), attID, "https://example.com/1", "s1")
	testing.SetRealm(testing.NewUserRealm(bob))
	SubmitWork(cross(cur), attID, "https://example.com/2", "s2")
	testing.SetRealm(testing.NewUserRealm(carol))
	SubmitWork(cross(cur), attID, "https://example.com/3", "s3")

	testing.SetRealm(testing.NewUserRealm(creator))
	wrapCSV := strconv.FormatInt(math.MaxInt64, 10) + "," + strconv.FormatInt(math.MaxInt64, 10) + ",10002"
	uassert.AbortsWithMessage(t, cur, "escrowmath: each weight must be in 1..10000", func() {
		SplitAndPay(cross(cur), attID, "0,1,2", wrapCSV)
	})
	uassert.Equal(t, int64(100_020_000), TotalEscrowed())
}

func Test04_CriticalRegression_SplitZeroShareRejected(cur realm, t *testing.T) {
	resetState()

	depositToEscrow(1_000)
	testing.SetRealm(testing.NewUserRealm(creator))
	id := CreateBounty(cross(cur), "Dust Split Test", "Reject zero-ugnot shares", "math", "", 0)

	testing.SetOriginSend(nil)
	testing.SetRealm(testing.NewUserRealm(alice))
	SubmitWork(cross(cur), id, "https://example.com/a", "a")
	testing.SetRealm(testing.NewUserRealm(bob))
	SubmitWork(cross(cur), id, "https://example.com/b", "b")

	testing.SetRealm(testing.NewUserRealm(creator))
	uassert.AbortsWithMessage(t, cur, "escrowmath: split weight produces a zero-ugnot share", func() {
		SplitAndPay(cross(cur), id, "0,1", "9999,1")
	})
	uassert.Equal(t, int64(0), BuilderXP(bob))
}

func Test05_CriticalRegression_CancelRefundsSponsorsNotCreator(cur realm, t *testing.T) {
	resetState()

	depositToEscrow(10_000)
	testing.SetRealm(testing.NewUserRealm(creator))
	id := CreateBounty(cross(cur), "Crowdfunded Quest", "No sponsor rug-pull allowed", "crowdfund", "", 100)

	depositToEscrow(5_000_000)
	testing.SetRealm(testing.NewUserRealm(sponsor))
	TopUpBounty(cross(cur), id)

	depositToEscrow(2_000_000)
	testing.SetRealm(testing.NewUserRealm(sponsor2))
	TopUpBounty(cross(cur), id)

	b := banker.NewReadonlyBanker()
	cBefore := b.GetCoin(creator, "ugnot")
	s1Before := b.GetCoin(sponsor, "ugnot")
	s2Before := b.GetCoin(sponsor2, "ugnot")

	testing.SetOriginSend(nil)
	testing.SetRealm(testing.NewUserRealm(creator))
	CancelAndRefund(cross(cur), id)

	uassert.Equal(t, int64(10_000), b.GetCoin(creator, "ugnot")-cBefore)
	uassert.Equal(t, int64(5_000_000), b.GetCoin(sponsor, "ugnot")-s1Before)
	uassert.Equal(t, int64(2_000_000), b.GetCoin(sponsor2, "ugnot")-s2Before)
	uassert.Equal(t, int64(0), TotalEscrowed())
}

func Test06_DisputeProRataSponsorRefundAndArbiterResolution(cur realm, t *testing.T) {
	resetState()

	depositToEscrow(4_000_000)
	testing.SetRealm(testing.NewUserRealm(creator))
	id := CreateBounty(cross(cur), "Audit Realm", "Review escrow math", "security", arbiter.String(), 50)

	depositToEscrow(2_000_000)
	testing.SetRealm(testing.NewUserRealm(sponsor))
	TopUpBounty(cross(cur), id)

	testing.SetOriginSend(nil)
	testing.SetRealm(testing.NewUserRealm(alice))
	SubmitWork(cross(cur), id, "https://example.com/audit", "Found critical issues")
	OpenDispute(cross(cur), id, "Deliverable complete, awaiting release")

	b := banker.NewReadonlyBanker()
	aBefore := b.GetCoin(alice, "ugnot")
	cBefore := b.GetCoin(creator, "ugnot")
	sBefore := b.GetCoin(sponsor, "ugnot")

	testing.SetRealm(testing.NewUserRealm(arbiter))
	ResolveDispute(cross(cur), id, 0, 5000)

	uassert.Equal(t, int64(3_000_000), b.GetCoin(alice, "ugnot")-aBefore)
	uassert.Equal(t, int64(2_000_000), b.GetCoin(creator, "ugnot")-cBefore)
	uassert.Equal(t, int64(1_000_000), b.GetCoin(sponsor, "ugnot")-sBefore)
	uassert.Equal(t, int64(0), TotalEscrowed())
	uassert.True(t, BuilderXP(alice) > 0, "50% dispute win awards XP")
}

func Test07_DisputeZeroAndMinorSettlementXP(cur realm, t *testing.T) {
	resetState()

	depositToEscrow(1_000_000)
	testing.SetRealm(testing.NewUserRealm(creator))
	id1 := CreateBounty(cross(cur), "Dispute Reject All", "Testing 0 bps", "sec", arbiter.String(), 100)
	testing.SetOriginSend(nil)
	testing.SetRealm(testing.NewUserRealm(alice))
	SubmitWork(cross(cur), id1, "https://example.com/spam", "junk")
	OpenDispute(cross(cur), id1, "spam dispute")

	b := banker.NewReadonlyBanker()
	cBefore := b.GetCoin(creator, "ugnot")
	testing.SetRealm(testing.NewUserRealm(arbiter))
	ResolveDispute(cross(cur), id1, -1, 0)
	uassert.Equal(t, int64(1_000_000), b.GetCoin(creator, "ugnot")-cBefore)

	depositToEscrow(2_000_000)
	testing.SetRealm(testing.NewUserRealm(creator))
	id2 := CreateBounty(cross(cur), "Minor Settlement", "Testing <25% win", "sec", arbiter.String(), 100)
	testing.SetOriginSend(nil)
	testing.SetRealm(testing.NewUserRealm(bob))
	SubmitWork(cross(cur), id2, "https://example.com/partial", "partial")
	OpenDispute(cross(cur), id2, "partial effort")

	bBefore := b.GetCoin(bob, "ugnot")
	testing.SetRealm(testing.NewUserRealm(arbiter))
	ResolveDispute(cross(cur), id2, 0, 1000)
	uassert.Equal(t, int64(200_000), b.GetCoin(bob, "ugnot")-bBefore)
	uassert.Equal(t, int64(0), BuilderXP(bob))
}

func Test08_DisputeTimeoutEscapeHatchDeadArbiter(cur realm, t *testing.T) {
	resetState()

	depositToEscrow(3_000_000)
	testing.SetRealm(testing.NewUserRealm(creator))
	id := CreateBounty(cross(cur), "Dead Arbiter Test", "Verify escape hatch", "sec", arbiter.String(), 100)

	depositToEscrow(1_000_000)
	testing.SetRealm(testing.NewUserRealm(sponsor))
	TopUpBounty(cross(cur), id)

	testing.SetOriginSend(nil)
	testing.SetRealm(testing.NewUserRealm(alice))
	SubmitWork(cross(cur), id, "https://example.com/work", "done")
	OpenDispute(cross(cur), id, "stalled")

	testing.SetRealm(testing.NewUserRealm(sponsor))
	uassert.AbortsWithMessage(t, cur, "bountyforge: dispute has not timed out yet", func() {
		ExpireDispute(cross(cur), id)
	})

	testing.SkipHeights(DisputeTimeoutBlocks + 1)

	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsWithMessage(t, cur, "bountyforge: only a contributor or active submitter can expire a timed-out dispute", func() {
		ExpireDispute(cross(cur), id)
	})

	b := banker.NewReadonlyBanker()
	cBefore := b.GetCoin(creator, "ugnot")
	sBefore := b.GetCoin(sponsor, "ugnot")
	testing.SetRealm(testing.NewUserRealm(sponsor))
	ExpireDispute(cross(cur), id)

	uassert.Equal(t, int64(3_000_000), b.GetCoin(creator, "ugnot")-cBefore)
	uassert.Equal(t, int64(1_000_000), b.GetCoin(sponsor, "ugnot")-sBefore)
	uassert.Equal(t, int64(0), TotalEscrowed())
}

func Test09_CriticalRegression_DeadlineOverflowBlocked(cur realm, t *testing.T) {
	resetState()
	depositToEscrow(1_000_000)
	testing.SetRealm(testing.NewUserRealm(creator))
	uassert.AbortsWithMessage(t, cur, "bountyforge: int64 overflow in deadlineH", func(cur realm) {
		createBountyCore(cur, creator, 1_000_000, "Overflow Deadline", "Must abort", "sec", "", math.MaxInt64)
	})
}

func Test10_DeadlineAndReviewGraceWindowEnforced(cur realm, t *testing.T) {
	resetState()

	depositToEscrow(1_000_000)
	testing.SetRealm(testing.NewUserRealm(creator))
	id := CreateBounty(cross(cur), "Grace Window Test", "Verify deadline + review grace", "sec", "", 20)

	testing.SetOriginSend(nil)
	testing.SetRealm(testing.NewUserRealm(alice))
	SubmitWork(cross(cur), id, "https://example.com/pr", "submitted in time")

	testing.SkipHeights(21)

	// Late submission rejected after DeadlineH
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsWithMessage(t, cur, "bountyforge: submission deadline has passed", func() {
		SubmitWork(cross(cur), id, "https://example.com/late", "too late")
	})

	// Creator cannot cancel during ReviewGraceBlocks
	testing.SetRealm(testing.NewUserRealm(creator))
	uassert.AbortsWithMessage(t, cur, "bountyforge: cannot cancel while submissions exist before deadline + review grace", func() {
		CancelAndRefund(cross(cur), id)
	})

	// After ReviewGraceBlocks passes, creator can cancel cleanly
	testing.SkipHeights(ReviewGraceBlocks + 1)
	CancelAndRefund(cross(cur), id)
	uassert.Equal(t, int64(0), TotalEscrowed())
}

func Test11_TopUpAfterDeadlineBlocked(cur realm, t *testing.T) {
	resetState()

	depositToEscrow(1_000_000)
	testing.SetRealm(testing.NewUserRealm(creator))
	id := CreateBounty(cross(cur), "Late TopUp", "Must reject after deadline", "sec", "", 10)

	testing.SkipHeights(11)
	depositToEscrow(500_000)
	testing.SetRealm(testing.NewUserRealm(sponsor))
	uassert.AbortsWithMessage(t, cur, "bountyforge: cannot top up after submission deadline has passed", func(cur realm) {
		topUpBountyCore(cur, sponsor, id, 500_000)
	})
}

func Test12_RejectMultiDenomOriginSend(cur realm, t *testing.T) {
	resetState()

	multi := chain.Coins{
		chain.NewCoin("ugnot", 1_000_000),
		chain.NewCoin("uatom", 500),
	}
	testing.IssueCoins(realmAddr, multi)
	testing.SetOriginSend(multi)
	uassert.PanicsWithMessage(t, cur, "bountyforge: transaction must attach strictly positive ugnot only", func() {
		_ = strictUgnotFromOriginSend()
	})
}

func Test13_RejectNonUserCodeRealmOriginSend(cur realm, t *testing.T) {
	resetState()

	depositToEscrow(1_000_000)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/attacker/relay"))
	uassert.AbortsWithMessage(t, cur, "bountyforge: only direct user calls (maketx call) are accepted for OriginSend deposits", func(cur realm) {
		requireDirectUserRealm(cur)
	})
}

func Test14_AssertOriginCallBlocksNestedRelayCall(cur realm, t *testing.T) {
	resetState()

	depositToEscrow(1_000_000)
	testing.SetRealm(testing.NewUserRealm(creator))
	// Calling CreateBounty or TopUpBounty via another package (uassert) triggers runtime.AssertOriginCall()!
	uassert.AbortsWithMessage(t, cur, "invalid non-origin call", func() {
		CreateBounty(cross(cur), "Nested Call", "Blocked by AssertOriginCall", "sec", "", 0)
	})
	uassert.AbortsWithMessage(t, cur, "invalid non-origin call", func() {
		TopUpBounty(cross(cur), 1)
	})
}

func Test15_RejectCreatorAsOwnArbiter(cur realm, t *testing.T) {
	resetState()

	depositToEscrow(1_000_000)
	testing.SetRealm(testing.NewUserRealm(creator))
	uassert.AbortsWithMessage(t, cur, "bountyforge: creator cannot be their own arbiter", func(cur realm) {
		createBountyCore(cur, creator, 1_000_000, "Self Arbiter", "Invalid", "sec", creator.String(), 0)
	})
}

func Test16_CanonicalBankerDAOComposabilityAndFakeBankerRejection(cur realm, t *testing.T) {
	resetState()

	testing.SetRealm(testing.NewCodeRealm("gno.land/r/demo/dao"))
	uassert.AbortsWithMessage(t, cur, "bountyforge: non-canonical banker rejected", func() {
		CreateBountyWithBanker(cross(cur), fakeBanker{}, 1_000_000, "Fake DAO", "Should fail", "dao", "", 0)
	})

	uassert.AbortsWithMessage(t, cur, "bountyforge: non-canonical banker rejected", func() {
		TopUpBountyWithBanker(cross(cur), fakeBanker{}, 1, 500_000)
	})
}

func Test17_WithdrawSubmissionPreservesIndicesAndAllowsCancel(cur realm, t *testing.T) {
	resetState()

	depositToEscrow(2_000_000)
	testing.SetRealm(testing.NewUserRealm(creator))
	id := CreateBounty(cross(cur), "Withdraw Test", "Check index stability", "ux", "", 0)

	testing.SetOriginSend(nil)
	testing.SetRealm(testing.NewUserRealm(alice))
	idxA := SubmitWork(cross(cur), id, "https://example.com/a", "alice")
	testing.SetRealm(testing.NewUserRealm(bob))
	idxB := SubmitWork(cross(cur), id, "https://example.com/b", "bob")
	uassert.Equal(t, 0, idxA)
	uassert.Equal(t, 1, idxB)

	testing.SetRealm(testing.NewUserRealm(alice))
	WithdrawSubmission(cross(cur), id)

	testing.SetRealm(testing.NewUserRealm(creator))
	uassert.AbortsWithMessage(t, cur, "bountyforge: cannot pay a withdrawn submission", func() {
		ApproveAndPay(cross(cur), id, 0)
	})

	testing.SetRealm(testing.NewUserRealm(bob))
	WithdrawSubmission(cross(cur), id)

	testing.SetRealm(testing.NewUserRealm(creator))
	CancelAndRefund(cross(cur), id)
	uassert.Equal(t, int64(0), TotalEscrowed())
}

func Test18_MarkdownHTMLBiDiAndURLInjectionDefense(cur realm, t *testing.T) {
	resetState()

	depositToEscrow(1_000_000)
	testing.SetRealm(testing.NewUserRealm(creator))
	id := CreateBounty(
		cross(cur),
		"Quest | `break` \u202E<gno-button href=\"/evil\" label=\"Claim\" />",
		"<!-- swallow page\n<gno-button href=\"/r/evil$help&func=ApproveAndPay\" label=\"Free GNOT\" />\n[phish](javascript:alert(1))",
		"tag`break`|pipe",
		arbiter.String(),
		100,
	)

	testing.SetOriginSend(nil)
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsWithMessage(t, cur, "bountyforge: proofURL must start with https:// or http://", func() {
		SubmitWork(cross(cur), id, "javascript:alert(1)", "xss")
	})

	SubmitWork(cross(cur), id, "https://github.com/LHorTL/bountyforge/pull/9", "Notes | <gno-button href=\"/x\" label=\"y\" />")
	OpenDispute(cross(cur), id, "<!-- comment hijack\n<gno-button href=\"/x\" label=\"pwn\" />")

	home := Render("")
	uassert.False(t, strings.Contains(home, "\u202E"), "BiDi RLO must be stripped")
	uassert.False(t, strings.Contains(home, `<gno-button href="/evil"`), "unescaped gno-button in title must NOT exist")
	uassert.True(t, strings.Contains(home, `\<gno\-button`), "title gno-button must be backslash-escaped by sanitize.TableCell")

	detail := Render("bounty/1")
	uassert.True(t, strings.Contains(detail, `\<!--`), "HTML comment opener must be escaped by sanitize.Block")
	uassert.True(t, strings.Contains(detail, `\<gno-button`), "injected gno-button inside Summary/Dispute must be escaped")
	uassert.True(t, strings.Contains(detail, "## Submissions"), "Submissions section must survive hostile Summary")

	notFound := Render("foo`bar`baz")
	uassert.True(t, strings.Contains(notFound, "``foo`bar`baz``"), "InlineCode must outscan embedded backticks")

	badBuilder := Render("builder/`evil`")
	uassert.True(t, strings.Contains(badBuilder, "Invalid Address"), "non-bech32 builder route must be rejected")
}

func Test19_AVLLeaderboardOrderingPaginationAndClamping(cur realm, t *testing.T) {
	resetState()

	rewards := []struct {
		builder address
		amt     int64
	}{
		{bob, 2_000_000},
		{carol, 10_000_000},
		{alice, 5_000_000},
	}
	for i, tc := range rewards {
		depositToEscrow(tc.amt)
		testing.SetRealm(testing.NewUserRealm(creator))
		id := CreateBounty(cross(cur), "Quest "+strconv.Itoa(i+1), "Desc", "gno", "", 0)
		testing.SetOriginSend(nil)
		testing.SetRealm(testing.NewUserRealm(tc.builder))
		SubmitWork(cross(cur), id, "https://example.com/"+strconv.Itoa(i), "done")
		testing.SetRealm(testing.NewUserRealm(creator))
		ApproveAndPay(cross(cur), id, 0)
	}

	lbPage1 := Render("leaderboard?page=1&size=2")
	carolPos := strings.Index(lbPage1, carol.String())
	alicePos := strings.Index(lbPage1, alice.String())
	uassert.True(t, carolPos > 0 && alicePos > carolPos, "Carol must rank above Alice")
	uassert.False(t, strings.Contains(lbPage1, bob.String()), "Bob should be on page 2")

	lbPage2 := Render("leaderboard?page=2&size=2")
	uassert.True(t, strings.Contains(lbPage2, bob.String()), "Bob must appear on page 2")

	homeClamped := Render("?status=PAID&page=1&size=999999")
	uassert.True(t, strings.Contains(homeClamped, "Quest 3"), "status index + clamped paging works")
}

func Test20_StructuredJSONViewsForMCPAndWebDApp(cur realm, t *testing.T) {
	resetState()

	depositToEscrow(5_000_000)
	testing.SetRealm(testing.NewUserRealm(creator))
	id := CreateBounty(cross(cur), `Quote "Test"`, "Line 1\nLine 2", "gno,mcp", arbiter.String(), 500)

	proto := ProtocolJSON()
	uassert.True(t, strings.Contains(proto, `"total_bounties":1`), "ProtocolJSON total_bounties")
	uassert.True(t, strings.Contains(proto, `"total_escrowed_ugnot":5000000`), "ProtocolJSON escrowed")

	detail := BountyJSON(id)
	uassert.True(t, strings.Contains(detail, `"title":"Quote \"Test\""`), "BountyJSON escapes quotes cleanly")
	uassert.True(t, strings.Contains(detail, `"contributions":[`), "BountyJSON includes sponsor ledger")

	listed := ListBountiesJSON("OPEN", 1, 10)
	uassert.True(t, strings.Contains(listed, `"total_items":1`), "ListBountiesJSON status filter")

	lb := LeaderboardJSON(1, 10)
	uassert.True(t, strings.Contains(lb, `"items":[]`), "LeaderboardJSON empty list")

	bj := BuilderJSON(alice)
	uassert.True(t, strings.Contains(bj, `"tier":"Novice"`), "BuilderJSON returns Novice for new addr")
}

func Test21_SecurityGuardsAuthorizationPanics(cur realm, t *testing.T) {
	resetState()

	depositToEscrow(1_000_000)
	testing.SetRealm(testing.NewUserRealm(creator))
	id := CreateBounty(cross(cur), "Guarded Quest", "Check authorization panics", "sec", arbiter.String(), 100)

	testing.SetOriginSend(nil)
	testing.SetRealm(testing.NewUserRealm(creator))
	uassert.AbortsWithMessage(t, cur, "bountyforge: bounty creator cannot submit work to their own bounty", func() {
		SubmitWork(cross(cur), id, "https://example.com/self", "nope")
	})

	testing.SetRealm(testing.NewUserRealm(arbiter))
	uassert.AbortsWithMessage(t, cur, "bountyforge: bounty arbiter cannot submit work", func() {
		SubmitWork(cross(cur), id, "https://example.com/arb", "nope")
	})

	testing.SetRealm(testing.NewUserRealm(alice))
	SubmitWork(cross(cur), id, "https://example.com/alice", "valid")

	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsWithMessage(t, cur, "bountyforge: only the bounty creator can approve payout", func() {
		ApproveAndPay(cross(cur), id, 0)
	})

	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsWithMessage(t, cur, "bountyforge: only creator or an active submitter can open a dispute", func() {
		OpenDispute(cross(cur), id, "outsider grief")
	})

	testing.SetRealm(testing.NewUserRealm(alice))
	OpenDispute(cross(cur), id, "dispute test")
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsWithMessage(t, cur, "bountyforge: only the designated arbiter can resolve disputes", func() {
		ResolveDispute(cross(cur), id, 0, 5000)
	})
}

func Test22_DAOCanonicalBankerEndToEndLifecycle(cur realm, t *testing.T) {
	resetState()

	// Issue funds and mint a genuine canonical RealmSend banker.
	testing.IssueCoins(realmAddr, chain.Coins{chain.NewCoin("ugnot", 6_000_000)})
	canonical := banker.NewBanker(banker.BankerTypeRealmSend, cur)

	// Simulate DAO realm funding and topping up without OriginSend.
	testing.SetOriginSend(nil)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/g10yuqyktt4777jn8rt3nmuhw4suz9mvypaec7ac/bountyforge"))
	id := CreateBountyWithBanker(cross(cur), canonical, 4_000_000, "DAO Governance Quest", "Funded via canonical banker", "dao,gov", "", 0)
	uassert.Equal(t, uint64(1), id)
	uassert.Equal(t, int64(4_000_000), TotalEscrowed())

	newTotal := TopUpBountyWithBanker(cross(cur), canonical, id, 2_000_000)
	uassert.Equal(t, int64(6_000_000), newTotal)

	// Builder submits work and DAO realm approves & pays cleanly!
	testing.SetRealm(testing.NewUserRealm(alice))
	SubmitWork(cross(cur), id, "https://github.com/LHorTL/bountyforge/pull/42", "DAO PR merged")

	b := banker.NewReadonlyBanker()
	beforeAlice := b.GetCoin(alice, "ugnot")

	testing.SetRealm(testing.NewCodeRealm("gno.land/r/g10yuqyktt4777jn8rt3nmuhw4suz9mvypaec7ac/bountyforge"))
	ApproveAndPay(cross(cur), id, 0)
	uassert.Equal(t, int64(6_000_000), b.GetCoin(alice, "ugnot")-beforeAlice)
	uassert.Equal(t, int64(0), TotalEscrowed())
}
