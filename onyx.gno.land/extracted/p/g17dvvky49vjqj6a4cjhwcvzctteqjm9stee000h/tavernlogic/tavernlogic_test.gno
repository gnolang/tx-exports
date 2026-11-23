package tavernlogic

import "testing"

func TestLevelForXP(t *testing.T) {
	cases := []struct{ xp, want int }{
		{0, 1}, {1, 1}, {XPPerLevel - 1, 1}, {XPPerLevel, 2},
		{2 * XPPerLevel, 3}, {4 * XPPerLevel, 5}, {-10, 1},
	}
	for _, c := range cases {
		if got := LevelForXP(c.xp); got != c.want {
			t.Fatalf("LevelForXP(%d) = %d, want %d", c.xp, got, c.want)
		}
	}
	if XPForLevel(1) != 0 || XPForLevel(2) != XPPerLevel || XPForLevel(5) != 4*XPPerLevel {
		t.Fatalf("XPForLevel thresholds are wrong")
	}
}

func TestMenuLadder(t *testing.T) {
	menu := Menu()
	if len(menu) != 6 {
		t.Fatalf("menu has %d items, want 6", len(menu))
	}
	prevLevel, prevCoins := 0, 0
	for i, item := range menu {
		if item.ID != i {
			t.Fatalf("menu item %d has ID %d", i, item.ID)
		}
		if item.MinLevel < prevLevel {
			t.Fatalf("menu levels are not a ladder at %q", item.Name)
		}
		if item.Coins <= prevCoins {
			t.Fatalf("menu payouts are not increasing at %q", item.Name)
		}
		// Every menu item must be unlockable: its MinLevel must be
		// reachable and consistent with the quest pool referencing it.
		if LevelForXP(XPForLevel(item.MinLevel)) != item.MinLevel {
			t.Fatalf("MinLevel %d of %q is not reachable", item.MinLevel, item.Name)
		}
		prevLevel, prevCoins = item.MinLevel, item.Coins
	}
	if _, ok := MenuItemByID(-1); ok {
		t.Fatalf("MenuItemByID(-1) should not exist")
	}
	if _, ok := MenuItemByID(len(menu)); ok {
		t.Fatalf("MenuItemByID(len) should not exist")
	}
}

func TestQuestsDeterministic(t *testing.T) {
	for _, day := range []int64{0, 1, 2, 7, 42, 1000, 987654} {
		a := QuestsForDay(day)
		b := QuestsForDay(day)
		if a != b {
			t.Fatalf("QuestsForDay(%d) is not deterministic", day)
		}
		seen := map[int]bool{}
		for _, q := range a {
			if seen[q.ID] {
				t.Fatalf("day %d board repeats quest %d", day, q.ID)
			}
			seen[q.ID] = true
			if q.Count <= 0 || q.Count > MaxServesPerDay {
				t.Fatalf("quest %q count %d cannot fit in a day", q.Title, q.Count)
			}
			if q.Kind == QuestItemServes {
				if _, ok := MenuItemByID(q.ItemID); !ok {
					t.Fatalf("quest %q references missing item %d", q.Title, q.ItemID)
				}
			}
		}
	}
	// Different days should (usually) show different boards.
	same := 0
	for day := int64(0); day < 20; day++ {
		if QuestsForDay(day) == QuestsForDay(day+1) {
			same++
		}
	}
	if same > 5 {
		t.Fatalf("quest board barely rotates: %d/20 consecutive days identical", same)
	}
}

func TestServeEarnsAndLevels(t *testing.T) {
	g := NewGnome("Bram", 0)
	coins, xp, err := g.Serve(0, 0)
	if err != nil {
		t.Fatalf("serve soup: %v", err)
	}
	if coins != 3 || xp != 2 || g.Coins != 3 || g.XP != 2 {
		t.Fatalf("after soup: earned (%d,%d), gnome (%d coins, %d xp)", coins, xp, g.Coins, g.XP)
	}
	if g.ServesToday != 1 || g.TotalServes != 1 || g.ItemToday[0] != 1 {
		t.Fatalf("counters wrong after one serve: %+v", g)
	}
	// Level gate: a level-1 gnome cannot serve Honeyed Ham (min level 2).
	if _, _, err := g.Serve(0, 2); err == nil {
		t.Fatalf("level-1 gnome served a level-2 item")
	}
	// Unknown item.
	if _, _, err := g.Serve(0, 99); err == nil {
		t.Fatalf("served a nonexistent item")
	}
	// Earn enough XP to reach level 2, then the ham unlocks.
	for g.Level() < 2 {
		if _, _, err := g.Serve(0, 1); err != nil {
			t.Fatalf("serve ale: %v", err)
		}
	}
	if _, _, err := g.Serve(0, 2); err != nil {
		t.Fatalf("level-2 gnome could not serve ham: %v", err)
	}
}

