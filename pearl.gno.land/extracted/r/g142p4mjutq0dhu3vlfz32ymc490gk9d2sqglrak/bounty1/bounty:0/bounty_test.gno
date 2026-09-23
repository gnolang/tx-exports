package bounty

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

const modulePath = "gno.land/r/g142p4mjutq0dhu3vlfz32ymc490gk9d2sqglrak/bounty1/bounty"

func resetTestState() {
	bounties = avl.Tree{}
	submissions = avl.Tree{}
	nextBountyID = 0
}

// createBounty is a test helper: it switches to poster, declares an origin
// send of amount ugnot equal to reward, credits the realm's bank balance so
// a later Approve/Refund SendCoins has funds to move, and calls CreateBounty.
func createBounty(cur realm, t *testing.T, poster address, title string, reward int64, deadline int64) int64 {
	pkgAddr := chain.PackageAddress(modulePath)
	testing.SetRealm(testing.NewUserRealm(poster))
	testing.SetOriginSend(chain.Coins{{denom, reward}})
	testing.IssueCoins(pkgAddr, chain.Coins{{denom, reward}})
	return CreateBounty(cross(cur), title, reward, deadline)
}

func TestCreateBounty_Success(cur realm, t *testing.T) {
	defer resetTestState()

	poster := testutils.TestAddress("poster1")
	deadline := time.Now().Add(1 * time.Hour).Unix()
	reward := minimumRewardUgnot * 10
	id := createBounty(cur, t, poster, "Fix the bug", reward, deadline)
	uassert.Equal(t, int64(1), id)

	b := mustGetBounty(id)
	uassert.Equal(t, "Fix the bug", b.title)
	uassert.Equal(t, poster, b.poster)
	uassert.Equal(t, reward, b.rewardUgnot)
	uassert.False(t, b.released)
	uassert.False(t, b.refunded)
}

func TestCreateBounty_ZeroRewardRefused(cur realm, t *testing.T) {
	defer resetTestState()

	poster := testutils.TestAddress("poster-zeroreward")
	testing.SetRealm(testing.NewUserRealm(poster))
	deadline := time.Now().Add(1 * time.Hour).Unix()

	uassert.AbortsWithMessage(t, cur, "reward below minimum", func() {
		CreateBounty(cross(cur), "Zero reward", 0, deadline)
	})
}

// TestCreateBounty_BelowMinimumRefused pins that a single guard
// (rewardUgnot < minimumRewardUgnot) rejects a below-minimum reward without
// a separate, always-redundant positivity check -- see the comment beside
// this guard in bounty.gno.
func TestCreateBounty_BelowMinimumRefused(cur realm, t *testing.T) {
	defer resetTestState()

	poster := testutils.TestAddress("poster-belowmin")
	testing.SetRealm(testing.NewUserRealm(poster))
	deadline := time.Now().Add(1 * time.Hour).Unix()

	uassert.AbortsWithMessage(t, cur, "reward below minimum", func() {
		CreateBounty(cross(cur), "Below minimum", minimumRewardUgnot-1, deadline)
	})
}

func TestCreateBounty_PastDeadlineRefused(cur realm, t *testing.T) {
	defer resetTestState()

	poster := testutils.TestAddress("poster-pastdl")
	testing.SetRealm(testing.NewUserRealm(poster))
	pastDeadline := time.Now().Add(-1 * time.Hour).Unix()

	uassert.AbortsWithMessage(t, cur, "deadline must be in the future", func() {
		CreateBounty(cross(cur), "Too late", minimumRewardUgnot*10, pastDeadline)
	})
}

// TestCreateBounty_DeadlineTooFarInFutureRefused pins the same
// maxDeadlineSecondsFromNow typo guard as crowdfunding's
// TestCreateCampaign_DeadlineTooFarInFutureRefused. The 60-second margin
// beyond the bound (rather than exactly +1) keeps this test from flaking if
// a second elapses between this line's clock read and CreateBounty's own.
func TestCreateBounty_DeadlineTooFarInFutureRefused(cur realm, t *testing.T) {
	defer resetTestState()

	poster := testutils.TestAddress("poster-fardl")
	testing.SetRealm(testing.NewUserRealm(poster))
	tooFar := time.Now().Unix() + maxDeadlineSecondsFromNow + 60

	uassert.AbortsWithMessage(t, cur, "deadline too far in the future", func() {
		CreateBounty(cross(cur), "Millisecond typo", minimumRewardUgnot*10, tooFar)
	})
}

