package nisse2

import (
	"strconv"

	"gno.land/p/g1wt79w2q0sfmpfrxc4990mlsg5ll09yva6fyc4p/nisse2/book"
	"gno.land/p/g1wt79w2q0sfmpfrxc4990mlsg5ll09yva6fyc4p/nisse2/rules"
)

func ListPlayerPositions() string {
	if len(players) == 0 {
		return "No players."
	}
	out := "Player positions\n"
	for _, player := range players {
		out += "- " + player.Name + " @ (" + strconv.Itoa(int(player.Pos.X)) + ", " + strconv.Itoa(int(player.Pos.Y)) + ")\n"
	}
	return out
}

func GetPlayerCoreData(name string) string {
	player, ok := players[normalizeKey(name)]
	if !ok {
		panic("player not found")
	}
	return "Name: " + player.Name
}

func GetPlayerTravelData(name string) string {
	key := normalizeKey(name)
	player, ok := players[key]
	if !ok {
		panic("player not found")
	}
	out := "Position: (" + strconv.Itoa(int(player.Pos.X)) + ", " + strconv.Itoa(int(player.Pos.Y)) + ")\n"
	out += "Turns: " + strconv.Itoa(int(player.Turns)) + "\n"
	out += "MonthIndex: " + strconv.Itoa(int(rules.MonthIndex(player.Turns))) + "\n"
	out += "Season: " + rules.SeasonName(player.Turns) + "\n"
	out += "SeasonMonth: " + strconv.Itoa(int(rules.SeasonMonth(player.Turns))) + "\n"
	out += "TravelBonus: +" + strconv.Itoa(int(player.TravelBonus)) + "\n"
	out += "Boat: " + boatStatusSummary(key)
	return out
}

func GetPlayerWealthData(name string) string {
	key := normalizeKey(name)
	if _, ok := players[key]; !ok {
		panic("player not found")
	}
	return "Pearls: " + strconv.Itoa(int(pearls[key]))
}

func GetPlayerMapData(name string) string {
	player, ok := players[normalizeKey(name)]
	if !ok {
		panic("player not found")
	}
	return "Name: " + player.Name + "\n" +
		"PlayerID: " + strconv.Itoa(int(player.ID)) + "\n" +
		"Position: (" + strconv.Itoa(int(player.Pos.X)) + ", " + strconv.Itoa(int(player.Pos.Y)) + ")"
}

func DescribeCompanion(playerName string) string {
	key := normalizeKey(playerName)
	player, ok := players[key]
	if !ok {
		panic("player not found")
	}
	collection := companions[key]
	if len(collection) == 0 {
		return "No companions."
	}
	out := "Companions for " + player.Name + "\n"
	for id := uint64(1); id < nextCompanionID; id++ {
		c, exists := collection[id]
		if !exists {
			continue
		}
		label := c.Kind
		if spec, ok := book.Creature(c.Kind); ok {
			label = spec.Label
		}
		out += "- #" + strconv.Itoa(int(c.ID)) + " " + label + "\n"
		out += "  Profile: bold:" + strconv.Itoa(int(c.Boldness)) +
			" cautious:" + strconv.Itoa(int(c.Caution)) +
			" kind:" + strconv.Itoa(int(c.Kindness)) +
			" soul:" + strconv.Itoa(int(c.Soul)) + "\n"
		out += "  Found: (" + strconv.Itoa(int(c.FoundAt.X)) + "," + strconv.Itoa(int(c.FoundAt.Y)) +
			") turn " + strconv.Itoa(int(c.FoundTurn)) + "\n"
	}
	return out
}

func DescribeLatestDiaryEntry(playerName string) string {
	key := normalizeKey(playerName)
	player, ok := players[key]
	if !ok {
		panic("player not found")
	}
	if player.DiaryPages == 0 {
		return "Diary empty."
	}
	entryMap := diaries[key]
	if entryMap == nil {
		return "Diary empty."
	}
	for entryID := player.NextEntryID; entryID > 1; entryID-- {
		entry := entryMap[entryID-1]
		if entry != nil {
			out := "Turn:" + strconv.Itoa(int(entry.Turn)) + "\n"
			out += "Action:" + entry.Action + "\n"
			out += "Place:" + entry.Place + "\n"
			out += "Title:" + entry.Title + "\n"
			out += "Body:" + entry.Body
			return out
		}
	}
	return "Diary empty."
}

func boatStatusSummary(key string) string {
	b := boats[key]
	if b == nil {
		return "none"
	}
	if b.Carried {
		return "carried " + b.Name
	}
	return "moored " + b.Name + " @ (" + strconv.Itoa(int(b.Pos.X)) + "," + strconv.Itoa(int(b.Pos.Y)) + ")"
}

func DescribeCreature(kind string) string {
	c, ok := book.Creature(book.NormalizeKind(kind))
	if !ok {
		return "unknown creature"
	}
	out := c.Label + " (" + c.Kind + ")\n"
	out += "Domain: " + c.Domain + "\n"
	out += "Level: " + strconv.Itoa(int(c.Level)) + "\n"
	out += "Dice: bold d" + strconv.Itoa(int(c.BoldSides)) +
		" kind d" + strconv.Itoa(int(c.KindnessSides)) +
		" caut d" + strconv.Itoa(int(c.CautSides)) +
		" soul d" + strconv.Itoa(int(c.SoulSides)) + "\n"
	if c.MaxMints == 0 {
		out += "MaxMints: unlimited\n"
	} else {
		out += "MaxMints: " + strconv.Itoa(int(c.MaxMints)) + " minted:" + strconv.Itoa(int(mintCounts[c.Kind])) + "\n"
	}
	out += "Lore: " + c.Lore
	return out
}
