package magnacoda

import "time"

// Rate kinds for an agent's listed price.
const (
	RateHourly = "hourly"
	RateFlat   = "flat"
)

// Task statuses. The escrowed ugnot is held while the task is open or
// in-progress, then released exactly once on complete or cancel.
const (
	StatusOpen       = "open"
	StatusInProgress = "in-progress"
	StatusCompleted  = "completed"
	StatusCancelled  = "cancelled"
)

// Agent is a registered worker. The caller's address is the agent id
// and owner; one address can register at most one agent.
type Agent struct {
	Owner        address
	Name         string
	Tags         string // canonical, comma-space separated specialties
	RateKind     string
	RateUgnot    int64
	RegisteredAt time.Time
	Completed    int
	EarnedUgnot  int64
}

// Task is a job posted with an ugnot budget held in escrow by the realm.
type Task struct {
	ID          int
	Poster      address
	Title       string
	Description string
	Specialty   string // required specialty tag
	BudgetUgnot int64
	Status      string
	PostedAt    time.Time

	WinningBidID int
	Winner       address
	AcceptedAt   time.Time
	CompletedAt  time.Time
	Settled      bool // true after payout or refund; prevents double settlement

	// Optional hash-commit settlement. Empty CommitHash means the winning
	// agent may call CompleteTask as usual. When set, they must reveal a
	// preimage of this SHA-256 (lowercase hex) before RevealBy.
	CommitHash string
	RevealBy   time.Time
}

// Bid is one agent's offer on an open task.
type Bid struct {
	ID       int
	TaskID   int
	Agent    address
	Amount   int64 // ugnot, must be > 0 and <= the task budget
	Note     string
	PlacedAt time.Time
}

// Rating is one poster's 1-5 review of a settled job.
type Rating struct {
	ID          int
	TaskID      int
	Agent       address
	Poster      address
	Score       int // 1-5
	Comment     string
	BudgetUgnot int64 // snapshot of the task budget, used as weight
	ReviewerWt  int64 // snapshot of reviewer weight (1000 = 1.0)
	RatedAt     time.Time
}

// AgentScore is a cached view of an agent's reputation, rebuilt on Rate
// and RefreshScore. Queries and Render recompute decay live from ratings.
type AgentScore struct {
	Agent       address
	RatedCount  int
	TrustMilli  int64 // 1000-5000, 0 if unrated
	RawMilli    int64
	Provisional bool
	LastRatedAt time.Time
}

// PosterStats tracks a poster's history, used to grow reviewer weight.
type PosterStats struct {
	Owner          address
	SettledJobs    int
	SettledUgnot   int64
	DistinctAgents int
}
