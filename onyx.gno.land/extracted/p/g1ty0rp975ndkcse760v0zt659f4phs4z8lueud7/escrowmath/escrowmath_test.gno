package escrowmath

import "testing"

func TestParseSplitsBps(t *testing.T) {
	splits, err := ParseSplitsBps("4000, 3500, 2500")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(splits) != 3 || splits[0] != 4000 || splits[1] != 3500 || splits[2] != 2500 {
		t.Fatalf("unexpected splits: %v", splits)
	}

	if _, err := ParseSplitsBps("5000,4000"); err == nil {
		t.Fatalf("expected error for sum != 10000")
	}
	if _, err := ParseSplitsBps("10000,0"); err == nil {
		t.Fatalf("expected error for zero split")
	}
}

func TestComputeMilestoneAmountsConservation(t *testing.T) {
	splits := []int64{3333, 3333, 3334}
	total := int64(1000001) // non-divisible amount to test zero-dust remainder conservation
	amts, err := ComputeMilestoneAmounts(total, splits)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	sum := amts[0] + amts[1] + amts[2]
	if sum != total {
		t.Fatalf("conservation violated: got %d, want %d", sum, total)
	}
}

func TestComputeDisputeSplit(t *testing.T) {
	b, s, err := ComputeDisputeSplit(5000000, 6000)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if b != 3000000 || s != 2000000 {
		t.Fatalf("got (%d,%d), want (3000000,2000000)", b, s)
	}
	if _, _, err := ComputeDisputeSplit(1000, 10001); err == nil {
		t.Fatalf("expected error for bps > 10000")
	}
}

func TestFormatAndTiers(t *testing.T) {
	if got := FormatGnot(1250000); got != "1.250000 GNOT" {
		t.Fatalf("got %s", got)
	}
	if got := FormatGnot(500); got != "0.000500 GNOT" {
		t.Fatalf("got %s", got)
	}
	if got := TierForXP(100); got != "Apprentice" {
		t.Fatalf("got %s", got)
	}
	if got := TierForXP(1800); got != "Master" {
		t.Fatalf("got %s", got)
	}
	if got := ProgressBar(50, 100, 10); got != "[#####-----] 50%" {
		t.Fatalf("got %s", got)
	}
}
