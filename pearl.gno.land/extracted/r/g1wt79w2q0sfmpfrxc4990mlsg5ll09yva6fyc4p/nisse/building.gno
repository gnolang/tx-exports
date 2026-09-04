package nisse

import "strconv"

// Houses on tiles. Cost rises with popularity of the plot.

type Building struct {
	ID          uint64
	OwnerPlayer string
	Pos         Position
	Sign        string // shop / sign text
	BuiltTurn   uint64
}

var buildings map[uint64]*Building
var tileBuildingIDs map[string][]uint64
var nextBuildingID uint64

const baseHouseCost uint64 = 20

func init() {
	buildings = make(map[uint64]*Building)
	tileBuildingIDs = make(map[string][]uint64)
	nextBuildingID = 1
}

func tileBuildCount(pos Position) uint64 {
	return uint64(len(tileBuildingIDs[placeTileKey(pos)]))
}

func houseBuildCost(pos Position) uint64 {
	// 20 pearls + 1 pearl for every building already on the tile
	return baseHouseCost + tileBuildCount(pos)
}

func canBuildOnTile(pos Position) bool {
	if !inBounds(pos.X, pos.Y) {
		return false
	}
	// No building on open ocean
	return GetTile(pos.X, pos.Y) != 0
}

func appendTileBuilding(pos Position, id uint64) {
	key := placeTileKey(pos)
	tileBuildingIDs[key] = append(tileBuildingIDs[key], id)
}

// BuildHouse raises a house on the caller's current tile.
// Cost = 20 + (number of houses already on this tile).
func BuildHouse(cur realm, playerName string) string {
	key, player, _ := ownedPlayer(cur, playerName)
	pos := player.Pos
	if !canBuildOnTile(pos) {
		panic("cannot build on this tile")
	}
	cost := houseBuildCost(pos)
	if totalPearls(key) < cost {
		panic("not enough pearls to build (need " + strconv.Itoa(int(cost)) + ")")
	}

	spendPearls(key, cost, "Built a house for "+strconv.Itoa(int(cost))+" pearls.")
	id := nextBuildingID
	nextBuildingID++
	b := &Building{
		ID:          id,
		OwnerPlayer: player.Name,
		Pos:         pos,
		Sign:        "",
		BuiltTurn:   player.Turns,
	}
	buildings[id] = b
	appendTileBuilding(pos, id)

	place := placeName(pos)
	body := "Built house #" + strconv.Itoa(int(id)) + "\n"
	body += "Cost:" + strconv.Itoa(int(cost)) + " pearls\n"
	body += "TileHouses:" + strconv.Itoa(int(tileBuildCount(pos))) + "\n"
	body += "Place:" + place
	createDiaryEntry(key, "build", place, "day", "house_built", body)
	return "house #" + strconv.Itoa(int(id)) + " built for " + strconv.Itoa(int(cost)) + " pearls"
}

// SetHouseSign sets the shop/sign text on a house you own.
// You must stand on the house tile.
func SetHouseSign(cur realm, playerName string, buildingID uint64, text string) string {
	key, player, _ := ownedPlayer(cur, playerName)
	b := buildings[buildingID]
	if b == nil {
		panic("house not found")
	}
	if normalizeKey(b.OwnerPlayer) != key {
		panic("only the house owner may set the sign")
	}
	if !sameTile(player.Pos, b.Pos) {
		panic("you must be at the house to set its sign")
	}
	text = cleanName(text)
	if len(text) > 120 {
		panic("sign text must be 120 characters or fewer")
	}
	b.Sign = text
	place := placeName(player.Pos)
	label := text
	if label == "" {
		label = "(cleared)"
	}
	createDiaryEntry(key, "sign", place, "day", "house_sign", "House #"+strconv.Itoa(int(buildingID))+"\nSign:"+label)
	if text == "" {
		return "sign cleared on house #" + strconv.Itoa(int(buildingID))
	}
	return "sign set on house #" + strconv.Itoa(int(buildingID))
}

func DescribeTileBuildings(x uint64, y uint64) string {
	if !inBounds(x, y) {
		panic("tile out of bounds")
	}
	pos := Position{X: x, Y: y}
	ids := tileBuildingIDs[placeTileKey(pos)]
	out := "Tile (" + strconv.Itoa(int(x)) + "," + strconv.Itoa(int(y)) + ")\n"
	out += "Houses: " + strconv.Itoa(int(len(ids))) + "\n"
	out += "NextBuildCost: " + strconv.Itoa(int(houseBuildCost(pos))) + " pearls\n"
	if len(ids) == 0 {
		out += "No houses here."
		return out
	}
	for _, id := range ids {
		b := buildings[id]
		if b == nil {
			continue
		}
		out += "- #" + strconv.Itoa(int(b.ID)) + " owner:" + b.OwnerPlayer
		if b.Sign != "" {
			out += " sign:\"" + b.Sign + "\""
		} else {
			out += " sign:(none)"
		}
		out += "\n"
	}
	return out
}

func ListPlayerHouses(playerName string) string {
	key := normalizeKey(playerName)
	player, ok := players[key]
	if !ok {
		panic("player not found")
	}
	out := "Houses owned by " + player.Name + "\n"
	count := 0
	for id := uint64(1); id < nextBuildingID; id++ {
		b := buildings[id]
		if b == nil || normalizeKey(b.OwnerPlayer) != key {
			continue
		}
		count++
		out += "- #" + strconv.Itoa(int(b.ID)) +
			" @ (" + strconv.Itoa(int(b.Pos.X)) + "," + strconv.Itoa(int(b.Pos.Y)) + ")"
		if b.Sign != "" {
			out += " \"" + b.Sign + "\""
		}
		out += "\n"
	}
	if count == 0 {
		out += "None."
	}
	return out
}
