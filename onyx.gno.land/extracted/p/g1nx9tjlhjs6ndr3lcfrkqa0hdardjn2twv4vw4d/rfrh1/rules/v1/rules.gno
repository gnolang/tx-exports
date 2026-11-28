// Package rules is the pure rule book of Ribbonfight, a two-player grid duel.
//
// Each player is a ribbon that moves one cell per turn and leaves a solid
// trail. Moving into a wall, an obstacle, any trail, or the cell the other
// head enters at the same time kills the ribbon. Both moves of a turn resolve
// simultaneously.
//
// The package has no chain imports: no address, no height, no clock. A game
// is fully described by its map and its move string, so everything else
// (the board at any turn, the winner, the end reason) is derived by replay.
package rules

// Dir is a direction. Bots return one per turn.
type Dir uint8

const (
	Up Dir = iota
	Right
	Down
	Left
)

// crashed is the move symbol recorded when a bot panics or returns an
// invalid direction.
const crashed = 4

var (
	dx = [4]int{0, 1, 0, -1}
	dy = [4]int{-1, 0, 1, 0}
)

// Valid reports whether d is one of the four directions.
func (d Dir) Valid() bool { return d <= Left }

// Opposite returns the reverse direction.
func (d Dir) Opposite() Dir { return (d + 2) % 4 }

// String returns u, r, d or l.
func (d Dir) String() string {
	if !d.Valid() {
		return "?"
	}
	return string("urdl"[d])
}

// ParseDir parses u, r, d or l.
func ParseDir(c byte) (Dir, bool) {
	switch c {
	case 'u':
		return Up, true
	case 'r':
		return Right, true
	case 'd':
		return Down, true
	case 'l':
		return Left, true
	}
	return 0, false
}

// Point is a board cell. (0, 0) is the top-left corner.
type Point struct {
	X, Y int
}

// Step returns the neighbour of p in direction d.
func (p Point) Step(d Dir) Point {
	return Point{p.X + dx[d&3], p.Y + dy[d&3]}
}

// Side identifies a player.
const (
	SideA = 0
	SideB = 1
)

// Winner values of a Result.
const (
	Draw  = 0
	WinA  = 1
	WinB  = 2
	going = -1
)

// Death causes.
const (
	Alive    = 0
	HitWall  = 1 // left the board or hit an obstacle
	HitTrail = 2 // hit a trail (either ribbon)
	HitHead  = 3 // both heads entered the same cell
	Crashed  = 4 // the bot panicked or returned an invalid direction
)

// Bot is a ribbon's brain. It is called once per turn with a read-only view
// in which it always plays from side A's perspective (side B's view is the
// board rotated 180 degrees). It must be deterministic for the league to be
// fair, which is automatic for a function in a /p/ package.
type Bot func(v View) Dir
