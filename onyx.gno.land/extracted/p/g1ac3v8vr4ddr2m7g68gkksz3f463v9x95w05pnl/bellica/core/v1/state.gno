// Package core holds Bellica's data model, the State the realm owns, and the
// shared reputation, lookup and page helpers. It keeps no state of its own:
// every stateful function takes the realm's *State as db.
package core

import "gno.land/p/nt/avl/v0"

// State is everything the Bellica realm stores. The realm creates one at
// deploy time and passes it to the functions of the Bellica packages.
type State struct {
	Agents    *avl.Tree // address -> *Agent
	Bounties  *avl.Tree // padded id -> *Bounty
	NextID    int
	TotalPaid int64 // ugnot paid to competitors, all time
	Escrowed  int64 // ugnot currently held for unclosed bounties / jobs
	Refunded  int64 // ugnot returned to creators

	// read indexes, so no Render path walks an attacker-growable set (AUDIT F5)
	OpenBounties *avl.Tree // padded id -> *Bounty, status open (incl. judging)
	Board        *avl.Tree // boardKey(agent) -> *Agent, agents with >= 1 entry
	Competing    int       // agents with >= 1 entry
	Entered      *avl.Tree // agent address -> []int bounty ids entered
	Roles        *avl.Tree // address -> []int bounty ids posted or judged

	Jobs     *avl.Tree // key(id) -> *Job
	OpenJobs *avl.Tree // key(id) -> *Job, not closed
	NextJob  int
	JobRoles *avl.Tree // address -> []int job ids (creator / agent / arbiter), newest 200
	ByCat    *avl.Tree // "b:"|"j:" + category + ":" + key(id) -> id

	Reps         *avl.Tree // address -> *Rep
	GiverBoard   *avl.Tree // score key -> *Rep (givers who paid out)
	AgentBoard2  *avl.Tree // score key -> *Rep (agents who earned)
	Ratings      *avl.Tree // "kind:id:rater:target" -> *Rating
	RatingsOf    *avl.Tree // target -> []*Rating, newest 50
	Reports      *avl.Tree // key(id) -> *ReportRec
	NextReport   int
	ReportPair   *avl.Tree // "kind:id:reporter:target" -> report id
	ReportsOn    *avl.Tree // "kind:id" -> []int, newest 100
	ReportsAbout *avl.Tree // target -> []int, newest 50

	SelfPath string  // the realm's package path (captured at deploy)
	SelfAddr address // the realm's address (escrow holder)

	// Emit records a chain event. The realm sets it to its own emitter so
	// events carry the realm's pkg_path, not this package's.
	Emit func(typ string, attrs ...string)
}

// NewState returns an empty State for the realm at selfPath / selfAddr.
func NewState(selfPath string, selfAddr address) *State {
	return &State{
		Agents: avl.NewTree(), Bounties: avl.NewTree(), NextID: 1,
		OpenBounties: avl.NewTree(), Board: avl.NewTree(), Entered: avl.NewTree(), Roles: avl.NewTree(),
		Jobs: avl.NewTree(), OpenJobs: avl.NewTree(), NextJob: 1, JobRoles: avl.NewTree(), ByCat: avl.NewTree(),
		Reps: avl.NewTree(), GiverBoard: avl.NewTree(), AgentBoard2: avl.NewTree(), Ratings: avl.NewTree(),
		RatingsOf: avl.NewTree(), Reports: avl.NewTree(), NextReport: 1, ReportPair: avl.NewTree(),
		ReportsOn: avl.NewTree(), ReportsAbout: avl.NewTree(),
		SelfPath: selfPath, SelfAddr: selfAddr,
	}
}
