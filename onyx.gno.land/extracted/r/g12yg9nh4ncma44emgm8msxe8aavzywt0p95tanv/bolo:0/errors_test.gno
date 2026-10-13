package bolo

import (
	"strings"
	"testing"
)

// Each error and its copy key, as API §7 pairs them for the registry.
var errorKeys = map[Error]string{
	ErrNotUserCall: "err.use_wallet",
	ErrSessionKey:  "err.master_key",
	ErrNotAdmin:    "err.not_allowed",
	ErrSetting:     "err.input",
}

// TestErrorsLeadWithCopyKeys: every error starts with its own copy key, then ": "
// and a message (API C10).
func TestErrorsLeadWithCopyKeys(t *testing.T) {
	if len(errorKeys) != 4 {
		t.Errorf("%d errors, API §7 gives the registry 4", len(errorKeys))
	}
	for e, want := range errorKeys {
		key, msg, ok := strings.Cut(string(e), ": ")
		if !ok || key != want || msg == "" {
			t.Errorf("%q doesn't start with %s", string(e), want)
		}
	}
}
