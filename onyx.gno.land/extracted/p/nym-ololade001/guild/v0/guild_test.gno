package guild

import (
	"strings"
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
	"gno.land/p/nt/urequire/v0"
)

var (
	poster  = testutils.TestAddress("poster")
	worker  = testutils.TestAddress("worker")
	worker2 = testutils.TestAddress("worker2")
	rando   = testutils.TestAddress("rando")
)

const (
	h0           = int64(1000)
	leaseBlocks  = int64(600)
	reviewBlocks = int64(1200)
	deadline     = h0 + 10000
	reward       = int64(5000000)
)

func newValidQuest(t *testing.T) *Quest {
	q, err := New(1, poster, "Write tests", "cover the avl package", reward, leaseBlocks, reviewBlocks, deadline, h0)
	urequire.NoError(t, err)
	return q
}

func newClaimedQuest(t *testing.T) *Quest {
	q := newValidQuest(t)
	urequire.NoError(t, q.Claim(worker, h0))
	return q
}

func newSubmittedQuest(t *testing.T) *Quest {
	q := newClaimedQuest(t)
	urequire.NoError(t, q.Submit(worker, h0+10, "https://example.com/proof", "done"))
	return q
}

func TestNew(t *testing.T) {
	q := newValidQuest(t)
	uassert.Equal(t, uint64(1), q.ID)
	uassert.Equal(t, poster, q.Poster)
	uassert.Equal(t, "Write tests", q.Title)
	uassert.Equal(t, reward, q.Reward)
	uassert.True(t, q.Status == Open)
	uassert.Equal(t, 1, len(q.History))
	uassert.Equal(t, "posted", q.History[0].Action)
	uassert.Equal(t, poster, q.History[0].Actor)
	uassert.Equal(t, h0, q.History[0].Height)
}

func TestNew_TrimsTitle(t *testing.T) {
	q, err := New(1, poster, "  padded title  ", "", reward, leaseBlocks, reviewBlocks, deadline, h0)
	urequire.NoError(t, err)
	uassert.Equal(t, "padded title", q.Title)
}

func TestNew_Validation(t *testing.T) {
	longTitle := strings.Repeat("t", MaxTitle+1)
	longSpec := strings.Repeat("s", MaxSpec+1)

	cases := []struct {
		name    string
		poster  address
		title   string
		spec    string
		reward  int64
		lease   int64
		review  int64
		dl      int64
		wantErr error
	}{
		{"bad poster", address("bogus"), "t", "", reward, leaseBlocks, reviewBlocks, deadline, ErrInvalidPoster},
		{"empty title", poster, "", "", reward, leaseBlocks, reviewBlocks, deadline, ErrEmptyTitle},
		{"blank title", poster, "   ", "", reward, leaseBlocks, reviewBlocks, deadline, ErrEmptyTitle},
		{"long title", poster, longTitle, "", reward, leaseBlocks, reviewBlocks, deadline, ErrTitleTooLong},
		{"long spec", poster, "t", longSpec, reward, leaseBlocks, reviewBlocks, deadline, ErrSpecTooLong},
		{"zero reward", poster, "t", "", 0, leaseBlocks, reviewBlocks, deadline, ErrInvalidReward},
		{"negative reward", poster, "t", "", -5, leaseBlocks, reviewBlocks, deadline, ErrInvalidReward},
		{"lease too small", poster, "t", "", reward, MinBlocks - 1, reviewBlocks, deadline, ErrInvalidLease},
		{"lease too big", poster, "t", "", reward, MaxBlocks + 1, reviewBlocks, deadline, ErrInvalidLease},
		{"review too small", poster, "t", "", reward, leaseBlocks, MinBlocks - 1, deadline, ErrInvalidReview},
		{"review too big", poster, "t", "", reward, leaseBlocks, MaxBlocks + 1, deadline, ErrInvalidReview},
		{"deadline inside lease", poster, "t", "", reward, leaseBlocks, reviewBlocks, h0 + leaseBlocks, ErrInvalidDeadline},
		{"deadline before lease", poster, "t", "", reward, leaseBlocks, reviewBlocks, h0 + leaseBlocks - 1, ErrInvalidDeadline},
	}
	for _, tc := range cases {
		_, err := New(1, tc.poster, tc.title, tc.spec, tc.reward, tc.lease, tc.review, tc.dl, h0)
		uassert.ErrorIs(t, err, tc.wantErr, tc.name)
	}

	// Boundary values that must be accepted.
	_, err := New(1, poster, strings.Repeat("t", MaxTitle), strings.Repeat("s", MaxSpec),
		reward, MinBlocks, MaxBlocks, deadline, h0)
	uassert.NoError(t, err)
}

func TestClaim(t *testing.T) {
	q := newValidQuest(t)
	urequire.NoError(t, q.Claim(worker, h0+50))
	uassert.True(t, q.Status == Claimed)
	uassert.Equal(t, worker, q.Worker)
	uassert.Equal(t, h0+50+leaseBlocks, q.LeaseEnd)
	uassert.Equal(t, "claimed", q.History[len(q.History)-1].Action)
}

