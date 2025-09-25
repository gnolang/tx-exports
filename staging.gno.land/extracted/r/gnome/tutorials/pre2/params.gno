package tutorials

import (
	"time"

	gnome "gno.land/p/gnome/dao"
)

// Day defines the duration of a day.
const Day = time.Hour * 24

// Names for the different strategy types.
const (
	StrategyNameCreation     = "tutorial-creation"
	StrategyNameDeletion     = "tutorial-deletion"
	StrategyNameLocking      = "tutorial-realm-locking"
	StrategyNameModification = "tutorial-modification"
	StrategyNameParamsUpdate = "tutorial-params-update"
)

var parameters struct {
	VotingPeriods gnome.DurationParams
}

func init() {
	// Initial voting periods for each proposal type.
	// Periods can be changed by sumitting a params update proposal.
	parameters.VotingPeriods.Set(StrategyNameCreation, Day*3)
	parameters.VotingPeriods.Set(StrategyNameDeletion, Day*3)
	parameters.VotingPeriods.Set(StrategyNameLocking, Day*3)
	parameters.VotingPeriods.Set(StrategyNameModification, Day*3)
	parameters.VotingPeriods.Set(StrategyNameParamsUpdate, time.Minute*10)
}
