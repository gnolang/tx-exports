// https://raw.githubusercontent.com/sts10/tic-tac-go/main/game.go

package tictacgno

import (
	fmt "gno.land/p/demo/ufmt"
	"std"
	"strings"
)

var board [9]int
var gameOver bool
var turnNumber int
var lastCaller std.Address
var playerOne std.Address
var playerTwo std.Address
var winner std.Address
var tieGame bool

func Render(string) string {
	var s strings.Builder
	s.WriteString("### Board\n\n")
	s.WriteString(presentBoard(board))
	s.WriteString("\n\n")

	if gameOver {
		s.WriteString("### The winner is:\n\n")
		if tieGame {
			s.WriteString("Tie game!")
		} else {
			s.WriteString(winner.String())
		}
	} else {
		s.WriteString("### Playing...")
	}

	return s.String()
}

func Play(move int) string {
	if lastCaller == std.GetOrigCaller() {
		return "It's not your turn!"
	}
	lastCaller = std.GetOrigCaller()

	switch {
	case playerOne == nil:
		playerOne = lastCaller
	case playerTwo == nil:
		playerTwo = lastCaller
	default:
		switch lastCaller {
		case playerOne, playerTwo:
		default:
			return "All seats are taken!"
		}
	}

	playerNo := 1
	if lastCaller == playerTwo {
		playerNo = 2
	}

	if board[move] != 0 {
		return "Please pick an unoccupied space."
	}

	if move > 8 {
		return "Please enter a number under 9."
	}
	board = executePlayerMove(move, playerNo, board)

	result := checkForWin(board)
	if result > 0 {
		gameOver = true
		switch result {
		case 1:
			winner = playerOne
		case 21:
			winner = playerTwo
		}
		return fmt.Sprintf("Player %s wins!", winner)
	} else if turnNumber == 9 {
		// Tie game example: 0 2 1 3 4 7 5 8 6
		tieGame = true
		gameOver = true
	} else {
		turnNumber++
	}
}

func init() {
	board = [9]int{0, 0, 0, 0, 0, 0, 0, 0, 0}
	turnNumber = 1
}

func executePlayerMove(moveInt int, player int, b [9]int) [9]int {

	if player == 1 {
		b[moveInt] = 1
	} else if player == 2 {
		b[moveInt] = 10
	}

	if player == 1 {
		b[moveInt] = 1
	} else if player == 2 {
		b[moveInt] = 10
	}
	return b
}

func presentBoard(b [9]int) string {
	var s strings.Builder
	for i, v := range b {
		if v == 0 {
			// empty space. Display number
			s.WriteString(fmt.Sprintf("%d", i))
		} else if v == 1 {
			s.WriteString("X")
		} else if v == 10 {
			s.WriteString("O")
		}
		// And now the decorations
		if i > 0 && (i+1)%3 == 0 {
			s.WriteString("\n")
		} else {
			s.WriteString(" | ")
		}
	}
	return s.String()
}

func checkForWin(b [9]int) int {
	// re-calculate sums Array
	sums := [8]int{0, 0, 0, 0, 0, 0, 0, 0}
	// for _, v := range b[0:2] { sums[7] += v }
	// for _, v := range b[3:5] { sums[6] += v }
	// for _, v := range b[6:8] { sums[5] += v }

	sums[0] = b[2] + b[4] + b[6]
	sums[1] = b[0] + b[3] + b[6]
	sums[2] = b[1] + b[4] + b[7]
	sums[3] = b[2] + b[5] + b[8]
	sums[4] = b[0] + b[4] + b[8]
	sums[5] = b[6] + b[7] + b[8]
	sums[6] = b[3] + b[4] + b[5]
	sums[7] = b[0] + b[1] + b[2]
	for _, v := range sums {
		if v == 3 {
			return 1
		} else if v == 30 {
			return 2
		}
	}
	return 0
}
