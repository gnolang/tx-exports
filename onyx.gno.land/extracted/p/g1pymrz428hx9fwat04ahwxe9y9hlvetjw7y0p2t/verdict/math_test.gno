package verdict

import "testing"

func TestOutcomeValues(t *testing.T) {
	if OutcomeUnresolved != 0 || OutcomeYes != 1 || OutcomeNo != 2 || OutcomeInvalid != 3 {
		t.Fatalf("unexpected outcome values: (%d,%d,%d,%d)", OutcomeUnresolved, OutcomeYes, OutcomeNo, OutcomeInvalid)
	}
}

type testResolver struct{}

func (testResolver) CanResolve() bool {
	return true
}

func (testResolver) Resolve() (Outcome, error) {
	return OutcomeYes, nil
}

func (testResolver) Description() string {
	return "test resolver"
}

func TestResolver(t *testing.T) {
	var resolver Resolver = testResolver{}
	if !resolver.CanResolve() {
		t.Fatal("expected resolver to be ready")
	}
	outcome, err := resolver.Resolve()
	if err != nil || outcome != OutcomeYes {
		t.Fatalf("got (%d,%v), want (%d,nil)", outcome, err, OutcomeYes)
	}
	if resolver.Description() != "test resolver" {
		t.Fatalf("got %q, want %q", resolver.Description(), "test resolver")
	}
}

func TestCalculateOdds(t *testing.T) {
	tests := []struct {
		name    string
		yes, no int64
		wantYes int64
		wantNo  int64
	}{
		{"empty", 0, 0, 5000, 5000},
		{"balanced", 50, 50, 5000, 5000},
		{"yes only", 100, 0, 10000, 0},
		{"no only", 0, 100, 0, 10000},
		{"two thirds", 200, 100, 6667, 3333},
		{"large intermediate", 9223372036854775807, 0, 10000, 0},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			yes, no := CalculateOdds(tt.yes, tt.no)
			if yes != tt.wantYes || no != tt.wantNo {
				t.Fatalf("got (%d,%d), want (%d,%d)", yes, no, tt.wantYes, tt.wantNo)
			}
		})
	}
}

func TestCalculatePayout(t *testing.T) {
	tests := []struct {
		name                       string
		stake, winning, total, fee int64
		want                       int64
	}{
		{"zero stake", 0, 0, 0, 0, 0},
		{"stake returned", 10, 10, 10, 0, 10},
		{"two for one", 10, 50, 100, 0, 20},
		{"round down", 1, 3, 10, 0, 3},
		{"two percent fee", 10, 50, 100, 200, 19},
		{"truncate before fee", 1, 3, 10, 200, 2},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := CalculatePayout(tt.stake, tt.winning, tt.total, tt.fee)
			if got != tt.want {
				t.Fatalf("got %d, want %d", got, tt.want)
			}
		})
	}
}

func TestPayoutLargeIntermediateWithFee(t *testing.T) {
	const maxInt64 = int64(1<<63 - 1)
	tests := []struct {
		name                       string
		stake, winning, total, fee int64
		want                       int64
	}{
		{"quotient above int64", maxInt64, 2, 3, 9999, 1383505805528216},
		{"quotient above uint64", maxInt64, 1, 100, 9999, 92233720368547758},
		{"full fee with large product", maxInt64, 1, maxInt64, 10000, 0},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := CalculatePayout(tt.stake, tt.winning, tt.total, tt.fee)
			if got != tt.want {
				t.Fatalf("got %d, want %d", got, tt.want)
			}
		})
	}
}

func TestInvalidMathPanics(t *testing.T) {
	assertPanic(t, func() { CalculateOdds(-1, 0) })
	assertPanic(t, func() { CalculatePayout(1, 0, 100, 0) })
	assertPanic(t, func() { CalculatePayout(1, 100, 50, 0) })
	assertPanic(t, func() { CalculatePayout(1, 100, 100, 10001) })
}

func TestNegativeNoPoolPanics(t *testing.T) {
	assertPanic(t, func() { CalculateOdds(0, -1) })
}

func TestNegativeUserStakePanics(t *testing.T) {
	assertPanic(t, func() { CalculatePayout(-1, 100, 100, 0) })
}

func TestNegativeWinningPoolPanics(t *testing.T) {
	assertPanic(t, func() { CalculatePayout(1, -1, 100, 0) })
}

func TestNegativeTotalPoolPanics(t *testing.T) {
	assertPanic(t, func() { CalculatePayout(1, 100, -1, 0) })
}

func TestNegativeFeePanics(t *testing.T) {
	assertPanic(t, func() { CalculatePayout(1, 100, 100, -1) })
}

func TestOddsTotalPoolOverflowPanics(t *testing.T) {
	assertPanic(t, func() { CalculateOdds(9223372036854775807, 1) })
}

func TestPayoutResultOverflowPanics(t *testing.T) {
	assertPanic(t, func() { CalculatePayout(9223372036854775807, 1, 9223372036854775807, 0) })
}

func TestMathProperties(t *testing.T) {
	values := []int64{0, 1, 3, 10, 50, 100, 200}
	fees := []int64{0, 1, 200, 9999, 10000}

	for _, yesPool := range values {
		for _, noPool := range values {
			yesBps, noBps := CalculateOdds(yesPool, noPool)
			if yesBps < 0 || yesBps > 10000 || noBps < 0 || noBps > 10000 || yesBps+noBps != 10000 {
				t.Fatalf("invalid odds for (%d,%d): (%d,%d)", yesPool, noPool, yesBps, noBps)
			}
		}
	}

	for _, stake := range values {
		for _, winningPool := range values {
			if winningPool == 0 {
				continue
			}
			for _, totalPool := range values {
				if totalPool < winningPool {
					continue
				}
				for _, feeBps := range fees {
					payout := CalculatePayout(stake, winningPool, totalPool, feeBps)
					if payout < 0 {
						t.Fatalf("negative payout for (%d,%d,%d,%d): %d", stake, winningPool, totalPool, feeBps, payout)
					}
				}
			}
		}
	}
}

func assertPanic(t *testing.T, fn func()) {
	t.Helper()
	defer func() {
		if recover() == nil {
			t.Fatal("expected panic")
		}
	}()
	fn()
}
