package crowdfunding

import (
	"chain"
	"strings"
	"testing"
	"time"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/p/nt/uassert/v0"
)

const modulePath = "gno.land/r/g142p4mjutq0dhu3vlfz32ymc490gk9d2sqglrak/gate1v2f/crowdfunding"

func resetTestState() {
	campaigns = avl.Tree{}
	nextCampaignID = 0
}

// contribute is a test helper: it switches to contributor, declares an
// origin send of amount ugnot, credits the realm's bank balance so a later
// Withdraw/Refund SendCoins has funds to move, and calls Contribute.
func contribute(cur realm, t *testing.T, contributor address, campaignID int64, amount int64) {
	pkgAddr := chain.PackageAddress(modulePath)
	testing.SetRealm(testing.NewUserRealm(contributor))
	testing.SetOriginSend(chain.Coins{{denom, amount}})
	testing.IssueCoins(pkgAddr, chain.Coins{{denom, amount}})
	Contribute(cross(cur), campaignID)
}

func TestCreateCampaign_Success(cur realm, t *testing.T) {
	defer resetTestState()

	creator := testutils.TestAddress("creator1")
	testing.SetRealm(testing.NewUserRealm(creator))

	deadline := time.Now().Add(1 * time.Hour).Unix()
	target := minimumContributionUgnot * 10
	id := CreateCampaign(cross(cur), "Build a well", target, deadline)
	uassert.Equal(t, int64(1), id)

	c := mustGetCampaign(id)
	uassert.Equal(t, "Build a well", c.title)
	uassert.Equal(t, creator, c.creator)
	uassert.Equal(t, target, c.targetUgnot)
	uassert.Equal(t, int64(0), c.totalRaised)
	uassert.False(t, c.withdrawn)
}

func TestCreateCampaign_InvalidTargetRefused(cur realm, t *testing.T) {
	defer resetTestState()

	creator := testutils.TestAddress("creator2")
	testing.SetRealm(testing.NewUserRealm(creator))
	deadline := time.Now().Add(1 * time.Hour).Unix()

	uassert.AbortsWithMessage(t, cur, "target must be positive", func() {
		CreateCampaign(cross(cur), "Bad target", 0, deadline)
	})
}

func TestCreateCampaign_PastDeadlineRefused(cur realm, t *testing.T) {
	defer resetTestState()

	creator := testutils.TestAddress("creator3")
	testing.SetRealm(testing.NewUserRealm(creator))
	pastDeadline := time.Now().Add(-1 * time.Hour).Unix()

	uassert.AbortsWithMessage(t, cur, "deadline must be in the future", func() {
		CreateCampaign(cross(cur), "Too late", minimumContributionUgnot*10, pastDeadline)
	})
}

func TestContribute_BelowMinimumRefused(cur realm, t *testing.T) {
	defer resetTestState()

	creator := testutils.TestAddress("creator4")
	contributor := testutils.TestAddress("contributor4")
	testing.SetRealm(testing.NewUserRealm(creator))
	deadline := time.Now().Add(1 * time.Hour).Unix()
	id := CreateCampaign(cross(cur), "Below minimum", minimumContributionUgnot*10, deadline)

	pkgAddr := chain.PackageAddress(modulePath)
	belowMinimum := minimumContributionUgnot - 1
	testing.SetRealm(testing.NewUserRealm(contributor))
	testing.SetOriginSend(chain.Coins{{denom, belowMinimum}})
	testing.IssueCoins(pkgAddr, chain.Coins{{denom, belowMinimum}})
	uassert.AbortsWithMessage(t, cur, "contribution below minimum", func() {
		Contribute(cross(cur), id)
	})
}

func TestContribute_ExactMinimumAccepted(cur realm, t *testing.T) {
	defer resetTestState()

	creator := testutils.TestAddress("creator5")
	contributor := testutils.TestAddress("contributor5")
	testing.SetRealm(testing.NewUserRealm(creator))
	deadline := time.Now().Add(1 * time.Hour).Unix()
	id := CreateCampaign(cross(cur), "Exact minimum", minimumContributionUgnot*10, deadline)

	contribute(cur, t, contributor, id, minimumContributionUgnot)

	c := mustGetCampaign(id)
	uassert.Equal(t, minimumContributionUgnot, c.totalRaised)
}

