package gnometavern

import (
	"strings"
	"testing"

	"gno.land/p/g17dvvky49vjqj6a4cjhwcvzctteqjm9stee000h/tavernlogic"
)

// The two test players are the project's real testnet accounts; only
// their public addresses are used here.
var (
	alice = address("g17dvvky49vjqj6a4cjhwcvzctteqjm9stee000h")
	bob   = address("g15g63hzg36z8n5qjnzq6kxg4as5kms3vgqy42gw")
)

func resetState() {
	gnomes = map[address]*tavernlogic.Gnome{}
	joinOrder = nil
	wall = nil
	totalServes = 0
}

// NOTE: testing.SetRealm must be called directly in the test function
// body — it mutates the test frame's realm in place, so wrapping it in a
// helper function would mutate the helper's frame instead and lose it.

// mustPanic asserts that f aborts. Realm functions are crossing
// functions, so their panics surface as aborts, which plain recover()
// cannot catch — the revive() builtin is the test-mode tool for this
// (same mechanism as p/nt/uassert's AbortsWithMessage).
func mustPanic(t *testing.T, what string, f func()) {
	t.Helper()
	if r := revive(f); r == nil {
		t.Fatalf("expected abort: %s", what)
	}
}

func TestRegister(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(alice))
	msg := Register(cross(cur), "Bram")
	if !strings.Contains(msg, "Bram") {
		t.Fatalf("welcome message does not name the gnome: %q", msg)
	}
	if GnomeCount() != 1 {
		t.Fatalf("GnomeCount = %d, want 1", GnomeCount())
	}
	if p := Profile(alice); !strings.Contains(p, "Bram") || !strings.Contains(p, "level 1") {
		t.Fatalf("profile wrong: %q", p)
	}
	// One gnome per address.
	mustPanic(t, "second gnome for same address", func() {
		Register(cross(cur), "Other")
	})
	// Invalid names.
	for _, bad := range []string{"ab", "SeventeenCharsLong", "Bad!Name", "with|pipe", ""} {
		testing.SetRealm(testing.NewUserRealm(bob))
		mustPanic(t, "invalid name "+bad, func() {
			Register(cross(cur), bad)
		})
	}
	// Name uniqueness across addresses.
	testing.SetRealm(testing.NewUserRealm(bob))
	mustPanic(t, "name already taken", func() {
		Register(cross(cur), "Bram")
	})
	Register(cross(cur), "Zed")
	if GnomeCount() != 2 {
		t.Fatalf("GnomeCount = %d, want 2", GnomeCount())
	}
	if p := Profile(bob); !strings.Contains(p, "No gnome") && !strings.Contains(p, "Zed") {
		t.Fatalf("bob profile wrong: %q", p)
	}
	if p := Profile(address("g1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq2rq73q")); !strings.Contains(p, "No gnome") {
		t.Fatalf("unknown profile wrong: %q", p)
	}
}

func TestServeFlow(cur realm, t *testing.T) {
	resetState()
	// Unregistered callers cannot serve.
	testing.SetRealm(testing.NewUserRealm(bob))
	mustPanic(t, "serve while unregistered", func() {
		Serve(cross(cur), 0)
	})
	testing.SetRealm(testing.NewUserRealm(alice))
	Register(cross(cur), "Bram")
	out := Serve(cross(cur), 0)
	if !strings.Contains(out, "Barley Soup") {
		t.Fatalf("serve output wrong: %q", out)
	}
	if gnomes[alice].Coins != 3 || TotalServes() != 1 {
		t.Fatalf("after one serve: coins=%d totalServes=%d", gnomes[alice].Coins, TotalServes())
	}
	// Level gate through the realm: Honeyed Ham needs level 2.
	mustPanic(t, "serve above level", func() {
		Serve(cross(cur), 2)
	})
	// Work up to level 2 with ales (3 XP each, 40 XP needed).
	for gnomes[alice].Level() < 2 {
		Serve(cross(cur), 1)
	}
	Serve(cross(cur), 2) // must not panic now
	if gnomes[alice].ItemToday[2] != 1 {
		t.Fatalf("ham serve not recorded")
	}
	// Unknown item.
	mustPanic(t, "serve unknown item", func() {
		Serve(cross(cur), 42)
	})
}

