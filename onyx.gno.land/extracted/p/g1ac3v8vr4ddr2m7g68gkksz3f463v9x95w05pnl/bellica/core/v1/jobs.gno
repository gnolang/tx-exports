package core

import (
	"time"

	"gno.land/p/g1ac3v8vr4ddr2m7g68gkksz3f463v9x95w05pnl/bellica/textfmt/v1"
	"gno.land/p/nt/avl/v0"
)

const JobOpen = "open" // taking applications (selection: also shortlist + trials)

const JobOffered = "offered" // a named agent may Accept

const JobActive = "active" // agent working

const JobDelivered = "delivered" // creator reviewing

const JobDisputed = "disputed" // arbiter deciding

const JobPaid = "paid" // agent(s) paid in full

const JobSplit = "split" // pay split (arbiter, trial fees, or silence)

const JobRefunded = "refunded" // all back to the creator (minus trial fees)

const JobCancelled = "cancelled" // withdrawn before work started

const ModeDirect = "direct"

const ModeSelection = "selection"

const maxJobRoleIDs = 200

// Application is an agent's pitch to be hired.
type Application struct {
	Agent  address
	Pitch  string
	Sample string // portfolio / sample link (https or ipfs), optional
	At     time.Time
}

// Trial is one shortlisted agent's delivery in a selection job.
type Trial struct {
	Agent  address
	Kind   string
	URL    string
	Hash   string
	Text   string
	Note   string
	At     time.Time // zero = not delivered
	Place  int       // 1-based if picked
	Payout int64
}

// Job is a hire with escrowed pay.
type Job struct {
	ID           int
	Title        string
	SpecURL      string
	Category     string
	Mode         string
	MinTier      int
	Pay          int64
	Splits       []int // selection: percent per winner
	TrialFee     int64 // selection: ugnot per on-time non-winner trial
	Creator      address
	Agent        address // direct: "" until hired / named
	Arbiter      address // direct: "" = no arbiter
	CreatedAt    time.Time
	Deadline     time.Time // delivery due
	WorkMin      int
	ReviewMin    int
	ReviewBy     time.Time // creator must decide before this
	ResolveBy    time.Time // arbiter must resolve before this
	Status       string
	Kind         string // direct: last deliverable
	URL          string
	Hash         string
	Text         string
	Note         string
	DeliveredAt  time.Time
	Deliveries   int
	Rejects      int
	RejectReason string
	AgentPct     int   // direct: share the agent received at close
	PaidAgents   int64 // ugnot to agents
	Returned     int64 // ugnot back to the creator
	ClosedAt     time.Time
	Resolved     bool      // closed by the arbiter
	AutoReleased bool      // closed by Release (silence)
	NoDelivery   bool      // closed by Refund, nothing delivered
	RejectedAll  bool      // selection: creator rejected every trial
	Apps         *avl.Tree // agent -> *Application
	AppOrder     []address
	Shortlist    []address
	Trials       *avl.Tree // agent -> *Trial
}

func (j *Job) Closed() bool {
	switch j.Status {
	case JobPaid, JobSplit, JobRefunded, JobCancelled:
		return true
	}
	return false
}

func MustJob(db *State, id int) *Job {
	j, ok := db.Jobs.Get(textfmt.Key(id)).(*Job)
	if !ok || j == nil {
		panic("job not found")
	}
	return j
}

// addJobRole indexes a job under an address, keeping the newest maxJobRoleIDs (AUDIT F5).
func AddJobRole(db *State, a address, id int) {
	ids, _ := db.JobRoles.Get(a.String()).([]int)
	if n := len(ids); n > 0 && ids[n-1] == id {
		return
	}
	ids = append(ids, id)
	if len(ids) > maxJobRoleIDs {
		ids = ids[len(ids)-maxJobRoleIDs:]
	}
	db.JobRoles.Set(a.String(), ids)
}

func JobPhase(j *Job) string {
	now := time.Now()
	switch j.Status {
	case JobOpen:
		if j.Mode == ModeSelection && !now.Before(j.Deadline) {
			switch {
			case j.Deliveries == 0:
				return "expired" // anyone can Refund
			case now.Before(j.ReviewBy):
				return "picking" // creator compares trials
			}
			return "releasable" // anyone can Release (equal split)
		}
		if !now.Before(j.Deadline) {
			return "expired"
		}
	case JobOffered, JobActive:
		if !now.Before(j.Deadline) {
			return "expired"
		}
	case JobDelivered:
		if !now.Before(j.ReviewBy) {
			return "releasable"
		}
	case JobDisputed:
		if !now.Before(j.ResolveBy) {
			return "releasable"
		}
	}
	return j.Status
}
