package hearthescrow

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"strings"
	"testing"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
	"gno.land/p/nt/urequire/v0"
)

const testPkgPath = "gno.land/r/g1x7ud67jym95qh9zf0swmq6ck07s3ly3lksxc5n/hearthescrow"

func resetState() {
	nextID = 0
	escrows = avl.NewTree()
	addressIndex = avl.NewTree()
	stats = Stats{}
}

func fundAndCreate(
	cur realm,
	depositor address,
	title string,
	recipient address,
	arbiter address,
	deadlineOffset int64,
	titles string,
	bps string,
	amount int64,
) uint64 {
	pkgAddr := chain.PackageAddress(testPkgPath)
	coins := chain.NewCoins(chain.NewCoin(DenomUGNOT, amount))
	testing.IssueCoins(pkgAddr, coins)
	testing.SetRealm(testing.NewUserRealm(depositor))
	testing.SetOriginSend(coins)
	deadline := runtime.ChainHeight() + deadlineOffset
	return CreateEscrow(cross(cur), title, recipient, arbiter, deadline, titles, bps)
}

func TestHappyPath_MultiMilestoneAndDustSweep(cur realm, t *testing.T) {
	defer resetState()

	depositor := testutils.TestAddress("dep_happy")
	recipient := testutils.TestAddress("rec_happy")
	arbiter := testutils.TestAddress("arb_happy")
	ro := banker.NewReadonlyBanker()
	recBefore := ro.GetCoin(recipient, DenomUGNOT)

	// 1,000,001 ugnot split 3333 / 3333 / 3334 bps tests rounding-dust sweep on final approval
	id := fundAndCreate(
		cur, depositor,
		"Tavern Website Build",
		recipient, arbiter, 100,
		"Wireframes,Frontend,Audit",
		"3333,3333,3334",
		1_000_001,
	)
	urequire.Equal(t, uint64(1), id)

	e := GetEscrow(id)
	urequire.True(t, e != nil)
	uassert.Equal(t, string(StatusActive), string(e.Status))
	uassert.Equal(t, int64(1_000_001), e.RemainingAmount())
	uassert.Equal(t, 3, len(e.Milestones))

	// Recipient submits milestone 0
	testing.SetRealm(testing.NewUserRealm(recipient))
	SubmitMilestone(cross(cur), id, 0, "https://example.com/wireframes")
	e = GetEscrow(id)
	uassert.Equal(t, string(MilestoneSubmitted), string(e.Milestones[0].Status))
	uassert.Equal(t, "https://example.com/wireframes", e.Milestones[0].Deliverable)

	// Depositor approves milestone 0
	testing.SetRealm(testing.NewUserRealm(depositor))
	p0 := ApproveMilestone(cross(cur), id, 0)
	uassert.Equal(t, int64(333_300), p0)

	// Out-of-order approval: approve milestone 2 directly without submission
	p2 := ApproveMilestone(cross(cur), id, 2)
	uassert.Equal(t, int64(333_400), p2)

	// Final unapproved milestone (index 1) must sweep the remaining 333,301 ugnot (zero dust trapped)
	p1 := ApproveMilestone(cross(cur), id, 1)
	uassert.Equal(t, int64(333_301), p1)
	uassert.Equal(t, int64(1_000_001), p0+p1+p2)

	e = GetEscrow(id)
	uassert.Equal(t, string(StatusCompleted), string(e.Status))
	uassert.Equal(t, int64(0), e.RemainingAmount())
	uassert.Equal(t, int64(1_000_001), e.ReleasedAmount)
	uassert.Equal(t, recBefore+1_000_001, ro.GetCoin(recipient, DenomUGNOT))

	st := GetStats()
	uassert.Equal(t, 1, st.TotalEscrows)
	uassert.Equal(t, 0, st.ActiveCount)
	uassert.Equal(t, 1, st.CompletedCount)
	uassert.Equal(t, int64(0), st.TotalLocked)
	uassert.Equal(t, int64(1_000_001), st.TotalReleased)

	// Double-approve or refund on completed escrow must abort
	uassert.AbortsWithMessage(t, cur, ErrEscrowNotActive.Error(), func() {
		ApproveMilestone(cross(cur), id, 0)
	})
	uassert.AbortsWithMessage(t, cur, ErrEscrowNotActive.Error(), func() {
		ClaimRefund(cross(cur), id)
	})
}

