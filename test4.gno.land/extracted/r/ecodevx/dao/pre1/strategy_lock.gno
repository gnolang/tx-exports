package gnome

import (
	"errors"
	"strings"
	"time"

	gnome "gno.land/p/ecodevx/dao"
)

// newLockingStrategy creates a new DAO locking proposal strategy.
func newLockingStrategy(council *gnome.DAO, reason string, preLockFn func() error) lockingStrategy {
	// Locking should only be done in the council DAO
	if !council.IsSuperCouncil() {
		panic("DAO is not the council")
	}

	return lockingStrategy{
		choices:   []gnome.VoteChoice{gnome.ChoiceYes, gnome.ChoiceNo},
		council:   council,
		reason:    reason,
		preLockFn: preLockFn,
	}
}

type lockingStrategy struct {
	choices   []gnome.VoteChoice
	council   *gnome.DAO
	reason    string
	preLockFn func() error
}

// Name returns the name of the strategy.
func (lockingStrategy) Name() string {
	return StrategyNameLocking
}

// Quorum returns the minimum required percentage of DAO member votes
// required for a proposal to pass.
func (lockingStrategy) Quorum() float64 {
	return 0.33
}

// VotingPeriod returns the period that a proposal should allow voting.
func (lockingStrategy) VotingPeriod() time.Duration {
	period, _ := parameters.VotingPeriods.Get(StrategyNameLocking)
	return period
}

// VoteChoices returns the valid voting choices for the strategy.
func (s lockingStrategy) VoteChoices() []gnome.VoteChoice {
	return s.choices
}

// Tally counts the votes and returns the winner voting choice.
func (lockingStrategy) Tally(_ *gnome.DAO, r gnome.VotingRecord) gnome.VoteChoice {
	if choice, ok := gnome.SelectChoiceByPlurality(r); ok {
		return choice
	}
	return gnome.ChoiceNone
}

// Validate validates if a proposal is valid for the current state.
func (s lockingStrategy) Validate(*gnome.Proposal) error {
	if s.council.IsLocked() {
		return errors.New("council DAO is already locked")
	}
	return nil
}

// Execute locks the council DAO.
func (s lockingStrategy) Execute(*gnome.DAO) (err error) {
	if s.preLockFn != nil {
		if err := s.preLockFn(); err != nil {
			return err
		}
	}

	s.council.Lock(s.reason)
	return nil
}

// RenderParams returns a markdown with the rendered strategy parameters.
func (s lockingStrategy) RenderParams() string {
	var b strings.Builder

	b.WriteString("|||\n|---|---|\n")
	b.WriteString("| Reason: | " + gnome.EscapeHTML(s.reason) + " |\n")

	return b.String()
}
