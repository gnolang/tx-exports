// Package minichess is an on-chain chess game (standard 8x8 board).
//
// Two ways to play:
//
//   - Solo: NewSoloGame starts a game against the built-in bot. The bot
//     replies inside the same transaction as your move.
//   - Two players: Challenge creates a game (open to anyone, or for one
//     invited address); AcceptChallenge takes the empty seat.
//
// Moves use coordinate notation: "e2e4", "g1f3", castling as the king's
// move ("e1g1"), en passant as the pawn's move to the target square, and
// promotion as "e7e8" (queen) or "e7e8n" (under-promotion). Visit the realm
// in gnoweb to see the board and click legal moves.
package minichess

import (
	"chain"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"strings"

	mc "gno.land/p/g1um2pwwnx3gn8p3ryfdert8mhpu4u4up49sc9ru/minichess"
	"gno.land/p/nt/avl/v0"
)

// Mode is how a game is played.
type Mode int

const (
	ModeSolo      Mode = iota // human vs bot
	ModeTwoPlayer             // human vs human
)

func (m Mode) String() string {
	if m == ModeSolo {
		return "vs bot"
	}
	return "two-player"
}

// State is a game's lifecycle stage.
type State int

const (
	StateWaiting State = iota // challenge waiting for an opponent
	StateActive               // being played
	StateWhiteWon
	StateBlackWon
	StateDraw
	StateCancelled // challenge withdrawn before anyone joined
)

func (s State) String() string {
	switch s {
	case StateWaiting:
		return "waiting for opponent"
	case StateActive:
		return "in progress"
	case StateWhiteWon:
		return "white won"
	case StateBlackWon:
		return "black won"
	case StateDraw:
		return "draw"
	case StateCancelled:
		return "cancelled"
	}
	return "unknown"
}

// Finished reports whether the game is over.
func (s State) Finished() bool { return s >= StateWhiteWon }

// Game is one game of minichess.
type Game struct {
	ID        int
	Mode      Mode
	White     address // empty: the bot (solo) or an open seat (waiting)
	Black     address
	Creator   address
	Invitee   address // two-player challenge target; empty = open to all
	BotLevel  int     // solo only
	Pos       mc.Position
	Moves     []string // coordinate notation, in order
	History   []string // board keys since the last capture or pawn move
	Hashes    []uint64 // position hashes since the last capture or pawn move (for the bot)
	State     State
	Reason    string  // how the game ended
	DrawOffer address // player with a pending draw offer
	CreatedAt int64   // block height
	UpdatedAt int64
}

var (
	games       = avl.NewTree() // padded id -> *Game
	openGames   = avl.NewTree() // padded id -> *Game, challenges awaiting an opponent
	playerGames = avl.NewTree() // address -> []int
	nextID      = 1
	realmPath   string // e.g. "/r/g1um2pwwnx3gn8p3ryfdert8mhpu4u4up49sc9ru/minichess", for links
)

func init() {
	p := unsafe.CurrentRealm().PkgPath()
	realmPath = strings.TrimPrefix(p, "gno.land")
}

// ---------------------------------------------------------------------------
// Public, state-changing functions (crossing).

// NewSoloGame starts a game against the bot.
// color: "white", "black" or "random". level: 1 (easy) to 3 (hard).
// If you play black, the bot makes the first move immediately.
func NewSoloGame(cur realm, color string, level int) int {
	caller := cur.Previous().Address()
	if level < mc.MinLevel || level > mc.MaxLevel {
		panic("level must be between " + strconv.Itoa(mc.MinLevel) + " and " + strconv.Itoa(mc.MaxLevel))
	}
	side := parseColor(color)

	g := newGame(ModeSolo, caller)
	g.BotLevel = level
	g.State = StateActive
	if side == mc.White {
		g.White = caller
	} else {
		g.Black = caller
	}
	saveGame(g)
	addPlayerGame(caller, g.ID)
	chain.Emit("GameCreated", "id", strconv.Itoa(g.ID), "mode", "solo", "player", caller.String())

	if side == mc.Black {
		botMove(g)
	}
	return g.ID
}

// Challenge creates a two-player game. opponent may be empty (anyone can
// accept) or a g1... address (only they can accept). color is the
// challenger's side: "white", "black" or "random".
func Challenge(cur realm, opponent string, color string) int {
	caller := cur.Previous().Address()
	side := parseColor(color)

	var invitee address
	opponent = strings.TrimSpace(opponent)
	if opponent != "" {
		invitee = address(opponent)
		if !invitee.IsValid() {
			panic("invalid opponent address")
		}
		if invitee == caller {
			panic("you cannot challenge yourself")
		}
	}

	g := newGame(ModeTwoPlayer, caller)
	g.Invitee = invitee
	if side == mc.White {
		g.White = caller
	} else {
		g.Black = caller
	}
	saveGame(g)
	openGames.Set(gameKey(g.ID), g)
	addPlayerGame(caller, g.ID)
	if invitee != "" {
		addPlayerGame(invitee, g.ID)
	}
	chain.Emit("ChallengeCreated", "id", strconv.Itoa(g.ID), "creator", caller.String(), "invitee", invitee.String())
	return g.ID
}

