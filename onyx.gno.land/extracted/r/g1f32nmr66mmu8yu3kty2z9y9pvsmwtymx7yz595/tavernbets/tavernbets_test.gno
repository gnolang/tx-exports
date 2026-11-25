// Tests for Tavern Bets. Internal functions take explicit caller/amount/time
// parameters so every rule is testable without chain hooks. Tests share the
// realm's global state, so each test creates its own market and uses the
// returned id instead of assuming absolute ids.
package tavernbets

import (
	"strconv"
	"strings"
	"testing"
)

// Fixed test actors (real bech32 addresses taken from Gno docs examples).
var (
	alice = address("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5")
	bob   = address("g1y0n2geu0rmdrm9u30c5fmk3ykkl2enw9n9yr2k")
	carol = address("g1leu8d2vsplhehcfkjg50mwgdpxdkt8tztu95wr")
)

// now is a fixed "current time" for tests (unix seconds).
const now = int64(1_800_000_000)

const day = int64(86400)

// mustPanic fails the test unless f panics.
func mustPanic(t *testing.T, f func()) {
	t.Helper()
	defer func() {
		if r := recover(); r == nil {
			t.Fatal("expected panic, got none")
		}
	}()
	f()
}

func TestCreateMarket(t *testing.T) {
	id := createMarket(alice, "Will the tavern be full tonight?", now+day, now)
	if id < 1 {
		t.Fatalf("expected a positive market id, got %d", id)
	}
	m := mustMarket(id)
	if m.Question != "Will the tavern be full tonight?" {
		t.Fatalf("wrong question stored: %q", m.Question)
	}
	if m.Creator != alice {
		t.Fatalf("wrong creator stored: %v", m.Creator)
	}
	if m.Deadline != now+day {
		t.Fatalf("wrong deadline stored: %d", m.Deadline)
	}
	if m.Resolved || m.YesPool != 0 || m.NoPool != 0 {
		t.Fatal("new market must be unresolved with empty pools")
	}
}

func TestCreateMarketInvalid(t *testing.T) {
	mustPanic(t, func() { createMarket(alice, "", now+day, now) })
	mustPanic(t, func() { createMarket(alice, "Q?", now, now) })
	mustPanic(t, func() { createMarket(alice, "Q?", now-day, now) })
}

func TestBetBothSides(t *testing.T) {
	id := createMarket(alice, "Will it rain tomorrow?", now+day, now)
	placeBet(alice, id, true, 100, now)
	placeBet(bob, id, false, 300, now)
	placeBet(alice, id, true, 50, now)
	m := mustMarket(id)
	if m.YesPool != 150 {
		t.Fatalf("YES pool = %d, want 150", m.YesPool)
	}
	if m.NoPool != 300 {
		t.Fatalf("NO pool = %d, want 300", m.NoPool)
	}
	if len(m.YesBets) != 2 || len(m.NoBets) != 1 {
		t.Fatalf("bet counts wrong: YES %d, NO %d", len(m.YesBets), len(m.NoBets))
	}
}

func TestBetInvalid(t *testing.T) {
	id := createMarket(alice, "Bet validation?", now+day, now)
	mustPanic(t, func() { placeBet(alice, id, true, 0, now) })
	mustPanic(t, func() { placeBet(alice, id, true, -5, now) })
	mustPanic(t, func() { placeBet(alice, 999999, true, 10, now) })
	mustPanic(t, func() { placeBet(alice, id, true, 10, now+day) })
}

func TestResolveBeforeDeadlineFails(t *testing.T) {
	id := createMarket(alice, "Too early?", now+day, now)
	mustPanic(t, func() { resolveMarket(alice, id, true, now) })
	mustPanic(t, func() { resolveMarket(alice, id, true, now+day-1) })
}

func TestResolveByNonCreatorFails(t *testing.T) {
	id := createMarket(alice, "Not yours?", now+day, now)
	mustPanic(t, func() { resolveMarket(bob, id, true, now+day+1) })
	mustPanic(t, func() { resolveMarket(carol, id, false, now+day+1) })
}

func TestDoubleResolveFails(t *testing.T) {
	id := createMarket(alice, "Once only?", now+day, now)
	resolveMarket(alice, id, true, now+day+1)
	mustPanic(t, func() { resolveMarket(alice, id, false, now+day+2) })
}

func TestBetAfterResolveFails(t *testing.T) {
	id := createMarket(alice, "Closed?", now+day, now)
	placeBet(alice, id, true, 100, now)
	resolveMarket(alice, id, true, now+day+1)
	mustPanic(t, func() { placeBet(bob, id, false, 10, now+day+2) })
}

func TestResolveNonexistentFails(t *testing.T) {
	mustPanic(t, func() { resolveMarket(alice, 999999, true, now) })
}

