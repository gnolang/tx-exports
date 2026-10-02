package crowdfund

import (
	"strings"
	"testing"

	"chain"

	"gno.land/p/g1qp5pt8cdq2f6kfdamn3yuxwg6quqnfpyewzz39/coinio"
	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

var (
	creator1 = testutils.TestAddress("cfcreator1")
	creator2 = testutils.TestAddress("cfcreator2")
	backerA  = testutils.TestAddress("cfbackera")
	backerB  = testutils.TestAddress("cfbackerb")
	mallory  = testutils.TestAddress("cfmallory")
)

// HARNESS NOTES, carried from the treasury_board, vesting and grants
// suites (measured there, relied on here):
//
//   - testing.SetRealm records the override per FRAME INDEX: stage the
//     caller INLINE in the test function's frame before a uassert call,
//     or inside a helper that stages and calls in one frame of its own.
//     Never inside a uassert closure — that staging does not take.
//
//   - testing.SkipHeights REPLACES the whole context (OriginCaller,
//     CurrentRealm, OriginSend included). Re-stage after every skip.
//
//   - Realm globals PERSIST across tests while banker state resets per
//     test. begin() disarms any leftover envelope and re-seeds the
//     realm's bank to its carried liabilities, so conservation is
//     asserted in DELTA form.
//
//   - A panic caught by uassert does NOT roll back realm globals here,
//     whereas on-chain the whole transaction reverts. Every abort
//     asserted below happens strictly BEFORE this realm writes state,
//     with one measured exception documented inline
//     (TestClaimTimingIsTheDuebooksVerdict).
//
//   - The SEND envelope is process-global: a staged envelope must be
//     cleared (SetOriginSend(nil)) before the next non-payable call, or
//     rejectStraySend fires and the test asserts the harness leak, not
//     the guard.
func init() {
	self = chain.PackageAddress("gno.land/r/g1qp5pt8cdq2f6kfdamn3yuxwg6quqnfpyewzz39/crowdfund")
}

type baseline struct {
	held   int64
	backed int64
	fees   int64
}

func begin() baseline {
	testing.SetOriginSend(nil)
	if l := Liabilities(); l > 0 {
		testing.IssueCoins(Address(), ugnot(l))
	}
	return baseline{held: Held(), backed: TotalBacked(), fees: FeesAccrued()}
}

func ugnot(n int64) chain.Coins {
	return chain.NewCoins(chain.NewCoin(Denom, n))
}

// launchAs stages `from` and launches a MinGoal x MinDuration campaign.
func launchAs(cur realm, from address, title string) int64 {
	testing.SetRealm(testing.NewUserRealm(from))
	return Launch(cross(cur), title, "", MinGoal, MinDurationBlocks)
}

// pledgeAs stages a direct EOA call with -send and mirrors the
// envelope into the realm's bank, as the chain would.
func pledgeAs(cur realm, from address, id, amount int64) {
	testing.SetRealm(testing.NewUserRealm(from))
	testing.SetOriginSend(ugnot(amount))
	testing.IssueCoins(Address(), ugnot(amount))
	Pledge(cross(cur), id)
	testing.SetOriginSend(nil)
}

func balanceOf(addr address) int64 {
	return coinio.HeldAt(addr, Denom)
}

// --- launch ---

func TestLaunchBasics(cur realm, t *testing.T) {
	begin()
	before := NumCampaigns()
	openBefore := OpenCampaigns()

	id := launchAs(cur, creator1, "Solar panels for the hackerspace")
	uassert.Equal(t, before+1, id)
	uassert.Equal(t, before+1, NumCampaigns())
	uassert.Equal(t, openBefore+1, OpenCampaigns())
	uassert.Equal(t, int64(1), OpenOf(creator1))

	cr, goal, raised, feeBps, createdAt, deadline, claimEnd, backers, state := CampaignInfo(id)
	uassert.Equal(t, creator1, cr)
	uassert.Equal(t, MinGoal, goal)
	uassert.Equal(t, int64(0), raised)
	uassert.Equal(t, SuccessFeeBps, feeBps)
	uassert.Equal(t, createdAt+MinDurationBlocks, deadline)
	uassert.Equal(t, deadline+ClaimWindowBlocks, claimEnd)
	uassert.Equal(t, 0, backers)
	uassert.Equal(t, stateFunding, state)
	uassert.Equal(t, stateFunding, Status(id))

	// Clean up the open slot so later per-creator-cap tests see a known
	// count.
	testing.SetRealm(testing.NewUserRealm(creator1))
	CreatorCancel(cross(cur), id)
	uassert.Equal(t, int64(0), OpenOf(creator1))
}

func TestLaunchValidation(cur realm, t *testing.T) {
	begin()
	testing.SetRealm(testing.NewUserRealm(creator1))
	uassert.AbortsWithMessage(t, cur, "title must not be empty", func() {
		Launch(cross(cur), "", "", MinGoal, MinDurationBlocks)
	})
	testing.SetRealm(testing.NewUserRealm(creator1))
	uassert.AbortsWithMessage(t, cur, "title exceeds 100 bytes", func() {
		Launch(cross(cur), strings.Repeat("x", MaxTitleLen+1), "", MinGoal, MinDurationBlocks)
	})
	testing.SetRealm(testing.NewUserRealm(creator1))
	uassert.AbortsWithMessage(t, cur, "memo exceeds 256 bytes", func() {
		Launch(cross(cur), "t", strings.Repeat("x", MaxMemoLen+1), MinGoal, MinDurationBlocks)
	})
	testing.SetRealm(testing.NewUserRealm(creator1))
	uassert.AbortsWithMessage(t, cur, "goal must be at least 1000000ugnot", func() {
		Launch(cross(cur), "t", "", MinGoal-1, MinDurationBlocks)
	})
	// Duration bounds are the duebook's own validation, not a check in
	// this realm — asserted against the primitive's error text.
	testing.SetRealm(testing.NewUserRealm(creator1))
	uassert.AbortsWithMessage(t, cur, "duebook: delay outside [minDelay, maxDelay]", func() {
		Launch(cross(cur), "t", "", MinGoal, MinDurationBlocks-1)
	})
	testing.SetRealm(testing.NewUserRealm(creator1))
	uassert.AbortsWithMessage(t, cur, "duebook: delay outside [minDelay, maxDelay]", func() {
		Launch(cross(cur), "t", "", MinGoal, MaxDurationBlocks+1)
	})
	uassert.Equal(t, int64(0), OpenOf(creator1))
}

func TestLaunchPerCreatorCap(cur realm, t *testing.T) {
	begin()
	uassert.Equal(t, int64(0), OpenOf(creator2))
	ids := []int64{}
	for i := int64(0); i < MaxOpenPerCreator; i++ {
		ids = append(ids, launchAs(cur, creator2, "cap filler"))
	}
	uassert.Equal(t, MaxOpenPerCreator, OpenOf(creator2))

	testing.SetRealm(testing.NewUserRealm(creator2))
	uassert.AbortsWithMessage(t, cur, "creator already has 8 unsettled campaigns", func() {
		Launch(cross(cur), "one too many", "", MinGoal, MinDurationBlocks)
	})

	// A settled campaign releases its slot.
	testing.SetRealm(testing.NewUserRealm(creator2))
	CreatorCancel(cross(cur), ids[0])
	uassert.Equal(t, MaxOpenPerCreator-1, OpenOf(creator2))
	idNew := launchAs(cur, creator2, "slot reopened")
	uassert.Equal(t, MaxOpenPerCreator, OpenOf(creator2))

	// Drain the slots so later tests start from a clean count.
	for _, id := range append(ids[1:], idNew) {
		testing.SetRealm(testing.NewUserRealm(creator2))
		CreatorCancel(cross(cur), id)
	}
	uassert.Equal(t, int64(0), OpenOf(creator2))
}

// --- pledging ---

func TestPledgeAndConservation(cur realm, t *testing.T) {
	b := begin()
	id := launchAs(cur, creator1, "conservation case")

	pledgeAs(cur, backerA, id, 400_000)
	pledgeAs(cur, backerB, id, 250_000)
	pledgeAs(cur, backerA, id, 100_000) // same backer accumulates

	uassert.Equal(t, int64(500_000), PledgeOf(id, backerA))
	uassert.Equal(t, int64(250_000), PledgeOf(id, backerB))
	_, _, raised, _, _, _, _, backers, _ := CampaignInfo(id)
	uassert.Equal(t, int64(750_000), raised)
	uassert.Equal(t, 2, backers)

	// Conservation, delta form: every pledged coin is in B and in H.
	uassert.Equal(t, b.backed+750_000, TotalBacked())
	uassert.Equal(t, b.held+750_000, Held())
	uassert.Equal(t, b.fees, FeesAccrued())
	uassert.True(t, Held() >= Liabilities())

	// Clean up: back out both pledges, cancel.
	testing.SetRealm(testing.NewUserRealm(backerA))
	Unpledge(cross(cur), id)
	testing.SetRealm(testing.NewUserRealm(backerB))
	Unpledge(cross(cur), id)
	uassert.Equal(t, b.backed, TotalBacked())
	testing.SetRealm(testing.NewUserRealm(creator1))
	CreatorCancel(cross(cur), id)
}

func TestPledgeGuards(cur realm, t *testing.T) {
	begin()
	id := launchAs(cur, creator1, "guard case")

	// The payment-guard regression: a realm-routed pledge is refused by
	// coinio's receipt shape, not by anything this file could forget.
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/demo/attacker"))
	testing.SetOriginSend(ugnot(1000))
	uassert.AbortsWithMessage(t, cur,
		"coinio: payment must be a direct EOA call with -send (realms and maketx-run are rejected)",
		func() { Pledge(cross(cur), id) })
	testing.SetOriginSend(nil)

	// Wrong denomination.
	testing.SetRealm(testing.NewUserRealm(backerA))
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin("foocoin", 1000)))
	uassert.AbortsWithMessage(t, cur, "coinio: send exactly one coin type: ugnot", func() {
		Pledge(cross(cur), id)
	})
	testing.SetOriginSend(nil)

	// No envelope at all.
	testing.SetRealm(testing.NewUserRealm(backerA))
	uassert.AbortsWithMessage(t, cur, "coinio: send exactly one coin type: ugnot", func() {
		Pledge(cross(cur), id)
	})

	// Unknown campaign.
	testing.SetRealm(testing.NewUserRealm(backerA))
	testing.SetOriginSend(ugnot(1000))
	uassert.AbortsWithMessage(t, cur, "unknown campaign id", func() {
		Pledge(cross(cur), 999_999)
	})
	testing.SetOriginSend(nil)

	// Below the pledge minimum (audit open question 1: dust-entry
	// bloat); exactly the minimum is accepted.
	testing.SetRealm(testing.NewUserRealm(backerA))
	testing.SetOriginSend(ugnot(MinPledge - 1))
	testing.IssueCoins(Address(), ugnot(MinPledge-1))
	uassert.AbortsWithMessage(t, cur, "pledge at least 10000ugnot", func() {
		Pledge(cross(cur), id)
	})
	testing.SetOriginSend(nil)
	pledgeAs(cur, backerA, id, MinPledge)
	uassert.Equal(t, MinPledge, PledgeOf(id, backerA))
	testing.SetRealm(testing.NewUserRealm(backerA))
	Unpledge(cross(cur), id)

	// Settled campaign.
	testing.SetRealm(testing.NewUserRealm(creator1))
	CreatorCancel(cross(cur), id)
	testing.SetRealm(testing.NewUserRealm(backerA))
	testing.SetOriginSend(ugnot(1000))
	uassert.AbortsWithMessage(t, cur, "campaign is settled", func() {
		Pledge(cross(cur), id)
	})
	testing.SetOriginSend(nil)
}

