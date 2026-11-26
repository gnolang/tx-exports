package oathledger

import (
	"strconv"
	"time"
)

type PactStatus string

const (
	StatusOpen      PactStatus = "OPEN"
	StatusActive    PactStatus = "ACTIVE"
	StatusCompleted PactStatus = "COMPLETED"
	StatusDisputed  PactStatus = "DISPUTED"
	StatusResolved  PactStatus = "RESOLVED"
	StatusExpired   PactStatus = "EXPIRED"
)

type MilestoneStatus string

const (
	MilestonePending   MilestoneStatus = "PENDING"
	MilestoneSubmitted MilestoneStatus = "SUBMITTED"
	MilestonePaid      MilestoneStatus = "PAID"
)

type Milestone struct {
	Index       int
	Title       string
	SplitBps    int64
	AmountUgnot int64
	Status      MilestoneStatus
	ProofURI    string
	Approvals   []address
	SubmittedAt time.Time
	PaidAt      time.Time
}

type DisputeVote struct {
	Reviewer        address
	BuilderShareBps int64
}

type Pact struct {
	ID            int64
	Title         string
	Summary       string
	Sponsor       address
	Builder       address
	Reviewers     []address
	Quorum        int
	TotalUgnot    int64
	ReleasedUgnot int64
	Status        PactStatus
	Milestones    []*Milestone
	CreatedAt     time.Time
	Deadline      time.Time
	DisputeReason string
	DisputeVotes  []DisputeVote
	HadDispute    bool
}

type BuilderProfile struct {
	Address             address
	XP                  int64
	TotalEarnedUgnot    int64
	MilestonesCompleted int
	PactsCompleted      int
	DisputesCount       int
}

func padID(id int64) string {
	s := strconv.FormatInt(id, 10)
	for len(s) < 12 {
		s = "0" + s
	}
	return s
}

func hasAddress(list []address, target address) bool {
	for _, a := range list {
		if a == target {
			return true
		}
	}
	return false
}