func TestServeDailyCapAndRollover(t *testing.T) {
	g := NewGnome("Cap", 0)
	for i := 0; i < MaxServesPerDay; i++ {
		if _, _, err := g.Serve(0, 0); err != nil {
			t.Fatalf("serve %d of the day failed: %v", i, err)
		}
	}
	if _, _, err := g.Serve(0, 0); err == nil {
		t.Fatalf("served beyond the daily cap")
	}
	// Next day: counters reset, serving works again, totals keep counting.
	coinsBefore := g.Coins
	if _, _, err := g.Serve(1, 0); err != nil {
		t.Fatalf("serve on day 1 failed: %v", err)
	}
	if g.ServesToday != 1 || g.TotalServes != MaxServesPerDay+1 {
		t.Fatalf("rollover counters wrong: today=%d total=%d", g.ServesToday, g.TotalServes)
	}
	if g.Coins != coinsBefore+3 {
		t.Fatalf("coins did not carry over the rollover")
	}
	if got := g.ProgressFor(0, Quest{Kind: QuestTotalServes}); got != 0 {
		t.Fatalf("progress for a past day = %d, want 0", got)
	}
}

func TestClaimQuest(t *testing.T) {
	g := NewGnome("Questy", 0)
	g.XP = 1000 // claim logic is under test here, not level gating
	board := QuestsForDay(0)
	// Find the cheapest total-serves quest on today's board and work it.
	slot := -1
	for i, q := range board {
		if q.Kind == QuestTotalServes && (slot == -1 || q.Count < board[slot].Count) {
			slot = i
		}
	}
	if slot == -1 {
		// Fall back: work whichever quest is in slot 0 via its item.
		slot = 0
		q := board[0]
		for g.ProgressFor(0, q) < q.Count {
			if _, _, err := g.Serve(0, q.ItemID); err != nil {
				t.Fatalf("working quest: %v", err)
			}
		}
	} else {
		for g.ProgressFor(0, board[slot]) < board[slot].Count {
			if _, _, err := g.Serve(0, 0); err != nil {
				t.Fatalf("working quest: %v", err)
			}
		}
	}
	// Claiming an unfinished quest must fail: pick a slot we did not finish,
	// if any, and confirm; otherwise skip that half of the check.
	for i, q := range board {
		if i != slot && g.ProgressFor(0, q) < q.Count {
			if _, err := g.ClaimQuest(0, i); err == nil {
				t.Fatalf("claimed unfinished quest %q", q.Title)
			}
			break
		}
	}
	coinsBefore, xpBefore := g.Coins, g.XP
	q, err := g.ClaimQuest(0, slot)
	if err != nil {
		t.Fatalf("claim finished quest: %v", err)
	}
	if g.Coins != coinsBefore+q.CoinReward || g.XP != xpBefore+q.XPReward {
		t.Fatalf("quest payout wrong: got +%d coins +%d xp, want +%d +%d",
			g.Coins-coinsBefore, g.XP-xpBefore, q.CoinReward, q.XPReward)
	}
	// Double claim must fail.
	if _, err := g.ClaimQuest(0, slot); err == nil {
		t.Fatalf("claimed the same quest twice in one day")
	}
	// Bad slot must fail.
	if _, err := g.ClaimQuest(0, 3); err == nil {
		t.Fatalf("claimed slot 3")
	}
	// Tomorrow the same slot is a fresh claim (board may differ, but the
	// claim flag must have reset): serve the new board's slot-0 quest and
	// claim it.
	board1 := QuestsForDay(1)
	q1 := board1[0]
	item := 0
	if q1.Kind == QuestItemServes {
		item = q1.ItemID
	}
	for g.ProgressFor(1, q1) < q1.Count {
		if _, _, err := g.Serve(1, item); err != nil {
			t.Fatalf("day-1 quest work: %v", err)
		}
	}
	if _, err := g.ClaimQuest(1, 0); err != nil {
		t.Fatalf("claim on day 1 failed: %v", err)
	}
}

func TestFeast(t *testing.T) {
	g := NewGnome("Hungry", 0)
	if err := g.Feast(0); err == nil {
		t.Fatalf("feasted with no coins")
	}
	for i := 0; i < 10; i++ { // 10 ales = 50 coins
		if _, _, err := g.Serve(0, 1); err != nil {
			t.Fatalf("serve ale: %v", err)
		}
	}
	xpBefore := g.XP
	if err := g.Feast(0); err != nil {
		t.Fatalf("feast: %v", err)
	}
	if g.Coins != 0 || g.XP != xpBefore+FeastXP {
		t.Fatalf("after feast: coins=%d xp=%d, want 0 and %d", g.Coins, g.XP, xpBefore+FeastXP)
	}
	if err := g.Feast(0); err == nil {
		t.Fatalf("feasted twice in one day")
	}
	if err := g.Feast(1); err == nil {
		t.Fatalf("feasted on day 1 with no coins")
	}
}