func TestDisputeAndArbiterSplit(cur realm, t *testing.T) {
	defer resetState()

	depositor := testutils.TestAddress("dep_disp")
	recipient := testutils.TestAddress("rec_disp")
	arbiter := testutils.TestAddress("arb_disp")
	outsider := testutils.TestAddress("out_disp")
	ro := banker.NewReadonlyBanker()

	id := fundAndCreate(
		cur, depositor,
		"Smart Contract Audit",
		recipient, arbiter, 100,
		"Draft Report,Final Report",
		"4000,6000",
		1_000_000,
	)

	// Approve milestone 0 (400,000 ugnot) first
	testing.SetRealm(testing.NewUserRealm(depositor))
	p0 := ApproveMilestone(cross(cur), id, 0)
	uassert.Equal(t, int64(400_000), p0)

	// Outsider cannot open dispute
	testing.SetRealm(testing.NewUserRealm(outsider))
	uassert.AbortsWithMessage(t, cur, ErrUnauthorized.Error(), func() {
		OpenDispute(cross(cur), id, "Not my escrow")
	})

	// Recipient opens dispute over the remaining 600,000 ugnot
	testing.SetRealm(testing.NewUserRealm(recipient))
	OpenDispute(cross(cur), id, "Final report delivered but depositor unresponsive")

	e := GetEscrow(id)
	uassert.Equal(t, string(StatusDisputed), string(e.Status))
	urequire.True(t, e.Dispute != nil)
	uassert.Equal(t, recipient, e.Dispute.OpenedBy)

	// Depositor cannot bypass open dispute with ClaimRefund even after deadline
	testing.SkipHeights(150)
	testing.SetRealm(testing.NewUserRealm(depositor))
	uassert.AbortsWithMessage(t, cur, ErrEscrowNotActive.Error(), func() {
		ClaimRefund(cross(cur), id)
	})

	// Non-arbiter cannot resolve dispute
	uassert.AbortsWithMessage(t, cur, ErrUnauthorized.Error(), func() {
		ResolveDispute(cross(cur), id, 0, "Depositor trying to self-resolve")
	})

	// Invalid split bps rejected
	testing.SetRealm(testing.NewUserRealm(arbiter))
	uassert.AbortsWithMessage(t, cur, ErrInvalidSplitBps.Error(), func() {
		ResolveDispute(cross(cur), id, 10_001, "Too high")
	})
	uassert.AbortsWithMessage(t, cur, ErrInvalidSplitBps.Error(), func() {
		ResolveDispute(cross(cur), id, -1, "Negative")
	})

	depBefore := ro.GetCoin(depositor, DenomUGNOT)
	recBefore := ro.GetCoin(recipient, DenomUGNOT)

	// Arbiter splits remaining 600,000 ugnot: 70% (420,000) to recipient, 30% (180,000) to depositor
	recPay, depRef := ResolveDispute(cross(cur), id, 7000, "Substantial completion verified")
	uassert.Equal(t, int64(420_000), recPay)
	uassert.Equal(t, int64(180_000), depRef)
	uassert.Equal(t, recBefore+420_000, ro.GetCoin(recipient, DenomUGNOT))
	uassert.Equal(t, depBefore+180_000, ro.GetCoin(depositor, DenomUGNOT))

	e = GetEscrow(id)
	uassert.Equal(t, string(StatusResolved), string(e.Status))
	uassert.Equal(t, int64(0), e.RemainingAmount())
	uassert.Equal(t, int64(820_000), e.ReleasedAmount)
	uassert.Equal(t, int64(180_000), e.RefundedAmount)

	// Cannot resolve twice
	uassert.AbortsWithMessage(t, cur, ErrEscrowNotDisputed.Error(), func() {
		ResolveDispute(cross(cur), id, 5000, "Double resolve")
	})
}

