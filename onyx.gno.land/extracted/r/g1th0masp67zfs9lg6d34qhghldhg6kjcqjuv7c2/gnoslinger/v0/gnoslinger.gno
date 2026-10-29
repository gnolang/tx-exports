// Package gnoslinger is the on-chain lobby and referee of Gunslinger
// showdowns (the 1982 Avalon Hill gunfight game) of two to four players.
// Players create and join games and play their turn plans hidden: each
// commits the hash of its plan, then reveals it once every plan is
// committed (DESIGN_HIDDEN_PLANS.md); the realm resolves each turn with the
// pure engine package and keeps the result for the web client to animate.
package gnoslinger

import (
	"crypto/sha256"
	enchex "encoding/hex"
	"strconv"
	"time"

	"gno.land/p/g1th0masp67zfs9lg6d34qhghldhg6kjcqjuv7c2/gnoslinger/engine/v0"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/seqid/v0"
	profiles "gno.land/r/g1th0masp67zfs9lg6d34qhghldhg6kjcqjuv7c2/gnoslinger/profiles/v0"
)

const (
	realmPath = "gno.land/r/g1th0masp67zfs9lg6d34qhghldhg6kjcqjuv7c2/gnoslinger/v0"

	// DefaultTimeout is how long a turn may sit without progress before
	// anyone can call ClaimTimeout on it, when CreateGame gets 0.
	DefaultTimeout = 48 * time.Hour
	// MinTimeout and MaxTimeout bound the timeout a creator may pick.
	MinTimeout = 5 * time.Minute
	MaxTimeout = 30 * 24 * time.Hour
	// MinMaxTurns and MaxMaxTurns bound the game length.
	MinMaxTurns = 10
	MaxMaxTurns = 30
	// MaxMissed is the turns in a row a player may let time out: each is
	// passed for it, the last puts its character out of the fight.
	MaxMissed = 3
	// RevealGrace is how long after the commit deadline a claim waits
	// before it may pass the turn of a seat whose plan is not revealed: the
	// timelocked plans open LockDelay after the deadline, and their opener
	// needs time for its transaction.
	RevealGrace = 5 * time.Minute
	// LockDelay puts the drand round the plans are timelocked to after the
	// deadline, past any drift between the block time and drand's clock.
	LockDelay = 2 * time.Minute
	// MaxLocked bounds the size of a timelocked plan.
	MaxLocked = 1024
	// MaxSalt bounds the size of a salt (hex).
	MaxSalt = 64
	// The drand quicknet chain the plans are timelocked to: its genesis
	// (unix seconds) and the seconds between two rounds.
	DrandGenesis = 1692803367
	DrandPeriod  = 3
)

// Phase is where a game stands.
type Phase int

const (
	// PhaseWaiting: the seats are filling up.
	PhaseWaiting Phase = iota
	// PhasePlanning: every seat taken; collecting the commits of the
	// current turn.
	PhasePlanning
	// PhaseFinished: over, see Game.EndReason.
	PhaseFinished
	// PhaseRevealing: every seat in the fight committed; collecting the
	// reveals.
	PhaseRevealing
)

// String returns the phase name used in JSON views.
func (p Phase) String() string {
	switch p {
	case PhaseWaiting:
		return "waiting"
	case PhasePlanning:
		return "planning"
	case PhaseFinished:
		return "finished"
	case PhaseRevealing:
		return "revealing"
	}
	return "?"
}

// Player is a seat: the address that controls it (empty while nobody took
// it) and its character token.
type Player struct {
	Addr address
	Char string
}

// TurnResult is the outcome of one resolved turn, kept so the client can
// replay it: the state the turn started from, the plans (one per seat),
// and what happened. Seed lets anyone re-run the resolution; Cards is the
// trace of the result cards drawn from the deck it shuffles, in order. The
// start snapshot, the weapons on the ground at the start, the cards and the
// events are kept in the engine's compact text encodings: as structs they
// cost a hundred times more storage (see engine/encode.gno). With the
// ground, a turn is shown from its own record, without the turns before it.
type TurnResult struct {
	Turn      int
	Plans     []string
	Seed      string
	StartEnc  string // engine.EncodeChars
	GroundEnc string // engine.EncodeGround
	CardsEnc  string // engine.EncodeInts
	EventsEnc string // engine.EncodeEvents
}

func newTurnResult(turn int, start []engine.Character, ground string, plans []string, seed string, cards []int, evs []engine.Event) *TurnResult {
	return &TurnResult{
		Turn: turn, Plans: plans, Seed: seed, StartEnc: engine.EncodeChars(start), GroundEnc: ground,
		CardsEnc: engine.EncodeInts(cards), EventsEnc: engine.EncodeEvents(evs),
	}
}

