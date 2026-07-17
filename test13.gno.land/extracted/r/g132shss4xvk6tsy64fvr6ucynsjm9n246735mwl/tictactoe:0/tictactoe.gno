// Package tictactoe is a two-player tic-tac-toe realm.
//
// One game is active at a time. Start a game with NewGame, have a second
// player join with Join, then alternate Move calls until someone wins or
// the board fills up.
package tictactoe

import (
	"strconv"

	"chain"
)

type cell int

const (
	empty cell = iota
	markX
	markO
)

type status int

const (
	waiting status = iota
	playing
	xWon
	oWon
	draw
)

var (
	board   [9]cell
	playerX address
	playerO address
	turn    cell
	st      status
)

var winLines = [8][3]int{
	{0, 1, 2}, {3, 4, 5}, {6, 7, 8},
	{0, 3, 6}, {1, 4, 7}, {2, 5, 8},
	{0, 4, 8}, {2, 4, 6},
}

// NewGame starts a fresh game with the caller as player X. Fails while a
// game is currently being played; a finished or not-yet-started game may
// always be (re)started.
func NewGame(cur realm) {
	if st == playing {
		panic("a game is already in progress")
	}
	board = [9]cell{}
	playerX = cur.Previous().Address()
	var zero address
	playerO = zero
	turn = markX
	st = waiting
	chain.Emit("NewGame", "playerX", playerX.String())
}

// Join enrolls the caller as player O for the waiting game and starts play.
func Join(cur realm) {
	if st != waiting {
		panic("no game waiting for a second player")
	}
	caller := cur.Previous().Address()
	if caller == playerX {
		panic("cannot join your own game")
	}
	playerO = caller
	st = playing
	chain.Emit("GameStarted", "playerX", playerX.String(), "playerO", playerO.String())
}

// Move places the caller's mark at board position pos (0-8, left-to-right,
// top-to-bottom) and advances the turn.
func Move(cur realm, pos int) {
	if st != playing {
		panic("no game in progress")
	}
	if pos < 0 || pos > 8 {
		panic("position out of range 0-8")
	}
	if board[pos] != empty {
		panic("cell already occupied")
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
	chain.Emit("Move", "player", caller.String(), "pos", strconv.Itoa(pos))

	if checkWin(mark) {
		if mark == markX {
			st = xWon
		} else {
			st = oWon
		}
		chain.Emit("GameOver", "result", resultLabel())
		return
	}
	if boardFull() {
		st = draw
		chain.Emit("GameOver", "result", "draw")
		return
	}
	if turn == markX {
		turn = markO
	} else {
		turn = markX
	}
}

func checkWin(mark cell) bool {
	for _, line := range winLines {
		if board[line[0]] == mark && board[line[1]] == mark && board[line[2]] == mark {
			return true
		}
	}
	return false
}

func boardFull() bool {
	for _, c := range board {
		if c == empty {
			return false
		}
	}
	return true
}

func resultLabel() string {
	switch st {
	case xWon:
		return "X wins"
	case oWon:
		return "O wins"
	case draw:
		return "draw"
	default:
		return "in progress"
	}
}

func cellChar(c cell) string {
	switch c {
	case markX:
		return "X"
	case markO:
		return "O"
	default:
		return " "
	}
}

func boardString() string {
	out := "```\n"
	for row := 0; row < 3; row++ {
		for col := 0; col < 3; col++ {
			idx := row*3 + col
			out += cellChar(board[idx])
			if col < 2 {
				out += " | "
			}
		}
		out += "\n"
		if row < 2 {
			out += "---------\n"
		}
	}
	out += "```\n"
	return out
}

// Render shows the current board and game status.
func Render(path string) string {
	out := "# Tic-Tac-Toe\n\n"
	switch st {
	case waiting:
		out += "Waiting for a second player to Join. Player X: `" + playerX.String() + "`\n\n"
	case playing:
		turnAddr := playerX
		turnMark := "X"
		if turn == markO {
			turnAddr = playerO
			turnMark = "O"
		}
		out += "Player X: `" + playerX.String() + "`  \n"
		out += "Player O: `" + playerO.String() + "`\n\n"
		out += "Turn: **" + turnMark + "** (`" + turnAddr.String() + "`)\n\n"
	case xWon:
		out += "**X wins!** (`" + playerX.String() + "`)\n\n"
	case oWon:
		out += "**O wins!** (`" + playerO.String() + "`)\n\n"
	case draw:
		out += "**Draw.**\n\n"
	}
	out += boardString()
	return out
}
