package bench

import "gno.land/p/g1nvxaasuu2muqg0nf05jezu5422qtgnx60h2qlp/cube3x3"

const (
	Domain                 = "colorado/v1"
	MaxNotesBytes          = 280
	MaxAgentModelBytes     = 64
	MinQuickWindowSeconds  = 30
	MaxQuickWindowSeconds  = 3600
	DefaultPruneLimit      = 50
	MaxPruneLimit          = 100
	MaxLeaderboardLimit    = 100
	RecentQuickRoundsLimit = 20
)

const (
	ErrInputTooLong      = cube3x3.ErrInputTooLong
	ErrInvalidNotation   = cube3x3.ErrInvalidNotation
	ErrMoveLimit         = cube3x3.ErrMoveLimit
	ErrNotSolved         = cube3x3.ErrNotSolved
	ErrTrivialInverse    = cube3x3.ErrTrivialInverse
	ErrRuleViolation     = cube3x3.ErrRuleViolation
	ErrRoundNotFound     = "ERR_ROUND_NOT_FOUND"
	ErrHashMismatch      = "ERR_HASH_MISMATCH"
	ErrNoCommit          = "ERR_NO_COMMIT"
	ErrPhaseClosed       = "ERR_PHASE_CLOSED"
	ErrInvalidSalt       = "ERR_INVALID_SALT"
	ErrNotesTooLong      = "ERR_NOTES_TOO_LONG"
	ErrRuleNotFound      = "ERR_RULE_NOT_FOUND"
	ErrWindowRange       = "ERR_WINDOW_RANGE"
	ErrInvalidModeTag    = "ERR_INVALID_MODE_TAG"
	ErrInvalidAgentModel = "ERR_INVALID_AGENT_MODEL"
)

type challengeRecord struct {
	RoundKey            string
	Kind                string
	RuleKey             string
	ScrambleMoves       []cube3x3.Move
	ScrambleStr         string
	ScrambleState       cube3x3.Cube
	CommitDeadline      int64
	RevealDeadline      int64
	CommitCount         int
	RevealCount         int
	UnrevealedCount     int
	Creator             string
	CommitWindowSeconds int64
}

type submissionRecord struct {
	Solver         string
	CanonicalMoves string
	OBTM           int
	QTM            int
	RevealedAt     int64
	Notes          string
	ModeTag        string
	AgentModel     string
	Phases         cube3x3.PhaseReport
}

type registeredRule struct {
	Key         string
	Rule        cube3x3.ConstraintRule
	Title       string
	Description string
}
