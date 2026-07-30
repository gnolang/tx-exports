package myrealm

import "testing"

func TestIncrement(cur realm, t *testing.T) {
	val := Increment(cross(cur))
	if val != 1 {
		t.Fatalf("expected 1, got %d", val)
	}
}