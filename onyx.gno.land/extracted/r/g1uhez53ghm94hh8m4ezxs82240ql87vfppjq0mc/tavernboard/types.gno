package tavernboard

import (
	"time"

	"gno.land/p/g1uhez53ghm94hh8m4ezxs82240ql87vfppjq0mc/tavernkit"
)

// All core stateful data types are declared inside /r/tavernboard (never /p/)
// per the Gno Security Guide so foreign /p/ packages cannot reference or
// launder write authority against realm-owned structs.

type bounty struct {
	id                    uint64
	title                 string
	summary               string
	tags                  string
	sponsor               address
	builder               address
	builderPitch          string
	status                tavernkit.Status
	totalFundedUgnot      int64
	totalReleasedUgnot    int64
	totalRefundedUgnot    int64
	vaultAccountedUgnot   int64
	createdAt             time.Time
	deadline              time.Time
	minReviewerStakeUgnot int64
	reviewerQuorum        int
	milestones            []*milestone
	archived              bool
}

type milestone struct {
	index           int
	title           string
	weightBps       int64
	payoutUgnot     int64
	status          tavernkit.MilestoneStatus
	proofURL        string
	deliveryNotes   string
	sponsorFeedback string
	revisionCount   int
	submittedAt     time.Time
	settledAt       time.Time
	dispute         *dispute
}

type dispute struct {
	openedBy       address
	reason         string
	openedAt       time.Time
	votes          []*reviewVote
	approveCount   int
	rejectCount    int
	stakePoolUgnot int64
	resolved       bool
	builderWon     bool
	resolvedAt     time.Time
}

type reviewVote struct {
	reviewer       address
	approveBuilder bool
	stakeUgnot     int64
	rationale      string
	castAt         time.Time
}

type builderProfile struct {
	addr               address
	completedBounties  int64
	approvedMilestones int64
	totalEarnedUgnot   int64
	reviewsAligned     int64
	reviewsSlashed     int64
	disputesWon        int64
	disputesLost       int64
	bountiesPosted     int64
	bountiesClaimed    int64
}

// -----------------------------------------------------------------------------
// Exported immutable value snapshots (safe to return cross-realm; zero aliases)
// -----------------------------------------------------------------------------

// MilestoneSnapshot is an immutable read-only view of a bounty milestone.
type MilestoneSnapshot struct {
	Index           int
	Title           string
	WeightBps       int64
	PayoutUgnot     int64
	Status          tavernkit.MilestoneStatus
	ProofURL        string
	DeliveryNotes   string
	SponsorFeedback string
	RevisionCount   int
	HasDispute      bool
	ApproveVotes    int
	RejectVotes     int
	DisputeResolved bool
	BuilderWon      bool
}

// BountySnapshot is an immutable read-only view of a bounty and its vaults.
type BountySnapshot struct {
	ID                    uint64
	Title                 string
	Summary               string
	Tags                  string
	Sponsor               address
	Builder               address
	Status                tavernkit.Status
	TotalFundedUgnot      int64
	TotalReleasedUgnot    int64
	TotalRefundedUgnot    int64
	EscrowVaultAddr       address
	StakeVaultAddr        address
	EscrowVaultLiveUgnot  int64
	StakeVaultLiveUgnot   int64
	CreatedAtUnix         int64
	DeadlineUnix          int64
	MinReviewerStakeUgnot int64
	ReviewerQuorum        int
	MilestoneCount        int
	SettledMilestones     int
	Archived              bool
}

// ProfileSnapshot is an immutable read-only summary of a participant's reputation.
type ProfileSnapshot struct {
	Address            address
	Score              tavernkit.ReputationScore
	CompletedBounties  int64
	ApprovedMilestones int64
	TotalEarnedUgnot   int64
	ReviewsAligned     int64
	ReviewsSlashed     int64
	DisputesWon        int64
	DisputesLost       int64
	BountiesPosted     int64
	BountiesClaimed    int64
}

// BoardStats is an immutable aggregate snapshot of realm-wide activity.
type BoardStats struct {
	TotalBounties     int64
	OpenBounties      int64
	CompletedBounties int64
	DisputesResolved  int64
	TotalFundedUgnot  int64
	TotalPaidUgnot    int64
	ActiveEscrowUgnot int64
	RankedBuilders    int
	ArchivedBounties  int64
}
