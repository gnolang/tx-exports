package tavernescrow

import "strconv"

const (
	DenomUgnot        = "ugnot"
	MaxMilestones     = 16
	MaxTitleLen       = 96
	MaxSummaryLen     = 512
	MaxNoteLen        = 280
	MaxInt64    int64 = 1<<63 - 1
)

type BountyStatus string

const (
	StatusOpen      BountyStatus = "OPEN"
	StatusActive    BountyStatus = "ACTIVE"
	StatusDisputed  BountyStatus = "DISPUTED"
	StatusCompleted BountyStatus = "COMPLETED"
	StatusCancelled BountyStatus = "CANCELLED"
)

type MilestoneStatus string

const (
	MilestonePending   MilestoneStatus = "PENDING"
	MilestoneSubmitted MilestoneStatus = "SUBMITTED"
	MilestoneRejected  MilestoneStatus = "REJECTED"
	MilestoneReleased  MilestoneStatus = "RELEASED"
	MilestoneRefunded  MilestoneStatus = "REFUNDED"
)

type Milestone struct {
	Index        int
	Title        string
	AmountUgnot  int64
	Status       MilestoneStatus
	ProofURI     string
	CommitDigest string
	FeedbackNote string
	UpdatedAtBlk int64
}

type Bounty struct {
	ID             uint64
	Title          string
	Summary        string
	Sponsor        address
	Worker         address
	Arbiter        address
	Status         BountyStatus
	TotalFunded    int64
	ReleasedAmount int64
	RefundedAmount int64
	CreatedAtBlk   int64
	ExpiryHeight   int64
	DisputedIdx    int
	Milestones     []Milestone
}

type AuditEntry struct {
	Seq          uint64
	Height       int64
	Action       string
	BountyID     uint64
	MilestoneIdx int
	Actor        address
	AmountUgnot  int64
	Note         string
	PrevDigest   string
	Digest       string
}

// BountyView is an immutable value-type snapshot returned to callers
// so internal mutable realm pointers are never exposed across boundaries.
type BountyView struct {
	ID             uint64
	Title          string
	Summary        string
	Sponsor        address
	Worker         address
	Arbiter        address
	Status         BountyStatus
	TotalFunded    int64
	ReleasedAmount int64
	RefundedAmount int64
	LockedUgnot    int64
	CreatedAtBlk   int64
	ExpiryHeight   int64
	DisputedIdx    int
	MilestoneCount int
}

// RealmStats is an immutable aggregate snapshot of realm accounting.
type RealmStats struct {
	ChainID            string
	BlockHeight        int64
	BountyCount        int
	AuditCount         int
	TotalFundedUgnot   int64
	TotalLockedUgnot   int64
	TotalReleasedUgnot int64
	TotalRefundedUgnot int64
	LatestAuditDigest  string
}

func (b *Bounty) lockedRemaining() int64 {
	return b.TotalFunded - b.ReleasedAmount - b.RefundedAmount
}

func (b *Bounty) allMilestonesTerminal() bool {
	for _, m := range b.Milestones {
		if m.Status != MilestoneReleased && m.Status != MilestoneRefunded {
			return false
		}
	}
	return true
}

func (b *Bounty) toView() BountyView {
	return BountyView{
		ID:             b.ID,
		Title:          b.Title,
		Summary:        b.Summary,
		Sponsor:        b.Sponsor,
		Worker:         b.Worker,
		Arbiter:        b.Arbiter,
		Status:         b.Status,
		TotalFunded:    b.TotalFunded,
		ReleasedAmount: b.ReleasedAmount,
		RefundedAmount: b.RefundedAmount,
		LockedUgnot:    b.lockedRemaining(),
		CreatedAtBlk:   b.CreatedAtBlk,
		ExpiryHeight:   b.ExpiryHeight,
		DisputedIdx:    b.DisputedIdx,
		MilestoneCount: len(b.Milestones),
	}
}

func padUint64Key(id uint64) string {
	raw := strconv.FormatUint(id, 10)
	if len(raw) >= 20 {
		return raw
	}
	zeros := "00000000000000000000"
	return zeros[:20-len(raw)] + raw
}

func safeAddInt64(a, b int64) int64 {
	if a < 0 || b < 0 {
		panic("negative ugnot amount not permitted")
	}
	if a > MaxInt64-b {
		panic("int64 overflow in ugnot accounting")
	}
	return a + b
}

func safeSubInt64(a, b int64) int64 {
	if b < 0 || a < b {
		panic("int64 underflow in ugnot accounting")
	}
	return a - b
}

func require(cond bool, msg string) {
	if !cond {
		panic(msg)
	}
}
