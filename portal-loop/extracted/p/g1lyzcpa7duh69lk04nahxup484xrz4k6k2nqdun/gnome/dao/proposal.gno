package dao

import (
	"errors"
	"std"
	"strings"
	"time"
)

const (
	StatusReview ProposalStatus = iota
	StatusActive
	StatusPassed
	StatusRejected
	StatusWithdrawed
	StatusDismissed
	StatusFailed
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
	ErrProposalPromote           = errors.New("proposals can only be promoted to a parent DAO")
	ErrProposalVotingDeadlineMet = errors.New("proposal voting deadline already met")
	ErrProposalNotActive         = errors.New("proposal is not active")
	ErrProposalNotPassed         = errors.New(`proposal status must be "passed"`)
	ErrReasonRequired            = errors.New("reason is required")
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
	case StatusWithdrawed:
		return "withdrawed"
	case StatusDismissed:
		return "dismissed"
	case StatusFailed:
		return "failed"
	default:
		return "unknown"
	}
}

// IsFinal checks if the status is a final status.
// When a status is final it can't be changed to a different status.
// Being final means that status signals the final outcome of a proposal.
func (s ProposalStatus) IsFinal() bool {
	switch s {
	case StatusReview, StatusActive:
		return false
	default:
		return true
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

// WithDescription assigns a description to the proposal.
func WithDescription(s string) ProposalOption {
	return func(p *Proposal) {
		p.description = s
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
	title string,
	options ...ProposalOption,
) (*Proposal, error) {
	if dao == nil {
		return nil, errors.New("proposal DAO is required")
	}

	if strings.TrimSpace(title) == "" {
		return nil, errors.New("proposal title is required")
	}

	now := time.Now()
	p := &Proposal{
		id:                 id,
		proposer:           proposer,
		title:              title,
		votingDeadline:     now.Add(strategy.VotingPeriod()),
		voteChangeDuration: defaultVoteChangeDuration,
		strategy:           strategy,
		daos:               []*DAO{dao},
		votingRecords:      []*VotingRecord{NewVotingRecord()},
		createdAt:          now,
	}

	for _, apply := range options {
		apply(p)
	}

	// Create the proposal as active when a review deadline is not assigned
	if p.reviewDeadline.IsZero() {
		p.status = StatusActive
	}

	return p, nil
}

// Proposal defines a DAO proposal.
type Proposal struct {
	id                 ID
	title              string
	description        string
	proposer           std.Address
	createdAt          time.Time
	votingDeadline     time.Time
	reviewDeadline     time.Time
	voteChangeDuration time.Duration
	status             ProposalStatus
	strategy           ProposalStrategy
	daos               []*DAO
	votingRecords      []*VotingRecord
	choice             VoteChoice
	statusReason       string
}

// ID returns the proposal ID.
func (p Proposal) ID() ID {
	return p.id
}

// DAO returns the DAO that the proposal is assigned to.
// If proposal has been promoted the returned DAO is the one where proposal has been promoted to.
func (p Proposal) DAO() *DAO {
	count := len(p.daos)
	if count == 0 {
		panic("proposal is not assigned to a DAO")
	}
	return p.daos[count-1]
}

// InitialDAO returns the the DAO that was assigned during proposal creation.
func (p Proposal) InitialDAO() *DAO {
	if len(p.daos) > 0 {
		return p.daos[0]
	}
	return nil
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

// StatusReason returns the reason that triggered the current proposal status.
// Reason is relevant for some statuses like dismissed or failed.
func (p Proposal) StatusReason() string {
	return p.statusReason
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

// Promotions returns the list of DAOs where the proposal has been promoted.
// The result is nil when the proposal has never been promoted to another DAO.
func (p Proposal) Promotions() []*DAO {
	if p.HasBeenPromoted() {
		return p.daos
	}
	return nil
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
	return p.VotingRecord().Votes()
}

// VotingRecord returns the voting record of the proposal for the current DAO.
// The record contains the number of votes for each voting choice.
func (p Proposal) VotingRecord() *VotingRecord {
	count := len(p.votingRecords)
	if count == 0 {
		panic("proposal is not voting records")
	}
	return p.votingRecords[count-1]
}

// VotingRecords returns all voting records of the proposal.
// Each record contains the number of votes for each DAO that the proposal was promoted to.
func (p Proposal) VotingRecords() []*VotingRecord {
	return p.votingRecords
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

// HasBeenPromoted checks if the proposal has been promoted to another DAO.
func (p Proposal) HasBeenPromoted() bool {
	return len(p.daos) > 1
}

// HasPromotion checks if proposal has been promoted to a DAO.
func (p Proposal) HasPromotion(daoPath string) bool {
	for _, dao := range p.Promotions() {
		if dao.Path() == daoPath {
			return true
		}
	}
	return false
}

// GetVotingRecordByName returns the voting record for a DAO.
func (p Proposal) GetVotingRecordByName(daoPath string) *VotingRecord {
	for i, dao := range p.daos {
		if dao.Path() == daoPath {
			// Voting record index must match the DAO promotions index
			return p.votingRecords[i]
		}
	}
	return nil
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

// Dismiss dismisses a proposal.
func (p *Proposal) Dismiss(reason string) error {
	reason = strings.TrimSpace(reason)
	if reason == "" {
		return ErrReasonRequired
	}

	p.statusReason = reason
	p.status = StatusDismissed
	return nil
}

// Fail changes the proposal status to failed.
func (p *Proposal) Fail(reason string) error {
	reason = strings.TrimSpace(reason)
	if reason == "" {
		return ErrReasonRequired
	}

	p.statusReason = reason
	p.status = StatusFailed
	return nil
}

// Activate changes the status of the proposal to active.
// Proposal must have status "review" to be activated.
func (p *Proposal) Activate() error {
	if p.status != StatusReview {
		return ErrReviewStatusRequired
	}

	p.status = StatusActive
	return nil
}

// Promote promotes the proposal to a parent DAO.
// Promoting extends the voting deadline by the voting period defined for the proposal
// strategy and also creates a new voting record for the parent DAO members.
func (p *Proposal) Promote(dao *DAO) error {
	if !p.DAO().HasParent(dao) {
		return ErrProposalPromote
	}

	p.daos = append(p.daos, dao)
	p.votingRecords = append(p.votingRecords, NewVotingRecord())
	p.votingDeadline = time.Now().Add(p.strategy.VotingPeriod())
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

	if reason != "" {
		reason = strings.TrimSpace(reason)
		if len(reason) < 5 {
			return ErrInvalidReason
		}
	}

	// When there is a vote for the account check if it's voting within the
	// grace period that allows changing the voted choice. This allows to
	// correct mistakes made when seding the vote TX within a small time frame.
	// TODO: Add a unit test case to check vote change
	record := p.VotingRecord()
	for _, v := range record.Votes() {
		if v.Address == addr {
			if v.CreatedAt.Add(p.voteChangeDuration).Before(now) {
				return ErrAlreadyVoted
			}

			record.Remove(addr)
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
	if p.DAO().HasMember(addr) {
		// When the account is member of the proposal's DAO its vote is accounted
		// as a vote from this DAO even if its also member of a parent DAO.
		dao = p.DAO()
	} else {
		// Try to find the higher order DAO that the account is member of
		dao = findBelongingDAO(addr, p.DAO().Parent())
	}

	if dao == nil {
		return ErrMemberVoteNotAllowed
	}

	record.Add(Vote{
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

	// Check if the required quorum is met
	record := p.VotingRecord()
	percentage := float64(record.VoteCount()) / float64(len(p.DAO().Members()))
	if percentage < p.strategy.Quorum() {
		p.status = StatusRejected
		p.statusReason = "low participation"
		return nil
	}

	// Tally votes and update proposal with the outcome
	choice := p.strategy.Tally(p.DAO(), *record)

	switch choice {
	case ChoiceYes:
		p.choice = ChoiceYes
		p.status = StatusPassed
	case ChoiceNo:
		p.choice = ChoiceNo
		p.status = StatusRejected
	default:
		p.status = StatusRejected
	}
	return nil
}

func (p *Proposal) Validate() error {
	if v, ok := p.strategy.(Validator); ok {
		if err := v.Validate(p); err != nil {
			return err
		}
	}
	return nil
}

// Execute executes the proposal.
func (p *Proposal) Execute() error { // TODO: Write test for proposal execute
	if p.status != StatusPassed {
		return ErrProposalNotPassed
	}

	if e, ok := p.strategy.(Executer); ok {
		if err := p.Validate(); err != nil {
			return ExecutionError{err}
		}

		if err := e.Execute(p.InitialDAO()); err != nil {
			return ExecutionError{err}
		}
	}
	return nil
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