func TestClaim_Rejects(t *testing.T) {
	q := newValidQuest(t)
	uassert.ErrorIs(t, q.Claim(poster, h0), ErrSelfClaim, "poster cannot claim")

	uassert.ErrorIs(t, q.Claim(worker, deadline), ErrPastDeadline, "at deadline")
	uassert.ErrorIs(t, q.Claim(worker, deadline+1), ErrPastDeadline, "past deadline")

	claimed := newClaimedQuest(t)
	uassert.ErrorIs(t, claimed.Claim(worker2, h0+1), ErrNotOpen, "live claim blocks second claim")
	uassert.Equal(t, worker, claimed.Worker, "failed claim must not mutate worker")

	for _, s := range []Status{Submitted, Paid, Refunded, Cancelled} {
		qq := newValidQuest(t)
		qq.Status = s
		uassert.ErrorIs(t, qq.Claim(worker, h0), ErrNotOpen, s.String())
	}
}

func TestClaim_StaleLease(t *testing.T) {
	q := newClaimedQuest(t)
	after := q.LeaseEnd + 1
	urequire.NoError(t, q.Claim(worker2, after))
	uassert.Equal(t, worker2, q.Worker)
	uassert.Equal(t, after+leaseBlocks, q.LeaseEnd)

	// The stale claim is recorded as expired before the new claim.
	n := len(q.History)
	uassert.Equal(t, "expired", q.History[n-2].Action)
	uassert.Equal(t, worker.String(), q.History[n-2].Detail)
	uassert.Equal(t, "claimed", q.History[n-1].Action)
}

func TestSubmit(t *testing.T) {
	q := newClaimedQuest(t)
	urequire.NoError(t, q.Submit(worker, h0+100, "https://proof.example/1", "all done"))
	uassert.True(t, q.Status == Submitted)
	uassert.Equal(t, "https://proof.example/1", q.ProofURL)
	uassert.Equal(t, "all done", q.Note)
	uassert.Equal(t, h0+100, q.SubmittedAt)

	// Submitting exactly at the lease end is still valid.
	q2 := newClaimedQuest(t)
	urequire.NoError(t, q2.Submit(worker, q2.LeaseEnd, "https://proof.example/2", ""))
	uassert.True(t, q2.Status == Submitted)
}

func TestSubmit_Rejects(t *testing.T) {
	open := newValidQuest(t)
	uassert.ErrorIs(t, open.Submit(worker, h0, "u", ""), ErrNotClaimed, "open quest")

	q := newClaimedQuest(t)
	uassert.ErrorIs(t, q.Submit(worker2, h0, "u", ""), ErrNotWorker, "wrong worker")
	uassert.ErrorIs(t, q.Submit(worker, q.LeaseEnd+1, "u", ""), ErrLeaseExpired, "stale lease")
	uassert.ErrorIs(t, q.Submit(worker, h0, "", ""), ErrProofURLEmpty, "empty proof")
	uassert.ErrorIs(t, q.Submit(worker, h0, "   ", ""), ErrProofURLEmpty, "blank proof")
	uassert.ErrorIs(t, q.Submit(worker, h0, strings.Repeat("u", MaxURL+1), ""), ErrProofURLTooLong, "long proof")
	uassert.ErrorIs(t, q.Submit(worker, h0, "u", strings.Repeat("n", MaxNote+1)), ErrNoteTooLong, "long note")

	uassert.True(t, q.Status == Claimed, "failed submits must not mutate")
	uassert.Equal(t, "", q.ProofURL)
}

func TestAccept(t *testing.T) {
	q := newSubmittedQuest(t)
	urequire.NoError(t, q.Accept(poster, h0+500))
	uassert.True(t, q.Status == Paid)
	uassert.False(t, q.AutoPaid)

	// Acceptance has no time limit: valid even after the review window.
	q2 := newSubmittedQuest(t)
	urequire.NoError(t, q2.Accept(poster, q2.ReviewEnd()+1))
	uassert.True(t, q2.Status == Paid)
}

func TestAccept_Rejects(t *testing.T) {
	open := newValidQuest(t)
	uassert.ErrorIs(t, open.Accept(poster, h0), ErrNotSubmitted, "open quest")

	q := newSubmittedQuest(t)
	uassert.ErrorIs(t, q.Accept(rando, h0), ErrNotPoster, "non-poster")
	uassert.ErrorIs(t, q.Accept(worker, h0), ErrNotPoster, "worker is not poster")
	uassert.True(t, q.Status == Submitted)
}

func TestReject(t *testing.T) {
	q := newSubmittedQuest(t)
	uassert.NoError(t, q.Reject(poster, h0+500, "needs more detail"))
	uassert.True(t, q.Status == Open)
	uassert.Equal(t, address(""), q.Worker)
	uassert.Equal(t, int64(0), q.LeaseEnd)
	uassert.Equal(t, "", q.ProofURL)
	uassert.Equal(t, "", q.Note)
	uassert.Equal(t, int64(0), q.SubmittedAt)

	last := q.History[len(q.History)-1]
	uassert.Equal(t, "rejected", last.Action)
	uassert.True(t, strings.Contains(last.Detail, worker.String()), "detail keeps old worker")
	uassert.True(t, strings.Contains(last.Detail, "needs more detail"), "detail keeps reason")

	// Rejected quest is claimable again by a different worker.
	urequire.NoError(t, q.Claim(worker2, h0+600))
	uassert.Equal(t, worker2, q.Worker)
}

