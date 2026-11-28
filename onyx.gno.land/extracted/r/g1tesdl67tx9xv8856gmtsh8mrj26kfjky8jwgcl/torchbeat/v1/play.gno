package torchbeat

import (
	"chain"
	"chain/runtime"
	"strconv"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/g1tesdl67tx9xv8856gmtsh8mrj26kfjky8jwgcl/torchbeat/commit"
	"gno.land/p/g1tesdl67tx9xv8856gmtsh8mrj26kfjky8jwgcl/torchbeat/sim"
)

const (
	revealWindow = 600 // blocks a commit stays revealable
	boardSize    = 3
)

// Star bits a run earns on a room.
const (
	starCleared  uint8 = 1
	starFlawless uint8 = 2 // no damage taken
	starPar      uint8 = 4 // beats <= the room's par
)

// Pending is a player's one outstanding commit.
type Pending struct {
	Entry commit.Entry
	Room  string
}

// Player is a player's (or author's) totals.
type Player struct {
	Renown  int // unique clearers, other than itself, of rooms this address authored
	Relics  int // bitmask: bit r set when relic r is owned
	Cleared int // rooms cleared at least once
	Stars   int // sum of star bits over every room
}

// Progress is a player's record on one room.
type Progress struct {
	Best   uint16 // fewest beats; ties keep the lower damage
	Damage uint8  // damage of the Best run
	Stars  uint8  // union of star bits over every clear
}

// Run is a board entry.
type Run struct {
	Owner  address
	Beats  uint16
	Damage uint8
	Route  uint32
	Log    string
	Height int64 // the run's commit height
	Relic  uint8 // the relic the run was played with
}

var (
	commits  = avl.NewTree() // addr -> *Pending
	players  = avl.NewTree() // addr -> *Player
	progress = avl.NewTree() // progressKey(addr, room ID) -> *Progress
	boards   = avl.NewTree() // room ID -> []Run, best first, at most boardSize
	// explorers indexes every player with a clear by explorerKey, so in-order
	// iteration lists the top explorers first. Its size is the number of
	// unique explorers.
	explorers = avl.NewTree()

	totalClears int // every cleared run, all rooms
)

// Commit records hash = commit.Hash(caller, roomID, relic, log, salt) as the
// caller's pending run, replacing any earlier one. User calls only. It panics
// with caller, hash, unknown, or hidden (a hidden room cannot be revealed, so
// a commit to it would only hold storage).
func Commit(cur realm, roomID, hash string) {
	caller := userCaller(cur)
	if !isLowerHex(hash, 64) {
		panic("hash")
	}
	v := rooms.Get(roomID)
	if v == nil {
		panic("unknown")
	}
	if v.(*Room).Hidden {
		panic("hidden")
	}
	commits.Set(caller.String(), &Pending{
		Entry: commit.Entry{Hash: hash, Height: runtime.ChainHeight()},
		Room:  roomID,
	})
}

// Cancel drops the caller's pending commit, if any. User calls only.
func Cancel(cur realm) {
	commits.Remove(userCaller(cur).String())
}

// Reveal replays the caller's committed run on roomID and, if it clears,
// records it and emits Clear. User calls only. It panics with a reason code:
// caller, salt, log, unknown, hidden, none, early, expired, mismatch, relic,
// locked, or "run:" + the sim reason. The commit is kept unless the run clears.
func Reveal(cur realm, roomID, log string, relic int, salt string) {
	player := userCaller(cur)
	if !isLowerHex(salt, 32) {
		panic("salt")
	}
	r, why := playable(roomID, log)
	if why != "" {
		panic(why)
	}
	who := player.String()
	var e commit.Entry
	if v := commits.Get(who); v != nil && v.(*Pending).Room == roomID {
		e = v.(*Pending).Entry
	}
	if why := commit.CheckReveal(e, runtime.ChainHeight(), revealWindow, commit.Hash(who, roomID, relic, log, salt)); why != "" {
		panic(why)
	}
	res, why := replay(r, who, log, relic)
	if why != "" {
		panic(why)
	}
	commits.Remove(who)
	first := record(r, who, res)
	enterBoard(roomID, Run{Owner: player, Beats: res.Beats, Damage: res.Damage, Route: res.RouteHash, Log: log, Height: e.Height, Relic: uint8(relic)})
	chain.Emit("Clear", "room", roomID, "player", who, "beats", strconv.Itoa(int(res.Beats)),
		"route", routeHex(res.RouteHash), "first", strconv.FormatBool(first))
}

