package escrow

import "testing"

func TestHappyPath(t *testing.T) {
	d := NewDeal("1", "g1client", "g1worker", 1_000_000, "Logo", 100)
	MarkFunded(&d, "g1client", 101)
	if d.State != StateFunded {
		t.Fatal("expected funded")
	}
	Release(&d, "g1client", 102)
	if d.State != StateReleased {
		t.Fatal("expected released")
	}
}

func TestCancelOpen(t *testing.T) {
	d := NewDeal("2", "g1client", "g1worker", 500, "Task", 200)
	Cancel(&d, "g1worker", 201)
	if d.State != StateCancelled {
		t.Fatal("expected cancelled")
	}
}
