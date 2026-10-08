package memba_gov

import "time"

// The policy's durations, in their own file so a node fixture, which cannot
// wait days, can replace this file alone and run the real rules faster.
const (
	VotingPeriod    = 7 * 24 * time.Hour
	ExecutionWindow = 7 * 24 * time.Hour
	WeightedDelay   = 24 * time.Hour // critical, weight route
	HeadcountDelay  = 72 * time.Hour // critical, headcount route
	RosterDelay     = 7 * 24 * time.Hour
	InactiveDelay   = 14 * 24 * time.Hour
	InactiveAfter   = 180 * 24 * time.Hour
	SeedInviteTTL   = 90 * 24 * time.Hour
	VotedInviteTTL  = 30 * 24 * time.Hour
)