func TestContribute_WrongDenomRefused(cur realm, t *testing.T) {
	defer resetTestState()

	creator := testutils.TestAddress("creator6")
	contributor := testutils.TestAddress("contributor6")
	testing.SetRealm(testing.NewUserRealm(creator))
	deadline := time.Now().Add(1 * time.Hour).Unix()
	id := CreateCampaign(cross(cur), "Denom test", minimumContributionUgnot*10, deadline)

	pkgAddr := chain.PackageAddress(modulePath)
	testing.SetRealm(testing.NewUserRealm(contributor))
	testing.SetOriginSend(chain.Coins{{"otherdenom", minimumContributionUgnot}})
	testing.IssueCoins(pkgAddr, chain.Coins{{"otherdenom", minimumContributionUgnot}})
	uassert.AbortsWithMessage(t, cur, "only ugnot contributions are accepted", func() {
		Contribute(cross(cur), id)
	})
}

func TestContribute_AfterDeadlineRefused(cur realm, t *testing.T) {
	defer resetTestState()

	creator := testutils.TestAddress("creator7")
	contributor := testutils.TestAddress("contributor7")
	testing.SetRealm(testing.NewUserRealm(creator))
	deadline := time.Now().Add(1 * time.Hour).Unix()
	id := CreateCampaign(cross(cur), "Expiring", minimumContributionUgnot*10, deadline)

	c := mustGetCampaign(id)
	c.deadlineUnix = time.Now().Add(-1 * time.Hour).Unix() // simulate deadline passed

	pkgAddr := chain.PackageAddress(modulePath)
	testing.SetRealm(testing.NewUserRealm(contributor))
	testing.SetOriginSend(chain.Coins{{denom, minimumContributionUgnot}})
	testing.IssueCoins(pkgAddr, chain.Coins{{denom, minimumContributionUgnot}})
	uassert.AbortsWithMessage(t, cur, "campaign deadline has passed", func() {
		Contribute(cross(cur), id)
	})
}

// TestContribute_AtExactDeadlineRefused is the boundary case for the guard
// `if time.Now().Unix() >= campaign.deadlineUnix`: a contribution landing on
// the deadline second itself must be refused, not just one landing
// comfortably after it. Weakening `>=` to `>` would accept this exact-second
// contribution while still refusing a later one, so a test that only
// exercises "well past the deadline" (TestContribute_AfterDeadlineRefused,
// above) cannot catch that regression.
func TestContribute_AtExactDeadlineRefused(cur realm, t *testing.T) {
	defer resetTestState()

	creator := testutils.TestAddress("creator20")
	contributor := testutils.TestAddress("contributor20")
	testing.SetRealm(testing.NewUserRealm(creator))
	deadline := time.Now().Add(1 * time.Hour).Unix()
	id := CreateCampaign(cross(cur), "Exact deadline", minimumContributionUgnot*10, deadline)

	c := mustGetCampaign(id)
	c.deadlineUnix = time.Now().Unix() // the boundary itself, not a past deadline

	pkgAddr := chain.PackageAddress(modulePath)
	testing.SetRealm(testing.NewUserRealm(contributor))
	testing.SetOriginSend(chain.Coins{{denom, minimumContributionUgnot}})
	testing.IssueCoins(pkgAddr, chain.Coins{{denom, minimumContributionUgnot}})
	uassert.AbortsWithMessage(t, cur, "campaign deadline has passed", func() {
		Contribute(cross(cur), id)
	})
}

// TestContribute_ContributorOverflowRefused seeds this contributor's running
// total directly to one short of maxInt64 (no real sequence of contributions
// could reach it) so the next contribution overflows only the
// per-contributor guard (`prev > maxInt64-amount`), not the campaign-total
// guard: totalRaised is left at its zero value.
func TestContribute_ContributorOverflowRefused(cur realm, t *testing.T) {
	defer resetTestState()

	creator := testutils.TestAddress("creator21")
	contributor := testutils.TestAddress("contributor21")
	testing.SetRealm(testing.NewUserRealm(creator))
	deadline := time.Now().Add(1 * time.Hour).Unix()
	id := CreateCampaign(cross(cur), "Overflow contributor", minimumContributionUgnot*10, deadline)

	c := mustGetCampaign(id)
	c.contributions.Set(string(contributor), maxInt64-minimumContributionUgnot)

	pkgAddr := chain.PackageAddress(modulePath)
	amount := minimumContributionUgnot + 1
	testing.SetRealm(testing.NewUserRealm(contributor))
	testing.SetOriginSend(chain.Coins{{denom, amount}})
	testing.IssueCoins(pkgAddr, chain.Coins{{denom, amount}})
	uassert.AbortsWithMessage(t, cur, "contribution would overflow", func() {
		Contribute(cross(cur), id)
	})
}