func TestPledgeClosesAtDeadline(cur realm, t *testing.T) {
	begin()
	id := launchAs(cur, creator1, "deadline case")
	testing.SkipHeights(MinDurationBlocks) // height == deadline exactly

	testing.SetRealm(testing.NewUserRealm(backerA))
	testing.SetOriginSend(ugnot(1000))
	testing.IssueCoins(Address(), ugnot(1000))
	uassert.AbortsWithMessage(t, cur, "funding is closed", func() {
		Pledge(cross(cur), id)
	})
	testing.SetOriginSend(nil)

	// Unpledge is likewise closed at the deadline (the failed path is
	// Refund's).
	testing.SetRealm(testing.NewUserRealm(backerA))
	uassert.AbortsWithMessage(t, cur,
		"funding is closed; use Refund if the campaign failed",
		func() { Unpledge(cross(cur), id) })

	// Failed (0 < goal) and past deadline: refunds open, nothing to pay.
	uassert.True(t, IsRefundable(id))
	uassert.Equal(t, "failed (refunds open)", Status(id))

	testing.SetRealm(testing.NewUserRealm(creator1))
	CreatorCancel(cross(cur), id)
}

// --- unpledge ---

func TestUnpledgeReturnsWholePledge(cur realm, t *testing.T) {
	b := begin()
	id := launchAs(cur, creator1, "unpledge case")
	pledgeAs(cur, backerA, id, 300_000)

	walletBefore := balanceOf(backerA)
	testing.SetRealm(testing.NewUserRealm(backerA))
	Unpledge(cross(cur), id)

	uassert.Equal(t, walletBefore+300_000, balanceOf(backerA))
	uassert.Equal(t, int64(0), PledgeOf(id, backerA))
	uassert.Equal(t, b.backed, TotalBacked())
	uassert.Equal(t, b.held, Held())

	// Nothing left to unpledge.
	testing.SetRealm(testing.NewUserRealm(backerA))
	uassert.AbortsWithMessage(t, cur, "no pledge to return", func() {
		Unpledge(cross(cur), id)
	})
	testing.SetRealm(testing.NewUserRealm(creator1))
	CreatorCancel(cross(cur), id)
}

