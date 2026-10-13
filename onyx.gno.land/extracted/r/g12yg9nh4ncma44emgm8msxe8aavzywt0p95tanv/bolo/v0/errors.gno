package bolo

// Error is the type of every failure Bolo reports (API C10, §7). Each one is a
// constant, never a variable another realm could reassign (C6), and its text
// starts with its copy key, which a client turns into a message (UI spec §8).
type Error string

func (e Error) Error() string { return string(e) }

const (
	ErrNotFound           Error = "err.not_found: no such campaign or receipt"
	ErrNotUserCall        Error = "err.use_wallet: not a direct transaction from a wallet"
	ErrSessionKey         Error = "err.master_key: a session key can't do this"
	ErrWrongDenom         Error = "err.amount: only ugnot is accepted"
	ErrBadAmount          Error = "err.amount: the amount is wrong"
	ErrDepositMismatch    Error = "err.amount: send exactly the creation deposit"
	ErrPaused             Error = "err.paused: Bolo is paused"
	ErrNotOrganizer       Error = "err.not_allowed: only the organizer can do this"
	ErrNotBeneficiary     Error = "err.not_allowed: only the beneficiary can do this"
	ErrNotAdmin           Error = "err.not_allowed: only the admin can do this"
	ErrCampaignClosed     Error = "err.state: the campaign is closed"
	ErrCampaignSettled    Error = "err.state: the campaign is settled"
	ErrBondSlashed        Error = "err.state: the bond was slashed"
	ErrNoBond             Error = "err.state: there is no bond to slash"
	ErrHoldEnded          Error = "err.state: the bond's hold has ended"
	ErrWrongMode          Error = "err.mode: not for this custody mode"
	ErrNothingToRefund    Error = "err.refund: nothing to refund"
	ErrRefundWindowClosed Error = "err.refund: no refund window is open"
	ErrExitOpen           Error = "err.exit_open: the exit window is open"
	ErrNotClosable        Error = "err.not_yet: the campaign can't be closed yet"
	ErrNotFinalizable     Error = "err.not_yet: the campaign can't be finalized yet"
	ErrNothingToWithdraw  Error = "err.withdraw: nothing to withdraw"
	ErrTitle              Error = "err.text: the title's length is out of bounds"
	ErrDescription        Error = "err.text: the story's length is out of bounds"
	ErrMessage            Error = "err.text: the message's length is out of bounds"
	ErrUpdate             Error = "err.text: the update's length is out of bounds"
	ErrNotice             Error = "err.text: the notice's length is out of bounds"
	ErrImage              Error = "err.text: the photo or its description is invalid"
	ErrMarkup             Error = "err.markup: a story or update holds no image and no raw HTML"
	ErrBeneficiary        Error = "err.input: invalid beneficiary"
	ErrCategory           Error = "err.input: unknown category"
	ErrMode               Error = "err.input: invalid custody mode"
	ErrDeadline           Error = "err.input: invalid deadline"
	ErrGoal               Error = "err.input: invalid goal"
	ErrSetting            Error = "err.input: invalid setting"
	ErrSunset             Error = "err.sunset: this version takes no new campaigns"
	ErrCapReached         Error = "err.cap: the campaign's escrow cap is reached"
	ErrBooksMismatch      Error = "err.internal: the books exceed the bank (INV-1)"
)