// TestClaimProRataExact checks the payout math with concrete numbers.
// Case 1 (3:1 pool): YES pool 100 (alice), NO pool 300 (bob), YES wins.
// Alice gets 100 + 100*300/100 = 400 ugnot — exactly 4x her stake.
// Case 2 (two winners): YES 100 (alice) + 100 (carol), NO 400 (bob), YES wins.
// Each winner gets 100 + 100*400/200 = 300; total paid 600 = whole pool.
func TestClaimProRataExact(t *testing.T) {
	id1 := createMarket(alice, "3:1 split?", now+day, now)
	placeBet(alice, id1, true, 100, now)
	placeBet(bob, id1, false, 300, now)
	resolveMarket(alice, id1, true, now+day+1)
	payout := claimWinnings(alice, id1)
	if payout != 400 {
		t.Fatalf("case 1: payout = %d, want exactly 400", payout)
	}

	id2 := createMarket(alice, "Two winners?", now+day, now)
	placeBet(alice, id2, true, 100, now)
	placeBet(carol, id2, true, 100, now)
	placeBet(bob, id2, false, 400, now)
	resolveMarket(alice, id2, true, now+day+1)
	if p := claimWinnings(alice, id2); p != 300 {
		t.Fatalf("case 2 alice: payout = %d, want exactly 300", p)
	}
	if p := claimWinnings(carol, id2); p != 300 {
		t.Fatalf("case 2 carol: payout = %d, want exactly 300", p)
	}
}

func TestClaimByLoserFails(t *testing.T) {
	id := createMarket(alice, "Losers get nothing?", now+day, now)
	placeBet(alice, id, true, 100, now)
	placeBet(bob, id, false, 300, now)
	resolveMarket(alice, id, true, now+day+1)
	mustPanic(t, func() { claimWinnings(bob, id) })
}

func TestDoubleClaimFails(t *testing.T) {
	id := createMarket(alice, "Claim once?", now+day, now)
	placeBet(alice, id, true, 100, now)
	placeBet(bob, id, false, 300, now)
	resolveMarket(alice, id, true, now+day+1)
	if p := claimWinnings(alice, id); p != 400 {
		t.Fatalf("first claim = %d, want 400", p)
	}
	mustPanic(t, func() { claimWinnings(alice, id) })
}

func TestClaimBeforeResolveFails(t *testing.T) {
	id := createMarket(alice, "Too soon to claim?", now+day, now)
	placeBet(alice, id, true, 100, now)
	mustPanic(t, func() { claimWinnings(alice, id) })
}

// TestRefundNoWinnersExact covers the locked-funds fix: only YES bets
// exist (alice 100, carol 50), the market resolves NO, so there are no
// winners. Each loser refunds their exact stake; Claim panics for everyone;
// a non-bettor cannot refund.
func TestRefundNoWinnersExact(t *testing.T) {
	id := createMarket(alice, "Nobody bet NO?", now+day, now)
	placeBet(alice, id, true, 100, now)
	placeBet(carol, id, true, 50, now)
	resolveMarket(alice, id, false, now+day+1)
	if r := refundBet(alice, id); r != 100 {
		t.Fatalf("alice refund = %d, want exactly 100", r)
	}
	if r := refundBet(carol, id); r != 50 {
		t.Fatalf("carol refund = %d, want exactly 50", r)
	}
	mustPanic(t, func() { claimWinnings(alice, id) })
	mustPanic(t, func() { claimWinnings(carol, id) })
	mustPanic(t, func() { refundBet(bob, id) })
}

func TestRefundWhenWinnersExistFails(t *testing.T) {
	id := createMarket(alice, "Winners take all?", now+day, now)
	placeBet(alice, id, true, 100, now)
	placeBet(bob, id, false, 300, now)
	resolveMarket(alice, id, true, now+day+1)
	mustPanic(t, func() { refundBet(bob, id) })
	mustPanic(t, func() { refundBet(alice, id) })
}

func TestRefundBeforeResolveFails(t *testing.T) {
	id := createMarket(alice, "Too soon to refund?", now+day, now)
	placeBet(alice, id, true, 100, now)
	mustPanic(t, func() { refundBet(alice, id) })
}

func TestDoubleRefundFails(t *testing.T) {
	id := createMarket(alice, "Refund once?", now+day, now)
	placeBet(alice, id, true, 100, now)
	resolveMarket(alice, id, false, now+day+1)
	if r := refundBet(alice, id); r != 100 {
		t.Fatalf("first refund = %d, want 100", r)
	}
	mustPanic(t, func() { refundBet(alice, id) })
}

func TestRender(t *testing.T) {
	id := createMarket(alice, "Render shows me?", now+day, now)
	placeBet(alice, id, true, 100, now)
	placeBet(bob, id, false, 300, now)
	out := Render("")
	if !strings.Contains(out, "Render shows me?") {
		t.Fatal("Render output is missing the market question")
	}
	if !strings.Contains(out, "#"+strconv.Itoa(id)) {
		t.Fatal("Render output is missing the market id")
	}
	if !strings.Contains(out, "0.000100 GNOT") {
		t.Fatalf("Render output is missing the YES pool amount; got:\n%s", out)
	}
	if !strings.Contains(out, "0.000300 GNOT") {
		t.Fatalf("Render output is missing the NO pool amount; got:\n%s", out)
	}
	if !strings.Contains(out, "open") {
		t.Fatal("Render output should mark the market open")
	}
}
