package daokit

// Handles DAO governance through proposal voting and execution.
// They contain actions that run when voting requirements are satisfied.
//
// Common use cases: member management, treasury operations, rule updates.

import (
	"chain/runtime"
	"errors"
	"time"

	"gno.land/p/nt/seqid/v0"
	"gno.land/p/onbloc/json"
	"gno.land/p/samcrew/avl"
	"gno.land/p/samcrew/daocond"
)

type ProposalStatus int

const (
	ProposalStatusOpen     ProposalStatus = iota // Currently accepting votes
	ProposalStatusPassed                         // Met conditions, ready for execution
	ProposalStatusExecuted                       // Successfully executed
)

func (s ProposalStatus) String() string {
	switch s {
	case ProposalStatusOpen:
		return "Open"
	case ProposalStatusPassed:
		return "Passed"
	case ProposalStatusExecuted:
		return "Executed"
	default:
		return "Unknown"
	}
}

type Proposal struct {
	ID            seqid.ID
	Title         string
	Description   string
	CreatedAt     time.Time
	CreatedHeight int64
	ProposerID    string

	Action     Action            // What to execute if passed
	Condition  daocond.Condition // Voting conditions for this proposal
	Status     ProposalStatus
	ExecutedAt time.Time

	Ballot daocond.Ballot // All votes cast on this proposal
}

type ProposalsStore struct {
	Tree  *avl.Tree // int -> Proposal
	genID seqid.ID
}

// Data needed to create a new proposal.
type ProposalRequest struct {
	Title       string
	Description string
	Action      Action
}

func NewProposalsStore() *ProposalsStore {
	return &ProposalsStore{
		Tree: avl.NewTree(),
	}
}

func (p *ProposalsStore) GetProposal(id uint64) *Proposal {
	value, ok := p.Tree.Get(seqid.ID(id).String())
	if !ok {
		return nil
	}
	proposal := value.(*Proposal)
	return proposal
}

// Returns all proposals that match the given filter function.
func (p *ProposalsStore) GetProposals(filter func(Proposal) bool) *ProposalsStore {
	proposals := NewProposalsStore()
	p.Tree.Iterate("", "", func(key string, value interface{}) bool {
		prop, ok := value.(*Proposal)
		if !ok {
			panic(errors.New("unexpected invalid proposal type"))
		}
		if filter(*prop) {
			proposals.Tree.Set(key, prop)
		}
		return false
	})
	return proposals
}

// Reports the status a proposal should be displayed as, without writing it.
//
// Reading must never move a proposal. Render is on the cross-realm DAO
// interface, so anything it touches is reachable by any realm holding the
// handle: every read path used to call UpdateStatus on each proposal it walked,
// and a single Render flipped every condition-met proposal from Open to Passed —
// which, back when Execute demanded Open, bricked it permanently.
func (p *Proposal) DisplayStatus() ProposalStatus {
	if p.Status == ProposalStatusOpen && p.Condition.Eval(p.Ballot) {
		return ProposalStatusPassed
	}
	return p.Status
}

// Persists the status implied by the current votes: Open becomes Passed once the
// condition is met.
//
// Nothing in this package calls it. Execute evaluates the condition itself and
// the read paths use DisplayStatus, so a proposal that is never passed through
// here stays Open until it is Executed. It exists for a realm that wants the
// passed state on-chain rather than computed.
//
// SAFE ONLY BECAUSE Vote and Execute both key on Executed alone. When they
// demanded Open, calling this was destructive twice over: it froze the ballot,
// so support could not be withdrawn, and it made the proposal permanently
// unexecutable. Do not narrow either of those checks without removing this.
//
// It is also a READ path hazard — do not call it while rendering. And once
// persisted the status no longer tracks the votes: withdraw support afterwards
// and this still reads Passed, though Execute re-evaluates the condition and
// will refuse.
func (p *Proposal) UpdateStatus() {
	p.Status = p.DisplayStatus()
}

// Returns all proposals as a JSON string.
func (p *ProposalsStore) GetProposalsJSON() string {
	props := make([]*json.Node, 0, p.Tree.Size())
	// XXX: pagination
	p.Tree.Iterate("", "", func(key string, value interface{}) bool {
		prop, ok := value.(*Proposal)
		if !ok {
			panic(errors.New("unexpected invalid proposal type"))
		}
		props = append(props, json.ObjectNode("", map[string]*json.Node{
			"id":          json.NumberNode("", float64(prop.ID)),
			"title":       json.StringNode("", prop.Title),
			"description": json.StringNode("", prop.Description),
			"proposer":    json.StringNode("", prop.ProposerID),
			"status":      json.StringNode("", prop.DisplayStatus().String()),
			"startHeight": json.NumberNode("", float64(prop.CreatedHeight)),
			"signal":      json.NumberNode("", prop.Condition.Signal(prop.Ballot)),
		}))
		return false
	})
	bz, err := json.Marshal(json.ArrayNode("", props))
	if err != nil {
		panic(err)
	}
	return string(bz)
}

func (p *ProposalsStore) newProposal(proposer string, req ProposalRequest, condition daocond.Condition) *Proposal {
	id := p.genID.Next()
	proposal := &Proposal{
		ID:            id,
		Title:         req.Title,
		Description:   req.Description,
		ProposerID:    proposer,
		Status:        ProposalStatusOpen,
		Action:        req.Action,
		Condition:     condition,
		Ballot:        daocond.NewBallot(),
		CreatedAt:     time.Now(),
		CreatedHeight: runtime.ChainHeight(),
	}
	p.Tree.Set(id.String(), proposal)
	return proposal
}
