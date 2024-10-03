package space

import (
	"time"

	gnome "gno.land/p/ecodevx/dao"
)

// Day defines the duration of a day.
const Day = time.Hour * 24

// Names for the different strategy types.
const (
	StrategyNameDataSection         = "space-data-section"
	StrategyNameEditorsModification = "space-editors-modification"
	StrategyNameLocking             = "space-realm-locking"
	StrategyNameParamsUpdate        = "space-params-update"
)

var parameters struct {
	VotingPeriods gnome.DurationParams
	SpaceDAO      string
}

func init() {
	// Initial voting periods for each proposal type.
	// Periods can be changed by sumitting a params update proposal.
	parameters.VotingPeriods.Set(StrategyNameDataSection, Day*5)
	parameters.VotingPeriods.Set(StrategyNameEditorsModification, Day*2)
	parameters.VotingPeriods.Set(StrategyNameLocking, Day*3)
	parameters.VotingPeriods.Set(StrategyNameParamsUpdate, time.Minute*10)

	// Path to the Gnome space DAO
	parameters.SpaceDAO = "council/main/space"
}
