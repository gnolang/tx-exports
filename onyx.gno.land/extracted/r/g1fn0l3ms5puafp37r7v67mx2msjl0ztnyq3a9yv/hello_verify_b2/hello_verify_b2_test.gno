package hello_verify_b2

import (
	"strings"
	"testing"
)

func TestMutateAndPanic(cur realm, t *testing.T) {
	r := revive(func() {
		MutateAndPanic(cross(cur), "unit")
	})
	if r == nil {
		t.Fatalf("expected abort")
	}
	if s, ok := r.(string); !ok || !strings.Contains(s, "intentional cross-realm panic") {
		t.Fatalf("unexpected abort: %v", r)
	}
}