func userCaller(cur realm) address {
	prev := cur.Previous()
	if !prev.IsUserCall() {
		panic("caller")
	}
	return prev.Address()
}

// playable checks a log's charset and length and that roomID is a visible room.
func playable(roomID, log string) (*Room, string) {
	if !validLog(log) {
		return nil, "log"
	}
	v := rooms.Get(roomID)
	if v == nil {
		return nil, "unknown"
	}
	r := v.(*Room)
	if r.Hidden {
		return nil, "hidden"
	}
	return r, ""
}

// replay checks the relic and adjacency for player who (skipped when who is
// "", except the relic's range) and runs log. It returns the cleared result or
// a reason code.
func replay(r *Room, who, log string, relic int) (sim.Result, string) {
	if relic < 0 || relic > 2 {
		return sim.Result{}, "relic"
	}
	if who != "" {
		if relic != 0 && relicsOf(who)&(1<<uint(relic)) == 0 {
			return sim.Result{}, "relic"
		}
		x, y := int(r.X), int(r.Y)
		if !reached(who, x+1, y) && !reached(who, x-1, y) && !reached(who, x, y+1) && !reached(who, x, y-1) {
			return sim.Result{}, "locked"
		}
	}
	res := sim.Run(&r.Static.Map, uint8(relic), log)
	if !res.Cleared {
		return res, "run:" + res.Reason
	}
	return res, ""
}

// reached reports whether (x, y) is the hub or a room who has cleared.
func reached(who string, x, y int) bool {
	if x == 0 && y == 0 {
		return true
	}
	v := world.Get(cellKey(x, y))
	return v != nil && progress.Has(progressKey(who, v.(string)))
}

// record applies a cleared run's rewards, keeps the explorers index in step,
// and reports whether it was who's first clear of r.
func record(r *Room, who string, res sim.Result) bool {
	r.Clears++
	totalClears++
	p := playerOf(who, true)
	old := explorerKey(who, p.Cleared, p.Stars)
	first := credit(r, p, who, res)
	if k := explorerKey(who, p.Cleared, p.Stars); k != old {
		if old != "" {
			explorers.Remove(old)
		}
		explorers.Set(k, nil)
	}
	return first
}

// explorerKey is who's key in the explorers index, or "" for a player without
// a clear: 4 digits of 9999 - cleared, 4 of 9999 - stars, then the address, so
// more rooms sort first, then more stars, then the lower address. Counts are
// clamped to 9999 (at most 1088 rooms exist, so they never reach it).
func explorerKey(who string, cleared, stars int) string {
	if cleared <= 0 {
		return ""
	}
	return pad4(9999-min9999(cleared)) + pad4(9999-min9999(stars)) + who
}

func min9999(n int) int {
	if n > 9999 {
		return 9999
	}
	return n
}

// pad4 formats 0 <= n <= 9999 as 4 digits. Its callers stay in range: the
// explorer counts are clamped, and the publish sequence (the newest index)
// stays below the 1088 cells a world has (33x33 minus the hub), far under
// 10000.
func pad4(n int) string {
	s := strconv.Itoa(n)
	return "0000"[len(s):] + s
}

// credit applies a cleared run to r and p and reports whether it was who's
// first clear of r. A first clear counts toward Uniques and, unless who is the
// author, the author's renown. Opening the chest grants its relic on any clear.
func credit(r *Room, p *Player, who string, res sim.Result) bool {
	if c := r.Static.Chest; c != 0 && res.Chest {
		p.Relics |= 1 << uint(c)
	}
	earned := starsFor(r, res)
	key := progressKey(who, r.ID)
	v := progress.Get(key)
	if v == nil {
		progress.Set(key, &Progress{Best: res.Beats, Damage: res.Damage, Stars: earned})
		p.Cleared++
		p.Stars += popcount(earned)
		r.Uniques++
		if author := r.Author.String(); author != who {
			playerOf(author, true).Renown++
		}
		return true
	}
	pr := v.(*Progress)
	p.Stars += popcount(earned &^ pr.Stars)
	pr.Stars |= earned
	if res.Beats < pr.Best || (res.Beats == pr.Best && res.Damage < pr.Damage) {
		pr.Best, pr.Damage = res.Beats, res.Damage
	}
	return false
}

