package arena

import "errors"

// Errors are values created once, at package init: a panic with one of them
// costs no allocation. Messages that need a value are built at the call.
var (
	errSpoofedRealm = errors.New("gnofly: spoofed realm")
	errNotOwner     = errors.New("gnofly: caller is not the owner")
	errNotAdmin     = errors.New("gnofly: caller is not an admin")
	errNotReferee   = errors.New("gnofly: caller is not a referee")

	errInvalidSpec        = errors.New("gnofly: invalid arena spec")
	errInvalidMode        = errors.New("gnofly: mode must be one of: battle-royale, deathmatch")
	errInvalidStake       = errors.New("gnofly: stake must be between 1000000 and 1000000000 ugnot")
	errInvalidSeats       = errors.New("gnofly: seats must satisfy 2 <= minSeats <= maxSeats <= 8")
	errInvalidLives       = errors.New("gnofly: lives must be between 1 and 3")
	errInvalidSeconds     = errors.New("gnofly: game time must be between 300 and 1800 seconds")
	errInvalidKillTarget  = errors.New("gnofly: the kill target must be between 0 and 20")
	errRoyaleTarget       = errors.New("gnofly: battle-royale has no kill target: the last one flying wins")
	errInvalidAddress     = errors.New("gnofly: invalid address")
	errInvalidRefundDelay = errors.New("gnofly: refund delay must be between 60 and 86400 seconds")
	errUnknownArena       = errors.New("gnofly: unknown arena")

	errNotUserCall    = errors.New("gnofly: Enter must be called directly by a user (maketx call)")
	errEntryClosed    = errors.New("gnofly: this arena no longer takes entries")
	errNotYetCreated  = errors.New("gnofly: this arena was created in the future")
	errInvalidTicket  = errors.New("gnofly: ticket must be 64 lowercase hex characters")
	errAlreadyInLobby = errors.New("gnofly: already in the lobby of this arena")
	errLobbyFull      = errors.New("gnofly: the lobby is full")
	errNotInLobby     = errors.New("gnofly: not in the lobby of this arena")
	errNotExpired     = errors.New("gnofly: this arena still takes entries")

	errRoundRunning   = errors.New("gnofly: the game of this arena has started")
	errTooFewPlayers  = errors.New("gnofly: fewer players than the arena requires")
	errNoRound        = errors.New("gnofly: the game of this arena is not running")
	errRefundTooEarly = errors.New("gnofly: the game cannot be refunded yet")

	errBadSettlement = errors.New("gnofly: settlement refused: the rule pays someone who did not play, twice, or nothing")
	errNotConserved  = errors.New("gnofly: settlement refused: payouts and fee do not add up to the pot")
	errEscrow        = errors.New("gnofly: escrow accounting error")
	errInsolvent     = errors.New("gnofly: the realm holds less than the stakes it owes")

	errNothingToClaim = errors.New("gnofly: nothing to claim")
	errCorruptClaims  = errors.New("gnofly: corrupt claims record")

	errCorruptResult   = errors.New("gnofly: corrupt result record")
	errCorruptEarnings = errors.New("gnofly: corrupt earnings record")
)
