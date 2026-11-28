// Package descent is the Daily Descent: ten floors a UTC day, drawn on chain by
// gen from the day alone, played one floor per commit-reveal. Every counted
// floor is verified here by replaying the player's log on the regenerated
// floor from the HP and relic the attempt carries.
//
// An attempt starts at floor 1 with 3 HP and no relic. A clear advances it,
// carrying HP (healed by 1 on arriving at floors 4 and 8) and any relic taken
// from the day's chest; a death ends it. Attempts are unlimited; a player's
// best attempt of the day is what the board shows. There is no admin.
package descent

import (
	"chain"
	"chain/runtime"
	"strconv"
	"time"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/g1tesdl67tx9xv8856gmtsh8mrj26kfjky8jwgcl/torchbeat/commit"
	"gno.land/p/g1tesdl67tx9xv8856gmtsh8mrj26kfjky8jwgcl/torchbeat/gen"
	"gno.land/p/g1tesdl67tx9xv8856gmtsh8mrj26kfjky8jwgcl/torchbeat/sim"
)

const (
	// revealWindow is how many blocks a commit stays revealable, as in the
	// hub (its play.gno).
	revealWindow = 600
	// roomPrefix names the descent in commit preimages:
	// gen.RoomID(roomPrefix, day, floor, attempt).
	roomPrefix = "descent"
	// Arriving at these floors heals 1 HP, up to the relic's max.
	healFloorA = 4
	healFloorB = 8
)

// Record is everything the realm keeps per player, in one flat object (Gno
// stores every nested struct as an object of its own, so nesting would cost
// deposit): the current (or last) attempt, the best of each recent day, and
// the all-time stats. It is updated in place, so playing more days does not
// grow it.
type Record struct {
	// The attempt.
	Day           uint32 // the UTC day it started; it plays that day's floors
	N             uint32 // attempt number within Day, from 1 (0: none yet)
	Floor         uint8  // the floor to play next (10 once the descent is cleared)
	HP            int8   // HP carried into Floor (0 once dead)
	Relic         uint8  // 0 none, 1 Featherboots, 2 Ironheart (from the chest)
	Beats         uint16 // total over cleared floors
	Damage        uint8  // total over cleared floors
	Ended         string // "" while live, else "dead" or "cleared"
	PendingHash   string // the pending commit, "" when none
	PendingHeight int64

	// Days holds the best of today and the keepDays before it, packed (see
	// ringGet).
	Days string

	// All-time.
	Deepest   uint8  // most floors cleared in one attempt
	Streak    uint16 // consecutive days reaching streakFloor, ending StreakDay
	Longest   uint16
	StreakDay uint32
	Total     uint32 // floors cleared: the sum of each day's best attempt
	Played    uint16 // days with at least one floor cleared
}

// cleared is the number of floors the attempt has cleared.
func (r *Record) cleared() uint8 {
	if r.Ended == "cleared" {
		return gen.Floors
	}
	return r.Floor - 1
}

var records = avl.NewTree() // addr -> *Record

// Start begins a new attempt on today's floors: floor 1, 3 HP, no relic. It
// replaces the caller's previous attempt and drops its pending commit; a live
// one that cleared a floor ends with DescentEnd reason "restart" (one that
// cleared nothing ends silently). User calls only.
func Start(cur realm) {
	who := userCaller(cur).String()
	day := today()
	prune(day)
	a := recordOf(who, true)
	if a.N > 0 && a.Ended == "" && a.cleared() > 0 {
		emitEnd(who, a, "restart")
	}
	if a.Day == day && a.N > 0 {
		a.N++
	} else {
		a.Day, a.N = day, 1
	}
	a.Floor, a.HP, a.Relic = 1, maxHP(0), 0
	a.Beats, a.Damage, a.Ended = 0, 0, ""
	a.PendingHash, a.PendingHeight = "", 0
}

// Commit records hash = commit.Hash(caller, gen.RoomID("descent", day, floor,
// attempt), relic, log, salt) for the attempt's current floor, with the
// attempt's day, floor, number and relic. User calls only. It panics with
// caller, hash, no attempt, done (the attempt ended), old day (it started
// before today: Start again) or pending (a commit is still revealable: reveal
// or Cancel it first).
func Commit(cur realm, hash string) {
	who := userCaller(cur).String()
	if !isLowerHex(hash, 64) {
		panic("hash")
	}
	a := attemptOf(who)
	if a == nil {
		panic("no attempt")
	}
	if a.Ended != "" {
		panic("done")
	}
	if a.Day != today() {
		panic("old day")
	}
	h := runtime.ChainHeight()
	if a.PendingHash != "" && h <= a.PendingHeight+revealWindow {
		panic("pending")
	}
	a.PendingHash, a.PendingHeight = hash, h
}

// Cancel drops the caller's pending commit, if any. User calls only.
func Cancel(cur realm) {
	if a := attemptOf(userCaller(cur).String()); a != nil {
		a.PendingHash, a.PendingHeight = "", 0
	}
}