// AcceptChallenge takes the open seat in a waiting two-player game.
func AcceptChallenge(cur realm, gameID int) {
	caller := cur.Previous().Address()
	g := mustGetGame(gameID)
	if g.State != StateWaiting {
		panic("game is not waiting for an opponent")
	}
	if caller == g.Creator {
		panic("you cannot accept your own challenge")
	}
	if g.Invitee != "" && caller != g.Invitee {
		panic("this challenge is for another player")
	}
	if g.White == "" {
		g.White = caller
	} else {
		g.Black = caller
	}
	g.State = StateActive
	openGames.Remove(gameKey(g.ID))
	touch(g)
	if g.Invitee == "" {
		addPlayerGame(caller, g.ID)
	}
	chain.Emit("ChallengeAccepted", "id", strconv.Itoa(g.ID), "player", caller.String())
}

// CancelChallenge withdraws a challenge nobody has accepted yet.
func CancelChallenge(cur realm, gameID int) {
	caller := cur.Previous().Address()
	g := mustGetGame(gameID)
	if caller != g.Creator {
		panic("only the creator can cancel this challenge")
	}
	if g.State != StateWaiting {
		panic("only waiting challenges can be cancelled")
	}
	g.State = StateCancelled
	g.Reason = "challenge withdrawn"
	openGames.Remove(gameKey(g.ID))
	touch(g)
	chain.Emit("ChallengeCancelled", "id", strconv.Itoa(g.ID))
}

// Move plays a move, e.g. "e2e4", "e1g1" (castling) or "e7e8q". In a solo game the bot
// answers in the same transaction. Returns a short summary.
func Move(cur realm, gameID int, move string) string {
	caller := cur.Previous().Address()
	g := mustGetGame(gameID)
	if g.State != StateActive {
		panic("game is not in progress (" + g.State.String() + ")")
	}
	if g.playerToMove() != caller {
		if !g.IsPlayer(caller) {
			panic("you are not a player in this game")
		}
		panic("it is not your turn")
	}

	m, err := mc.ParseMove(move)
	if err != nil {
		panic(err.Error())
	}
	lm, ok := g.Pos.FindLegal(m)
	if !ok {
		panic("illegal move: " + m.String())
	}
	g.apply(lm)
	if g.DrawOffer != "" && g.DrawOffer != caller {
		g.DrawOffer = "" // moving instead of accepting declines the offer
	}
	summary := "you played " + lm.String()

	if g.Mode == ModeSolo && g.State == StateActive {
		if bm, ok := botMove(g); ok {
			summary += ", bot played " + bm
		}
	}
	touch(g)
	if g.State.Finished() {
		summary += ". Game over: " + g.State.String() + " (" + g.Reason + ")"
	}
	return summary
}

// Resign ends the game as a loss for the caller.
func Resign(cur realm, gameID int) {
	caller := cur.Previous().Address()
	g := mustGetGame(gameID)
	if g.State != StateActive {
		panic("game is not in progress")
	}
	switch caller {
	case g.White:
		g.finish(StateBlackWon, "white resigned")
	case g.Black:
		g.finish(StateWhiteWon, "black resigned")
	default:
		panic("you are not a player in this game")
	}
	touch(g)
}

// OfferDraw offers a draw in a two-player game. If your opponent has
// already offered one, this accepts it.
func OfferDraw(cur realm, gameID int) {
	caller := cur.Previous().Address()
	g := mustGetGame(gameID)
	g.assertActiveTwoPlayer(caller)
	if g.DrawOffer != "" && g.DrawOffer != caller {
		g.finish(StateDraw, "draw agreed")
	} else {
		g.DrawOffer = caller
		chain.Emit("DrawOffered", "id", strconv.Itoa(g.ID), "by", caller.String())
	}
	touch(g)
}

// AcceptDraw accepts your opponent's pending draw offer.
func AcceptDraw(cur realm, gameID int) {
	caller := cur.Previous().Address()
	g := mustGetGame(gameID)
	g.assertActiveTwoPlayer(caller)
	if g.DrawOffer == "" || g.DrawOffer == caller {
		panic("there is no draw offer from your opponent")
	}
	g.finish(StateDraw, "draw agreed")
	touch(g)
}

// ---------------------------------------------------------------------------
// Read-only helpers (callable with vm/qeval).

// GameFEN returns the current position of a game in FEN notation.
func GameFEN(gameID int) string {
	return mustGetGame(gameID).Pos.FEN()
}

// GameStatus returns a one-line status for a game.
func GameStatus(gameID int) string {
	g := mustGetGame(gameID)
	s := g.State.String()
	if g.State == StateActive {
		s += ", " + g.Pos.Turn.String() + " to move"
	}
	if g.Reason != "" {
		s += " (" + g.Reason + ")"
	}
	return s
}