func TestDeadlineRefund(cur realm, t *testing.T) {
	defer resetState()

	depositor := testutils.TestAddress("dep_ref")
	recipient := testutils.TestAddress("rec_ref")
	ro := banker.NewReadonlyBanker()

	// No arbiter configured ("")
	id := fundAndCreate(
		cur, depositor,
		"Icon Pack",
		recipient, "", 25,
		"Set A,Set B",
		"5000,5000",
		2_000_000,
	)

	// Cannot open dispute without arbiter
	testing.SetRealm(testing.NewUserRealm(depositor))
	uassert.AbortsWithMessage(t, cur, ErrNoArbiter.Error(), func() {
		OpenDispute(cross(cur), id, "Need arbiter")
	})

	// Approve milestone 0 (1,000,000 ugnot)
	ApproveMilestone(cross(cur), id, 0)

	// Refund before deadline must abort
	uassert.AbortsWithMessage(t, cur, ErrDeadlineNotReached.Error(), func() {
		ClaimRefund(cross(cur), id)
	})

	// Advance past deadline
	testing.SkipHeights(25)

	// Recipient cannot claim refund
	testing.SetRealm(testing.NewUserRealm(recipient))
	uassert.AbortsWithMessage(t, cur, ErrUnauthorized.Error(), func() {
		ClaimRefund(cross(cur), id)
	})

	// Depositor reclaims remaining 1,000,000 ugnot
	depBefore := ro.GetCoin(depositor, DenomUGNOT)
	testing.SetRealm(testing.NewUserRealm(depositor))
	refunded := ClaimRefund(cross(cur), id)
	uassert.Equal(t, int64(1_000_000), refunded)
	uassert.Equal(t, depBefore+1_000_000, ro.GetCoin(depositor, DenomUGNOT))

	e := GetEscrow(id)
	uassert.Equal(t, string(StatusRefunded), string(e.Status))
	uassert.Equal(t, int64(0), e.RemainingAmount())
	uassert.Equal(t, int64(1_000_000), e.RefundedAmount)

	// Double refund must abort
	uassert.AbortsWithMessage(t, cur, ErrEscrowNotActive.Error(), func() {
		ClaimRefund(cross(cur), id)
	})
}

func TestValidationAndAuthGuards(cur realm, t *testing.T) {
	defer resetState()

	depositor := testutils.TestAddress("dep_guard")
	recipient := testutils.TestAddress("rec_guard")
	arbiter := testutils.TestAddress("arb_guard")
	pkgAddr := chain.PackageAddress(testPkgPath)

	coins := chain.NewCoins(chain.NewCoin(DenomUGNOT, 500_000))
	testing.IssueCoins(pkgAddr, chain.NewCoins(chain.NewCoin(DenomUGNOT, 5_000_000)))
	testing.SetRealm(testing.NewUserRealm(depositor))
	testing.SetOriginSend(coins)
	future := runtime.ChainHeight() + 50

	// Empty title
	uassert.AbortsWithMessage(t, cur, ErrInvalidTitle.Error(), func() {
		CreateEscrow(cross(cur), "   ", recipient, arbiter, future, "M1", "10000")
	})

	// Self-escrow
	uassert.AbortsWithMessage(t, cur, ErrSelfEscrow.Error(), func() {
		CreateEscrow(cross(cur), "Self", depositor, arbiter, future, "M1", "10000")
	})

	// Arbiter equals recipient
	uassert.AbortsWithMessage(t, cur, ErrInvalidArbiter.Error(), func() {
		CreateEscrow(cross(cur), "Bad Arb", recipient, recipient, future, "M1", "10000")
	})

	// Past deadline
	uassert.AbortsWithMessage(t, cur, ErrInvalidDeadline.Error(), func() {
		CreateEscrow(cross(cur), "Past", recipient, arbiter, runtime.ChainHeight(), "M1", "10000")
	})

	// Milestone bps not summing to 10000
	uassert.AbortsWithMessage(t, cur, ErrInvalidMilestones.Error(), func() {
		CreateEscrow(cross(cur), "Bad BPS", recipient, arbiter, future, "M1,M2", "4000,5000")
	})

	// Zero milestone bps
	uassert.AbortsWithMessage(t, cur, ErrInvalidMilestones.Error(), func() {
		CreateEscrow(cross(cur), "Zero BPS", recipient, arbiter, future, "M1,M2", "0,10000")
	})

	// Wrong denom deposit
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin("uatom", 500_000)))
	uassert.AbortsWithMessage(t, cur, ErrInvalidDeposit.Error(), func() {
		CreateEscrow(cross(cur), "Wrong Denom", recipient, arbiter, future, "M1", "10000")
	})

	// Zero deposit
	testing.SetOriginSend(chain.Coins{})
	uassert.AbortsWithMessage(t, cur, ErrInvalidDeposit.Error(), func() {
		CreateEscrow(cross(cur), "Zero Deposit", recipient, arbiter, future, "M1", "10000")
	})

	// Valid creation then check unauthorized submit/approve + bad milestone index
	testing.SetOriginSend(coins)
	id := CreateEscrow(cross(cur), "Guard Test", recipient, arbiter, future, "M1,M2", "5000,5000")

	// Depositor cannot submit milestone
	uassert.AbortsWithMessage(t, cur, ErrUnauthorized.Error(), func() {
		SubmitMilestone(cross(cur), id, 0, "dep trying to submit")
	})

	// Recipient cannot approve milestone
	testing.SetRealm(testing.NewUserRealm(recipient))
	uassert.AbortsWithMessage(t, cur, ErrUnauthorized.Error(), func() {
		ApproveMilestone(cross(cur), id, 0)
	})

	// Out-of-range milestone index
	uassert.AbortsWithMessage(t, cur, ErrMilestoneOutOfRange.Error(), func() {
		SubmitMilestone(cross(cur), id, 5, "out of range")
	})

	// Empty deliverable
	uassert.AbortsWithMessage(t, cur, ErrInvalidDeliverable.Error(), func() {
		SubmitMilestone(cross(cur), id, 0, "   ")
	})

	// Double submit
	SubmitMilestone(cross(cur), id, 0, "ipfs://cid1")
	uassert.AbortsWithMessage(t, cur, ErrMilestoneNotPending.Error(), func() {
		SubmitMilestone(cross(cur), id, 0, "ipfs://cid2")
	})

	// Double approve on same milestone
	testing.SetRealm(testing.NewUserRealm(depositor))
	ApproveMilestone(cross(cur), id, 0)
	uassert.AbortsWithMessage(t, cur, ErrMilestoneAlreadyApproved.Error(), func() {
		ApproveMilestone(cross(cur), id, 0)
	})

	// Unknown escrow ID
	uassert.AbortsWithMessage(t, cur, ErrEscrowNotFound.Error(), func() {
		ApproveMilestone(cross(cur), 999, 0)
	})
}

