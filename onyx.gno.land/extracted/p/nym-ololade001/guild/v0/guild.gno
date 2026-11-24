// Package guild implements the quest state machine used by the Guildhall
// bounty board. It holds no coins and keeps no globals: a realm posts a
// Quest, locks the reward itself, and drives the quest through these pure
// transition methods.
package guild

import (
	"errors"
	"strings"
)

// Field limits, in bytes, and block-count bounds for leases and review
// windows.
const (
	MaxTitle  = 80
	MaxSpec   = 2000
	MaxURL    = 300
	MaxNote   = 500
	MinBlocks = 100
	MaxBlocks = 500000
)

var (
	ErrInvalidPoster    = errors.New("guild: invalid poster address")
	ErrEmptyTitle       = errors.New("guild: title is required")
	ErrTitleTooLong     = errors.New("guild: title exceeds 80 bytes")
	ErrSpecTooLong      = errors.New("guild: spec exceeds 2000 bytes")
	ErrInvalidReward    = errors.New("guild: reward must be positive")
	ErrInvalidLease     = errors.New("guild: lease blocks out of range [100, 500000]")
	ErrInvalidReview    = errors.New("guild: review blocks out of range [100, 500000]")
	ErrInvalidDeadline  = errors.New("guild: deadline must be later than height plus lease")
	ErrNotOpen          = errors.New("guild: quest is not open")
	ErrNotClaimed       = errors.New("guild: quest is not claimed")
	ErrNotSubmitted     = errors.New("guild: quest is not submitted")
	ErrNotPoster        = errors.New("guild: caller is not the poster")
	ErrNotWorker        = errors.New("guild: caller is not the worker")
	ErrSelfClaim        = errors.New("guild: poster cannot claim their own quest")
	ErrPastDeadline     = errors.New("guild: deadline has passed")
	ErrLeaseExpired     = errors.New("guild: lease has expired")
	ErrReviewOpen       = errors.New("guild: review window is still open")
	ErrReviewClosed     = errors.New("guild: review window has closed")
	ErrBeforeDeadline   = errors.New("guild: deadline has not passed")
	ErrSubmittedPending = errors.New("guild: quest has a pending submission")
	ErrProofURLEmpty    = errors.New("guild: proof URL is required")
	ErrProofURLTooLong  = errors.New("guild: proof URL exceeds 300 bytes")
	ErrNoteTooLong      = errors.New("guild: note exceeds 500 bytes")
	ErrReasonTooLong    = errors.New("guild: reason exceeds 500 bytes")
)

// Status is the lifecycle state of a Quest.
type Status int

const (
	Open Status = iota
	Claimed
	Submitted
	Paid
	Refunded
	Cancelled
)

func (s Status) String() string {
	switch s {
	case Open:
		return "open"
	case Claimed:
		return "claimed"
	case Submitted:
		return "submitted"
	case Paid:
		return "paid"
	case Refunded:
		return "refunded"
	case Cancelled:
		return "cancelled"
	}
	return "unknown"
}

// Event records one state change in a quest's history.
type Event struct {
	Height int64
	Actor  address
	Action string
	Detail string
}

// Quest is a single bounty: posted with an escrowed reward, claimed under a
// lease, submitted with proof, then paid, rejected back to open, refunded or
// cancelled.
type Quest struct {
	ID           uint64
	Poster       address
	Title        string
	Spec         string
	Reward       int64
	LeaseBlocks  int64
	ReviewBlocks int64
	Deadline     int64
	Status       Status
	Worker       address
	LeaseEnd     int64
	ProofURL     string
	Note         string
	SubmittedAt  int64
	AutoPaid     bool
	History      []Event
}

// New validates its inputs and returns an Open quest with a "posted" event
// recorded at height h.
func New(id uint64, poster address, title, spec string, reward, leaseBlocks, reviewBlocks, deadline, h int64) (*Quest, error) {
	if !poster.IsValid() {
		return nil, ErrInvalidPoster
	}
	title = strings.TrimSpace(title)
	if title == "" {
		return nil, ErrEmptyTitle
	}
	if len(title) > MaxTitle {
		return nil, ErrTitleTooLong
	}
	if len(spec) > MaxSpec {
		return nil, ErrSpecTooLong
	}
	if reward <= 0 {
		return nil, ErrInvalidReward
	}
	if leaseBlocks < MinBlocks || leaseBlocks > MaxBlocks {
		return nil, ErrInvalidLease
	}
	if reviewBlocks < MinBlocks || reviewBlocks > MaxBlocks {
		return nil, ErrInvalidReview
	}
	if deadline <= h+leaseBlocks {
		return nil, ErrInvalidDeadline
	}
	q := &Quest{
		ID:           id,
		Poster:       poster,
		Title:        title,
		Spec:         spec,
		Reward:       reward,
		LeaseBlocks:  leaseBlocks,
		ReviewBlocks: reviewBlocks,
		Deadline:     deadline,
		Status:       Open,
	}
	q.appendEvent(h, poster, "posted", "")
	return q, nil
}