// LegalMoves returns the legal moves of a game as a space-separated list.
func LegalMoves(gameID int) string {
	g := mustGetGame(gameID)
	if g.State != StateActive {
		return ""
	}
	out := []string{}
	for _, m := range g.Pos.LegalMoves() {
		out = append(out, m.String())
	}
	return strings.Join(out, " ")
}

// ---------------------------------------------------------------------------
// Internals.

func newGame(mode Mode, creator address) *Game {
	h := runtime.ChainHeight()
	g := &Game{
		ID:        nextID,
		Mode:      mode,
		Creator:   creator,
		Pos:       mc.NewGame(),
		State:     StateWaiting,
		CreatedAt: h,
		UpdatedAt: h,
	}
	g.History = []string{g.Pos.BoardKey()}
	g.Hashes = []uint64{g.Pos.Hash()}
	nextID++
	return g
}

func parseColor(color string) mc.Color {
	switch strings.ToLower(strings.TrimSpace(color)) {
	case "white", "w", "":
		return mc.White
	case "black", "b":
		return mc.Black
	case "random", "r":
		// Deterministic but unpredictable enough for picking a side.
		if (runtime.ChainHeight()+int64(nextID))%2 == 0 {
			return mc.White
		}
		return mc.Black
	}
	panic("color must be white, black or random")
}

func gameKey(id int) string {
	s := strconv.Itoa(id)
	for len(s) < 10 {
		s = "0" + s
	}
	return s
}

func saveGame(g *Game) { games.Set(gameKey(g.ID), g) }

func getGame(id int) (*Game, bool) {
	v := games.Get(gameKey(id))
	if v == nil {
		return nil, false
	}
	return v.(*Game), true
}

func mustGetGame(id int) *Game {
	g, ok := getGame(id)
	if !ok {
		panic("game " + strconv.Itoa(id) + " not found")
	}
	return g
}

func addPlayerGame(a address, id int) {
	var ids []int
	if v := playerGames.Get(a.String()); v != nil {
		ids = v.([]int)
	}
	playerGames.Set(a.String(), append(ids, id))
}

func touch(g *Game) { g.UpdatedAt = runtime.ChainHeight() }

// IsPlayer reports whether a is one of the game's human players.
func (g *Game) IsPlayer(a address) bool {
	return a != "" && (a == g.White || a == g.Black)
}

// playerToMove is the address whose turn it is ("" = the bot).
func (g *Game) playerToMove() address {
	if g.Pos.Turn == mc.White {
		return g.White
	}
	return g.Black
}

func (g *Game) assertActiveTwoPlayer(caller address) {
	if g.Mode != ModeTwoPlayer {
		panic("draw offers are only for two-player games; resign to end a bot game")
	}
	if g.State != StateActive {
		panic("game is not in progress")
	}
	if !g.IsPlayer(caller) {
		panic("you are not a player in this game")
	}
}

// apply plays a legal move and updates the game result.
func (g *Game) apply(m mc.Move) {
	irreversible := g.Pos.IsIrreversible(m)
	g.Pos = g.Pos.Play(m)
	g.Moves = append(g.Moves, m.String())
	key := g.Pos.BoardKey()
	h := g.Pos.Hash()
	if irreversible {
		g.History = []string{key}
		g.Hashes = []uint64{h}
	} else {
		g.History = append(g.History, key)
		g.Hashes = append(g.Hashes, h)
	}

	switch g.Pos.Status() {
	case mc.Checkmate:
		if g.Pos.Turn == mc.White {
			g.finish(StateBlackWon, "checkmate")
		} else {
			g.finish(StateWhiteWon, "checkmate")
		}
		return
	case mc.Stalemate:
		g.finish(StateDraw, "stalemate")
		return
	case mc.InsufficientMaterial:
		g.finish(StateDraw, "insufficient material")
		return
	case mc.FiftyMoveDraw:
		g.finish(StateDraw, "50-move rule")
		return
	}
	reps := 0
	for _, k := range g.History {
		if k == key {
			reps++
		}
	}
	if reps >= 3 {
		g.finish(StateDraw, "threefold repetition")
	}
}

func (g *Game) finish(s State, reason string) {
	g.State = s
	g.Reason = reason
	g.DrawOffer = ""
	chain.Emit("GameOver", "id", strconv.Itoa(g.ID), "result", s.String(), "reason", reason)
}

// botMove lets the bot play if it is its turn in an active solo game.
func botMove(g *Game) (string, bool) {
	if g.Mode != ModeSolo || g.State != StateActive || g.playerToMove() != "" {
		return "", false
	}
	seed := g.ID*1009 + len(g.Moves)
	m, ok := mc.BestMoveWithHistory(g.Pos, g.BotLevel, seed, g.Hashes)
	if !ok {
		return "", false
	}
	g.apply(m)
	return m.String(), true
}