// TestCreateBounty_DeadlineAtUpperBoundAccepted is the boundary case for
// `deadlineUnix > time.Now().Unix()+maxDeadlineSecondsFromNow`: a deadline
// landing exactly on the bound must still be accepted, so a mutation
// weakening `>` to `>=` has something to be caught by.
func TestCreateBounty_DeadlineAtUpperBoundAccepted(cur realm, t *testing.T) {
	defer resetTestState()

	poster := testutils.TestAddress("poster-bounddl")
	atBound := time.Now().Unix() + maxDeadlineSecondsFromNow

	id := createBounty(cur, t, poster, "At the boundary", minimumRewardUgnot*10, atBound)
	b := mustGetBounty(id)
	uassert.Equal(t, atBound, b.deadlineUnix)
}

func TestCreateBounty_WrongDenomRefused(cur realm, t *testing.T) {
	defer resetTestState()

	poster := testutils.TestAddress("poster-denom")
	testing.SetRealm(testing.NewUserRealm(poster))
	deadline := time.Now().Add(1 * time.Hour).Unix()
	reward := minimumRewardUgnot * 10

	pkgAddr := chain.PackageAddress(modulePath)
	testing.SetOriginSend(chain.Coins{{"otherdenom", reward}})
	testing.IssueCoins(pkgAddr, chain.Coins{{"otherdenom", reward}})
	uassert.AbortsWithMessage(t, cur, "only ugnot escrow is accepted", func() {
		CreateBounty(cross(cur), "Denom test", reward, deadline)
	})
}

// TestCreateBounty_AmountMismatchRefused pins PER_BOUNTY_CONSERVATION /
// CHECKED_INTEGER_MONEY at creation time: the declared rewardUgnot term and
// the coins actually attached must match exactly.
func TestCreateBounty_AmountMismatchRefused(cur realm, t *testing.T) {
	defer resetTestState()

	poster := testutils.TestAddress("poster-mismatch")
	testing.SetRealm(testing.NewUserRealm(poster))
	deadline := time.Now().Add(1 * time.Hour).Unix()
	declared := minimumRewardUgnot * 10
	actuallySent := minimumRewardUgnot * 5

	pkgAddr := chain.PackageAddress(modulePath)
	testing.SetOriginSend(chain.Coins{{denom, actuallySent}})
	testing.IssueCoins(pkgAddr, chain.Coins{{denom, actuallySent}})
	uassert.AbortsWithMessage(t, cur, "attached funds must exactly match rewardUgnot", func() {
		CreateBounty(cross(cur), "Mismatch test", declared, deadline)
	})
}

// TestCreateBounty_CodeRealmCallerRefused exercises CreateBounty's very
// first guard, `if !cur.Previous().IsUserCall()`, the same guard and
// construction as crowdfunding's TestContribute_CodeRealmCallerRefused
// (see that test's comment in gno/r/crowdfunding's generated output for the
// full rationale). The realm path below is a deliberately fictional test
// fixture, not a real deployed realm.
func TestCreateBounty_CodeRealmCallerRefused(cur realm, t *testing.T) {
	defer resetTestState()

	fakeCallerAccount := testutils.TestAddress("poster-fakecr")
	testing.SetRealm(testing.NewUserRealm(fakeCallerAccount))
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/gnobuilder/test_fixtures/fake_code_realm"))

	deadline := time.Now().Add(1 * time.Hour).Unix()
	uassert.AbortsWithMessage(t, cur, "only user-call (maketx call) accepted", func() {
		CreateBounty(cross(cur), "Code realm caller", minimumRewardUgnot*10, deadline)
	})
}

