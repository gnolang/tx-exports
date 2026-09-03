// dao — Decentralized Autonomous Organization governance system
// Features: Proposal creation, voting with quorum, timelock execution
package dao

import (
	"strconv"
	"strings"

	"chain/runtime"
)

// Proposal states
const (
	StatusActive   = "active"
	StatusPassed   = "passed"
	StatusExecuted = "executed"
	StatusRejected = "rejected"
)

type Proposal struct {
	ID                int
	Title             string
	Description       string
	Proposer          string
	ForVotes          int
	AgainstVotes      int
	Voters            map[string]bool
	Status            string
	CreatedBlock      int64
	VotingEndBlock    int64
	ExecuteAfterBlock int64
}

var (
	proposals       map[int]*Proposal
	nextID           int
	votingPeriod     int64
	timelockPeriod   int64
	quorum           int
	totalMembers     int
	members          map[string]bool
)

func init() {
	proposals = make(map[int]*Proposal)
	nextID = 1
	votingPeriod = 100
	timelockPeriod = 50
	quorum = 5
	totalMembers = 0
	members = make(map[string]bool)
}

// === Membership ===

func AddMember(cur realm, member string) {
	caller := cur.Previous().Address().String()
	if totalMembers > 0 && !members[caller] {
		panic("only DAO members can add new members")
	}
	if members[member] {
		panic("already a member")
	}
	members[member] = true
	totalMembers++
}

func IsMember(addr string) bool {
	return members[addr]
}

func MemberCount() int {
	return totalMembers
}

// === Proposal Lifecycle ===

func CreateProposal(cur realm, title, description string) int {
	caller := cur.Previous().Address().String()
	if !members[caller] {
		panic("only DAO members can create proposals")
	}

	id := nextID
	nextID++
	currentBlock := runtime.ChainHeight()

	proposals[id] = &Proposal{
		ID:                id,
		Title:             title,
		Description:       description,
		Proposer:          caller,
		Voters:            make(map[string]bool),
		Status:            StatusActive,
		CreatedBlock:      currentBlock,
		VotingEndBlock:    currentBlock + votingPeriod,
		ExecuteAfterBlock: currentBlock + votingPeriod + timelockPeriod,
	}
	return id
}

func Vote(cur realm, proposalID int, support bool) {
	caller := cur.Previous().Address().String()
	if !members[caller] {
		panic("only DAO members can vote")
	}

	p, ok := proposals[proposalID]
	if !ok {
		panic("proposal not found")
	}
	if p.Status != StatusActive {
		panic("voting not active")
	}
	if runtime.ChainHeight() > p.VotingEndBlock {
		panic("voting period ended")
	}
	if p.Voters[caller] {
		panic("already voted")
	}

	p.Voters[caller] = true
	if support {
		p.ForVotes++
	} else {
		p.AgainstVotes++
	}
}

func FinalizeProposal(cur realm, proposalID int) string {
	p, ok := proposals[proposalID]
	if !ok {
		panic("proposal not found")
	}
	if p.Status != StatusActive {
		return p.Status
	}
	if runtime.ChainHeight() <= p.VotingEndBlock {
		panic("voting period not ended")
	}

	totalVotes := p.ForVotes + p.AgainstVotes
	if totalVotes < quorum {
		p.Status = StatusRejected
		return StatusRejected
	}
	if p.ForVotes > p.AgainstVotes {
		p.Status = StatusPassed
		return StatusPassed
	}
	p.Status = StatusRejected
	return StatusRejected
}

func ExecuteProposal(cur realm, proposalID int) string {
	p, ok := proposals[proposalID]
	if !ok {
		panic("proposal not found")
	}
	if p.Status != StatusPassed {
		panic("proposal not passed")
	}
	if runtime.ChainHeight() < p.ExecuteAfterBlock {
		remaining := p.ExecuteAfterBlock - runtime.ChainHeight()
		panic("timelock not expired - wait " + strconv.FormatInt(remaining, 10) + " blocks")
	}
	p.Status = StatusExecuted
	return StatusExecuted
}

// === Query Functions ===

func GetProposal(id int) (string, string, string, string, int, int, int, int64) {
	p := proposals[id]
	return p.Title, p.Description, p.Proposer, p.Status,
		p.ForVotes, p.AgainstVotes, len(p.Voters), p.ExecuteAfterBlock
}

func ProposalCount() int {
	return len(proposals)
}

func GetConfig() (int64, int64, int, int) {
	return votingPeriod, timelockPeriod, quorum, totalMembers
}

func SetConfig(cur realm, voting, timelock, quorumNeeded int64) {
	caller := cur.Previous().Address().String()
	if !members[caller] {
		panic("only members can update config")
	}
	votingPeriod = voting
	timelockPeriod = timelock
	quorum = int(quorumNeeded)
}

// === Render ===

func Render(_ string) string {
	b := strings.Builder{}
	b.WriteString("# DAO Governance\n\n")
	b.WriteString("## Config\n")
	b.WriteString("- Voting Period: " + strconv.FormatInt(votingPeriod, 10) + " blocks\n")
	b.WriteString("- Timelock: " + strconv.FormatInt(timelockPeriod, 10) + " blocks\n")
	b.WriteString("- Quorum: " + strconv.Itoa(quorum) + " votes\n")
	b.WriteString("- Members: " + strconv.Itoa(totalMembers) + "\n\n")
	b.WriteString("## Proposals (" + strconv.Itoa(len(proposals)) + ")\n")
	for id, p := range proposals {
		b.WriteString("### #" + strconv.Itoa(id) + " " + p.Title + "\n")
		b.WriteString("- Status: " + p.Status + "\n")
		b.WriteString("- For: " + strconv.Itoa(p.ForVotes) + " | Against: " + strconv.Itoa(p.AgainstVotes) + "\n")
		b.WriteString("- Voters: " + strconv.Itoa(len(p.Voters)) + "\n")
		b.WriteString("- Execute after block: " + strconv.FormatInt(p.ExecuteAfterBlock, 10) + "\n\n")
	}
	return b.String()
}
