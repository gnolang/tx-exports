package escrowmath

import (
	"math"
	"testing"
	"unicode/utf8"
)

func TestSplitBasisPointsExactAndDustConservation(t *testing.T) {
	// Odd amount 1001 split 70/30 -> 700 + 300 = 1000, dust 1 goes to 70% weight -> 701 + 300
	shares, err := SplitBasisPoints(1001, []int64{7000, 3000})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(shares) != 2 || shares[0] != 701 || shares[1] != 300 {
		t.Fatalf("expected [701 300], got %v", shares)
	}

	// Equal 3-way split on 100 -> 33+33+33 = 99, dust 1 goes to largest (index 0)
	shares3, err := SplitBasisPoints(100, []int64{3334, 3333, 3333})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	sum := shares3[0] + shares3[1] + shares3[2]
	if sum != 100 {
		t.Fatalf("dust lost: sum=%d != 100 (%v)", sum, shares3)
	}

	// Large overflow-safe amount near MaxInt64
	bigTotal := int64(math.MaxInt64 - 13)
	bigShares, err := SplitBasisPoints(bigTotal, []int64{2500, 7500})
	if err != nil {
		t.Fatalf("unexpected error on big split: %v", err)
	}
	if bigShares[0]+bigShares[1] != bigTotal || bigShares[0] <= 0 || bigShares[1] <= 0 {
		t.Fatalf("big split invalid: %v (total=%d)", bigShares, bigTotal)
	}
}

