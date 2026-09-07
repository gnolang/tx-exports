package nisse2

import (
	"strconv"

	"gno.land/p/g1wt79w2q0sfmpfrxc4990mlsg5ll09yva6fyc4p/nisse2/book"
	"gno.land/p/g1wt79w2q0sfmpfrxc4990mlsg5ll09yva6fyc4p/nisse2/rules"
	"gno.land/p/g1wt79w2q0sfmpfrxc4990mlsg5ll09yva6fyc4p/nisse2/types"
)

func SetHouseSign(cur realm, playerName string, buildingID uint64, text string) string {
	key, player := ownedPlayer(cur, playerName)
	b := buildings[buildingID]
	if b == nil {
		panic("house not found")
	}
	if normalizeKey(b.OwnerPlayer) != key {
		panic("only the house owner may set the sign")
	}
	if !types.SameTile(player.Pos, b.Pos) {
		panic("you must be at the house to set its sign")
	}
	text = cleanName(text)
	if len(text) > 120 {
		panic("sign text must be 120 characters or fewer")
	}
	b.Sign = text
	label := text
	if label == "" {
		label = "(cleared)"
	}
	createDiary(key, "sign", "house_sign", "House #"+strconv.Itoa(int(buildingID))+"\nSign:"+label)
	if text == "" {
		return "sign cleared on house #" + strconv.Itoa(int(buildingID))
	}
	return "sign set on house #" + strconv.Itoa(int(buildingID))
}

func DescribeTileBuildings(x uint64, y uint64) string {
	if !book.InBounds(x, y) {
		panic("tile out of bounds")
	}
	pos := types.Position{X: x, Y: y}
	ids := tileHouses[tileKey(pos)]
	out := "Tile (" + strconv.Itoa(int(x)) + "," + strconv.Itoa(int(y)) + ")\n"
	out += "Houses: " + strconv.Itoa(int(len(ids))) + "\n"
	out += "NextBuildCost: " + strconv.Itoa(int(rules.HouseBuildCost(uint64(len(ids))))) + " pearls\n"
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

func DescribeTileSceneAt(x uint64, y uint64) string {
	if !book.InBounds(x, y) {
		panic("tile out of bounds")
	}
	pos := types.Position{X: x, Y: y}
	code := book.Tile(x, y)
	tk := tileKey(pos)
	named := namedPlaces[tk] != ""
	out := "TileSceneID: tile-" + strconv.Itoa(int(x)) + "-" + strconv.Itoa(int(y)) + "\n"
	out += "TileScenePlaceName: " + placeName(pos) + "\n"
	out += "TileSceneTerrain: " + book.TerrainName(code) + "\n"
	out += "TileSceneResources: " + book.TerrainResources(code) + "\n"
	if book.PlaceCanBeNamed(code, named) {
		out += "TileSceneCanName: yes\n"
	} else {
		out += "TileSceneCanName: no\n"
	}
	ids := tileHouses[tk]
	out += "TileSceneHouses: " + strconv.Itoa(int(len(ids))) + "\n"
	out += "TileSceneNextBuildCost: " + strconv.Itoa(int(rules.HouseBuildCost(uint64(len(ids))))) + "\n"
	for _, id := range ids {
		b := buildings[id]
		if b == nil {
			continue
		}
		out += "House #" + strconv.Itoa(int(b.ID)) + " owner:" + b.OwnerPlayer
		if b.Sign != "" {
			out += " sign:\"" + b.Sign + "\""
		}
		out += "\n"
	}
	return out
}
