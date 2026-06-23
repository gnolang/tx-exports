package tictactoe

import (
	"bytes"
	"strconv"
	"strings"

	"gno.land/p/nt/avl/v0"
	"chain"
)

type cell uint8

const (
	empty cell = 0
	xMark cell = 1
	oMark cell = 2
)

type gameStatus uint8

const (
	statusOngoing gameStatus = 0
	statusXWins   gameStatus = 1
	statusOWins   gameStatus = 2
	statusDraw    gameStatus = 3
)

type game struct {
	id      int
	board   [9]cell
	playerX address
	playerO address
	turn    cell
	status  gameStatus
}

var (
	games   avl.Tree
	counter int
)

// NewGame creates a new tic-tac-toe game. The caller becomes player X.
// Returns the game ID to share with your opponent.
func NewGame(cur realm) int {
	if !cur.IsCurrent() {
		panic("spoofed realm")
	}
	if !cur.Previous().IsUserCall() {
		panic("EOA call only")
	}

	counter++
	g := &game{
		id:      counter,
		playerX: cur.Previous().Address(),
		turn:    xMark,
		status:  statusOngoing,
	}
	games.Set(strconv.Itoa(counter), g)

	chain.Emit("GameCreated",
		"gameID", strconv.Itoa(counter),
		"playerX", g.playerX.String(),
	)

	return counter
}

// Join lets a second player join an existing game as player O.
func Join(cur realm, gameID int) {
	if !cur.IsCurrent() {
		panic("spoofed realm")
	}
	if !cur.Previous().IsUserCall() {
		panic("EOA call only")
	}

	g := mustGetGame(gameID)
	caller := cur.Previous().Address()

	if g.playerO != address("") {
		panic("game already has two players")
	}
	if g.playerX == caller {
		panic("cannot play against yourself")
	}

	g.playerO = caller

	chain.Emit("PlayerJoined",
		"gameID", strconv.Itoa(gameID),
		"playerO", caller.String(),
	)
}

// Move places the caller's mark at the given board position.
// Positions are 0-8, laid out row-major:
//
//	0 | 1 | 2
//	3 | 4 | 5
//	6 | 7 | 8
func Move(cur realm, gameID int, pos int) {
	if !cur.IsCurrent() {
		panic("spoofed realm")
	}
	if !cur.Previous().IsUserCall() {
		panic("EOA call only")
	}

	g := mustGetGame(gameID)
	caller := cur.Previous().Address()

	if g.status != statusOngoing {
		panic("game is already over")
	}
	if g.playerO == address("") {
		panic("waiting for second player to join")
	}
	if g.turn == xMark && caller != g.playerX {
		panic("not your turn")
	}
	if g.turn == oMark && caller != g.playerO {
		panic("not your turn")
	}
	if pos < 0 || pos > 8 {
		panic("position out of range: must be 0-8")
	}
	if g.board[pos] != empty {
		panic("position already occupied")
	}

	g.board[pos] = g.turn

	chain.Emit("MoveMade",
		"gameID", strconv.Itoa(gameID),
		"player", caller.String(),
		"pos", strconv.Itoa(pos),
		"mark", markStr(g.turn),
	)

	if checkWin(g.board, g.turn) {
		if g.turn == xMark {
			g.status = statusXWins
		} else {
			g.status = statusOWins
		}
		chain.Emit("GameOver",
			"gameID", strconv.Itoa(gameID),
			"result", markStr(g.turn)+"Wins",
			"winner", caller.String(),
		)
		return
	}

	if isBoardFull(g.board) {
		g.status = statusDraw
		chain.Emit("GameOver",
			"gameID", strconv.Itoa(gameID),
			"result", "draw",
		)
		return
	}

	if g.turn == xMark {
		g.turn = oMark
	} else {
		g.turn = xMark
	}
}

// Render returns the home page ("") or a specific game ("game/1").
func Render(path string) string {
	if path == "" {
		return renderHome()
	}
	if strings.HasPrefix(path, "game/") {
		idStr := strings.TrimPrefix(path, "game/")
		id, err := strconv.Atoi(idStr)
		if err != nil || id < 1 {
			return "> [!WARNING]\n> Invalid game ID.\n"
		}
		g, ok := getGame(id)
		if !ok {
			return "> [!WARNING]\n> Game not found.\n"
		}
		return renderGame(g)
	}
	return "> [!WARNING]\n> Path not found.\n"
}

