package gnometavern

import (
	"chain"
	"strings"
	"testing"
	"time"
)

// Test addresses borrowed from the gno repository's own example tests
// (deterministic, valid bech32 — no private keys behind them).
var (
	keeperAddr = address("g1wdjkuer9wgc47h6lta047h6lta047h6l56jtjc")
	aliceAddr  = address("g1wfjkx6tsd9jkuap3ta047h6lta047h6lkk20gv")
	bobAddr    = address("g1v9kxjcm9ta047h6lta047h6lta047h6lzd40gh")
)

// reset returns the tavern to its opening state with a known keeper.
func reset() {
	keeper = keeperAddr
	seed()
}

// IMPORTANT testing notes (learned the hard way on gno v1.8):
//   - testing.SetRealm / testing.SetOriginSend must be called INLINE in
//     the test body; calling them from a helper function does not stick.
//   - The origin send must be set BEFORE the realm: SetOriginSend
//     round-trips the context without CurrentRealm and would clobber it.
//   - Realm panics cross a crossing boundary where plain recover() cannot
//     catch them; the revive() builtin exists for exactly this.

// --- tiny assertion helpers (kept local so the tests need no downloads) ---

func eqI64(t *testing.T, want, got int64, what string) {
	t.Helper()
	if want != got {
		t.Fatalf("%s: want %d, got %d", what, want, got)
	}
}

func eqStr(t *testing.T, want, got string, what string) {
	t.Helper()
	if want != got {
		t.Fatalf("%s: want %q, got %q", what, want, got)
	}
}

func isTrue(t *testing.T, cond bool, what string) {
	t.Helper()
	if !cond {
		t.Fatalf("expected true: %s", what)
	}
}

func contains(t *testing.T, s, sub string) {
	t.Helper()
	if !strings.Contains(s, sub) {
		t.Fatalf("expected %q to contain %q", s, sub)
	}
}

// abortsWith runs fn and requires it to panic with a message containing sub.
func abortsWith(t *testing.T, sub string, fn func()) {
	t.Helper()
	r := revive(fn)
	if r == nil {
		t.Fatalf("expected panic containing %q, but the call succeeded", sub)
	}
	msg := ""
	switch v := r.(type) {
	case string:
		msg = v
	case error:
		msg = v.Error()
	default:
		msg = "unprintable panic"
	}
	if !strings.Contains(msg, sub) {
		t.Fatalf("panic %q does not contain %q", msg, sub)
	}
}

// --- tests ---

func TestCheckIn(cur realm, t *testing.T) {
	reset()

	testing.SetOriginSend(chain.Coins{})
	testing.SetRealm(testing.NewUserRealm(aliceAddr))
	msg := CheckIn(cross(cur), "AliceTheGnome")
	contains(t, msg, "AliceTheGnome")

	_, visits, _, _, _, _, found := GetPatron(aliceAddr)
	isTrue(t, found, "patron exists after check-in")
	eqI64(t, 1, visits, "visits after first check-in")

	// Second visit: counter grows, original nickname is kept.
	testing.SetOriginSend(chain.Coins{})
	testing.SetRealm(testing.NewUserRealm(aliceAddr))
	CheckIn(cross(cur), "SomeOtherName")
	nick, visits, _, _, _, _, _ := GetPatron(aliceAddr)
	eqStr(t, "AliceTheGnome", nick, "nickname locked after first check-in")
	eqI64(t, 2, visits, "visits after second check-in")

	v, _, _, pc := GetStats()
	eqI64(t, 2, v, "total visits")
	eqI64(t, 1, pc, "patron count")
}

func TestOrderDrink(cur realm, t *testing.T) {
	reset()

	// Exact payment for a Gnome Ale (item 0, price 50000, stock 40).
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: 50000}})
	testing.SetRealm(testing.NewUserRealm(aliceAddr))
	OrderDrink(cross(cur), 0)
	eqI64(t, 39, menu[0].Stock, "stock after one order")
	_, _, drinks, tips, _, _, _ := GetPatron(aliceAddr)
	eqI64(t, 1, drinks, "drinks after one order")
	eqI64(t, 0, tips, "no tip on exact payment")
	_, d, tillAmt, _ := GetStats()
	eqI64(t, 1, d, "total drinks")
	eqI64(t, 50000, tillAmt, "till after one order")

	// Overpayment is recorded as a tip.
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: 60000}})
	testing.SetRealm(testing.NewUserRealm(aliceAddr))
	OrderDrink(cross(cur), 0)
	_, _, _, tips, _, _, _ = GetPatron(aliceAddr)
	eqI64(t, 10000, tips, "overpayment recorded as tip")

	// Underpayment aborts and changes nothing.
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: 49999}})
	testing.SetRealm(testing.NewUserRealm(bobAddr))
	abortsWith(t, "not enough ugnot", func() {
		OrderDrink(cross(cur), 0)
	})
	eqI64(t, 38, menu[0].Stock, "stock unchanged after failed order")

	// Unknown item aborts.
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: 999999}})
	testing.SetRealm(testing.NewUserRealm(bobAddr))
	abortsWith(t, "no such drink", func() {
		OrderDrink(cross(cur), 99)
	})

	// Sold-out keg aborts.
	menu[0].Stock = 0
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: 50000}})
	testing.SetRealm(testing.NewUserRealm(bobAddr))
	abortsWith(t, "sold out", func() {
		OrderDrink(cross(cur), 0)
	})
}

