package minichess

import (
	"strings"
	"testing"

	mc "gno.land/p/g1um2pwwnx3gn8p3ryfdert8mhpu4u4up49sc9ru/minichess"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

var (
	alice = testutils.TestAddress("alice")
	bob   = testutils.TestAddress("bob")
	carol = testutils.TestAddress("carol")
)

func reset() {
	games = avl.NewTree()
	openGames = avl.NewTree()
	playerGames = avl.NewTree()
	nextID = 1
}

func TestSoloAsWhite(cur realm, t *testing.T) {
	reset()
	testing.SetOriginCaller(alice)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := NewSoloGame(cross(cur), "white", 1)
	g := mustGetGame(id)
	uassert.Equal(t, alice.String(), g.White.String())
	uassert.Equal(t, "", g.Black.String())
	uassert.Equal(t, 0, len(g.Moves))

	out := Move(cross(cur), id, "b1c3")
	uassert.True(t, strings.Contains(out, "bot played"), out)
	uassert.Equal(t, 2, len(g.Moves))
	uassert.Equal(t, int(mc.White), int(g.Pos.Turn))
}

func TestSoloAsBlackBotMovesFirst(cur realm, t *testing.T) {
	reset()
	testing.SetOriginCaller(alice)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := NewSoloGame(cross(cur), "black", 2)
	g := mustGetGame(id)
	uassert.Equal(t, 1, len(g.Moves))
	uassert.Equal(t, int(mc.Black), int(g.Pos.Turn))
}

func TestMoveValidation(cur realm, t *testing.T) {
	reset()
	testing.SetOriginCaller(alice)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := NewSoloGame(cross(cur), "white", 1)

	uassert.AbortsWithMessage(t, cur, "illegal move: e2e5", func() {
		Move(cross(cur), id, "e2e5")
	})
	uassert.AbortsWithMessage(t, cur, "chess: move must look like e2e4 or e7e8q", func() {
		Move(cross(cur), id, "b2")
	})
	testing.SetOriginCaller(bob)
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsWithMessage(t, cur, "you are not a player in this game", func() {
		Move(cross(cur), id, "b2b3")
	})
	uassert.AbortsWithMessage(t, cur, "game 99 not found", func() {
		Move(cross(cur), 99, "b2b3")
	})
	uassert.AbortsWithMessage(t, cur, "level must be between 1 and 3", func() {
		NewSoloGame(cross(cur), "white", 4)
	})
}

func TestTwoPlayerCheckmate(cur realm, t *testing.T) {
	reset()
	testing.SetOriginCaller(alice)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := Challenge(cross(cur), "", "white")
	g := mustGetGame(id)
	uassert.Equal(t, int(StateWaiting), int(g.State))
	uassert.True(t, strings.Contains(Render(""), "func=AcceptChallenge&gameID=1"))

	uassert.AbortsWithMessage(t, cur, "you cannot accept your own challenge", func() {
		AcceptChallenge(cross(cur), id)
	})
	testing.SetOriginCaller(bob)
	testing.SetRealm(testing.NewUserRealm(bob))
	AcceptChallenge(cross(cur), id)
	uassert.Equal(t, int(StateActive), int(g.State))
	uassert.Equal(t, bob.String(), g.Black.String())
	uassert.True(t, strings.Contains(Render(""), "_None right now._"))

	uassert.AbortsWithMessage(t, cur, "it is not your turn", func() {
		Move(cross(cur), id, "e7e5")
	})

	// Scholar's mate, with castling-free development: 4. Qxf7#.
	seq := []string{"e2e4", "e7e5", "f1c4", "b8c6", "d1h5", "g8f6", "h5f7"}
	for i, m := range seq {
		if i%2 == 0 {
			testing.SetOriginCaller(alice)
			testing.SetRealm(testing.NewUserRealm(alice))
		} else {
			testing.SetOriginCaller(bob)
			testing.SetRealm(testing.NewUserRealm(bob))
		}
		Move(cross(cur), id, m)
	}
	uassert.Equal(t, int(StateWhiteWon), int(g.State))
	uassert.Equal(t, "checkmate", g.Reason)

	testing.SetOriginCaller(bob)
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsWithMessage(t, cur, "game is not in progress (white won)", func() {
		Move(cross(cur), id, "e8f7")
	})
}

func TestInviteOnlyAndCancel(cur realm, t *testing.T) {
	reset()
	testing.SetOriginCaller(alice)
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsWithMessage(t, cur, "you cannot challenge yourself", func() {
		Challenge(cross(cur), alice.String(), "white")
	})
	uassert.AbortsWithMessage(t, cur, "invalid opponent address", func() {
		Challenge(cross(cur), "not-an-address", "white")
	})
	id := Challenge(cross(cur), bob.String(), "black")

	testing.SetOriginCaller(carol)
	testing.SetRealm(testing.NewUserRealm(carol))
	uassert.AbortsWithMessage(t, cur, "this challenge is for another player", func() {
		AcceptChallenge(cross(cur), id)
	})
	uassert.AbortsWithMessage(t, cur, "only the creator can cancel this challenge", func() {
		CancelChallenge(cross(cur), id)
	})

	testing.SetOriginCaller(alice)
	testing.SetRealm(testing.NewUserRealm(alice))
	CancelChallenge(cross(cur), id)
	uassert.Equal(t, int(StateCancelled), int(mustGetGame(id).State))

	testing.SetOriginCaller(bob)
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsWithMessage(t, cur, "game is not waiting for an opponent", func() {
		AcceptChallenge(cross(cur), id)
	})
}

func TestDrawAndResign(cur realm, t *testing.T) {
	reset()
	testing.SetOriginCaller(alice)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := Challenge(cross(cur), bob.String(), "white")
	testing.SetOriginCaller(bob)
	testing.SetRealm(testing.NewUserRealm(bob))
	AcceptChallenge(cross(cur), id)
	g := mustGetGame(id)

	testing.SetOriginCaller(alice)
	testing.SetRealm(testing.NewUserRealm(alice))
	OfferDraw(cross(cur), id)
	uassert.AbortsWithMessage(t, cur, "there is no draw offer from your opponent", func() {
		AcceptDraw(cross(cur), id)
	})
	testing.SetOriginCaller(bob)
	testing.SetRealm(testing.NewUserRealm(bob))
	AcceptDraw(cross(cur), id)
	uassert.Equal(t, int(StateDraw), int(g.State))

	// New game: offer is declined by moving, then black resigns.
	testing.SetOriginCaller(alice)
	testing.SetRealm(testing.NewUserRealm(alice))
	id2 := Challenge(cross(cur), "", "white")
	testing.SetOriginCaller(bob)
	testing.SetRealm(testing.NewUserRealm(bob))
	AcceptChallenge(cross(cur), id2)
	g2 := mustGetGame(id2)
	testing.SetOriginCaller(alice)
	testing.SetRealm(testing.NewUserRealm(alice))
	Move(cross(cur), id2, "b1c3")
	testing.SetOriginCaller(alice)
	testing.SetRealm(testing.NewUserRealm(alice))
	OfferDraw(cross(cur), id2)
	testing.SetOriginCaller(bob)
	testing.SetRealm(testing.NewUserRealm(bob))
	Move(cross(cur), id2, "g8f6")
	uassert.Equal(t, "", g2.DrawOffer.String())
	Resign(cross(cur), id2)
	uassert.Equal(t, int(StateWhiteWon), int(g2.State))
}

func TestThreefoldRepetition(cur realm, t *testing.T) {
	reset()
	testing.SetOriginCaller(alice)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := Challenge(cross(cur), "", "white")
	testing.SetOriginCaller(bob)
	testing.SetRealm(testing.NewUserRealm(bob))
	AcceptChallenge(cross(cur), id)
	// Knights hop out and back twice: the start position occurs 3 times.
	moves := []string{"g1f3", "g8f6", "f3g1", "f6g8", "g1f3", "g8f6", "f3g1", "f6g8"}
	for i, m := range moves {
		if i%2 == 0 {
			testing.SetOriginCaller(alice)
			testing.SetRealm(testing.NewUserRealm(alice))
		} else {
			testing.SetOriginCaller(bob)
			testing.SetRealm(testing.NewUserRealm(bob))
		}
		Move(cross(cur), id, m)
	}
	g := mustGetGame(id)
	uassert.Equal(t, int(StateDraw), int(g.State))
	uassert.Equal(t, "threefold repetition", g.Reason)
}

func TestSpecialMovesInRealm(cur realm, t *testing.T) {
	reset()
	testing.SetOriginCaller(alice)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := Challenge(cross(cur), bob.String(), "white")
	testing.SetOriginCaller(bob)
	testing.SetRealm(testing.NewUserRealm(bob))
	AcceptChallenge(cross(cur), id)
	g := mustGetGame(id)
	// Castling and en passant through the public API.
	moves := []string{"e2e4", "a7a6", "e4e5", "d7d5", "e5d6", "c7d6", "g1f3", "b8c6", "f1e2", "c8g4", "e1g1"}
	for i, m := range moves {
		if i%2 == 0 {
			testing.SetOriginCaller(alice)
			testing.SetRealm(testing.NewUserRealm(alice))
		} else {
			testing.SetOriginCaller(bob)
			testing.SetRealm(testing.NewUserRealm(bob))
		}
		Move(cross(cur), id, m)
	}
	uassert.Equal(t, int(mc.King), int(g.Pos.PieceAt("g1")))
	uassert.Equal(t, int(mc.Rook), int(g.Pos.PieceAt("f1")))
	uassert.Equal(t, int(mc.Empty), int(g.Pos.PieceAt("d5")))
	uassert.Equal(t, int(StateActive), int(g.State))
}

func TestRender(cur realm, t *testing.T) {
	reset()
	testing.SetOriginCaller(alice)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := NewSoloGame(cross(cur), "white", 1)
	home := Render("")
	uassert.True(t, strings.Contains(home, "# ♟ Mini Chess"))
	uassert.True(t, strings.Contains(home, "$help&func=NewSoloGame&color=white&level=1"))

	page := Render("game/1")
	uassert.True(t, strings.Contains(page, "data:image/svg+xml;base64,"))
	uassert.True(t, strings.Contains(page, "$help&func=Move&gameID=1&move=b1c3"), page)
	uassert.True(t, strings.Contains(page, "White to move"))

	uassert.True(t, strings.Contains(Render("player/"+alice.String()), "#1"))
	uassert.True(t, strings.Contains(Render("rules"), "en passant"))
	uassert.True(t, strings.Contains(Render("game/42"), "does not exist"))
	uassert.Equal(t, mc.StartFEN, GameFEN(id))
	uassert.Equal(t, "in progress, white to move", GameStatus(id))
}
