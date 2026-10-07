package memba_bridge_v1

import "time"

// Stage 0 durations: minutes, so the rehearsal runs in hours.
const (
	EmergencyPauseFor = 10 * time.Minute
	PauseAllowance    = 6 * time.Hour
	MaxPauseAhead     = 6 * time.Hour
)