// --- claim ---

func TestClaimPaysCreatorMinusFee(cur realm, t *testing.T) {
	b := begin()
	id := launchAs(cur, creator1, "funded project")
	pledgeAs(cur, backerA, id, 900_000)
	pledgeAs(cur, backerB, id, 350_000) // raised 1_250_000 >= goal 1_000_000

	testing.SkipHeights(MinDurationBlocks)
	uassert.Equal(t, "succeeded (awaiting creator claim)", Status(id))
	uassert.False(t, IsRefundable(id)) // the pot is the creator's to collect

	// A backer cannot refund out of a succeeded campaign in-window.
	testing.SetRealm(testing.NewUserRealm(backerA))
	uassert.AbortsWithMessage(t, cur, "campaign is not refundable", func() {
		Refund(cross(cur), id)
	})

	// Only the creator may claim.
	testing.SetRealm(testing.NewUserRealm(mallory))
	uassert.AbortsWithMessage(t, cur, "creator only", func() {
		CreatorClaim(cross(cur), id)
	})

	walletBefore := balanceOf(creator1)
	openBefore := OpenCampaigns()
	testing.SetRealm(testing.NewUserRealm(creator1))
	CreatorClaim(cross(cur), id)

	// fee = floor(1_250_000 * 100 / 10_000) = 12_500; credited the rest.
	uassert.Equal(t, walletBefore+1_237_500, balanceOf(creator1))
	uassert.Equal(t, b.fees+12_500, FeesAccrued())
	uassert.Equal(t, b.backed, TotalBacked())
	uassert.Equal(t, statePaid, Status(id))
	uassert.Equal(t, openBefore-1, OpenCampaigns())
	uassert.Equal(t, int64(0), OpenOf(creator1))

	// The pledge table is dropped; the final backer count is frozen.
	uassert.Equal(t, int64(0), PledgeOf(id, backerA))
	_, _, raised, _, _, _, _, backers, state := CampaignInfo(id)
	uassert.Equal(t, int64(0), raised)
	uassert.Equal(t, 2, backers)
	uassert.Equal(t, statePaid, state)

	// Settlement is exactly-once: the deferral is consumed.
	testing.SetRealm(testing.NewUserRealm(creator1))
	uassert.AbortsWithMessage(t, cur, "campaign is settled", func() {
		CreatorClaim(cross(cur), id)
	})
	// Conservation: H gained the fee, B is flat, the payout left.
	uassert.Equal(t, b.held+12_500, Held())
	uassert.True(t, Held() >= Liabilities())
}

