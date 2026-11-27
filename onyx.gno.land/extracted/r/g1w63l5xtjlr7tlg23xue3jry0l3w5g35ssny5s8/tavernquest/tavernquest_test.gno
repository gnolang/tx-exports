// Tests for Tavern Quest. Internal game-logic functions are tested
// directly (they take the caller address explicitly); the crossing
// wrappers are tested through the chain with testing.SetOriginCaller,
// exactly as a wallet transaction would reach them.
package tavernquest

import "testing"

var (
	alice = address("g1w63l5xtjlr7tlg23xue3jry0l3w5g35ssny5s8")
	bob   = address("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5")
	carol = address("g1skl80cuz8zq3lul9pgz5pc35l2pfzgxgfpsqkx")
	dave  = address("g1x582angdzrqadgv4382j6y7ju6fj5wll6yuuq4")
)

func resetState() {
	adventurers = nil
	quests = nil
	questLog = nil
	totalQuests = 0
	totalTipped = 0
	totalBrewed = 0
	totalDrunk = 0
}

func mustMint(t *testing.T, caller address, name, class string) {
	t.Helper()
	if err := mintAdventurer(caller, name, class); err != nil {
		t.Fatalf("mintAdventurer(%s): unexpected error: %s", name, err)
	}
}

func TestMintAdventurer(t *testing.T) {
	resetState()
	mustMint(t, alice, "Mira", ClassBrewmaster)
	a, ok := GetAdventurer(alice)
	if !ok {
		t.Fatalf("adventurer not found after mint")
	}
	if a.Name != "Mira" || a.Class != ClassBrewmaster {
		t.Fatalf("bad adventurer: %+v", a)
	}
	if a.Gold != startGold || a.HP != startHP || a.Level != 1 || a.XP != 0 {
		t.Fatalf("bad starting stats: %+v", a)
	}
	if a.Healing != 1 {
		t.Fatalf("Brewmaster should start with 1 Healing Draught, got %d", a.Healing)
	}
	if a.ActiveQuest != -1 {
		t.Fatalf("new adventurer should have no active quest")
	}
	// One adventurer per address.
	if err := mintAdventurer(alice, "Second", ClassRanger); err == nil {
		t.Fatalf("second mint for same address should fail")
	}
	// Name and class validation.
	if err := mintAdventurer(bob, "Al", ClassRanger); err == nil {
		t.Fatalf("2-letter name should fail")
	}
	if err := mintAdventurer(bob, "Bob", "Wizard"); err == nil {
		t.Fatalf("unknown class should fail")
	}
	// Class starting bonuses.
	mustMint(t, bob, "Bram", ClassRanger)
	if b, _ := GetAdventurer(bob); b.Gold != startGold+20 {
		t.Fatalf("Ranger should start with %d gold, got %d", startGold+20, b.Gold)
	}
	mustMint(t, carol, "Cleo", ClassBard)
	if c, _ := GetAdventurer(carol); c.Lucky != 1 {
		t.Fatalf("Bard should start with 1 Ember Mead, got %d", c.Lucky)
	}
	mustMint(t, dave, "Dax", ClassRogue)
	if d, _ := GetAdventurer(dave); d.Stone != 1 {
		t.Fatalf("Rogue should start with 1 Stoneskin Stout, got %d", d.Stone)
	}
}

func TestMintViaCrossing(cur realm, t *testing.T) {
	resetState()
	testing.SetOriginCaller(alice)
	MintAdventurer(cross(cur), "Mira", "Ranger")
	a, ok := GetAdventurer(alice)
	if !ok || a.Name != "Mira" {
		t.Fatalf("crossing mint failed: %+v %v", a, ok)
	}
}

func TestQuestFlow(t *testing.T) {
	resetState()
	mustMint(t, alice, "Mira", ClassRanger) // 70 gold
	if err := acceptQuest(alice, 1); err != nil {
		t.Fatalf("accept quest 1: %s", err)
	}
	if err := acceptQuest(alice, 2); err == nil {
		t.Fatalf("second active quest should fail")
	}
	tale, err := completeQuest(alice)
	if err != nil {
		t.Fatalf("complete quest 1: %s", err)
	}
	if tale == "" {
		t.Fatalf("completeQuest should return a tale")
	}
	a, _ := GetAdventurer(alice)
	if a.Gold != 70+25 {
		t.Fatalf("gold after quest 1: want %d, got %d", 95, a.Gold)
	}
	if a.XP != 30 || a.HP != 90 || a.QuestsDone != 1 || a.ActiveQuest != -1 {
		t.Fatalf("bad state after quest 1: %+v", a)
	}
	if a.EmberPepper != 1 {
		t.Fatalf("quest 1 should grant Ember Pepper, got %d", a.EmberPepper)
	}
	if Stats().QuestsDone != 1 {
		t.Fatalf("tavern stats quests done: want 1, got %d", Stats().QuestsDone)
	}
	if len(QuestLog()) != 2 { // mint tale + completion tale
		t.Fatalf("quest log should have 2 lines, got %d", len(QuestLog()))
	}
}