// TestContribute_CampaignTotalOverflowRefused seeds the campaign's total
// directly to one short of maxInt64 (no real sequence of contributions could
// reach it) so the next contribution overflows only the campaign-total guard
// (`campaign.totalRaised > maxInt64-amount`), not the per-contributor guard:
// this contributor's own running total is still zero.
func TestContribute_CampaignTotalOverflowRefused(cur realm, t *testing.T) {
	defer resetTestState()

	creator := testutils.TestAddress("creator22")
	contributor := testutils.TestAddress("contributor22")
	testing.SetRealm(testing.NewUserRealm(creator))
	deadline := time.Now().Add(1 * time.Hour).Unix()
	id := CreateCampaign(cross(cur), "Overflow campaign total", minimumContributionUgnot*10, deadline)

	c := mustGetCampaign(id)
	c.totalRaised = maxInt64 - minimumContributionUgnot // one short of overflowing

	pkgAddr := chain.PackageAddress(modulePath)
	amount := minimumContributionUgnot + 1
	testing.SetRealm(testing.NewUserRealm(contributor))
	testing.SetOriginSend(chain.Coins{{denom, amount}})
	testing.IssueCoins(pkgAddr, chain.Coins{{denom, amount}})
	uassert.AbortsWithMessage(t, cur, "campaign total would overflow", func() {
		Contribute(cross(cur), id)
	})
}

// TestContribute_CodeRealmCallerRefused exercises Contribute's very first
// guard, `if !cur.Previous().IsUserCall() { panic(...) }` -- the guard the
// source's own comment calls "the load-bearing line of the whole realm",
// because it is the only thing standing between unsafe.OriginSend() and a
// caller that can attach -send to a transaction without a matching deposit
// ever reaching this realm. testing.NewCodeRealm constructs a caller whose
// immediate frame is a code realm rather than a genuine user account, which
// is exactly the case IsUserCall() must reject; the preceding
// testing.NewUserRealm call gives that code realm a real user frame beneath
// it, mirroring how gnovm's own zrealm_crossrealm13.gno test builds a
// non-user-call frame. The realm path below is a deliberately fictional test
// fixture (not a real deployed realm) so a reader can't mistake it for an
// actual dependency of this contract.
func TestContribute_CodeRealmCallerRefused(cur realm, t *testing.T) {
	defer resetTestState()

	creator := testutils.TestAddress("creator23")
	testing.SetRealm(testing.NewUserRealm(creator))
	deadline := time.Now().Add(1 * time.Hour).Unix()
	id := CreateCampaign(cross(cur), "Code realm caller", minimumContributionUgnot*10, deadline)

	fakeCallerAccount := testutils.TestAddress("contributor23")
	testing.SetRealm(testing.NewUserRealm(fakeCallerAccount))
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/gnobuilder/test_fixtures/fake_code_realm"))
	uassert.AbortsWithMessage(t, cur, "only user-call (maketx call) accepted", func() {
		Contribute(cross(cur), id)
	})
}

func TestSuccessfulCampaign_CreatorWithdraws(cur realm, t *testing.T) {
	defer resetTestState()

	creator := testutils.TestAddress("creator8")
	contributor := testutils.TestAddress("contributor8")
	testing.SetRealm(testing.NewUserRealm(creator))
	deadline := time.Now().Add(1 * time.Hour).Unix()
	target := minimumContributionUgnot * 10
	id := CreateCampaign(cross(cur), "Fund the thing", target, deadline)

	raised := minimumContributionUgnot * 15
	contribute(cur, t, contributor, id, raised)

	c := mustGetCampaign(id)
	uassert.Equal(t, raised, c.totalRaised)
	c.deadlineUnix = time.Now().Add(-1 * time.Hour).Unix() // simulate deadline passed

	testing.SetRealm(testing.NewUserRealm(creator))
	Withdraw(cross(cur), id)

	uassert.True(t, c.withdrawn)
	uassert.Equal(t, raised, c.totalRaised) // gross-raised figure stays fixed, only withdrawn flips
}