func TestClaimFeeRoundingFavorsCreator(cur realm, t *testing.T) {
	b := begin()
	testing.SetRealm(testing.NewUserRealm(creator1))
	id := Launch(cross(cur), "rounding case", "", MinGoal, MinDurationBlocks)
	// 1_000_050 at 100 bps: exact fee 10_000.5 -> floor 10_000.
	pledgeAs(cur, backerA, id, 1_000_050)
	testing.SkipHeights(MinDurationBlocks)

	walletBefore := balanceOf(creator1)
	testing.SetRealm(testing.NewUserRealm(creator1))
	CreatorClaim(cross(cur), id)
	uassert.Equal(t, walletBefore+990_050, balanceOf(creator1))
	uassert.Equal(t, b.fees+10_000, FeesAccrued())
}

func TestClaimGoalNotReached(cur realm, t *testing.T) {
	begin()
	id := launchAs(cur, creator1, "underfunded")
	pledgeAs(cur, backerA, id, MinGoal-1)
	testing.SkipHeights(MinDurationBlocks)

	testing.SetRealm(testing.NewUserRealm(creator1))
	uassert.AbortsWithMessage(t, cur, "goal not reached", func() {
		CreatorClaim(cross(cur), id)
	})

	// The failed pot is refundable immediately — no settlement needed.
	uassert.True(t, IsRefundable(id))
	testing.SetRealm(testing.NewUserRealm(backerA))
	Refund(cross(cur), id)
	testing.SetRealm(testing.NewUserRealm(mallory))
	SettleFailed(cross(cur), id) // anyone closes it out; slot freed
}

