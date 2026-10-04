package game

import "errors"

var (
	errSpoofedRealm   = errors.New("gnofly: spoofed realm")
	errNotOwner       = errors.New("gnofly: caller is not the owner")
	errNotAdmin       = errors.New("gnofly: caller is not an admin")
	errNotReferee     = errors.New("gnofly: caller is not a referee")
	errInvalidAddress = errors.New("gnofly: invalid address")
	errAlreadyAdmin   = errors.New("gnofly: address is already an admin")
	errNoSuchAdmin    = errors.New("gnofly: address is not in the admin list")
	errAlreadyReferee = errors.New("gnofly: address is already a referee")
	errNoSuchReferee  = errors.New("gnofly: address is not a referee")
	errTreasurySelf   = errors.New("gnofly: the treasury cannot be the realm itself")

	errUnknownParam     = errors.New("gnofly: unknown param")
	errInvalidBounds    = errors.New("gnofly: bounds must satisfy 0 <= min <= max")
	errValueOutOfBounds = errors.New("gnofly: the current value is outside these bounds, set the value first")
	errLeaderboardMin   = errors.New("gnofly: leaderboard_size cannot go below 1")
)
