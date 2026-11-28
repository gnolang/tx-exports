package sim

// Tile bytes. Monster glyphs appear only in source grids; they are stored as floor.
const (
	TFloor   uint8 = '.'
	TWall    uint8 = '#'
	TPit     uint8 = '~'
	TSpikes  uint8 = '^'
	TCrumble uint8 = '%'
	TPlate   uint8 = '_'
	TGate    uint8 = '|'
	TChest   uint8 = 'C'
	TStart   uint8 = '@'
	TExit    uint8 = 'E'
)

const (
	MinW, MinH, MaxW, MaxH = 7, 7, 20, 14
	MaxTiles               = 280
	MaxOcc                 = (MaxW + 2) * (MaxH + 2) // grid plus a 1-tile border
	MaxMonsters            = 16
	MaxProjs               = 8
	MaxBeats               = 240
	MaxGates               = 8 // gate toggles loop over every gate
	MaxPlates              = 4
)

const (
	KSlime    uint8 = 1
	KArcher   uint8 = 2
	KBrute    uint8 = 3
	KGargoyle uint8 = 4
)

const (
	ObjExit uint8 = 0
	ObjSlay uint8 = 1
)

// Mon is a monster's spawn data.
type Mon struct {
	Kind   uint8
	X, Y   int8
	HP     int8
	Facing uint8
	Phase  uint8
}

// Map is a parsed room. Tiles is indexed y*W + x.
type Map struct {
	W, H           uint8
	Tiles          [MaxTiles]uint8
	StartX, StartY int8
	Mons           [MaxMonsters]Mon
	NMons          uint8
	Obj            uint8
	HasChest       bool
}

// Glyph classes for Parse and Validate, one table read per byte: cTile marks a
// tile glyph, cHazard a hazard tile, and the low bits hold a monster glyph's kind.
const (
	cTile   uint8 = 0x80
	cHazard uint8 = 0x40
	cKind   uint8 = 0x07
)

var glyphClass = [256]uint8{
	TFloor: cTile, TWall: cTile, TChest: cTile, TStart: cTile, TExit: cTile,
	TPit: cTile | cHazard, TSpikes: cTile | cHazard, TCrumble: cTile | cHazard,
	TPlate: cTile | cHazard, TGate: cTile | cHazard,
	's': KSlime, 'a': KArcher, 'b': KBrute, 'g': KGargoyle,
}

func kindForGlyph(c byte) uint8 {
	return glyphClass[c] & cKind
}

func hpForKind(k uint8) int8 {
	switch k {
	case KSlime, KArcher:
		return 1
	case KBrute:
		return 2
	}
	return 0
}

func isTileGlyph(c byte) bool {
	return glyphClass[c]&cTile != 0
}

func isHazard(c uint8) bool {
	return glyphClass[c]&cHazard != 0
}