func TestClaimTimingIsTheDuebooksVerdict(cur realm, t *testing.T) {
	begin()
	id := launchAs(cur, creator1, "timing case")
	pledgeAs(cur, backerA, id, MinGoal)

	// Before the deadline: the duebook refuses, and on-chain the whole
	// transaction would revert. In the test VM the abort does not roll
	// back realm globals, but MustClaim aborts BEFORE this realm writes
	// any state, so the campaign is observably untouched either way —
	// asserted below.
	testing.SetRealm(testing.NewUserRealm(creator1))
	uassert.AbortsWithMessage(t, cur, "duebook: not due yet", func() {
		CreatorClaim(cross(cur), id)
	})
	uassert.Equal(t, stateFunding, Status(id)) // still funding, untouched
	uassert.Equal(t, MinGoal, PledgeOf(id, backerA))

	// Past the claim window: expired, the creator's authorization died.
	testing.SkipHeights(MinDurationBlocks + ClaimWindowBlocks)
	testing.SetRealm(testing.NewUserRealm(creator1))
	uassert.AbortsWithMessage(t, cur, "duebook: deferral has expired", func() {
		CreatorClaim(cross(cur), id)
	})

	// Which is exactly when Lapse starts working — by anyone.
	testing.SetRealm(testing.NewUserRealm(mallory))
	Lapse(cross(cur), id)
	uassert.Equal(t, stateLapsed, Status(id))
	uassert.True(t, IsRefundable(id))

	testing.SetRealm(testing.NewUserRealm(backerA))
	Refund(cross(cur), id)
}

// --- settle-failed (audit Y1 remediation) ---

func TestSettleFailedFreesTheSlotAtTheDeadline(cur realm, t *testing.T) {
	begin()
	id := launchAs(cur, creator1, "doomed project")
	pledgeAs(cur, backerA, id, MinGoal-10_000)

	// Not before the deadline — the timing verdict is the duebook's.
	testing.SetRealm(testing.NewUserRealm(mallory))
	uassert.AbortsWithMessage(t, cur, "duebook: not due yet", func() {
		SettleFailed(cross(cur), id)
	})

	testing.SkipHeights(MinDurationBlocks)
	openBefore := OpenCampaigns()
	uassert.Equal(t, int64(1), OpenOf(creator1))

	// Anyone may settle a failed campaign the moment it is due.
	testing.SetRealm(testing.NewUserRealm(mallory))
	SettleFailed(cross(cur), id)
	uassert.Equal(t, stateFailed, Status(id))
	uassert.Equal(t, openBefore-1, OpenCampaigns()) // duebook slot freed
	uassert.Equal(t, int64(0), OpenOf(creator1))    // creator slot freed
	uassert.True(t, IsRefundable(id))

	// Settlement is exactly-once here too.
	testing.SetRealm(testing.NewUserRealm(mallory))
	uassert.AbortsWithMessage(t, cur, "campaign is settled", func() {
		SettleFailed(cross(cur), id)
	})
	// And the creator cannot claim a settled campaign.
	testing.SetRealm(testing.NewUserRealm(creator1))
	uassert.AbortsWithMessage(t, cur, "campaign is settled", func() {
		CreatorClaim(cross(cur), id)
	})

	// Refunds work exactly as on the un-settled failed path, and the
	// drained record is prunable.
	walletBefore := balanceOf(backerA)
	testing.SetRealm(testing.NewUserRealm(backerA))
	Refund(cross(cur), id)
	uassert.Equal(t, walletBefore+MinGoal-10_000, balanceOf(backerA))
	testing.SetRealm(testing.NewUserRealm(mallory))
	Prune(cross(cur), id)
}

