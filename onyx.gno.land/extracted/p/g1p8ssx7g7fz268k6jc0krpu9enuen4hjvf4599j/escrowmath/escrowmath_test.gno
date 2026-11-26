package escrowmath

import "testing"

func TestValidateMilestones(t *testing.T) {
	bps, err := ValidateMilestones([]int64{1000000, 2000000, 1000000}, 4000000)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(bps) != 3 || bps[0] != 2500 || bps[1] != 5000 || bps[2] != 2500 {
		t.Fatalf("unexpected bps: %v", bps)
	}

	// Rounding remainder goes to last milestone so total equals 10000 bps.
	bpsOdd, err := ValidateMilestones([]int64{100, 100, 100}, 300)
	if err != nil {
		t.Fatalf("unexpected error on equal 3-way split: %v", err)
	}
	if bpsOdd[0]+bpsOdd[1]+bpsOdd[2] != BpsDenominator {
		t.Fatalf("expected bps sum 10000, got %d", bpsOdd[0]+bpsOdd[1]+bpsOdd[2])
	}

	// Sum mismatch must fail.
	if _, err := ValidateMilestones([]int64{500, 500}, 999); err != ErrDepositMismatch {
		t.Fatalf("expected ErrDepositMismatch, got %v", err)
	}

	// Zero or negative amounts must fail.
	if _, err := ValidateMilestones([]int64{0, 1000}, 1000); err != ErrInvalidAmount {
		t.Fatalf("expected ErrInvalidAmount, got %v", err)
	}

	// Empty milestones must fail.
	if _, err := ValidateMilestones(nil, 1000); err != ErrNoMilestones {
		t.Fatalf("expected ErrNoMilestones, got %v", err)
	}
}

func TestDisputeQuorumAndDeadlock(t *testing.T) {
	if QuorumThreshold(1) != 1 || QuorumThreshold(3) != 2 || QuorumThreshold(5) != 3 {
		t.Fatalf("wrong quorum threshold calculation")
	}

	if out, ok := EvaluateDisputeTally(1, 0, 0, 3); ok || out != "" {
		t.Fatalf("1 of 3 should not reach quorum, got %s %v", out, ok)
	}
	if out, ok := EvaluateDisputeTally(2, 1, 0, 3); !ok || out != "RELEASE" {
		t.Fatalf("expected RELEASE, got %s %v", out, ok)
	}
	if out, ok := EvaluateDisputeTally(0, 2, 0, 3); !ok || out != "REFUND" {
		t.Fatalf("expected REFUND, got %s %v", out, ok)
	}
	// 3-way deadlock (1-1-1 out of 3 arbiters) must deterministically resolve to SPLIT.
	if out, ok := EvaluateDisputeTally(1, 1, 1, 3); !ok || out != "SPLIT" {
		t.Fatalf("expected deadlock SPLIT fallback, got %s %v", out, ok)
	}
}

func TestComputeSplitConservation(t *testing.T) {
	b, s := ComputeSplit(1001)
	if b != 501 || s != 500 || b+s != 1001 {
		t.Fatalf("odd split not conserved: %d + %d", b, s)
	}
	b2, s2 := ComputeSplit(2000000)
	if b2 != 1000000 || s2 != 1000000 {
		t.Fatalf("even split wrong: %d / %d", b2, s2)
	}
}

func TestFormatAndProgress(t *testing.T) {
	if got := FormatUGNOT(1500000); got != "1.5 GNOT" {
		t.Fatalf("got %q, want 1.5 GNOT", got)
	}
	if got := FormatUGNOT(2000000); got != "2 GNOT" {
		t.Fatalf("got %q, want 2 GNOT", got)
	}
	if got := FormatUGNOT(500); got != "0.0005 GNOT" {
		t.Fatalf("got %q, want 0.0005 GNOT", got)
	}
	bar := RenderProgressBar(50, 100, 10)
	if bar != "[█████░░░░░] 50%" {
		t.Fatalf("unexpected progress bar: %q", bar)
	}
	if esc := EscapeJSON("hi \"gno\"\nline2"); esc != `hi \"gno\"\nline2` {
		t.Fatalf("unexpected escaped json: %q", esc)
	}
}
