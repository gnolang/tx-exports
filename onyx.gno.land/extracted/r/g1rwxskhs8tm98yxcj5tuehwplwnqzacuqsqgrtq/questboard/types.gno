package questboard

import (
	"time"
)

// Status is the lifecycle state of a quest.
type Status int

const (
	StatusOpen      Status = iota // accepting submissions / funds
	StatusAwarded                 // escrow paid to a hunter
	StatusCancelled               // escrow refunded by poster or arbiter
	StatusExpired                 // nobody decided in time; escrow refunded
)

func (s Status) String() string {
	switch s {
	case StatusOpen:
		return "open"
	case StatusAwarded:
		return "awarded"
	case StatusCancelled:
		return "cancelled"
	case StatusExpired:
		return "expired"
	}
	return "unknown"
}

// Submission is a hunter's claim that the quest is done.
type Submission struct {
	Hunter   address
	Link     string
	Note     string
	At       time.Time
	Rejected bool
	Reason   string
}

// Contribution is the total ugnot one address locked in a quest.
type Contribution struct {
	From   address
	Amount int64
}

// Quest is one escrowed bounty.
type Quest struct {
	ID        int
	Poster    address
	Arbiter   address // optional third party allowed to award, reject or cancel
	Title     string
	Body      string
	CreatedAt time.Time
	Deadline  time.Time
	Reward    int64 // ugnot currently held in escrow (or paid out once closed)
	Contribs  []Contribution
	Subs      []*Submission
	Status    Status
	Winner    address
	ClosedAt  time.Time
}

// Profile is the public, on-chain track record of an address.
type Profile struct {
	Posted    int   // quests posted
	Completed int   // quests this address posted and paid out
	Paid      int64 // ugnot paid to hunters from quests this address posted
	Cancelled int   // quests cancelled after someone had submitted work
	Ghosted   int   // quests that expired with pending submissions (poster never decided)
	Submitted int   // submissions made as a hunter
	Won       int   // quests won as a hunter
	Earned    int64 // ugnot earned as a hunter
	Funded    int64 // ugnot contributed to other people's quests
	Recent    []int // latest quest ids this address posted (bounded)
}

func (q *Quest) isManager(addr address) bool {
	return addr == q.Poster || (q.Arbiter != "" && addr == q.Arbiter)
}

func (q *Quest) findSub(hunter address) *Submission {
	for _, s := range q.Subs {
		if s.Hunter == hunter {
			return s
		}
	}
	return nil
}

func (q *Quest) activeSubs() int {
	n := 0
	for _, s := range q.Subs {
		if !s.Rejected {
			n++
		}
	}
	return n
}

func (q *Quest) pastDeadline(now time.Time) bool {
	return now.After(q.Deadline)
}

func (q *Quest) expirable(now time.Time) bool {
	return now.After(q.Deadline.Add(GracePeriod))
}
