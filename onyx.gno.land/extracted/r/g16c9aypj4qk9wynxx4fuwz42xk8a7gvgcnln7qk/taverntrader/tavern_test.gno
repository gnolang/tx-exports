// Tests for the Tavern Trader realm. Run: gno test ./...
// Test functions take (cur realm, t *testing.T) and call exported realm
// functions through cross(cur), the same way an external caller would.
package taverntrader

import (
	"strings"
	"testing"
)

func mustPanic(t *testing.T, name string, f func()) {
	t.Helper()
	defer func() {
		if r := recover(); r == nil {
			t.Fatalf("%s: expected panic, got none", name)
		}
	}()
	f()
}

func TestClaimOwner(cur realm, t *testing.T) {
	if GetOwner() != "" {
		t.Fatalf("owner should start unclaimed")
	}
	ClaimOwner(cross(cur))
	if GetOwner() == "" {
		t.Fatalf("owner should be set after ClaimOwner")
	}
	// NOTE: a second ClaimOwner call panics ("owner already claimed") by
	// design, but it cannot be asserted here: a panic across a cross-realm
	// call is not recoverable by the caller's recover() in the Gno test VM
	// and aborts the whole test run. The exactly-once rule is enforced in
	// ClaimOwner (tavern.gno) and verified live after deploy instead.
}

func TestOpenAndCloseLong(cur realm, t *testing.T) {
	// $10.00 paper long on BTC at $100.00, close at $110.00 -> +$1.00 (+100c).
	id := OpenPaperPosition(cross(cur), "BTC", "long", 1000, 100_000_000, 90_000_000, 120_000_000, 75, "test long")
	pnl := ClosePaperPosition(cross(cur), id, 110_000_000, "test close")
	if pnl != 100 {
		t.Fatalf("long pnl: got %d cents, want 100", pnl)
	}
	if GetRealizedPnLCents() < 100 {
		t.Fatalf("realised pnl should include the +100c close")
	}
}

func TestOpenAndCloseShort(t *testing.T) {
	// $20.00 paper short on ETH at $50.00, close at $45.00 -> +$2.00 (+200c).
	id := openPosition("ETH", "short", 2000, 50_000_000, 55_000_000, 40_000_000, 80, "test short")
	pnl := closePosition(id, 45_000_000, "test close")
	if pnl != 200 {
		t.Fatalf("short pnl: got %d cents, want 200", pnl)
	}
}

func TestLosingClose(t *testing.T) {
	// $10.00 long on SOL at $100.00, close at $95.00 -> -$0.50 (-50c).
	before := GetRealizedPnLCents()
	id := openPosition("SOL", "long", 1000, 100_000_000, 90_000_000, 120_000_000, 65, "test loss")
	pnl := closePosition(id, 95_000_000, "test loss close")
	if pnl != -50 {
		t.Fatalf("losing pnl: got %d cents, want -50", pnl)
	}
	if GetRealizedPnLCents() != before-50 {
		t.Fatalf("realised pnl not updated by the loss")
	}
}

func TestScoreBelowThresholdBlocked(t *testing.T) {
	// Same rule as OpenPaperPosition's cross-realm path (it calls
	// validateTrade first), tested through validateTrade directly:
	// a cross-realm panic is not recoverable in the Gno test VM.
	mustPanic(t, "score 59", func() {
		validateTrade("BTC", "long", 1000, 100_000_000, 90_000_000, 120_000_000, 59)
	})
}

func TestStopLossRequired(t *testing.T) {
	mustPanic(t, "no stop-loss", func() {
		validateTrade("BTC", "long", 1000, 100_000_000, 0, 120_000_000, 75)
	})
	mustPanic(t, "long stop above entry", func() {
		validateTrade("BTC", "long", 1000, 100_000_000, 110_000_000, 120_000_000, 75)
	})
	mustPanic(t, "short stop below entry", func() {
		validateTrade("BTC", "short", 1000, 100_000_000, 90_000_000, 80_000_000, 75)
	})
}

func TestTakeProfitSideEnforced(t *testing.T) {
	mustPanic(t, "long tp below entry", func() {
		validateTrade("BTC", "long", 1000, 100_000_000, 90_000_000, 90_000_000, 75)
	})
	mustPanic(t, "short tp above entry", func() {
		validateTrade("BTC", "short", 1000, 100_000_000, 110_000_000, 110_000_000, 75)
	})
}

func TestPerTradeCap(t *testing.T) {
	mustPanic(t, "size 5001c above $50 cap", func() {
		validateTrade("BTC", "long", 5001, 100_000_000, 90_000_000, 120_000_000, 75)
	})
	// Exactly at the cap is allowed (if no other rule blocks it).
	validateTrade("BTC", "long", 5000, 100_000_000, 90_000_000, 120_000_000, 75)
}

func TestLossCapBlocksNewOpens(t *testing.T) {
	saved := realizedPnLCents
	realizedPnLCents = -DailyLossCapCents - 1
	mustPanic(t, "loss cap breached", func() {
		validateTrade("BTC", "long", 1000, 100_000_000, 90_000_000, 120_000_000, 75)
	})
	realizedPnLCents = saved
}

func TestDoubleCloseBlocked(t *testing.T) {
	id := openPosition("GNOT", "long", 500, 1_000_000, 900_000, 1_200_000, 70, "test double close")
	closePosition(id, 1_100_000, "first close")
	mustPanic(t, "second close", func() {
		closePosition(id, 1_100_000, "second close")
	})
}

func TestRecordScoreAndGetters(cur realm, t *testing.T) {
	RecordScore(cross(cur), "BTC", 72, "test score")
	if !strings.Contains(GetScores("BTC"), "score=72") {
		t.Fatalf("GetScores missing the recorded score")
	}
	id := OpenPaperPosition(cross(cur), "BTC", "long", 1000, 100_000_000, 90_000_000, 120_000_000, 77, "render check")
	line := GetPosition(id)
	if !strings.Contains(line, "BTC") || !strings.Contains(line, "open") {
		t.Fatalf("GetPosition line missing BTC/open: %q", line)
	}
	if GetPosition(999999) != "" {
		t.Fatalf("GetPosition of unknown id should be empty")
	}
	page := Render("")
	if !strings.Contains(page, "Tavern Trader") || !strings.Contains(page, "PAPER ONLY") {
		t.Fatalf("Render page missing header/PAPER label")
	}
	if !strings.Contains(GetPositions(), "BTC") {
		t.Fatalf("GetPositions missing the open BTC position")
	}
	ClosePaperPosition(cross(cur), id, 105_000_000, "cleanup close")
}
