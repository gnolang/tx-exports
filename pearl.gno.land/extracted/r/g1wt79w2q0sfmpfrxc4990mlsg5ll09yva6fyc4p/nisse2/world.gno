package nisse2

import (
	"strconv"
	"strings"

	"gno.land/p/g1wt79w2q0sfmpfrxc4990mlsg5ll09yva6fyc4p/nisse2/book"
	"gno.land/p/g1wt79w2q0sfmpfrxc4990mlsg5ll09yva6fyc4p/nisse2/dice"
	"gno.land/p/g1wt79w2q0sfmpfrxc4990mlsg5ll09yva6fyc4p/nisse2/rules"
	"gno.land/p/g1wt79w2q0sfmpfrxc4990mlsg5ll09yva6fyc4p/nisse2/types"
)

// Stateful world. Lookups go to /p/book and /p/rules.
// Dice seeds are built here from *this* state's player, never from a script.

type Player struct {
	ID          uint64
	Owner       types.Address
	Name        string
	Pos         types.Position
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
	Title     string
	Body      string
}

type Companion struct {
	ID          uint64
	OwnerPlayer string
	Kind        string
	FoundAt     types.Position
	FoundTurn   uint64
	Boldness    uint64
	Caution     uint64
	Kindness    uint64
	Soul        uint64
}

type Boat struct {
	OwnerPlayer string
	Name        string
	Pos         types.Position
	Carried     bool
}

type Building struct {
	ID          uint64
	OwnerPlayer string
	Pos         types.Position
	Sign        string
	BuiltTurn   uint64
}

var players map[string]*Player
var diaries map[string]map[uint64]*DiaryEntry
var companions map[string]map[uint64]*Companion
var boats map[string]*Boat
var pearls map[string]uint64
var buildings map[uint64]*Building
var tileHouses map[string][]uint64
var namedPlaces map[string]string
var latestEncounter map[string]types.EncounterOutcome
var mintCounts map[string]uint64
var nextPlayerID uint64
var nextCompanionID uint64
var nextBuildingID uint64

func init() {
	players = make(map[string]*Player)
	diaries = make(map[string]map[uint64]*DiaryEntry)
	companions = make(map[string]map[uint64]*Companion)
	boats = make(map[string]*Boat)
	pearls = make(map[string]uint64)
	buildings = make(map[uint64]*Building)
	tileHouses = make(map[string][]uint64)
	namedPlaces = make(map[string]string)
	latestEncounter = make(map[string]types.EncounterOutcome)
	mintCounts = make(map[string]uint64)
	nextPlayerID = 1
	nextCompanionID = 1
	nextBuildingID = 1
	seedBookPlaces()
}

func seedBookPlaces() {
	w := book.Width()
	h := book.Height()
	for y := uint64(0); y < h; y++ {
		for x := uint64(0); x < w; x++ {
			if n := book.SeededPlaceName(x, y); n != "" {
				namedPlaces[tileKey(types.Position{X: x, Y: y})] = n
			}
		}
	}
}

func cleanName(value string) string { return strings.TrimSpace(value) }

func normalizeKey(value string) string { return strings.ToLower(cleanName(value)) }

func callerFromCur(cur realm) types.Address {
	return types.Address(cur.Previous().Address().String())
}

func tileKey(pos types.Position) string {
	return strconv.Itoa(int(pos.X)) + "," + strconv.Itoa(int(pos.Y))
}

func placeName(pos types.Position) string {
	if n := namedPlaces[tileKey(pos)]; n != "" {
		return n
	}
	return book.TerrainName(book.Tile(pos.X, pos.Y))
}

func ownedPlayer(cur realm, playerName string) (string, *Player) {
	caller := callerFromCur(cur)
	key := normalizeKey(playerName)
	player, ok := players[key]
	if !ok {
		panic("player not found")
	}
	if player.Owner != caller {
		panic("only the player owner may do this")
	}
	recoverBoat(key, player)
	return key, player
}

func companionCount(key string) uint64 {
	return uint64(len(companions[key]))
}

func heldAggregate(key string) (uint64, uint64, uint64, uint64) {
	var b, c, k, s uint64
	for _, comp := range companions[key] {
		if comp == nil {
			continue
		}
		if comp.Boldness > b {
			b = comp.Boldness
		}
		if comp.Caution > c {
			c = comp.Caution
		}
		if comp.Kindness > k {
			k = comp.Kindness
		}
		if comp.Soul > s {
			s = comp.Soul
		}
	}
	return b, c, k, s
}