// Reveal replays the committed log on the attempt's current floor, drawn again
// from the attempt's day and floor. A clear advances the attempt and emits
// DescentFloor (and DescentEnd "cleared" after floor 10); a death ends it with
// DescentEnd "dead". A commit made before midnight still reveals against its
// own day's floor. User calls only. It panics with caller, salt, log, too long
// (more than gen.DescentMaxBeats beats), no attempt, done, none, early,
// expired, mismatch, or "run:" + the sim reason for a run that neither clears
// nor dies (the commit is then kept).
func Reveal(cur realm, log, salt string) {
	who := userCaller(cur).String()
	if !isLowerHex(salt, 32) {
		panic("salt")
	}
	if why := checkLog(log); why != "" {
		panic(why)
	}
	a := attemptOf(who)
	if a == nil {
		panic("no attempt")
	}
	if a.Ended != "" {
		panic("done")
	}
	e := commit.Entry{Hash: a.PendingHash, Height: a.PendingHeight}
	got := commit.Hash(who, gen.RoomID(roomPrefix, a.Day, a.Floor, a.N), int(a.Relic), log, salt)
	if why := commit.CheckReveal(e, runtime.ChainHeight(), revealWindow, got); why != "" {
		panic(why)
	}
	f := gen.Layout(a.Day, a.Floor)
	m, why := sim.Parse(f.Grid, f.Props, f.Objective)
	if why != "" {
		panic("floor:" + why) // gen only draws floors Parse accepts
	}
	res := sim.RunFrom(&m, a.Relic, a.HP, log)
	switch {
	case res.Cleared:
		a.PendingHash, a.PendingHeight = "", 0
		cleared(who, a, f.HasChest, res, log, e.Height)
	case res.Reason == "dead":
		a.PendingHash, a.PendingHeight = "", 0
		a.Ended, a.HP = "dead", 0
		emitEnd(who, a, "dead")
	default:
		panic("run:" + res.Reason)
	}
}

// cleared applies a clear of a's current floor: totals, chest, floor best,
// the next floor (with its heal) or the end, then the player's records.
func cleared(who string, a *Record, hasChest bool, res sim.Result, log string, height int64) {
	n := a.Floor
	bd := boardOf(a.Day, true)
	noteFloor(bd, n, FloorRun{
		Owner: address(who), Beats: res.Beats, Damage: res.Damage, Height: height,
		Log: log, Relic: a.Relic, HP: a.HP,
	})
	a.Beats += res.Beats
	a.Damage += res.Damage
	a.HP -= int8(res.Damage)
	if hasChest && res.Chest {
		a.Relic = gen.ChestRelic(a.Day)
		if mx := maxHP(a.Relic); a.HP > mx {
			a.HP = mx
		}
	}
	chain.Emit("DescentFloor", "player", who, "day", u32(a.Day), "floor", strconv.Itoa(int(n)),
		"attempt", u32(a.N), "beats", strconv.Itoa(int(res.Beats)), "damage", strconv.Itoa(int(res.Damage)))
	if n == gen.Floors {
		a.Ended = "cleared"
	} else {
		a.Floor++
		if a.Floor == healFloorA || a.Floor == healFloorB {
			if a.HP < maxHP(a.Relic) {
				a.HP++
			}
		}
	}
	noteResult(a, bd, Row{Owner: address(who), Floors: a.cleared(), Beats: a.Beats, Damage: a.Damage, Height: height})
	noteStreak(a)
	if a.Ended != "" {
		emitEnd(who, a, a.Ended)
	}
}

func emitEnd(who string, a *Record, reason string) {
	chain.Emit("DescentEnd", "player", who, "day", u32(a.Day), "attempt", u32(a.N),
		"floors", strconv.Itoa(int(a.cleared())), "beats", strconv.Itoa(int(a.Beats)),
		"damage", strconv.Itoa(int(a.Damage)), "reason", reason)
}

// maxHP is the hero's max HP with relic, as sim.NewGameFrom sets it
// (TestMaxHPMatchesSim keeps the two in step).
func maxHP(relic uint8) int8 {
	switch relic {
	case 1:
		return 2
	case 2:
		return 4
	}
	return 3
}

// today is the UTC day of the block time.
func today() uint32 { return gen.DayOf(time.Now().Unix()) }

// attemptOf is who's record if they have started an attempt, else nil.
func attemptOf(who string) *Record {
	if r := recordOf(who, false); r != nil && r.N > 0 {
		return r
	}
	return nil
}

// recordOf returns who's record, creating it if create is set (else nil when
// absent).
func recordOf(who string, create bool) *Record {
	if v := records.Get(who); v != nil {
		return v.(*Record)
	}
	if !create {
		return nil
	}
	r := &Record{}
	records.Set(who, r)
	return r
}

func userCaller(cur realm) address {
	prev := cur.Previous()
	if !prev.IsUserCall() {
		panic("caller")
	}
	return prev.Address()
}

// checkLog accepts 1 to gen.DescentMaxBeats chars of '0'..'8': "" when it
// does, else "log" or "too long".
func checkLog(log string) string {
	if len(log) == 0 {
		return "log"
	}
	if len(log) > gen.DescentMaxBeats {
		return "too long"
	}
	for i := 0; i < len(log); i++ {
		if log[i] < '0' || log[i] > '8' {
			return "log"
		}
	}
	return ""
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

func u32(v uint32) string { return strconv.FormatUint(uint64(v), 10) }
