package trickle

import (
	"errors"
	"math/bits"
)

// MaxDuration bounds a stream's length (100 years) so timestamps stay sane.
const MaxDuration int64 = 100 * 365 * 24 * 60 * 60

var (
	ErrZeroDeposit   = errors.New("trickle: deposit must be positive")
	ErrBadAddress    = errors.New("trickle: invalid sender or recipient address")
	ErrSelfStream    = errors.New("trickle: sender and recipient must differ")
	ErrBadSchedule   = errors.New("trickle: need 0 <= start <= cliff <= end and start < end")
	ErrTooLong       = errors.New("trickle: duration exceeds 100 years")
	ErrNothingToPay  = errors.New("trickle: nothing to withdraw yet")
	ErrOverWithdraw  = errors.New("trickle: amount exceeds withdrawable balance")
	ErrBadAmount     = errors.New("trickle: amount must not be negative")
	ErrCanceled      = errors.New("trickle: stream already canceled")
	ErrNotCancelable = errors.New("trickle: stream is not cancelable")
	ErrEnded         = errors.New("trickle: stream already fully vested")
)

// Status is the lifecycle phase of a stream at a given time.
type Status int

const (
	Scheduled Status = iota // before Start
	Cliffed                 // started, cliff not reached
	Streaming               // unlocking
	Completed               // fully vested, funds still to withdraw
	Settled                 // fully vested and fully withdrawn
	Canceled                // canceled by a party; both sides paid out
)

func (s Status) String() string {
	switch s {
	case Scheduled:
		return "scheduled"
	case Cliffed:
		return "cliff"
	case Streaming:
		return "streaming"
	case Completed:
		return "completed"
	case Settled:
		return "settled"
	case Canceled:
		return "canceled"
	}
	return "unknown"
}

// Stream is a linear vesting schedule over a fixed deposit.
// Times are unix seconds; amounts are in the smallest unit of the asset.
type Stream struct {
	Sender     address
	Recipient  address
	Deposit    int64
	Start      int64
	Cliff      int64
	End        int64
	Withdrawn  int64
	Cancelable bool
	CanceledAt int64 // 0 while live
	// Refunded is what Cancel returned to the sender.
	Refunded int64
}

// New validates a schedule and returns a fresh stream.
func New(sender, recipient address, deposit, start, cliff, end int64, cancelable bool) (Stream, error) {
	if deposit <= 0 {
		return Stream{}, ErrZeroDeposit
	}
	if !sender.IsValid() || !recipient.IsValid() {
		return Stream{}, ErrBadAddress
	}
	if sender == recipient {
		return Stream{}, ErrSelfStream
	}
	if start < 0 || cliff < start || end < cliff || end <= start {
		return Stream{}, ErrBadSchedule
	}
	if end-start > MaxDuration {
		return Stream{}, ErrTooLong
	}
	return Stream{
		Sender:     sender,
		Recipient:  recipient,
		Deposit:    deposit,
		Start:      start,
		Cliff:      cliff,
		End:        end,
		Cancelable: cancelable,
	}, nil
}

// IsCanceled reports whether Cancel has run.
func (s Stream) IsCanceled() bool { return s.CanceledAt != 0 }

// Vested is the amount unlocked for the recipient at time now, including
// what was already withdrawn. It never decreases and never exceeds Deposit.
// After cancellation it is frozen at the cancellation time.
func (s Stream) Vested(now int64) int64 {
	if s.IsCanceled() {
		return s.Deposit - s.Refunded
	}
	if now < s.Cliff || now <= s.Start {
		return 0
	}
	if now >= s.End {
		return s.Deposit
	}
	return mulDiv(s.Deposit, now-s.Start, s.End-s.Start)
}

// Withdrawable is what the recipient can claim at time now.
func (s Stream) Withdrawable(now int64) int64 {
	return s.Vested(now) - s.Withdrawn
}

// Refundable is what the sender would get back by canceling at time now.
// It is zero for a canceled stream.
func (s Stream) Refundable(now int64) int64 {
	return s.Deposit - s.Refunded - s.Vested(now)
}

// Status returns the lifecycle phase at time now.
func (s Stream) Status(now int64) Status {
	switch {
	case s.IsCanceled():
		return Canceled
	case now < s.Start:
		return Scheduled
	case now < s.Cliff:
		return Cliffed
	case now < s.End:
		return Streaming
	case s.Withdrawn < s.Deposit:
		return Completed
	}
	return Settled
}

// Withdraw records a claim of amount by the recipient and returns the amount
// to pay out. An amount of 0 claims everything withdrawable.
func (s *Stream) Withdraw(now, amount int64) (int64, error) {
	if amount < 0 {
		return 0, ErrBadAmount
	}
	avail := s.Withdrawable(now)
	if avail == 0 {
		return 0, ErrNothingToPay
	}
	if amount == 0 {
		amount = avail
	}
	if amount > avail {
		return 0, ErrOverWithdraw
	}
	s.Withdrawn += amount
	return amount, nil
}

// Cancel stops the stream at time now. It returns what must be paid to the
// recipient (vested but unclaimed) and refunded to the sender (unvested).
// The stream is fully settled afterwards. Cancel does not check Cancelable:
// that flag binds the sender only, so the caller decides who may cancel
// (see CancelBySender).
func (s *Stream) Cancel(now int64) (toRecipient, toSender int64, err error) {
	if s.IsCanceled() {
		return 0, 0, ErrCanceled
	}
	if now >= s.End {
		return 0, 0, ErrEnded
	}
	vested := s.Vested(now)
	toRecipient = vested - s.Withdrawn
	toSender = s.Deposit - vested
	s.Refunded = toSender
	s.Withdrawn = vested
	s.CanceledAt = now
	if s.CanceledAt == 0 {
		s.CanceledAt = 1
	}
	return toRecipient, toSender, nil
}

// CancelBySender is Cancel with the Cancelable flag enforced.
func (s *Stream) CancelBySender(now int64) (toRecipient, toSender int64, err error) {
	if !s.Cancelable {
		return 0, 0, ErrNotCancelable
	}
	return s.Cancel(now)
}

// RatePerDay is the average unlock rate, per 86400 seconds, rounded down.
func (s Stream) RatePerDay() int64 {
	d := s.End - s.Start
	if d <= 86400 {
		return s.Deposit
	}
	return mulDiv(s.Deposit, 86400, d)
}

// mulDiv returns floor(a*b/c) for non-negative a, b and positive c with
// a*b/c <= MaxInt64, using a 128-bit intermediate so a*b cannot overflow.
func mulDiv(a, b, c int64) int64 {
	hi, lo := bits.Mul64(uint64(a), uint64(b))
	q, _ := bits.Div64(hi, lo, uint64(c))
	return int64(q)
}
