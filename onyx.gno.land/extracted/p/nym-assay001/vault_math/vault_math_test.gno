package vault_math

import "testing"

func eq(t *testing.T, name string, want, got int64) {
	if want != got {
		t.Errorf("%s: want %d, got %d", name, want, got)
	}
}

func mustPanic(t *testing.T, name string, f func()) {
	defer func() {
		if recover() == nil {
			t.Errorf("%s: expected panic", name)
		}
	}()
	f()
}

func TestSimpleYield(t *testing.T) {
	eq(t, "5% x 1", 50, SimpleYield(1000, 500, 1))
	eq(t, "5% x 12", 600, SimpleYield(1000, 500, 12))
	eq(t, "zero periods", 0, SimpleYield(1000, 500, 0))
	eq(t, "rounds down", 0, SimpleYield(1, 1, 1))
}

func TestCompoundYield(t *testing.T) {
	// 1000 at 10% for 2 periods: 100 + 110 = 210
	eq(t, "10% x 2", 210, CompoundYield(1000, 1000, 2))
	eq(t, "zero rate", 0, CompoundYield(1000, 0, 365))
	if CompoundYield(1_000_000, 10, 365) <= SimpleYield(1_000_000, 10, 365) {
		t.Errorf("compounding should beat simple interest")
	}
}

func TestShares(t *testing.T) {
	eq(t, "first deposit 1:1", 500, SharesFor(500, 0, 0))
	eq(t, "pro rata", 50, SharesFor(100, 2000, 1000))
	eq(t, "redeem", 200, AssetsFor(100, 2000, 1000))
	eq(t, "empty vault", 0, AssetsFor(0, 0, 0))
}

func TestAPY(t *testing.T) {
	// 1% monthly compounds to ~12.68% a year.
	eq(t, "1% monthly", 1268, APYBps(100, 12))
}

func TestGuards(t *testing.T) {
	mustPanic(t, "negative", func() { SimpleYield(-1, 1, 1) })
	mustPanic(t, "rate > 100%", func() { SimpleYield(1, 10_001, 1) })
	mustPanic(t, "too many periods", func() { CompoundYield(1, 1, MaxPeriods+1) })
	mustPanic(t, "shares > supply", func() { AssetsFor(11, 100, 10) })
	mustPanic(t, "div by zero", func() { mulDiv(1, 1, 0) })
}
