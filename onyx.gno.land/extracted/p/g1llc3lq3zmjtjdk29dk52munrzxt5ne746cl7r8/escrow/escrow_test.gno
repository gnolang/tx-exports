package escrow

import (
	"chain"
	"errors"
	"strings"
	"testing"
)

var (
	poster   = chain.PackageAddress("questmaster/test/poster")
	builder  = chain.PackageAddress("questmaster/test/builder")
	builder2 = chain.PackageAddress("questmaster/test/builder2")
	stranger = chain.PackageAddress("questmaster/test/stranger")
)

const (
	reward     int64 = 5_000_000
	workBlocks int64 = 2_000
	h0         int64 = 1000 // post height
)

// --- helpers ---

var errUnexpectedPayout = errors.New("test: unexpected payout")

// nopay turns a (Payout, error) move into an error, failing on any payout:
// for moves that must not release money (quests that are not closing).
func nopay(p Payout, err error) error {
	if err == nil && p.Due() {
		return errUnexpectedPayout
	}
	return err
}

func mustErr(t *testing.T, want, got error, what string) {
	t.Helper()
	if got != want {
		t.Fatalf("%s: want error %v, got %v", what, want, got)
	}
}

func mustOK(t *testing.T, err error, what string) {
	t.Helper()
	if err != nil {
		t.Fatalf("%s: unexpected error %v", what, err)
	}
}

func mustState(t *testing.T, q *Quest, want State) {
	t.Helper()
	if q.State() != want {
		t.Fatalf("state: want %s, got %s", want, q.State())
	}
}

func newOpen(t *testing.T) *Quest {
	t.Helper()
	q, err := NewQuest(1, poster, "Fix the docs typo", "Details here", reward, workBlocks, h0)
	mustOK(t, err, "NewQuest")
	return q
}

// claimed at h0+10, work deadline h0+10+workBlocks
func newClaimed(t *testing.T) *Quest {
	t.Helper()
	q := newOpen(t)
	mustOK(t, q.Claim(builder, h0+10), "Claim")
	return q
}

// submitted at h0+20, review deadline h0+20+ReviewBlocks
func newSubmitted(t *testing.T) *Quest {
	t.Helper()
	q := newClaimed(t)
	mustOK(t, q.Submit(builder, "https://github.com/x/y/pull/1", h0+20), "Submit")
	return q
}

func newPaid(t *testing.T) *Quest {
	t.Helper()
	q := newSubmitted(t)
	if _, err := q.Approve(poster, h0+30); err != nil {
		t.Fatalf("Approve: %v", err)
	}
	return q
}

func newCancelled(t *testing.T) *Quest {
	t.Helper()
	q := newOpen(t)
	if _, err := q.Cancel(poster, h0+5); err != nil {
		t.Fatalf("Cancel: %v", err)
	}
	return q
}

func mustPayout(t *testing.T, p Payout, kind PayoutKind, to address, amount int64) {
	t.Helper()
	if p.Kind != kind || p.To != to || p.Amount != amount {
		t.Fatalf("payout: want {%s %s %d}, got {%s %s %d}", kind, to, amount, p.Kind, p.To, p.Amount)
	}
}

// --- Post ---

func TestPost(t *testing.T) {
	q := newOpen(t)
	mustState(t, q, Open)
	if q.ID() != 1 || q.Poster() != poster || q.Reward() != reward || q.WorkBlocks() != workBlocks || q.CreatedAt() != h0 {
		t.Fatalf("fields not stored: %+v", q)
	}
	if q.Builder() != "" || q.WorkLink() != "" || q.RejectCount() != 0 {
		t.Fatalf("new quest must have no builder, link or rejects")
	}
	if !q.HoldsFunds() {
		t.Fatalf("open quest must hold funds")
	}
}

