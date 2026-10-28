package factory_v6

import (
	"chain"
	"strings"
	"testing"
)

// Regression tests for PAY-1 (docs/SECURITY_AUDIT_2026-06-13.md): every payment
// entry point must reject callers that are not a direct EOA, because
// unsafe.OriginSend() reports the tx envelope, not coins actually received.
//
// These use only the builtin testing package + revive() (cross-realm aborts are
// not catchable by defer/recover), avoiding any external test dependency.

// An intermediary code realm (a wrapper called with --send, or a `gnokey maketx
// run` ephemeral realm) must be rejected: otherwise it could keep the user's
// coins and still launch/trade against the full OriginSend envelope.
func TestPAY1_RejectsIntermediaryRealm(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/attacker/wrapper"))
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin("ugnot", CREATE_FEE)))

	r := revive(func() {
		LaunchToken(cross(cur), "ATK", "Attack Token", "", "", "", "", "", "", "")
	})
	if r == nil {
		t.Fatalf("PAY-1: LaunchToken must abort for an intermediary code realm, but it succeeded")
	}
	msg, ok := r.(string)
	if !ok || !strings.Contains(msg, "must come directly from a user account") {
		t.Fatalf("PAY-1: expected EOA-guard abort, got: %v", r)
	}
	if _, exists := tokenRegistry["ATK"]; exists {
		t.Fatalf("PAY-1: rejected launch must not register a token")
	}
}

// The intended path - a direct user call (maketx call) - must still succeed.
func TestPAY1_AllowsDirectEOA(cur realm, t *testing.T) {
	addr := address("g1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq4p0n2m")
	testing.SetRealm(testing.NewUserRealm(addr))
	testing.SetOriginCaller(addr)
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin("ugnot", CREATE_FEE)))

	r := revive(func() {
		LaunchToken(cross(cur), "GUD", "Good Token", "", "", "", "", "", "", "")
	})
	if r != nil {
		t.Fatalf("PAY-1: direct EOA LaunchToken must succeed, got abort: %v", r)
	}
	if _, exists := tokenRegistry["GUD"]; !exists {
		t.Fatalf("PAY-1: GUD should be registered after a successful direct-EOA launch")
	}
}