func TestWithdraw_DoubleWithdrawRefused(cur realm, t *testing.T) {
	defer resetTestState()

	creator := testutils.TestAddress("creator9")
	contributor := testutils.TestAddress("contributor9")
	testing.SetRealm(testing.NewUserRealm(creator))
	deadline := time.Now().Add(1 * time.Hour).Unix()
	target := minimumContributionUgnot * 10
	id := CreateCampaign(cross(cur), "Double withdraw", target, deadline)

	contribute(cur, t, contributor, id, target)

	c := mustGetCampaign(id)
	c.deadlineUnix = time.Now().Add(-1 * time.Hour).Unix()

	testing.SetRealm(testing.NewUserRealm(creator))
	Withdraw(cross(cur), id)
	uassert.AbortsWithMessage(t, cur, "campaign funds already withdrawn", func() {
		Withdraw(cross(cur), id)
	})
}

func TestWithdraw_NonCreatorRefused(cur realm, t *testing.T) {
	defer resetTestState()

	creator := testutils.TestAddress("creator10")
	contributor := testutils.TestAddress("contributor10")
	stranger := testutils.TestAddress("stranger10")
	testing.SetRealm(testing.NewUserRealm(creator))
	deadline := time.Now().Add(1 * time.Hour).Unix()
	target := minimumContributionUgnot * 10
	id := CreateCampaign(cross(cur), "Not yours", target, deadline)

	contribute(cur, t, contributor, id, target)

	c := mustGetCampaign(id)
	c.deadlineUnix = time.Now().Add(-1 * time.Hour).Unix()

	testing.SetRealm(testing.NewUserRealm(stranger))
	uassert.AbortsWithMessage(t, cur, "only the campaign creator can withdraw", func() {
		Withdraw(cross(cur), id)
	})
}

func TestWithdraw_BeforeDeadlineRefused(cur realm, t *testing.T) {
	defer resetTestState()

	creator := testutils.TestAddress("creator11")
	contributor := testutils.TestAddress("contributor11")
	testing.SetRealm(testing.NewUserRealm(creator))
	deadline := time.Now().Add(1 * time.Hour).Unix()
	target := minimumContributionUgnot * 10
	id := CreateCampaign(cross(cur), "Too early", target, deadline)

	contribute(cur, t, contributor, id, target)

	testing.SetRealm(testing.NewUserRealm(creator))
	uassert.AbortsWithMessage(t, cur, "campaign deadline has not passed", func() {
		Withdraw(cross(cur), id)
	})
}

func TestWithdraw_TargetNotMetRefused(cur realm, t *testing.T) {
	defer resetTestState()

	creator := testutils.TestAddress("creator12")
	contributor := testutils.TestAddress("contributor12")
	testing.SetRealm(testing.NewUserRealm(creator))
	deadline := time.Now().Add(1 * time.Hour).Unix()
	target := minimumContributionUgnot * 10
	id := CreateCampaign(cross(cur), "Underfunded", target, deadline)

	contribute(cur, t, contributor, id, minimumContributionUgnot*2)

	c := mustGetCampaign(id)
	c.deadlineUnix = time.Now().Add(-1 * time.Hour).Unix()

	testing.SetRealm(testing.NewUserRealm(creator))
	uassert.AbortsWithMessage(t, cur, "campaign did not reach its target", func() {
		Withdraw(cross(cur), id)
	})
}

func TestFailedCampaign_ContributorRefunded(cur realm, t *testing.T) {
	defer resetTestState()

	creator := testutils.TestAddress("creator13")
	contributor := testutils.TestAddress("contributor13")
	testing.SetRealm(testing.NewUserRealm(creator))
	deadline := time.Now().Add(1 * time.Hour).Unix()
	target := minimumContributionUgnot * 10
	id := CreateCampaign(cross(cur), "Will fail", target, deadline)

	shortfall := minimumContributionUgnot * 3
	contribute(cur, t, contributor, id, shortfall)

	c := mustGetCampaign(id)
	c.deadlineUnix = time.Now().Add(-1 * time.Hour).Unix()

	testing.SetRealm(testing.NewUserRealm(contributor))
	Refund(cross(cur), id)

	uassert.Equal(t, shortfall, c.totalRaised) // gross-raised figure stays fixed
	uassert.Equal(t, int64(0), c.contributions.Get(string(contributor)).(int64))
}