func TestPostInvalid(t *testing.T) {
	long := func(n int) string { return strings.Repeat("a", n) }
	cases := []struct {
		name    string
		poster  address
		title   string
		details string
		reward  int64
		work    int64
		height  int64
		want    error
	}{
		{"bad poster", "", "t", "", reward, workBlocks, h0, ErrInvalidPoster},
		{"bad poster 2", "notanaddress", "t", "", reward, workBlocks, h0, ErrInvalidPoster},
		{"zero reward", poster, "t", "", 0, workBlocks, h0, ErrInvalidReward},
		{"negative reward", poster, "t", "", -1, workBlocks, h0, ErrInvalidReward},
		{"negative height", poster, "t", "", reward, workBlocks, -1, ErrInvalidHeight},
		{"empty title", poster, "", "", reward, workBlocks, h0, ErrTitleEmpty},
		{"blank title", poster, "   ", "", reward, workBlocks, h0, ErrTitleEmpty},
		{"title too long", poster, long(MaxTitleLen + 1), "", reward, workBlocks, h0, ErrTitleTooLong},
		{"details too long", poster, "t", long(MaxDetailsLen + 1), reward, workBlocks, h0, ErrDetailsTooLong},
		{"invalid utf8", poster, "t\xff", "", reward, workBlocks, h0, ErrInvalidText},
		{"title newline", poster, "a\nb", "", reward, workBlocks, h0, ErrTitleControlChar},
		{"title tab", poster, "a\tb", "", reward, workBlocks, h0, ErrTitleControlChar},
		{"title CR", poster, "a\rb", "", reward, workBlocks, h0, ErrTitleControlChar},
		{"title NUL", poster, "a\x00b", "", reward, workBlocks, h0, ErrTitleControlChar},
		{"title DEL", poster, "a\x7fb", "", reward, workBlocks, h0, ErrTitleControlChar},
		{"title C1 NEL", poster, "a\u0085b", "", reward, workBlocks, h0, ErrTitleControlChar},
		{"title line separator", poster, "a\u2028b", "", reward, workBlocks, h0, ErrTitleControlChar},
		{"title paragraph separator", poster, "a\u2029b", "", reward, workBlocks, h0, ErrTitleControlChar},
		{"work too low", poster, "t", "", reward, MinWorkBlocks - 1, h0, ErrWorkBlocksTooLow},
		{"work too high", poster, "t", "", reward, MaxWorkBlocks + 1, h0, ErrWorkBlocksTooHigh},
	}
	for _, c := range cases {
		q, err := NewQuest(1, c.poster, c.title, c.details, c.reward, c.work, c.height)
		if err != c.want {
			t.Errorf("%s: want %v, got %v", c.name, c.want, err)
		}
		if err != nil && q != nil {
			t.Errorf("%s: quest returned with error", c.name)
		}
	}
}

// Titles may hold ordinary punctuation and non-ASCII letters; details and
// reject reasons may keep newlines (the realm's Render escapes them).
func TestTextAllowed(t *testing.T) {
	_, err := NewQuest(1, poster, "Fix | table [link](x) — ünïcode 日本", "line 1\nline 2\ttab", reward, workBlocks, h0)
	mustOK(t, err, "title punctuation, details with newline")
	q := newSubmitted(t)
	mustOK(t, nopay(q.Reject(poster, "first line\nsecond line", h0+30)), "reason with newline")
}

// The window constants are pinned so a change is a deliberate, reviewed edit.
func TestWindowConstants(t *testing.T) {
	if MinWorkBlocks != 1_000 || MaxWorkBlocks != 2_200_000 || ReviewBlocks != 172_800 {
		t.Fatalf("window constants changed: min %d max %d review %d", MinWorkBlocks, MaxWorkBlocks, ReviewBlocks)
	}
}

func TestPostLimitsExact(t *testing.T) {
	// exactly at the limits is allowed; limits count characters, not bytes
	title := strings.Repeat("é", MaxTitleLen) // 80 chars, 160 bytes
	details := strings.Repeat("a", MaxDetailsLen)
	_, err := NewQuest(1, poster, title, details, 1, MinWorkBlocks, 0)
	mustOK(t, err, "limits exact, min work")
	_, err = NewQuest(1, poster, "t", "", 1, MaxWorkBlocks, 0)
	mustOK(t, err, "max work, empty details")
}

// --- section 4 table, row by row ---

func TestOpenClaim(t *testing.T) {
	q := newOpen(t)
	mustOK(t, q.Claim(builder, h0+10), "Claim")
	mustState(t, q, Claimed)
	if q.Builder() != builder || q.ClaimedAt() != h0+10 || q.WorkDeadline() != h0+10+workBlocks {
		t.Fatalf("claim fields wrong")
	}
}

