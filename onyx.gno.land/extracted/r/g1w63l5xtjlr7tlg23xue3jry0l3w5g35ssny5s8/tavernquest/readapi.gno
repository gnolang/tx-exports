// Read API for the web frontend.
//
// The frontend talks to the realm through the testnet RPC `vm/qeval`
// endpoint, which returns values in Gno syntax. These helpers return
// plain JSON strings instead, so the browser can parse them with
// JSON.parse after stripping the outer Gno string quoting.
//
// This mirrors the pattern other Gno.land projects use (a dedicated
// read API for the frontend); the functions are read-only and change
// no state.
package tavernquest

import "strconv"

// jsonEscape escapes a string for inclusion in a JSON string value.
// Tavern text uses only plain letters, apostrophes and punctuation,
// but escaping keeps the output valid whatever the input holds.
func jsonEscape(s string) string {
	out := ""
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch c {
		case '"':
			out += "\\\""
		case '\\':
			out += "\\\\"
		case '\n':
			out += "\\n"
		default:
			out += string(c)
		}
	}
	return out
}

// StatsJSON returns the tavern scoreboard as JSON.
func StatsJSON() string {
	s := Stats()
	return "{\"adventurers\":" + strconv.Itoa(s.Adventurers) +
		",\"questsDone\":" + strconv.Itoa(s.QuestsDone) +
		",\"goldTipped\":" + strconv.Itoa(s.GoldTipped) +
		",\"potionsBrewed\":" + strconv.Itoa(s.PotionsBrewed) +
		",\"potionsDrunk\":" + strconv.Itoa(s.PotionsDrunk) + "}"
}

// QuestsJSON returns the quest board as a JSON array.
func QuestsJSON() string {
	list := ListQuests()
	out := "["
	for i := 0; i < len(list); i++ {
		q := list[i]
		if i > 0 {
			out += ","
		}
		out += "{\"id\":" + strconv.Itoa(q.ID) +
			",\"name\":\"" + jsonEscape(q.Name) +
			"\",\"desc\":\"" + jsonEscape(q.Desc) +
			"\",\"minLevel\":" + strconv.Itoa(q.MinLevel) +
			",\"gold\":" + strconv.Itoa(q.Gold) +
			",\"xp\":" + strconv.Itoa(q.XP) +
			",\"hpCost\":" + strconv.Itoa(q.HPCost) +
			",\"ingredient\":\"" + jsonEscape(q.Ingredient) + "\"}"
	}
	return out + "]"
}

// LeaderboardJSON returns the top adventurers as a JSON array.
func LeaderboardJSON() string {
	board := Leaderboard()
	out := "["
	for i := 0; i < len(board); i++ {
		a := board[i]
		if i > 0 {
			out += ","
		}
		out += "{\"name\":\"" + jsonEscape(a.Name) +
			"\",\"class\":\"" + jsonEscape(a.Class) +
			"\",\"level\":" + strconv.Itoa(a.Level) +
			",\"xp\":" + strconv.Itoa(a.XP) +
			",\"questsDone\":" + strconv.Itoa(a.QuestsDone) +
			",\"gold\":" + strconv.Itoa(a.Gold) + "}"
	}
	return out + "]"
}

// AdventurerJSON returns one adventurer as JSON, or "{}" when the
// address has no adventurer.
func AdventurerJSON(addr string) string {
	a, ok := GetAdventurer(address(addr))
	if !ok {
		return "{}"
	}
	out := "{\"owner\":\"" + a.Owner.String() +
		"\",\"name\":\"" + jsonEscape(a.Name) +
		"\",\"class\":\"" + jsonEscape(a.Class) +
		"\",\"level\":" + strconv.Itoa(a.Level) +
		",\"xp\":" + strconv.Itoa(a.XP) +
		",\"gold\":" + strconv.Itoa(a.Gold) +
		",\"hp\":" + strconv.Itoa(a.HP) +
		",\"maxHp\":" + strconv.Itoa(a.MaxHP) +
		",\"activeQuest\":" + strconv.Itoa(a.ActiveQuest) +
		",\"questsDone\":" + strconv.Itoa(a.QuestsDone) +
		",\"tipsGiven\":" + strconv.Itoa(a.TipsGiven) +
		",\"tipsReceived\":" + strconv.Itoa(a.TipsReceived) +
		",\"healing\":" + strconv.Itoa(a.Healing) +
		",\"lucky\":" + strconv.Itoa(a.Lucky) +
		",\"stone\":" + strconv.Itoa(a.Stone) +
		",\"emberPepper\":" + strconv.Itoa(a.EmberPepper) +
		",\"moonpetal\":" + strconv.Itoa(a.Moonpetal) +
		",\"frogspawn\":" + strconv.Itoa(a.Frogspawn) +
		",\"dragonScale\":" + strconv.Itoa(a.DragonScale) +
		",\"honey\":" + strconv.Itoa(a.Honey) +
		",\"batWing\":" + strconv.Itoa(a.BatWing) + "}"
	return out
}

// TalesJSON returns the tavern tales log as a JSON array of strings.
func TalesJSON() string {
	log := QuestLog()
	out := "["
	for i := 0; i < len(log); i++ {
		if i > 0 {
			out += ","
		}
		out += "\"" + jsonEscape(log[i]) + "\""
	}
	return out + "]"
}
