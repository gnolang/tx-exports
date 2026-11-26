package cube3x3

// Cube stores nine row-major facelets per face in U, R, F, D, L, B order.
// Colors 0 through 5 are white, red, green, yellow, orange and blue.
type Cube [54]uint8

// Move is a face turn, wide turn or cube rotation. Mod is 1 for clockwise,
// 2 for a half turn and 3 for counterclockwise.
type Move struct {
	Base uint8
	Mod  uint8
}

// Move bases. X, Y and Z represent x, y and z in algorithm notation.
const (
	U uint8 = iota
	D
	L
	R
	F
	B
	Uw
	Dw
	Lw
	Rw
	Fw
	Bw
	X
	Y
	Z
)

const (
	upCenter    = 4
	rightCenter = 13
	frontCenter = 22
	downCenter  = 31
	leftCenter  = 40
	backCenter  = 49
)

// Each clockwise quarter turn shifts stickers one position forward in its
// disjoint cycles. A half turn shifts two positions and an inverse three.
var turnCycles = [Z + 1][][4]uint8{
	U: {
		{0, 2, 8, 6}, {1, 5, 7, 3}, {9, 18, 36, 45}, {10, 19, 37, 46}, {11, 20, 38, 47},
	},
	D: {
		{15, 51, 42, 24}, {16, 52, 43, 25}, {17, 53, 44, 26}, {27, 29, 35, 33}, {28, 32, 34, 30},
	},
	L: {
		{0, 18, 27, 53}, {3, 21, 30, 50}, {6, 24, 33, 47}, {36, 38, 44, 42}, {37, 41, 43, 39},
	},
	R: {
		{2, 51, 29, 20}, {5, 48, 32, 23}, {8, 45, 35, 26}, {9, 11, 17, 15}, {10, 14, 16, 12},
	},
	F: {
		{6, 9, 29, 44}, {7, 12, 28, 41}, {8, 15, 27, 38}, {18, 20, 26, 24}, {19, 23, 25, 21},
	},
	B: {
		{0, 42, 35, 11}, {1, 39, 34, 14}, {2, 36, 33, 17}, {45, 47, 53, 51}, {46, 50, 52, 48},
	},
	X: {
		{0, 53, 27, 18}, {1, 52, 28, 19}, {2, 51, 29, 20}, {3, 50, 30, 21},
		{4, 49, 31, 22}, {5, 48, 32, 23}, {6, 47, 33, 24}, {7, 46, 34, 25},
		{8, 45, 35, 26}, {9, 11, 17, 15}, {10, 14, 16, 12}, {36, 42, 44, 38},
		{37, 39, 43, 41},
	},
	Y: {
		{0, 2, 8, 6}, {1, 5, 7, 3}, {9, 18, 36, 45}, {10, 19, 37, 46},
		{11, 20, 38, 47}, {12, 21, 39, 48}, {13, 22, 40, 49}, {14, 23, 41, 50},
		{15, 24, 42, 51}, {16, 25, 43, 52}, {17, 26, 44, 53}, {27, 33, 35, 29},
		{28, 30, 34, 32},
	},
	Z: {
		{0, 11, 35, 42}, {1, 14, 34, 39}, {2, 17, 33, 36}, {3, 10, 32, 43},
		{4, 13, 31, 40}, {5, 16, 30, 37}, {6, 9, 29, 44}, {7, 12, 28, 41},
		{8, 15, 27, 38}, {18, 20, 26, 24}, {19, 23, 25, 21}, {45, 51, 53, 47},
		{46, 48, 52, 50},
	},
}

// The opposite face and parallel cube rotation commute. Their combination
// cancels the turn of the opposite layer while moving the other two layers.
var wideTurns = [...]struct {
	oppositeFace    uint8
	rotation        uint8
	reverseRotation bool
}{
	Uw - Uw: {D, Y, false},
	Dw - Uw: {U, Y, true},
	Lw - Uw: {R, X, true},
	Rw - Uw: {L, X, false},
	Fw - Uw: {B, Z, false},
	Bw - Uw: {F, Z, true},
}

// SolvedCube returns the solved state with white on U and green on F.
func SolvedCube() Cube {
	var c Cube
	for i := range c {
		c[i] = uint8(i / 9)
	}
	return c
}

// CubeToFaceletString encodes each color as its solved face letter.
// A facelet outside the six-color palette is encoded as '?'.
func CubeToFaceletString(c Cube) string {
	const colors = "URFDLB"
	var letters [54]byte
	for i, color := range c {
		if color >= uint8(len(colors)) {
			letters[i] = '?'
			continue
		}
		letters[i] = colors[color]
	}
	return string(letters[:])
}

// ApplyMove returns the state after a move. An invalid base or modifier leaves
// the cube unchanged.
func ApplyMove(c Cube, m Move) Cube {
	if m.Base > Z || m.Mod < 1 || m.Mod > 3 {
		return c
	}
	if m.Base >= Uw && m.Base <= Bw {
		wide := wideTurns[m.Base-Uw]
		c = applyTurn(c, wide.oppositeFace, m.Mod)
		if wide.reverseRotation {
			m.Mod = 4 - m.Mod
		}
		return applyTurn(c, wide.rotation, m.Mod)
	}
	return applyTurn(c, m.Base, m.Mod)
}

func applyTurn(c Cube, base, mod uint8) Cube {
	// Each destination reads the sticker mod steps earlier in its cycle.
	back := 4 - mod
	for _, cycle := range turnCycles[base] {
		c[cycle[0]], c[cycle[1]], c[cycle[2]], c[cycle[3]] =
			c[cycle[back]], c[cycle[(back+1)%4]], c[cycle[(back+2)%4]], c[cycle[(back+3)%4]]
	}
	return c
}

// ApplyMoves applies moves in the order given.
func ApplyMoves(c Cube, moves []Move) Cube {
	for _, move := range moves {
		c = ApplyMove(c, move)
	}
	return c
}

// IsSolved reports whether c is a solved cube in any orientation.
func IsSolved(c Cube) bool {
	for i, color := range c {
		if color != c[(i/9)*9+4] {
			return false
		}
	}
	return NormalizeOrientation(c) == SolvedCube()
}

// NormalizeOrientation rotates a cube to white U and green F. If the centers
// cannot be brought to those positions, it returns the input unchanged.
func NormalizeOrientation(c Cube) Cube {
	oriented := c
	// Move White to U with one rotation about X or Z.
	switch {
	case c[upCenter] == 0:
	case c[frontCenter] == 0:
		oriented = applyTurn(c, X, 1)
	case c[downCenter] == 0:
		oriented = applyTurn(c, X, 2)
	case c[backCenter] == 0:
		oriented = applyTurn(c, X, 3)
	case c[leftCenter] == 0:
		oriented = applyTurn(c, Z, 1)
	case c[rightCenter] == 0:
		oriented = applyTurn(c, Z, 3)
	default:
		return c
	}

	// A Y rotation keeps White on U and brings Green to F.
	switch {
	case oriented[frontCenter] == 2:
		return oriented
	case oriented[rightCenter] == 2:
		return applyTurn(oriented, Y, 1)
	case oriented[backCenter] == 2:
		return applyTurn(oriented, Y, 2)
	case oriented[leftCenter] == 2:
		return applyTurn(oriented, Y, 3)
	default:
		return c
	}
}