func renderHome() string {
	var b bytes.Buffer

	b.WriteString("# Tic-Tac-Toe\n\n")
	b.WriteString("Challenge friends on-chain — create a game and share the link!\n\n")
	b.WriteString("## New Game\n\n")
	b.WriteString("<gno-form exec=\"NewGame\">\n</gno-form>\n\n")

	if counter == 0 {
		b.WriteString("_No games yet — be the first!_\n")
		return b.String()
	}

	b.WriteString("## Games\n\n")
	b.WriteString("| # | Status | Player X | Player O |\n")
	b.WriteString("|---|--------|----------|----------|\n")

	games.Iterate("", "", func(key string, value any) bool {
		g := value.(*game)
		playerO := "_(open)_"
		if g.playerO != address("") {
			playerO = g.playerO.String()
		}
		b.WriteString("| [#" + key + "](:game/" + key + ") | " +
			gameStatusStr(g) + " | " +
			g.playerX.String() + " | " +
			playerO + " |\n")
		return false
	})

	return b.String()
}

func renderGame(g *game) string {
	var b bytes.Buffer
	id := strconv.Itoa(g.id)

	b.WriteString("# Game #" + id + "\n\n")
	b.WriteString(renderBoard(g.board))
	b.WriteString("\n\n")

	switch g.status {
	case statusXWins:
		b.WriteString("> [!SUCCESS]\n> **X wins!** Congratulations!\n\n")
	case statusOWins:
		b.WriteString("> [!SUCCESS]\n> **O wins!** Congratulations!\n\n")
	case statusDraw:
		b.WriteString("> [!INFO]\n> **Draw!** Well played, both.\n\n")
	case statusOngoing:
		if g.playerO == address("") {
			b.WriteString("> [!NOTE]\n> Waiting for Player O to join.\n\n")
			b.WriteString("## Join as Player O\n\n")
			b.WriteString("<gno-form exec=\"Join\">\n")
			b.WriteString("<gno-input name=\"gameID\" value=\"" + id + "\" readonly=\"true\" />\n")
			b.WriteString("</gno-form>\n\n")
		} else {
			b.WriteString("> [!INFO]\n> It's **" + markStr(g.turn) + "'s** turn.\n\n")
			b.WriteString("## Make a Move\n\n")
			b.WriteString("<gno-form exec=\"Move\">\n")
			b.WriteString("<gno-input name=\"gameID\" value=\"" + id + "\" readonly=\"true\" />\n")
			b.WriteString("<gno-input name=\"pos\" type=\"number\" placeholder=\"Position (0-8)\" required=\"true\" />\n")
			b.WriteString("</gno-form>\n\n")
		}
	}

	b.WriteString("**Player X:** " + g.playerX.String() + "\n\n")
	if g.playerO != address("") {
		b.WriteString("**Player O:** " + g.playerO.String() + "\n\n")
	}
	b.WriteString("[← All games](:)\n")

	return b.String()
}

// renderBoard renders the 3x3 board as a markdown table.
// Empty cells show their position number (0-8) to guide the next move.
// The top row doubles as the markdown table header.
func renderBoard(board [9]cell) string {
	var b bytes.Buffer
	b.WriteString("| ")
	for col := 0; col < 3; col++ {
		b.WriteString(cellDisplay(board[col], col) + " | ")
	}
	b.WriteString("\n|:---:|:---:|:---:|\n")
	for row := 1; row < 3; row++ {
		b.WriteString("| ")
		for col := 0; col < 3; col++ {
			pos := row*3 + col
			b.WriteString(cellDisplay(board[pos], pos) + " | ")
		}
		b.WriteString("\n")
	}
	return b.String()
}

func cellDisplay(c cell, pos int) string {
	if c == empty {
		return strconv.Itoa(pos)
	}
	return markStr(c)
}

func markStr(c cell) string {
	if c == xMark {
		return "X"
	}
	return "O"
}

func gameStatusStr(g *game) string {
	switch g.status {
	case statusXWins:
		return "X Wins"
	case statusOWins:
		return "O Wins"
	case statusDraw:
		return "Draw"
	default:
		if g.playerO == address("") {
			return "Open"
		}
		return "Ongoing"
	}
}

func mustGetGame(id int) *game {
	g, ok := getGame(id)
	if !ok {
		panic("game not found: " + strconv.Itoa(id))
	}
	return g
}

func getGame(id int) (*game, bool) {
	v, ok := games.Get(strconv.Itoa(id))
	if !ok {
		return nil, false
	}
	return v.(*game), true
}

var winLines = [8][3]int{
	{0, 1, 2}, {3, 4, 5}, {6, 7, 8},
	{0, 3, 6}, {1, 4, 7}, {2, 5, 8},
	{0, 4, 8}, {2, 4, 6},
}

func checkWin(board [9]cell, mark cell) bool {
	for _, line := range winLines {
		if board[line[0]] == mark && board[line[1]] == mark && board[line[2]] == mark {
			return true
		}
	}
	return false
}

func isBoardFull(board [9]cell) bool {
	for _, c := range board {
		if c == empty {
			return false
		}
	}
	return true
}
