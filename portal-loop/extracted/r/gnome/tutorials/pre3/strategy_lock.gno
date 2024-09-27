package tutorials

import (
	"errors"
	"time"

	gnome "gno.land/p/gnome/dao"
)

type lockingStrategy struct {
	realmPath string
}

func (lockingStrategy) Name() string {
	return StrategyNameLocking
}

func (lockingStrategy) Quorum() float64 {
	return 0.33
}

func (lockingStrategy) VotingPeriod() time.Duration {
	period, _ := parameters.VotingPeriods.Get(StrategyNameLocking)
	return period
}

func (lockingStrategy) VoteChoices() []gnome.VoteChoice {
	return []gnome.VoteChoice{gnome.ChoiceYes, gnome.ChoiceNo}
}

func (s lockingStrategy) Validate(*gnome.Proposal) error {
	// Allow modification of the newxt version package path when realm is locked
	if locked && nextVersionRealmPath == "" && s.realmPath != "" {
		return nil
	}

	if locked {
		return errors.New("realm is already locked")
	}
	return nil
}

func (lockingStrategy) Tally(_ *gnome.DAO, r gnome.VotingRecord) gnome.VoteChoice {
	if choice, ok := gnome.SelectChoiceByPlurality(r); ok {
		return choice
	}
	return gnome.ChoiceNone
}

func (s lockingStrategy) Execute(*gnome.DAO) error {
	locked = true
	if s.realmPath != "" {
		nextVersionRealmPath = s.realmPath
	}
	return nil
}

func (s lockingStrategy) RenderParams() string {
	if s.realmPath != "" {
		return "Next Realm Path: [" + s.realmPath + "](https://" + s.realmPath + ")"
	}
	return ""
}
