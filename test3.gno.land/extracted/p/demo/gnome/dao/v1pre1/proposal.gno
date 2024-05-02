package gnome

import (
	"errors"
	"std"
	"strings"
	"time"

	"gno.land/p/demo/avl"
)

const (
	StatusReview ProposalStatus = iota
	StatusActive
	StatusPassed
	StatusRejected
	StatusLowParticipation
	StatusWithdrawed
)

const (
	// TODO: Add more choices which also should be configurable (use a different type?)
	ChoiceNone VoteChoice = ""
	ChoiceYes  VoteChoice = "yes"
	ChoiceNo   VoteChoice = "no"
)

const (
	defaultVoteChangeDuration = time.Hour
	executionErrorMsg         = "proposal execution error"
)

var (
	ErrAlreadyVoted              = errors.New("member already voted on this proposal")
	ErrInvalidReason             = errors.New("reason must have at least 5 characters")
	ErrInvalidVoteChoice         = errors.New("invalid vote choice")
	ErrMemberVoteNotAllowed      = errors.New("you must be a DAO or parent DAO member to vote")
	ErrProposalVotingDeadlineMet = errors.New("proposal voting deadline already met")
	ErrProposalNotActive         = errors.New("proposal is not active")
	ErrProposalNotPassed         = errors.New(`proposal status must be "passed"`)
	ErrReviewStatusRequired      = errors.New(`proposal status must be "review"`)
)

type (
	// ExecutionError indicates that proposal execution failed.
	ExecutionError struct {
		// Reason contains the error or error message with the reason of the error.
		Reason interface{}
	}

	// ProposalIterFn defines the a callback to iterate proposals.
	ProposalIterFn func(*Proposal) bool

	// ProposalOption configures proposals.
	ProposalOption func(*Proposal)

	// ProposalStatus defines the type for proposal states.
	ProposalStatus uint8

	// VoteChoice defines the type for proposal vote choices.
	VoteChoice string

	// Vote contains the information for a member vote.
	Vote struct {
		// Address is the DAO member address.
		Address std.Address

		// Choice is the proposal choice being voted.
		Choice VoteChoice

		// Reason contains the reason for the vote.
		Reason string

		// DAO contains the DAO that the proposal being voted belongs to.
		DAO *DAO

		// CreatedAt contains the time when the vote was submitted.
		CreatedAt time.Time
	}
)

// Error returns the execution error message.
func (e ExecutionError) Error() string {
	switch v := e.Reason.(type) {
	case string:
		return executionErrorMsg + ": " + v
	case error:
		return executionErrorMsg + ": " + v.Error()
	default:
		return executionErrorMsg
	}
}

// String returns the proposal status name.
func (s ProposalStatus) String() string {
	switch s {
	case StatusReview:
		return "review"
	case StatusActive:
		return "active"
	case StatusPassed:
		return "passed"
	case StatusRejected:
		return "rejected"
	case StatusLowParticipation:
		return "low participation"
	case StatusWithdrawed:
		return "withdrawed"
	default:
		return "invalid"
	}
}

// IsExecutionError checks if an error is an ExecutionError.
func IsExecutionError(err error) bool {
	switch err.(type) {
	case ExecutionError:
		return true
	case *ExecutionError:
		return true
	default:
		return false
	}
}

// WithVotingDeadline assigns a voting deadline to the proposal.
func WithVotingDeadline(t time.Time) ProposalOption {
	return func(p *Proposal) {
		p.votingDeadline = t
	}
}

// WithReviewDeadline assigns a review deadline to the proposal.
// Review status allows proposal withdraw within a time frame after the proposal is created.
// Proposals must be activated when a review deadline is assigned.
func WithReviewDeadline(t time.Time) ProposalOption {
	return func(p *Proposal) {
		p.reviewDeadline = t
	}
}

// WithVoteChangeDuration change the default grace period to change a submitted vote choice.
func WithVoteChangeDuration(d time.Duration) ProposalOption {
	return func(p *Proposal) {
		p.voteChangeDuration = d
	}
}

