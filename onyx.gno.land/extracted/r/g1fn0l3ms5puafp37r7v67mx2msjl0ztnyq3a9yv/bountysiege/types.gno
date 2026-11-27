package bountysiege

import "gno.land/p/g1fn0l3ms5puafp37r7v67mx2msjl0ztnyq3a9yv/bs_core"

type TimelineEvent struct {
	Timestamp int64
	Actor     address
	Action    string
	Detail    string
}

type Comment struct {
	ID        uint64
	Author    address
	RoleTag   string // "SPONSOR", "BUILDER", "SUBMITTER", or "COMMUNITY"
	Body      string
	CreatedAt int64
}

type ProofEntry struct {
	URL         string
	Note        string
	SubmittedAt int64
	RevisionIdx int
}

// QuestAttempt is stored in an append-only slice so ExpireClaim never deletes
// or shrinks stored strings/structs (guaranteeing bytes_delta >= 0).
type QuestAttempt struct {
	Builder         address
	ClaimedAt       int64
	WorkDeadline    int64
	SubmittedAt     int64
	ReviewDeadline  int64
	RejectDeadline  int64
	RevisionCount   int
	Outcome         bs_core.AttemptOutcome
	Proofs          []ProofEntry
	RevisionNotes   []string
	RejectionReason string
	DisputeFee      int64
	DisputeReason   string
	LockedArbiter   address
	DisputedAt      int64
	DisputeDeadline int64
	ResolutionNote  string
}

// Quest models a Single-Claim Quest (and is reused verbatim as each independent
// slot inside a Co-op Raid).
type Quest struct {
	ID             uint64
	ParentRaidID   uint64 // 0 for standalone Single-Claim Quest
	SlotIndex      int    // 0 for standalone
	Sponsor        address
	Title          string
	Description    string
	Criteria       string
	Category       bs_core.Category
	Reward         int64
	Stake          int64
	OpenDuration   int64
	WorkDuration   int64
	ReviewDuration int64
	CreatedAt      int64
	OpenDeadline   int64
	Status         bs_core.QuestStatus

	// Explicit per-quest escrow tracking (Reward + active Stake + active DisputeFee).
	EscrowHeld int64

	// Append-only attempts; ActiveAttemptIdx == -1 when Quest is Open with no claimer.
	Attempts         []QuestAttempt
	ActiveAttemptIdx int
	Timeline         []TimelineEvent
}

func (q *Quest) activeAttempt() *QuestAttempt {
	if q.ActiveAttemptIdx < 0 || q.ActiveAttemptIdx >= len(q.Attempts) {
		return nil
	}
	return &q.Attempts[q.ActiveAttemptIdx]
}

func (q *Quest) addEvent(ts int64, actor address, action, detail string) {
	q.Timeline = append(q.Timeline, TimelineEvent{
		Timestamp: ts,
		Actor:     actor,
		Action:    action,
		Detail:    detail,
	})
}
