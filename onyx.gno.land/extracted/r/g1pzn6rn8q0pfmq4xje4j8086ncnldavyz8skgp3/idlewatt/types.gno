package idlewatt

import "time"

// Node kinds.
const (
	KindHomeGPU = "home-gpu"
	KindVehicle = "vehicle"
	KindCPU     = "cpu"
)

// Power sources.
const (
	PowerGrid       = "grid"
	PowerSolar      = "solar"
	PowerPowershare = "powershare-backup"
)

// Availability modes.
const (
	ModeAvailable = "available" // parked & plugged in, ready for work
	ModeDriving   = "driving"   // vehicle in use, not renting compute
	ModePaused    = "paused"    // operator paused the node
)

// Node is one idle-compute node registered by an operator.
// All figures are self-reported by the operator; nothing here is verified
// by Akash, Tesla or any hardware attestation (yet).
type Node struct {
	ID        int
	Operator  address
	Name      string
	Kind      string
	Hardware  string
	Region    string
	Power     string
	RateCents int64 // asking price, USD cents per hour
	Mode      string

	RegisteredAt   time.Time
	LastHeartbeat  time.Time // zero if never
	SessionStart   time.Time // start of the current unbroken heartbeat run
	HeartbeatCount int
	LastNote       string

	JobCount    int
	JobMinutes  int64
	EarnedCents int64 // operator share of simulated job earnings
	BonusCents  int64 // share of the small-node fairness pool
}

// TotalCents is what the leaderboard ranks on.
func (n *Node) TotalCents() int64 {
	return n.EarnedCents + n.BonusCents
}

// Job is one simulated (self-reported) lease / job completion.
type Job struct {
	ID            int
	NodeID        int
	NodeName      string // snapshot, survives node removal
	Workload      string
	Minutes       int
	RateCents     int64
	GrossCents    int64 // rate x duration
	PoolCents     int64 // part sent to the fairness pool
	OperatorCents int64
	CompletedAt   time.Time
}