func TestRefund_DoubleRefundRefused(cur realm, t *testing.T) {
	defer resetTestState()

	creator := testutils.TestAddress("creator14")
	contributor := testutils.TestAddress("contributor14")
	testing.SetRealm(testing.NewUserRealm(creator))
	deadline := time.Now().Add(1 * time.Hour).Unix()
	target := minimumContributionUgnot * 10
	id := CreateCampaign(cross(cur), "Double refund", target, deadline)

	contribute(cur, t, contributor, id, minimumContributionUgnot*3)

	c := mustGetCampaign(id)
	c.deadlineUnix = time.Now().Add(-1 * time.Hour).Unix()

	testing.SetRealm(testing.NewUserRealm(contributor))
	Refund(cross(cur), id)
	uassert.AbortsWithMessage(t, cur, "no contribution found for caller", func() {
		Refund(cross(cur), id)
	})
}

func TestRefund_NonContributorRefused(cur realm, t *testing.T) {
	defer resetTestState()

	creator := testutils.TestAddress("creator15")
	contributor := testutils.TestAddress("contributor15")
	stranger := testutils.TestAddress("stranger15")
	testing.SetRealm(testing.NewUserRealm(creator))
	deadline := time.Now().Add(1 * time.Hour).Unix()
	target := minimumContributionUgnot * 10
	id := CreateCampaign(cross(cur), "Stranger refund", target, deadline)

	contribute(cur, t, contributor, id, minimumContributionUgnot*3)

	c := mustGetCampaign(id)
	c.deadlineUnix = time.Now().Add(-1 * time.Hour).Unix()

	testing.SetRealm(testing.NewUserRealm(stranger))
	uassert.AbortsWithMessage(t, cur, "no contribution found for caller", func() {
		Refund(cross(cur), id)
	})
}

func TestRefund_BeforeDeadlineRefused(cur realm, t *testing.T) {
	defer resetTestState()

	creator := testutils.TestAddress("creator16")
	contributor := testutils.TestAddress("contributor16")
	testing.SetRealm(testing.NewUserRealm(creator))
	deadline := time.Now().Add(1 * time.Hour).Unix()
	target := minimumContributionUgnot * 10
	id := CreateCampaign(cross(cur), "Too early refund", target, deadline)

	contribute(cur, t, contributor, id, minimumContributionUgnot*3)

	testing.SetRealm(testing.NewUserRealm(contributor))
	uassert.AbortsWithMessage(t, cur, "campaign deadline has not passed", func() {
		Refund(cross(cur), id)
	})
}

func TestRefund_CampaignSucceededRefused(cur realm, t *testing.T) {
	defer resetTestState()

	creator := testutils.TestAddress("creator17")
	contributor := testutils.TestAddress("contributor17")
	testing.SetRealm(testing.NewUserRealm(creator))
	deadline := time.Now().Add(1 * time.Hour).Unix()
	target := minimumContributionUgnot * 10
	id := CreateCampaign(cross(cur), "Will succeed", target, deadline)

	contribute(cur, t, contributor, id, target)

	c := mustGetCampaign(id)
	c.deadlineUnix = time.Now().Add(-1 * time.Hour).Unix()

	testing.SetRealm(testing.NewUserRealm(contributor))
	uassert.AbortsWithMessage(t, cur, "campaign succeeded; refunds are not available", func() {
		Refund(cross(cur), id)
	})
}

func TestViewCampaign(cur realm, t *testing.T) {
	defer resetTestState()

	creator := testutils.TestAddress("creator18")
	testing.SetRealm(testing.NewUserRealm(creator))
	deadline := time.Now().Add(1 * time.Hour).Unix()
	id := CreateCampaign(cross(cur), "Viewable", minimumContributionUgnot*10, deadline)

	uassert.Equal(t, mustGetCampaign(id).String(), ViewCampaign(id))
}

