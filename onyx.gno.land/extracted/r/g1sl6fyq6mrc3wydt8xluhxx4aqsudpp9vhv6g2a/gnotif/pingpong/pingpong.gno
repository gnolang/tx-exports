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

	"gno.land/r/g1sl6fyq6mrc3wydt8xluhxx4aqsudpp9vhv6g2a/gnotif"
)

// Game is a match between First and Second. First plays turn 1.
type Game struct {
	ID                  string
	First, Second, Next address
	Turn                int
}

var (
	games    avl.Tree // id → *Game
	lastGame seqid.ID
	declared bool
)

// NewGame opens a game against opponent and returns its id. The caller plays first.
func NewGame(cur realm, opponent address) string {
	caller := cur.Previous().Address()
	if opponent == caller {
		panic("cannot play against yourself")
	}
	g := &Game{ID: lastGame.Next().String(), First: caller, Second: opponent, Next: caller}
	games.Set(g.ID, g)
	chain.Emit("GameCreated", "game", g.ID, "first", g.First.String(), "second", g.Second.String())
	return g.ID
}

// Play takes the caller's turn in game and passes it to the other player.
func Play(cur realm, game string) {
	v := games.Get(game)
	if v == nil {
		panic("unknown game")
	}
	g := v.(*Game)
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

// DeclareTriggers declares the "your turn" trigger in the gnotif registry.
// The registry sees this realm as the caller, so the trigger is verified.
func DeclareTriggers(cur realm) {
	if declared {
		panic("triggers already declared")
	}
	declared = true
	gnotif.Declare(cross(cur), cur.PkgPath(), "TurnPlayed", "", "next", "Your turn", "Game {game}, turn {turn}", "/?game={game}")
}

// Render lists the games with their players, turn and next player.
func Render(path string) string {
	var b strings.Builder
	b.WriteString("# pingpong\n\n")
	games.Iterate("", "", func(_ string, v any) bool {
		g := v.(*Game)
		b.WriteString("- **" + g.ID + "** " + g.First.String() + " vs " + g.Second.String() +
			" · turn " + strconv.Itoa(g.Turn) + " · next " + g.Next.String() + "\n")
		return false
	})
	return b.String()
}
