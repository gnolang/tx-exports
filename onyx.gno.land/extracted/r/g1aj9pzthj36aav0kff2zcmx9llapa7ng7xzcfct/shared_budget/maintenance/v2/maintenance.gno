// Package maintenance requires two independent reviewers to settle a milestone.
package maintenance

import (
	"chain"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"

	"gno.land/p/g1aj9pzthj36aav0kff2zcmx9llapa7ng7xzcfct/shared_budget/budget/v1"
	"gno.land/r/g1aj9pzthj36aav0kff2zcmx9llapa7ng7xzcfct/shared_budget/treasury/v2"
)

const packagePath = "gno.land/r/g1aj9pzthj36aav0kff2zcmx9llapa7ng7xzcfct/shared_budget/maintenance/v2"

type Roles struct {
	Coordinator address
	Reviewers   [3]address
}

type milestone struct {
	digest string
	votes  [3]string
}

type program struct {
	roles      Roles
	milestones map[int64]*milestone
}

type MilestoneView struct {
	Evidence    string
	Votes       [3]string
	Reservation treasury.ReservationView
}

var programs = make(map[int64]*program)

func Configure(cur realm, programID int64, coordinator, reviewer1, reviewer2, reviewer3 address) {
	runtime.AssertOriginCall()
	caller := userCaller(cur)
	config := treasury.GetProgram(programID)
	if config.Sponsor != caller {
		panic("only the program sponsor can configure maintenance")
	}
	if config.Status != treasury.Draft || config.Maintenance.Path != packagePath || programs[programID] != nil {
		panic("maintenance configuration requires an unconfigured draft with this policy pinned")
	}
	budget.RequireAddress(coordinator)
	reviewers := [3]address{reviewer1, reviewer2, reviewer3}
	for _, reviewer := range reviewers {
		budget.RequireAddress(reviewer)
		if reviewer == coordinator {
			panic("coordinator cannot be a reviewer")
		}
	}
	if reviewer1 == reviewer2 || reviewer1 == reviewer3 || reviewer2 == reviewer3 {
		panic("reviewers must be distinct")
	}

	programs[programID] = &program{
		roles:      Roles{Coordinator: coordinator, Reviewers: reviewers},
		milestones: make(map[int64]*milestone),
	}
	treasury.RegisterPolicy(cross(cur), programID)
	chain.Emit("MaintenanceConfigured", "program", number(programID), "coordinator", string(coordinator))
}

// SubmitMilestone fixes the evidence and opens a reservation for holdBlocks.
func SubmitMilestone(cur realm, programID, itemID int64, recipient address, amount, holdBlocks int64, proofDigest string) int64 {
	runtime.AssertOriginCall()
	caller := userCaller(cur)
	p := mustProgram(programID)
	if caller != p.roles.Coordinator {
		panic("only the maintenance coordinator can submit")
	}
	evidence := budget.EvidenceCommitment(programID, budget.Maintenance, itemID, proofDigest)
	budget.RequirePositive(holdBlocks)
	deadline := budget.Add(runtime.ChainHeight(), holdBlocks)
	available := treasury.Reserve(cross(cur), programID, itemID, recipient, amount, deadline)
	p.milestones[itemID] = &milestone{digest: evidence}
	chain.Emit("MilestoneSubmitted", "program", number(programID), "item", number(itemID), "actor", string(caller), "evidence", evidence)
	return available
}

func Vote(cur realm, programID, itemID int64, evidence string, approve bool) string {
	runtime.AssertOriginCall()
	caller := userCaller(cur)
	p := mustProgram(programID)
	index := p.reviewerIndex(caller)
	item := p.mustMilestone(itemID)
	reservation := treasury.GetReservation(programID, budget.Maintenance, itemID)
	if caller == reservation.Recipient {
		panic("recipient cannot review their own milestone")
	}
	if reservation.Status != treasury.Reserved || reservation.ExpiredAtHeight {
		panic("milestone is no longer open for review")
	}
	if item.digest != evidence {
		panic("milestone evidence does not match")
	}
	if item.votes[index] != "" {
		panic("reviewer already voted")
	}

	vote := treasury.Rejected
	if approve {
		vote = treasury.Approved
	}
	item.votes[index] = vote
	chain.Emit("MilestoneVote", "program", number(programID), "item", number(itemID), "reviewer", string(caller), "decision", vote, "evidence", evidence)
	matching := 0
	for _, recorded := range item.votes {
		if recorded == vote {
			matching++
		}
	}
	if matching < 2 {
		return treasury.Reserved
	}
	if approve {
		treasury.Approve(cross(cur), programID, itemID)
	} else {
		treasury.Reject(cross(cur), programID, itemID)
	}
	return vote
}

func GetRoles(programID int64) Roles {
	return mustProgram(programID).roles
}

func GetMilestone(programID, itemID int64) MilestoneView {
	item := mustProgram(programID).mustMilestone(itemID)
	return MilestoneView{
		Evidence:    item.digest,
		Votes:       item.votes,
		Reservation: treasury.GetReservation(programID, budget.Maintenance, itemID),
	}
}

func Render(path string) string {
	id, itemID := budget.ParsePolicyViewPath(path)
	p := programs[id]
	if p == nil {
		return "# Shared Budget · Maintenance\n\nOpen a program with `:programID` or a milestone with `:programID/itemID`."
	}
	if itemID == 0 {
		r := p.roles
		return "# Maintenance · Program " + number(id) + "\n\n" +
			"- Coordinator: " + string(r.Coordinator) + "\n" +
			"- Quorum: two of three eligible reviewers\n" +
			"- Reviewers: " + string(r.Reviewers[0]) + ", " + string(r.Reviewers[1]) + ", " + string(r.Reviewers[2]) + "\n"
	}
	if p.milestones[itemID] == nil {
		return "# Maintenance\n\nMilestone not found."
	}
	m := GetMilestone(id, itemID)
	return "# Maintenance · Milestone " + number(itemID) + "\n\n" +
		"- Status: " + m.Reservation.Status + "\n" +
		"- Evidence: `" + m.Evidence + "`\n" +
		"- Votes in reviewer order: [" + m.Votes[0] + ", " + m.Votes[1] + ", " + m.Votes[2] + "]\n"
}

func mustProgram(id int64) *program {
	p := programs[id]
	if p == nil {
		panic("maintenance is not configured for this program")
	}
	return p
}

func (p *program) mustMilestone(itemID int64) *milestone {
	item := p.milestones[itemID]
	if item == nil {
		panic("milestone not found")
	}
	return item
}

func (p *program) reviewerIndex(caller address) int {
	for i, reviewer := range p.roles.Reviewers {
		if reviewer == caller {
			return i
		}
	}
	panic("only a registered maintenance reviewer can vote")
}

func userCaller(cur realm) address {
	if !cur.IsCurrent() || cur.PkgPath() != packagePath || !cur.Previous().IsUserCall() {
		panic("direct maintenance call required")
	}
	if len(unsafe.OriginSend()) != 0 {
		panic("unexpected attached coins")
	}
	return cur.Previous().Address()
}

func number(n int64) string {
	return strconv.FormatInt(n, 10)
}