func TestRenderViews(cur realm, t *testing.T) {
	defer resetState()

	// Empty state
	emptyHome := Render("")
	uassert.True(t, strings.Contains(emptyHome, "# HearthEscrow"))
	uassert.True(t, strings.Contains(emptyHome, "No escrows created yet"))

	depositor := testutils.TestAddress("dep_render")
	recipient := testutils.TestAddress("rec_render")
	arbiter := testutils.TestAddress("arb_render")

	id1 := fundAndCreate(cur, depositor, "Quest Board UI", recipient, arbiter, 100, "Spec,Ship", "3000,7000", 2_500_000)
	id2 := fundAndCreate(cur, depositor, "Audio Pack", recipient, arbiter, 100, "Draft,Final", "5000,5000", 1_000_000)

	// Open dispute on id2 so we test active vs disputed filters
	testing.SetRealm(testing.NewUserRealm(depositor))
	OpenDispute(cross(cur), id2, "Missing stems")

	home := Render("")
	uassert.True(t, strings.Contains(home, "Quest Board UI"))
	uassert.True(t, strings.Contains(home, "Audio Pack"))
	uassert.True(t, strings.Contains(home, "3.5 GNOT"))

	activeOnly := Render("?status=active")
	uassert.True(t, strings.Contains(activeOnly, "Quest Board UI"))
	uassert.False(t, strings.Contains(activeOnly, "Audio Pack"))

	disputedOnly := Render("?status=disputed")
	uassert.True(t, strings.Contains(disputedOnly, "Audio Pack"))
	uassert.False(t, strings.Contains(disputedOnly, "Quest Board UI"))

	closedOnly := Render("?status=closed")
	uassert.True(t, strings.Contains(closedOnly, "No escrows match filter"))

	// Detail view
	detail := Render("escrow/1")
	uassert.True(t, strings.Contains(detail, "# Escrow #1 — Quest Board UI"))
	uassert.True(t, strings.Contains(detail, "2.5 GNOT"))
	uassert.True(t, strings.Contains(detail, "SubmitMilestone"))

	// Disputed detail view shows dispute record and ResolveDispute CLI snippet
	detail2 := Render("escrow/2")
	uassert.True(t, strings.Contains(detail2, "Missing stems"))
	uassert.True(t, strings.Contains(detail2, "ResolveDispute"))

	// Address view
	addrView := Render("address/" + recipient.String())
	uassert.True(t, strings.Contains(addrView, "Recipient"))
	uassert.True(t, strings.Contains(addrView, "Quest Board UI"))
	uassert.True(t, strings.Contains(addrView, "Audio Pack"))

	// Graceful 404 / invalid routes
	uassert.True(t, strings.Contains(Render("escrow/999"), "Not Found"))
	uassert.True(t, strings.Contains(Render("escrow/abc"), "Route Not Found"))
	uassert.True(t, strings.Contains(Render("unknown/path"), "Route Not Found"))
	uassert.True(t, strings.Contains(Render("address/not-a-valid-addr"), "Invalid Gno address"))

	_ = id1
}