func TestSettleFailedExpiresIntoLapse(cur realm, t *testing.T) {
	begin()
	id := launchAs(cur, creator1, "never settled")
	pledgeAs(cur, backerA, id, MinPledge)
	testing.SkipHeights(MinDurationBlocks + ClaimWindowBlocks)

	// Past the claim window the deferral is expired: SettleFailed's
	// path is gone (the primitive's verdict) and Lapse is the valve —
	// which is exactly what the campaign page now advises (audit G1).
	page := Render(itoa(id))
	uassert.True(t, strings.Contains(page, "Lapse("+itoa(id)+")"))
	uassert.False(t, strings.Contains(page, "SettleFailed("))

	testing.SetRealm(testing.NewUserRealm(mallory))
	uassert.AbortsWithMessage(t, cur, "duebook: deferral has expired", func() {
		SettleFailed(cross(cur), id)
	})
	testing.SetRealm(testing.NewUserRealm(mallory))
	Lapse(cross(cur), id)
	uassert.Equal(t, stateLapsed, Status(id))
	testing.SetRealm(testing.NewUserRealm(backerA))
	Refund(cross(cur), id)
}

func TestSettleFailedRefusesAMetGoal(cur realm, t *testing.T) {
	begin()
	id := launchAs(cur, creator1, "funded, not failed")
	pledgeAs(cur, backerA, id, MinGoal)
	testing.SkipHeights(MinDurationBlocks)

	testing.SetRealm(testing.NewUserRealm(mallory))
	uassert.AbortsWithMessage(t, cur,
		"goal reached; the claim window is the creator's",
		func() { SettleFailed(cross(cur), id) })

	testing.SetRealm(testing.NewUserRealm(creator1))
	CreatorClaim(cross(cur), id)
}

// --- cancel ---

func TestCancelOpensRefunds(cur realm, t *testing.T) {
	b := begin()
	id := launchAs(cur, creator1, "cancelled project")
	pledgeAs(cur, backerA, id, 600_000)

	// Mallory cannot cancel someone else's campaign.
	testing.SetRealm(testing.NewUserRealm(mallory))
	uassert.AbortsWithMessage(t, cur, "creator only", func() {
		CreatorCancel(cross(cur), id)
	})

	testing.SetRealm(testing.NewUserRealm(creator1))
	CreatorCancel(cross(cur), id)
	uassert.Equal(t, stateCancelled, Status(id))
	uassert.True(t, IsRefundable(id))

	// Cancelling twice: the deferral is gone, the state says so first.
	testing.SetRealm(testing.NewUserRealm(creator1))
	uassert.AbortsWithMessage(t, cur, "campaign is settled", func() {
		CreatorCancel(cross(cur), id)
	})

	walletBefore := balanceOf(backerA)
	testing.SetRealm(testing.NewUserRealm(backerA))
	Refund(cross(cur), id)
	uassert.Equal(t, walletBefore+600_000, balanceOf(backerA))
	uassert.Equal(t, b.backed, TotalBacked())
	uassert.Equal(t, b.fees, FeesAccrued()) // refunds are fee-free
}

func TestCancelAfterSuccessRenouncesThePot(cur realm, t *testing.T) {
	begin()
	id := launchAs(cur, creator1, "renounced project")
	pledgeAs(cur, backerA, id, MinGoal)
	testing.SkipHeights(MinDurationBlocks)
	uassert.Equal(t, "succeeded (awaiting creator claim)", Status(id))

	testing.SetRealm(testing.NewUserRealm(creator1))
	CreatorCancel(cross(cur), id)
	uassert.True(t, IsRefundable(id))
	testing.SetRealm(testing.NewUserRealm(backerA))
	Refund(cross(cur), id)
	uassert.Equal(t, int64(0), PledgeOf(id, backerA))
}

// --- lapse ---

func TestLapseRefusesWhileClaimWindowIsOpen(cur realm, t *testing.T) {
	begin()
	id := launchAs(cur, creator1, "lapse timing")
	pledgeAs(cur, backerA, id, MinGoal)
	testing.SkipHeights(MinDurationBlocks) // due, but window open

	testing.SetRealm(testing.NewUserRealm(mallory))
	uassert.AbortsWithMessage(t, cur, "duebook: deferral has not expired", func() {
		Lapse(cross(cur), id)
	})

	testing.SkipHeights(ClaimWindowBlocks)
	testing.SetRealm(testing.NewUserRealm(mallory))
	Lapse(cross(cur), id)
	uassert.Equal(t, stateLapsed, Status(id))

	testing.SetRealm(testing.NewUserRealm(mallory))
	uassert.AbortsWithMessage(t, cur, "campaign is settled", func() {
		Lapse(cross(cur), id)
	})
	testing.SetRealm(testing.NewUserRealm(backerA))
	Refund(cross(cur), id)
}

