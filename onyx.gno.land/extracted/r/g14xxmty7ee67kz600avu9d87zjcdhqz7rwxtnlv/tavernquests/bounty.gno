package tavernquests

import (
	"chain"
	"time"

	"gno.land/p/nt/ufmt/v0"
)

// Bounty is a single micro-bounty with its GNOT reward held in escrow
// by the realm until it is approved (paid to the worker) or refunded
// (returned to the creator).
type Bounty struct {
	creator     address
	title       string
	description string
	reward      chain.Coins
	worker      address
	proof       string
	submitted   bool
	approved    bool
	refunded    bool
	deadline    time.Time
}

func newBounty(creator address, title, description string, reward chain.Coins, deadline time.Time) *Bounty {
	require(time.Now().Before(deadline), "deadline must be in the future")
	require(title != "", "title must not be empty")
	return &Bounty{
		creator:     creator,
		title:       title,
		description: description,
		reward:      reward,
		deadline:    deadline,
	}
}

// SubmitProof records the caller's proof of completion.
// rlm is the cur of the surrounding crossing wrapper; rlm.Previous() is
// the immediate caller of that wrapper, against which we authorize.
func (b *Bounty) SubmitProof(_ int, rlm realm, proof string) {
	require(rlm.IsCurrent(), "unauthorized: rlm is not the caller's live cur")
	require(!b.submitted, "proof already submitted")
	require(!b.approved, "bounty already approved")
	require(!b.refunded, "bounty already refunded")
	worker := rlm.Previous().Address()
	require(worker != b.creator, "creator cannot work on own bounty")
	require(proof != "", "proof must not be empty")

	b.worker = worker
	b.proof = proof
	b.submitted = true
}

// Approve releases the escrowed reward to the worker.
// Only the bounty creator can approve, and only after a proof was submitted.
func (b *Bounty) Approve(_ int, rlm realm) {
	require(rlm.IsCurrent(), "unauthorized: rlm is not the caller's live cur")
	require(!b.approved, "bounty already approved")
	require(!b.refunded, "bounty already refunded")
	require(b.submitted, "no proof submitted yet")
	require(rlm.Previous().Address() == b.creator, "only the bounty creator can approve")

	b.approved = true
	pay(cross(rlm), b.worker, b.reward)
}

// Refund returns the escrowed reward to the creator. Allowed before any
// proof is submitted (cancel), or after the deadline when a submitted
// proof was never approved (expired). Never allowed after approval.
func (b *Bounty) Refund(_ int, rlm realm) {
	require(rlm.IsCurrent(), "unauthorized: rlm is not the caller's live cur")
	require(!b.approved, "bounty already approved")
	require(!b.refunded, "bounty already refunded")
	require(rlm.Previous().Address() == b.creator, "only the bounty creator can refund")
	if b.submitted {
		require(time.Now().After(b.deadline), "cannot refund submitted bounty before deadline")
	}

	b.refunded = true
	pay(cross(rlm), b.creator, b.reward)
}

// Status returns the lifecycle state of the bounty.
func (b Bounty) Status() string {
	switch {
	case b.refunded:
		return "refunded"
	case b.approved:
		return "approved"
	case b.submitted:
		if time.Now().After(b.deadline) {
			return "submitted (expired)"
		}
		return "submitted"
	case time.Now().After(b.deadline):
		return "expired"
	default:
		return "open"
	}
}

// WorkerOrNone returns the worker address, or "none" when nobody has
// submitted proof yet. Used by Render.
func (b Bounty) WorkerOrNone() string {
	if b.worker == "" {
		return "none"
	}
	return string(b.worker)
}

// TimeRemaining returns the time left until the deadline (0 if passed).
func (b Bounty) TimeRemaining() time.Duration {
	remaining := time.Until(b.deadline)
	if remaining < 0 {
		return 0
	}
	return remaining
}

// String returns the current state of the bounty.
func (b Bounty) String() string {
	return ufmt.Sprintf(
		"- status: %s\n- creator: %s\n- title: %s\n- description: %s\n- reward: %s\n- worker: %s\n- proof: %s\n- deadline: %s\n- remaining: %s",
		b.Status(), b.creator, b.title, b.description, b.reward.String(),
		b.WorkerOrNone(), b.proof, b.deadline.Format(time.RFC3339), b.TimeRemaining().String(),
	)
}
