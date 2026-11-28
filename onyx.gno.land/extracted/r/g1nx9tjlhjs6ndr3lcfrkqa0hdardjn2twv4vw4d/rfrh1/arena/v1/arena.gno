// Package arena runs the Ribbonfight league on chain.
//
// Bots are Go functions, ideally in /p/ packages, registered by small entry
// realms from their init. Every pair of bots plays exactly one game on each
// league map. Games are deterministic, so anyone may push a pending game
// forward with PlayPair, a chunk of turns per transaction, and everyone gets
// the same result. The realm stores only match strings; boards, winners and
// pictures are derived by replay.
package arena

import (
	"chain"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"strings"

	"gno.land/p/g1nx9tjlhjs6ndr3lcfrkqa0hdardjn2twv4vw4d/rfrh1/rules/v1"
	"gno.land/p/nt/avl/v0"
)

// League maps (24x24). Their keys are part of every match string.
var maps = []mapInfo{
	{"Open field", 0, 0},
	{"Pillars", 11, 14},
	{"Maze", 29, 30},
}

type mapInfo struct {
	Name    string
	Seed    uint32
	Density int
}

const (
	boardSize = 24
	maxChunk  = 100
	maxBots   = 64
)

// Bot is a registered player.
type Bot struct {
	ID      uint64
	Name    string
	Owner   address
	Entry   string // realm that registered the bot
	Brain   string // package the author says holds the logic (unverified)
	Height  int64
	Retired bool
	Points  int
	Wins    int
	Draws   int
	Losses  int
	Crashes int
	fn      rules.Bot
}

// Game is one league game between two bots on one map.
type Game struct {
	A, B    uint64 // A < B; A plays side A
	Map     int
	Match   string
	Done    bool
	Winner  int // rules.Draw, rules.WinA or rules.WinB once Done
	Turns   int
	Started int64
	Ended   int64
}

var (
	admin   address
	paused  bool
	playing bool

	bots    avl.Tree // id key -> *Bot
	byName  avl.Tree // name -> id
	byEntry avl.Tree // entry realm path -> id
	games   avl.Tree // game key -> *Game
	done    avl.Tree // finish order key -> game key
	nextID  uint64
	nDone   int
	lastKey string
)

// deployer is the initial admin. It can pause the arena, retire bots whose
// games cannot complete, and hand the role on.
const deployer = address("g1nx9tjlhjs6ndr3lcfrkqa0hdardjn2twv4vw4d")

func init() {
	admin = deployer
}

// guard rejects calls while paused or while a game is running (so a bot
// declared in a realm cannot call back into the arena mid-game).
func guard() {
	if playing {
		panic("arena: re-entrant call")
	}
}

func idKey(id uint64) string {
	s := strconv.FormatUint(id, 10)
	for len(s) < 6 {
		s = "0" + s
	}
	return s
}

func gameKey(a, b uint64, m int) string { return idKey(a) + "-" + idKey(b) + "-" + strconv.Itoa(m) }

func leagueMap(i int) rules.Map {
	mi := maps[i]
	return rules.NewMap(boardSize, boardSize, mi.Seed, mi.Density)
}

// Register adds a bot. It must be called by a realm (normally from the
// entry realm's init); that realm path becomes the bot's entry and may
// register only once. name: 3 to 24 chars of a-z, 0-9 and '-'. brain is the
// package path holding the bot's logic, shown as its claimed source.
func Register(cur realm, name, brain string, fn rules.Bot) uint64 {
	guard()
	if paused {
		panic("arena: paused")
	}
	entry := cur.Previous().PkgPath()
	if entry == "" {
		panic("arena: Register must be called from a realm")
	}
	if fn == nil {
		panic("arena: nil bot")
	}
	if !validName(name) {
		panic("arena: name must be 3-24 chars of a-z, 0-9, -")
	}
	if byName.Has(name) {
		panic("arena: name taken")
	}
	if byEntry.Has(entry) {
		panic("arena: this realm already registered a bot")
	}
	if !validPath(brain) {
		panic("arena: brain must be a gno.land/p/ or gno.land/r/ path")
	}
	if bots.Size() >= maxBots {
		panic("arena: league is full")
	}
	nextID++
	b := &Bot{ID: nextID, Name: name, Owner: unsafe.OriginCaller(), Entry: entry, Brain: brain, Height: runtime.ChainHeight(), fn: fn}
	bots.Set(idKey(b.ID), b)
	byName.Set(name, b.ID)
	byEntry.Set(entry, b.ID)
	chain.Emit("BotRegistered", "id", strconv.FormatUint(b.ID, 10), "name", name, "entry", entry)
	return b.ID
}