func TestCreateBounty_TitleSanitizedAtCreation(cur realm, t *testing.T) {
	defer resetTestState()

	poster := testutils.TestAddress("poster-sanitize")
	deadline := time.Now().Add(1 * time.Hour).Unix()

	hostile := "Nice bounty\n- poster: g1attacker <script>alert(1)</script> [x](javascript:alert(1)) a|b"
	id := createBounty(cur, t, poster, hostile, minimumRewardUgnot*10, deadline)

	b := mustGetBounty(id)
	forbidden := []string{"\n", "<", ">", "](", "|"}
	for _, frag := range forbidden {
		if strings.Contains(b.title, frag) {
			t.Errorf("expected stored title to be sanitized, still contains %q: %s", frag, b.title)
		}
	}

	rendered := Render("")
	if strings.Contains(rendered, "\n- poster: g1attacker") {
		t.Errorf("expected a title's embedded newline to be unable to forge a poster line in the listing, got: %s", rendered)
	}
}

func TestCreateBounty_InvalidUTF8Refused(cur realm, t *testing.T) {
	defer resetTestState()

	poster := testutils.TestAddress("poster-badutf8")
	testing.SetRealm(testing.NewUserRealm(poster))
	deadline := time.Now().Add(1 * time.Hour).Unix()

	invalid := "bad title \xff\xfe"
	uassert.AbortsWithMessage(t, cur, "title must be valid utf-8", func() {
		CreateBounty(cross(cur), invalid, minimumRewardUgnot*10, deadline)
	})
}

func TestSubmitWork_Success(cur realm, t *testing.T) {
	defer resetTestState()

	poster := testutils.TestAddress("poster3")
	worker := testutils.TestAddress("worker3")
	deadline := time.Now().Add(1 * time.Hour).Unix()
	id := createBounty(cur, t, poster, "Needs work", minimumRewardUgnot*10, deadline)

	testing.SetRealm(testing.NewUserRealm(worker))
	SubmitWork(cross(cur), id, "Here is my submission")

	b := mustGetBounty(id)
	uassert.Equal(t, int64(1), b.submissionCount)

	v := submissions.Get(submissionKey(id, worker))
	if v == nil {
		t.Errorf("expected a submission to be stored for worker %s", worker)
		return
	}
	sub := v.(*Submission)
	uassert.Equal(t, "Here is my submission", sub.note)
	uassert.Equal(t, worker, sub.worker)
}

// TestSubmitWork_UnknownBountyRefused pins BOUNTY_ISOLATION at the entry
// point: an unknown bountyID is refused outright, before any submission
// state could be written under a crafted id.
func TestSubmitWork_UnknownBountyRefused(cur realm, t *testing.T) {
	defer resetTestState()

	worker := testutils.TestAddress("worker-unknown")
	testing.SetRealm(testing.NewUserRealm(worker))
	uassert.AbortsWithMessage(t, cur, "unknown bounty id", func() {
		SubmitWork(cross(cur), 999, "some work")
	})
}

func TestSubmitWork_OversizedNoteRefused(cur realm, t *testing.T) {
	defer resetTestState()

	poster := testutils.TestAddress("poster4")
	worker := testutils.TestAddress("worker4")
	deadline := time.Now().Add(1 * time.Hour).Unix()
	id := createBounty(cur, t, poster, "Oversized note", minimumRewardUgnot*10, deadline)

	oversized := make([]byte, maxNoteBytes+1)
	for i := range oversized {
		oversized[i] = 'a'
	}

	testing.SetRealm(testing.NewUserRealm(worker))
	uassert.AbortsWithMessage(t, cur, "note exceeds max size", func() {
		SubmitWork(cross(cur), id, string(oversized))
	})
}

func TestSubmitWork_InvalidUTF8NoteRefused(cur realm, t *testing.T) {
	defer resetTestState()

	poster := testutils.TestAddress("poster5")
	worker := testutils.TestAddress("worker5")
	deadline := time.Now().Add(1 * time.Hour).Unix()
	id := createBounty(cur, t, poster, "Bad utf8 note", minimumRewardUgnot*10, deadline)

	testing.SetRealm(testing.NewUserRealm(worker))
	invalid := "bad note \xff\xfe"
	uassert.AbortsWithMessage(t, cur, "note must be valid utf-8", func() {
		SubmitWork(cross(cur), id, invalid)
	})
}

