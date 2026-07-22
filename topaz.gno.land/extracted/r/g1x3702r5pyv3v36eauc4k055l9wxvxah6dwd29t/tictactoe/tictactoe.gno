// Package tictactoe is a two-player tic-tac-toe realm. The first caller to
// Join becomes X, the second becomes O; players then alternate Move calls by
// cell index (0-8, left-to-right top-to-bottom) until someone wins or the
// board fills. Reset starts a fresh game once the current one has ended.
package tictactoe

import (
	"strconv"

	"chain"
)

var (
	zero address

	board   [9]string // "" empty, "X", "O"
	playerX address
	playerO address
	turn    string // "X" or "O", whose move is next
	winner  string // "", "X", "O", or "Draw"
	moves   int
)

func init() {
	turn = "X"
}

// Join seats the caller as X (if the seat is open) or O (if X is taken).
// Panics if both seats are already filled.
func Join(cur realm) string {
	caller := cur.Previous().Address()
	switch {
	case playerX == zero:
		playerX = caller
		chain.Emit("Join", "player", caller.String(), "mark", "X")
		return "joined as X"
	case playerO == zero:
		if caller == playerX {
			panic("already joined as X")
		}
		playerO = caller
		chain.Emit("Join", "player", caller.String(), "mark", "O")
		return "joined as O"
	default:
		panic("game is full")
	}
}

// Move places the caller's mark at the given cell (0-8) if it is their turn
// and the cell is empty, then checks for a win or a draw.
func Move(cur realm, pos int) {
	if winner != "" {
		panic("game already over, call Reset to start a new one")
	}
	if pos < 0 || pos > 8 {
		panic("position must be between 0 and 8")
	}
	if board[pos] != "" {
		panic("cell already occupied")
	}

	var expected address
	if turn == "X" {
		expected = playerX
	} else {
		expected = playerO
	}
	if expected == zero {
		panic("waiting for both players to join")
	}

	caller := cur.Previous().Address()
	if caller != expected {
		panic("not your turn")
	}

	board[pos] = turn
	moves++
	chain.Emit("Move", "player", caller.String(), "mark", turn, "pos", strconv.Itoa(pos))

	if checkWin(turn) {
		winner = turn
		chain.Emit("GameOver", "result", winner)
	} else if moves == 9 {
		winner = "Draw"
		chain.Emit("GameOver", "result", winner)
	} else if turn == "X" {
		turn = "O"
	} else {
		turn = "X"
	}
}

// Reset clears the board for a new game. Only callable once the current
// game has ended (someone won or the board is full).
func Reset(cur realm) {
	if winner == "" {
		panic("game still in progress")
	}
	board = [9]string{}
	playerX = zero
	playerO = zero
	turn = "X"
	winner = ""
	moves = 0
	chain.Emit("Reset")
}

var winLines = [8][3]int{
	{0, 1, 2}, {3, 4, 5}, {6, 7, 8}, // rows
	{0, 3, 6}, {1, 4, 7}, {2, 5, 8}, // columns
	{0, 4, 8}, {2, 4, 6}, // diagonals
}

func checkWin(mark string) bool {
	for _, line := range winLines {
		if board[line[0]] == mark && board[line[1]] == mark && board[line[2]] == mark {
			return true
		}
	}
	return false
}

func cell(pos int) string {
	if board[pos] == "" {
		return strconv.Itoa(pos)
	}
	return board[pos]
}

// Render draws the current board and game status as markdown.
func Render(path string) string {
	out := "# Tic-Tac-Toe\n\n"
	out += "|   |   |   |\n"
	out += "|---|---|---|\n"
	for row := 0; row < 3; row++ {
		out += "| "
		for col := 0; col < 3; col++ {
			out += cell(row*3+col) + " | "
		}
		out += "\n"
	}
	out += "\n"

	switch {
	case winner == "Draw":
		out += "**Game over: draw.**\n"
	case winner != "":
		out += "**Game over: " + winner + " wins!**\n"
	default:
		out += "Turn: **" + turn + "**\n"
	}

	out += "\nPlayer X: "
	if playerX == zero {
		out += "_(open)_"
	} else {
		out += playerX.String()
	}
	out += "\n\nPlayer O: "
	if playerO == zero {
		out += "_(open)_"
	} else {
		out += playerO.String()
	}
	out += "\n"
	return out
}