func TestOpenCancel(t *testing.T) {
	q := newOpen(t)
	p, err := q.Cancel(poster, h0+5)
	mustOK(t, err, "Cancel")
	mustState(t, q, Cancelled)
	mustPayout(t, p, RefundPoster, poster, reward)
	if q.HoldsFunds() {
		t.Fatalf("cancelled quest must not hold funds")
	}
}

func TestClaimedSubmit(t *testing.T) {
	q := newClaimed(t)
	mustOK(t, q.Submit(builder, "https://example.com/work", h0+20), "Submit")
	mustState(t, q, Submitted)
	if q.WorkLink() != "https://example.com/work" || q.SubmittedAt() != h0+20 || q.ReviewDeadline() != h0+20+ReviewBlocks {
		t.Fatalf("submit fields wrong")
	}
}

func TestClaimedUnclaim(t *testing.T) {
	q := newClaimed(t)
	mustOK(t, nopay(q.Unclaim(builder, h0+15)), "Unclaim")
	mustState(t, q, Open)
	if q.Builder() != "" || q.ClaimedAt() != 0 || q.WorkDeadline() != 0 {
		t.Fatalf("unclaim must clear builder")
	}
	// someone else can claim it now
	mustOK(t, q.Claim(builder2, h0+16), "re-claim")
}

func TestClaimedRelease(t *testing.T) {
	q := newClaimed(t)
	mustOK(t, nopay(q.Release(stranger, q.WorkDeadline()+1)), "Release")
	mustState(t, q, Open)
	if q.Builder() != "" {
		t.Fatalf("release must clear builder")
	}
}

func TestSubmittedApprove(t *testing.T) {
	q := newSubmitted(t)
	p, err := q.Approve(poster, h0+30)
	mustOK(t, err, "Approve")
	mustState(t, q, Paid)
	mustPayout(t, p, PayBuilder, builder, reward)
	if q.HoldsFunds() {
		t.Fatalf("paid quest must not hold funds")
	}
}

func TestSubmittedReject(t *testing.T) {
	q := newSubmitted(t)
	mustOK(t, nopay(q.Reject(poster, "missing tests", h0+30)), "Reject")
	mustState(t, q, Open)
	if q.Builder() != "" || q.WorkLink() != "" || q.SubmittedAt() != 0 {
		t.Fatalf("reject must clear builder and work")
	}
	if q.RejectCount() != 1 || q.LastRejectReason() != "missing tests" {
		t.Fatalf("reject count/reason wrong: %d %q", q.RejectCount(), q.LastRejectReason())
	}
	// count keeps going up over several rounds
	mustOK(t, q.Claim(builder2, h0+40), "claim 2")
	mustOK(t, q.Submit(builder2, "https://example.com/2", h0+41), "submit 2")
	mustOK(t, nopay(q.Reject(poster, "still wrong", h0+42)), "reject 2")
	if q.RejectCount() != 2 || q.LastRejectReason() != "still wrong" {
		t.Fatalf("second reject: %d %q", q.RejectCount(), q.LastRejectReason())
	}
}

func TestSubmittedClaimPayout(t *testing.T) {
	q := newSubmitted(t)
	p, err := q.ClaimPayout(builder, q.ReviewDeadline()+1)
	mustOK(t, err, "ClaimPayout")
	mustState(t, q, Paid)
	mustPayout(t, p, PayBuilder, builder, reward)
}

// --- plan section 10 cases ---

// 1. happy path: post, claim, submit, approve; payout is the reward to the builder.
func TestHappyPath(t *testing.T) {
	q := newOpen(t)
	mustOK(t, q.Claim(builder, h0+1), "claim")
	mustOK(t, q.Submit(builder, "https://example.com/pr", h0+2), "submit")
	p, err := q.Approve(poster, h0+3)
	mustOK(t, err, "approve")
	mustPayout(t, p, PayBuilder, builder, reward)
	mustState(t, q, Paid)
}

// 2. cancel an open quest: refund to the poster.  (see TestOpenCancel)
// 3. reject reopens, clears builder, counts.        (see TestSubmittedReject)

