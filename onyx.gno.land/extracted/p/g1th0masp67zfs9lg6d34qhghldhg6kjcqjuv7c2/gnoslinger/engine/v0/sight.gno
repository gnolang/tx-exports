package engine

import "gno.land/p/g1th0masp67zfs9lg6d34qhghldhg6kjcqjuv7c2/gnoslinger/hex/v0"

// sightHeight is a character's height for the line of sight (30.32):
// upright, or DOWN unless it lies on an obstacle, where it counts as
// upright.
func sightHeight(board *hex.Board, c *Character) hex.Height {
	if c.Down && !board.Obstacle(c.Hex) {
		return hex.HeightDown
	}
	return hex.HeightUpright
}

// canSee reports whether c has a clear line of sight (rule 31) to its
// target: the character t when t is not nil, wherever it stands and at its
// height, else the hex at, which counts as upright (31.3). blocker names
// the obstacle in the way. The aim zone is checked apart (31.21).
func canSee(board *hex.Board, c *Character, at string, t *Character) (clear bool, blocker string) {
	h := hex.HeightUpright
	if t != nil {
		at, h = t.Hex, sightHeight(board, t)
	}
	return board.LineOfSight(c.Hex, at, sightHeight(board, c), h)
}