// StatusAt reports the effective status at height h: a Claimed quest whose
// lease has run out reads as Open again.
func (q *Quest) StatusAt(h int64) Status {
	if q.Status == Claimed && h > q.LeaseEnd {
		return Open
	}
	return q.Status
}

// ReviewEnd is the last height at which the poster may reject a submission.
func (q *Quest) ReviewEnd() int64 {
	return q.SubmittedAt + q.ReviewBlocks
}

// Claim lets w take the quest while it is Open — including a stale claim
// whose lease expired. The poster can never claim their own quest.
func (q *Quest) Claim(w address, h int64) error {
	if q.StatusAt(h) != Open {
		return ErrNotOpen
	}
	if w == q.Poster {
		return ErrSelfClaim
	}
	if h >= q.Deadline {
		return ErrPastDeadline
	}
	if q.Status == Claimed {
		q.appendEvent(h, q.Worker, "expired", q.Worker.String())
	}
	q.Worker = w
	q.LeaseEnd = h + q.LeaseBlocks
	q.Status = Claimed
	q.appendEvent(h, w, "claimed", "")
	return nil
}

// Submit turns in the worker's proof while the lease is live.
func (q *Quest) Submit(w address, h int64, proofURL, note string) error {
	if q.Status != Claimed {
		return ErrNotClaimed
	}
	if w != q.Worker {
		return ErrNotWorker
	}
	if h > q.LeaseEnd {
		return ErrLeaseExpired
	}
	if strings.TrimSpace(proofURL) == "" {
		return ErrProofURLEmpty
	}
	if len(proofURL) > MaxURL {
		return ErrProofURLTooLong
	}
	if len(note) > MaxNote {
		return ErrNoteTooLong
	}
	q.ProofURL = proofURL
	q.Note = note
	q.SubmittedAt = h
	q.Status = Submitted
	q.appendEvent(h, w, "submitted", proofURL)
	return nil
}

// Accept pays the submission out: the poster approves inside or past the
// review window, there is no time limit on acceptance.
func (q *Quest) Accept(p address, h int64) error {
	if q.Status != Submitted {
		return ErrNotSubmitted
	}
	if p != q.Poster {
		return ErrNotPoster
	}
	q.Status = Paid
	q.appendEvent(h, p, "accepted", "")
	return nil
}

// Reject sends the quest back to Open, inside the review window, and clears
// the worker. The cleared fields are preserved in the event detail.
func (q *Quest) Reject(p address, h int64, reason string) error {
	if q.Status != Submitted {
		return ErrNotSubmitted
	}
	if p != q.Poster {
		return ErrNotPoster
	}
	if h > q.ReviewEnd() {
		return ErrReviewClosed
	}
	if len(reason) > MaxNote {
		return ErrReasonTooLong
	}
	detail := "worker=" + q.Worker.String()
	if q.ProofURL != "" {
		detail += " proof=" + q.ProofURL
	}
	if q.Note != "" {
		detail += " note=" + q.Note
	}
	if reason != "" {
		detail += " reason=" + reason
	}
	q.Status = Open
	q.Worker = ""
	q.LeaseEnd = 0
	q.ProofURL = ""
	q.Note = ""
	q.SubmittedAt = 0
	q.appendEvent(h, p, "rejected", detail)
	return nil
}

// AutoAccept pays the worker when the poster let the review window lapse:
// silence counts as acceptance.
func (q *Quest) AutoAccept(w address, h int64) error {
	if q.Status != Submitted {
		return ErrNotSubmitted
	}
	if w != q.Worker {
		return ErrNotWorker
	}
	if h <= q.ReviewEnd() {
		return ErrReviewOpen
	}
	q.Status = Paid
	q.AutoPaid = true
	q.appendEvent(h, w, "auto-accepted", "")
	return nil
}

// Refund returns the escrow to the poster once the deadline has passed, for
// an Open quest or a claim whose lease went stale. A pending submission can
// never be refunded.
func (q *Quest) Refund(p address, h int64) error {
	if q.Status == Submitted {
		return ErrSubmittedPending
	}
	if q.StatusAt(h) != Open {
		return ErrNotOpen
	}
	if p != q.Poster {
		return ErrNotPoster
	}
	if h < q.Deadline {
		return ErrBeforeDeadline
	}
	q.Status = Refunded
	q.appendEvent(h, p, "refunded", "")
	return nil
}

// Cancel withdraws an Open quest — or one whose claim went stale — and frees
// the escrow back to the poster.
func (q *Quest) Cancel(p address, h int64) error {
	if q.StatusAt(h) != Open {
		return ErrNotOpen
	}
	if p != q.Poster {
		return ErrNotPoster
	}
	q.Status = Cancelled
	q.appendEvent(h, p, "cancelled", "")
	return nil
}

func (q *Quest) appendEvent(h int64, actor address, action, detail string) {
	q.History = append(q.History, Event{
		Height: h,
		Actor:  actor,
		Action: action,
		Detail: detail,
	})
}
