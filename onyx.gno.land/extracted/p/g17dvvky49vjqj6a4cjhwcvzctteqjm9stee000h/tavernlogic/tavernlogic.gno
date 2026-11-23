// Package tavernlogic holds the pure game rules of the Gnome Tavern:
// the menu, the level ladder, the rotating daily quest board and the
// per-gnome state machine (serving drinks, claiming quests, feasting).
//
// It is a pure package (gno.land/p/...): it owns no chain state of its
// own. The Gnome Tavern realm keeps the state (a *Gnome per player) and
// calls into these functions, which keeps every rule unit-testable
// without a chain.
package tavernlogic

import "errors"

// DayBlocks is the length of one tavern day, in blocks. Quest boards,
// daily serve counters and feast allowances all reset when the day rolls
// over. A short day keeps the game lively on a testnet: at Onyx's block
// pace a tavern day lasts roughly an hour.
const DayBlocks int64 = 2000

// MaxServesPerDay caps how many items one gnome may serve per tavern day.
const MaxServesPerDay = 40

// FeastCost and FeastXP describe the Gnome Feast: a coin sink that lets a
// hard-working gnome convert earnings into experience, once per day.
const (
	FeastCost = 50
	FeastXP   = 15
)

// DayAt maps a chain height to its tavern day number.
func DayAt(height int64) int64 {
	if height < 0 {
		return 0
	}
	return height / DayBlocks
}

// --- Levels ---------------------------------------------------------------

// XPPerLevel is the amount of XP between consecutive levels.
const XPPerLevel = 40

// LevelForXP returns the level of a gnome holding xp experience points.
// Level 1 is the starting level; every XPPerLevel XP earns a new level.
func LevelForXP(xp int) int {
	if xp < 0 {
		xp = 0
	}
	return 1 + xp/XPPerLevel
}

// XPForLevel returns the cumulative XP at which level l is reached.
func XPForLevel(l int) int {
	if l <= 1 {
		return 0
	}
	return (l - 1) * XPPerLevel
}

// --- Menu -----------------------------------------------------------------

// MenuItem is one serveable entry on the tavern menu. Serving it pays the
// gnome Coins tavern coins and XP experience, and requires MinLevel.
type MenuItem struct {
	ID       int
	Name     string
	Detail   string
	MinLevel int
	Coins    int
	XP       int
}

var menu = []MenuItem{
	{0, "Barley Soup", "A humble bowl that never empties.", 1, 3, 2},
	{1, "Gnomebrew Ale", "Foamy, nutty, proudly gnome-sized.", 1, 5, 3},
	{2, "Honeyed Ham", "Glazed with wildflower honey.", 2, 9, 5},
	{3, "Emberwhisky", "Warms the beard from the inside.", 3, 14, 8},
	{4, "Moonpetal Tea", "Brewed under a full moon, allegedly.", 4, 20, 12},
	{5, "Dragonfire Stew", "Sign the waiver. Then enjoy.", 5, 30, 18},
}

// Menu returns the full tavern menu, in serving order.
func Menu() []MenuItem {
	return menu
}

// MenuItemByID looks up a menu item by its ID.
func MenuItemByID(id int) (MenuItem, bool) {
	if id < 0 || id >= len(menu) {
		return MenuItem{}, false
	}
	return menu[id], true
}

// --- Quests ---------------------------------------------------------------

// Quest kinds: what the progress counter measures.
const (
	QuestTotalServes = 0 // serve Count items of any kind today
	QuestItemServes  = 1 // serve Count of item ItemID today
)

// Quest is one entry on the daily quest board.
type Quest struct {
	ID         int
	Title      string
	Desc       string
	Kind       int
	ItemID     int // only for QuestItemServes
	Count      int
	CoinReward int
	XPReward   int
}

var questPool = []Quest{
	{0, "First Round", "Serve 4 items today.", QuestTotalServes, 0, 4, 15, 8},
	{1, "Ale Baron", "Serve 4 Gnomebrew Ales today.", QuestItemServes, 1, 4, 25, 12},
	{2, "Morning Rush", "Serve 8 items today.", QuestTotalServes, 0, 8, 30, 15},
	{3, "Ham It Up", "Serve 3 Honeyed Hams today.", QuestItemServes, 2, 3, 30, 14},
	{4, "Full House", "Serve 14 items today.", QuestTotalServes, 0, 14, 55, 26},
	{5, "Whisky Business", "Serve 3 Emberwhiskies today.", QuestItemServes, 3, 3, 45, 22},
	{6, "Tea Ceremony", "Serve 3 Moonpetal Teas today.", QuestItemServes, 4, 3, 60, 30},
	{7, "Dragon Slayer's Feast", "Serve 2 Dragonfire Stews today.", QuestItemServes, 5, 2, 70, 36},
}