// Start is the state of every seat when the turn began.
func (r *TurnResult) Start() []engine.Character { return engine.DecodeChars(r.StartEnc) }

// Ground is the weapons lying on the board when the turn began.
func (r *TurnResult) Ground() []engine.GroundGun { return engine.DecodeGround(r.GroundEnc) }

// Cards is the result cards drawn during the turn, in order.
func (r *TurnResult) Cards() []int { return engine.DecodeInts(r.CardsEnc) }

// Events is what happened during the turn, in order.
func (r *TurnResult) Events() []engine.Event { return engine.DecodeEvents(r.EventsEnc) }

// Sealed is a seat's sealed plan for the turn in progress, cleared by its
// reveal.
type Sealed struct {
	Hash   string // PlanHash of the seat's salt and plan; "" until committed
	Locked string // the salt and plan timelocked to LockRound
}

// Game is one showdown. Players, Commits, Plans, Salts, Revealed, Missed and
// VP have one entry per seat, the seats filling up in the order the players
// join.
type Game struct {
	ID        string
	Players   []Player
	State     engine.State
	Turn      int // 1-based
	MaxTurns  int
	Timeout   time.Duration // the time a turn gives, from TurnStart, after which ClaimTimeout succeeds
	Phase     Phase
	Commits   []Sealed      // the turn in progress, each cleared by its seat's reveal
	Plans     []string      // the turn in progress, revealed, canonical form
	Salts     []string      // the turn in progress, revealed; part of the deck's seed
	Revealed  []bool        // the turn in progress: the seat's plan is in (revealed, or passed)
	Missed    []int         // turns in a row each seat let time out, reset by a revealed plan
	TurnStart time.Time     // when the turn in progress started: its clock, left alone by the saves within the turn
	Turns     []*TurnResult // resolved turns, in order (at most MaxTurns)
	Winner    int           // seat index, -1 for none: the most victory points, -1 on a tie
	EndReason string
	// Awards are the victory points earned and lost so far (rule 15), at
	// the end of each turn and of the showdown; VP adds them up per seat.
	Awards []engine.Award
	VP     []int
	// Stake is what each player puts in, in ugnot (0: a free showdown);
	// Pot what the realm holds for the showdown, the stakes paid so far.
	// Payouts is what each seat got once the showdown is over (nil before,
	// and for a free one), HouseCut what the house kept (stakes.gno).
	Stake     int64
	Pot       int64
	Payouts   []int64
	HouseCut  int64
	Rev       int // bumped on every change; clients poll it
	CreatedAt time.Time
	UpdatedAt time.Time
}

var (
	games     = avl.NewTree() // id -> *Game
	gameSeq   seqid.ID
	byPlayer  = avl.NewTree() // address -> []string game ids, newest first
	openGames = avl.NewTree() // id -> *Game while a seat is free
)

func getGame(id string) *Game {
	if _, err := seqid.FromString(id); err != nil {
		panic("gnoslinger: invalid game id")
	}
	v := games.Get(id)
	if v == nil {
		panic("gnoslinger: game not found")
	}
	return v.(*Game)
}

// seats is the number of seats of the game, taken or not.
func (g *Game) seats() int { return len(g.Players) }

// seat returns the seat of addr in g, or -1.
func (g *Game) seat(addr address) int {
	for i, p := range g.Players {
		if p.Addr == addr && p.Addr != "" {
			return i
		}
	}
	return -1
}

func (g *Game) mustSeat(addr address) int {
	p := g.seat(addr)
	if p < 0 {
		panic("gnoslinger: you are not a player of this game")
	}
	return p
}

// freeSeat is the first seat nobody took, -1 once every seat is taken.
func (g *Game) freeSeat() int {
	for i, p := range g.Players {
		if p.Addr == "" {
			return i
		}
	}
	return -1
}

// seated counts the seats taken.
func (g *Game) seated() int {
	n := 0
	for _, p := range g.Players {
		if p.Addr != "" {
			n++
		}
	}
	return n
}

// committed reports whether seat p committed its plan this turn (revealed
// or not).
func (g *Game) committed(p int) bool { return g.Commits[p].Hash != "" || g.Revealed[p] }

// allCommitted reports whether every character still in the fight
// committed its plan.
func (g *Game) allCommitted() bool {
	for p := range g.Players {
		if g.State.Chars[p].Status == engine.Alive && !g.committed(p) {
			return false
		}
	}
	return true
}

// allRevealed reports whether the turn has every plan it waits for: one
// from each character still in the fight.
func (g *Game) allRevealed() bool {
	for p := range g.Players {
		if g.State.Chars[p].Status == engine.Alive && !g.Revealed[p] {
			return false
		}
	}
	return true
}

// clearTurn forgets the commits and plans of the turn.
func (g *Game) clearTurn() {
	n := g.seats()
	g.Commits = make([]Sealed, n)
	g.Plans = make([]string, n)
	g.Salts = make([]string, n)
	g.Revealed = make([]bool, n)
}

