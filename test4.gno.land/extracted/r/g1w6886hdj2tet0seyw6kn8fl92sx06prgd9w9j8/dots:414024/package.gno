package dotsandboxes

import (
	"errors"
	"std"

	"gno.land/p/demo/ufmt"
)

const (
	dots = iota
	horizontal
	vertical
)

type Game struct {
	player1, player2 std.Address // Dots and Boxes is a 2 players game
	board            [][]int     // 0: empty, 1: horizontal, 2: vertical
	currentPlayer    std.Address
	playerAScore     int
	playerBScore     int
}

var games = []*Game{}

// NewGame creates a new game where player1 is the caller and player2 the argument.
// A new game index is returned.
func NewGame(player std.Address) int {
	boardSize := 5 // Example board size
	board := make([][]int, 2*boardSize+1)
	for i := range board {
		board[i] = make([]int, 2*boardSize+1)
	}

	newGame := &Game{
		player1:       std.GetOrigCaller(),
		player2:       player,
		board:         board,
		currentPlayer: std.GetOrigCaller(),
	}
	games = append(games, newGame)
	return len(games) - 1
}

// Move executes a move for the game at index idx, where x and y are the coordinates.
func Move(idx, x, y int) error {
	g := games[idx]
	if std.GetOrigCaller() != g.currentPlayer {
		return errors.New("not your turn")
	}

	if x < 0 || y < 0 || x >= len(g.board) || y >= len(g.board[0]) {
		return errors.New("invalid coordinates")
	}

	if g.board[x][y] != dots {
		return errors.New("position already filled")
	}

	// Place the move
	if (x%2 == 0 && y%2 == 1) || (x%2 == 1 && y%2 == 0) {
		g.board[x][y] = horizontal
	} else {
		g.board[x][y] = vertical
	}

	// Update score
	// Here you would add logic to update scores based on the move.

	return nil
}

// Render displays the current state of the game.
func Render(path string) string {
	output := `# 🟢 Dots and Boxes
Actions:
* [NewGame](r/demo/games/dotsandboxes?help&__func=NewGame) opponentAddress
* [Move](r/demo/games/dotsandboxes?help&__func=Move) gameIndex x y

Game Board:
`

	for i := 0; i < len(games); i++ {
		g := games[i]
		output += "Game " + ufmt.Sprint(i) + ":\n"
		for _, row := range g.board {
			for _, cell := range row {
				switch cell {
				case horizontal:
					output += "─"
				case vertical:
					output += "│"
				default:
					output += " "
				}
			}
			output += "\n"
		}
		output += "\nPlayer A Score: " + ufmt.Sprint(g.playerAScore) + "\n"
		output += "Player B Score: " + ufmt.Sprint(g.playerBScore) + "\n"
		output += "Current Turn: " + short(g.currentPlayer) + "\n"
	}

	return output
}

// short shortens the address for display purposes.
func short(addr std.Address) string {
	if len(addr) < 10 {
		return string(addr)
	}
	return string(addr)[:10] + "..."
}