func playerSeed(player *Player, key string) string {
	return dice.PlayerSeed(normalizeKey(player.Name), player.Pos.X, player.Pos.Y, player.Turns, companionCount(key))
}

func applyDelta(v *uint64, d int64) {
	if d == 0 {
		return
	}
	if d > 0 {
		*v += uint64(d)
		return
	}
	loss := uint64(-d)
	if *v <= loss {
		*v = 0
		return
	}
	*v -= loss
}

func createDiary(key string, action string, title string, body string) {
	player := players[key]
	if diaries[key] == nil {
		diaries[key] = make(map[uint64]*DiaryEntry)
	}
	id := player.NextEntryID
	player.NextEntryID++
	diaries[key][id] = &DiaryEntry{
		ID:     id,
		Turn:   player.Turns,
		Action: action,
		Place:  placeName(player.Pos),
		Title:  title,
		Body:   body,
	}
	player.DiaryPages++
}

func recoverBoat(key string, player *Player) bool {
	boat := boats[key]
	if boat == nil || boat.Carried {
		return false
	}
	if !types.SameTile(boat.Pos, player.Pos) {
		return false
	}
	boat.Carried = true
	return true
}

func playerOwnsKind(playerName string, kind string) bool {
	key := normalizeKey(playerName)
	for _, c := range companions[key] {
		if c != nil && c.Kind == kind {
			return true
		}
	}
	return false
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
	id := nextPlayerID
	nextPlayerID++
	pos := book.StartPosition()
	players[key] = &Player{
		ID: id, Owner: caller, Name: name, Pos: pos, Level: 1,
		Turns: 0, NextEntryID: 1,
	}
	p := players[key]
	seed := playerSeed(p, key)
	p.Boldness = 10 + dice.D10(seed, "boldness")
	p.Caution = 10 + dice.D10(seed, "caution")
	p.Kindness = 10 + dice.D10(seed, "kindness")
	p.Soul = 10 + dice.D10(seed, "soul")
	pearls[key] = 100
	createDiary(key, "birth", "Day one", "PlayerCreated")
	return name
}

func TravelPlayer(cur realm, playerName string, x uint64, y uint64, attitude string) string {
	key, player := ownedPlayer(cur, playerName)
	attitude = types.NormalizeAttitude(attitude)
	if !book.InBounds(x, y) {
		panic("tile out of bounds")
	}
	dest := types.Position{X: x, Y: y}
	if types.SameTile(player.Pos, dest) {
		panic("player is already on that tile")
	}
	origin := player.Pos
	carries := boats[key] != nil && boats[key].Carried
	plan := rules.PlanTravel(origin, dest, player.TravelBonus, carries)

	if !plan.UseBoat && carries && rules.WaterTravelTile(book.Tile(origin.X, origin.Y)) && plan.LeavesBoat {
		boats[key].Carried = false
		boats[key].Pos = origin
	}

	player.Pos = dest
	if !plan.UseBoat {
		player.TravelBonus = rules.SavedTravelBonus(plan.Budget, plan.Cost)
	}
	recoverBoat(key, player)
	player.Turns++

	title := "A short crossing"
	body := "You travel to " + placeName(player.Pos) + "."
	if plan.UseBoat {
		title = "A coastal sailing"
		body = "You sail to " + placeName(player.Pos) + "."
	}

	cb, cc, ck, cs := heldAggregate(key)
	in := types.EncounterInput{
		Attitude:    attitude,
		PlayerLevel: player.Level,
		Boldness:    player.Boldness,
		Caution:     player.Caution,
		Kindness:    player.Kindness,
		Soul:        player.Soul,
		CompBold:    cb, CompCaution: cc, CompKind: ck, CompSoul: cs,
	}
	seed := playerSeed(player, key)
	outcome, happened := rules.ResolveArrival(seed, book.Tile(player.Pos.X, player.Pos.Y), in)
	if happened {
		applyEncounter(key, player, outcome)
		return outcome.Kind + "_" + outcome.Band
	}
	createDiary(key, "travel", title, body)
	return title
}

