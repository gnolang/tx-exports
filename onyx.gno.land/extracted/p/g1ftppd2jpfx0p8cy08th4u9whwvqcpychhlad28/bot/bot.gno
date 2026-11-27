// Package bot is everything a bot author needs: what a bot sees each turn,
// the moves it can make, and helpers for finding its way around the board.
//
// A bot is either a type with a Move method (it can live in its own realm and
// keep memory between turns) or a plain Strategy function.
package bot

const (
	Size  = 9  // the board is Size x Size
	Turns = 50 // turns per match
)

// Pos is a square on the board. X grows to the right, Y grows downwards.
type Pos struct{ X, Y int }

// Action is what a bot does on one turn.
type Action int

const (
	Stay   Action = iota // do nothing
	Up                   // move one square up
	Down                 // move one square down
	Left                 // move one square left
	Right                // move one square right
	Attack               // steal one coin from an adjacent enemy
	Defend               // block an attack this turn
)

var actionNames = []string{"stay", "up", "down", "left", "right", "attack", "defend"}

// Valid reports whether a is one of the defined actions.
func (a Action) Valid() bool { return a >= Stay && a <= Defend }

func (a Action) String() string {
	if !a.Valid() {
		return "invalid"
	}
	return actionNames[a]
}

// State is what a bot sees on its turn. It is a fresh copy every turn, so
// changing it has no effect on the real match.
type State struct {
	Match     int    // match id, so bots with memory can tell matches apart
	EnemyBot  string // the opponent's registered name, so bots can keep notes on it
	Turn      int // 0 .. Turns-1
	Me        Pos
	Enemy     Pos
	MyGold    int
	EnemyGold int
	Coins     []Pos  // coins still on the board
	MyLast    Action // what this bot did last turn (Stay on turn 0)
	EnemyLast Action // what the enemy did last turn (Stay on turn 0)
}

// Bot is a bot with a Move method. Implement it on a type in your own realm
// to keep memory between turns.
type Bot interface {
	Move(s State) Action
}

// Strategy is a bot written as a plain function, usually in a /p/ package.
type Strategy func(s State) Action

func abs(n int) int {
	if n < 0 {
		return -n
	}
	return n
}

// Dist is the number of moves between a and b.
func Dist(a, b Pos) int { return abs(a.X-b.X) + abs(a.Y-b.Y) }

// Adjacent reports whether a and b are one move apart, which is attack range.
func Adjacent(a, b Pos) bool { return Dist(a, b) == 1 }

// OnBoard reports whether p is inside the board.
func OnBoard(p Pos) bool { return p.X >= 0 && p.Y >= 0 && p.X < Size && p.Y < Size }

// NearestCoin returns the closest coin to the bot, if any are left.
func (s State) NearestCoin() (Pos, bool) {
	best, found := Pos{}, false
	for _, c := range s.Coins {
		if !found || Dist(s.Me, c) < Dist(s.Me, best) {
			best, found = c, true
		}
	}
	return best, found
}

// Winning reports whether the bot has more gold than the enemy.
func (s State) Winning() bool { return s.MyGold > s.EnemyGold }

// TurnsLeft is how many turns remain after this one.
func (s State) TurnsLeft() int { return Turns - 1 - s.Turn }

// StepToward returns the move that takes from one step closer to to,
// moving along X first. It returns Stay when from == to.
func StepToward(from, to Pos) Action {
	switch {
	case to.X > from.X:
		return Right
	case to.X < from.X:
		return Left
	case to.Y > from.Y:
		return Down
	case to.Y < from.Y:
		return Up
	}
	return Stay
}

// StepAway returns a move that takes from one step further from danger,
// staying on the board. It returns Stay if no move increases the distance.
func StepAway(from, danger Pos) Action {
	best, bestDist := Stay, Dist(from, danger)
	for _, a := range []Action{Up, Down, Left, Right} {
		p := Apply(from, a)
		if d := Dist(p, danger); d > bestDist {
			best, bestDist = a, d
		}
	}
	return best
}

// Apply returns where p ends up after a. Moves off the edge leave p in place.
func Apply(p Pos, a Action) Pos {
	n := p
	switch a {
	case Up:
		n.Y--
	case Down:
		n.Y++
	case Left:
		n.X--
	case Right:
		n.X++
	}
	if !OnBoard(n) {
		return p
	}
	return n
}
