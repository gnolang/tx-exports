package dao

import (
	"std"
	"time"
)

type (
	// VoteChoiceRecord contains the number of counted votes for a single voting choice.
	VoteChoiceRecord struct {
		Choice VoteChoice
		Count  uint
	}

	// ProposalStrategy defines the interface for the different proposal types.
	ProposalStrategy interface {
		// Name returns the name of the strategy.
		Name() string

		// Quorum returns the minimum required percentage of DAO member votes
		// required for a proposal to pass.
		Quorum() float64

		// VotingPeriod returns the period that a proposal should allow voting.
		VotingPeriod() time.Duration

		// VoteChoices returns the valid voting choices for the strategy.
		VoteChoices() []VoteChoice

		// Tally counts the votes and returns the winner voting choice.
		// The DAO argument is the DAO that the proposal is currently assigned to,
		// by default the one where the proposal was created.
		// Proposals can be promoted to parent DAOs in which case the DAO argument
		// is the DAO where the proposal was promoted the last time.
		Tally(*DAO, VotingRecord) VoteChoice
	}
)

// VoteChecker defines an interface for proposal vote validation.
// Proposal strategies that require checking votes when they are submitted should implement it.
type VoteChecker interface {
	// CheckVote checks that a vote is valid for the strategy.
	CheckVote(member std.Address, choice VoteChoice, reason string) error
}

// Executer defines an interface for executable proposals.
// Proposals strategies that implement the interface can modify the DAO state when proposal passes.
type Executer interface {
	// Execute executes the proposal.
	// The DAO argument is the DAO where the proposal was created, even if the proposal has been promoted
	// to a parent DAO.
	// TODO: Execute should return some feedback on success
	Execute(*DAO) error
}

// Validator defines an interface for proposal validation.
// Proposal strategies that implement the interface can validate that a proposal is valid for the current state.
type Validator interface {
	// Validate validates if a proposal is valid for the current state.
	Validate(*Proposal) error
}

// ParamsRenderer defines an interface to allow strategies to render its input parameters.
type ParamsRenderer interface {
	// RenderParams returns a markdown with the rendered strategy parameters.
	RenderParams() string
}