// 4. ClaimPayout fails up to and including the review deadline, works one block after.
func TestClaimPayoutDeadline(t *testing.T) {
	q := newSubmitted(t)
	d := q.ReviewDeadline()
	for _, h := range []int64{q.SubmittedAt(), d - 1, d} {
		_, err := q.ClaimPayout(builder, h)
		mustErr(t, ErrReviewDeadlineNotPassed, err, "ClaimPayout early")
		if q.CanClaimPayout(h) {
			t.Fatalf("CanClaimPayout(%d) must be false", h)
		}
	}
	mustState(t, q, Submitted)
	if !q.CanClaimPayout(d + 1) {
		t.Fatalf("CanClaimPayout(d+1) must be true")
	}
	_, err := q.ClaimPayout(builder, d+1)
	mustOK(t, err, "ClaimPayout at d+1")
	mustState(t, q, Paid)
}

// Reject is allowed up to and including the review deadline, not after.
func TestRejectDeadline(t *testing.T) {
	q := newSubmitted(t)
	d := q.ReviewDeadline()
	mustErr(t, ErrReviewDeadlinePassed, nopay(q.Reject(poster, "late", d+1)), "reject at d+1")
	mustState(t, q, Submitted)
	mustOK(t, nopay(q.Reject(poster, "on time", d)), "reject at d")

	q = newSubmitted(t)
	mustOK(t, nopay(q.Reject(poster, "early", q.ReviewDeadline()-1)), "reject at d-1")
}

// Approve stays possible after the review deadline (it pays the builder either way).
func TestApproveAfterReviewDeadline(t *testing.T) {
	q := newSubmitted(t)
	p, err := q.Approve(poster, q.ReviewDeadline()+1000)
	mustOK(t, err, "late approve")
	mustPayout(t, p, PayBuilder, builder, reward)
}

// 5. Release fails up to and including the work deadline, works one block after.
func TestReleaseDeadline(t *testing.T) {
	q := newClaimed(t)
	d := q.WorkDeadline()
	for _, h := range []int64{q.ClaimedAt(), d - 1, d} {
		mustErr(t, ErrWorkDeadlineNotPassed, nopay(q.Release(stranger, h)), "release early")
		if q.CanRelease(h) {
			t.Fatalf("CanRelease(%d) must be false", h)
		}
	}
	mustState(t, q, Claimed)
	if !q.CanRelease(d + 1) {
		t.Fatalf("CanRelease(d+1) must be true")
	}
	mustOK(t, nopay(q.Release(stranger, d+1)), "release at d+1")
	mustState(t, q, Open)
}

// Submit is allowed up to and including the work deadline, not after.
func TestSubmitDeadline(t *testing.T) {
	q := newClaimed(t)
	d := q.WorkDeadline()
	mustErr(t, ErrWorkDeadlinePassed, q.Submit(builder, "https://x.io", d+1), "submit at d+1")
	mustState(t, q, Claimed)
	mustOK(t, q.Submit(builder, "https://x.io", d), "submit at d")

	q = newClaimed(t)
	mustOK(t, q.Submit(builder, "https://x.io", q.WorkDeadline()-1), "submit at d-1")
}

// Release may be called by anyone, including the poster and the builder.
func TestReleaseByAnyone(t *testing.T) {
	for _, who := range []address{poster, builder, stranger} {
		q := newClaimed(t)
		mustOK(t, nopay(q.Release(who, q.WorkDeadline()+1)), "release by "+who.String())
	}
	q := newClaimed(t)
	mustErr(t, ErrInvalidActor, nopay(q.Release("", q.WorkDeadline()+1)), "release by empty")
}