func TestReject_Rejects(t *testing.T) {
	open := newValidQuest(t)
	uassert.ErrorIs(t, open.Reject(poster, h0, "r"), ErrNotSubmitted, "open quest")

	q := newSubmittedQuest(t)
	uassert.ErrorIs(t, q.Reject(rando, h0, "r"), ErrNotPoster, "non-poster")
	uassert.ErrorIs(t, q.Reject(poster, q.ReviewEnd()+1, "r"), ErrReviewClosed, "past review window")
	uassert.ErrorIs(t, q.Reject(poster, h0, strings.Repeat("r", MaxNote+1)), ErrReasonTooLong, "long reason")

	// Reject exactly at the review end is still valid.
	urequire.NoError(t, q.Reject(poster, q.ReviewEnd(), "ok"))
	uassert.True(t, q.Status == Open)
}

func TestAutoAccept(t *testing.T) {
	q := newSubmittedQuest(t)
	urequire.NoError(t, q.AutoAccept(worker, q.ReviewEnd()+1))
	uassert.True(t, q.Status == Paid)
	uassert.True(t, q.AutoPaid)
	uassert.Equal(t, "auto-accepted", q.History[len(q.History)-1].Action)
}

func TestAutoAccept_Rejects(t *testing.T) {
	open := newValidQuest(t)
	uassert.ErrorIs(t, open.AutoAccept(worker, h0), ErrNotSubmitted, "open quest")

	q := newSubmittedQuest(t)
	uassert.ErrorIs(t, q.AutoAccept(worker, q.ReviewEnd()), ErrReviewOpen, "at review end")
	uassert.ErrorIs(t, q.AutoAccept(rando, q.ReviewEnd()+1), ErrNotWorker, "non-worker")
	uassert.ErrorIs(t, q.AutoAccept(poster, q.ReviewEnd()+1), ErrNotWorker, "poster is not worker")
	uassert.True(t, q.Status == Submitted)
	uassert.False(t, q.AutoPaid)
}

func TestRefund(t *testing.T) {
	// Open quest refunded at the deadline.
	q := newValidQuest(t)
	urequire.NoError(t, q.Refund(poster, deadline))
	uassert.True(t, q.Status == Refunded)

	// Stale-claimed quest refunded after the deadline.
	q2 := newClaimedQuest(t)
	urequire.NoError(t, q2.Refund(poster, deadline+1))
	uassert.True(t, q2.Status == Refunded)
}

func TestRefund_Rejects(t *testing.T) {
	q := newValidQuest(t)
	uassert.ErrorIs(t, q.Refund(poster, deadline-1), ErrBeforeDeadline, "before deadline")
	uassert.ErrorIs(t, q.Refund(rando, deadline), ErrNotPoster, "non-poster")

	sub := newSubmittedQuest(t)
	uassert.ErrorIs(t, sub.Refund(poster, deadline+999), ErrSubmittedPending, "submitted can never refund")

	paid := newSubmittedQuest(t)
	urequire.NoError(t, paid.Accept(poster, h0+1))
	uassert.ErrorIs(t, paid.Refund(poster, deadline+999), ErrNotOpen, "paid is terminal")
}

func TestCancel(t *testing.T) {
	q := newValidQuest(t)
	urequire.NoError(t, q.Cancel(poster, h0+1))
	uassert.True(t, q.Status == Cancelled)

	// A claim whose lease went stale is cancellable too.
	q2 := newClaimedQuest(t)
	urequire.NoError(t, q2.Cancel(poster, q2.LeaseEnd+1))
	uassert.True(t, q2.Status == Cancelled)
}

func TestCancel_Rejects(t *testing.T) {
	q := newValidQuest(t)
	uassert.ErrorIs(t, q.Cancel(rando, h0), ErrNotPoster, "non-poster")

	claimed := newClaimedQuest(t)
	uassert.ErrorIs(t, claimed.Cancel(poster, h0+1), ErrNotOpen, "live claim blocks cancel")
	uassert.True(t, claimed.Status == Claimed)

	sub := newSubmittedQuest(t)
	uassert.ErrorIs(t, sub.Cancel(poster, h0+1), ErrNotOpen, "submitted blocks cancel")
}

func TestStatusString(t *testing.T) {
	uassert.Equal(t, "open", Open.String())
	uassert.Equal(t, "claimed", Claimed.String())
	uassert.Equal(t, "submitted", Submitted.String())
	uassert.Equal(t, "paid", Paid.String())
	uassert.Equal(t, "refunded", Refunded.String())
	uassert.Equal(t, "cancelled", Cancelled.String())
	uassert.Equal(t, "unknown", Status(99).String())
}
