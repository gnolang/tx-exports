package tavernkit

// BasisPointsTotal represents 100.00% in integer basis points.
const BasisPointsTotal int64 = 10000

// UgnotPerGnot is the number of micro-GNOT (ugnot) per 1 GNOT.
const UgnotPerGnot int64 = 1000000

// MaxMilestones bounds milestone count per bounty to keep storage & gas predictable.
const MaxMilestones = 8

// Status represents the lifecycle phase of a TavernBoard bounty.
type Status uint8

const (
	StatusOpen Status = iota
	StatusClaimed
	StatusInReview
	StatusDisputed
	StatusCompleted
	StatusCancelled
	StatusArchived
)

// String returns a human-readable label for a bounty Status.
func (s Status) String() string {
	switch s {
	case StatusOpen:
		return "OPEN"
	case StatusClaimed:
		return "CLAIMED"
	case StatusInReview:
		return "IN REVIEW"
	case StatusDisputed:
		return "DISPUTED"
	case StatusCompleted:
		return "COMPLETED"
	case StatusCancelled:
		return "CANCELLED"
	case StatusArchived:
		return "ARCHIVED"
	default:
		return "UNKNOWN"
	}
}

// ColorHex returns a hex color for SVG rendering of the status badge.
func (s Status) ColorHex() string {
	switch s {
	case StatusOpen:
		return "#22c55e"
	case StatusClaimed:
		return "#38bdf8"
	case StatusInReview:
		return "#f59e0b"
	case StatusDisputed:
		return "#ef4444"
	case StatusCompleted:
		return "#a855f7"
	case StatusCancelled:
		return "#64748b"
	case StatusArchived:
		return "#475569"
	default:
		return "#94a3b8"
	}
}

// MilestoneStatus represents the state of an individual bounty milestone.
type MilestoneStatus uint8

const (
	MilestonePending MilestoneStatus = iota
	MilestoneSubmitted
	MilestoneRevisionRequested
	MilestoneApproved
	MilestoneDisputed
	MilestoneResolvedBuilder
	MilestoneResolvedSponsor
)

// String returns a human-readable label for MilestoneStatus.
func (ms MilestoneStatus) String() string {
	switch ms {
	case MilestonePending:
		return "PENDING"
	case MilestoneSubmitted:
		return "SUBMITTED"
	case MilestoneRevisionRequested:
		return "REVISION"
	case MilestoneApproved:
		return "APPROVED"
	case MilestoneDisputed:
		return "DISPUTED"
	case MilestoneResolvedBuilder:
		return "PAID (QUORUM)"
	case MilestoneResolvedSponsor:
		return "REFUNDED (QUORUM)"
	default:
		return "UNKNOWN"
	}
}

// IsTerminal reports whether the milestone has already been settled.
func (ms MilestoneStatus) IsTerminal() bool {
	return ms == MilestoneApproved ||
		ms == MilestoneResolvedBuilder ||
		ms == MilestoneResolvedSponsor
}

// CraftTier represents a builder's on-chain reputation rank.
type CraftTier uint8

const (
	TierApprentice CraftTier = iota
	TierJourneyman
	TierArtisan
	TierMaster
	TierArchmage
)

// String returns the display title of a CraftTier.
func (t CraftTier) String() string {
	switch t {
	case TierApprentice:
		return "Apprentice"
	case TierJourneyman:
		return "Journeyman"
	case TierArtisan:
		return "Artisan"
	case TierMaster:
		return "Master"
	case TierArchmage:
		return "Archmage"
	default:
		return "Apprentice"
	}
}

// MinXP returns the minimum XP threshold required for this tier.
func (t CraftTier) MinXP() int64 {
	switch t {
	case TierApprentice:
		return 0
	case TierJourneyman:
		return 250
	case TierArtisan:
		return 750
	case TierMaster:
		return 2000
	case TierArchmage:
		return 5000
	default:
		return 0
	}
}

// AccentHex returns the primary crest accent color for this CraftTier.
func (t CraftTier) AccentHex() string {
	switch t {
	case TierApprentice:
		return "#94a3b8"
	case TierJourneyman:
		return "#38bdf8"
	case TierArtisan:
		return "#f59e0b"
	case TierMaster:
		return "#c084fc"
	case TierArchmage:
		return "#fbbf24"
	default:
		return "#94a3b8"
	}
}

// MilestoneSpec defines a single milestone's title and basis-point payout share.
type MilestoneSpec struct {
	Title     string
	WeightBps int64
}

// ReputationInput aggregates verifiable on-chain activity for a builder or reviewer.
type ReputationInput struct {
	CompletedBounties  int64
	ApprovedMilestones int64
	TotalEarnedUgnot   int64
	ReviewsAligned     int64
	ReviewsSlashed     int64
	DisputesWon        int64
	DisputesLost       int64
}

// ReputationScore is the deterministic reputation output computed from ReputationInput.
type ReputationScore struct {
	XP             int64
	Tier           CraftTier
	ReliabilityBps int64 // 0..10000 (10000 = 100.00%)
	NextTierXP     int64 // 0 if already at TierArchmage
	ProgressBps    int64 // progress toward next tier in basis points (0..10000)
}

// QuorumTally summarizes reviewer quorum voting state for a disputed milestone.
type QuorumTally struct {
	ApproveVotes int
	RejectVotes  int
	TotalVotes   int
	MinQuorum    int
	Decided      bool
	BuilderWins  bool
}
