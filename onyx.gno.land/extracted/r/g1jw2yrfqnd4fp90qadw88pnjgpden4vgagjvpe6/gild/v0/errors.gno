package gild

// Error messages. Each failure has its own message so callers, tests and the
// web app can tell them apart.
const (
	ErrUserCallOnly = "gild: post must be a direct user call"
	ErrReward       = "gild: send exactly one coin of " + Denom
	ErrRewardRange  = "gild: reward is outside the allowed range"
	ErrTitle        = "gild: title must be 3 to 120 characters"
	ErrDetails      = "gild: details are too long"
	ErrDone         = "gild: done text is too long"
	ErrCategory     = "gild: unknown category"
	ErrDeadline     = "gild: deadline must be 1 hour to 90 days from now"
	ErrNotFound     = "gild: task not found"
	ErrNotOpen      = "gild: task is not open"
	ErrOwnTask      = "gild: you cannot take your own task"
	ErrPastDeadline = "gild: deadline has passed"
	ErrNotDoer      = "gild: only the doer can do this"
	ErrNotPoster    = "gild: only the poster can do this"
	ErrNotTaken     = "gild: task is not taken"
	ErrNotInReview  = "gild: task is not in review"
	ErrURL          = "gild: work link must start with https:// and have no spaces"
	ErrChangesUsed  = "gild: changes were already asked once"
	ErrNote         = "gild: note must be 1 to 1000 characters"
	ErrTooEarly     = "gild: the review window has not ended"
	ErrDoerHasTime  = "gild: the doer still has time before the deadline"
	ErrCannotCancel = "gild: this task can no longer be cancelled"
)
