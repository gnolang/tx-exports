// Package escrow is the pure escrow state machine behind Tavern Quests.
//
// It is a stateless library: it owns the quest record type and every rule
// for how a quest may move through its lifecycle, but it holds no chain
// state and moves no coins. The Tavern Quests realm (gno.land/r/nym-tavern777/quests)
// stores the records, verifies payments, and performs the actual coin
// transfers; every authorization and transition decision is delegated here
// so the rules can be unit-tested in isolation and reused by other realms.
//
// Lifecycle:
//
//	Open --Claim(claimer != poster)--> Claimed
//	Open --Cancel(poster)--> Cancelled            (escrow refunded by realm)
//	Claimed --Submit(claimant)--> Submitted
//	Submitted --Approve(poster)--> Completed      (escrow released by realm)
//	Submitted --Reject(poster)--> Claimed         (submission cleared, retry)
//
// Every transition validates first and mutates only on success, so a
// rejected transition never leaves partial state behind.
package escrow

import (
	"errors"
	"strings"
)

// Status is the lifecycle state of a quest.
type Status int

const (
	Open Status = iota
	Claimed
	Submitted
	Completed
	Cancelled
)

// String returns the lowercase board label for the status.
func (s Status) String() string {
	switch s {
	case Open:
		return "open"
	case Claimed:
		return "claimed"
	case Submitted:
		return "submitted"
	case Completed:
		return "completed"
	case Cancelled:
		return "cancelled"
	}
	return "unknown"
}

// Quest is a single escrowed task on the board. Reward is denominated in
// ugnot and is held by the hosting realm between posting and payout/refund.
type Quest struct {
	ID          int64
	Poster      address
	Claimant    address
	Title       string
	Description string
	Reward      int64 // ugnot
	Status      Status
	Submission  string // claimant's delivery note / proof reference
}

// ValidateNew checks the fields of a quest that is about to be posted.
// reward is the ugnot amount the poster actually sent, verified by the
// realm against the transaction before calling this.
func ValidateNew(title, description string, reward int64) error {
	if strings.TrimSpace(title) == "" {
		return errors.New("title must not be empty")
	}
	if len(title) > 140 {
		return errors.New("title too long (max 140 chars)")
	}
	if len(description) > 2048 {
		return errors.New("description too long (max 2048 chars)")
	}
	if reward <= 0 {
		return errors.New("reward must be a positive ugnot amount")
	}
	return nil
}

// Claim moves an Open quest to Claimed for actor. The poster cannot claim
// their own quest, and a quest can have only one claimant.
func Claim(q *Quest, actor address) error {
	if q.Status != Open {
		return errors.New("quest is not open")
	}
	if actor == q.Poster {
		return errors.New("poster cannot claim their own quest")
	}
	q.Claimant = actor
	q.Status = Claimed
	return nil
}

// Submit records the claimant's delivery note and moves a Claimed quest
// to Submitted.
func Submit(q *Quest, actor address, note string) error {
	if q.Status != Claimed {
		return errors.New("quest is not in claimed state")
	}
	if actor != q.Claimant {
		return errors.New("only the claimant can submit work")
	}
	if strings.TrimSpace(note) == "" {
		return errors.New("submission note must not be empty")
	}
	if len(note) > 1024 {
		return errors.New("submission note too long (max 1024 chars)")
	}
	q.Submission = note
	q.Status = Submitted
	return nil
}

// Approve marks a Submitted quest Completed. The hosting realm releases
// the escrowed reward to the claimant when this succeeds.
func Approve(q *Quest, actor address) error {
	if q.Status != Submitted {
		return errors.New("quest is not in submitted state")
	}
	if actor != q.Poster {
		return errors.New("only the poster can approve")
	}
	q.Status = Completed
	return nil
}

// Reject sends a Submitted quest back to Claimed, clearing the delivery
// note so the claimant can fix and resubmit.
func Reject(q *Quest, actor address) error {
	if q.Status != Submitted {
		return errors.New("quest is not in submitted state")
	}
	if actor != q.Poster {
		return errors.New("only the poster can reject")
	}
	q.Submission = ""
	q.Status = Claimed
	return nil
}

// Cancel closes an Open quest. The hosting realm refunds the escrowed
// reward to the poster when this succeeds. A quest that has been claimed
// can no longer be cancelled.
func Cancel(q *Quest, actor address) error {
	if q.Status != Open {
		return errors.New("only an open quest can be cancelled")
	}
	if actor != q.Poster {
		return errors.New("only the poster can cancel")
	}
	q.Status = Cancelled
	return nil
}
