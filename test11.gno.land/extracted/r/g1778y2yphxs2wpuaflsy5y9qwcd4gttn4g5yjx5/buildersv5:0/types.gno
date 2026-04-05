package builders

import "time"

type Status int

const (
	StatusPending Status = iota
	StatusApproved
	StatusRejected
	StatusPaid
)

func (s Status) String() string {
	switch s {
	case StatusPending:
		return "pending"
	case StatusApproved:
		return "approved"
	case StatusRejected:
		return "rejected"
	case StatusPaid:
		return "paid"
	default:
		return "unknown"
	}
}

type Submission struct {
	Applicant   address
	Twitter     string
	Discord     string
	GitHub      string
	RequestType string
	Details     string

	Status      Status
	ReviewNote  string
	SubmittedAt time.Time
	ReviewedAt  time.Time
	PaidAt      time.Time
}