// PlanHash is what a seat commits: the sha256, in hex, of its salt and plan
// for that game, turn and seat ("gnoslinger|id|turn|seat|salt|plan").
func PlanHash(id string, turn, seat int, salt, plan string) string {
	h := sha256.Sum256([]byte("gnoslinger|" + id + "|" + strconv.Itoa(turn) + "|" + strconv.Itoa(seat) + "|" + salt + "|" + plan))
	return enchex.EncodeToString(h[:])
}

// lastTurn is the most recently resolved turn, or nil.
func (g *Game) lastTurn() *TurnResult {
	if len(g.Turns) == 0 {
		return nil
	}
	return g.Turns[len(g.Turns)-1]
}

// commitUntil is the turn's deadline: commits are refused from then, and
// the turn can be claimed if commits are missing. Timeout after the turn's
// start whatever happened since (a commit does not restart it); a game
// waiting for players has none.
func (g *Game) commitUntil() time.Time { return g.TurnStart.Add(g.Timeout) }

// revealUntil is when a claim may put the seats that did not reveal out of
// the fight: RevealGrace after the deadline.
func (g *Game) revealUntil() time.Time { return g.commitUntil().Add(RevealGrace) }

// timeoutAt is when the turn in progress becomes claimable through
// ClaimTimeout: the deadline while planning, revealUntil while revealing.
func (g *Game) timeoutAt() time.Time {
	if g.Phase == PhaseRevealing {
		return g.revealUntil()
	}
	return g.commitUntil()
}

// LockRound is the drand quicknet round the turn's plans are timelocked
// to: the first round after the deadline plus LockDelay. The realm never
// checks anything about drand: the round only tells every client the same.
func (g *Game) lockRound() int64 {
	return (g.commitUntil().Add(LockDelay).Unix()-DrandGenesis)/DrandPeriod + 2
}

// startTurn starts the turn's clock.
func (g *Game) startTurn() { g.TurnStart = time.Now() }

// assertInTime refuses a commit once the turn's deadline passed: from
// then it can only be claimed (ClaimTimeout), so playing late cannot turn
// a lost game around, nor win it by claiming right after.
func (g *Game) assertInTime() {
	if !time.Now().Before(g.commitUntil()) {
		panic("gnoslinger: out of time: the game can only be claimed now")
	}
}

// award records victory points (rule 15): each award is a VictoryPoints
// event, adds to the seat's total and to the player's profile (in the
// profiles realm, which cur, the crossing call's, gets to write).
func (g *Game) award(cur realm, awards []engine.Award) {
	for _, a := range awards {
		g.Awards = append(g.Awards, a)
		g.VP[a.Player] += a.Points
		emit("VictoryPoints", "id", g.ID, "seat", strconv.Itoa(a.Player), "player", g.Players[a.Player].Addr.String(),
			"reason", a.Reason, "points", strconv.Itoa(a.Points))
		profiles.AddVictoryPoints(cross(cur), g.Players[a.Player].Addr, a.Points)
	}
}

// finish ends the game: the most victory points win, a tie for the most (a
// game nobody played included) being a draw; the pot is paid out (cur,
// the crossing call's, pays from the realm).
func (g *Game) finish(cur realm, reason string) {
	g.Phase = PhaseFinished
	g.EndReason = reason
	g.Winner = -1
	best, tie := 0, false
	for p, v := range g.VP {
		switch {
		case g.Winner < 0 || v > best:
			g.Winner, best, tie = p, v, false
		case v == best:
			tie = true
		}
	}
	if tie {
		g.Winner = -1
	}
	w := ""
	if g.Winner >= 0 {
		w = g.Players[g.Winner].Addr.String()
	}
	emit("GameEnded", "id", g.ID, "reason", reason, "winner", w)
	g.notifyOver()
	g.payPot(cur)
}

// save records a change: bumps the revision and the activity clock.
func save(g *Game) {
	g.Rev++
	g.UpdatedAt = time.Now()
	games.Set(g.ID, g)
}

func index(addr address, id string) {
	var ids []string
	if v := byPlayer.Get(addr.String()); v != nil {
		ids = v.([]string)
	}
	byPlayer.Set(addr.String(), append([]string{id}, ids...))
}

// unindex removes id from addr's games, and addr from byPlayer once it has
// none left.
func unindex(addr address, id string) {
	v := byPlayer.Get(addr.String())
	if v == nil {
		return
	}
	var ids []string
	for _, x := range v.([]string) {
		if x != id {
			ids = append(ids, x)
		}
	}
	if len(ids) == 0 {
		byPlayer.Remove(addr.String())
		return
	}
	byPlayer.Set(addr.String(), ids)
}
