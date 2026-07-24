// Package tictactoe implements a simple two-player tic-tac-toe game.
//
// One game is active at a time. Call NewGame to start a game against an
// opponent, then Move to place a mark. Render shows the current board.
package tictactoe

import (
	"strconv"
	"strings"

	"chain"
)

var (
	board   [9]byte // ' ' empty, 'X', 'O'
	playerX address
	playerO address
	turn    byte // 'X' or 'O' — whose turn it is
	winner  byte // 0 = none yet, 'X', 'O', or 'D' for draw
	active  bool
)

var zeroAddr address

func init() {
	resetBoard()
}

func resetBoard() {
	for i := range board {
		board[i] = ' '
	}
	turn = 'X'
	winner = 0
	active = false
}

// NewGame starts a new game between the caller (playing X) and opponent
// (playing O). EOA call only. Overwrites any existing game.
func NewGame(cur realm, opponent address) {
	if !cur.Previous().IsUserCall() {
		panic("only a direct EOA call can start a game")
	}
	caller := cur.Previous().Address()
	if opponent == zeroAddr {
		panic("opponent address required")
	}
	if opponent == caller {
		panic("opponent must be a different address")
	}
	resetBoard()
	playerX = caller
	playerO = opponent
	active = true
	chain.Emit("NewGame", "playerX", playerX.String(), "playerO", playerO.String())
}

// Move places the caller's mark at board position pos (0-8, row-major,
// top-left is 0). EOA call only.
func Move(cur realm, pos int) {
	if !cur.Previous().IsUserCall() {
		panic("only a direct EOA call can play")
	}
	if !active {
		panic("no active game — call NewGame first")
	}
	if pos < 0 || pos > 8 {
		panic("position out of range 0-8")
	}
	if board[pos] != ' ' {
		panic("that cell is already taken")
	}

	caller := cur.Previous().Address()
	var mark byte
	switch caller {
	case playerX:
		mark = 'X'
	case playerO:
		mark = 'O'
	default:
		panic("caller is not a player in the active game")
	}
	if mark != turn {
		panic("not your turn")
	}

	board[pos] = mark

	if w := checkWinner(); w != 0 {
		winner = w
		active = false
		chain.Emit("GameOver", "result", string(w))
		return
	}
	if isBoardFull() {
		winner = 'D'
		active = false
		chain.Emit("GameOver", "result", "draw")
		return
	}

	if turn == 'X' {
		turn = 'O'
	} else {
		turn = 'X'
	}
}

var winLines = [8][3]int{
	{0, 1, 2}, {3, 4, 5}, {6, 7, 8}, // rows
	{0, 3, 6}, {1, 4, 7}, {2, 5, 8}, // columns
	{0, 4, 8}, {2, 4, 6}, // diagonals
}

func checkWinner() byte {
	for _, l := range winLines {
		a, b, c := board[l[0]], board[l[1]], board[l[2]]
		if a != ' ' && a == b && b == c {
			return a
		}
	}
	return 0
}

func isBoardFull() bool {
	for _, c := range board {
		if c == ' ' {
			return false
		}
	}
	return true
}

// Render shows the current board and game status.
func Render(path string) string {
	var sb strings.Builder
	sb.WriteString("# Tic-Tac-Toe\n\n")

	if playerX == zeroAddr {
		sb.WriteString("No game yet. Call `NewGame(opponent)` to start one.\n")
		return sb.String()
	}

	sb.WriteString("Player X: " + playerX.String() + "\n\n")
	sb.WriteString("Player O: " + playerO.String() + "\n\n")

	for row := 0; row < 3; row++ {
		cells := make([]string, 3)
		for col := 0; col < 3; col++ {
			c := board[row*3+col]
			if c == ' ' {
				cells[col] = strconv.Itoa(row*3 + col)
			} else {
				cells[col] = string(c)
			}
		}
		sb.WriteString(strings.Join(cells, " | ") + "\n")
		if row < 2 {
			sb.WriteString("---------\n")
		}
	}
	sb.WriteString("\n")

	switch {
	case winner == 'D':
		sb.WriteString("Game over: draw!\n")
	case winner != 0:
		sb.WriteString("Game over: " + string(winner) + " wins!\n")
	case active:
		sb.WriteString("Turn: " + string(turn) + "\n")
	}

	return sb.String()
}
