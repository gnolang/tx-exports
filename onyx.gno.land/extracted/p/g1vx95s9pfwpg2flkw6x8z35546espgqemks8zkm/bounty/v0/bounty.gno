// Package bounty is a reusable, escrow-agnostic bounty board for Gno realms.
//
// A Board keeps bounties and per-address reputation. It never touches coins:
// the realm that owns the Board holds the escrow and pays out whatever the
// Board tells it to (see Approve, Collect and Cancel return values). This keeps
// the package pure and lets any realm (a DAO, a project treasury, a game)
// embed its own bounty board with a few lines of code.
//
// Lifecycle:
//
//	Open ──Claim──▶ Claimed ──Submit──▶ Submitted ──Approve/Collect──▶ Paid
//	 ▲  │             │                     │
//	 │  └─Cancel─▶ Cancelled                │
//	 └──────Release (claim expired)─────────┘◀──Reject
//
// All methods take the acting address and the current time explicitly, so the
// owning realm decides who is acting (usually cur.Previous().Address()) and
// tests can control the clock.
package bounty

import (
	"time"
)

// Status is the lifecycle state of a bounty.
type Status int

const (
	StatusOpen Status = iota
	StatusClaimed
	StatusSubmitted
	StatusPaid
	StatusCancelled
)

// String returns a human-readable status name.
func (s Status) String() string {
	switch s {
	case StatusOpen:
		return "open"
	case StatusClaimed:
		return "claimed"
	case StatusSubmitted:
		return "submitted"
	case StatusPaid:
		return "paid"
	case StatusCancelled:
		return "cancelled"
	}
	return "unknown"
}

// ParseStatus is the inverse of Status.String. ok is false for unknown names.
func ParseStatus(s string) (st Status, ok bool) {
	switch s {
	case "open":
		return StatusOpen, true
	case "claimed":
		return StatusClaimed, true
	case "submitted":
		return StatusSubmitted, true
	case "paid":
		return StatusPaid, true
	case "cancelled":
		return StatusCancelled, true
	}
	return StatusOpen, false
}

// Event is one entry in a bounty's history.
type Event struct {
	At     time.Time
	Actor  address
	Action string // posted, claimed, submitted, rejected, released, paid, auto-paid, cancelled
	Note   string
}

// Bounty is a single task with a reward held in escrow by the owning realm.
type Bounty struct {
	ID          uint64
	Title       string
	Description string
	Poster      address
	Reward      int64 // in the smallest unit of the realm's denom (e.g. ugnot)

	Status      Status
	Hunter      address // zero when open
	Proof       string  // latest submission (link, PR, tx hash …)
	ClaimWindow time.Duration

	CreatedAt   time.Time
	ClaimedAt   time.Time
	SubmittedAt time.Time
	ClosedAt    time.Time

	History []Event
}

// ClaimDeadline is the time by which the current hunter must submit.
func (b *Bounty) ClaimDeadline() time.Time {
	return b.ClaimedAt.Add(b.ClaimWindow)
}

// ClaimExpired reports whether a claimed bounty can be released again.
func (b *Bounty) ClaimExpired(now time.Time) bool {
	return b.Status == StatusClaimed && now.After(b.ClaimDeadline())
}

func (b *Bounty) log(at time.Time, actor address, action, note string) {
	b.History = append(b.History, Event{At: at, Actor: actor, Action: action, Note: note})
}

// Stats is the public reputation of an address on one board.
type Stats struct {
	Address address

	// As hunter
	Completed int   // submissions approved (or auto-approved)
	Earned    int64 // total rewards received
	Rejected  int   // submissions rejected by posters
	Abandoned int   // claims that expired without a submission

	// As poster
	Posted         int   // bounties posted
	PaidOut        int64 // total rewards paid out
	RejectionsMade int   // submissions this poster rejected
	Cancelled      int   // bounties this poster cancelled
}

// Score is a simple reputation score used for the leaderboard:
// completed work counts, abandoned claims and rejected work cost a bit.
func (s *Stats) Score() int {
	score := s.Completed*10 - s.Abandoned*3 - s.Rejected*2
	if score < 0 {
		return 0
	}
	return score
}
