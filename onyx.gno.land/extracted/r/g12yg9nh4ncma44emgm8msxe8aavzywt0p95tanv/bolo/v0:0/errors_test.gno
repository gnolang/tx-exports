package bolo

import (
	"strings"
	"testing"
)

// Each error and its copy key, as API §7 pairs them; every key resolves to a
// message in UI spec §8.
var errorKeys = map[Error]string{
	ErrNotFound:           "err.not_found",
	ErrNotUserCall:        "err.use_wallet",
	ErrSessionKey:         "err.master_key",
	ErrWrongDenom:         "err.amount",
	ErrBadAmount:          "err.amount",
	ErrDepositMismatch:    "err.amount",
	ErrPaused:             "err.paused",
	ErrNotOrganizer:       "err.not_allowed",
	ErrNotBeneficiary:     "err.not_allowed",
	ErrNotAdmin:           "err.not_allowed",
	ErrCampaignClosed:     "err.state",
	ErrCampaignSettled:    "err.state",
	ErrBondSlashed:        "err.state",
	ErrNoBond:             "err.state",
	ErrHoldEnded:          "err.state",
	ErrWrongMode:          "err.mode",
	ErrNothingToRefund:    "err.refund",
	ErrRefundWindowClosed: "err.refund",
	ErrExitOpen:           "err.exit_open",
	ErrNotClosable:        "err.not_yet",
	ErrNotFinalizable:     "err.not_yet",
	ErrNothingToWithdraw:  "err.withdraw",
	ErrTitle:              "err.text",
	ErrDescription:        "err.text",
	ErrMessage:            "err.text",
	ErrUpdate:             "err.text",
	ErrNotice:             "err.text",
	ErrImage:              "err.text",
	ErrMarkup:             "err.markup",
	ErrBeneficiary:        "err.input",
	ErrCategory:           "err.input",
	ErrMode:               "err.input",
	ErrDeadline:           "err.input",
	ErrGoal:               "err.input",
	ErrSetting:            "err.input",
	ErrSunset:             "err.sunset",
	ErrCapReached:         "err.cap",
	ErrBooksMismatch:      "err.internal",
}

// TestErrorsLeadWithCopyKeys: every error of API §7 starts with its own copy key,
// then ": " and a message (API C10). The static check refuses an Error without a
// key; this pins which key each one has.
func TestErrorsLeadWithCopyKeys(t *testing.T) {
	if len(errorKeys) != 38 {
		t.Errorf("%d errors, API §7 has 38", len(errorKeys))
	}
	for e, want := range errorKeys {
		key, msg, ok := strings.Cut(string(e), ": ")
		if !ok || key != want || msg == "" {
			t.Errorf("%q doesn't start with %s", string(e), want)
		}
	}
}
