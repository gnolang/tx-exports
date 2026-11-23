package escrowmath

import "testing"

func TestSplitBasisPointsExactAndDustConservation(t *testing.T) {
	// Odd amount 1001 split 70/30 -> 700 + 300 = 1000, dust 1 goes to 70% weight -> 701 + 300
	shares, err := SplitBasisPoints(1001, []int64{7000, 3000})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(shares) != 2 || shares[0] != 701 || shares[1] != 300 {
		t.Fatalf("expected [701 300], got %v", shares)
	}

	// Equal 3-way split on 100 -> 33+33+33 = 99, dust 1 goes to largest (tie -> index 0)
	shares3, err := SplitBasisPoints(100, []int64{3334, 3333, 3333})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	sum := shares3[0] + shares3[1] + shares3[2]
	if sum != 100 {
		t.Fatalf("dust lost: sum=%d != 100 (%v)", sum, shares3)
	}

	// Large overflow-safe amount: 900,000,000,000,000 ugnot
	bigTotal := int64(900000000000007)
	bigShares, err := SplitBasisPoints(bigTotal, []int64{2500, 7500})
	if err != nil {
		t.Fatalf("unexpected error on big split: %v", err)
	}
	if bigShares[0]+bigShares[1] != bigTotal {
		t.Fatalf("big split sum mismatch: %d != %d", bigShares[0]+bigShares[1], bigTotal)
	}
}

func TestSplitBasisPointsValidation(t *testing.T) {
	if _, err := SplitBasisPoints(0, []int64{10000}); err != ErrInvalidAmount {
		t.Fatalf("expected ErrInvalidAmount, got %v", err)
	}
	if _, err := SplitBasisPoints(100, nil); err != ErrEmptyWeights {
		t.Fatalf("expected ErrEmptyWeights, got %v", err)
	}
	if _, err := SplitBasisPoints(100, []int64{10000, 0}); err != ErrInvalidWeight {
		t.Fatalf("expected ErrInvalidWeight, got %v", err)
	}
	if _, err := SplitBasisPoints(100, []int64{5000, 4000}); err != ErrWeightSum {
		t.Fatalf("expected ErrWeightSum, got %v", err)
	}
}

func TestFormatGNOTAndTiers(t *testing.T) {
	cases := []struct {
		in   int64
		want string
	}{
		{0, "0 GNOT"},
		{1000000, "1 GNOT"},
		{1500000, "1.5 GNOT"},
		{25000, "0.025 GNOT"},
		{1, "0.000001 GNOT"},
		{-1250000, "-1.25 GNOT"},
	}
	for _, tc := range cases {
		got := FormatGNOT(tc.in)
		if got != tc.want {
			t.Fatalf("FormatGNOT(%d) = %q, want %q", tc.in, got, tc.want)
		}
	}

	if tier, _ := TierForXP(0); tier != "Novice" {
		t.Fatalf("expected Novice, got %s", tier)
	}
	if tier, _ := TierForXP(ComputeXP(1000000)); tier != "Apprentice" {
		t.Fatalf("expected Apprentice, got %s", tier)
	}
	if tier, _ := TierForXP(5000); tier != "Grandmaster" {
		t.Fatalf("expected Grandmaster, got %s", tier)
	}
}

func TestHelpers(t *testing.T) {
	if bar := ProgressBar(3, 6, 10); bar != "[#####-----]" {
		t.Fatalf("unexpected bar: %s", bar)
	}
	if s := SanitizeInline("hello | world\nnext", 14); s != "hello / wor..." {
		t.Fatalf("unexpected sanitize: %q", s)
	}
}