// --- refund guards ---

func TestRefundGuards(cur realm, t *testing.T) {
	begin()
	id := launchAs(cur, creator1, "refund guards")
	pledgeAs(cur, backerA, id, 100_000)

	// Not refundable while funding is open.
	testing.SetRealm(testing.NewUserRealm(backerA))
	uassert.AbortsWithMessage(t, cur, "campaign is not refundable", func() {
		Refund(cross(cur), id)
	})

	testing.SetRealm(testing.NewUserRealm(creator1))
	CreatorCancel(cross(cur), id)

	// A stranger with no pledge gets nothing.
	testing.SetRealm(testing.NewUserRealm(mallory))
	uassert.AbortsWithMessage(t, cur, "no pledge to return", func() {
		Refund(cross(cur), id)
	})

	// The backer refunds once, then has nothing left.
	testing.SetRealm(testing.NewUserRealm(backerA))
	Refund(cross(cur), id)
	testing.SetRealm(testing.NewUserRealm(backerA))
	uassert.AbortsWithMessage(t, cur, "no pledge to return", func() {
		Refund(cross(cur), id)
	})
}

// --- prune ---

func TestPrune(cur realm, t *testing.T) {
	begin()
	id := launchAs(cur, creator1, "prunable")
	pledgeAs(cur, backerA, id, 50_000)

	// Not while unsettled.
	testing.SetRealm(testing.NewUserRealm(mallory))
	uassert.AbortsWithMessage(t, cur, "campaign is not settled", func() {
		Prune(cross(cur), id)
	})

	testing.SetRealm(testing.NewUserRealm(creator1))
	CreatorCancel(cross(cur), id)

	// Not while backer funds remain.
	testing.SetRealm(testing.NewUserRealm(mallory))
	uassert.AbortsWithMessage(t, cur, "campaign still holds backer funds", func() {
		Prune(cross(cur), id)
	})

	testing.SetRealm(testing.NewUserRealm(backerA))
	Refund(cross(cur), id)

	nBefore := NumCampaigns()
	testing.SetRealm(testing.NewUserRealm(mallory))
	Prune(cross(cur), id)
	uassert.Equal(t, nBefore, NumCampaigns()) // ids are never reused
	testing.SetRealm(testing.NewUserRealm(mallory))
	uassert.AbortsWithMessage(t, cur, "unknown campaign id", func() {
		Prune(cross(cur), id)
	})
	uassert.PanicsWithMessage(t, cur, "unknown campaign id", func() {
		CampaignInfo(id)
	})
}

// --- fees and surplus ---

func TestWithdrawFees(cur realm, t *testing.T) {
	b := begin()
	if b.fees == 0 {
		// Accrue a fee: fund and claim a campaign.
		id := launchAs(cur, creator1, "fee source")
		pledgeAs(cur, backerA, id, MinGoal)
		testing.SkipHeights(MinDurationBlocks)
		testing.SetRealm(testing.NewUserRealm(creator1))
		CreatorClaim(cross(cur), id)
	}
	fees := FeesAccrued()
	uassert.True(t, fees > 0)

	collectorBefore := balanceOf(FeeCollector)
	testing.SetRealm(testing.NewUserRealm(mallory)) // anyone may trigger
	got := WithdrawFees(cross(cur))
	uassert.Equal(t, fees, got)
	uassert.Equal(t, collectorBefore+fees, balanceOf(FeeCollector))
	uassert.Equal(t, int64(0), FeesAccrued())

	testing.SetRealm(testing.NewUserRealm(mallory))
	uassert.AbortsWithMessage(t, cur, "no fees accrued", func() {
		WithdrawFees(cross(cur))
	})
}

