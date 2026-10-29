package engine

import "gno.land/p/g1th0masp67zfs9lg6d34qhghldhg6kjcqjuv7c2/gnoslinger/hex/v0"

// The showdown's SET UP (rules 3.4 and 29.2; [H3]): each character has its
// own hexes to set up in, as a showdown's SET UP assigns them (showdown 1,
// Gunfight, lines its two sides up inside the corral; this one puts up to
// four around its middle). The seats take the characters in order: the creator is
// the first, each player joining the next. Nobody is alerted (29.21): all
// start upright with the Colt holstered, facing any direction.

// CharSetup is where a character of the showdown sets up: the hexes it may
// stand in, and the way it faces unless its player turns it.
type CharSetup struct {
	Char   string
	Hexes  []string
	Facing hex.Dir
}

// Setups is the showdown played, one character per seat in seat order,
// each a side of its own, around the middle of the corral: the Marshal on
// the west side in D5-D7, E6 and E7, the Kid on the east side in H5-H7, G6
// and G7, Reb to the south in E8, F7, F8 and G8, Yankee to the north in
// E5, F5, F4 and G5. They face
// the middle: a flat-top grid has no west or east, so the Marshal looks
// south-east and the Kid north-west; Reb looks north, Yankee south. A
// character with no entry is not in the showdown; a game of n seats uses
// the first n.
var Setups = []CharSetup{
	{Char: "marshal", Hexes: []string{"A-D5", "A-D6", "A-D7", "A-E6", "A-E7"}, Facing: hex.SE},
	{Char: "the_kid", Hexes: []string{"A-H5", "A-H6", "A-H7", "A-G6", "A-G7"}, Facing: hex.NW},
	{Char: "reb", Hexes: []string{"A-E8", "A-F7", "A-F8", "A-G8"}, Facing: hex.N},
	{Char: "yankee", Hexes: []string{"A-E5", "A-F5", "A-F4", "A-G5"}, Facing: hex.S},
}

// SeatChar is the character of a seat, "" for a seat the showdown does not have.
func SeatChar(seat int) string {
	if seat < 0 || seat >= len(Setups) {
		return ""
	}
	return Setups[seat].Char
}

// SetupOf returns the set up of a character, nil when it is not in the showdown.
func SetupOf(charKey string) *CharSetup {
	for i := range Setups {
		if Setups[i].Char == charKey {
			return &Setups[i]
		}
	}
	return nil
}

// ShowdownChars lists the characters of the showdown, seats in order.
func ShowdownChars() []string {
	out := make([]string, len(Setups))
	for i, s := range Setups {
		out[i] = s.Char
	}
	return out
}

// CanSetUp reports whether charKey may set up in hex id: one of its hexes.
func CanSetUp(charKey, id string) bool {
	s := SetupOf(charKey)
	if s == nil {
		return false
	}
	for _, h := range s.Hexes {
		if h == id {
			return true
		}
	}
	return false
}

// SetUp stands seat p's character upright in hex id facing f; the rest of
// its sheet is left as it is.
func (s *State) SetUp(p int, id string, f hex.Dir) {
	s.Chars[p].Hex = id
	s.Chars[p].Facing = f
	s.Chars[p].Down = false
}