// 6. a stranger cannot approve, reject, cancel, submit, unclaim or claim payout.
func TestStranger(t *testing.T) {
	q := newOpen(t)
	_, err := q.Cancel(stranger, h0+1)
	mustErr(t, ErrNotPoster, err, "stranger cancel")
	_, err = q.Cancel(builder, h0+1)
	mustErr(t, ErrNotPoster, err, "builder-to-be cancel")
	mustState(t, q, Open)

	q = newClaimed(t)
	mustErr(t, ErrNotBuilder, q.Submit(stranger, "https://x.io", h0+11), "stranger submit")
	mustErr(t, ErrNotBuilder, q.Submit(poster, "https://x.io", h0+11), "poster submit")
	mustErr(t, ErrNotBuilder, nopay(q.Unclaim(stranger, h0+11)), "stranger unclaim")
	mustErr(t, ErrNotBuilder, nopay(q.Unclaim(poster, h0+11)), "poster unclaim")
	mustState(t, q, Claimed)

	q = newSubmitted(t)
	_, err = q.Approve(stranger, h0+21)
	mustErr(t, ErrNotPoster, err, "stranger approve")
	_, err = q.Approve(builder, h0+21)
	mustErr(t, ErrNotPoster, err, "builder approve")
	mustErr(t, ErrNotPoster, nopay(q.Reject(stranger, "no", h0+21)), "stranger reject")
	mustErr(t, ErrNotPoster, nopay(q.Reject(builder, "no", h0+21)), "builder reject")
	_, err = q.ClaimPayout(stranger, q.ReviewDeadline()+1)
	mustErr(t, ErrNotBuilder, err, "stranger claim payout")
	_, err = q.ClaimPayout(poster, q.ReviewDeadline()+1)
	mustErr(t, ErrNotBuilder, err, "poster claim payout")
	mustState(t, q, Submitted)
}

// 7. the poster cannot claim their own quest.
func TestPosterCannotClaim(t *testing.T) {
	q := newOpen(t)
	mustErr(t, ErrPosterCannotClaim, q.Claim(poster, h0+1), "poster claim")
	mustErr(t, ErrInvalidActor, q.Claim("", h0+1), "empty claim")
	mustErr(t, ErrInvalidHeight, q.Claim(builder, h0-1), "claim before post")
	mustState(t, q, Open)
}

// 9. a payout cannot happen twice.
func TestNoDoublePayout(t *testing.T) {
	q := newSubmitted(t)
	_, err := q.Approve(poster, h0+30)
	mustOK(t, err, "approve")
	_, err = q.Approve(poster, h0+31)
	mustErr(t, ErrWrongState, err, "approve twice")
	_, err = q.ClaimPayout(builder, q.SubmittedAt()+ReviewBlocks+1)
	mustErr(t, ErrWrongState, err, "approve then claim payout")
	_, err = q.Cancel(poster, h0+32)
	mustErr(t, ErrWrongState, err, "approve then cancel")

	q = newSubmitted(t)
	_, err = q.ClaimPayout(builder, q.ReviewDeadline()+1)
	mustOK(t, err, "claim payout")
	_, err = q.ClaimPayout(builder, h0+ReviewBlocks+100)
	mustErr(t, ErrWrongState, err, "claim payout twice")
	_, err = q.Approve(poster, h0+ReviewBlocks+100)
	mustErr(t, ErrWrongState, err, "claim payout then approve")

	q = newOpen(t)
	_, err = q.Cancel(poster, h0+1)
	mustOK(t, err, "cancel")
	_, err = q.Cancel(poster, h0+2)
	mustErr(t, ErrWrongState, err, "cancel twice")
}

// 10. cancel after Claimed (and after Submitted) fails.
// 10. cancel after Claimed or Submitted does not refund: it only closes the
// quest (no coins move, the builder keeps their turn).
func TestCancelAfterClaimOnlyCloses(t *testing.T) {
	for _, q := range []*Quest{newClaimed(t), newSubmitted(t)} {
		st := q.State()
		p, err := q.Cancel(poster, h0+25)
		mustOK(t, err, "close")
		if p.Due() {
			t.Fatalf("closing must not pay: %+v", p)
		}
		mustState(t, q, st)
		if !q.Closing() || q.HoldsFunds() != true {
			t.Fatalf("closing quest must still hold the reward")
		}
	}
}

// --- closing ---

func newClosing(t *testing.T, mk func(*testing.T) *Quest) *Quest {
	t.Helper()
	q := mk(t)
	p, err := q.Cancel(poster, h0+25)
	mustOK(t, err, "close")
	if p.Due() || !q.Closing() {
		t.Fatalf("close: payout %+v closing %v", p, q.Closing())
	}
	return q
}

