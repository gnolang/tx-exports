// Package pingpong is a two-player game where the only move is to pass the
// turn. It exists to demonstrate gnotif: every turn emits TurnPlayed, and
// the realm declares a verified gnotif trigger that tells the next player.
package pingpong

import (
	"chain"
	"strconv"
	"strings"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/seqid/v0"

	"gno.land/r/g1rzgxl6njyu4c2x89gxvaa9cswrt73rz8mlp7l6/gnotif/v0"
)

// Game is a match between First and Second. First plays turn 1. It is
// pending until Second accepts, and only then are players named in events
// that notify them.
type Game struct {
	ID                  string
	First, Second, Next address
	Turn                int
	Started             bool
}

var (
	games    avl.Tree // id → *Game
	lastGame seqid.ID
	declared bool
)

func load(id string) *Game {
	if !games.Has(id) {
		panic("unknown game")
	}
	return games.Get(id).(*Game)
}

// NewGame invites opponent to a game and returns its id. The caller plays
// first once opponent accepts.
func NewGame(cur realm, opponent address) string {
	caller := cur.Previous().Address()
	// IsValid accepts all-uppercase bech32, but a caller's address is always
	// lowercase, so an uppercase opponent could never accept.
	if !opponent.IsValid() || opponent.String() != strings.ToLower(opponent.String()) {
		panic("invalid opponent")
	}
	if opponent == caller {
		panic("cannot play against yourself")
	}
	g := &Game{ID: lastGame.Next().String(), First: caller, Second: opponent, Next: caller}
	games.Set(g.ID, g)
	chain.Emit("GameInvited", "game", g.ID, "first", g.First.String(), "second", g.Second.String())
	return g.ID
}

// Accept starts a pending game. Only the invited player may call it.
func Accept(cur realm, game string) {
	g := load(game)
	if g.Second != cur.Previous().Address() {
		panic("not invited")
	}
	if g.Started {
		panic("game already started")
	}
	g.Started = true
	chain.Emit("GameStarted", "game", g.ID, "first", g.First.String(), "second", g.Second.String())
}

// Play takes the caller's turn in game and passes it to the other player.
func Play(cur realm, game string) {
	g := load(game)
	if !g.Started {
		panic("game not started")
	}
	if g.Next != cur.Previous().Address() {
		panic("not your turn")
	}
	if g.Next == g.First {
		g.Next = g.Second
	} else {
		g.Next = g.First
	}
	g.Turn++
	chain.Emit("TurnPlayed", "game", g.ID, "next", g.Next.String(), "turn", strconv.Itoa(g.Turn))
}

// Leave cancels a pending game or ends a started one, and deletes it.
func Leave(cur realm, game string) {
	g := load(game)
	caller := cur.Previous().Address()
	if caller != g.First && caller != g.Second {
		panic("not a player")
	}
	games.Remove(game)
	chain.Emit("GameEnded", "game", g.ID, "by", caller.String())
}

// DeclareTriggers declares the "your turn" trigger in the gnotif registry.
// The registry sees this realm as the caller, so the trigger is verified.
func DeclareTriggers(cur realm) {
	if declared {
		panic("triggers already declared")
	}
	declared = true
	gnotif.Declare(cross(cur), cur.PkgPath(), "TurnPlayed", "", "next", "Your turn", "Game {game}, turn {turn}", "/?game={game}")
}
