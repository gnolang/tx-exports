package gnometavern

import (
	"strconv"
	"strings"

	"gno.land/p/g17dvvky49vjqj6a4cjhwcvzctteqjm9stee000h/tavernlogic"
)

// Render draws the tavern for gnoweb. Pages:
//   ""               the tavern board (stats, today's quests, top 10, wall)
//   "menu"           the full menu with level requirements
//   "quests"         today's quest board in detail
//   "leaderboard"    every gnome, ranked
//   "wall"           the full message wall
//   "gnome/<addr>"   one gnome's card
func Render(path string) string {
	switch {
	case path == "":
		return renderHome()
	case path == "menu":
		return renderMenu()
	case path == "quests":
		return renderQuests()
	case path == "leaderboard":
		return renderLeaderboard()
	case path == "wall":
		return renderWall()
	case strings.HasPrefix(path, "gnome/"):
		return renderGnome(strings.TrimPrefix(path, "gnome/"))
	default:
		return "# The Gnome Tavern\n\nUnknown page `" + path +
			"`. Try the board at this realm's root, or the pages `menu`, `quests`, `leaderboard`, `wall`."
	}
}

// --- leaderboard ----------------------------------------------------------

type entry struct {
	addr  address
	gnome *tavernlogic.Gnome
}

// ranked returns all gnomes sorted by XP (then lifetime serves), best
// first. Insertion sort: the tavern is small and this stays
// dependency-free and deterministic (join order breaks full ties).
func ranked() []entry {
	out := make([]entry, 0, len(joinOrder))
	for _, addr := range joinOrder {
		out = append(out, entry{addr, gnomes[addr]})
	}
	for i := 1; i < len(out); i++ {
		for j := i; j > 0 && ranksBefore(out[j], out[j-1]); j-- {
			out[j], out[j-1] = out[j-1], out[j]
		}
	}
	return out
}

func ranksBefore(a, b entry) bool {
	if a.gnome.XP != b.gnome.XP {
		return a.gnome.XP > b.gnome.XP
	}
	return a.gnome.TotalServes > b.gnome.TotalServes
}

func leaderboardTable(limit int) string {
	board := ranked()
	if limit > 0 && len(board) > limit {
		board = board[:limit]
	}
	if len(board) == 0 {
		return "_No gnomes yet — be the first to register!_\n"
	}
	var sb strings.Builder
	sb.WriteString("| # | Gnome | Level | XP | Coins | Lifetime serves |\n")
	sb.WriteString("|---|-------|-------|----|----|----|\n")
	for i, e := range board {
		sb.WriteString("| " + strconv.Itoa(i+1) + " | " + e.gnome.Name +
			" | " + strconv.Itoa(e.gnome.Level()) +
			" | " + strconv.Itoa(e.gnome.XP) +
			" | " + strconv.Itoa(e.gnome.Coins) +
			" | " + strconv.Itoa(e.gnome.TotalServes) + " |\n")
	}
	return sb.String()
}

// --- pages ----------------------------------------------------------------

func renderHome() string {
	day := currentDay()
	var sb strings.Builder
	sb.WriteString("# The Gnome Tavern\n\n")
	sb.WriteString("Welcome, traveller. The Gnome Tavern is a tiny tavern that lives entirely on-chain: " +
		"register a gnome, work shifts serving the menu, finish the daily quest board, level up, and leave " +
		"a note on the wall for the next traveller. Every serve, quest and note is a real transaction, and " +
		"this page is rendered by the realm itself.\n\n")
	sb.WriteString("**Tavern day " + strconv.FormatInt(day, 10) + "** · " +
		strconv.Itoa(len(gnomes)) + " gnomes registered · " +
		strconv.Itoa(totalServes) + " items served all time\n\n")

	sb.WriteString("## Today's quest board\n\n")
	sb.WriteString(questList(day))
	sb.WriteString("\n")

	sb.WriteString("## Leaderboard (top 10)\n\n")
	sb.WriteString(leaderboardTable(10))
	sb.WriteString("\n")

	sb.WriteString("## From the wall\n\n")
	sb.WriteString(wallList(5))
	sb.WriteString("\n")

	sb.WriteString("## How to play\n\n")
	sb.WriteString("Call the realm with `gnokey` (testnet remote, chain id `onyx-1`):\n\n")
	sb.WriteString("1. `Register(\"YourName\")` — one gnome per address, names are unique.\n")
	sb.WriteString("2. `Serve(itemID)` — serve menu items to earn coins and XP. IDs and level requirements are on the `menu` page.\n")
	sb.WriteString("3. `ClaimQuest(slot)` — claim slots 0-2 of the quest board once you have done the work.\n")
	sb.WriteString("4. `Feast()` — spend 50 coins on +15 XP, once per tavern day.\n")
	sb.WriteString("5. `PostNote(\"...\")` — pin a note to the wall.\n\n")
	sb.WriteString("Pages: append `:menu`, `:quests`, `:leaderboard`, `:wall` or `:gnome/<address>` to this realm's URL. " +
		"A tavern day lasts " + strconv.FormatInt(tavernlogic.DayBlocks, 10) + " blocks; the quest board and daily counters reset when it rolls over.\n")
	return sb.String()
}

