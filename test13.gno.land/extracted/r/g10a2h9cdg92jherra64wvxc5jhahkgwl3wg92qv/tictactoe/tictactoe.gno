// Package tictactoe is a two-player tic-tac-toe realm.
package tictactoe

import (
	"strconv"
	"strings"

	"gno.land/p/nt/avl/v0"
)

// Game holds the full state of one tic-tac-toe match.
// Board is indexed 0-8, row-major (0,1,2 / 3,4,5 / 6,7,8).
type Game struct {
	ID       int64
	X        address // ❌ creator, moves first
	O        address // ⭕ opponent
	Board    [9]int  // 0 empty, 1 = X, 2 = O
	Turn     int     // whose turn: markX or markO
	Winner   int     // empty until decided; markX/markO = winner
	Draw     bool
	Finished bool
}

const (
	empty = 0
	markX = 1
	markO = 2
)

var (
	games  avl.Tree // id string -> *Game
	nextID int64
)

// wins[i] lists the eight winning lines as cell-index triples.
var winLines = [8][3]int{
	{0, 1, 2}, {3, 4, 5}, {6, 7, 8}, // rows
	{0, 3, 6}, {1, 4, 7}, {2, 5, 8}, // cols
	{0, 4, 8}, {2, 4, 6}, // diagonals
}

func idKey(id int64) string {
	return strconv.FormatInt(id, 10)
}

func getGame(id int64) *Game {
	v, ok := games.Get(idKey(id))
	if !ok {
		panic("game not found")
	}
	return v.(*Game)
}

// NewGame creates a match between the caller (❌) and opponent (⭕).
// The caller moves first. Returns the new game id.
func NewGame(cur realm, opponent address) int64 {
	caller := cur.Previous().Address()
	if opponent == caller {
		panic("opponent must differ from caller")
	}
	if opponent == "" {
		panic("opponent address required")
	}

	id := nextID
	nextID++

	games.Set(idKey(id), &Game{
		ID:   id,
		X:    caller,
		O:    opponent,
		Turn: markX,
	})

	return id
}

// Play places the caller's mark at the given cell (0-8) of gameID.
// Enforces turn order, rejects out-of-range or occupied cells, and
// detects a win or a draw.
func Play(cur realm, gameID int64, cell int) {
	caller := cur.Previous().Address()
	g := getGame(gameID)

	if g.Finished {
		panic("game already finished")
	}
	if cell < 0 || cell > 8 {
		panic("cell out of range")
	}
	if g.Board[cell] != empty {
		panic("cell already occupied")
	}

	var mark int
	switch caller {
	case g.X:
		mark = markX
	case g.O:
		mark = markO
	default:
		panic("caller is not a player in this game")
	}
	if mark != g.Turn {
		panic("not your turn")
	}

	g.Board[cell] = mark

	if wins(&g.Board, mark) {
		g.Winner = mark
		g.Finished = true
		return
	}
	if full(&g.Board) {
		g.Draw = true
		g.Finished = true
		return
	}

	if g.Turn == markX {
		g.Turn = markO
	} else {
		g.Turn = markX
	}
}

func wins(b *[9]int, mark int) bool {
	for _, line := range winLines {
		if b[line[0]] == mark && b[line[1]] == mark && b[line[2]] == mark {
			return true
		}
	}
	return false
}

func full(b *[9]int) bool {
	for _, v := range b {
		if v == empty {
			return false
		}
	}
	return true
}

func glyph(v int) string {
	switch v {
	case markX:
		return "❌"
	case markO:
		return "⭕"
	default:
		return "·"
	}
}

func short(a address) string {
	s := a.String()
	if len(s) <= 12 {
		return s
	}
	return s[:8] + "…" + s[len(s)-4:]
}

// Render draws the board with ❌⭕· and shows whose turn / the winner.
// path "" lists all games; path "<id>" shows a single board.
func Render(path string) string {
	if path == "" {
		return renderList()
	}
	id, err := strconv.ParseInt(path, 10, 64)
	if err != nil {
		return "> [!WARNING]\n> Path not found"
	}
	v, ok := games.Get(idKey(id))
	if !ok {
		return "> [!WARNING]\n> Path not found"
	}
	return renderGame(v.(*Game))
}

func renderList() string {
	if games.Size() == 0 {
		return "# Tic-Tac-Toe\n\nNo games yet."
	}
	var out strings.Builder
	out.WriteString("# Tic-Tac-Toe\n\n")
	games.Iterate("", "", func(key string, value any) bool {
		g := value.(*Game)
		status := "in progress"
		switch {
		case g.Winner == markX:
			status = "❌ wins"
		case g.Winner == markO:
			status = "⭕ wins"
		case g.Draw:
			status = "draw"
		}
		out.WriteString("- [Game " + key + "](" + key + "): " +
			short(g.X) + " (❌) vs " + short(g.O) + " (⭕) — " + status + "\n")
		return false
	})
	return out.String()
}

func renderGame(g *Game) string {
	var out strings.Builder
	out.WriteString("# Game " + strconv.FormatInt(g.ID, 10) + "\n\n")
	out.WriteString("❌ " + short(g.X) + " vs ⭕ " + short(g.O) + "\n\n")

	for row := 0; row < 3; row++ {
		cells := make([]string, 3)
		for col := 0; col < 3; col++ {
			cells[col] = glyph(g.Board[row*3+col])
		}
		out.WriteString(strings.Join(cells, " | ") + "\n")
		if row < 2 {
			out.WriteString("---------\n")
		}
	}

	out.WriteString("\n")
	switch {
	case g.Winner == markX:
		out.WriteString("❌ wins!\n")
	case g.Winner == markO:
		out.WriteString("⭕ wins!\n")
	case g.Draw:
		out.WriteString("Draw.\n")
	case g.Turn == markX:
		out.WriteString("Turn: ❌\n")
	default:
		out.WriteString("Turn: ⭕\n")
	}
	return out.String()
}