func TestQuestClaimViaRealm(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(alice))
	Register(cross(cur), "Questor")
	gnomes[alice].XP = 1000 // quest flow under test, not level gating

	day := currentDay()
	board := tavernlogic.QuestsForDay(day)
	// Work the cheapest quest on today's board.
	slot := 0
	for i, q := range board {
		if q.Count < board[slot].Count {
			slot = i
		}
	}
	q := board[slot]
	item := 0
	if q.Kind == tavernlogic.QuestItemServes {
		item = q.ItemID
	}
	// Claiming before doing the work must panic.
	mustPanic(t, "claim before work", func() {
		ClaimQuest(cross(cur), slot)
	})
	for gnomes[alice].ProgressFor(day, q) < q.Count {
		Serve(cross(cur), item)
	}
	coinsBefore := gnomes[alice].Coins
	out := ClaimQuest(cross(cur), slot)
	if !strings.Contains(out, q.Title) {
		t.Fatalf("claim output wrong: %q", out)
	}
	if gnomes[alice].Coins != coinsBefore+q.CoinReward {
		t.Fatalf("quest coins not paid: %d -> %d, reward %d",
			coinsBefore, gnomes[alice].Coins, q.CoinReward)
	}
	// Claiming twice must panic.
	mustPanic(t, "double claim", func() {
		ClaimQuest(cross(cur), slot)
	})
}

func TestFeastViaRealm(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(alice))
	Register(cross(cur), "Feaster")
	mustPanic(t, "feast with no coins", func() {
		Feast(cross(cur))
	})
	for i := 0; i < 10; i++ { // 10 ales = 50 coins
		Serve(cross(cur), 1)
	}
	xpBefore := gnomes[alice].XP
	out := Feast(cross(cur))
	if !strings.Contains(out, "feasts") {
		t.Fatalf("feast output wrong: %q", out)
	}
	if gnomes[alice].Coins != 0 || gnomes[alice].XP != xpBefore+tavernlogic.FeastXP {
		t.Fatalf("feast accounting wrong: coins=%d xp=%d", gnomes[alice].Coins, gnomes[alice].XP)
	}
	mustPanic(t, "second feast same day", func() {
		Feast(cross(cur))
	})
}

func TestWallAndRender(cur realm, t *testing.T) {
	resetState()
	// Notes need a registered gnome.
	testing.SetRealm(testing.NewUserRealm(bob))
	mustPanic(t, "note while unregistered", func() {
		PostNote(cross(cur), "hello?")
	})
	testing.SetRealm(testing.NewUserRealm(alice))
	Register(cross(cur), "Bram")
	PostNote(cross(cur), "First round is on me!")
	testing.SetRealm(testing.NewUserRealm(bob))
	Register(cross(cur), "Zed")
	PostNote(cross(cur), "Save me a seat by the fire.")

	home := Render("")
	for _, want := range []string{"The Gnome Tavern", "Bram", "First round is on me!", "Today's quest board", "Leaderboard"} {
		if !strings.Contains(home, want) {
			t.Fatalf("home render missing %q", want)
		}
	}
	if m := Render("menu"); !strings.Contains(m, "Dragonfire Stew") {
		t.Fatalf("menu render incomplete")
	}
	if q := Render("quests"); !strings.Contains(q, "Quest Board") {
		t.Fatalf("quests render wrong")
	}
	if lb := Render("leaderboard"); !strings.Contains(lb, "Bram") || !strings.Contains(lb, "Zed") {
		t.Fatalf("leaderboard render missing gnomes")
	}
	if w := Render("wall"); !strings.Contains(w, "Save me a seat by the fire.") {
		t.Fatalf("wall render missing note")
	}
	if card := Render("gnome/" + alice.String()); !strings.Contains(card, "Bram") {
		t.Fatalf("gnome card wrong: %q", card)
	}
	if card := Render("gnome/g1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq2rq73q"); !strings.Contains(card, "No gnome") {
		t.Fatalf("unknown gnome card wrong: %q", card)
	}
	if u := Render("cellar"); !strings.Contains(u, "Unknown page") {
		t.Fatalf("unknown page handling wrong: %q", u)
	}
	// Multi-line notes are refused.
	testing.SetRealm(testing.NewUserRealm(alice))
	mustPanic(t, "multi-line note", func() {
		PostNote(cross(cur), "line one\nline two")
	})
}