func TestSplitBasisPointsValidationAndOverflowDefense(t *testing.T) {
	if _, err := SplitBasisPoints(0, []int64{10000}); err != ErrInvalidAmount {
		t.Fatalf("expected ErrInvalidAmount, got %v", err)
	}
	if _, err := SplitBasisPoints(-500, []int64{10000}); err != ErrInvalidAmount {
		t.Fatalf("expected ErrInvalidAmount on negative, got %v", err)
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

	// CRITICAL REGRESSION: int64 wraparound sum == 10000 MUST be rejected!
	// MaxInt64 + MaxInt64 + 10002 wraps to 10000 in two's complement int64.
	if _, err := SplitBasisPoints(20000, []int64{math.MaxInt64, math.MaxInt64, 10002}); err != ErrInvalidWeight {
		t.Fatalf("expected ErrInvalidWeight on wraparound weights, got %v", err)
	}
	if _, err := SplitBasisPoints(20000, []int64{10001}); err != ErrInvalidWeight {
		t.Fatalf("expected ErrInvalidWeight on weight > TotalBPS, got %v", err)
	}

	// Dust-zero share rejection: 1000 ugnot with 1 bps rounds to 0 ugnot
	if _, err := SplitBasisPoints(1000, []int64{9999, 1}); err != ErrZeroShare {
		t.Fatalf("expected ErrZeroShare, got %v", err)
	}
}

func TestProRataRefundExactAndBounded(t *testing.T) {
	// Full refund returns exact deposits
	full, err := ProRataRefund(6_500_000, []int64{5_000_000, 1_500_000})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if full[0] != 5_000_000 || full[1] != 1_500_000 {
		t.Fatalf("expected exact deposits, got %v", full)
	}

	// Partial refund (25% of 6,500,000 = 1,625,000) across creator (5M) & sponsor (1.5M)
	part, err := ProRataRefund(1_625_000, []int64{5_000_000, 1_500_000})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if part[0]+part[1] != 1_625_000 || part[0] != 1_250_000 || part[1] != 375_000 {
		t.Fatalf("unexpected pro-rata refund: %v", part)
	}

	// Bounded Hamilton dust test: 10 sponsors x 10 ugnot = 100, refund 99
	// No single sponsor may receive > 10 ugnot!
	deps := []int64{10, 10, 10, 10, 10, 10, 10, 10, 10, 10}
	r99, err := ProRataRefund(99, deps)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	var sum int64
	for i, r := range r99 {
		if r < 0 || r > deps[i] {
			t.Fatalf("refund[%d]=%d exceeds deposit %d", i, r, deps[i])
		}
		sum += r
	}
	if sum != 99 {
		t.Fatalf("expected sum 99, got %d (%v)", sum, r99)
	}

	// Large 128-bit overflow-proof refund
	bigA := int64(3_000_000_000_000_000_000)
	bigB := int64(2_000_000_000_000_000_000)
	bigPool := int64(2_500_000_000_000_000_001)
	bigR, err := ProRataRefund(bigPool, []int64{bigA, bigB})
	if err != nil {
		t.Fatalf("unexpected error on big refund: %v", err)
	}
	if bigR[0]+bigR[1] != bigPool {
		t.Fatalf("big refund mismatch: %d != %d", bigR[0]+bigR[1], bigPool)
	}

	// Error cases
	if _, err := ProRataRefund(-1, []int64{100}); err != ErrInvalidRefund {
		t.Fatalf("expected ErrInvalidRefund, got %v", err)
	}
	if _, err := ProRataRefund(101, []int64{100}); err != ErrRefundExceedsDeposits {
		t.Fatalf("expected ErrRefundExceedsDeposits, got %v", err)
	}
	if _, err := ProRataRefund(1, []int64{math.MaxInt64, 1}); err != ErrDepositOverflow {
		t.Fatalf("expected ErrDepositOverflow, got %v", err)
	}
}

func TestFormatGNOTBPSAndTiers(t *testing.T) {
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
		{math.MinInt64, "-9223372036854.775808 GNOT"},
		{math.MaxInt64, "9223372036854.775807 GNOT"},
	}
	for _, tc := range cases {
		got := FormatGNOT(tc.in)
		if got != tc.want {
			t.Fatalf("FormatGNOT(%d) = %q, want %q", tc.in, got, tc.want)
		}
	}

	bpsCases := []struct {
		in   int64
		want string
	}{
		{0, "0%"},
		{10000, "100%"},
		{7500, "75%"},
		{6667, "66.67%"},
		{3330, "33.3%"},
		{5, "0.05%"},
	}
	for _, tc := range bpsCases {
		got := FormatBPS(tc.in)
		if got != tc.want {
			t.Fatalf("FormatBPS(%d) = %q, want %q", tc.in, got, tc.want)
		}
	}

	// Wash-XP resistance: 0.001 GNOT micro-bounty gives only 1 XP
	if xp := ComputeXP(1000); xp != 1 {
		t.Fatalf("expected 1 XP for 0.001 GNOT dust bounty, got %d", xp)
	}
	if tier, _ := TierForXP(0); tier != "Novice" {
		t.Fatalf("expected Novice, got %s", tier)
	}
	if tier, _ := TierForXP(ComputeXP(5_000_000)); tier != "Apprentice" {
		t.Fatalf("expected Apprentice for 5 GNOT bounty, got %s", tier)
	}
	if tier, _ := TierForXP(5000); tier != "Grandmaster" {
		t.Fatalf("expected Grandmaster, got %s", tier)
	}
	if TierColor(5000) != "#F59E0B" {
		t.Fatalf("unexpected Grandmaster color")
	}
}

func TestProgressBarAndUTF8SafeTruncation(t *testing.T) {
	if bar := ProgressBar(3, 6, 10); bar != "[#####-----]" {
		t.Fatalf("unexpected bar: %s", bar)
	}
	// Width cap & large-value overflow safety
	capped := ProgressBar(math.MaxInt64/2, math.MaxInt64, 99999)
	if len(capped) != MaxProgressBarWidth+2 {
		t.Fatalf("expected width capped to %d+2, got %d", MaxProgressBarWidth, len(capped))
	}

	// UTF-8 safety: multi-byte runes must never split into invalid UTF-8
	cjk := "赏金猎人协议测试文档内容"
	trunc := TruncateRunes(cjk, 6)
	if !utf8.ValidString(trunc) || trunc != "赏金猎..." {
		t.Fatalf("UTF-8 corruption in TruncateRunes: %q", trunc)
	}

	// SanitizeInline strips bidi/zero-width and truncates cleanly
	sanitized := SanitizeInline("hello\u202E | world\nnext", 14)
	if sanitized != "hello / wor..." {
		t.Fatalf("unexpected sanitize: %q", sanitized)
	}
}
