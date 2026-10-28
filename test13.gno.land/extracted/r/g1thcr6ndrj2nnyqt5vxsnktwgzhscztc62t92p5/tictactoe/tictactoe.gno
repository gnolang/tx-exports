// Package tictactoe implements a two-player tic-tac-toe game realm.
//
// Call NewGame to start a game as X, Join to sign up as O, and Play to
// place a mark. Render shows the board and whose turn it is.
package tictactoe

type cell int

const (
	empty cell = iota
	markX
	markO
)

func (c cell) String() string {
	switch c {
	case markX:
		return "X"
	case markO:
		return "O"
	default:
		return "·"
	}
}

var (
	board   [9]cell
	playerX address
	playerO address
	turn    cell
	winner  cell
	started bool
	over    bool
)

var winLines = [8][3]int{
	{0, 1, 2}, {3, 4, 5}, {6, 7, 8},
	{0, 3, 6}, {1, 4, 7}, {2, 5, 8},
	{0, 4, 8}, {2, 4, 6},
}

// NewGame starts a fresh game. The caller becomes X. Panics if a game is
// already in progress.
func NewGame(cur realm) {
	if started && !over {
		panic("a game is already in progress")
	}
	board = [9]cell{}
	playerX = cur.Previous().Address()
	playerO = address("")
	turn = markX
	winner = empty
	started = true
	over = false
}

// Join signs the caller up as O for the in-progress game. Panics if there
// is no open game, or the O seat is already taken.
func Join(cur realm) {
	if !started || over {
		panic("no open game to join")
	}
	caller := cur.Previous().Address()
	if caller == playerX {
		panic("already playing as X in this game")
	}
	if playerO != address("") {
		panic("game already has two players")
	}
	playerO = caller
}

// Play places the caller's mark at pos (0-8, row-major). Panics on an
// invalid move: out-of-range position, occupied cell, wrong turn, or a
// caller that isn't one of the two players.
func Play(cur realm, pos int) {
	if !started || over {
		panic("no active game")
	}
	if pos < 0 || pos > 8 {
		panic("position must be between 0 and 8")
	}
	if board[pos] != empty {
		panic("cell already occupied")
	}
	if playerO == address("") {
		panic("waiting for a second player to join")
	}

	caller := cur.Previous().Address()
	var mark cell
	switch caller {
	case playerX:
		mark = markX
	case playerO:
		mark = markO
	default:
		panic("caller is not a player in this game")
	}
	if mark != turn {
		panic("not your turn")
	}

	board[pos] = mark

	if hasWon(mark) {
		winner = mark
		over = true
		return
	}
	if isFull() {
		over = true
		return
	}
	if turn == markX {
		turn = markO
	} else {
		turn = markX
	}
}

func hasWon(mark cell) bool {
	for _, line := range winLines {
		if board[line[0]] == mark && board[line[1]] == mark && board[line[2]] == mark {
			return true
		}
	}
	return false
}

func isFull() bool {
	for _, c := range board {
		if c == empty {
			return false
		}
	}
	return true
}

// Render renders the current board as markdown.
func Render(path string) string {
	out := "# Tic-Tac-Toe\n\n"
	if !started {
		out += "No game yet. Call `NewGame` to start one.\n"
		return out
	}

	out += "```\n"
	for row := 0; row < 3; row++ {
		for col := 0; col < 3; col++ {
			idx := row*3 + col
			out += board[idx].String()
			if col < 2 {
				out += " | "
			}
		}
		out += "\n"
		if row < 2 {
			out += "--+---+--\n"
		}
	}
	out += "```\n\n"

	out += "X: " + playerX.String() + "\n\n"
	if playerO != address("") {
		out += "O: " + playerO.String() + "\n\n"
	} else {
		out += "O: (waiting for a player to `Join`)\n\n"
	}

	switch {
	case over && winner != empty:
		out += "**" + winner.String() + " wins!**\n"
	case over:
		out += "**Draw.**\n"
	default:
		out += "Turn: **" + turn.String() + "** (position 0-8, row-major:\n\n```\n0 | 1 | 2\n--+---+--\n3 | 4 | 5\n--+---+--\n6 | 7 | 8\n```)\n"
	}

	return out
}
