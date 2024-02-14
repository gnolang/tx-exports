package tictactoe

import (
	"std"
	"strconv"

	"gno.land/p/demo/avl"
)

type gameState struct {
	ID         string
	board      [3][3]int8
	turnPlayer int8
	player1    string
	player2    string
	winner     int8
	status     int8 // 0=open 1=closed
}

var (
	allGames       avl.Tree
	nextGameId     int64
	availableGames []string
	userGames      avl.Tree
)

const zeroes = "000000000"

// zeroPad9 pads s to the left with zeroes until it's at least 9 bytes long.
func zeroPad9(s string) string {
	n := 9 - len(s)
	if n < 0 {
		return s
	}
	return zeroes[:n] + s
}

func StartGame(_ string) string {
	std.AssertOriginCall()
	caller := std.GetOrigCaller()
	return startGame(caller)
}

func startGame(player std.Address) string {
	nextGameId++
	// id is zero-padded to work well with avl's alphabetic order.
	id := zeroPad9(strconv.FormatInt(nextGameId, 10))
	g := &gameState{
		ID:         id,
		board:      [3][3]int8{},
		turnPlayer: 1,
		player1:    string(player),
		player2:    "",
		status:     0,
	}
	allGames.Set(string(g.ID), g)
	availableGames = append(availableGames, g.ID)
	addGameToUser(g.ID, player)
	return g.ID
}

func marshalGameState(g gameState) string {
	out := "{"
	out = out + `"ID": "` + g.ID + `",`
	out = out + `"turnPlayer": ` + strconv.Itoa(int(g.turnPlayer)) + `,`
	out = out + `"player1": "` + g.player1 + `",`
	out = out + `"player2": "` + g.player2 + `",`
	out = out + `"status": ` + strconv.Itoa(int(g.status)) + `,`
	out = out + `"winner": ` + strconv.Itoa(int(g.winner)) + `,`
	out = out + `"board": [`
	for i, v := range g.board {
		out = out + marshalIntSlice(v[:])
		if i != (len(v) - 1) {
			out = out + ","
		}
	}
	out = out + "]}"
	return out
}

func marshalIntSlice(s []int8) string {
	out := "["
	for i, v := range s {
		out = out + strconv.Itoa(int(v))
		if i != (len(s) - 1) {
			out = out + ","
		}
	}
	out = out + "]"
	return out
}

func addGameToUser(gameId string, player std.Address) {
	var games []string
	v, ok := userGames.Get(string(player))
	if ok {
		games = v.([]string)
	}
	games = append([]string{gameId}, games...)
	userGames.Set(string(player), games)
}

func GetGames(address string) string {
	return marshalStringSlice(getGames(address))
}

func getGames(player string) []string {
	var games []string
	v, ok := userGames.Get(player)
	if ok {
		games = v.([]string)
	}
	return games
}

func GetAvailableGames(_ string) string {
	return marshalStringSlice(availableGames)
}

func marshalStringSlice(slice []string) string {
	out := "["
	for i, v := range slice {
		out = out + "\"" + v + "\""
		if i != (len(slice) - 1) {
			out = out + ","
		}
	}
	out = out + "]"
	return out
}

func JoinGame(gameId string) bool {
	std.AssertOriginCall()
	caller := std.GetOrigCaller()
	return joinGame(gameId, caller)
}

func joinGame(gameId string, player std.Address) bool {
	graw, ok := allGames.Get(gameId)
	if ok {
		g := graw.(*gameState)
		if g.player2 != "" {
			panic("Game not available")
		}
		g.player2 = string(player)
		allGames.Set(g.ID, g)
		removeFromAvailableGames(g.ID)
		return ok
	}
	panic("Game not found")
}

func indexOf(element string, data []string) int {
	for k, v := range data {
		if element == v {
			return k
		}
	}
	return -1 // not found.
}

func removeFromAvailableGames(gameId string) {
	index := indexOf(gameId, availableGames)
	if index == -1 {
		panic("Game was not available")
	}
	if index == 0 && len(availableGames) == 1 {
		availableGames = []string{}
	} else {
		newAvailableGames := availableGames[:len(availableGames)-1]
		newAvailableGames[index] = availableGames[len(availableGames)-1]
		availableGames = append([]string{}, newAvailableGames...)
	}
}

func MakeMove(gameId string, row, col int8) int8 {
	std.AssertOriginCall()
	caller := std.GetOrigCaller()
	return makeMove(gameId, row, col, caller)
}

func makeMove(gameId string, row, col int8, player std.Address) int8 {
	graw, ok := allGames.Get(gameId)
	if ok {
		g := graw.(*gameState)
		if g.status == 1 {
			panic("Game has ended")
		}
		if g.player1 != string(player) && g.player2 != string(player) {
			panic("You are not part of this game")
		}
		if (g.turnPlayer == 1 && g.player1 != string(player)) || (g.turnPlayer == 2 && g.player2 != string(player)) {
			panic("Not your turn")
		}
		if row < 0 || col < 0 || row >= 3 || col >= 3 {
			panic("Move position out of bounds")
		}
		if g.board[row][col] != 0 {
			panic("Square not empty")
		}

		g.board[row][col] = g.turnPlayer
		winner := checkForWinner(g)
		if winner != 0 {
			if winner != 3 {
				g.winner = winner
			}
			g.status = 1
		} else {
			if g.turnPlayer == 1 {
				g.turnPlayer = 2
			} else {
				g.turnPlayer = 1
			}
		}
		allGames.Set(g.ID, g)
		return g.status
	}
	panic("Game not found")
}

func checkForWinner(g *gameState) int8 {
	checkLine := func(startRow int, startColumn int, dr int, dc int) int8 {
		var lastSquare int8 = g.board[startRow][startColumn]
		row, column := startRow+dr, startColumn+dc
		for row >= 0 && column >= 0 && row < 3 && column < 3 {
			if g.board[row][column] == 0 {
				// Empty, can't win
				return 0
			}
			if lastSquare != g.board[row][column] {
				// different from last square in line, can't win
				return 0
			}
			lastSquare = g.board[row][column]
			row, column = row+dr, column+dc
		}
		// if not returned, we have a winner
		return lastSquare
	}

	for row := 0; row < 3; row++ {
		if result := checkLine(row, 0, 0, 1); result != 0 {
			return result
		}
	}
	for column := 0; column < 3; column++ {
		if result := checkLine(0, column, 1, 0); result != 0 {
			return result
		}
	}
	if result := checkLine(0, 0, 1, 1); result != 0 {
		return result
	}
	if result := checkLine(0, 2, 1, -1); result != 0 {
		return result
	}
	for _, row := range g.board {
		for _, square := range row {
			if square == 0 {
				return 0
			}
		}
	}
	// no empty square and no winner = draw
	return 3
}

func GetGame(gameId string) string {
	graw, ok := allGames.Get(gameId)
	if ok {
		g := graw.(*gameState)
		return marshalGameState(*g)
	} else {
		panic("Game not found")
	}
}

func Render(path string) string {
	if path == "" {
		return "Welcome to tictactoe"
	} else {
		graw, ok := allGames.Get(path)
		if ok {
			g := graw.(*gameState)
			out := "\n"
			for i, row := range g.board {
				for j, square := range row {
					out = out + " "
					switch square {
					case 0:
						out = out + " "
					case 1:
						out = out + "X"
					case 2:
						out = out + "O"
					}
					if j != len(row)-1 {
						out = out + " |"
					}
				}
				if i != len(g.board)-1 {
					out = out + "\n------------"
				}
				out = out + "\n"
			}
			return out
		} else {
			return "Game not found"
		}
	}
}