// NewProposal creates a new proposal.
// By default proposals use the standard strategy with a deadline of seven days.
func NewProposal(
	id ID,
	strategy ProposalStrategy,
	proposer std.Address,
	dao *DAO,
	title, description string,
	options ...ProposalOption,
) (*Proposal, error) {
	if dao == nil {
		return nil, errors.New("proposal DAO is required")
	}

	if strings.TrimSpace(title) == "" {
		return nil, errors.New("proposal title is required")
	}

	if strings.TrimSpace(description) == "" {
		return nil, errors.New("proposal description is required")
	}

	now := time.Now()
	p := &Proposal{
		id:                 id,
		proposer:           proposer,
		dao:                dao,
		title:              title,
		description:        description,
		votingDeadline:     now.Add(strategy.VotingPeriod()),
		voteChangeDuration: defaultVoteChangeDuration,
		strategy:           strategy,
		votingRecord:       NewVotingRecord(),
		createdAt:          now,
	}

	for _, apply := range options {
		apply(p)
	}

	// Create the proposal as active when a review deadline is not assigned
	if p.reviewDeadline.IsZero() {
		p.status = StatusActive
	}

	if err := p.Validate(); err != nil {
		return nil, err
	}
	return p, nil
}

// Proposal defines a DAO proposal.
type Proposal struct {
	id                 ID
	dao                *DAO
	title              string
	description        string
	proposer           std.Address
	createdAt          time.Time
	votingDeadline     time.Time
	reviewDeadline     time.Time
	voteChangeDuration time.Duration
	status             ProposalStatus
	strategy           ProposalStrategy
	votingRecord       *VotingRecord
	choice             VoteChoice
}

// ID returns the proposal ID.
func (p Proposal) ID() ID {
	return p.id
}

// DAO returns the DAO that the proposal belongs to.
func (p Proposal) DAO() *DAO {
	return p.dao
}

// Strategy returns the strategy of the proposal.
func (p Proposal) Strategy() ProposalStrategy {
	return p.strategy
}

// Title returns the title of the proposal.
func (p Proposal) Title() string {
	return p.title
}

// Description returns the description of the proposal.
func (p Proposal) Description() string {
	return p.description
}

// Proposer returns the address of the member that created the proposal.
func (p Proposal) Proposer() std.Address {
	return p.proposer
}

// Choice returns the winner choice.
func (p Proposal) Choice() VoteChoice {
	return p.choice
}

// CreatedAt returns the creation time of the proposal.
func (p Proposal) CreatedAt() time.Time {
	return p.createdAt
}

// VotingDeadline returns the voting deadline for the proposal.
// No more votes are allowed after this deadline.
func (p Proposal) VotingDeadline() time.Time {
	return p.votingDeadline
}

// ReviewDeadline returns the deadline for proposal review.
func (p Proposal) ReviewDeadline() time.Time {
	return p.reviewDeadline
}

// VoteChangeDuration returns the duration after voting where users can change the voted choice.
func (p Proposal) VoteChangeDuration() time.Duration {
	return p.voteChangeDuration
}

// Status returns the status of the proposal.
func (p Proposal) Status() ProposalStatus {
	return p.status
}

// Votes returns the proposal votes.
func (p Proposal) Votes() []Vote {
	return p.votingRecord.Votes()
}

// VotingRecord returns the voting record of the proposal.
// The record contains the number of votes for each voting choice.
func (p Proposal) VotingRecord() *VotingRecord {
	return p.votingRecord
}

// IsExecutable checks if the proposal is executable.
func (p Proposal) IsExecutable() bool {
	_, ok := p.strategy.(Executer)
	return ok
}

// IsChoiceAllowed checks if a vote choice is valid for the proposal.
func (p Proposal) IsChoiceAllowed(choice VoteChoice) bool {
	for _, c := range p.strategy.VoteChoices() {
		if c == choice {
			return true
		}
	}
	return false
}

