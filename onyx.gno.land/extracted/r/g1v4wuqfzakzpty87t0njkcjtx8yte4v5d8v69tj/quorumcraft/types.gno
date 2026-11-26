package quorumcraft

import "gno.land/p/nt/avl/v0"

const (
	realmPkgPath = "gno.land/r/g1v4wuqfzakzpty87t0njkcjtx8yte4v5d8v69tj/quorumcraft"
	ugnotDenom   = "ugnot"
	bpsFull      = int64(10_000)
	minMilestones = 2
	maxMilestones = 4
)

// QFMode determines which matching algorithm is used at round finalization.
type QFMode int

const (
	ModeStandardQF QFMode = 0
	ModePairwiseQF QFMode = 1
)

func (m QFMode) String() string {
	switch m {
	case ModeStandardQF:
		return "StandardQF"
	case ModePairwiseQF:
		return "PairwiseQF"
	default:
		return "Unknown"
	}
}

// RoundStatus tracks the lifecycle of a quadratic funding round.
type RoundStatus int

const (
	RoundOpen      RoundStatus = 0
	RoundFinalized RoundStatus = 1
)

func (s RoundStatus) String() string {
	switch s {
	case RoundOpen:
		return "OPEN"
	case RoundFinalized:
		return "FINALIZED"
	default:
		return "UNKNOWN"
	}
}

// MilestoneStatus tracks the escrow state of an individual grant tranche.
type MilestoneStatus int

const (
	MilestonePending   MilestoneStatus = 0
	MilestoneSubmitted MilestoneStatus = 1
	MilestoneReleased  MilestoneStatus = 2
	MilestoneDisputed  MilestoneStatus = 3
	MilestoneRefunded  MilestoneStatus = 4
)

func (s MilestoneStatus) String() string {
	switch s {
	case MilestonePending:
		return "PENDING"
	case MilestoneSubmitted:
		return "SUBMITTED"
	case MilestoneReleased:
		return "RELEASED"
	case MilestoneDisputed:
		return "DISPUTED"
	case MilestoneRefunded:
		return "REFUNDED"
	default:
		return "UNKNOWN"
	}
}

// Milestone represents a single deliverable tranche backed by escrowed ugnot.
type Milestone struct {
	Index          int
	Title          string
	Bps            int64 // share of proposal's total grant in basis points (sum == 10000)
	Status         MilestoneStatus
	ProofURI       string
	CommitHash     string
	SubmittedAt    int64
	Approvals      *avl.Tree // address string -> bool
	ApprovalCount  int
	DisputeReason  string
	DisputedBy     address
	ReleasedAmount int64
}

// Proposal represents a builder grant proposal with structured milestones.
type Proposal struct {
	ID                int
	RoundID           int
	Recipient         address
	Title             string
	RepoURL           string
	Summary           string
	DirectTotal       int64
	MatchedGrant      int64
	StandardQFMatched int64
	EscrowReleased    int64
	EscrowRefunded    int64
	DonorContribs     *avl.Tree // donor address string -> int64 ugnot
	Milestones        []*Milestone
	CreatedAt         int64
}

// TotalGrant returns the proposal's combined direct + matched ugnot grant.
func (p *Proposal) TotalGrant() int64 {
	return p.DirectTotal + p.MatchedGrant
}

// RemainingEscrow returns unreleased, unrefunded ugnot still locked for this proposal.
func (p *Proposal) RemainingEscrow() int64 {
	rem := p.TotalGrant() - p.EscrowReleased - p.EscrowRefunded
	if rem < 0 {
		return 0
	}
	return rem
}

// Round represents a Pairwise or Standard Quadratic Funding round with on-chain escrow.
type Round struct {
	ID           int
	Sponsor      address
	Name         string
	Description  string
	Mode         QFMode
	PenaltyCoeff int64 // M in ugnot for PairwiseQF anti-collusion damping
	QuorumBps    int64 // required attestation quorum in basis points (1..10000)
	EndHeight    int64 // 0 = sponsor-finalized; >0 = anyone may finalize once ChainHeight >= EndHeight
	MatchingPool int64 // escrowed ugnot in the matching pool
	DirectTotal  int64 // sum of all direct community contributions
	Status       RoundStatus
	Reviewers    *avl.Tree // reviewer address string -> bool
	Donors       *avl.Tree // donor address string -> int64 total ugnot in this round
	Proposals    []*Proposal
	CreatedAt    int64
	FinalizedAt  int64
}

// ProtocolStats summarizes live protocol-wide escrow & activity metrics.
type ProtocolStats struct {
	RoundCount    int
	OpenRounds    int
	ProposalCount int
	TotalEscrowed int64
	TotalReleased int64
	TotalRefunded int64
}