func TestQuestGuards(t *testing.T) {
	resetState()
	if err := acceptQuest(alice, 1); err == nil {
		t.Fatalf("accept without adventurer should fail")
	}
	mustMint(t, alice, "Mira", ClassRanger)
	if err := acceptQuest(alice, 6); err == nil {
		t.Fatalf("level 1 adventurer should not take the level 4 quest")
	}
	if err := acceptQuest(alice, 99); err == nil {
		t.Fatalf("unknown quest id should fail")
	}
	if _, err := completeQuest(alice); err == nil {
		t.Fatalf("complete with no active quest should fail")
	}
	if err := abandonQuest(alice); err == nil {
		t.Fatalf("abandon with no active quest should fail")
	}
}

func TestAbandonQuest(t *testing.T) {
	resetState()
	mustMint(t, alice, "Mira", ClassRanger)
	if err := acceptQuest(alice, 1); err != nil {
		t.Fatalf("accept: %s", err)
	}
	if err := abandonQuest(alice); err != nil {
		t.Fatalf("abandon: %s", err)
	}
	a, _ := GetAdventurer(alice)
	if a.ActiveQuest != -1 {
		t.Fatalf("abandoned quest should clear ActiveQuest")
	}
}

func TestLevelUp(t *testing.T) {
	resetState()
	mustMint(t, alice, "Mira", ClassRanger)
	i := findAdventurer(alice)
	adventurers[i].XP = 95
	adventurers[i].HP = 40
	if err := acceptQuest(alice, 1); err != nil {
		t.Fatalf("accept: %s", err)
	}
	if _, err := completeQuest(alice); err != nil {
		t.Fatalf("complete: %s", err)
	}
	a, _ := GetAdventurer(alice)
	if a.Level != 2 {
		t.Fatalf("125 XP should be level 2, got %d", a.Level)
	}
	if a.MaxHP != 110 || a.HP != 110 {
		t.Fatalf("level up should raise MaxHP to 110 and fully heal, got HP %d/%d", a.HP, a.MaxHP)
	}
}

func TestBrewAndDrink(t *testing.T) {
	resetState()
	mustMint(t, alice, "Mira", ClassBrewmaster)
	i := findAdventurer(alice)
	adventurers[i].EmberPepper = 1
	adventurers[i].Honey = 1
	adventurers[i].Moonpetal = 1
	adventurers[i].Frogspawn = 1
	goldBefore := adventurers[i].Gold
	potion, err := brewPotion(alice, IngEmberPepper, IngHoney)
	if err != nil {
		t.Fatalf("brew Ember Mead: %s", err)
	}
	if potion != PotionLucky {
		t.Fatalf("Ember Pepper + Honey should brew %s, got %s", PotionLucky, potion)
	}
	a, _ := GetAdventurer(alice)
	if a.Lucky != 1 || a.Gold != goldBefore-brewCost {
		t.Fatalf("bad state after brew: %+v", a)
	}
	if _, err := brewPotion(alice, IngEmberPepper, IngMoonpetal); err == nil {
		t.Fatalf("unknown recipe should fail")
	}
	if _, err := brewPotion(alice, IngHoney, IngHoney); err == nil {
		t.Fatalf("same ingredient twice should fail")
	}
	potion, err = brewPotion(alice, IngMoonpetal, IngFrogspawn)
	if err != nil || potion != PotionHealing {
		t.Fatalf("Moonpetal + Frogspawn should brew %s, got %s (%s)", PotionHealing, potion, err)
	}
	// Drink the Healing Draught at low HP.
	j := findAdventurer(alice)
	adventurers[j].HP = 50
	if _, err := drinkPotion(alice, PotionHealing); err != nil {
		t.Fatalf("drink healing: %s", err)
	}
	a, _ = GetAdventurer(alice)
	// Brewmaster started with 1, brewed 1, drank 1: 1 left.
	if a.Healing != 1 || a.HP != 100 {
		t.Fatalf("after drinking: want Healing 1, HP 100; got %+v", a)
	}
	if _, err := drinkPotion(alice, "Snake Oil"); err == nil {
		t.Fatalf("unknown potion should fail")
	}
}

