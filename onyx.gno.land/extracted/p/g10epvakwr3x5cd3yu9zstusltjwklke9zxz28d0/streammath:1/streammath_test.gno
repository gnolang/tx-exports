package streammath

import (
	"math"
	"testing"
)

func TestValidateSchedule(t *testing.T) {
	tests := []struct {
		name      string
		start     int64
		cliff     int64
		end       int64
		total     int64
		expectErr error
	}{
		{"valid linear no cliff", 100, 100, 200, 1_000_000, nil},
		{"valid with cliff", 100, 125, 200, 1_000_000, nil},
		{"valid bullet cliff at end", 100, 200, 200, 1_000_000, nil},
		{"valid zero start", 0, 10, 50, 1, nil},
		{"zero total", 100, 100, 200, 0, ErrInvalidTotalAmount},
		{"negative total", 100, 100, 200, -500, ErrInvalidTotalAmount},
		{"negative start", -1, 0, 100, 1000, ErrInvalidStartHeight},
		{"end equals start", 100, 100, 100, 1000, ErrInvalidEndHeight},
		{"end before start", 100, 100, 99, 1000, ErrInvalidEndHeight},
		{"cliff before start", 100, 99, 200, 1000, ErrInvalidCliffHeight},
		{"cliff after end", 100, 201, 200, 1000, ErrInvalidCliffHeight},
	}

	for _, tc := range tests {
		err := ValidateSchedule(tc.start, tc.cliff, tc.end, tc.total)
		if err != tc.expectErr {
			t.Errorf("%s: got err=%v, want %v", tc.name, err, tc.expectErr)
		}
	}
}

func TestVestedAmountBoundaries(t *testing.T) {
	// Schedule: 1000 ugnot, start=100, cliff=125, end=200 (duration=100)
	const (
		total = int64(1000)
		start = int64(100)
		cliff = int64(125)
		end   = int64(200)
	)

	cases := []struct {
		height int64
		want   int64
	}{
		{0, 0},
		{99, 0},
		{100, 0},
		{124, 0},   // 1 block before cliff -> strictly 0
		{125, 250}, // exact cliff -> 25% immediately vests
		{150, 500},
		{175, 750},
		{199, 990},
		{200, 1000},
		{250, 1000},
	}

	for _, c := range cases {
		got := VestedAmount(total, start, cliff, end, c.height)
		if got != c.want {
			t.Errorf("height %d: got %d, want %d", c.height, got, c.want)
		}
	}

	// Bullet vesting (cliff == end): 0 until end, full at end
	if got := VestedAmount(5000, 10, 50, 50, 49); got != 0 {
		t.Errorf("bullet before end: got %d, want 0", got)
	}
	if got := VestedAmount(5000, 10, 50, 50, 50); got != 5000 {
		t.Errorf("bullet at end: got %d, want 5000", got)
	}

	// Invalid schedule returns 0
	if got := VestedAmount(1000, 200, 200, 100, 150); got != 0 {
		t.Errorf("invalid schedule: got %d, want 0", got)
	}
}

func TestVestedAmountNoOverflow(t *testing.T) {
	// Large values that would overflow naive int64 (totalAmount * elapsed).
	// math.MaxInt64 * 1_000_000_000 overflows int64 by ~9 orders of magnitude.
	const (
		total    = int64(math.MaxInt64)
		start    = int64(1_000_000)
		duration = int64(1_000_000_000)
		end      = start + duration
	)

	// Halfway through: floor(MaxInt64 / 2)
	mid := start + duration/2
	gotMid := VestedAmount(total, start, start, end, mid)
	wantMid := total / 2
	if gotMid != wantMid {
		t.Errorf("large mid: got %d, want %d", gotMid, wantMid)
	}

	// Quarter way through: floor(MaxInt64 / 4)
	qtr := start + duration/4
	gotQtr := VestedAmount(total, start, start, end, qtr)
	wantQtr := total / 4
	if gotQtr != wantQtr {
		t.Errorf("large quarter: got %d, want %d", gotQtr, wantQtr)
	}

	// End height returns exact MaxInt64
	if gotEnd := VestedAmount(total, start, start, end, end); gotEnd != total {
		t.Errorf("large end: got %d, want %d", gotEnd, total)
	}
}

func TestWithdrawableAmount(t *testing.T) {
	const (
		total = int64(10_000)
		start = int64(100)
		cliff = int64(120)
		end   = int64(200)
	)

	if got := WithdrawableAmount(total, 0, start, cliff, end, 119); got != 0 {
		t.Errorf("before cliff: got %d, want 0", got)
	}
	if got := WithdrawableAmount(total, 0, start, cliff, end, 120); got != 2000 {
		t.Errorf("at cliff: got %d, want 2000", got)
	}
	if got := WithdrawableAmount(total, 2000, start, cliff, end, 120); got != 0 {
		t.Errorf("after claiming at cliff: got %d, want 0", got)
	}
	if got := WithdrawableAmount(total, 2000, start, cliff, end, 150); got != 3000 {
		t.Errorf("halfway after 2000 withdrawn: got %d, want 3000", got)
	}
	if got := WithdrawableAmount(total, 12000, start, cliff, end, 150); got != 0 {
		t.Errorf("over-withdrawn safety: got %d, want 0", got)
	}
}

