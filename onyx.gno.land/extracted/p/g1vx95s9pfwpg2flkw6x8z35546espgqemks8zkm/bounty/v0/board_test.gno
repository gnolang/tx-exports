package bounty

import (
	"testing"
	"time"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
	"gno.land/p/nt/urequire/v0"
)

var (
	poster = testutils.TestAddress("poster")
	hunter = testutils.TestAddress("hunter")
	other  = testutils.TestAddress("other")
	t0     = time.Unix(1_800_000_000, 0)
)

func newBoard() *Board {
	return NewBoard(Config{MinReward: 100, ReviewWindow: 48 * time.Hour})
}

func post(t *testing.T, bd *Board) *Bounty {
	b, err := bd.Post(poster, "Translate the docs", "German please", 500, 24*time.Hour, t0)
	urequire.NoError(t, err)
	return b
}

func TestPostValidation(t *testing.T) {
	bd := newBoard()

	_, err := bd.Post(poster, "  ", "", 500, 24*time.Hour, t0)
	uassert.ErrorIs(t, err, ErrBadTitle)

	_, err = bd.Post(poster, "ok", "", 99, 24*time.Hour, t0)
	uassert.ErrorIs(t, err, ErrRewardTooLow)

	_, err = bd.Post(poster, "ok", "", 500, time.Minute, t0)
	uassert.ErrorIs(t, err, ErrBadWindow)

	_, err = bd.Post(poster, "ok", "", 500, 365*24*time.Hour, t0)
	uassert.ErrorIs(t, err, ErrBadWindow)

	b := post(t, bd)
	uassert.Equal(t, uint64(1), b.ID)
	uassert.True(t, b.Status == StatusOpen)
	uassert.Equal(t, int64(500), bd.Escrowed())
	uassert.Equal(t, 1, bd.Stats(poster).Posted)
}

func TestHappyPath(t *testing.T) {
	bd := newBoard()
	b := post(t, bd)

	_, err := bd.Claim(b.ID, poster, t0)
	uassert.ErrorIs(t, err, ErrOwnBounty)

	_, err = bd.Claim(b.ID, hunter, t0.Add(time.Hour))
	urequire.NoError(t, err)
	uassert.True(t, b.Status == StatusClaimed)
	uassert.Equal(t, hunter, b.Hunter)

	_, err = bd.Claim(b.ID, other, t0.Add(time.Hour))
	uassert.ErrorIs(t, err, ErrNotOpen)

	_, err = bd.Submit(b.ID, other, "https://example.com/pr/1", t0.Add(2*time.Hour))
	uassert.ErrorIs(t, err, ErrNotHunter)

	_, err = bd.Submit(b.ID, hunter, "", t0.Add(2*time.Hour))
	uassert.ErrorIs(t, err, ErrBadProof)

	_, err = bd.Submit(b.ID, hunter, "https://example.com/pr/1", t0.Add(2*time.Hour))
	urequire.NoError(t, err)
	uassert.True(t, b.Status == StatusSubmitted)

	_, err = bd.Approve(b.ID, other, t0.Add(3*time.Hour))
	uassert.ErrorIs(t, err, ErrNotPoster)

	_, err = bd.Approve(b.ID, poster, t0.Add(3*time.Hour))
	urequire.NoError(t, err)
	uassert.True(t, b.Status == StatusPaid)
	uassert.Equal(t, int64(0), bd.Escrowed())
	uassert.Equal(t, int64(500), bd.TotalPaid())

	hs := bd.Stats(hunter)
	uassert.Equal(t, 1, hs.Completed)
	uassert.Equal(t, int64(500), hs.Earned)
	uassert.Equal(t, int64(500), bd.Stats(poster).PaidOut)
	uassert.Equal(t, 4, len(b.History))

	_, err = bd.Approve(b.ID, poster, t0.Add(4*time.Hour))
	uassert.ErrorIs(t, err, ErrNotSubmitted)
}

func TestRejectReopens(t *testing.T) {
	bd := newBoard()
	b := post(t, bd)
	bd.Claim(b.ID, hunter, t0)
	bd.Submit(b.ID, hunter, "bad work", t0)

	_, err := bd.Reject(b.ID, poster, "not German", t0.Add(time.Hour))
	urequire.NoError(t, err)
	uassert.True(t, b.Status == StatusOpen)
	uassert.Equal(t, address(""), b.Hunter)
	uassert.Equal(t, 1, bd.Stats(hunter).Rejected)
	uassert.Equal(t, 1, bd.Stats(poster).RejectionsMade)
	uassert.Equal(t, int64(500), bd.Escrowed())

	// someone else can now take it
	_, err = bd.Claim(b.ID, other, t0.Add(2*time.Hour))
	urequire.NoError(t, err)
}

