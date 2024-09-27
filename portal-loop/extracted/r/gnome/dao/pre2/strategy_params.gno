package gnome

import (
	"strings"
	"time"

	gnome "gno.land/p/gnome/dao"
)

type paramsUpdateStrategy struct {
	votingPeriods  gnome.DurationParams
	reviewDeadline time.Duration
}

func (paramsUpdateStrategy) Name() string {
	return StrategyNameParamsUpdate
}

func (paramsUpdateStrategy) Quorum() float64 {
	return 0.51
}

func (paramsUpdateStrategy) VotingPeriod() time.Duration {
	period, _ := parameters.VotingPeriods.Get(StrategyNameParamsUpdate)
	return period
}

func (paramsUpdateStrategy) VoteChoices() []gnome.VoteChoice {
	return []gnome.VoteChoice{gnome.ChoiceYes, gnome.ChoiceNo}
}

func (paramsUpdateStrategy) Tally(dao *gnome.DAO, r gnome.VotingRecord) gnome.VoteChoice {
	abstentions := len(dao.Members()) - r.VoteCount()
	if choice, ok := gnome.SelectChoiceByMajority(r, abstentions); ok {
		return choice
	}
	return gnome.ChoiceNone
}

func (s paramsUpdateStrategy) Execute(*gnome.DAO) error {
	if s.reviewDeadline > 0 {
		parameters.ReviewDeadline = s.reviewDeadline
	}

	s.votingPeriods.Iterate(func(name string, period time.Duration) bool {
		parameters.VotingPeriods.Set(name, period)
		return false
	})
	return nil
}

func (s paramsUpdateStrategy) RenderParams() string {
	var b strings.Builder

	b.WriteString("|||\n|---|---|\n")
	if s.reviewDeadline > 0 {
		b.WriteString("| Proposal Review Deadline: | " + gnome.HumanizeDuration(s.reviewDeadline) + " |\n")
	}

	s.votingPeriods.Iterate(func(name string, period time.Duration) bool {
		b.WriteString("| Voting Period for `" + name + "`: | " + gnome.HumanizeDuration(period) + " |\n")
		return false
	})

	return b.String()
}
