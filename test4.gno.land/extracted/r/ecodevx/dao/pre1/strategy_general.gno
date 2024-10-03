package gnome

import (
	"errors"
	"std"
	"strings"
	"time"

	gnome "gno.land/p/ecodevx/dao"
)

// newGeneralStrategy creates a new general proposal strategy.
// This type of proposal is not executable so it doesn't modify the DAO state when proposal passes.
func newGeneralStrategy() generalStrategy {
	return generalStrategy{
		choices: []gnome.VoteChoice{gnome.ChoiceYes, gnome.ChoiceNo},
	}
}

type generalStrategy struct {
	choices []gnome.VoteChoice
}

// Name returns the name of the strategy.
func (generalStrategy) Name() string {
	return StrategyNameGeneral
}

// Quorum returns the minimum required percentage of DAO member votes
// required for a proposal to pass.
func (generalStrategy) Quorum() float64 {
	return 0.51
}

// VotingPeriod returns the period that a proposal should allow voting.
func (generalStrategy) VotingPeriod() time.Duration {
	period, _ := parameters.VotingPeriods.Get(StrategyNameGeneral)
	return period
}

// VoteChoices returns the valid voting choices for the strategy.
func (s generalStrategy) VoteChoices() []gnome.VoteChoice {
	return s.choices
}

// CheckVote checks that a vote is valid for the strategy.
func (s generalStrategy) CheckVote(_ std.Address, choice gnome.VoteChoice, reason string) error {
	// Reason is required when voting NO on standard proposals
	if choice == gnome.ChoiceNo && reason == "" {
		return errors.New("reason is required when voting NO in standard proposals")
	}
	return nil
}

// Tally counts the votes and returns the winner voting choice.
func (generalStrategy) Tally(dao *gnome.DAO, r gnome.VotingRecord) gnome.VoteChoice {
	// Consider abstentions to make the majority absolute
	abstentions := len(dao.Members()) - r.VoteCount()
	if choice, ok := gnome.SelectChoiceByMajority(r, abstentions); ok {
		return choice
	}
	return gnome.ChoiceNone
}

// Validate validates if a proposal is valid for the current DAO state.
func (generalStrategy) Validate(p *gnome.Proposal) error {
	if strings.TrimSpace(p.Description()) == "" {
		return errors.New("proposal description is required")
	}
	return nil
}