func starsFor(r *Room, res sim.Result) uint8 {
	s := starCleared
	if res.Damage == 0 {
		s |= starFlawless
	}
	if res.Beats <= r.Static.Par {
		s |= starPar
	}
	return s
}

func popcount(b uint8) int {
	n := 0
	for ; b != 0; b &= b - 1 {
		n++
	}
	return n
}

// enterBoard stores run on roomID's board if it ranks.
func enterBoard(roomID string, run Run) {
	var b []Run
	if v := boards.Get(roomID); v != nil {
		b = v.([]Run)
	}
	if nb, ok := rankRun(b, run); ok {
		boards.Set(roomID, nb)
	}
}

// rankRun returns b with run placed in rank order and cut to boardSize, and
// true; or b and false when run does not enter. An owner holds at most one
// slot: their run replaces their entry only when it is better, else it is
// ignored. A route on b belongs to its first finder, so another owner's run on
// it never enters. A newcomer to a full board must beat its worst entry. b is
// never modified.
func rankRun(b []Run, run Run) ([]Run, bool) {
	mine := -1
	for i, e := range b {
		if e.Owner == run.Owner {
			mine = i
		} else if e.Route == run.Route {
			return b, false
		}
	}
	rest := b
	if mine >= 0 {
		if !better(run, b[mine]) {
			return b, false
		}
		rest = make([]Run, 0, len(b)-1)
		rest = append(rest, b[:mine]...)
		rest = append(rest, b[mine+1:]...)
	} else if len(b) >= boardSize && !better(run, b[len(b)-1]) {
		return b, false
	}
	i := 0
	for i < len(rest) && !better(run, rest[i]) {
		i++
	}
	n := len(rest) + 1
	if n > boardSize {
		n = boardSize
	}
	nb := make([]Run, 0, n)
	nb = append(nb, rest[:i]...)
	nb = append(nb, run)
	for j := i; j < len(rest) && len(nb) < n; j++ {
		nb = append(nb, rest[j])
	}
	return nb, true
}

// better ranks by beats, then damage, then commit height, all ascending.
func better(a, b Run) bool {
	if a.Beats != b.Beats {
		return a.Beats < b.Beats
	}
	if a.Damage != b.Damage {
		return a.Damage < b.Damage
	}
	return a.Height < b.Height
}

// playerOf returns who's record, creating it if create is set (else nil when
// absent).
func playerOf(who string, create bool) *Player {
	if v := players.Get(who); v != nil {
		return v.(*Player)
	}
	if !create {
		return nil
	}
	p := &Player{}
	players.Set(who, p)
	return p
}

func relicsOf(who string) int {
	if p := playerOf(who, false); p != nil {
		return p.Relics
	}
	return 0
}

// progressKey is "addr|roomID"; '|' sorts after every bech32 character, so
// one player's rooms form a contiguous range.
func progressKey(who, roomID string) string {
	return who + "|" + roomID
}

// validLog accepts 1 to sim.MaxBeats chars of '0'..'8'.
func validLog(log string) bool {
	if len(log) == 0 || len(log) > sim.MaxBeats {
		return false
	}
	for i := 0; i < len(log); i++ {
		if log[i] < '0' || log[i] > '8' {
			return false
		}
	}
	return true
}

func isLowerHex(s string, n int) bool {
	if len(s) != n {
		return false
	}
	for i := 0; i < n; i++ {
		c := s[i]
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}

// routeHex is h as 8 lowercase hex chars.
func routeHex(h uint32) string {
	var b [8]byte
	for i := 7; i >= 0; i-- {
		b[i] = hexDigits[h&0xf]
		h >>= 4
	}
	return string(b[:])
}