// HasVotingDeadlinePassed checks if the voting deadline for the proposal has passed.
func (p Proposal) HasVotingDeadlinePassed() bool {
	return time.Now().After(p.votingDeadline)
}

// HasReviewDeadlinePassed checks if the deadline for proposal review has passed.
func (p Proposal) HasReviewDeadlinePassed() bool {
	return time.Now().After(p.reviewDeadline)
}

// Withdraw changes the status of the proposal to withdrawed.
// Proposal must have status "review" to be withdrawed.
func (p *Proposal) Withdraw() error {
	if p.status != StatusReview {
		return ErrReviewStatusRequired
	}

	p.status = StatusWithdrawed
	return nil
}

// Activate changes the status of the proposal to active.
// Proposal must have status "review" to be activated.
func (p *Proposal) Activate() error {
	// TODO: Add test cases for proposal Activate() method
	if p.status != StatusReview {
		return ErrReviewStatusRequired
	}

	p.status = StatusActive
	return nil
}

// Vote submits a vote for the proposal.
func (p *Proposal) Vote(addr std.Address, choice VoteChoice, reason string) error {
	if p.status != StatusActive {
		return ErrProposalNotActive
	}

	now := time.Now()
	if p.votingDeadline.Before(now) {
		return ErrProposalVotingDeadlineMet
	}

	if !p.IsChoiceAllowed(choice) {
		return ErrInvalidVoteChoice
	}

	if reason != "" && len(reason) < 5 {
		return ErrInvalidReason
	}

	// When there is a vote for the account check if it's voting within the
	// grace period that allows changing the voted choice. This allows to
	// correct mistakes made when seding the vote TX within a small time frame.
	// TODO: Add a unit test case to check vote change
	for _, v := range p.votingRecord.Votes() {
		if v.Address == addr {
			if v.CreatedAt.Add(p.voteChangeDuration).Before(now) {
				return ErrAlreadyVoted
			}

			p.votingRecord.Remove(addr)
		}
	}

	// Check the vote being submitted if vote check is required
	if c, ok := p.strategy.(VoteChecker); ok {
		if err := c.CheckVote(addr, choice, reason); err != nil {
			return err
		}
	}

	// Account must be a member of the proposal's DAO or any of its parents to be allowed to vote
	var dao *DAO
	if p.dao.HasMember(addr) {
		// When the account is member of the proposal's DAO its vote is accounted
		// as a vote from this DAO even if its also member of a parent DAO.
		dao = p.dao
	} else {
		// Try to find the higher order DAO that the account is member of
		dao = findBelongingDAO(addr, p.dao.parent)
	}

	if dao == nil {
		return ErrMemberVoteNotAllowed
	}

	p.votingRecord.Add(Vote{
		Address:   addr,
		Choice:    choice,
		Reason:    reason,
		DAO:       dao,
		CreatedAt: time.Now(),
	})

	return nil
}

// Tally counts the number of votes and updates the proposal status accordingly.
// The outcome of counting the votes depends on the proposal strategy.
// This function does NOT check the voting deadline, it's responsibility of the caller to do so.
func (p *Proposal) Tally() error {
	if p.status != StatusActive {
		return ErrProposalNotActive
	}

	// Split votes from DAO members and members of parent DAOs
	var memberVotes, parentVotes []Vote
	for _, v := range p.Votes() {
		if p.dao.HasMember(v.Address) {
			memberVotes = append(memberVotes, v)
		} else {
			parentVotes = append(parentVotes, v)
		}
	}

	// Votes from parent DAOs dismisses all votes from members of the current DAO
	if len(parentVotes) > 0 {
		p.tallyParentVotes(parentVotes)
	} else {
		p.tallyMemberVotes(memberVotes)
	}
	return nil
}

func (p Proposal) Validate() error {
	if v, ok := p.strategy.(Validator); ok {
		if err := v.Validate(p.dao); err != nil {
			return err
		}
	}
	return nil
}