// PlayPair advances the game between bots a and b on league map m by up to
// n turns (1 to 100). Anyone may call it. It returns the game's status. A
// finished game is never replayed, so calling it again is a no-op.
func PlayPair(cur realm, a, b uint64, m int, n int) string {
	guard()
	if paused {
		panic("arena: paused")
	}
	if a == b {
		panic("arena: a bot does not play itself")
	}
	if a > b {
		a, b = b, a
	}
	if m < 0 || m >= len(maps) {
		panic("arena: unknown map")
	}
	if n < 1 || n > maxChunk {
		panic("arena: n must be 1 to 100")
	}
	ba, bb := mustBot(a), mustBot(b)
	if ba.Retired || bb.Retired {
		panic("arena: retired bot")
	}
	key := gameKey(a, b, m)
	var gm *Game
	if v := games.Get(key); v != nil {
		gm = v.(*Game)
	} else {
		gm = &Game{A: a, B: b, Map: m, Match: rules.NewGame(leagueMap(m)).String(), Started: runtime.ChainHeight()}
		games.Set(key, gm)
	}
	if gm.Done {
		return status(gm)
	}
	g, err := rules.ReplayTo(gm.Match, -1)
	if err != nil {
		panic("arena: corrupt match")
	}
	playing = true
	g.Advance(ba.fn, bb.fn, n)
	playing = false
	gm.Match = g.String()
	gm.Turns = g.Turn()
	if g.Over() {
		finish(gm, g.Result(), ba, bb, key)
	}
	return status(gm)
}

func finish(gm *Game, r rules.Result, ba, bb *Bot, key string) {
	gm.Done = true
	gm.Winner = r.Winner
	gm.Ended = runtime.ChainHeight()
	switch r.Winner {
	case rules.WinA:
		ba.Points += 2
		ba.Wins++
		bb.Losses++
	case rules.WinB:
		bb.Points += 2
		bb.Wins++
		ba.Losses++
	default:
		ba.Points++
		bb.Points++
		ba.Draws++
		bb.Draws++
	}
	if r.DeathA == rules.Crashed {
		ba.Crashes++
	}
	if r.DeathB == rules.Crashed {
		bb.Crashes++
	}
	nDone++
	done.Set(idKey(uint64(nDone)), key)
	lastKey = key
	chain.Emit("GamePlayed", "key", key, "winner", strconv.Itoa(r.Winner), "turns", strconv.Itoa(r.Turns))
}

func status(gm *Game) string {
	if !gm.Done {
		return "pending at turn " + strconv.Itoa(gm.Turns)
	}
	switch gm.Winner {
	case rules.WinA:
		return "done: " + botName(gm.A) + " won in " + strconv.Itoa(gm.Turns)
	case rules.WinB:
		return "done: " + botName(gm.B) + " won in " + strconv.Itoa(gm.Turns)
	}
	return "done: draw in " + strconv.Itoa(gm.Turns)
}

// Pause stops Register and PlayPair (admin only).
func Pause(cur realm, on bool) {
	assertAdmin(cur)
	paused = on
	chain.Emit("Paused", "on", strconv.FormatBool(on))
}

// Retire removes a bot from the league table and from future games (admin
// only). Use it for bots whose games cannot complete; finished games keep
// their results.
func Retire(cur realm, id uint64) {
	assertAdmin(cur)
	b := mustBot(id)
	b.Retired = true
	chain.Emit("BotRetired", "id", strconv.FormatUint(id, 10))
}

// TransferAdmin hands the admin role to another address (admin only).
func TransferAdmin(cur realm, to address) {
	assertAdmin(cur)
	if !to.IsValid() {
		panic("arena: invalid address")
	}
	admin = to
}

func assertAdmin(cur realm) {
	guard()
	if cur.Previous().Address() != admin {
		panic("arena: admin only")
	}
}

func mustBot(id uint64) *Bot {
	v := bots.Get(idKey(id))
	if v == nil {
		panic("arena: unknown bot")
	}
	return v.(*Bot)
}

func getBot(id uint64) (*Bot, bool) {
	v := bots.Get(idKey(id))
	if v == nil {
		return nil, false
	}
	return v.(*Bot), true
}

func botName(id uint64) string {
	if b, ok := getBot(id); ok {
		return b.Name
	}
	return "?"
}

func validName(s string) bool {
	if len(s) < 3 || len(s) > 24 {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '-') {
			return false
		}
	}
	return true
}

func validPath(s string) bool {
	if !(strings.HasPrefix(s, "gno.land/p/") || strings.HasPrefix(s, "gno.land/r/")) || len(s) > 120 {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '/' || c == '_' || c == '.' || c == '-') {
			return false
		}
	}
	return true
}