func TestCancelSplitZeroDustConservation(t *testing.T) {
	// Non-divisible prime total (1_000_003 ugnot) across 53 blocks
	// Testing across 65 heights (before start, pre-cliff, mid-stream, after end)
	const (
		total = int64(1_000_003)
		start = int64(100)
		cliff = int64(111)
		end   = int64(153)
	)

	prevRecipientTotal := int64(0)
	for h := start - 5; h <= end+7; h++ {
		// Case 1: nothing withdrawn yet
		toRec, toSnd := CancelSplit(total, 0, start, cliff, end, h)
		if toRec < 0 || toSnd < 0 {
			t.Fatalf("height %d: negative split (%d, %d)", h, toRec, toSnd)
		}
		if toRec+toSnd != total {
			t.Fatalf("height %d: conservation violated: %d + %d != %d", h, toRec, toSnd, total)
		}
		// Monotonicity of recipient share
		if toRec < prevRecipientTotal {
			t.Fatalf("height %d: recipient vested decreased from %d to %d", h, prevRecipientTotal, toRec)
		}
		prevRecipientTotal = toRec

		// Case 2: half of currently vested already withdrawn
		alreadyWithdrawn := toRec / 2
		toRec2, toSnd2 := CancelSplit(total, alreadyWithdrawn, start, cliff, end, h)
		if toRec2 < 0 || toSnd2 < 0 {
			t.Fatalf("height %d (partial): negative split (%d, %d)", h, toRec2, toSnd2)
		}
		if alreadyWithdrawn+toRec2+toSnd2 != total {
			t.Fatalf("height %d (partial): conservation violated: %d + %d + %d != %d",
				h, alreadyWithdrawn, toRec2, toSnd2, total)
		}
	}

	// Verify exact cliff boundary split: before cliff, 100% goes back to sender
	toRec, toSnd := CancelSplit(total, 0, start, cliff, end, cliff-1)
	if toRec != 0 || toSnd != total {
		t.Errorf("pre-cliff cancel: got (%d, %d), want (0, %d)", toRec, toSnd, total)
	}

	// After end, 100% of remaining goes to recipient
	toRec, toSnd = CancelSplit(total, 300_000, start, cliff, end, end)
	if toRec != 700_003 || toSnd != 0 {
		t.Errorf("post-end cancel: got (%d, %d), want (700003, 0)", toRec, toSnd)
	}
}

func TestProgressBpsAndBar(t *testing.T) {
	if got := ProgressBps(100, 200, 50); got != 0 {
		t.Errorf("before start bps: got %d, want 0", got)
	}
	if got := ProgressBps(100, 200, 100); got != 0 {
		t.Errorf("at start bps: got %d, want 0", got)
	}
	if got := ProgressBps(100, 200, 180); got != 8000 {
		t.Errorf("80%% bps: got %d, want 8000", got)
	}
	if got := ProgressBps(100, 200, 200); got != 10000 {
		t.Errorf("100%% bps: got %d, want 10000", got)
	}
	if got := ProgressBps(100, 200, 999); got != 10000 {
		t.Errorf("past end bps: got %d, want 10000", got)
	}
	// Overflow safety on huge duration
	if got := ProgressBps(0, math.MaxInt64-1, (math.MaxInt64-1)/2); got != 5000 {
		t.Errorf("large duration 50%% bps: got %d, want 5000", got)
	}

	barCases := []struct {
		bps   int64
		width int
		want  string
	}{
		{0, 10, "░░░░░░░░░░ 0.0%"},
		{2550, 10, "██░░░░░░░░ 25.5%"},
		{8000, 10, "████████░░ 80.0%"},
		{10000, 10, "██████████ 100.0%"},
		{-100, 10, "░░░░░░░░░░ 0.0%"},
		{99999, 10, "██████████ 100.0%"},
		{5000, 0, "█████░░░░░ 50.0%"},
	}

	for _, c := range barCases {
		got := ProgressBar(c.bps, c.width)
		if got != c.want {
			t.Errorf("ProgressBar(%d, %d) = %q, want %q", c.bps, c.width, got, c.want)
		}
	}
}

func TestFormatUGNOT(t *testing.T) {
	cases := []struct {
		ugnot int64
		want  string
	}{
		{0, "0.000000 GNOT"},
		{1, "0.000001 GNOT"},
		{500, "0.000500 GNOT"},
		{1_000_000, "1.000000 GNOT"},
		{12_500_000, "12.500000 GNOT"},
		{123_456_789_012, "123456.789012 GNOT"},
		{-12_500_000, "-12.500000 GNOT"},
		{-1, "-0.000001 GNOT"},
	}

	for _, c := range cases {
		got := FormatUGNOT(c.ugnot)
		if got != c.want {
			t.Errorf("FormatUGNOT(%d) = %q, want %q", c.ugnot, got, c.want)
		}
	}
}
