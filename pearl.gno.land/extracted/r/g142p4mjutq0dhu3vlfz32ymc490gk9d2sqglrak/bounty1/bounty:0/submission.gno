package bounty

import (
	"time"

	"gno.land/p/nt/ufmt/v0"
)

// Bounty holds the immutable terms and mutable release state of a single
// bounty escrow: the per-item type CreateBounty creates, analogous to how
// crowdfunding's Campaign (see gno/r/crowdfunding/campaign.gno) is the
// per-item type CreateCampaign creates. Structurally the same escrow shape
// as Campaign -- an id, an owner, a fixed monetary term, a deadline and a
// settlement flag -- except settlement here is a discretionary Approve
// rather than a threshold comparison against accumulated contributions.
//
// poster, rewardUgnot and deadlineUnix are this bounty's rules.immutable_fields:
// no exported function ever assigns to them after this struct is
// constructed in CreateBounty [IMMUTABLE_TERMS, NO_MUTABLE_AUTHORITY_ESCAPE].
type Bounty struct {
	id           int64
	poster       address
	title        string
	rewardUgnot  int64
	deadlineUnix int64

	// released, releasedTo and refunded are the only fields Approve/Refund
	// (bounty.gno) ever mutate, and released/refunded are mutually
	// exclusive terminal states: both Approve and Refund refuse once
	// either is true [SINGLE_RELEASE_EVER].
	released   bool
	releasedTo address
	refunded   bool

	// submissionCount is an O(1) display counter kept in step with the
	// package-level `submissions` avl.Tree (see bounty.gno); it never
	// itself gates approval eligibility -- Approve always re-checks
	// `submissions` directly [APPROVAL_ONLY_TO_SUBMITTER].
	submissionCount int64
}

func (b *Bounty) status() string {
	switch {
	case b.released:
		return "released"
	case b.refunded:
		return "refunded"
	case time.Now().Unix() < b.deadlineUnix:
		return "open"
	default:
		return "expired"
	}
}

func (b *Bounty) String() string {
	releasedTo := ""
	if b.released {
		releasedTo = ufmt.Sprintf("\n- released to: %s", b.releasedTo)
	}
	return ufmt.Sprintf(
		"- id: %d\n- title: %s\n- poster: %s\n- reward: %dugnot\n- deadline: %s\n- status: %s\n- submissions: %d%s",
		b.id, b.title, b.poster, b.rewardUgnot,
		time.Unix(b.deadlineUnix, 0).UTC().Format(time.RFC3339), b.status(), b.submissionCount, releasedTo,
	)
}

// Submission holds one worker's registered response to a bounty, the second
// per-item type this family introduces (no crowdfunding analogue: a
// contribution there is a plain int64 ledger entry, not a struct). Keyed in
// the package-level `submissions` avl.Tree by submissionKey(bountyID,
// worker) (see bounty.gno), never nested inside Bounty itself, matching the
// spec's state shape (bounty_and_worker_to_submission is its own top-level
// entry, not a field of bounty_id_to_bounty).
type Submission struct {
	bountyID int64
	worker   address
	note     string
}

func (s *Submission) String() string {
	return ufmt.Sprintf("- worker: %s\n- note: %s", s.worker, s.note)
}
