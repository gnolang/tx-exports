package trickle

import (
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

var (
	alice = testutils.TestAddress("alice")
	bob   = testutils.TestAddress("bob")
)

func mk(t *testing.T, deposit, start, cliff, end int64, cancelable bool) Stream {
	t.Helper()
	s, err := New(alice, bob, deposit, start, cliff, end, cancelable)
	uassert.NoError(t, err)
	return s
}

func checkInvariant(t *testing.T, s Stream, now int64) {
	t.Helper()
	sum := s.Withdrawn + s.Withdrawable(now) + s.Refundable(now) + s.Refunded
	if sum != s.Deposit {
		t.Fatalf("invariant broken at %d: %d != %d", now, sum, s.Deposit)
	}
	if s.Withdrawable(now) < 0 || s.Refundable(now) < 0 {
		t.Fatalf("negative balance at %d", now)
	}
}

func TestNewValidation(t *testing.T) {
	cases := []struct {
		name                       string
		from, to                   address
		deposit, start, cliff, end int64
		want                       error
	}{
		{"zero deposit", alice, bob, 0, 0, 0, 10, ErrZeroDeposit},
		{"negative deposit", alice, bob, -5, 0, 0, 10, ErrZeroDeposit},
		{"bad recipient", alice, address("nope"), 1, 0, 0, 10, ErrBadAddress},
		{"self", alice, alice, 1, 0, 0, 10, ErrSelfStream},
		{"zero duration", alice, bob, 1, 10, 10, 10, ErrBadSchedule},
		{"cliff before start", alice, bob, 1, 10, 5, 20, ErrBadSchedule},
		{"cliff after end", alice, bob, 1, 10, 30, 20, ErrBadSchedule},
		{"negative start", alice, bob, 1, -1, 0, 20, ErrBadSchedule},
		{"too long", alice, bob, 1, 0, 0, MaxDuration + 1, ErrTooLong},
	}
	for _, c := range cases {
		_, err := New(c.from, c.to, c.deposit, c.start, c.cliff, c.end, true)
		uassert.ErrorIs(t, err, c.want, c.name)
	}
}

func TestLinearVesting(t *testing.T) {
	s := mk(t, 1000, 100, 100, 200, true)
	uassert.Equal(t, int64(0), s.Vested(50))
	uassert.Equal(t, int64(0), s.Vested(100))
	uassert.Equal(t, int64(10), s.Vested(101))
	uassert.Equal(t, int64(500), s.Vested(150))
	uassert.Equal(t, int64(990), s.Vested(199))
	uassert.Equal(t, int64(1000), s.Vested(200))
	uassert.Equal(t, int64(1000), s.Vested(1<<40))
	for now := int64(0); now < 300; now += 7 {
		checkInvariant(t, s, now)
	}
}

func TestCliff(t *testing.T) {
	s := mk(t, 1000, 0, 250, 1000, true)
	uassert.Equal(t, int64(0), s.Vested(249))
	uassert.Equal(t, int64(250), s.Vested(250)) // cliff releases the backlog
	uassert.Equal(t, Cliffed.String(), s.Status(10).String())
	uassert.Equal(t, Streaming.String(), s.Status(250).String())
}

func TestRoundingNeverOverpays(t *testing.T) {
	s := mk(t, 7, 0, 0, 3, true)
	uassert.Equal(t, int64(2), s.Vested(1))
	uassert.Equal(t, int64(4), s.Vested(2))
	uassert.Equal(t, int64(7), s.Vested(3))
}

func TestHugeAmountsDoNotOverflow(t *testing.T) {
	const max = int64(1<<63 - 1)
	s := mk(t, max, 0, 0, MaxDuration, true)
	uassert.Equal(t, max/2, s.Vested(MaxDuration/2))
	uassert.Equal(t, max, s.Vested(MaxDuration))
	checkInvariant(t, s, MaxDuration-1)
}

func TestWithdraw(t *testing.T) {
	s := mk(t, 1000, 0, 0, 100, true)

	_, err := s.Withdraw(0, 0)
	uassert.ErrorIs(t, err, ErrNothingToPay)

	paid, err := s.Withdraw(30, 100)
	uassert.NoError(t, err)
	uassert.Equal(t, int64(100), paid)
	uassert.Equal(t, int64(200), s.Withdrawable(30))

	_, err = s.Withdraw(30, 201)
	uassert.ErrorIs(t, err, ErrOverWithdraw)
	_, err = s.Withdraw(30, -1)
	uassert.ErrorIs(t, err, ErrBadAmount)

	paid, err = s.Withdraw(30, 0)
	uassert.NoError(t, err)
	uassert.Equal(t, int64(200), paid)
	checkInvariant(t, s, 30)

	paid, err = s.Withdraw(500, 0)
	uassert.NoError(t, err)
	uassert.Equal(t, int64(700), paid)
	uassert.Equal(t, Settled.String(), s.Status(500).String())
	checkInvariant(t, s, 500)
}

func TestCancelSplitsDeposit(t *testing.T) {
	s := mk(t, 1000, 0, 0, 100, true)
	_, err := s.Withdraw(20, 0)
	uassert.NoError(t, err)

	toR, toS, err := s.CancelBySender(60)
	uassert.NoError(t, err)
	uassert.Equal(t, int64(400), toR)
	uassert.Equal(t, int64(400), toS)
	uassert.Equal(t, Canceled.String(), s.Status(60).String())

	// Frozen: time passing changes nothing, nothing left to claim.
	uassert.Equal(t, int64(0), s.Withdrawable(1000))
	uassert.Equal(t, int64(0), s.Refundable(1000))
	checkInvariant(t, s, 1000)

	_, _, err = s.Cancel(70)
	uassert.ErrorIs(t, err, ErrCanceled)
	_, err = s.Withdraw(70, 0)
	uassert.ErrorIs(t, err, ErrNothingToPay)
}

func TestCancelBeforeCliffRefundsEverything(t *testing.T) {
	s := mk(t, 1000, 0, 50, 100, true)
	toR, toS, err := s.CancelBySender(49)
	uassert.NoError(t, err)
	uassert.Equal(t, int64(0), toR)
	uassert.Equal(t, int64(1000), toS)
}

func TestCancelRules(t *testing.T) {
	locked := mk(t, 1000, 0, 0, 100, false)
	_, _, err := locked.CancelBySender(10)
	uassert.ErrorIs(t, err, ErrNotCancelable)

	// The recipient may still walk away from a non-cancelable stream.
	toR, toS, err := locked.Cancel(10)
	uassert.NoError(t, err)
	uassert.Equal(t, int64(100), toR)
	uassert.Equal(t, int64(900), toS)

	done := mk(t, 1000, 0, 0, 100, true)
	_, _, err = done.CancelBySender(100)
	uassert.ErrorIs(t, err, ErrEnded)
}

func TestRatePerDay(t *testing.T) {
	uassert.Equal(t, int64(1000), mk(t, 30000, 0, 0, 30*86400, true).RatePerDay())
	uassert.Equal(t, int64(500), mk(t, 500, 0, 0, 60, true).RatePerDay())
}
