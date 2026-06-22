// Package rps implements a simple two-player Rock Paper Scissors game.
//
// Note: moves are stored in plaintext on-chain. Player 2 can read
// Player 1's move before submitting their own. For a fair game, a
// commit-reveal scheme would be needed.
package rps

import (
	"strconv"
	"strings"

	"chain"
	"gno.land/p/nt/avl/v0"
)

const (
	Rock     = "rock"
	Paper    = "paper"
	Scissors = "scissors"
)

// Game holds state for a single match.
type Game struct {
	ID      string
	Player1 address
	Player2 address
	Move1   string
	Move2   string
	Status  string // "waiting" | "finished"
	Winner  string // "player1" | "player2" | "draw" | ""
}

var (
	games   avl.Tree
	counter int
)

// NewGame creates a match between the caller (player 1) and opponent (player 2).
// Returns the game ID.
func NewGame(cur realm, opponent address) string {
	if !cur.IsCurrent() {
		panic("spoofed realm")
	}
	if !opponent.IsValid() {
		panic("invalid opponent address")
	}
	caller := cur.Previous().Address()
	if caller == opponent {
		panic("cannot play against yourself")
	}

	counter++
	gameID := strconv.Itoa(counter)

	games.Set(gameID, &Game{
		ID:      gameID,
		Player1: caller,
		Player2: opponent,
		Status:  "waiting",
	})

	chain.Emit("NewGame",
		"gameID", gameID,
		"player1", caller.String(),
		"player2", opponent.String(),
	)

	return gameID
}

// Play submits a move for the calling player. move must be "rock", "paper", or "scissors".
// The game resolves automatically when both players have submitted.
func Play(cur realm, gameID string, move string) {
	if !cur.IsCurrent() {
		panic("spoofed realm")
	}

	move = strings.ToLower(strings.TrimSpace(move))
	if move != Rock && move != Paper && move != Scissors {
		panic("invalid move: must be rock, paper, or scissors")
	}

	val, ok := games.Get(gameID)
	if !ok {
		panic("game not found: " + gameID)
	}
	game := val.(*Game)

	if game.Status == "finished" {
		panic("game already finished")
	}

	caller := cur.Previous().Address()
	switch caller {
	case game.Player1:
		if game.Move1 != "" {
			panic("already submitted a move")
		}
		game.Move1 = move
	case game.Player2:
		if game.Move2 != "" {
			panic("already submitted a move")
		}
		game.Move2 = move
	default:
		panic("not a player in this game")
	}

	if game.Move1 != "" && game.Move2 != "" {
		game.Status = "finished"
		game.Winner = determineWinner(game.Move1, game.Move2)
		chain.Emit("GameFinished",
			"gameID", gameID,
			"winner", game.Winner,
			"move1", game.Move1,
			"move2", game.Move2,
		)
	}
}

func determineWinner(move1, move2 string) string {
	if move1 == move2 {
		return "draw"
	}
	if beats(move1, move2) {
		return "player1"
	}
	return "player2"
}

func beats(a, b string) bool {
	return (a == Rock && b == Scissors) ||
		(a == Paper && b == Rock) ||
		(a == Scissors && b == Paper)
}

// Render shows all games on the home path, or a single game on /{gameID}.
func Render(path string) string {
	path = strings.TrimPrefix(path, "/")

	if path != "" {
		return renderGame(path)
	}

	if games.Size() == 0 {
		return "# Rock Paper Scissors\n\nNo games yet.\n"
	}

	out := "# Rock Paper Scissors\n\n"
	out += "| ID | Player 1 | Player 2 | Status | Winner |\n"
	out += "|---|---|---|---|---|\n"

	games.ReverseIterate("", "", func(key string, val any) bool {
		g := val.(*Game)
		winner := "-"
		switch g.Winner {
		case "player1":
			winner = "Player 1"
		case "player2":
			winner = "Player 2"
		case "draw":
			winner = "Draw"
		}
		out += "| " + g.ID +
			" | " + shortAddr(g.Player1) +
			" | " + shortAddr(g.Player2) +
			" | " + g.Status +
			" | " + winner + " |\n"
		return false
	})

	return out
}

func renderGame(gameID string) string {
	val, ok := games.Get(gameID)
	if !ok {
		return "> [!WARNING]\n> Game not found: " + gameID + "\n"
	}

	g := val.(*Game)
	out := "# Game #" + g.ID + "\n\n"
	out += "- **Player 1**: " + g.Player1.String() + "\n"
	out += "- **Player 2**: " + g.Player2.String() + "\n"
	out += "- **Status**: " + g.Status + "\n\n"

	if g.Status == "finished" {
		out += "## Result\n\n"
		out += "- Player 1 played: **" + g.Move1 + "**\n"
		out += "- Player 2 played: **" + g.Move2 + "**\n\n"
		switch g.Winner {
		case "player1":
			out += "**Player 1 wins!**\n"
		case "player2":
			out += "**Player 2 wins!**\n"
		case "draw":
			out += "**Draw!**\n"
		}
	} else {
		out += "## Moves\n\n"
		if g.Move1 == "" {
			out += "- Player 1: waiting...\n"
		} else {
			out += "- Player 1: submitted\n"
		}
		if g.Move2 == "" {
			out += "- Player 2: waiting...\n"
		} else {
			out += "- Player 2: submitted\n"
		}
	}

	return out
}

func shortAddr(addr address) string {
	s := addr.String()
	if len(s) <= 14 {
		return s
	}
	return s[:6] + "..." + s[len(s)-4:]
}
