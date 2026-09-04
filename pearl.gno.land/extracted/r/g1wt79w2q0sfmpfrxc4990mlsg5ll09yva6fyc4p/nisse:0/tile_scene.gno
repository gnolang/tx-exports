package nisse

import "strconv"

func DescribeTileSceneAt(x uint64, y uint64) string {
	if !inBounds(x, y) {
		panic("tile out of bounds")
	}
	return describeTileSceneBlockAt(Position{X: x, Y: y})
}

func describeTileSceneBlockAt(pos Position) string {
	out := "TileSceneID: tile-" + strconv.Itoa(int(pos.X)) + "-" + strconv.Itoa(int(pos.Y)) + "\n"
	out += "TileScenePlaceName: " + currentPlaceName(pos) + "\n"
	out += "TileSceneTerrain: " + terrainName(GetTile(pos.X, pos.Y)) + "\n"
	out += "TileSceneResources: " + terrainResources(GetTile(pos.X, pos.Y)) + "\n"
	if placeCanBeNamed(pos) {
		out += "TileSceneCanName: yes\n"
	} else {
		out += "TileSceneCanName: no\n"
	}
	out += "TileSceneHouses: " + strconv.Itoa(int(tileBuildCount(pos))) + "\n"
	out += "TileSceneNextBuildCost: " + strconv.Itoa(int(houseBuildCost(pos))) + "\n"
	ids := tileBuildingIDs[placeTileKey(pos)]
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
