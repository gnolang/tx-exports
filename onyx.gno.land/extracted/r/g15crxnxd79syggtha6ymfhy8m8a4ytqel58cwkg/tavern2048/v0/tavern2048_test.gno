package tavern2048

import (
	"strings"
	"testing"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

var (
	alice = testutils.TestAddress("alice")
	bob   = testutils.TestAddress("bob")
)

func resetState() {
	games = avl.NewTree()
	best = avl.NewTree()
	totalGames = 0
	totalMoves = 0
}

func countTiles(b Board) int {
	n := 0
	for i := 0; i < N; i++ {
		for j := 0; j < N; j++ {
			if b.Cells[i][j] != 0 {
				n++
			}
		}
	}
	return n
}

// moveAny tries every direction until one changes the board.
func moveAny(cur realm, g *Game) bool {
	for _, d := range []string{"left", "up", "right", "down"} {
		before := g.Board.Moves
		Move(cross(cur), d)
		if g.Board.Moves > before {
			return true
		}
	}
	return false
}

func TestNewGameAndMove(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(alice))
	NewGame(cross(cur))

	v := games.Get(alice.String())
	if v == nil {
		t.Fatal("alice should have a game keyed by her address")
	}
	g := v.(*Game)
	if countTiles(g.Board) != 2 {
		t.Fatalf("new board must have 2 tiles, got %d", countTiles(g.Board))
	}
	if !moveAny(cur, g) {
		t.Fatal("a fresh board must allow a move")
	}
	if g.Board.Moves != 1 || totalMoves != 1 {
		t.Fatalf("moves=%d total=%d, want 1/1", g.Board.Moves, totalMoves)
	}
	if countTiles(g.Board) < 2 {
		t.Fatal("a move must spawn a tile")
	}
}

func TestPlayersAreIsolated(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(alice))
	NewGame(cross(cur))
	ga := games.Get(alice.String()).(*Game)
	moveAny(cur, ga)

	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsWithMessage(t, cur, "no game yet: call NewGame first", func() {
		Move(cross(cur), "left")
	})
	NewGame(cross(cur))
	if games.Size() != 2 {
		t.Fatalf("want 2 games, got %d", games.Size())
	}
	if ga.Board.Moves != 1 {
		t.Fatal("bob must not touch alice's board")
	}
}

func TestInvalidInput(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(alice))
	NewGame(cross(cur))
	uassert.AbortsWithMessage(t, cur, "invalid direction diagonal: use up, down, left or right", func() {
		Move(cross(cur), "diagonal")
	})
	uassert.AbortsWithMessage(t, cur, "invalid move x: use only u, d, l, r", func() {
		Play(cross(cur), "lrx")
	})
	uassert.AbortsWithMessage(t, cur, "no moves given: e.g. lldrul", func() {
		Play(cross(cur), " , ")
	})
	uassert.AbortsWithMessage(t, cur, "too many moves: at most 64 per call", func() {
		Play(cross(cur), strings.Repeat("l", 65))
	})
}

func TestPlaySequenceAndBest(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(alice))
	NewGame(cross(cur))
	g := games.Get(alice.String()).(*Game)
	for i := 0; i < 20 && !g.Board.Over; i++ {
		testing.SkipHeights(1)
		Play(cross(cur), "ldru ldru ldru ldru")
	}
	if g.Board.Moves < 10 {
		t.Fatalf("expected many moves, got %d", g.Board.Moves)
	}
	if BestOf(alice) != g.Board.Score || ScoreOf(alice) != g.Board.Score {
		t.Fatalf("best=%d score=%d current=%d", BestOf(alice), ScoreOf(alice), g.Board.Score)
	}
	top := g.Board.Score
	// a new game resets the board but keeps the best score
	NewGame(cross(cur))
	if ScoreOf(alice) != 0 || BestOf(alice) != top {
		t.Fatalf("after NewGame: score=%d best=%d want 0/%d", ScoreOf(alice), BestOf(alice), top)
	}
}

func TestRender(cur realm, t *testing.T) {
	resetState()
	home := Render("")
	if !strings.Contains(home, "Tavern2048") || !strings.Contains(home, "No scores yet") {
		t.Fatalf("empty home render wrong:\n%s", home)
	}
	testing.SetRealm(testing.NewUserRealm(alice))
	NewGame(cross(cur))
	g := games.Get(alice.String()).(*Game)
	moveAny(cur, g)

	home = Render("")
	if !strings.Contains(home, "Leaderboard") || !strings.Contains(home, realmPath+":"+alice.String()) {
		t.Fatalf("home must link alice's board:\n%s", home)
	}
	page := Render(alice.String())
	if !strings.Contains(page, "data:image/svg+xml;base64,") {
		t.Fatalf("player page must embed the SVG board:\n%s", page)
	}
	if !strings.Contains(page, "<gno-form exec=\"Play\">") {
		t.Fatal("player page must offer the Play form")
	}
	if !strings.Contains(Render(bob.String()), "has not started a game") {
		t.Fatal("unknown player page wrong")
	}
	if !strings.Contains(Render("nope"), "Not found") {
		t.Fatal("bad path must render Not found")
	}
}
