package memba_gov

import "time"

// Stage 0 durations: minutes, so the rehearsal runs in hours.
const (
	VotingPeriod    = 30 * time.Minute
	ExecutionWindow = 60 * time.Minute
	WeightedDelay   = 5 * time.Minute
	HeadcountDelay  = 15 * time.Minute
	RosterDelay     = 10 * time.Minute
	InactiveDelay   = 14 * 24 * time.Hour
	InactiveAfter   = 180 * 24 * time.Hour
	SeedInviteTTL   = 90 * 24 * time.Hour
	VotedInviteTTL  = 30 * 24 * time.Hour
)
