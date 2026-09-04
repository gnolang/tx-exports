package nisse

import "strconv"

type Player struct {
	ID          uint64
	Owner       Address
	Name        string
	Pos         Position
	Level       uint64
	Boldness    uint64
	Caution     uint64
	Kindness    uint64
	Soul        uint64
	Turns       uint64
	DiaryPages  uint64
	NextEntryID uint64
	TravelBonus uint64
}

type DiaryEntry struct {
	ID        uint64
	Turn      uint64
	Action    string
	Place     string
	TimeOfDay string
	Title     string
	Body      string
}

type CompanionSpecies struct {
	Kind string
	Name string
}

type Companion struct {
	ID          uint64
	AssetID     uint64
	OwnerPlayer string
	Species     CompanionSpecies
	FoundAt     Position
	FoundTurn   uint64
	Boldness    uint64
	Caution     uint64
	Kindness    uint64
	Soul        uint64
}

var players map[string]*Player
var diaries map[string]map[uint64]*DiaryEntry
var companions map[string]map[uint64]*Companion
var nextCompanionID uint64
var nextPlayerID uint64

func init() {
	players = make(map[string]*Player)
	diaries = make(map[string]map[uint64]*DiaryEntry)
	companions = make(map[string]map[uint64]*Companion)
	nextCompanionID = 1
	nextPlayerID = 1
}

func ensureCompanionCollection(playerKey string) map[uint64]*Companion {
	if companions[playerKey] == nil {
		companions[playerKey] = make(map[uint64]*Companion)
	}
	return companions[playerKey]
}

func totalCompanions(playerKey string) uint64 {
	return uint64(len(companions[playerKey]))
}

func aggregateHeldCompanionProfile(playerKey string) (*Companion, bool) {
	collection := companions[playerKey]
	if len(collection) == 0 {
		return nil, false
	}
	aggregate := &Companion{}
	found := false
	for _, companion := range collection {
		if companion == nil {
			continue
		}
		asset := assets[companion.AssetID]
		if asset == nil || asset.Status != "held" {
			continue
		}
		if !found {
			aggregate.Boldness = companion.Boldness
			aggregate.Caution = companion.Caution
			aggregate.Kindness = companion.Kindness
			aggregate.Soul = companion.Soul
			found = true
			continue
		}
		if companion.Boldness > aggregate.Boldness {
			aggregate.Boldness = companion.Boldness
		}
		if companion.Caution > aggregate.Caution {
			aggregate.Caution = companion.Caution
		}
		if companion.Kindness > aggregate.Kindness {
			aggregate.Kindness = companion.Kindness
		}
		if companion.Soul > aggregate.Soul {
			aggregate.Soul = companion.Soul
		}
	}
	return aggregate, found
}

func grantAttitudeSuccessBonus(player *Player, attitude string) string {
	if player == nil {
		return ""
	}
	switch normalizeArrivalAttitude(attitude) {
	case "bold":
		player.Boldness++
		return "Boldness +1."
	case "kind":
		player.Kindness++
		return "Kindness +1."
	default:
		player.Caution++
		return "Caution +1."
	}
}

func createDiaryEntry(playerKey string, action string, place string, timeOfDay string, title string, body string) {
	player, ok := players[playerKey]
	if !ok {
		panic("player not found")
	}
	if diaries[playerKey] == nil {
		diaries[playerKey] = make(map[uint64]*DiaryEntry)
	}
	id := player.NextEntryID
	player.NextEntryID++
	diaries[playerKey][id] = &DiaryEntry{
		ID:        id,
		Turn:      player.Turns,
		Action:    action,
		Place:     place,
		TimeOfDay: timeOfDay,
		Title:     title,
		Body:      body,
	}
	player.DiaryPages++
}

func describeDiaryEntry(entry *DiaryEntry) string {
	if entry == nil {
		return ""
	}
	out := "EntryID:" + strconv.Itoa(int(entry.ID)) + "\n"
	out += "Turn:" + strconv.Itoa(int(entry.Turn)) + "\n"
	out += "Action:" + entry.Action + "\n"
	out += "Place:" + entry.Place + "\n"
	out += "Time:" + entry.TimeOfDay + "\n"
	out += "Title:" + entry.Title + "\n"
	out += "Body:" + entry.Body
	return out
}

