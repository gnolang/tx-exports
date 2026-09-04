package nisse

import "strconv"

var namedFrontierPlaces map[string]string

func init() {
	namedFrontierPlaces = make(map[string]string)
	seedPlaceName(Position{X: 5, Y: 4}, "Agerre")
	seedPlaceName(Position{X: 6, Y: 4}, "Aldazabal")
	seedPlaceName(Position{X: 2, Y: 5}, "Altzibar")
	seedPlaceName(Position{X: 13, Y: 5}, "Melkern")
	seedPlaceName(Position{X: 14, Y: 5}, "Arregi")
	seedPlaceName(Position{X: 13, Y: 6}, "Florida")
}

func placeTileKey(pos Position) string {
	return strconv.Itoa(int(pos.X)) + "," + strconv.Itoa(int(pos.Y))
}

func seedPlaceName(pos Position, name string) {
	if name == "" {
		return
	}
	namedFrontierPlaces[placeTileKey(pos)] = name
}

func frontierPlaceName(pos Position) string {
	return namedFrontierPlaces[placeTileKey(pos)]
}

func currentPlaceName(pos Position) string {
	return frontierPlaceName(pos)
}

func placeCanBeNamed(pos Position) bool {
	if currentPlaceName(pos) != "" {
		return false
	}

	switch terrainName(GetTile(pos.X, pos.Y)) {
	case "coastal", "moor", "forest", "hills", "mountain", "meadow":
		return true
	default:
		return false
	}
}

func unnamedPlaceLabel(pos Position) string {
	switch terrainName(GetTile(pos.X, pos.Y)) {
	case "coastal":
		return "Unnamed shore"
	case "moor":
		return "Unnamed moor"
	case "meadow":
		return "Unnamed meadow"
	case "forest":
		return "Unnamed forest place"
	case "hills":
		return "Unnamed hill place"
	case "mountain":
		return "Unnamed mountain place"
	default:
		return terrainName(GetTile(pos.X, pos.Y))
	}
}

func NameTile(cur realm, playerName string, name string) string {
	key, player, _ := ownedPlayer(cur, playerName)
	pos := player.Pos

	if !placeCanBeNamed(pos) {
		panic("this tile cannot be named")
	}

	name = cleanName(name)
	if name == "" {
		panic("place name is required")
	}
	if len(name) > 40 {
		panic("place name must be 40 characters or fewer")
	}

	namedFrontierPlaces[placeTileKey(pos)] = name
	createDiaryEntry(
		key,
		"name place",
		name,
		"day",
		"A place receives its name",
		"You stand at ("+strconv.Itoa(int(pos.X))+", "+strconv.Itoa(int(pos.Y))+") and give this frontier place its name: "+name+".",
	)
	return name
}