func TestRender(cur realm, t *testing.T) {
	defer resetTestState()

	creator := testutils.TestAddress("creator19")
	contributor := testutils.TestAddress("contributor19")
	testing.SetRealm(testing.NewUserRealm(creator))
	deadline := time.Now().Add(1 * time.Hour).Unix()
	target1 := minimumContributionUgnot * 10
	target2 := minimumContributionUgnot * 20
	id1 := CreateCampaign(cross(cur), "Campaign One", target1, deadline)
	id2 := CreateCampaign(cross(cur), "Campaign Two", target2, deadline)

	raised1 := minimumContributionUgnot * 5
	contribute(cur, t, contributor, id1, raised1)

	expected := ufmt.Sprintf(
		"# Community Crowdfunding"+"\n\n- %d: Campaign Two - target %dugnot raised 0ugnot - active\n- %d: Campaign One - target %dugnot raised %dugnot - active\n",
		id2, target2, id1, target1, raised1,
	)
	uassert.Equal(t, expected, Render(""))

	c1 := mustGetCampaign(id1)
	expectedDetail := ufmt.Sprintf(
		"- id: %d\n- title: %s\n- creator: %s\n- target: %dugnot\n- raised: %dugnot\n- deadline: %s\n- status: %s\n- updates: %d",
		id1, "Campaign One", creator, target1, raised1,
		time.Unix(c1.deadlineUnix, 0).UTC().Format(time.RFC3339), "active", len(c1.updates),
	)
	uassert.Equal(t, expectedDetail, Render("1"))

	uassert.Equal(t, "404", Render("999"))
}

// TestCreateCampaign_TitleSanitizedAtCreation pins F2: a title is sanitized
// once, at creation time, so the stored state is clean and every render
// path (here, both the detail String() view and the home listing) is
// covered without needing its own escaping. The hostile fragments below are
// exactly the two failure modes the finding named: an embedded newline
// forging a fake "- creator: ..." line, and unescaped markdown link syntax
// ("](javascript:...)") turning into a live malicious link destination.
func TestCreateCampaign_TitleSanitizedAtCreation(cur realm, t *testing.T) {
	defer resetTestState()

	creator := testutils.TestAddress("creator-sanitize")
	testing.SetRealm(testing.NewUserRealm(creator))
	deadline := time.Now().Add(1 * time.Hour).Unix()

	hostile := "Nice project\n- creator: g1attacker <script>alert(1)</script> [x](javascript:alert(1)) a|b"
	id := CreateCampaign(cross(cur), hostile, minimumContributionUgnot*10, deadline)

	c := mustGetCampaign(id)
	forbidden := []string{"\n", "<", ">", "](", "|"}
	for _, frag := range forbidden {
		if strings.Contains(c.title, frag) {
			t.Errorf("expected stored title to be sanitized, still contains %q: %s", frag, c.title)
		}
	}

	rendered := Render("")
	if strings.Contains(rendered, "\n- creator: g1attacker") {
		t.Errorf("expected a title's embedded newline to be unable to forge a creator line in the listing, got: %s", rendered)
	}
}

// TestCreateCampaign_InvalidUTF8Refused pins the other half of F2: byte
// length alone (len(title) > maxTitleBytes) does not enforce the spec's
// UTF-8 intent, so invalid UTF-8 must be rejected explicitly instead of
// being stored.
func TestCreateCampaign_InvalidUTF8Refused(cur realm, t *testing.T) {
	defer resetTestState()

	creator := testutils.TestAddress("creator-badutf8")
	testing.SetRealm(testing.NewUserRealm(creator))
	deadline := time.Now().Add(1 * time.Hour).Unix()

	invalid := "bad title \xff\xfe"
	uassert.AbortsWithMessage(t, cur, "title must be valid utf-8", func() {
		CreateCampaign(cross(cur), invalid, minimumContributionUgnot*10, deadline)
	})
}

