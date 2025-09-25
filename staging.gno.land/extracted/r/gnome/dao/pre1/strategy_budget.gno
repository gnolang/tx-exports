package gnome

import (
	"errors"
	"std"
	"strings"
	"time"

	gnome "gno.land/p/gnome/dao"
)

func newBudgetStrategy(council *gnome.DAO, budget string) budgetStrategy {
	if council == nil {
		panic("council DAO is requried")
	}

	if !council.IsSuperCouncil() {
		panic("budget strategy expects DAO to be a super council")
	}

	budget = strings.TrimSpace(budget)
	if budget == "" {
		panic("budget is required")
	}

	// The council DAO must have at least one sub DAO which should the main DAO.
	// The first sub DAO is some times used to check if a vote is valid.
	if len(council.SubDAOs()) == 0 {
		panic("budget strategy expects council DAO to have at least one sub DAO")
	}

	return budgetStrategy{
		choices: []gnome.VoteChoice{gnome.ChoiceYes, gnome.ChoiceNo},
		council: council,
		budget:  budget, // TODO: Validate/split budget format? (ex. AMOUNTSYMBOL: 10USD)
	}
}

type budgetStrategy struct {
	choices []gnome.VoteChoice
	council *gnome.DAO
	budget  string
}

// Name returns the name of the strategy.
func (budgetStrategy) Name() string {
	return StrategyNameBudget
}

// Quorum returns the minimum required percentage of DAO member votes
// required for a proposal to pass.
func (budgetStrategy) Quorum() float64 {
	return 0.51
}

// VotingPeriod returns the period that a proposal should allow voting.
func (budgetStrategy) VotingPeriod() time.Duration {
	period, _ := parameters.VotingPeriods.Get(StrategyNameBudget)
	return period
}

// VoteChoices returns the valid voting choices for the strategy.
func (s budgetStrategy) VoteChoices() []gnome.VoteChoice {
	return s.choices
}

// CheckVote checks that a vote is valid for the strategy.
func (s budgetStrategy) CheckVote(addr std.Address, _ gnome.VoteChoice, _ string) error {
	// Check that voter address belongs to a council DAO member
	if s.council.HasMember(addr) {
		return nil
	}

	// Make sure the main DAO was not dismissed and check that voter address belongs to a main DAO member
	// TODO: Check DAO status instead when DAO dismissal is implemented
	if sub := s.council.SubDAOs(); len(sub) > 0 {
		mainDAO := sub[0]
		if !mainDAO.HasMember(addr) {
			return errors.New("only members of the council DAO or main DAO can vote on budget proposals")
		}
	} else {
		return errors.New("main DAO not found")
	}
	return nil
}

// Tally counts the votes and returns the winner voting choice.
func (budgetStrategy) Tally(dao *gnome.DAO, r gnome.VotingRecord) gnome.VoteChoice {
	// Consider abstentions to make the majority absolute
	abstentions := len(dao.Members()) - r.VoteCount()
	if choice, ok := gnome.SelectChoiceByMajority(r, abstentions); ok {
		return choice
	}
	return gnome.ChoiceNone
}

// RenderParams returns a markdown with the rendered strategy parameters.
func (s budgetStrategy) RenderParams() string {
	return "Budget: " + gnome.EscapeHTML(s.budget)
}
