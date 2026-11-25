package probesha

import "testing"

func TestSum(t *testing.T) {
	if len(Sum("kolektif")) != 4 {
		t.Fatalf("unexpected length")
	}
}