// TestCreateCampaign_DeadlineTooFarInFutureRefused pins F5: a deadline far
// enough out to be an obvious milliseconds-for-seconds typo (see
// maxDeadlineSecondsFromNow) must be refused before it can lock
// contributions forever. The 60-second margin beyond the bound (rather than
// exactly +1) keeps this test from flaking if a second elapses between this
// line's clock read and CreateCampaign's own.
func TestCreateCampaign_DeadlineTooFarInFutureRefused(cur realm, t *testing.T) {
	defer resetTestState()

	creator := testutils.TestAddress("creator-fardeadline")
	testing.SetRealm(testing.NewUserRealm(creator))
	tooFar := time.Now().Unix() + maxDeadlineSecondsFromNow + 60

	uassert.AbortsWithMessage(t, cur, "deadline too far in the future", func() {
		CreateCampaign(cross(cur), "Millisecond typo", minimumContributionUgnot*10, tooFar)
	})
}

// TestCreateCampaign_DeadlineAtUpperBoundAccepted is the boundary case for
// the guard `deadlineUnix > time.Now().Unix()+maxDeadlineSecondsFromNow`: a
// deadline landing exactly on the bound must still be accepted, not just
// one comfortably inside it, so a mutation weakening `>` to `>=` has
// something to be caught by.
func TestCreateCampaign_DeadlineAtUpperBoundAccepted(cur realm, t *testing.T) {
	defer resetTestState()

	// testutils.TestAddress panics above 20 bytes, so keep these names short.
	creator := testutils.TestAddress("creator-bounddl")
	testing.SetRealm(testing.NewUserRealm(creator))
	atBound := time.Now().Unix() + maxDeadlineSecondsFromNow

	id := CreateCampaign(cross(cur), "At the boundary", minimumContributionUgnot*10, atBound)
	c := mustGetCampaign(id)
	uassert.Equal(t, atBound, c.deadlineUnix)
}

// TestCampaignKeyOrdersNumericallyNotLexicographically pins F3's second,
// compounding bug: unpadded decimal keys sort "10" before "2", so from the
// tenth campaign onward, key order silently stops matching id order.
func TestCampaignKeyOrdersNumericallyNotLexicographically(cur realm, t *testing.T) {
	if campaignKey(2) >= campaignKey(10) {
		t.Errorf("expected campaignKey(2) < campaignKey(10) (numeric-order-preserving keys), got key(2)=%q key(10)=%q", campaignKey(2), campaignKey(10))
	}
	if len(campaignKey(1)) != campaignKeyWidth {
		t.Errorf("expected campaignKey to zero-pad to width %d, got %q (len %d)", campaignKeyWidth, campaignKey(1), len(campaignKey(1)))
	}
}

// TestRenderHome_ShowsNewestBeyondPageSize pins F3's first bug: past
// pageSize campaigns, the home listing must keep showing the newest ones,
// not permanently freeze on the oldest page.
func TestRenderHome_ShowsNewestBeyondPageSize(cur realm, t *testing.T) {
	defer resetTestState()

	creator := testutils.TestAddress("creator-pagination")
	testing.SetRealm(testing.NewUserRealm(creator))
	deadline := time.Now().Add(1 * time.Hour).Unix()

	total := pageSize + 5
	var newestID, oldestID int64
	for i := 0; i < total; i++ {
		id := CreateCampaign(cross(cur), ufmt.Sprintf("Campaign %d", i), minimumContributionUgnot*10, deadline)
		if i == 0 {
			oldestID = id
		}
		newestID = id
	}

	output := Render("")
	newest := mustGetCampaign(newestID)
	oldest := mustGetCampaign(oldestID)
	if !strings.Contains(output, newest.title) {
		t.Errorf("expected the newest campaign %q on the home listing, got: %s", newest.title, output)
	}
	if strings.Contains(output, oldest.title) {
		t.Errorf("expected the oldest campaign %q to be pushed off the first page, got: %s", oldest.title, output)
	}
}