func TestLuckyDoublesGold(t *testing.T) {
	resetState()
	mustMint(t, alice, "Mira", ClassBard) // starts with 1 Ember Mead
	if _, err := drinkPotion(alice, PotionLucky); err != nil {
		t.Fatalf("drink lucky: %s", err)
	}
	if err := acceptQuest(alice, 1); err != nil {
		t.Fatalf("accept: %s", err)
	}
	if _, err := completeQuest(alice); err != nil {
		t.Fatalf("complete: %s", err)
	}
	a, _ := GetAdventurer(alice)
	// Ranger bonus does not apply (Bard): 50 + 25*2 = 100.
	if a.Gold != 100 {
		t.Fatalf("lucky quest should pay double gold: want 100, got %d", a.Gold)
	}
	if a.LuckyActive {
		t.Fatalf("lucky effect should be consumed by the quest")
	}
}

func TestStoneHalvesHPCost(t *testing.T) {
	resetState()
	mustMint(t, alice, "Mira", ClassRogue) // starts with 1 Stoneskin Stout
	if _, err := drinkPotion(alice, PotionStone); err != nil {
		t.Fatalf("drink stone: %s", err)
	}
	if err := acceptQuest(alice, 1); err != nil {
		t.Fatalf("accept: %s", err)
	}
	if _, err := completeQuest(alice); err != nil {
		t.Fatalf("complete: %s", err)
	}
	a, _ := GetAdventurer(alice)
	if a.HP != 95 { // 100 - (10/2)
		t.Fatalf("stoneskin quest should cost 5 HP: want HP 95, got %d", a.HP)
	}
}

func TestRest(t *testing.T) {
	resetState()
	mustMint(t, alice, "Mira", ClassRanger)
	i := findAdventurer(alice)
	adventurers[i].HP = 50
	if err := rest(alice); err != nil {
		t.Fatalf("rest: %s", err)
	}
	a, _ := GetAdventurer(alice)
	if a.HP != 80 || a.Gold != 70-restCost {
		t.Fatalf("after rest: want HP 80, gold %d; got %+v", 70-restCost, a)
	}
	// Rest caps at MaxHP.
	adventurers[findAdventurer(alice)].HP = 95
	if err := rest(alice); err != nil {
		t.Fatalf("rest at 95 HP: %s", err)
	}
	a, _ = GetAdventurer(alice)
	if a.HP != 100 {
		t.Fatalf("rest should cap at MaxHP 100, got %d", a.HP)
	}
	if err := rest(alice); err == nil {
		t.Fatalf("rest at full HP should fail")
	}
	// Broke adventurer cannot rest.
	j := findAdventurer(alice)
	adventurers[j].HP = 50
	adventurers[j].Gold = 0
	if err := rest(alice); err == nil {
		t.Fatalf("rest with 0 gold should fail")
	}
}

func TestTip(t *testing.T) {
	resetState()
	mustMint(t, alice, "Mira", ClassRanger) // 70 gold
	mustMint(t, bob, "Bram", ClassBard)     // 50 gold
	if err := tipAdventurer(alice, bob, 10); err != nil {
		t.Fatalf("tip: %s", err)
	}
	a, _ := GetAdventurer(alice)
	b, _ := GetAdventurer(bob)
	if a.Gold != 60 || b.Gold != 60 {
		t.Fatalf("after 10g tip: want 60/60, got %d/%d", a.Gold, b.Gold)
	}
	if a.TipsGiven != 10 || b.TipsReceived != 10 {
		t.Fatalf("tip counters wrong: %+v / %+v", a, b)
	}
	if Stats().GoldTipped != 10 {
		t.Fatalf("tavern gold tipped: want 10, got %d", Stats().GoldTipped)
	}
	if err := tipAdventurer(alice, alice, 5); err == nil {
		t.Fatalf("self-tip should fail")
	}
	if err := tipAdventurer(alice, bob, 1000); err == nil {
		t.Fatalf("over-tip should fail")
	}
	if err := tipAdventurer(alice, dave, 5); err == nil {
		t.Fatalf("tip to non-adventurer should fail")
	}
}

