package tictactoe

import (
	"strconv"
	"strings"

	"gno.land/p/nt/avl/v0"
)

type Game struct {
	ID     string
	X      address
	O      address
	Board  [9]string
	Turn   string // "X" or "O"
	Status string // "waiting", "playing", "done"
	Winner string // "X", "O", "draw", or ""
}

var (
	games   avl.Tree
	counter int
)

// NewGame creates a new game and makes the caller player X.
// Returns the game ID.
func NewGame(cur realm) string {
	if !cur.IsCurrent() {
		panic("spoofed realm")
	}
	if !cur.Previous().IsUserCall() {
		panic("EOA only")
	}
	caller := cur.Previous().Address()
	counter++
	id := "g" + strconv.Itoa(counter)
	g := &Game{
		ID:     id,
		X:      caller,
		Turn:   "X",
		Status: "waiting",
	}
	games.Set(id, g)
	return id
}

// Join lets the caller join as player O.
func Join(cur realm, gameID string) {
	if !cur.IsCurrent() {
		panic("spoofed realm")
	}
	if !cur.Previous().IsUserCall() {
		panic("EOA only")
	}
	caller := cur.Previous().Address()
	g := mustGet(gameID)
	if g.Status != "waiting" {
		panic("game not waiting for a player")
	}
	if g.X == caller {
		panic("cannot play against yourself")
	}
	g.O = caller
	g.Status = "playing"
	games.Set(gameID, g)
}

// Move places the caller's mark at pos (0-8, row-major order).
func Move(cur realm, gameID string, pos int) {
	if !cur.IsCurrent() {
		panic("spoofed realm")
	}
	if !cur.Previous().IsUserCall() {
		panic("EOA only")
	}
	caller := cur.Previous().Address()
	g := mustGet(gameID)
	if g.Status != "playing" {
		panic("game not in progress")
	}
	if pos < 0 || pos > 8 {
		panic("position must be 0-8")
	}
	if g.Board[pos] != "" {
		panic("cell already occupied")
	}
	if g.Turn == "X" && caller != g.X {
		panic("not your turn")
	}
	if g.Turn == "O" && caller != g.O {
		panic("not your turn")
	}
	g.Board[pos] = g.Turn
	if w := checkWinner(g.Board); w != "" {
		g.Winner = w
		g.Status = "done"
	} else if boardFull(g.Board) {
		g.Winner = "draw"
		g.Status = "done"
	} else {
		if g.Turn == "X" {
			g.Turn = "O"
		} else {
			g.Turn = "X"
		}
	}
	games.Set(gameID, g)
}

func checkWinner(b [9]string) string {
	wins := [][3]int{
		{0, 1, 2}, {3, 4, 5}, {6, 7, 8},
		{0, 3, 6}, {1, 4, 7}, {2, 5, 8},
		{0, 4, 8}, {2, 4, 6},
	}
	for _, w := range wins {
		if b[w[0]] != "" && b[w[0]] == b[w[1]] && b[w[1]] == b[w[2]] {
			return b[w[0]]
		}
	}
	return ""
}

func boardFull(b [9]string) bool {
	for _, c := range b {
		if c == "" {
			return false
		}
	}
	return true
}

func mustGet(id string) *Game {
	v, ok := games.Get(id)
	if !ok {
		panic("game not found: " + id)
	}
	return v.(*Game)
}

func Render(path string) string {
	path = strings.TrimPrefix(path, "/")
	if path != "" {
		return renderGame(path)
	}
	return renderIndex()
}

func renderIndex() string {
	out := "# Tic Tac Toe\n\n"
	count := 0
	games.Iterate("", "", func(key string, val any) bool {
		g := val.(*Game)
		out += "- [**" + g.ID + "**](" + g.ID + ") — "
		out += "X: `" + g.X.String() + "`"
		if g.O != address("") {
			out += ", O: `" + g.O.String() + "`"
		} else {
			out += ", O: _waiting_"
		}
		out += " — " + g.Status
		if g.Status == "done" {
			if g.Winner == "draw" {
				out += " (draw)"
			} else {
				out += " (" + g.Winner + " wins)"
			}
		}
		out += "\n"
		count++
		return false
	})
	if count == 0 {
		out += "_No games yet. Call `NewGame()` to start one._\n"
	}
	out += "\n## How to Play\n\n"
	out += "1. Call `NewGame()` — you become player X, get a game ID\n"
	out += "2. Opponent calls `Join(gameID)` to become player O\n"
	out += "3. Take turns calling `Move(gameID, pos)` where pos is 0–8:\n\n"
	out += "```\n 0 | 1 | 2\n---+---+---\n 3 | 4 | 5\n---+---+---\n 6 | 7 | 8\n```\n"
	return out
}

func renderGame(id string) string {
	v, ok := games.Get(id)
	if !ok {
		return "> [!WARNING]\n> Game not found: " + id + "\n"
	}
	g := v.(*Game)
	out := "# Game " + g.ID + "\n\n"
	out += "**X:** `" + g.X.String() + "`\n\n"
	if g.O != address("") {
		out += "**O:** `" + g.O.String() + "`\n\n"
	} else {
		out += "**O:** _waiting — call `Join(\"" + g.ID + "\")` to join_\n\n"
	}
	cell := func(i int) string {
		if g.Board[i] == "" {
			return " "
		}
		return g.Board[i]
	}
	out += "```\n"
	out += " " + cell(0) + " | " + cell(1) + " | " + cell(2) + "\n"
	out += "---+---+---\n"
	out += " " + cell(3) + " | " + cell(4) + " | " + cell(5) + "\n"
	out += "---+---+---\n"
	out += " " + cell(6) + " | " + cell(7) + " | " + cell(8) + "\n"
	out += "```\n\n"
	switch g.Status {
	case "waiting":
		out += "**Status:** Waiting for player O\n"
	case "playing":
		out += "**Status:** Playing — **" + g.Turn + "**'s turn\n"
	case "done":
		if g.Winner == "draw" {
			out += "**Status:** Game over — **Draw!**\n"
		} else {
			out += "**Status:** Game over — **" + g.Winner + " wins!**\n"
		}
	}
	return out
}
