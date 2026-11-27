// Render renders the tavern for gnoweb: the quest board, the leaderboard
// and each adventurer's character sheet as Markdown.
package tavernquest

import (
	"strconv"
	"strings"
)

func Render(path string) string {
	seedQuests()
	parts := strings.Split(strings.Trim(path, "/"), "/")
	if len(parts) == 2 && parts[0] == "adventurer" {
		return renderAdventurer(address(parts[1]))
	}
	switch path {
	case "", "/":
		return renderHome()
	case "/quests", "quests":
		return renderQuests()
	case "/leaderboard", "leaderboard":
		return renderLeaderboard()
	default:
		return renderHome()
	}
}

func renderHome() string {
	s := Stats()
	out := "# 🍺 Tavern Quest\n\n"
	out += "*A gnome tavern adventure, on-chain.* Pull up a stool, mint an adventurer, " +
		"take quests from the board, brew potions and climb the leaderboard.\n\n"
	out += "## The Tavern Tonight\n\n"
	out += "- **Adventurers:** " + strconv.Itoa(s.Adventurers) + "\n"
	out += "- **Quests completed:** " + strconv.Itoa(s.QuestsDone) + "\n"
	out += "- **Gold tipped:** " + strconv.Itoa(s.GoldTipped) + "\n"
	out += "- **Potions brewed:** " + strconv.Itoa(s.PotionsBrewed) + "\n\n"
	out += "## Quest Board\n\n"
	out += "| # | Quest | Level | Gold | XP | HP | Ingredient |\n"
	out += "|---|-------|-------|------|----|----|------------|\n"
	for i := 0; i < len(quests); i++ {
		q := quests[i]
		out += "| " + strconv.Itoa(q.ID) + " | " + q.Name + " | " + strconv.Itoa(q.MinLevel) +
			" | " + strconv.Itoa(q.Gold) + " | " + strconv.Itoa(q.XP) +
			" | " + strconv.Itoa(q.HPCost) + " | " + q.Ingredient + " |\n"
	}
	out += "\n## Leaderboard\n\n"
	board := Leaderboard()
	if len(board) == 0 {
		out += "No legends yet. Be the first to bell up to the bar.\n"
	} else {
		for i := 0; i < len(board); i++ {
			a := board[i]
			out += strconv.Itoa(i+1) + ". **" + a.Name + "** the " + a.Class +
				" — level " + strconv.Itoa(a.Level) + ", " + strconv.Itoa(a.XP) +
				" XP, " + strconv.Itoa(a.QuestsDone) + " quests\n"
		}
	}
	out += "\n## Tavern Tales\n\n"
	log := QuestLog()
	if len(log) == 0 {
		out += "The fire crackles. The tales have not begun.\n"
	} else {
		for i := 0; i < len(log); i++ {
			out += "- " + log[i] + "\n"
		}
	}
	out += "\n---\n\n*How to play: `MintAdventurer(name, class)` with class Brewmaster, " +
		"Ranger, Bard or Rogue — then `AcceptQuest(id)`, `CompleteQuest()`, " +
		"`BrewPotion(a, b)`, `Rest()` and `TipAdventurer(to, amount)`. " +
		"See the Actions tab to play from your wallet.*\n"
	return out
}

func renderQuests() string {
	out := "# 📜 Quest Board\n\n"
	for i := 0; i < len(quests); i++ {
		q := quests[i]
		out += "## " + strconv.Itoa(q.ID) + ". " + q.Name + "\n\n"
		out += q.Desc + "\n\n"
		out += "- Requires level " + strconv.Itoa(q.MinLevel) + "\n"
		out += "- Reward: " + strconv.Itoa(q.Gold) + " gold, " + strconv.Itoa(q.XP) + " XP\n"
		out += "- Costs " + strconv.Itoa(q.HPCost) + " HP\n"
		out += "- Find: " + q.Ingredient + "\n\n"
	}
	return out
}

func renderLeaderboard() string {
	out := "# 🏆 Leaderboard\n\n"
	board := Leaderboard()
	if len(board) == 0 {
		return out + "No legends yet.\n"
	}
	for i := 0; i < len(board); i++ {
		a := board[i]
		out += strconv.Itoa(i+1) + ". **" + a.Name + "** the " + a.Class +
			" — level " + strconv.Itoa(a.Level) + ", " + strconv.Itoa(a.XP) + " XP, " +
			strconv.Itoa(a.QuestsDone) + " quests, " + strconv.Itoa(a.Gold) + " gold\n"
	}
	return out
}

func renderAdventurer(addr address) string {
	a, ok := GetAdventurer(addr)
	if !ok {
		return "# No adventurer here\n\nNo adventurer is registered for `" + addr.String() + "`.\n"
	}
	out := "# ⚔️ " + a.Name + " the " + a.Class + "\n\n"
	out += "- **Level:** " + strconv.Itoa(a.Level) + " (" + strconv.Itoa(a.XP) + " XP)\n"
	out += "- **Health:** " + strconv.Itoa(a.HP) + " / " + strconv.Itoa(a.MaxHP) + "\n"
	out += "- **Gold:** " + strconv.Itoa(a.Gold) + "\n"
	out += "- **Quests completed:** " + strconv.Itoa(a.QuestsDone) + "\n"
	if a.ActiveQuest == -1 {
		out += "- **Active quest:** none — the board awaits\n"
	} else {
		q, _ := GetQuest(a.ActiveQuest)
		out += "- **Active quest:** " + q.Name + "\n"
	}
	out += "- **Tips given / received:** " + strconv.Itoa(a.TipsGiven) + " / " + strconv.Itoa(a.TipsReceived) + " gold\n\n"
	out += "## Satchel\n\n"
	out += "- Healing Draught: " + strconv.Itoa(a.Healing) + "\n"
	out += "- Ember Mead: " + strconv.Itoa(a.Lucky) + "\n"
	out += "- Stoneskin Stout: " + strconv.Itoa(a.Stone) + "\n\n"
	out += "## Ingredient Pouch\n\n"
	out += "- Ember Pepper: " + strconv.Itoa(a.EmberPepper) + "\n"
	out += "- Moonpetal: " + strconv.Itoa(a.Moonpetal) + "\n"
	out += "- Frogspawn: " + strconv.Itoa(a.Frogspawn) + "\n"
	out += "- Dragon Scale: " + strconv.Itoa(a.DragonScale) + "\n"
	out += "- Honey: " + strconv.Itoa(a.Honey) + "\n"
	out += "- Bat Wing: " + strconv.Itoa(a.BatWing) + "\n"
	return out
}
