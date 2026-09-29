// Package gno4 is Connect Four with the chain as the referee.
//
// The rules live in [p/moul/gno4](/p/moul/gno4/v0), which knows nothing about
// the chain. This realm owns the three things a pure engine cannot: who may
// move, when, and what the world gets to see. That split is the whole design,
// and it is why the engine has 14 tests that need no node.
//
// Nothing here is a wager. A game holds no coins, so there is no escrow, no
// payout and no abandoned-table timeout to get wrong. Money is a second design
// and not a flag on this one.
package gno4

import (
	"chain/runtime"
	"errors"

	"gno.land/p/moul/gno4/v0"
	"gno.land/p/nt/avl/v0"
)

// Game is one table.
//
// The position is NOT stored: Moves is, and the board is replayed from it on
// demand. Three reasons, in the order they matter. The move list is the whole
// game in at most 42 bytes, so storage is minimal and bounded. It is the
// engine's own canonical form, so no second encoder can disagree with it. And
// an engine change never needs a state migration, because the only thing on
// chain is the input, which no engine version can reinterpret.
type Game struct {
	ID      int
	Red     address
	Yellow  address // zero while the table is open
	Moves   string  // gno4.Board.Encode()
	Opened  int64   // block height
	Touched int64   // block height of the last move
	Quit    address // whoever resigned, zero otherwise
}

// Record is a player's standing. Rating is deliberately absent: an Elo needs a
// K factor, a provisional period and an answer for resignations, and every one
// of those is a policy argument that would outlive the three lines of code.
type Record struct {
	Wins, Losses, Draws int
}

var (
	games   avl.Tree // padded id -> *Game
	records avl.Tree // address -> *Record
	nextID  = 1

	// open and live are id lists kept in most-recent-first order. An avl walk
	// could derive both, but it would walk every game ever played to render a
	// page that shows ten, and that cost grows forever.
	open []int
	live []int
	done []int
)

const doneKept = 20 // how many finished games the home page remembers

var (
	ErrNoSuchGame  = errors.New("gno4: no such game")
	ErrNotOpen     = errors.New("gno4: that table is not open")
	ErrOwnGame     = errors.New("gno4: you cannot play yourself")
	ErrNotYours    = errors.New("gno4: you are not in this game")
	ErrNotYourTurn = errors.New("gno4: not your turn")
	ErrFinished    = errors.New("gno4: that game is over")
)

// Open starts a table anyone may join. The caller takes red and moves first.
func Open(cur realm) int {
	caller := cur.Previous().Address()
	g := &Game{
		ID:     nextID,
		Red:    caller,
		Opened: runtime.ChainHeight(),
	}
	nextID++
	games.Set(key(g.ID), g)
	open = prepend(open, g.ID)
	return g.ID
}

// Join takes the yellow seat of an open table.
func Join(cur realm, id int) {
	g := mustGame(id)
	caller := cur.Previous().Address()
	if g.Yellow != "" {
		panic(ErrNotOpen)
	}
	if g.Red == caller {
		panic(ErrOwnGame)
	}
	g.Yellow = caller
	g.Touched = runtime.ChainHeight()
	open = remove(open, id)
	live = prepend(live, id)
}

// Play drops the caller's disc into col, counted from 1.
//
// Every refusal below is a rule the engine cannot enforce, because the engine
// has no idea who is calling. The engine still owns "is that column legal",
// and Drop is what answers it.
func Play(cur realm, id, col int) {
	g := mustGame(id)
	caller := cur.Previous().Address()
	if g.Over() {
		panic(ErrFinished)
	}
	if g.Yellow == "" {
		panic(ErrNotOpen)
	}
	b := g.Board()
	var seat address
	if b.Turn() == gno4.Red {
		seat = g.Red
	} else {
		seat = g.Yellow
	}
	if caller != g.Red && caller != g.Yellow {
		panic(ErrNotYours)
	}
	if caller != seat {
		panic(ErrNotYourTurn)
	}
	if _, err := b.Drop(col - 1); err != nil {
		panic(err)
	}
	g.Moves = b.Encode()
	g.Touched = runtime.ChainHeight()
	if b.Over() {
		finish(g, b.Winner())
	}
}

// Resign concedes. A game nobody resigns and nobody finishes stays live
// forever; that is a known hole, and a timeout is the fix, not a cron.
func Resign(cur realm, id int) {
	g := mustGame(id)
	caller := cur.Previous().Address()
	if g.Over() {
		panic(ErrFinished)
	}
	if caller != g.Red && caller != g.Yellow {
		panic(ErrNotYours)
	}
	g.Quit = caller
	g.Touched = runtime.ChainHeight()
	if g.Yellow == "" {
		// An open table nobody joined: withdraw it, and score nothing.
		open = remove(open, id)
		done = trim(prepend(done, id))
		return
	}
	winner := gno4.Red
	if caller == g.Red {
		winner = gno4.Yellow
	}
	finish(g, winner)
}

