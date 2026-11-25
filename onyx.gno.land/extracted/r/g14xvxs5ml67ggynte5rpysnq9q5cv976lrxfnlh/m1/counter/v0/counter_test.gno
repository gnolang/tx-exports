// Tests for the M1 counter realm.
//
// Pattern verified 2026-11-25 against gnolang/gno tag v1.8.0:
//
//	examples/gno.land/r/demo/profile/profile_test.gno — the exact
//	`testing.SetRealm(testing.NewUserRealm(x))` + `Fn(cross(cur), ...)` idiom,
//	gnovm/tests/stdlibs/testing/context_testing.gno — SetRealm/SetHeight/NewUserRealm,
//	docs/resources/gno-interrealm-v2.md §9 — a panic crossing a realm boundary
//	cannot be caught by defer/recover; the test-mode builtin `revive(fn) any`
//	must be used instead (signature verified in gnovm/pkg/gnolang/uverse.go).
//
// Crossing tests receive `cur realm` as first parameter; calling a crossing
// function with cross(cur) makes the realm set by SetRealm visible to the
// callee as cur.Previous().
package counter

import (
	"strings"
	"testing"
)

// stranger stands in for "anyone who is not admin". This is the real
// feeder-kucoin testnet address — any valid bech32 address works here.
var stranger = address("g1dg7cgrdevgt80c7m5x3vy6k2dywts9hkrptpw0")

// resetState gives every test a clean slate (tests in one package share
// package-level state, exactly like on-chain state is shared).
func resetState() {
	count = 0
	lastCaller = address("")
	lastHeight = 0
}

func TestIncrementRecordsCallerAndHeight(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(stranger))
	testing.SetHeight(123)

	got := Increment(cross(cur))

	if got != 1 {
		t.Fatalf("Increment returned %d, want 1", got)
	}
	if count != 1 {
		t.Fatalf("state count = %d, want 1", count)
	}
	if lastCaller != stranger {
		t.Fatalf("lastCaller = %s, want %s", lastCaller, stranger)
	}
	if lastHeight != 123 {
		t.Fatalf("lastHeight = %d, want 123", lastHeight)
	}
}

func TestIncrementTwice(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(stranger))

	if v := Increment(cross(cur)); v != 1 {
		t.Fatalf("first Increment = %d, want 1", v)
	}
	if v := Increment(cross(cur)); v != 2 {
		t.Fatalf("second Increment = %d, want 2", v)
	}
}

func TestSetCountAllowsAdmin(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(admin))

	SetCount(cross(cur), 42)

	if count != 42 {
		t.Fatalf("count = %d, want 42", count)
	}
}

func TestSetCountRejectsStranger(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(stranger))

	// revive() catches the panic that crosses the realm boundary; a plain
	// defer/recover here would NOT (interrealm v2 spec §9). Note: revive in
	// v1.8.0 does not roll back state mutations made before the panic —
	// safe here because SetCount panics before touching count.
	ex := revive(func() {
		SetCount(cross(cur), 999)
	})
	if ex == nil {
		t.Fatal("SetCount by stranger did not panic — admin guard is broken")
	}
	if count != 0 {
		t.Fatalf("count = %d after rejected SetCount, want 0", count)
	}
}

func TestSetCountRejectsRealmCaller(cur realm, t *testing.T) {
	resetState()
	// Even if the caller is a CODE realm (another contract), it is not a
	// direct user call — IsUserCall() must reject it. This closes the
	// "confused deputy" hole: a malicious realm cannot call SetCount and
	// pass itself off as its user.
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/demo/counter"))

	ex := revive(func() {
		SetCount(cross(cur), 999)
	})
	if ex == nil {
		t.Fatal("SetCount by code realm did not panic — IsUserCall guard is broken")
	}
}

func TestRender(cur realm, t *testing.T) {
	resetState()
	count = 7
	lastCaller = admin
	lastHeight = 99

	res := Render("")

	for _, want := range []string{"count:       7", admin.String(), "last height: 99"} {
		if !strings.Contains(res, want) {
			t.Fatalf("Render output missing %q; got:\n%s", want, res)
		}
	}
}