// TestSubmitWork_AllowedAfterDeadline pins the deliberate design choice
// documented in bounty.gno: unlike crowdfunding's Contribute, SubmitWork is
// not deadline-gated, because release is a discretionary poster act via
// Approve rather than an automatic consequence of reaching a deadline.
func TestSubmitWork_AllowedAfterDeadline(cur realm, t *testing.T) {
	defer resetTestState()

	poster := testutils.TestAddress("poster6")
	worker := testutils.TestAddress("worker6")
	deadline := time.Now().Add(1 * time.Hour).Unix()
	id := createBounty(cur, t, poster, "Late submission", minimumRewardUgnot*10, deadline)

	b := mustGetBounty(id)
	b.deadlineUnix = time.Now().Add(-1 * time.Hour).Unix() // simulate deadline passed

	testing.SetRealm(testing.NewUserRealm(worker))
	SubmitWork(cross(cur), id, "submitted after the deadline")

	uassert.Equal(t, int64(1), b.submissionCount)
}

// TestSubmitWork_NoteSanitizedAtSubmission is SubmitWork's analogue of
// TestCreateBounty_TitleSanitizedAtCreation: a submission note is also
// attacker-controlled text a future Render path could display.
func TestSubmitWork_NoteSanitizedAtSubmission(cur realm, t *testing.T) {
	defer resetTestState()

	poster := testutils.TestAddress("poster7")
	worker := testutils.TestAddress("worker7")
	deadline := time.Now().Add(1 * time.Hour).Unix()
	id := createBounty(cur, t, poster, "Sanitize note", minimumRewardUgnot*10, deadline)

	hostile := "Done\n- poster: g1attacker <script>alert(1)</script> [x](javascript:alert(1)) a|b"
	testing.SetRealm(testing.NewUserRealm(worker))
	SubmitWork(cross(cur), id, hostile)

	v := submissions.Get(submissionKey(id, worker))
	sub := v.(*Submission)
	forbidden := []string{"\n", "<", ">", "](", "|"}
	for _, frag := range forbidden {
		if strings.Contains(sub.note, frag) {
			t.Errorf("expected stored note to be sanitized, still contains %q: %s", frag, sub.note)
		}
	}
}

func TestSubmitWork_ReplacesPriorSubmissionSameWorker(cur realm, t *testing.T) {
	defer resetTestState()

	poster := testutils.TestAddress("poster8")
	worker := testutils.TestAddress("worker8")
	deadline := time.Now().Add(1 * time.Hour).Unix()
	id := createBounty(cur, t, poster, "Resubmission", minimumRewardUgnot*10, deadline)

	testing.SetRealm(testing.NewUserRealm(worker))
	SubmitWork(cross(cur), id, "first attempt")
	SubmitWork(cross(cur), id, "second attempt")

	b := mustGetBounty(id)
	uassert.Equal(t, int64(1), b.submissionCount)

	v := submissions.Get(submissionKey(id, worker))
	sub := v.(*Submission)
	uassert.Equal(t, "second attempt", sub.note)
}

func TestApprove_Success(cur realm, t *testing.T) {
	defer resetTestState()

	poster := testutils.TestAddress("poster9")
	worker := testutils.TestAddress("worker9")
	deadline := time.Now().Add(1 * time.Hour).Unix()
	reward := minimumRewardUgnot * 10
	id := createBounty(cur, t, poster, "Approve me", reward, deadline)

	testing.SetRealm(testing.NewUserRealm(worker))
	SubmitWork(cross(cur), id, "my submission")

	testing.SetRealm(testing.NewUserRealm(poster))
	Approve(cross(cur), id, worker)

	b := mustGetBounty(id)
	uassert.True(t, b.released)
	uassert.Equal(t, worker, b.releasedTo)
}

func TestApprove_NonPosterRefused(cur realm, t *testing.T) {
	defer resetTestState()

	poster := testutils.TestAddress("poster10")
	worker := testutils.TestAddress("worker10")
	stranger := testutils.TestAddress("stranger10")
	deadline := time.Now().Add(1 * time.Hour).Unix()
	id := createBounty(cur, t, poster, "Not yours", minimumRewardUgnot*10, deadline)

	testing.SetRealm(testing.NewUserRealm(worker))
	SubmitWork(cross(cur), id, "submission")

	testing.SetRealm(testing.NewUserRealm(stranger))
	uassert.AbortsWithMessage(t, cur, "only the bounty poster can approve", func() {
		Approve(cross(cur), id, worker)
	})
}

