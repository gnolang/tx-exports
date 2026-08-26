package ambassadorweek

import "testing"

func TestIncrement(cur realm, t *testing.T) {
	value := Increment(cross(cur))
	if value != 1 {
		t.Fatalf("expected 1, got %d", value)
	}
}
