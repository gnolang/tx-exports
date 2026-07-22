// Package tictactoe is a two-player tic-tac-toe realm.
//
// Join(cur, "X") / Join(cur, "O") claims a mark; Play(cur, pos) plays
// cell pos (0-8, row-major); Reset(cur) clears the board once a game
// has ended. Render shows the current board.
package tictactoe

import (
	"strconv"

	"chain"
)

const (
	empty byte = 0
	markX byte = 1
	markO byte = 2
)

var (
	board     [9]byte
	turn      byte = markX
	playerX   address
	playerO   address
	winner    byte
	moveCount int
	gameOver  bool
)

var zeroAddr address

// Join claims the X or O mark for the calling account. Each mark may
// only be claimed once per game; call Reset to start a new game.
func Join(cur realm, mark string) {
	if !cur.Previous().IsUserCall() {
		panic("EOA call only")
	}
	caller := cur.Previous().Address()
	switch mark {
	case "X":
		if playerX != zeroAddr {
			panic("X already taken")
		}
		playerX = caller
	case "O":
		if playerO != zeroAddr {
			panic("O already taken")
		}
		playerO = caller
	default:
		panic(`mark must be "X" or "O"`)
	}
	chain.Emit("Join", "player", caller.String(), "mark", mark)
}

// Play places the calling player's mark at pos (0-8, row-major).
func Play(cur realm, pos int) {
	if !cur.Previous().IsUserCall() {
		panic("EOA call only")
	}
	if gameOver {
		panic("game is over, call Reset to start a new one")
	}
	if pos < 0 || pos > 8 {
		panic("position out of range 0-8")
	}
	if board[pos] != empty {
		panic("cell already occupied")
	}

	caller := cur.Previous().Address()
	var mark byte
	if turn == markX {
		if playerX == zeroAddr {
			panic("X has not joined yet")
		}
		if caller != playerX {
			panic("not your turn")
		}
		mark = markX
	} else {
		if playerO == zeroAddr {
			panic("O has not joined yet")
		}
		if caller != playerO {
			panic("not your turn")
		}
		mark = markO
	}

	board[pos] = mark
	moveCount++
	chain.Emit("Play", "player", caller.String(), "pos", strconv.Itoa(pos))

	if w := checkWinner(); w != empty {
		winner = w
		gameOver = true
		chain.Emit("GameOver", "result", markString(w)+" wins")
	} else if moveCount == 9 {
		gameOver = true
		chain.Emit("GameOver", "result", "draw")
	} else if turn == markX {
		turn = markO
	} else {
		turn = markX
	}
}

// Reset clears the board and both player slots. Only a current player
// may reset, and only after the game has ended.
func Reset(cur realm) {
	if !cur.Previous().IsUserCall() {
		panic("EOA call only")
	}
	if !gameOver {
		panic("game still in progress")
	}
	caller := cur.Previous().Address()
	if caller != playerX && caller != playerO {
		panic("only a player of the current game may reset it")
	}

	board = [9]byte{}
	turn = markX
	winner = empty
	moveCount = 0
	gameOver = false
	playerX = zeroAddr
	playerO = zeroAddr
	chain.Emit("Reset", "by", caller.String())
}

var winLines = [8][3]int{
	{0, 1, 2}, {3, 4, 5}, {6, 7, 8},
	{0, 3, 6}, {1, 4, 7}, {2, 5, 8},
	{0, 4, 8}, {2, 4, 6},
}

func checkWinner() byte {
	for _, l := range winLines {
		a, b, c := board[l[0]], board[l[1]], board[l[2]]
		if a != empty && a == b && b == c {
			return a
		}
	}
	return empty
}

func markString(m byte) string {
	switch m {
	case markX:
		return "X"
	case markO:
		return "O"
	default:
		return "_"
	}
}

// Render draws the current board and game status as markdown.
func Render(_ string) string {
	out := "# Tic-Tac-Toe\n\n"

	out += "```\n"
	for row := 0; row < 3; row++ {
		for col := 0; col < 3; col++ {
			out += markString(board[row*3+col])
			if col < 2 {
				out += " | "
			}
		}
		out += "\n"
		if row < 2 {
			out += "---------\n"
		}
	}
	out += "```\n\n"

	out += "X: "
	if playerX == zeroAddr {
		out += "_open_"
	} else {
		out += playerX.String()
	}
	out += "\n\nO: "
	if playerO == zeroAddr {
		out += "_open_"
	} else {
		out += playerO.String()
	}
	out += "\n\n"

	switch {
	case gameOver && winner != empty:
		out += "**" + markString(winner) + " wins!** Call Reset to play again.\n"
	case gameOver:
		out += "**Draw.** Call Reset to play again.\n"
	default:
		out += "Turn: **" + markString(turn) + "**\n"
	}

	return out
}
