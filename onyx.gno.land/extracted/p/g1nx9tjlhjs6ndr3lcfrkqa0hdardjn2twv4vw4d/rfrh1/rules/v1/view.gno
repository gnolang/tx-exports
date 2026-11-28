package rules

// View is what a bot sees: a read-only window on the game, always from side
// A's perspective. For side B every coordinate and direction is rotated 180
// degrees, so the same bot code works on both sides and the two sides are
// exactly symmetric.
type View struct {
	g    *Game
	side int
}

// W and H are the board size.
func (v View) W() int { return v.g.m.w }
func (v View) H() int { return v.g.m.h }

// Turn is the number of turns already played.
func (v View) Turn() int { return v.g.turn }

func (v View) toBoard(x, y int) (int, int) {
	if v.side == SideB {
		return v.g.m.w - 1 - x, v.g.m.h - 1 - y
	}
	return x, y
}

func (v View) fromBoard(p Point) Point {
	if v.side == SideB {
		return v.g.m.rot(p)
	}
	return p
}

// Free reports whether a cell is inside the board and empty.
func (v View) Free(x, y int) bool {
	g := v.g
	w, h := g.m.w, g.m.h
	if v.side == SideB {
		x, y = w-1-x, h-1-y
	}
	if x < 0 || y < 0 || x >= w || y >= h {
		return false
	}
	return g.cells[y*w+x] == Empty
}

// Mine reports whether a cell holds this bot's own trail.
func (v View) Mine(x, y int) bool {
	bx, by := v.toBoard(x, y)
	return v.g.Cell(bx, by) == TrailA+v.side
}

// Theirs reports whether a cell holds the opponent's trail.
func (v View) Theirs(x, y int) bool {
	bx, by := v.toBoard(x, y)
	return v.g.Cell(bx, by) == TrailA+1-v.side
}

// Me and Opp return the two heads.
func (v View) Me() Point  { return v.fromBoard(v.g.head[v.side]) }
func (v View) Opp() Point { return v.fromBoard(v.g.head[1-v.side]) }

// Heading is the direction this ribbon moved last turn (its start facing on
// turn 0), in the bot's own frame.
func (v View) Heading() Dir {
	f := v.g.facing[v.side]
	if v.side == SideB {
		return f.Opposite()
	}
	return f
}

// Reach counts the empty cells reachable from (x, y) through empty cells,
// including (x, y) itself, and stops counting at limit. It returns 0 if
// (x, y) is not empty. It is the cheap way for a bot to measure room: it
// runs on the board directly with no allocations.
func (v View) Reach(x, y, limit int) int {
	bx, by := v.toBoard(x, y)
	return v.g.reach(bx, by, limit)
}

// FreeDirs returns how many of the four neighbours of (x, y) are empty.
func (v View) FreeDirs(x, y int) int {
	n := 0
	if v.Free(x+1, y) {
		n++
	}
	if v.Free(x-1, y) {
		n++
	}
	if v.Free(x, y+1) {
		n++
	}
	if v.Free(x, y-1) {
		n++
	}
	return n
}
