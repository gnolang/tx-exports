// Package simpledao is a GnoForge starter kit: minimal proposal + voting DAO.
// v0 stores votes in-memory maps; production forks should migrate tallies to AVL.
package simpledao

import (
	"strconv"
	"strings"

	"gno.land/p/g16p08xxtyt320hjju7769lzguxlvzszwpg8duwl/roles/v0"
)

type ProposalStatus int

const (
	StatusActive ProposalStatus = iota
	StatusPassed
	StatusRejected
	StatusExecuted
	StatusCancelled
)

type Proposal struct {
	ID          int
	Title       string
	Description string
	Proposer    string
	Yes         int
	No          int
	Status      ProposalStatus
	// Action is a free-form string executed off-chain or by future hooks.
	Action string
}

var (
	roleSet    *roles.RoleSet
	proposals  map[int]Proposal
	votes      map[string]bool // key: proposalID:addr
	nextID     int
	name       string
	quorumYes  int // minimum yes votes to pass (simple threshold)
	inited     bool
)

func ensure() {
	if roleSet == nil {
		roleSet = roles.NewRoleSet()
	}
	if proposals == nil {
		proposals = map[int]Proposal{}
	}
	if votes == nil {
		votes = map[string]bool{}
	}
}

// InitDAO bootstraps DAO; caller is admin + voter.
func InitDAO(cur realm, daoName string, passThreshold int) string {
	ensure()
	if inited {
		panic("simpledao: already initialized")
	}
	if passThreshold < 1 {
		passThreshold = 1
	}
	caller := cur.Previous().Address().String()
	name = daoName
	quorumYes = passThreshold
	roleSet.Grant(caller, "admin")
	roleSet.Grant(caller, "voter")
	inited = true
	return "ok: dao=" + name
}

// AddVoter grants voting rights (admin).
func AddVoter(cur realm, addr string) string {
	ensure()
	caller := cur.Previous().Address().String()
	roleSet.Require(caller, "admin")
	roleSet.Grant(addr, "voter")
	return "voter added"
}

// Propose creates a new proposal (voters).
func Propose(cur realm, title, description, action string) string {
	ensure()
	if !inited {
		panic("simpledao: not initialized")
	}
	caller := cur.Previous().Address().String()
	roleSet.Require(caller, "voter")
	title = strings.TrimSpace(title)
	if title == "" {
		panic("simpledao: empty title")
	}
	nextID++
	p := Proposal{
		ID:          nextID,
		Title:       title,
		Description: description,
		Proposer:    caller,
		Status:      StatusActive,
		Action:      action,
	}
	proposals[nextID] = p
	return "proposal#" + strconv.Itoa(nextID)
}

// Vote casts yes/no (voters, once per proposal).
func Vote(cur realm, proposalID int, support bool) string {
	ensure()
	caller := cur.Previous().Address().String()
	roleSet.Require(caller, "voter")
	p, ok := proposals[proposalID]
	if !ok {
		panic("simpledao: unknown proposal")
	}
	if p.Status != StatusActive {
		panic("simpledao: proposal not active")
	}
	key := strconv.Itoa(proposalID) + ":" + caller
	if votes[key] {
		panic("simpledao: already voted")
	}
	votes[key] = true
	if support {
		p.Yes++
	} else {
		p.No++
	}
	// auto-pass if threshold met
	if p.Yes >= quorumYes {
		p.Status = StatusPassed
	}
	proposals[proposalID] = p
	if support {
		return "voted yes"
	}
	return "voted no"
}

// Finalize rejects if still active and no votes enough (admin manual close).
func Finalize(cur realm, proposalID int) string {
	ensure()
	caller := cur.Previous().Address().String()
	roleSet.Require(caller, "admin")
	p, ok := proposals[proposalID]
	if !ok {
		panic("simpledao: unknown proposal")
	}
	if p.Status != StatusActive {
		return statusString(p.Status)
	}
	if p.Yes >= quorumYes {
		p.Status = StatusPassed
	} else {
		p.Status = StatusRejected
	}
	proposals[proposalID] = p
	return statusString(p.Status)
}

// MarkExecuted marks a passed proposal as executed (admin / off-chain hook).
func MarkExecuted(cur realm, proposalID int) string {
	ensure()
	caller := cur.Previous().Address().String()
	roleSet.Require(caller, "admin")
	p, ok := proposals[proposalID]
	if !ok {
		panic("simpledao: unknown proposal")
	}
	if p.Status != StatusPassed {
		panic("simpledao: not passed")
	}
	p.Status = StatusExecuted
	proposals[proposalID] = p
	return "executed"
}

func statusString(s ProposalStatus) string {
	switch s {
	case StatusActive:
		return "active"
	case StatusPassed:
		return "passed"
	case StatusRejected:
		return "rejected"
	case StatusExecuted:
		return "executed"
	case StatusCancelled:
		return "cancelled"
	default:
		return "unknown"
	}
}

// Render DAO board.
func Render(_ string) string {
	ensure()
	if !inited {
		return "# Simple DAO Kit\n\nNot initialized. Call `InitDAO`.\n\n*GnoForge starter kit*"
	}
	var b strings.Builder
	b.WriteString("# DAO: " + name + "\n\n")
	b.WriteString("Pass threshold (yes votes): **" + strconv.Itoa(quorumYes) + "**\n\n")
	b.WriteString("## Proposals\n\n")
	if nextID == 0 {
		b.WriteString("_No proposals._\n")
	}
	for id := nextID; id >= 1; id-- {
		p, ok := proposals[id]
		if !ok {
			continue
		}
		b.WriteString("### #" + strconv.Itoa(p.ID) + " " + p.Title + "\n\n")
		b.WriteString("- Status: `" + statusString(p.Status) + "`\n")
		b.WriteString("- Proposer: `" + p.Proposer + "`\n")
		b.WriteString("- Yes/No: " + strconv.Itoa(p.Yes) + " / " + strconv.Itoa(p.No) + "\n")
		if p.Description != "" {
			b.WriteString("\n" + p.Description + "\n")
		}
		if p.Action != "" {
			b.WriteString("\nAction: `" + p.Action + "`\n")
		}
		b.WriteString("\n")
	}
	b.WriteString("---\n*Powered by GnoForge `simpledao` kit*\n")
	return b.String()
}