func TestClaimExpiryAndRelease(t *testing.T) {
	bd := newBoard()
	b := post(t, bd)
	bd.Claim(b.ID, hunter, t0)

	_, err := bd.Release(b.ID, other, t0.Add(23*time.Hour))
	uassert.ErrorIs(t, err, ErrClaimActive)

	_, err = bd.Submit(b.ID, hunter, "late", t0.Add(25*time.Hour))
	uassert.ErrorIs(t, err, ErrClaimExpired)

	_, err = bd.Release(b.ID, other, t0.Add(25*time.Hour))
	urequire.NoError(t, err)
	uassert.True(t, b.Status == StatusOpen)
	uassert.Equal(t, 1, bd.Stats(hunter).Abandoned)
}

func TestUnclaim(t *testing.T) {
	bd := newBoard()
	b := post(t, bd)
	bd.Claim(b.ID, hunter, t0)

	_, err := bd.Unclaim(b.ID, other, t0)
	uassert.ErrorIs(t, err, ErrNotHunter)

	_, err = bd.Unclaim(b.ID, hunter, t0)
	urequire.NoError(t, err)
	uassert.True(t, b.Status == StatusOpen)
}

func TestCollectAfterReviewWindow(t *testing.T) {
	bd := newBoard()
	b := post(t, bd)
	bd.Claim(b.ID, hunter, t0)
	bd.Submit(b.ID, hunter, "done", t0.Add(time.Hour))

	_, err := bd.Collect(b.ID, hunter, t0.Add(48*time.Hour))
	uassert.ErrorIs(t, err, ErrReviewActive)

	_, err = bd.Collect(b.ID, other, t0.Add(50*time.Hour))
	uassert.ErrorIs(t, err, ErrNotHunter)

	_, err = bd.Collect(b.ID, hunter, t0.Add(50*time.Hour))
	urequire.NoError(t, err)
	uassert.True(t, b.Status == StatusPaid)
	uassert.Equal(t, int64(500), bd.Stats(hunter).Earned)
}

func TestCancel(t *testing.T) {
	bd := newBoard()
	b := post(t, bd)

	_, err := bd.Cancel(b.ID, other, t0)
	uassert.ErrorIs(t, err, ErrNotPoster)

	bd.Claim(b.ID, hunter, t0)
	_, err = bd.Cancel(b.ID, poster, t0)
	uassert.ErrorIs(t, err, ErrNotOpen)

	bd.Unclaim(b.ID, hunter, t0)
	_, err = bd.Cancel(b.ID, poster, t0)
	urequire.NoError(t, err)
	uassert.True(t, b.Status == StatusCancelled)
	uassert.Equal(t, int64(0), bd.Escrowed())
}

func TestListAndLeaderboard(t *testing.T) {
	bd := newBoard()
	for i := 0; i < 5; i++ {
		post(t, bd)
	}
	// hunter completes #1 and #2, other completes #3
	for _, id := range []uint64{1, 2} {
		bd.Claim(id, hunter, t0)
		bd.Submit(id, hunter, "ok", t0)
		bd.Approve(id, poster, t0)
	}
	bd.Claim(3, other, t0)
	bd.Submit(3, other, "ok", t0)
	bd.Approve(3, poster, t0)

	open, total := bd.List(ByStatus(StatusOpen), 0, 10)
	uassert.Equal(t, 2, total)
	uassert.Equal(t, uint64(5), open[0].ID) // newest first

	page, total := bd.List(nil, 1, 2)
	uassert.Equal(t, 5, total)
	uassert.Equal(t, 2, len(page))
	uassert.Equal(t, uint64(4), page[0].ID)

	uassert.Equal(t, 3, bd.Count(ByStatus(StatusPaid)))
	uassert.Equal(t, 2, bd.Count(ByAddress(hunter)))

	top := bd.Leaderboard(10)
	urequire.Equal(t, 2, len(top))
	uassert.Equal(t, hunter, top[0].Address)
	uassert.Equal(t, other, top[1].Address)

	uassert.Equal(t, 1, len(bd.Leaderboard(1)))
	uassert.Equal(t, 3, bd.Participants())
}

func TestStatusRoundTrip(t *testing.T) {
	for _, s := range []Status{StatusOpen, StatusClaimed, StatusSubmitted, StatusPaid, StatusCancelled} {
		got, ok := ParseStatus(s.String())
		uassert.True(t, ok)
		uassert.True(t, got == s)
	}
	_, ok := ParseStatus("nope")
	uassert.False(t, ok)
}
