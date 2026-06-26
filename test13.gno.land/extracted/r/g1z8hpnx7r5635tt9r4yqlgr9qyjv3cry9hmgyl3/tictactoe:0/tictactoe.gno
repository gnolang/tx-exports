package tictactoe

import "strconv"

var (
	board  [9]string
	turn   = "X"
	winner string
	moves  int
)

func init() {
	for i := 0; i < 9; i++ {
		board[i] = "."
	}
}

// Mark places the current player's token at pos (0=top-left ... 8=bottom-right, row-major).
func Mark(pos int) string {
	if winner != "" {
		return "game over: " + winner
	}
	if pos < 0 || pos > 8 {
		return "invalid position: use 0-8"
	}
	if board[pos] != "." {
		return "cell already taken"
	}
	board[pos] = turn
	moves++
	if checkWin() {
		winner = turn
		return turn + " wins!"
	}
	if moves == 9 {
		winner = "draw"
		return "draw!"
	}
	if turn == "X" {
		turn = "O"
	} else {
		turn = "X"
	}
	return "ok"
}

func checkWin() bool {
	lines := [8][3]int{
		{0, 1, 2}, {3, 4, 5}, {6, 7, 8},
		{0, 3, 6}, {1, 4, 7}, {2, 5, 8},
		{0, 4, 8}, {2, 4, 6},
	}
	for _, l := range lines {
		if board[l[0]] != "." && board[l[0]] == board[l[1]] && board[l[1]] == board[l[2]] {
			return true
		}
	}
	return false
}

func Render(_ string) string {
	out := "# Tic-Tac-Toe\n\n"
	out += "```\n"
	out += " " + board[0] + " | " + board[1] + " | " + board[2] + "\n"
	out += "---+---+---\n"
	out += " " + board[3] + " | " + board[4] + " | " + board[5] + "\n"
	out += "---+---+---\n"
	out += " " + board[6] + " | " + board[7] + " | " + board[8] + "\n"
	out += "```\n\n"
	if winner == "draw" {
		out += "**Draw!**\n"
	} else if winner != "" {
		out += "**" + winner + " wins!**\n"
	} else {
		out += "Next turn: **" + turn + "**\n\n"
		out += "Positions: 0=top-left, 4=center, 8=bottom-right (row-major)\n"
	}
	out += "\nMoves played: " + strconv.Itoa(moves) + "\n"
	return out
}