func TestLeaderboard(t *testing.T) {
	resetState()
	mustMint(t, alice, "Mira", ClassRanger)
	mustMint(t, bob, "Bram", ClassBard)
	mustMint(t, carol, "Cleo", ClassRogue)
	adventurers[findAdventurer(alice)].XP = 10
	adventurers[findAdventurer(bob)].XP = 50
	adventurers[findAdventurer(carol)].XP = 30
	board := Leaderboard()
	if len(board) != 3 {
		t.Fatalf("leaderboard should have 3 entries, got %d", len(board))
	}
	if board[0].Owner != bob || board[1].Owner != carol || board[2].Owner != alice {
		t.Fatalf("leaderboard order wrong: %s, %s, %s",
			board[0].Name, board[1].Name, board[2].Name)
	}
}

func TestRender(t *testing.T) {
	resetState()
	mustMint(t, alice, "Mira", ClassRanger)
	home := Render("")
	for _, want := range []string{"Tavern Quest", "Rat Cellar", "Dragon's Tab", "Leaderboard"} {
		found := false
		for i := 0; i+len(want) <= len(home); i++ {
			if home[i:i+len(want)] == want {
				found = true
				break
			}
		}
		if !found {
			t.Fatalf("home render missing %q", want)
		}
	}
	sheet := Render("/adventurer/" + alice.String())
	for _, want := range []string{"Mira", "Ranger", "Satchel"} {
		found := false
		for i := 0; i+len(want) <= len(sheet); i++ {
			if sheet[i:i+len(want)] == want {
				found = true
				break
			}
		}
		if !found {
			t.Fatalf("adventurer render missing %q", want)
		}
	}
	questsPage := Render("/quests")
	if len(questsPage) < 100 {
		t.Fatalf("quests render too short")
	}
}

func TestQuestBoardContents(t *testing.T) {
	resetState()
	list := ListQuests()
	if len(list) != 6 {
		t.Fatalf("quest board should have 6 quests, got %d", len(list))
	}
	seen := map[string]bool{}
	for _, q := range list {
		if q.MinLevel < 1 || q.Gold <= 0 || q.XP <= 0 || q.HPCost <= 0 {
			t.Fatalf("quest %d has invalid numbers: %+v", q.ID, q)
		}
		if !validIngredient(q.Ingredient) {
			t.Fatalf("quest %d grants unknown ingredient %q", q.ID, q.Ingredient)
		}
		if seen[q.Name] {
			t.Fatalf("duplicate quest name %q", q.Name)
		}
		seen[q.Name] = true
	}
}

func contains(haystack, needle string) bool {
	if len(needle) == 0 {
		return true
	}
	for i := 0; i+len(needle) <= len(haystack); i++ {
		if haystack[i:i+len(needle)] == needle {
			return true
		}
	}
	return false
}

func TestReadAPIJSON(t *testing.T) {
	resetState()
	mustMint(t, alice, "Mira", ClassRanger)
	if err := acceptQuest(alice, 1); err != nil {
		t.Fatalf("accept: %s", err)
	}
	if _, err := completeQuest(alice); err != nil {
		t.Fatalf("complete: %s", err)
	}
	stats := StatsJSON()
	if !contains(stats, "\"adventurers\":1") || !contains(stats, "\"questsDone\":1") {
		t.Fatalf("StatsJSON wrong: %s", stats)
	}
	questsJSON := QuestsJSON()
	if !contains(questsJSON, "\"name\":\"Rat Cellar Cleanup\"") ||
		!contains(questsJSON, "\"ingredient\":\"Dragon Scale\"") {
		t.Fatalf("QuestsJSON wrong: %s", questsJSON)
	}
	board := LeaderboardJSON()
	if !contains(board, "\"name\":\"Mira\"") || !contains(board, "\"xp\":30") {
		t.Fatalf("LeaderboardJSON wrong: %s", board)
	}
	sheet := AdventurerJSON(alice.String())
	if !contains(sheet, "\"name\":\"Mira\"") || !contains(sheet, "\"gold\":95") {
		t.Fatalf("AdventurerJSON wrong: %s", sheet)
	}
	if AdventurerJSON(dave.String()) != "{}" {
		t.Fatalf("AdventurerJSON for a stranger should be {}, got %s", AdventurerJSON(dave.String()))
	}
	tales := TalesJSON()
	if !contains(tales, "Rat Cellar Cleanup") {
		t.Fatalf("TalesJSON wrong: %s", tales)
	}
	if jsonEscape("a\"b\\c") != "a\\\"b\\\\c" {
		t.Fatalf("jsonEscape wrong: %s", jsonEscape("a\"b\\c"))
	}
}
