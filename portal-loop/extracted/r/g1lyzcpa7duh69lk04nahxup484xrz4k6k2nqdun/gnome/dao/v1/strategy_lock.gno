package gnome

import (
	"errors"
	"strings"
	"time"

	"gno.land/p/demo/json"

	gnome "gno.land/p/g1lyzcpa7duh69lk04nahxup484xrz4k6k2nqdun/gnome/dao"
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
	return "locking"
}

// Quorum returns the minimum required percentage of DAO member votes
// required for a proposal to pass.
func (lockingStrategy) Quorum() float64 {
	return 0.26
}

// VotingPeriod returns the period that a proposal should allow voting.
func (lockingStrategy) VotingPeriod() time.Duration {
	return time.Minute * 30
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

// PreMarshaler defines an interface to enable JSON pre marshalling support.
func (s lockingStrategy) PreMarshal() *json.Node {
	node := json.ObjectNode("", nil)
	node.AppendObject("name", json.StringNode("name", s.Name()))
	node.AppendObject("reason", json.StringNode("reason", s.reason))
	return node
}