func MintPlayer(cur realm, name string) string {
	caller := callerFromCur(cur)
	name = cleanName(name)
	if name == "" {
		panic("player name is required")
	}
	key := normalizeKey(name)
	if _, exists := players[key]; exists {
		panic("player already exists")
	}
	pos := startPosition()
	id := nextPlayerID
	nextPlayerID++

	players[key] = &Player{
		ID:          id,
		Owner:       caller,
		Name:        name,
		Pos:         pos,
		Level:       1,
		Boldness:    10,
		Caution:     10,
		Kindness:    10,
		Soul:        10,
		Turns:       0,
		DiaryPages:  0,
		NextEntryID: 1,
		TravelBonus: 0,
	}
	player := players[key]
	player.Boldness = 10 + d10(player, "boldness")
	player.Caution = 10 + d10(player, "caution")
	player.Kindness = 10 + d10(player, "kindness")
	player.Soul = 10 + d10(player, "soul")
	diaries[key] = make(map[uint64]*DiaryEntry)
	mintInitialPearls(key, 100)
	recordPearlTransfer(key, "Minted 100 initial pearls from "+pearlOriginMark(key)+".")
	body := "PlayerCreated\n"
	body += "Boldness: " + strconv.Itoa(int(player.Boldness)) + "\n"
	body += "Caution: " + strconv.Itoa(int(player.Caution)) + "\n"
	body += "Kindness: " + strconv.Itoa(int(player.Kindness)) + "\n"
	body += "Soul: " + strconv.Itoa(int(player.Soul))
	createDiaryEntry(key, "birth", placeName(pos), "day", "Day one", body)
	return name
}

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
	key := normalizeKey(name)
	player, ok := players[key]
	if !ok {
		panic("player not found")
	}
	return "Name: " + player.Name
}

func GetPlayerStatsData(name string) string {
	key := normalizeKey(name)
	player, ok := players[key]
	if !ok {
		panic("player not found")
	}
	out := "Level: " + strconv.Itoa(int(player.Level)) + "\n"
	out += "Boldness: " + strconv.Itoa(int(player.Boldness)) + "\n"
	out += "Caution: " + strconv.Itoa(int(player.Caution)) + "\n"
	out += "Kindness: " + strconv.Itoa(int(player.Kindness)) + "\n"
	out += "Soul: " + strconv.Itoa(int(player.Soul))
	return out
}

func GetPlayerTravelData(name string) string {
	key := normalizeKey(name)
	player, ok := players[key]
	if !ok {
		panic("player not found")
	}
	out := "Position: (" + strconv.Itoa(int(player.Pos.X)) + ", " + strconv.Itoa(int(player.Pos.Y)) + ")\n"
	out += "Turns: " + strconv.Itoa(int(player.Turns)) + "\n"
	out += "MonthIndex: " + strconv.Itoa(int(monthIndexForTurns(player.Turns))) + "\n"
	out += "Season: " + seasonNameForTurns(player.Turns) + "\n"
	out += "SeasonMonth: " + strconv.Itoa(int(seasonMonthForTurns(player.Turns))) + "\n"
	out += "TravelBonus: +" + strconv.Itoa(int(player.TravelBonus)) + "\n"
	out += "Boat: " + boatStatusSummary(key)
	return out
}

func GetPlayerWealthData(name string) string {
	key := normalizeKey(name)
	if _, ok := players[key]; !ok {
		panic("player not found")
	}
	return "Pearls: " + strconv.Itoa(int(totalPearls(key)))
}

func GetPlayerMapData(name string) string {
	key := normalizeKey(name)
	player, ok := players[key]
	if !ok {
		panic("player not found")
	}
	out := "Name: " + player.Name + "\n"
	out += "PlayerID: " + strconv.Itoa(int(player.ID)) + "\n"
	out += "Position: (" + strconv.Itoa(int(player.Pos.X)) + ", " + strconv.Itoa(int(player.Pos.Y)) + ")"
	return out
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
		companion, exists := collection[id]
		if !exists {
			continue
		}
		out += "- #" + strconv.Itoa(int(companion.ID)) + " " + companion.Species.Name + "\n"
		asset, ok := assets[companion.AssetID]
		if ok {
			out += "  Asset: " + asset.Code + "\n"
			out += "  Status: " + asset.Status + "\n"
		}
		out += "  Profile: bold:" + strconv.Itoa(int(companion.Boldness)) +
			" cautious:" + strconv.Itoa(int(companion.Caution)) +
			" kind:" + strconv.Itoa(int(companion.Kindness)) +
			" soul:" + strconv.Itoa(int(companion.Soul)) + "\n"
		out += "  Found: (" + strconv.Itoa(int(companion.FoundAt.X)) + "," + strconv.Itoa(int(companion.FoundAt.Y)) +
			") turn " + strconv.Itoa(int(companion.FoundTurn)) + "\n"
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
			return describeDiaryEntry(entry)
		}
	}
	return "Diary empty."
}
