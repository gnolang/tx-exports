package hello_verify_b

import (
	"strings"
	"testing"
)

func TestRecordCallerDirect(cur realm, t *testing.T) {
	alice := address("g1fn0l3ms5puafp37r7v67mx2msjl0ztnyq3a9yv")
	testing.SetRealm(testing.NewUserRealm(alice))

	out := RecordCaller(cross(cur), "direct-test")
	if !strings.Contains(out, "prevIsEOA=true") {
		t.Fatalf("expected prevIsEOA=true, got: %s", out)
	}
	if !strings.Contains(out, "prevAddr="+alice.String()) {
		t.Fatalf("expected prevAddr=%s, got: %s", alice.String(), out)
	}
	if !strings.Contains(out, "origin="+alice.String()) {
		t.Fatalf("expected origin=%s, got: %s", alice.String(), out)
	}
	if RecordCount() < 1 {
		t.Fatalf("expected record count >= 1")
	}

	jsonOut := Render("json/state")
	if !strings.Contains(jsonOut, `"realm":"hello_verify_b"`) {
		t.Fatalf("unexpected json render: %s", jsonOut)
	}
}