func TestSweepSurplus(cur realm, t *testing.T) {
	begin()
	// No surplus: coinio refuses.
	testing.SetRealm(testing.NewUserRealm(mallory))
	uassert.AbortsWithMessage(t, cur, "coinio: no surplus to sweep for ugnot", func() {
		SweepSurplus(cross(cur), Denom)
	})

	// Force-send 33_000 ugnot out-of-band, then sweep it.
	testing.IssueCoins(Address(), ugnot(33_000))
	liabBefore := Liabilities()
	collectorBefore := balanceOf(FeeCollector)
	testing.SetRealm(testing.NewUserRealm(mallory))
	swept := SweepSurplus(cross(cur), Denom)
	uassert.Equal(t, int64(33_000), swept)
	uassert.Equal(t, collectorBefore+33_000, balanceOf(FeeCollector))
	uassert.Equal(t, liabBefore, Liabilities()) // tracked money untouched

	// A foreign denomination sweeps in full.
	testing.IssueCoins(Address(), chain.NewCoins(chain.NewCoin("foocoin", 4_200)))
	testing.SetRealm(testing.NewUserRealm(mallory))
	uassert.Equal(t, int64(4_200), SweepSurplus(cross(cur), "foocoin"))
}

// --- stray sends ---

func TestNonPayableEntrypointsRejectCoins(cur realm, t *testing.T) {
	begin()
	id := launchAs(cur, creator1, "stray send case")

	cases := []func(){
		func() { Launch(cross(cur), "t", "", MinGoal, MinDurationBlocks) },
		func() { Unpledge(cross(cur), id) },
		func() { CreatorClaim(cross(cur), id) },
		func() { CreatorCancel(cross(cur), id) },
		func() { SettleFailed(cross(cur), id) },
		func() { Lapse(cross(cur), id) },
		func() { Refund(cross(cur), id) },
		func() { Prune(cross(cur), id) },
		func() { WithdrawFees(cross(cur)) },
		func() { SweepSurplus(cross(cur), Denom) },
	}
	for _, call := range cases {
		testing.SetRealm(testing.NewUserRealm(mallory))
		testing.SetOriginSend(ugnot(1))
		uassert.AbortsWithMessage(t, cur, "this entrypoint does not accept coins", call)
	}
	testing.SetOriginSend(nil)
	testing.SetRealm(testing.NewUserRealm(creator1))
	CreatorCancel(cross(cur), id)
}

// --- render ---

func TestRenderIndexAndCampaign(cur realm, t *testing.T) {
	begin()
	// A hostile title must come out of the sanitizer defanged.
	hostile := "[evil](https://x) <script>alert(1)</script>"
	testing.SetRealm(testing.NewUserRealm(creator1))
	id := Launch(cross(cur), hostile, "memo with [link](x) inside", MinGoal, MinDurationBlocks)

	index := Render("")
	uassert.True(t, strings.Contains(index, "# Crowdfund"))
	uassert.True(t, strings.Contains(index, "conservation: OK"))
	uassert.False(t, strings.Contains(index, "<script>"))

	page := Render(itoa(id))
	uassert.True(t, strings.Contains(page, "status: **funding**"))
	uassert.True(t, strings.Contains(page, "0%"))
	uassert.False(t, strings.Contains(page, "<script>"))
	uassert.False(t, strings.Contains(page, "[evil](https://x)"))
	uassert.False(t, strings.Contains(page, "[link](x)"))

	uassert.True(t, strings.Contains(Render("notanumber"), "invalid campaign id"))
	uassert.True(t, strings.Contains(Render("999999"), "unknown campaign id"))

	testing.SetRealm(testing.NewUserRealm(creator1))
	CreatorCancel(cross(cur), id)
}

func TestPercentAndBps(t *testing.T) {
	uassert.Equal(t, "0%", percent(0, MinGoal))
	uassert.Equal(t, "50%", percent(500_000, MinGoal))
	uassert.Equal(t, "99%", percent(999_999, MinGoal))
	uassert.Equal(t, "100%", percent(MinGoal, MinGoal))
	uassert.Equal(t, "250%", percent(2_500_000, MinGoal))
	// The overflow-guard branch: r*100 would not fit in int64. Three
	// quarters of 2^62 is exactly 75%, and the scaled form lands on it.
	huge := int64(1) << 62
	uassert.Equal(t, "75%", percent(3*(huge/4), huge))

	uassert.Equal(t, "1%", bps(100))
	uassert.Equal(t, "5%", bps(500))
	uassert.Equal(t, "0.5%", bps(50))
	uassert.Equal(t, "0.01%", bps(1))
	uassert.Equal(t, "2.25%", bps(225))
}