func TestApprove_NonSubmitterRefused(cur realm, t *testing.T) {
	defer resetTestState()

	poster := testutils.TestAddress("poster11")
	neverSubmitted := testutils.TestAddress("noshow11")
	deadline := time.Now().Add(1 * time.Hour).Unix()
	id := createBounty(cur, t, poster, "No submission", minimumRewardUgnot*10, deadline)

	testing.SetRealm(testing.NewUserRealm(poster))
	uassert.AbortsWithMessage(t, cur, "worker has no submission for this bounty", func() {
		Approve(cross(cur), id, neverSubmitted)
	})
}

func TestApprove_DoubleApproveRefused(cur realm, t *testing.T) {
	defer resetTestState()

	poster := testutils.TestAddress("poster12")
	worker := testutils.TestAddress("worker12")
	deadline := time.Now().Add(1 * time.Hour).Unix()
	id := createBounty(cur, t, poster, "Double approve", minimumRewardUgnot*10, deadline)

	testing.SetRealm(testing.NewUserRealm(worker))
	SubmitWork(cross(cur), id, "submission")

	testing.SetRealm(testing.NewUserRealm(poster))
	Approve(cross(cur), id, worker)
	uassert.AbortsWithMessage(t, cur, "bounty reward already released", func() {
		Approve(cross(cur), id, worker)
	})
}

// TestApprove_AfterRefundRefused is the explicit cross-entrypoint case:
// once Refund has settled a bounty, Approve must refuse too, not just a
// second Approve.
func TestApprove_AfterRefundRefused(cur realm, t *testing.T) {
	defer resetTestState()

	poster := testutils.TestAddress("poster13")
	worker := testutils.TestAddress("worker13")
	deadline := time.Now().Add(1 * time.Hour).Unix()
	id := createBounty(cur, t, poster, "Refund then approve", minimumRewardUgnot*10, deadline)

	testing.SetRealm(testing.NewUserRealm(worker))
	SubmitWork(cross(cur), id, "submission")

	b := mustGetBounty(id)
	b.deadlineUnix = time.Now().Add(-1 * time.Hour).Unix() // simulate deadline passed

	testing.SetRealm(testing.NewUserRealm(poster))
	Refund(cross(cur), id)

	uassert.AbortsWithMessage(t, cur, "bounty reward already refunded", func() {
		Approve(cross(cur), id, worker)
	})
}

func TestApprove_UnknownBountyRefused(cur realm, t *testing.T) {
	defer resetTestState()

	poster := testutils.TestAddress("poster14")
	testing.SetRealm(testing.NewUserRealm(poster))
	uassert.AbortsWithMessage(t, cur, "unknown bounty id", func() {
		Approve(cross(cur), 999, poster)
	})
}

func TestRefund_Success(cur realm, t *testing.T) {
	defer resetTestState()

	poster := testutils.TestAddress("poster15")
	deadline := time.Now().Add(1 * time.Hour).Unix()
	id := createBounty(cur, t, poster, "Never claimed", minimumRewardUgnot*10, deadline)

	b := mustGetBounty(id)
	b.deadlineUnix = time.Now().Add(-1 * time.Hour).Unix()

	testing.SetRealm(testing.NewUserRealm(poster))
	Refund(cross(cur), id)

	uassert.True(t, b.refunded)
}

func TestRefund_NonPosterRefused(cur realm, t *testing.T) {
	defer resetTestState()

	poster := testutils.TestAddress("poster16")
	stranger := testutils.TestAddress("stranger16")
	deadline := time.Now().Add(1 * time.Hour).Unix()
	id := createBounty(cur, t, poster, "Not yours to refund", minimumRewardUgnot*10, deadline)

	b := mustGetBounty(id)
	b.deadlineUnix = time.Now().Add(-1 * time.Hour).Unix()

	testing.SetRealm(testing.NewUserRealm(stranger))
	uassert.AbortsWithMessage(t, cur, "only the bounty poster can refund", func() {
		Refund(cross(cur), id)
	})
}

