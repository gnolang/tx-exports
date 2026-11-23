package hearthescrow

import "math"

const (
	DenomUGNOT       = "ugnot"
	UGNOTPerGNOT     = 1_000_000
	BasisPointsTotal = 10_000
	MaxMilestones    = 20
	MaxTitleLen      = 120
	MaxMilestoneLen  = 100
	MaxDeliverable   = 240
	MaxNoteLen       = 280
	MaxEscrowAmount  = math.MaxInt64 / BasisPointsTotal
)

// Status represents the lifecycle state of an escrow.
type Status string

const (
	StatusActive    Status = "active"
	StatusDisputed  Status = "disputed"
	StatusCompleted Status = "completed"
	StatusResolved  Status = "resolved"
	StatusRefunded  Status = "refunded"
)

// MilestoneStatus represents the state of an individual milestone.
type MilestoneStatus string

const (
	MilestonePending   MilestoneStatus = "pending"
	MilestoneSubmitted MilestoneStatus = "submitted"
	MilestoneApproved  MilestoneStatus = "approved"
)

// Milestone defines one payout tranche inside an escrow.
type Milestone struct {
	Index           int
	Title           string
	Bps             int64
	Status          MilestoneStatus
	Deliverable     string
	SubmittedHeight int64
	ApprovedHeight  int64
	PaidAmount      int64
}

// DisputeRecord captures dispute opening and arbiter resolution details.
type DisputeRecord struct {
	OpenedBy        address
	Reason          string
	OpenedHeight    int64
	ResolvedHeight  int64
	RecipientBps    int64
	RecipientPayout int64
	DepositorRefund int64
	ResolutionNote  string
}

// Escrow holds the complete onchain state for one milestone escrow.
type Escrow struct {
	ID             uint64
	Title          string
	Depositor      address
	Recipient      address
	Arbiter        address // empty if no arbiter
	TotalAmount    int64   // ugnot
	ReleasedAmount int64   // ugnot paid to recipient
	RefundedAmount int64   // ugnot refunded to depositor
	CreatedHeight  int64
	DeadlineHeight int64
	ClosedHeight   int64
	Status         Status
	Milestones     []Milestone
	Dispute        *DisputeRecord
}

// RemainingAmount returns the ugnot still locked in this escrow.
func (e *Escrow) RemainingAmount() int64 {
	rem := e.TotalAmount - e.ReleasedAmount - e.RefundedAmount
	if rem < 0 {
		return 0
	}
	return rem
}

// ApprovedCount returns how many milestones have been approved.
func (e *Escrow) ApprovedCount() int {
	n := 0
	for i := range e.Milestones {
		if e.Milestones[i].Status == MilestoneApproved {
			n++
		}
	}
	return n
}

// Stats summarizes protocol-wide escrow counts and ugnot accounting.
type Stats struct {
	TotalEscrows   int
	ActiveCount    int
	DisputedCount  int
	CompletedCount int
	ResolvedCount  int
	RefundedCount  int
	TotalLocked    int64
	TotalReleased  int64
	TotalRefunded  int64
}