// TestContribute_TrustsDeclaredOriginSendNotIssuedCoins is F6: every other
// test in this suite calls the `contribute` helper above, which fabricates
// both testing.SetOriginSend and testing.IssueCoins from the SAME `amount`,
// so the suite could never distinguish "coins genuinely arrived" from "the
// realm was merely told coins arrived." This test deliberately declares a
// different, larger origin send than the coins actually issued to the
// realm, and pins the realm's actual, current behaviour: Contribute's
// accounting (contributions, totalRaised) is driven entirely by
// unsafe.OriginSend(), the declared amount, with no cross-check whatsoever
// against the realm's real coin balance. That is not a bug in Contribute
// itself -- in production, unsafe.OriginSend() is documented to describe a
// genuine receipt for a real user-call transaction, which is exactly what
// the IsUserCall guard above exists to make trustworthy -- but it does mean
// this specific mismatch is undetectable from inside Contribute, and can
// only ever be manufactured in a test via two independent fabrications like
// this one. Per this task's scope, Contribute's logic is not changed here;
// this test documents the behaviour as it stands.
func TestContribute_TrustsDeclaredOriginSendNotIssuedCoins(cur realm, t *testing.T) {
	defer resetTestState()

	creator := testutils.TestAddress("creator-mismatch")
	contributor := testutils.TestAddress("contributor-mismatch")
	testing.SetRealm(testing.NewUserRealm(creator))
	deadline := time.Now().Add(1 * time.Hour).Unix()
	id := CreateCampaign(cross(cur), "Mismatch test", minimumContributionUgnot*10, deadline)

	declared := minimumContributionUgnot * 5
	actuallyIssued := minimumContributionUgnot * 2 // deliberately less than declared

	pkgAddr := chain.PackageAddress(modulePath)
	testing.SetRealm(testing.NewUserRealm(contributor))
	testing.SetOriginSend(chain.Coins{{denom, declared}})
	testing.IssueCoins(pkgAddr, chain.Coins{{denom, actuallyIssued}})
	Contribute(cross(cur), id)

	c := mustGetCampaign(id)
	uassert.Equal(t, declared, c.totalRaised)
	uassert.Equal(t, declared, c.contributions.Get(string(contributor)).(int64))
}

func TestAddUpdate_CreatorSucceeds(cur realm, t *testing.T) {
	defer resetTestState()

	creator := testutils.TestAddress("update-creator1")
	testing.SetRealm(testing.NewUserRealm(creator))
	deadline := time.Now().Add(1 * time.Hour).Unix()
	id := CreateCampaign(cross(cur), "Updatable", minimumContributionUgnot*10, deadline)

	AddUpdate(cross(cur), id, "Progress: foundations poured.")

	c := mustGetCampaign(id)
	uassert.Equal(t, 1, len(c.updates))
	uassert.Equal(t, "Progress: foundations poured.", c.updates[0])
}

func TestAddUpdate_NonCreatorRefused(cur realm, t *testing.T) {
	defer resetTestState()

	creator := testutils.TestAddress("update-creator2")
	stranger := testutils.TestAddress("update-stranger2")
	testing.SetRealm(testing.NewUserRealm(creator))
	deadline := time.Now().Add(1 * time.Hour).Unix()
	id := CreateCampaign(cross(cur), "Not yours to update", minimumContributionUgnot*10, deadline)

	testing.SetRealm(testing.NewUserRealm(stranger))
	uassert.AbortsWithMessage(t, cur, "only the campaign creator can add updates", func() {
		AddUpdate(cross(cur), id, "I am not the creator")
	})
}

func TestAddUpdate_OversizedRefused(cur realm, t *testing.T) {
	defer resetTestState()

	creator := testutils.TestAddress("update-creator3")
	testing.SetRealm(testing.NewUserRealm(creator))
	deadline := time.Now().Add(1 * time.Hour).Unix()
	id := CreateCampaign(cross(cur), "Oversized update", minimumContributionUgnot*10, deadline)

	oversized := make([]byte, maxUpdateBytes+1)
	for i := range oversized {
		oversized[i] = 'a'
	}

	uassert.AbortsWithMessage(t, cur, "update exceeds max size", func() {
		AddUpdate(cross(cur), id, string(oversized))
	})
}

func TestAddUpdate_CountLimitEnforced(cur realm, t *testing.T) {
	defer resetTestState()

	creator := testutils.TestAddress("update-creator4")
	testing.SetRealm(testing.NewUserRealm(creator))
	deadline := time.Now().Add(1 * time.Hour).Unix()
	id := CreateCampaign(cross(cur), "Update limit", minimumContributionUgnot*10, deadline)

	for i := 0; i < maxUpdatesPerCampaign; i++ {
		AddUpdate(cross(cur), id, "update")
	}

	c := mustGetCampaign(id)
	uassert.Equal(t, maxUpdatesPerCampaign, len(c.updates))

	uassert.AbortsWithMessage(t, cur, "campaign has reached its update limit", func() {
		AddUpdate(cross(cur), id, "one too many")
	})
}