func TestDisputeBoundarySplits_ZeroAndFull(cur realm, t *testing.T) {
	defer resetState()

	depositor := testutils.TestAddress("dep_bound")
	recipient := testutils.TestAddress("rec_bound")
	arbiter := testutils.TestAddress("arb_bound")
	ro := banker.NewReadonlyBanker()

	// Case A: 0 bps to recipient (100% refund to depositor), opened by depositor
	id1 := fundAndCreate(cur, depositor, "Full Refund Dispute", recipient, arbiter, 50, "Deliverable", "10000", 500_000)
	testing.SetRealm(testing.NewUserRealm(depositor))
	OpenDispute(cross(cur), id1, "No work delivered")

	// Recipient cannot submit milestone while disputed
	testing.SetRealm(testing.NewUserRealm(recipient))
	uassert.AbortsWithMessage(t, cur, ErrEscrowNotActive.Error(), func() {
		SubmitMilestone(cross(cur), id1, 0, "late")
	})

	depBefore := ro.GetCoin(depositor, DenomUGNOT)
	recBefore := ro.GetCoin(recipient, DenomUGNOT)
	testing.SetRealm(testing.NewUserRealm(arbiter))
	recPay, depRef := ResolveDispute(cross(cur), id1, 0, "Full refund to depositor")
	uassert.Equal(t, int64(0), recPay)
	uassert.Equal(t, int64(500_000), depRef)
	uassert.Equal(t, depBefore+500_000, ro.GetCoin(depositor, DenomUGNOT))
	uassert.Equal(t, recBefore, ro.GetCoin(recipient, DenomUGNOT))

	// Case B: 10000 bps to recipient (100% payout to recipient)
	id2 := fundAndCreate(cur, depositor, "Full Payout Dispute", recipient, arbiter, 50, "Deliverable", "10000", 750_000)
	testing.SetRealm(testing.NewUserRealm(recipient))
	OpenDispute(cross(cur), id2, "Work delivered per spec")

	depBefore = ro.GetCoin(depositor, DenomUGNOT)
	recBefore = ro.GetCoin(recipient, DenomUGNOT)
	testing.SetRealm(testing.NewUserRealm(arbiter))
	recPay, depRef = ResolveDispute(cross(cur), id2, 10_000, "Full release to recipient")
	uassert.Equal(t, int64(750_000), recPay)
	uassert.Equal(t, int64(0), depRef)
	uassert.Equal(t, recBefore+750_000, ro.GetCoin(recipient, DenomUGNOT))
	uassert.Equal(t, depBefore, ro.GetCoin(depositor, DenomUGNOT))

	st := GetStats()
	uassert.Equal(t, 2, st.ResolvedCount)
	uassert.Equal(t, int64(0), st.TotalLocked)
}

func TestInvalidAddressesAndMaxMilestones(cur realm, t *testing.T) {
	defer resetState()

	depositor := testutils.TestAddress("dep_max")
	recipient := testutils.TestAddress("rec_max")
	pkgAddr := chain.PackageAddress(testPkgPath)

	coins := chain.NewCoins(chain.NewCoin(DenomUGNOT, 1_000_000))
	testing.IssueCoins(pkgAddr, chain.NewCoins(chain.NewCoin(DenomUGNOT, 5_000_000)))
	testing.SetRealm(testing.NewUserRealm(depositor))
	testing.SetOriginSend(coins)
	future := runtime.ChainHeight() + 50

	// Invalid recipient address
	uassert.AbortsWithMessage(t, cur, ErrInvalidRecipient.Error(), func() {
		CreateEscrow(cross(cur), "Bad Rec", address("invalid"), "", future, "M1", "10000")
	})

	// Invalid arbiter address
	uassert.AbortsWithMessage(t, cur, ErrInvalidArbiter.Error(), func() {
		CreateEscrow(cross(cur), "Bad Arb", recipient, address("invalid"), future, "M1", "10000")
	})

	// 21 milestones exceeds MaxMilestones (20)
	titles21 := strings.Repeat("M,", 20) + "M"
	bps21 := strings.Repeat("400,", 20) + "2000"
	uassert.AbortsWithMessage(t, cur, ErrInvalidMilestones.Error(), func() {
		CreateEscrow(cross(cur), "Too Many", recipient, "", future, titles21, bps21)
	})

	// Single milestone (10000 bps) succeeds and completes in one approval
	id := CreateEscrow(cross(cur), "Single Shot", recipient, "", future, "All Work", "10000")
	paid := ApproveMilestone(cross(cur), id, 0)
	uassert.Equal(t, int64(1_000_000), paid)
	uassert.Equal(t, string(StatusCompleted), string(GetEscrow(id).Status))
}
