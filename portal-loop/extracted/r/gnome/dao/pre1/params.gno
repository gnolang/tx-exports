package gnome

import (
	"time"

	gnome "gno.land/p/gnome/dao"
)

// Day defines the duration of a day.
const Day = time.Hour * 24

// Names for the different strategy types.
const (
	StrategyNameSubDAOCreation         = "sub-dao-creation"
	StrategyNameSubDAODismissal        = "sub-dao-dismissal"
	StrategyNameDAOMembersModification = "dao-members-modification"
	StrategyNameBudget                 = "budget"
	StrategyNameGeneral                = "general"
	StrategyNameLocking                = "locking"
	StrategyNameParamsUpdate           = "params-update"
)

var parameters struct {
	// VotingPeriods contains the current voting period for each proposal type.
	VotingPeriods gnome.DurationParams

	// ReviewDeadline defines the time after which a proposal can't be withdrawed by the proposer.
	// Proposal can only be voted on after this deadline but not before.
	// This greace period gives the proposer the chance to withdraw a proposal if there is a mistake.
	ReviewDeadline time.Duration
}

func init() {
	// Initial voting periods for each proposal type.
	// Periods can be changed by sumitting a params update proposal.
	parameters.VotingPeriods.Set(StrategyNameSubDAOCreation, time.Minute*10)
	parameters.VotingPeriods.Set(StrategyNameSubDAODismissal, Day*7)
	parameters.VotingPeriods.Set(StrategyNameDAOMembersModification, time.Minute*30)
	parameters.VotingPeriods.Set(StrategyNameBudget, Day*7)
	parameters.VotingPeriods.Set(StrategyNameGeneral, Day*2)
	parameters.VotingPeriods.Set(StrategyNameLocking, Day*2)
	parameters.VotingPeriods.Set(StrategyNameParamsUpdate, time.Minute*10)

	// Initial review deadline
	parameters.ReviewDeadline = time.Second
}
