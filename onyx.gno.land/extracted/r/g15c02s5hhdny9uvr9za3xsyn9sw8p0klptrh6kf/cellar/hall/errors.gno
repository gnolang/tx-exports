package hall

import "errors"

// Errors returned (as panics) by the hall's public functions.
var (
	ErrNotCurator       = errors.New("hall: only the curator may do this")
	ErrBadAddress       = errors.New("hall: invalid address")
	ErrNotRealm         = errors.New("hall: a challenge must enlist itself from its own realm")
	ErrNilChallenge     = errors.New("hall: nil challenge")
	ErrAlreadyEnlisted  = errors.New("hall: this realm already enlisted a challenge")
	ErrSlugTaken        = errors.New("hall: slug already taken")
	ErrUnknownChallenge = errors.New("hall: no such challenge")
	ErrNotListed        = errors.New("hall: challenge is not open for claims")
	ErrNotPending       = errors.New("hall: challenge is not awaiting review")
	ErrAlreadyClaimed   = errors.New("hall: you already claimed this challenge")
	ErrNotCaptured      = errors.New("hall: the cellar has no record of your capture; break the challenge first")
	ErrNotUser          = errors.New("hall: handles belong to people; call SetHandle directly from your wallet")
	ErrBadHandle        = errors.New("hall: a handle is 3-20 chars of [a-z0-9_], starting with a letter")
	ErrHandleTaken      = errors.New("hall: handle already taken")
	ErrBadSeasonName    = errors.New("hall: a season name is 1-40 printable characters")
)
