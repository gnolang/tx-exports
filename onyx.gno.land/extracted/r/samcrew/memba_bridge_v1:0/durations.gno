package memba_bridge_v1

import "time"

// The pause durations, in their own file so a node fixture, which cannot
// wait days, can replace this file alone; TestProductionDurations pins them.
const (
	EmergencyPauseFor = 7 * 24 * time.Hour  // escrow keeps exits closed this long
	PauseAllowance    = 30 * 24 * time.Hour // one emergency pause per member per period
	MaxPauseAhead     = 30 * 24 * time.Hour
)