func applyEncounter(key string, player *Player, out types.EncounterOutcome) {
	applyDelta(&player.Boldness, out.BoldDelta)
	applyDelta(&player.Caution, out.CautionDelta)
	applyDelta(&player.Kindness, out.KindDelta)
	applyDelta(&player.Soul, out.SoulDelta)
	player.Level += out.LevelGain
	minted := ""
	if out.ShouldMint {
		creature, ok := book.Creature(out.Kind)
		if ok {
			limitHit := creature.MaxMints > 0 && mintCounts[creature.Kind] >= creature.MaxMints
			if !limitHit && !playerOwnsKind(player.Name, creature.Kind) {
				seed := playerSeed(player, key)
				if companions[key] == nil {
					companions[key] = make(map[uint64]*Companion)
				}
				id := nextCompanionID
				nextCompanionID++
				companions[key][id] = &Companion{
					ID: id, OwnerPlayer: player.Name, Kind: creature.Kind,
					FoundAt: player.Pos, FoundTurn: player.Turns,
					Boldness:  dice.Dice(seed, "mint-bold", creature.BoldSides),
					Kindness:  dice.Dice(seed, "mint-kind", creature.KindnessSides),
					Caution:   dice.Dice(seed, "mint-caut", creature.CautSides),
					Soul:      dice.Dice(seed, "mint-soul", creature.SoulSides),
				}
				mintCounts[creature.Kind]++
				minted = creature.Label
			}
		}
	}
	body := "Encounter:" + out.Kind + " Outcome:" + out.Band
	if minted != "" {
		body += " Bonded:" + minted
	}
	createDiary(key, "encounter", out.Kind+"_"+out.Band, body)
	latestEncounter[key] = out
}

func BuyBoat(cur realm, playerName string) string {
	key, player := ownedPlayer(cur, playerName)
	code := book.Tile(player.Pos.X, player.Pos.Y)
	if !rules.CanBuyBoatHere(code) {
		panic("boats can only be bought in fishing villages")
	}
	if boats[key] != nil {
		panic("you already own a boat")
	}
	cost := rules.BoatPearlCost()
	if pearls[key] < cost {
		panic("not enough pearls")
	}
	pearls[key] -= cost
	boats[key] = &Boat{OwnerPlayer: player.Name, Name: "weathered skiff", Pos: player.Pos, Carried: true}
	createDiary(key, "boat", "boat_bought", "Cost:"+strconv.Itoa(int(cost)))
	return "boat_bought"
}

func BuildHouse(cur realm, playerName string) string {
	key, player := ownedPlayer(cur, playerName)
	if !rules.CanBuildOnTile(book.Tile(player.Pos.X, player.Pos.Y)) {
		panic("cannot build on this tile")
	}
	tk := tileKey(player.Pos)
	cost := rules.HouseBuildCost(uint64(len(tileHouses[tk])))
	if pearls[key] < cost {
		panic("not enough pearls")
	}
	pearls[key] -= cost
	id := nextBuildingID
	nextBuildingID++
	buildings[id] = &Building{ID: id, OwnerPlayer: player.Name, Pos: player.Pos, BuiltTurn: player.Turns}
	tileHouses[tk] = append(tileHouses[tk], id)
	createDiary(key, "build", "house_built", "house #"+strconv.Itoa(int(id)))
	return "house #" + strconv.Itoa(int(id))
}

func NameTile(cur realm, playerName string, name string) string {
	key, player := ownedPlayer(cur, playerName)
	tk := tileKey(player.Pos)
	code := book.Tile(player.Pos.X, player.Pos.Y)
	if !book.PlaceCanBeNamed(code, namedPlaces[tk] != "") {
		panic("this tile cannot be named")
	}
	name = cleanName(name)
	if name == "" || len(name) > 40 {
		panic("invalid place name")
	}
	namedPlaces[tk] = name
	createDiary(key, "name place", "A place receives its name", name)
	return name
}

func GetPlayerStatsData(name string) string {
	p, ok := players[normalizeKey(name)]
	if !ok {
		panic("player not found")
	}
	return "Level: " + strconv.Itoa(int(p.Level)) +
		"\nBoldness: " + strconv.Itoa(int(p.Boldness)) +
		"\nCaution: " + strconv.Itoa(int(p.Caution)) +
		"\nKindness: " + strconv.Itoa(int(p.Kindness)) +
		"\nSoul: " + strconv.Itoa(int(p.Soul))
}

func DescribeLatestEncounterResult(playerName string) string {
	key := normalizeKey(playerName)
	out, ok := latestEncounter[key]
	if !ok {
		return "No encounter yet."
	}
	return out.Kind + " " + out.Band + " roll:" + strconv.Itoa(int(out.Roll)) +
		" total:" + strconv.Itoa(int(out.PlayerTotal)) + " target:" + strconv.Itoa(int(out.Target))
}

func GetTile(x uint64, y uint64) uint8 { return book.Tile(x, y) }