func TestRefund_BeforeDeadlineRefused(cur realm, t *testing.T) {
	defer resetTestState()

	poster := testutils.TestAddress("poster17")
	deadline := time.Now().Add(1 * time.Hour).Unix()
	id := createBounty(cur, t, poster, "Too early", minimumRewardUgnot*10, deadline)

	testing.SetRealm(testing.NewUserRealm(poster))
	uassert.AbortsWithMessage(t, cur, "bounty deadline has not passed", func() {
		Refund(cross(cur), id)
	})
}

// TestRefund_AtExactDeadlineAccepted is the boundary case for the guard
// `if time.Now().Unix() < bounty.deadlineUnix`: a refund landing on the
// deadline second itself must be accepted, not refused, so a mutation
// weakening `<` to `<=` has something to be caught by.
func TestRefund_AtExactDeadlineAccepted(cur realm, t *testing.T) {
	defer resetTestState()

	poster := testutils.TestAddress("poster18")
	deadline := time.Now().Add(1 * time.Hour).Unix()
	id := createBounty(cur, t, poster, "Exact deadline refund", minimumRewardUgnot*10, deadline)

	b := mustGetBounty(id)
	b.deadlineUnix = time.Now().Unix() // the boundary itself, not a past deadline

	testing.SetRealm(testing.NewUserRealm(poster))
	Refund(cross(cur), id)

	uassert.True(t, b.refunded)
}

// TestRefund_AfterReleaseRefused is the explicit cross-entrypoint case: once
// Approve has settled a bounty, Refund must refuse too, not just a second
// Refund.
func TestRefund_AfterReleaseRefused(cur realm, t *testing.T) {
	defer resetTestState()

	poster := testutils.TestAddress("poster19")
	worker := testutils.TestAddress("worker19")
	deadline := time.Now().Add(1 * time.Hour).Unix()
	id := createBounty(cur, t, poster, "Released then refund attempt", minimumRewardUgnot*10, deadline)

	testing.SetRealm(testing.NewUserRealm(worker))
	SubmitWork(cross(cur), id, "submission")

	testing.SetRealm(testing.NewUserRealm(poster))
	Approve(cross(cur), id, worker)

	b := mustGetBounty(id)
	b.deadlineUnix = time.Now().Add(-1 * time.Hour).Unix()

	uassert.AbortsWithMessage(t, cur, "bounty reward already released", func() {
		Refund(cross(cur), id)
	})
}

func TestRefund_DoubleRefundRefused(cur realm, t *testing.T) {
	defer resetTestState()

	poster := testutils.TestAddress("poster20")
	deadline := time.Now().Add(1 * time.Hour).Unix()
	id := createBounty(cur, t, poster, "Double refund", minimumRewardUgnot*10, deadline)

	b := mustGetBounty(id)
	b.deadlineUnix = time.Now().Add(-1 * time.Hour).Unix()

	testing.SetRealm(testing.NewUserRealm(poster))
	Refund(cross(cur), id)
	uassert.AbortsWithMessage(t, cur, "bounty reward already refunded", func() {
		Refund(cross(cur), id)
	})
}

func TestRefund_UnknownBountyRefused(cur realm, t *testing.T) {
	defer resetTestState()

	poster := testutils.TestAddress("poster21")
	testing.SetRealm(testing.NewUserRealm(poster))
	uassert.AbortsWithMessage(t, cur, "unknown bounty id", func() {
		Refund(cross(cur), 999)
	})
}

// TestBountyIsolation_ApprovalCannotCrossBounties pins BOUNTY_ISOLATION
// directly: a worker who submitted to bountyA must not be approvable
// against bountyB merely because both ids share the same flat `submissions`
// tree.
func TestBountyIsolation_ApprovalCannotCrossBounties(cur realm, t *testing.T) {
	defer resetTestState()

	posterA := testutils.TestAddress("posterA22")
	posterB := testutils.TestAddress("posterB22")
	worker := testutils.TestAddress("worker22")
	deadline := time.Now().Add(1 * time.Hour).Unix()

	idA := createBounty(cur, t, posterA, "Bounty A", minimumRewardUgnot*10, deadline)
	idB := createBounty(cur, t, posterB, "Bounty B", minimumRewardUgnot*10, deadline)

	testing.SetRealm(testing.NewUserRealm(worker))
	SubmitWork(cross(cur), idA, "submission for A only")

	testing.SetRealm(testing.NewUserRealm(posterB))
	uassert.AbortsWithMessage(t, cur, "worker has no submission for this bounty", func() {
		Approve(cross(cur), idB, worker)
	})
}