// afterRefund checks the quest ended Cancelled and refuses every move.
func afterRefund(t *testing.T, q *Quest, p Payout, what string) {
	t.Helper()
	mustPayout(t, p, RefundPoster, poster, reward)
	mustState(t, q, Cancelled)
	if q.HoldsFunds() || q.Builder() != "" {
		t.Fatalf("%s: cancelled quest must hold nothing and have no builder", what)
	}
	far := h0 + MaxWorkBlocks + ReviewBlocks + 10
	mustErr(t, ErrWrongState, q.Claim(builder2, far), what+": claim again")
	_, err := q.Cancel(poster, far)
	mustErr(t, ErrWrongState, err, what+": cancel again")
	_, err = q.Approve(poster, far)
	mustErr(t, ErrWrongState, err, what+": approve after refund")
	_, err = q.ClaimPayout(builder, far)
	mustErr(t, ErrWrongState, err, what+": payout after refund")
	_, err = q.Release(stranger, far)
	mustErr(t, ErrWrongState, err, what+": release after refund")
}

func TestCloseThenUnclaimRefunds(t *testing.T) {
	q := newClosing(t, newClaimed)
	p, err := q.Unclaim(builder, h0+30)
	mustOK(t, err, "unclaim while closing")
	afterRefund(t, q, p, "unclaim")
}

// A squatter holds a closing quest until the work deadline; then anyone can
// end it and the refund goes to the poster, not to the caller.
func TestCloseThenReleaseRefundsPoster(t *testing.T) {
	q := newClosing(t, newClaimed)
	_, err := q.Release(stranger, q.WorkDeadline())
	mustErr(t, ErrWorkDeadlineNotPassed, err, "release at deadline")
	mustState(t, q, Claimed)
	p, err := q.Release(stranger, q.WorkDeadline()+1)
	mustOK(t, err, "release after deadline")
	afterRefund(t, q, p, "release")
}

func TestCloseThenRejectRefunds(t *testing.T) {
	q := newClosing(t, newSubmitted)
	p, err := q.Reject(poster, "junk", h0+30)
	mustOK(t, err, "reject while closing")
	afterRefund(t, q, p, "reject")
	if q.RejectCount() != 1 || q.LastRejectReason() != "junk" {
		t.Fatalf("reject while closing must still be recorded")
	}
}

// The builder who holds a closing quest keeps every right.
func TestCloseKeepsBuilderRights(t *testing.T) {
	q := newClosing(t, newClaimed)
	mustOK(t, q.Submit(builder, "https://example.com/w", h0+30), "submit while closing")
	p, err := q.Approve(poster, h0+31)
	mustOK(t, err, "approve while closing")
	mustPayout(t, p, PayBuilder, builder, reward)
	mustState(t, q, Paid)

	q = newClosing(t, newSubmitted)
	p, err = q.ClaimPayout(builder, q.ReviewDeadline()+1)
	mustOK(t, err, "timeout payout while closing")
	mustPayout(t, p, PayBuilder, builder, reward)
	mustState(t, q, Paid)
}

func TestCloseRules(t *testing.T) {
	q := newClaimed(t)
	_, err := q.Cancel(stranger, h0+20)
	mustErr(t, ErrNotPoster, err, "stranger close")
	_, err = q.Cancel(builder, h0+20)
	mustErr(t, ErrNotPoster, err, "builder close")
	if q.Closing() {
		t.Fatalf("refused close must not mark the quest")
	}
	q = newClosing(t, newClaimed)
	_, err = q.Cancel(poster, h0+26)
	mustErr(t, ErrAlreadyClosing, err, "close twice")
	if newOpen(t).Closing() {
		t.Fatalf("open quest is not closing")
	}
	// cancelling an Open quest is immediate and never "closing"
	o := newOpen(t)
	p, err := o.Cancel(poster, h0+1)
	mustOK(t, err, "cancel open")
	if o.Closing() {
		t.Fatalf("open cancel must not set closing")
	}
	mustPayout(t, p, RefundPoster, poster, reward)
}

