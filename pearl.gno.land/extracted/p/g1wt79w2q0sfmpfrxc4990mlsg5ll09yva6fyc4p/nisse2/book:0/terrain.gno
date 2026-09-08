package book

import "gno.land/p/g1wt79w2q0sfmpfrxc4990mlsg5ll09yva6fyc4p/nisse2/types"

var terrain [][]uint8
var startCity types.Position

func init() {
	// Frozen atlas — the map never changes after addpkg.
	terrain = [][]uint8{
		{0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
		{0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 0, 1, 1, 1, 1, 0, 0, 0},
		{0, 0, 0, 1, 13, 3, 3, 2, 2, 2, 11, 3, 3, 3, 1, 1, 0, 0},
		{0, 1, 1, 1, 3, 3, 3, 12, 3, 10, 3, 3, 7, 3, 2, 1, 1, 0},
		{0, 1, 11, 3, 3, 5, 5, 10, 3, 10, 15, 3, 3, 3, 10, 4, 1, 0},
		{0, 8, 5, 3, 15, 12, 10, 7, 10, 10, 3, 3, 3, 5, 5, 1, 1, 0},
		{0, 1, 3, 3, 3, 4, 10, 3, 10, 4, 11, 2, 2, 5, 14, 1, 0, 0},
		{0, 1, 1, 3, 11, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 0, 0, 0},
		{0, 0, 1, 1, 0, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0},
		{0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
	}
	startCity = types.Position{X: 14, Y: 6}
}

func Height() uint64 { return uint64(len(terrain)) }

func Width() uint64 {
	if len(terrain) == 0 {
		return 0
	}
	return uint64(len(terrain[0]))
}

func InBounds(x uint64, y uint64) bool {
	return y < Height() && x < Width()
}

func Tile(x uint64, y uint64) uint8 {
	if !InBounds(x, y) {
		panic("tile out of bounds")
	}
	return terrain[y][x]
}

func IsLand(x uint64, y uint64) bool {
	return InBounds(x, y) && terrain[y][x] != 0
}

func StartPosition() types.Position { return startCity }

func TerrainName(code uint8) string {
	switch code {
	case 0:
		return "ocean"
	case 1:
		return "coastal"
	case 2:
		return "moor"
	case 3:
		return "forest"
	case 4:
		return "hills"
	case 5:
		return "farm"
	case 6:
		return "village"
	case 7:
		return "monastery"
	case 8:
		return "harbor"
	case 9:
		return "city"
	case 10:
		return "mountain"
	case 11:
		return "fishing_village"
	case 12:
		return "mountain_village"
	case 13:
		return "city_north"
	case 14:
		return "city_south"
	case 15:
		return "meadow"
	default:
		return "unknown"
	}
}

func TerrainResources(code uint8) string {
	switch TerrainName(code) {
	case "forest":
		return "berries,nuts"
	case "mountain":
		return "gems,gold"
	case "coastal", "harbor", "fishing_village":
		return "flint,shells"
	case "hills":
		return "iron,berries"
	case "meadow", "moor":
		return "herbs,vegetables"
	case "farm":
		return "milk,eggs"
	default:
		return ""
	}
}

func SeededPlaceName(x uint64, y uint64) string {
	if x == 5 && y == 4 {
		return "Agerre"
	}
	if x == 6 && y == 4 {
		return "Aldazabal"
	}
	if x == 2 && y == 5 {
		return "Altzibar"
	}
	if x == 13 && y == 5 {
		return "Melkern"
	}
	if x == 14 && y == 5 {
		return "Arregi"
	}
	if x == 13 && y == 6 {
		return "Florida"
	}
	return ""
}

func PlaceCanBeNamed(code uint8, alreadyNamed bool) bool {
	if alreadyNamed {
		return false
	}
	switch TerrainName(code) {
	case "coastal", "moor", "forest", "hills", "mountain", "meadow":
		return true
	default:
		return false
	}
}