func TestViewBounty(cur realm, t *testing.T) {
	defer resetTestState()

	poster := testutils.TestAddress("poster23")
	deadline := time.Now().Add(1 * time.Hour).Unix()
	id := createBounty(cur, t, poster, "Viewable", minimumRewardUgnot*10, deadline)

	uassert.Equal(t, mustGetBounty(id).String(), ViewBounty(id))
}

func TestRender(cur realm, t *testing.T) {
	defer resetTestState()

	poster := testutils.TestAddress("poster24")
	deadline := time.Now().Add(1 * time.Hour).Unix()
	reward1 := minimumRewardUgnot * 10
	reward2 := minimumRewardUgnot * 20
	id1 := createBounty(cur, t, poster, "Bounty One", reward1, deadline)
	id2 := createBounty(cur, t, poster, "Bounty Two", reward2, deadline)

	expected := ufmt.Sprintf(
		"# Community Bounty"+"\n\n- %d: Bounty Two - reward %dugnot - open\n- %d: Bounty One - reward %dugnot - open\n",
		id2, reward2, id1, reward1,
	)
	uassert.Equal(t, expected, Render(""))

	b1 := mustGetBounty(id1)
	expectedDetail := ufmt.Sprintf(
		"- id: %d\n- title: %s\n- poster: %s\n- reward: %dugnot\n- deadline: %s\n- status: %s\n- submissions: %d",
		id1, "Bounty One", poster, reward1,
		time.Unix(b1.deadlineUnix, 0).UTC().Format(time.RFC3339), "open", int64(0),
	)
	uassert.Equal(t, expectedDetail, Render("1"))

	uassert.Equal(t, "404", Render("999"))
}

// TestBountyKeyOrdersNumericallyNotLexicographically pins the same
// zero-padding correctness property as crowdfunding's
// TestCampaignKeyOrdersNumericallyNotLexicographically.
func TestBountyKeyOrdersNumericallyNotLexicographically(cur realm, t *testing.T) {
	if bountyKey(2) >= bountyKey(10) {
		t.Errorf("expected bountyKey(2) < bountyKey(10) (numeric-order-preserving keys), got key(2)=%q key(10)=%q", bountyKey(2), bountyKey(10))
	}
	if len(bountyKey(1)) != bountyKeyWidth {
		t.Errorf("expected bountyKey to zero-pad to width %d, got %q (len %d)", bountyKeyWidth, bountyKey(1), len(bountyKey(1)))
	}
}

// TestRenderHome_ShowsNewestBeyondPageSize pins the same pagination
// correctness property as crowdfunding's
// TestRenderHome_ShowsNewestBeyondPageSize.
func TestRenderHome_ShowsNewestBeyondPageSize(cur realm, t *testing.T) {
	defer resetTestState()

	poster := testutils.TestAddress("poster-pagination")
	deadline := time.Now().Add(1 * time.Hour).Unix()

	total := pageSize + 5
	var newestID, oldestID int64
	for i := 0; i < total; i++ {
		id := createBounty(cur, t, poster, ufmt.Sprintf("Bounty %d", i), minimumRewardUgnot*10, deadline)
		if i == 0 {
			oldestID = id
		}
		newestID = id
	}

	output := Render("")
	newest := mustGetBounty(newestID)
	oldest := mustGetBounty(oldestID)
	if !strings.Contains(output, newest.title) {
		t.Errorf("expected the newest bounty %q on the home listing, got: %s", newest.title, output)
	}
	if strings.Contains(output, oldest.title) {
		t.Errorf("expected the oldest bounty %q to be pushed off the first page, got: %s", oldest.title, output)
	}
}