func renderMenu() string {
	var sb strings.Builder
	sb.WriteString("# Tavern Menu\n\n")
	sb.WriteString("Serve an item by calling `Serve(ID)`. Higher items pay more but need a higher gnome level.\n\n")
	sb.WriteString("| ID | Item | Min level | Pays | XP | About |\n")
	sb.WriteString("|----|------|----|----|----|----|\n")
	for _, item := range tavernlogic.Menu() {
		sb.WriteString("| " + strconv.Itoa(item.ID) + " | " + item.Name +
			" | " + strconv.Itoa(item.MinLevel) +
			" | " + strconv.Itoa(item.Coins) + " coins" +
			" | " + strconv.Itoa(item.XP) +
			" | " + item.Detail + " |\n")
	}
	sb.WriteString("\nLevels: every " + strconv.Itoa(tavernlogic.XPPerLevel) +
		" XP is a new level. A gnome may serve at most " +
		strconv.Itoa(tavernlogic.MaxServesPerDay) + " items per tavern day.\n")
	return sb.String()
}

func questList(day int64) string {
	board := tavernlogic.QuestsForDay(day)
	var sb strings.Builder
	for slot, q := range board {
		sb.WriteString(strconv.Itoa(slot) + ". **" + q.Title + "** — " + q.Desc +
			" Reward: " + strconv.Itoa(q.CoinReward) + " coins + " +
			strconv.Itoa(q.XPReward) + " XP.\n")
	}
	return sb.String()
}

func renderQuests() string {
	day := currentDay()
	var sb strings.Builder
	sb.WriteString("# Quest Board — tavern day " + strconv.FormatInt(day, 10) + "\n\n")
	sb.WriteString("The board rotates every tavern day (" +
		strconv.FormatInt(tavernlogic.DayBlocks, 10) +
		" blocks) and is the same for every gnome. Do the work by serving, then call `ClaimQuest(slot)`.\n\n")
	sb.WriteString(questList(day))
	sb.WriteString("\nQuests are drawn from a pool of " +
		strconv.Itoa(len(tavernlogic.QuestPool())) + "; tomorrow's board will differ.\n")
	return sb.String()
}

func renderLeaderboard() string {
	var sb strings.Builder
	sb.WriteString("# Leaderboard\n\n")
	sb.WriteString("Every gnome in the tavern, ranked by XP.\n\n")
	sb.WriteString(leaderboardTable(0))
	return sb.String()
}

func wallList(limit int) string {
	if len(wall) == 0 {
		return "_The wall is bare. Register a gnome and pin the first note._\n"
	}
	start := 0
	if limit > 0 && len(wall) > limit {
		start = len(wall) - limit
	}
	var sb strings.Builder
	for _, n := range wall[start:] {
		sb.WriteString("- **" + n.Author + "** (day " +
			strconv.FormatInt(n.Day, 10) + "): " +
			strings.ReplaceAll(n.Text, "|", "/") + "\n")
	}
	return sb.String()
}

func renderWall() string {
	var sb strings.Builder
	sb.WriteString("# The Tavern Wall\n\n")
	sb.WriteString("Notes from the gnomes. Pin your own with `PostNote(\"...\")`.\n\n")
	sb.WriteString(wallList(0))
	return sb.String()
}

func renderGnome(addrStr string) string {
	for _, addr := range joinOrder {
		if addr.String() == addrStr {
			g := gnomes[addr]
			var sb strings.Builder
			sb.WriteString("# " + g.Name + "\n\n")
			sb.WriteString("- **Address:** `" + addrStr + "`\n")
			sb.WriteString("- **Level:** " + strconv.Itoa(g.Level()) +
				" (" + strconv.Itoa(g.XP) + " XP; next level at " +
				strconv.Itoa(tavernlogic.XPForLevel(g.Level()+1)) + " XP)\n")
			sb.WriteString("- **Coins:** " + strconv.Itoa(g.Coins) + "\n")
			sb.WriteString("- **Lifetime serves:** " + strconv.Itoa(g.TotalServes) + "\n")
			servesToday := g.ServesToday
			if g.LastDay != currentDay() {
				servesToday = 0 // daily counters reset lazily on the next action
			}
			sb.WriteString("- **Serves today:** " + strconv.Itoa(servesToday) +
				" (tavern day " + strconv.FormatInt(currentDay(), 10) + ")\n")
			return sb.String()
		}
	}
	return "# The Gnome Tavern\n\nNo gnome is registered for `" + addrStr + "`."
}
