// rev 2026-11-26T17:22Z — realm resubmitted after the packages were verified
package kolektif

import (
	"time"

	"gno.land/p/g1udyt8ywv489087rn5td39m8t3peve3hxjz08w2/rosca"
)

// Member is one seat in a circle.
type Member struct {
	Addr       address
	Collateral int64 // ugnot still held as collateral for this member
	PaidRound  int   // highest round this member paid; -1 before the first payment
	RoundsPaid int
	Defaulted  bool
	Received   bool
	JoinedAt   time.Time
}

// Payout records one distribution out of the circle.
type Payout struct {
	Round  int
	To     address
	Amount int64
	At     time.Time
	Kind   string // "pot", "collateral", "penalty", "refund"
}

// Circle is one rotating savings circle.
type Circle struct {
	ID              uint64
	Name            string
	Creator         address
	Params          rosca.Params
	Members         []*Member
	Order           []int // payout order, indexes into Members
	Round           int
	Status          rosca.Status
	OpenedAt        time.Time
	ActivatedAt     time.Time
	Deadline        time.Time
	Pool            int64 // ugnot held by the realm on behalf of this circle
	Penalty         int64 // slashed collateral waiting to be shared out
	Payouts         []Payout
	ClosedAt        time.Time
	Cancelled       bool
	Seed            string
	ActivateHeight  int64
	PaidInTotal     int64 // lifetime contributions received
	PaidOutTotal    int64
}

// Member returns the seat of addr, or nil.
func (c *Circle) Member(addr address) *Member {
	for _, m := range c.Members {
		if m.Addr == addr {
			return m
		}
	}
	return nil
}

// Seats returns the number of joined members.
func (c *Circle) Seats() int {
	return len(c.Members)
}

// Active returns the number of members that are not defaulted.
func (c *Circle) Active() int {
	n := 0
	for _, m := range c.Members {
		if !m.Defaulted {
			n++
		}
	}
	return n
}

// RoundsPlanned is how many payouts the circle still owes.
func (c *Circle) RoundsPlanned() int {
	n := 0
	for _, m := range c.Members {
		if !m.Defaulted {
			n++
		}
	}
	return n
}

// RoundsSettled counts completed payouts.
func (c *Circle) RoundsSettled() int {
	n := 0
	for _, m := range c.Members {
		if m.Received {
			n++
		}
	}
	return n
}

// NextBeneficiary returns the member index that receives the current round's
// pot, or -1 when nobody is left to pay.
func (c *Circle) NextBeneficiary() int {
	for _, idx := range c.Order {
		if idx < 0 || idx >= len(c.Members) {
			continue
		}
		m := c.Members[idx]
		if !m.Received && !m.Defaulted {
			return idx
		}
	}
	return -1
}

// RoundPaid reports whether every active member has paid the current round.
func (c *Circle) RoundPaid() bool {
	for _, m := range c.Members {
		if m.Defaulted {
			continue
		}
		if m.PaidRound < c.Round {
			return false
		}
	}
	return true
}

// Remaining is the time left in the current round, in seconds.
func (c *Circle) Remaining(now time.Time) int64 {
	if c.Status != rosca.StatusActive {
		return 0
	}
	return c.Deadline.Unix() - now.Unix()
}

// Progress is the share of scheduled payouts already delivered.
func (c *Circle) Progress() (int, int) {
	return c.RoundsSettled(), c.RoundsPlanned()
}
