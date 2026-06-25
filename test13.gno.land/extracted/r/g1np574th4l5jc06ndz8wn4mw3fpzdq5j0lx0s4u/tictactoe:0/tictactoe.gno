package tictactoe

import (
	"strconv"

	"chain"
	"gno.land/p/nt/avl/v0"
)

type Cell int

const (
	Empty Cell = 0
	X     Cell = 1
	O     Cell = 2
)

type Game struct {
	ID      int
	Board   [9]Cell
	PlayerX address
	PlayerO address
	Turn    Cell
	Winner  Cell
	Draw    bool
}

var (
	games     = avl.NewTree()
	gameCount int
)

// NewGame creates a new game where the caller plays X and opponent plays O.
func NewGame(cur realm, opponent address) int {
	if !cur.IsCurrent() {
		panic("spoofed realm")
	}
	caller := cur.Previous().Address()
	gameCount++
	id := gameCount
	g := &Game{
		ID:      id,
		PlayerX: caller,
		PlayerO: opponent,
		Turn:    X,
	}
	games.Set(strconv.Itoa(id), g)
	chain.Emit("GameCreated",
		"id", strconv.Itoa(id),
		"playerX", caller.String(),
		"playerO", opponent.String(),
	)
	return id
}

// Move places the caller's mark at position pos (0-8, row-major).
func Move(cur realm, gameID int, pos int) {
	if !cur.IsCurrent() {
		panic("spoofed realm")
	}
	caller := cur.Previous().Address()
	g := mustGetGame(gameID)
	if g.Winner != Empty || g.Draw {
		panic("game is over")
	}
	if g.Turn == X && caller != g.PlayerX {
		panic("not your turn")
	}
	if g.Turn == O && caller != g.PlayerO {
		panic("not your turn")
	}
	if pos < 0 || pos > 8 {
		panic("position out of range [0-8]")
	}
	if g.Board[pos] != Empty {
		panic("position already taken")
	}
	g.Board[pos] = g.Turn
	if checkWin(g.Board, g.Turn) {
		g.Winner = g.Turn
		chain.Emit("GameOver",
			"id", strconv.Itoa(gameID),
			"winner", cellStr(g.Turn),
		)
	} else if checkDraw(g.Board) {
		g.Draw = true
		chain.Emit("GameOver",
			"id", strconv.Itoa(gameID),
			"winner", "draw",
		)
	} else {
		if g.Turn == X {
			g.Turn = O
		} else {
			g.Turn = X
		}
		chain.Emit("Move",
			"id", strconv.Itoa(gameID),
			"player", caller.String(),
			"pos", strconv.Itoa(pos),
		)
	}
}

func mustGetGame(id int) *Game {
	v, ok := games.Get(strconv.Itoa(id))
	if !ok {
		panic("game not found")
	}
	return v.(*Game)
}

func checkWin(board [9]Cell, player Cell) bool {
	lines := [8][3]int{
		{0, 1, 2}, {3, 4, 5}, {6, 7, 8},
		{0, 3, 6}, {1, 4, 7}, {2, 5, 8},
		{0, 4, 8}, {2, 4, 6},
	}
	for _, l := range lines {
		if board[l[0]] == player && board[l[1]] == player && board[l[2]] == player {
			return true
		}
	}
	return false
}

func checkDraw(board [9]Cell) bool {
	for _, c := range board {
		if c == Empty {
			return false
		}
	}
	return true
}

func cellStr(c Cell) string {
	switch c {
	case X:
		return "X"
	case O:
		return "O"
	default:
		return "."
	}
}

func renderBoard(board [9]Cell) string {
	out := ""
	for i, c := range board {
		out += cellStr(c)
		if i%3 < 2 {
			out += "|"
		} else if i < 8 {
			out += "\n-+-+-\n"
		}
	}
	return out
}

func Render(path string) string {
	if path == "" {
		return renderHome()
	}
	id, err := strconv.Atoi(path)
	if err != nil {
		return "> [!WARNING]\n> Invalid game ID\n"
	}
	v, ok := games.Get(strconv.Itoa(id))
	if !ok {
		return "> [!WARNING]\n> Game not found\n"
	}
	return renderGame(v.(*Game))
}

func renderHome() string {
	out := "# Tic Tac Toe\n\n"
	out += "**Total games:** " + strconv.Itoa(gameCount) + "\n\n"
	if gameCount == 0 {
		out += "No games yet. Call `NewGame(opponent)` to start!\n"
		return out
	}
	out += "## Games\n\n"
	count := 0
	games.Iterate("", "", func(key string, value any) bool {
		g := value.(*Game)
		out += "- [Game #" + strconv.Itoa(g.ID) + "](" + strconv.Itoa(g.ID) + ")"
		if g.Winner != Empty {
			out += " — Winner: **" + cellStr(g.Winner) + "**"
		} else if g.Draw {
			out += " — **Draw**"
		} else {
			out += " — in progress, turn: **" + cellStr(g.Turn) + "**"
		}
		out += "\n"
		count++
		return count >= 20
	})
	return out
}

func renderGame(g *Game) string {
	out := "# Game #" + strconv.Itoa(g.ID) + "\n\n"
	out += "| Player | Address |\n"
	out += "| --- | --- |\n"
	out += "| **X** | " + g.PlayerX.String() + " |\n"
	out += "| **O** | " + g.PlayerO.String() + " |\n\n"
	out += "```\n" + renderBoard(g.Board) + "\n```\n\n"
	if g.Winner != Empty {
		out += "## Result\n\n**Winner: " + cellStr(g.Winner) + "** \n"
	} else if g.Draw {
		out += "## Result\n\n**Draw!**\n"
	} else {
		out += "**Next turn: " + cellStr(g.Turn) + "**\n"
	}
	return out
}