// Without closing, the moves that reopen a quest never pay.
func TestReopenMovesNeverPay(t *testing.T) {
	q := newClaimed(t)
	mustOK(t, nopay(q.Unclaim(builder, h0+11)), "unclaim")
	mustState(t, q, Open)
	q = newClaimed(t)
	mustOK(t, nopay(q.Release(stranger, q.WorkDeadline()+1)), "release")
	mustState(t, q, Open)
	q = newSubmitted(t)
	mustOK(t, nopay(q.Reject(poster, "no", h0+21)), "reject")
	mustState(t, q, Open)
}

// The timeout rule, documented: a builder who submits anything (even junk)
// is paid after the review window if the poster does nothing. A reject at the
// last block of the window prevents it.
func TestJunkSubmissionTimeout(t *testing.T) {
	q := newClaimed(t)
	mustOK(t, q.Submit(builder, "https://x", h0+11), "junk submit")
	p, err := q.ClaimPayout(builder, q.ReviewDeadline()+1)
	mustOK(t, err, "silent poster")
	mustPayout(t, p, PayBuilder, builder, reward)

	q = newClaimed(t)
	mustOK(t, q.Submit(builder, "https://x", h0+11), "junk submit")
	mustOK(t, nopay(q.Reject(poster, "junk", q.ReviewDeadline())), "reject at the last block")
	_, err = q.ClaimPayout(builder, q.SubmittedAt()+ReviewBlocks+1)
	mustErr(t, ErrWrongState, err, "no payout after reject")
}

// 11. text over the limits fails; a link without https:// fails.
func TestLinkAndReasonValidation(t *testing.T) {
	bad := []struct {
		link string
		want error
	}{
		{"", ErrLinkEmpty},
		{"http://example.com", ErrLinkNotHTTPS},
		{"HTTPS://example.com", ErrLinkNotHTTPS},
		{"ftp://example.com", ErrLinkNotHTTPS},
		{"example.com", ErrLinkNotHTTPS},
		{"https://", ErrLinkNotHTTPS},
		{" https://example.com", ErrLinkNotHTTPS},
		{"javascript:alert(1)", ErrLinkNotHTTPS},
		{"https://example.com/a b", ErrLinkInvalid},
		{"https://example.com/\nx", ErrLinkInvalid},
		{"https://example.com/\x7f", ErrLinkInvalid},
		{"https://" + strings.Repeat("a", MaxLinkLen-len("https://")+1), ErrLinkTooLong},
	}
	for _, c := range bad {
		q := newClaimed(t)
		mustErr(t, c.want, q.Submit(builder, c.link, h0+20), "link "+c.link)
		mustState(t, q, Claimed)
	}
	q := newClaimed(t)
	mustOK(t, q.Submit(builder, "https://"+strings.Repeat("a", MaxLinkLen-len("https://")), h0+20), "link at max")

	q = newSubmitted(t)
	mustErr(t, ErrReasonEmpty, nopay(q.Reject(poster, "", h0+30)), "empty reason")
	mustErr(t, ErrReasonEmpty, nopay(q.Reject(poster, " \t", h0+30)), "blank reason")
	mustErr(t, ErrReasonTooLong, nopay(q.Reject(poster, strings.Repeat("r", MaxReasonLen+1), h0+30)), "long reason")
	mustState(t, q, Submitted)
	mustOK(t, nopay(q.Reject(poster, strings.Repeat("r", MaxReasonLen), h0+30)), "reason at max")
}

// --- at least one illegal move from every state (rule 8) ---

