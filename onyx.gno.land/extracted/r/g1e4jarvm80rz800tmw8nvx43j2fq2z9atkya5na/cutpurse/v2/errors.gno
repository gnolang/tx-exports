package cutpurse

// SPEC §8. Every panic in this realm is one of these strings, verbatim.
const (
	ErrBadAction       = "cutpurse: e400 bad-action"
	ErrBadFee          = "cutpurse: e400 bad-fee"
	ErrBadName         = "cutpurse: e400 bad-name"
	ErrBadHash         = "cutpurse: e400 bad-hash"
	ErrBadSalt         = "cutpurse: e400 bad-salt"
	ErrSameJob         = "cutpurse: e400 same-job"
	ErrBadPhase        = "cutpurse: e400 bad-phase"
	ErrNotSeated       = "cutpurse: e401 not-seated"
	ErrNotCreator      = "cutpurse: e401 not-creator"
	ErrSpoofed         = "cutpurse: e403 spoofed-realm"
	ErrNotUserCall     = "cutpurse: e403 not-user-call"
	ErrNoJob           = "cutpurse: e404 no-job"
	ErrFull            = "cutpurse: e409 full"
	ErrAlreadySeated   = "cutpurse: e409 already-seated"
	ErrAlreadyComitted = "cutpurse: e409 already-committed"
	ErrHashMismatch    = "cutpurse: e409 hash-mismatch"
	ErrAlreadySettled  = "cutpurse: e409 already-settled"
	ErrDeadlinePassed  = "cutpurse: e410 deadline-passed"
	ErrNotReady        = "cutpurse: e412 not-ready"
	ErrFeeTooLow       = "cutpurse: e413 fee-too-low"
	ErrPotCap          = "cutpurse: e413 pot-cap"
	ErrTooManyLive     = "cutpurse: e429 too-many-live-jobs"
	ErrPayoutFailed    = "cutpurse: e500 payout-failed"
)