func finish(g *Game, winner gno4.Disc) {
	live = remove(live, g.ID)
	done = trim(prepend(done, g.ID))
	switch winner {
	case gno4.Red:
		record(g.Red).Wins++
		record(g.Yellow).Losses++
	case gno4.Yellow:
		record(g.Yellow).Wins++
		record(g.Red).Losses++
	default:
		record(g.Red).Draws++
		record(g.Yellow).Draws++
	}
}

// Board replays the move list. It never returns nil and never panics: a stored
// encoding that no longer decodes would make the game's page unreadable
// forever, so it degrades to an empty board instead.
func (g *Game) Board() *gno4.Board {
	b, err := gno4.Decode(g.Moves)
	if err != nil {
		return gno4.New()
	}
	return b
}

// Over reports whether the game is settled, by the rules or by a resignation.
func (g *Game) Over() bool { return g.Quit != "" || g.Board().Over() }

// Winner returns the winning seat, or the zero address on a draw, an open
// table or a game still in play.
func (g *Game) Winner() address {
	if g.Quit != "" {
		if g.Quit == g.Red {
			return g.Yellow
		}
		return g.Red
	}
	switch g.Board().Winner() {
	case gno4.Red:
		return g.Red
	case gno4.Yellow:
		return g.Yellow
	}
	return ""
}

// GameOf returns a copy of one game's public facts, for another realm or an
// off-chain reader that wants state rather than a rendered page.
//
// It returns values, not the *Game: this realm is private = true, so handing
// out a pointer into its own storage is the one thing that cannot be undone
// later.
func GameOf(id int) (red, yellow address, moves string, over bool) {
	v := games.Get(key(id))
	if v == nil {
		return "", "", "", false
	}
	g := v.(*Game)
	return g.Red, g.Yellow, g.Moves, g.Over()
}

// RecordOf returns a player's standing.
func RecordOf(addr address) (wins, losses, draws int) {
	v := records.Get(addr.String())
	if v == nil {
		return 0, 0, 0
	}
	r := v.(*Record)
	return r.Wins, r.Losses, r.Draws
}

func mustGame(id int) *Game {
	v := games.Get(key(id))
	if v == nil {
		panic(ErrNoSuchGame)
	}
	return v.(*Game)
}

func record(addr address) *Record {
	if v := records.Get(addr.String()); v != nil {
		return v.(*Record)
	}
	r := &Record{}
	records.Set(addr.String(), r)
	return r
}

// key zero-pads an id so avl's byte ordering is numeric ordering. ufmt has no
// width verb, which is why this is five lines instead of one.
func key(id int) string {
	s := itoa(id)
	for len(s) < 10 {
		s = "0" + s
	}
	return s
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	neg := n < 0
	if neg {
		n = -n
	}
	out := ""
	for n > 0 {
		out = string(rune('0'+n%10)) + out
		n /= 10
	}
	if neg {
		out = "-" + out
	}
	return out
}

func prepend(list []int, id int) []int {
	return append([]int{id}, list...)
}

func remove(list []int, id int) []int {
	out := make([]int, 0, len(list))
	for _, v := range list {
		if v != id {
			out = append(out, v)
		}
	}
	return out
}

func trim(list []int) []int {
	if len(list) > doneKept {
		return list[:doneKept]
	}
	return list
}

// Feed returns every game this realm knows, one per line, newest first:
//
//	<id>\t<red>\t<yellow>\t<moves>\t<state>
//
// where state is open, live, or the address that won, or "draw".
//
// A realm that only renders markdown forces its own front-end to scrape the
// page it renders, and then a wording change breaks the app. So there are two
// views of the same state: Render for people, Feed for programs. Neither is
// derived from the other, both are derived from the state, and the machine one
// is the cheap one to keep stable.
func Feed() string {
	out := ""
	games.ReverseIterate("", "", func(_ string, v any) bool {
		out += line(v.(*Game)) + "\n"
		return false
	})
	return out
}

// Line returns one game in the same shape as [Feed], or "" if there is no such
// game. A front-end polling one table asks for this, not for the whole feed.
func Line(id int) string {
	v := games.Get(key(id))
	if v == nil {
		return ""
	}
	return line(v.(*Game))
}

func line(g *Game) string {
	state := "live"
	switch {
	case g.Yellow == "" && g.Quit == "":
		state = "open"
	case g.Over():
		if w := g.Winner(); w != "" {
			state = w.String()
		} else if g.Yellow == "" {
			state = "withdrawn"
		} else {
			state = "draw"
		}
	}
	return itoa(g.ID) + "\t" + g.Red.String() + "\t" + g.Yellow.String() + "\t" + g.Moves + "\t" + state
}