func TestIllegalMovesPerState(t *testing.T) {
	far := h0 + MaxWorkBlocks + ReviewBlocks + 10 // past every deadline
	type move struct {
		name string
		do   func(q *Quest) error
	}
	pay := func(p Payout, err error) error { return err }
	moves := []move{
		{"Claim", func(q *Quest) error { return q.Claim(builder2, far) }},
		{"Cancel", func(q *Quest) error { return pay(q.Cancel(poster, far)) }},
		{"Submit", func(q *Quest) error { return q.Submit(q.Builder(), "https://x.io", q.ClaimedAt()+1) }},
		{"Unclaim", func(q *Quest) error { return nopay(q.Unclaim(q.Builder(), far)) }},
		{"Release", func(q *Quest) error { return nopay(q.Release(stranger, far)) }},
		{"Approve", func(q *Quest) error { return pay(q.Approve(poster, far)) }},
		{"Reject", func(q *Quest) error { return nopay(q.Reject(poster, "no", q.SubmittedAt()+1)) }},
		{"ClaimPayout", func(q *Quest) error { return pay(q.ClaimPayout(q.Builder(), far)) }},
	}
	// allowed moves per state (section 4); everything else must be ErrWrongState
	allowed := map[State]map[string]bool{
		Open:      {"Claim": true, "Cancel": true},
		Claimed:   {"Submit": true, "Unclaim": true, "Release": true, "Cancel": true},
		Submitted: {"Approve": true, "Reject": true, "ClaimPayout": true, "Cancel": true},
		Paid:      {},
		Cancelled: {},
	}
	makers := map[State]func(*testing.T) *Quest{
		Open:      newOpen,
		Claimed:   newClaimed,
		Submitted: newSubmitted,
		Paid:      newPaid,
		Cancelled: newCancelled,
	}
	for _, st := range []State{Open, Claimed, Submitted, Paid, Cancelled} {
		for _, m := range moves {
			q := makers[st](t)
			err := m.do(q)
			if allowed[st][m.name] {
				if err != nil {
					t.Errorf("%s from %s: want ok, got %v", m.name, st, err)
				}
				continue
			}
			if err != ErrWrongState {
				t.Errorf("%s from %s: want ErrWrongState, got %v", m.name, st, err)
			}
			if q.State() != st {
				t.Errorf("%s from %s: state changed to %s", m.name, st, q.State())
			}
		}
	}
}

// --- escrow accounting at package level (towards rule 12) ---

func TestHeldFundsAccounting(t *testing.T) {
	var qs []*Quest
	held := int64(0) // what a realm would hold
	post := func(r int64) *Quest {
		q, err := NewQuest(uint64(len(qs)+1), poster, "q", "", r, workBlocks, h0)
		mustOK(t, err, "post")
		qs = append(qs, q)
		held += r
		return q
	}
	pay := func(p Payout, err error) {
		mustOK(t, err, "payout move")
		held -= p.Amount
	}
	a, b, c, d, e := post(1), post(20), post(300), post(4000), post(50000)
	pay(a.Cancel(poster, h0+1))
	mustOK(t, b.Claim(builder, h0+1), "b claim")
	mustOK(t, b.Submit(builder, "https://x.io", h0+2), "b submit")
	pay(b.Approve(poster, h0+3))
	mustOK(t, c.Claim(builder, h0+1), "c claim")
	mustOK(t, c.Submit(builder, "https://x.io", h0+2), "c submit")
	pay(c.ClaimPayout(builder, c.ReviewDeadline()+1))
	mustOK(t, d.Claim(builder, h0+1), "d claim")
	mustOK(t, nopay(d.Release(stranger, d.WorkDeadline()+1)), "d release")
	mustOK(t, e.Claim(builder2, h0+1), "e claim")
	mustOK(t, e.Submit(builder2, "https://x.io", h0+2), "e submit")
	mustOK(t, nopay(e.Reject(poster, "no", h0+3)), "e reject")

	sum := int64(0)
	for _, q := range qs {
		if q.HoldsFunds() {
			sum += q.Reward()
		}
	}
	if sum != held || held != 4000+50000 {
		t.Fatalf("held %d, sum of open escrows %d", held, sum)
	}
}

func TestStateStrings(t *testing.T) {
	names := map[State]string{Open: "Open", Claimed: "Claimed", Submitted: "Submitted", Paid: "Paid", Cancelled: "Cancelled", State(0): "Unknown"}
	for s, n := range names {
		if s.String() != n {
			t.Errorf("State(%d).String() = %q, want %q", s, s.String(), n)
		}
	}
	if !Paid.IsFinal() || !Cancelled.IsFinal() || Open.IsFinal() || Claimed.IsFinal() || Submitted.IsFinal() {
		t.Errorf("IsFinal wrong")
	}
	if PayBuilder.String() != "PayBuilder" || RefundPoster.String() != "RefundPoster" {
		t.Errorf("PayoutKind strings wrong")
	}
}