func TestTip(cur realm, t *testing.T) {
	reset()

	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: 123456}})
	testing.SetRealm(testing.NewUserRealm(bobAddr))
	Tip(cross(cur))
	_, _, _, tips, _, score, _ := GetPatron(bobAddr)
	eqI64(t, 123456, tips, "tip recorded")
	eqI64(t, 1, score, "score: 123456/100000 = 1 pt")
	_, _, tillAmt, _ := GetStats()
	eqI64(t, 123456, tillAmt, "till after tip")

	// A tip without coins aborts.
	testing.SetOriginSend(chain.Coins{})
	testing.SetRealm(testing.NewUserRealm(bobAddr))
	abortsWith(t, "must send some ugnot", func() {
		Tip(cross(cur))
	})
}

func TestCompleteQuest(cur realm, t *testing.T) {
	reset()

	testing.SetOriginSend(chain.Coins{})
	testing.SetRealm(testing.NewUserRealm(aliceAddr))
	CompleteQuest(cross(cur), 2) // "Generous Soul", 10 pts
	_, _, _, _, qp, _, _ := GetPatron(aliceAddr)
	eqI64(t, 10, qp, "quest points after first claim")

	// Same quest again on the same day aborts.
	abortsWith(t, "already completed today", func() {
		CompleteQuest(cross(cur), 2)
	})

	// A different quest the same day is fine.
	CompleteQuest(cross(cur), 0)
	_, _, _, _, qp, _, _ = GetPatron(aliceAddr)
	eqI64(t, 15, qp, "quest points after second quest")

	// Next day (chain time +25h) the first quest can be claimed again.
	ctx := testing.GetContext()
	ctx.Time = ctx.Time.Add(25 * time.Hour)
	testing.SetContext(ctx)
	testing.SetOriginSend(chain.Coins{})
	testing.SetRealm(testing.NewUserRealm(aliceAddr))
	CompleteQuest(cross(cur), 2)
	_, _, _, _, qp, _, _ = GetPatron(aliceAddr)
	eqI64(t, 25, qp, "quest points after next-day claim")

	// Unknown quest aborts.
	abortsWith(t, "no such quest", func() {
		CompleteQuest(cross(cur), 42)
	})
}

func TestKeeperOnly(cur realm, t *testing.T) {
	reset()

	// A random patron cannot manage the menu or the board.
	testing.SetOriginSend(chain.Coins{})
	testing.SetRealm(testing.NewUserRealm(aliceAddr))
	abortsWith(t, "only the tavern keeper", func() {
		AddMenuItem(cross(cur), "Sneaky Brew", 1000, 5)
	})
	abortsWith(t, "only the tavern keeper", func() {
		Restock(cross(cur), 0, 5)
	})
	abortsWith(t, "only the tavern keeper", func() {
		AddQuest(cross(cur), "Sneaky Quest", 5)
	})

	// The keeper can.
	testing.SetOriginSend(chain.Coins{})
	testing.SetRealm(testing.NewUserRealm(keeperAddr))
	AddMenuItem(cross(cur), "Golden Mead Deluxe", 300000, 7)
	eqI64(t, 6, int64(len(menu)), "menu length after keeper add")
	Restock(cross(cur), 0, 10)
	eqI64(t, 50, menu[0].Stock, "stock after restock")
	AddQuest(cross(cur), "Sing a shanty on the bar", 15)
	eqI64(t, 5, int64(len(quests)), "quest count after keeper add")
}

func TestRender(cur realm, t *testing.T) {
	reset()

	home := Render("")
	contains(t, home, "The Gnome Tavern")
	contains(t, home, "Gnome Ale")
	contains(t, home, "Quest board")
	contains(t, home, "No patrons yet")

	unknown := Render("patron/" + bobAddr.String())
	contains(t, unknown, "has never visited")

	testing.SetOriginSend(chain.Coins{})
	testing.SetRealm(testing.NewUserRealm(aliceAddr))
	CheckIn(cross(cur), "AliceTheGnome")
	card := Render("patron/" + aliceAddr.String())
	contains(t, card, "AliceTheGnome")
	contains(t, card, "Check-ins | 1")

	home = Render("")
	contains(t, home, "AliceTheGnome")

	bad := Render("cellar")
	contains(t, bad, "No such page")
}

func TestHallOfFameRanking(cur realm, t *testing.T) {
	reset()

	// Alice: 1 visit (1 pt). Bob: 1 visit + big tip (1 + 3 pts).
	testing.SetOriginSend(chain.Coins{})
	testing.SetRealm(testing.NewUserRealm(aliceAddr))
	CheckIn(cross(cur), "Alice")
	testing.SetOriginSend(chain.Coins{})
	testing.SetRealm(testing.NewUserRealm(bobAddr))
	CheckIn(cross(cur), "Bob")
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: 300000}})
	testing.SetRealm(testing.NewUserRealm(bobAddr))
	Tip(cross(cur))

	home := Render("")
	idxBob := strings.Index(home, "[Bob]")
	idxAlice := strings.Index(home, "[Alice]")
	isTrue(t, idxBob >= 0 && idxAlice >= 0, "both patrons listed in Hall of Fame")
	isTrue(t, idxBob < idxAlice, "higher score must rank first")
}