// QuestPool returns every quest that can appear on the board.
func QuestPool() []Quest {
	return questPool
}

// QuestsForDay deterministically picks the 3 quests on the board for a
// tavern day. The same day always yields the same board, on every node,
// with no randomness source beyond the day number itself (a small LCG).
func QuestsForDay(day int64) [3]Quest {
	var out [3]Quest
	state := day*2654435761 + 97
	used := map[int]bool{}
	for slot := 0; slot < 3; slot++ {
		for {
			state = state*1103515245 + 12345
			idx := int(((state >> 16) & 0x7fffffff) % int64(len(questPool)))
			if !used[idx] {
				used[idx] = true
				out[slot] = questPool[idx]
				break
			}
		}
	}
	return out
}

// --- Gnome state ----------------------------------------------------------

// Gnome is one player's tavern career. The realm owns one *Gnome per
// registered address; all fields are plain data so the realm can persist
// it directly.
type Gnome struct {
	Name string
	XP   int
	Coins int

	TotalServes int

	// Daily counters; they belong to LastDay and reset on rollover.
	LastDay      int64
	ServesToday  int
	ItemToday    map[int]int
	ClaimedToday map[int]bool // quest IDs already claimed today
	FeastedToday bool
}

// NewGnome creates a fresh gnome registered under the given name.
func NewGnome(name string, day int64) *Gnome {
	return &Gnome{
		Name:         name,
		LastDay:      day,
		ItemToday:    map[int]int{},
		ClaimedToday: map[int]bool{},
	}
}

// Level returns the gnome's current level.
func (g *Gnome) Level() int {
	return LevelForXP(g.XP)
}

// rollover resets the daily counters when a new tavern day has begun.
func (g *Gnome) rollover(day int64) {
	if g.LastDay == day {
		return
	}
	g.LastDay = day
	g.ServesToday = 0
	g.ItemToday = map[int]int{}
	g.ClaimedToday = map[int]bool{}
	g.FeastedToday = false
}

// Serve records the gnome serving one menu item on the given day and
// returns what was earned. It enforces the menu's level requirement and
// the daily serve cap.
func (g *Gnome) Serve(day int64, itemID int) (coinsEarned, xpEarned int, err error) {
	item, ok := MenuItemByID(itemID)
	if !ok {
		return 0, 0, errors.New("no such menu item")
	}
	g.rollover(day)
	if g.Level() < item.MinLevel {
		return 0, 0, errors.New("your level is too low for this item")
	}
	if g.ServesToday >= MaxServesPerDay {
		return 0, 0, errors.New("you have served enough for one day; come back tomorrow")
	}
	g.ServesToday++
	g.TotalServes++
	g.ItemToday[itemID]++
	g.Coins += item.Coins
	g.XP += item.XP
	return item.Coins, item.XP, nil
}

// ProgressFor reports the gnome's progress toward a quest today.
func (g *Gnome) ProgressFor(day int64, q Quest) int {
	if g.LastDay != day {
		return 0
	}
	if q.Kind == QuestItemServes {
		return g.ItemToday[q.ItemID]
	}
	return g.ServesToday
}

// ClaimQuest pays out the quest in board slot (0-2) for the given day, if
// the gnome has met its requirement and has not claimed it yet today.
func (g *Gnome) ClaimQuest(day int64, slot int) (Quest, error) {
	if slot < 0 || slot > 2 {
		return Quest{}, errors.New("quest slot must be 0, 1 or 2")
	}
	g.rollover(day)
	q := QuestsForDay(day)[slot]
	if g.ClaimedToday[q.ID] {
		return Quest{}, errors.New("you already claimed this quest today")
	}
	if g.ProgressFor(day, q) < q.Count {
		return Quest{}, errors.New("quest requirement not met yet")
	}
	g.ClaimedToday[q.ID] = true
	g.Coins += q.CoinReward
	g.XP += q.XPReward
	return q, nil
}

// Feast lets the gnome spend FeastCost coins on a Gnome Feast, gaining
// FeastXP experience. Once per tavern day.
func (g *Gnome) Feast(day int64) error {
	g.rollover(day)
	if g.FeastedToday {
		return errors.New("you already feasted today")
	}
	if g.Coins < FeastCost {
		return errors.New("not enough coins for a feast")
	}
	g.Coins -= FeastCost
	g.XP += FeastXP
	g.FeastedToday = true
	return nil
}