// Execute executes the proposal.
func (p *Proposal) Execute() error {
	if p.status != StatusPassed {
		return ErrProposalNotPassed
	}

	if e, ok := p.strategy.(Executer); ok {
		if err := p.Validate(); err != nil {
			return ExecutionError{err}
		}

		if err := e.Execute(p.dao); err != nil {
			return ExecutionError{err}
		}
	}
	return nil
}

func (p *Proposal) tallyParentVotes(votes []Vote) {
	// TODO: Implement parent votes tally
	// TODO: Save member votes tally results? Or use a proposal status to show votes were dismissed?
}

func (p *Proposal) tallyMemberVotes(votes []Vote) {
	// TODO: Deal with the case where a member that voted in active proposals is removed.
	//       Index/Keep track of the DAOs each member belongs to? For easy access to proposals.

	// Check if the required quorum is met
	percentage := float64(len(votes)) / float64(len(p.dao.Members()))
	if percentage < p.strategy.Quorum() {
		p.status = StatusLowParticipation
		return
	}

	// Tally votes and update proposal with the outcome
	choice := p.strategy.Tally(p.dao, *p.votingRecord)

	switch choice {
	case ChoiceYes:
		p.choice = ChoiceYes
		p.status = StatusPassed
	case ChoiceNo:
		p.status = StatusRejected
	default:
		p.status = StatusLowParticipation
	}
}

// Proposals helps managing multiple proposals.
// Its also a factory for proposals that assigns incremental IDs to each new proposal.
type Proposals struct {
	lastID    ID
	proposals avl.Tree // ID -> *Proposal
	groups    avl.Tree // DAO name -> []*Proposal
}

// New creates a new proposal.
func (ps *Proposals) New(
	strategy ProposalStrategy,
	proposer std.Address,
	dao *DAO,
	title, description string,
	options ...ProposalOption,
) (*Proposal, error) {
	p, err := NewProposal(ps.genID(), strategy, proposer, dao, title, description, options...)
	if err != nil {
		return nil, err
	}

	ps.indexProposal(p)

	return p, nil
}

// Exists checks if a proposal exists.
func (ps Proposals) Exists(id ID) bool {
	return ps.proposals.Has(id.Key())
}

// Get gets a proposal.
func (ps Proposals) Get(id ID) *Proposal {
	if v, exists := ps.proposals.Get(id.Key()); exists {
		return v.(*Proposal)
	}
	return nil
}

// GetByDAO gets all proposals of a DAO.
func (ps Proposals) GetByDAO(daoName string) []*Proposal {
	if v, exists := ps.groups.Get(daoName); exists {
		return v.([]*Proposal)
	}
	return nil
}

// Iterate iterates all proposals starting from the oldest one.
func (ps Proposals) Iterate(fn ProposalIterFn) bool {
	return ps.proposals.Iterate("", "", func(_ string, value interface{}) bool {
		return fn(value.(*Proposal))
	})
}

// ReverseIterate iterates all proposals starting from the latest one.
func (ps Proposals) ReverseIterate(fn ProposalIterFn) bool {
	return ps.proposals.ReverseIterate("", "", func(_ string, value interface{}) bool {
		return fn(value.(*Proposal))
	})
}

func (ps *Proposals) genID() ID {
	ps.lastID += 1
	return ps.lastID
}

func (ps *Proposals) indexProposal(p *Proposal) {
	daoName := p.DAO().Name()
	proposals := ps.GetByDAO(daoName)
	ps.groups.Set(daoName, append([]*Proposal{p}, proposals...)) // reverse append
	ps.proposals.Set(p.ID().Key(), p)
}

func findBelongingDAO(addr std.Address, node *DAO) *DAO {
	if node == nil {
		return nil
	}

	// Before checking the current DAO try to find
	// if address is a member of a higher order DAO
	dao := findBelongingDAO(addr, node.parent)
	if dao == nil && node.HasMember(addr) {
		return node
	}
	return nil
}
