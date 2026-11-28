package descent

import (
	"gno.land/p/nt/avl/v0"
	"gno.land/p/g1tesdl67tx9xv8856gmtsh8mrj26kfjky8jwgcl/torchbeat/gen"
)

// Storage grows with players only through their one record each; per day it
// is one object: a player's day bests live in a ring inside their record
// (updated in place), and each day keeps one DayBoard holding, packed, at most
// boardSize rows and gen.Floors floor bests. Gno stores every struct and tree
// node as an object of its own (about 1-3 KB of deposit each), so packing is
// what keeps a day's first full descent cheap. A day more than keepDays old is
// cut down to its winner.
const (
	boardSize = 50
	// streakFloor: a day counts toward a streak once an attempt of that day
	// reaches (stands on) this floor.
	streakFloor = 3
	// keepDays: a day more than keepDays before today keeps only its winner.
	keepDays = 7
	// ringDays is how many day bests a record holds: today and the keepDays
	// before it.
	ringDays = keepDays + 1
)

// Row is a player's best attempt of a day: a board row (packed by packRow),
// and (without the owner) a slot of their record's ring.
type Row struct {
	Owner  address
	Floors uint8  // floors cleared (0: no result)
	Beats  uint16 // total beats over them
	Damage uint8  // total damage over them
	Height int64  // commit height of the clear that set this result
}

// better ranks by floors (more first), then beats, damage and height (fewer,
// less, earlier first).
func (r *Row) better(o *Row) bool {
	if r.Floors != o.Floors {
		return r.Floors > o.Floors
	}
	if r.Beats != o.Beats {
		return r.Beats < o.Beats
	}
	if r.Damage != o.Damage {
		return r.Damage < o.Damage
	}
	return r.Height < o.Height
}

// DayBoard is one day's shared records, packed into strings so the day is a
// single object: Rows holds its top rows, best first, one per player (see
// packRow); Floors holds its floor bests (see floorGet).
type DayBoard struct {
	Day    uint32
	Rows   string
	Floors string
}

// FloorRun is the best clear of one floor of a day, with what a ghost or a
// dare needs to replay it: the log and the relic and HP it started from. It
// is stored packed in DayBoard.Floors.
type FloorRun struct {
	Owner  address
	Beats  uint16
	Damage uint8
	Height int64 // commit height
	Log    string
	Relic  uint8
	HP     int8
}

func (r *FloorRun) better(o *FloorRun) bool {
	if r.Beats != o.Beats {
		return r.Beats < o.Beats
	}
	if r.Damage != o.Damage {
		return r.Damage < o.Damage
	}
	return r.Height < o.Height
}

var (
	boards = avl.NewTree() // dayKey -> *DayBoard
	// pruneFrom: every day before it has been cut down to its winner.
	pruneFrom uint32
)

// noteResult records r as rec's result for bd's day if it beats their best
// of that day, adds its new floors to rec's totals, and enters it on the
// board.
func noteResult(rec *Record, bd *DayBoard, r Row) {
	old, ok := ringGet(rec.Days, bd.Day)
	if ok && !r.better(&old) {
		return
	}
	// The day's best only grows, so its new floors add to the all-time total.
	if !ok {
		rec.Played++
		old.Floors = 0
	}
	if r.Floors > old.Floors {
		rec.Total += uint32(r.Floors - old.Floors)
	}
	rec.Days = ringSet(rec.Days, bd.Day, &r)
	enterBoard(bd, r)
}

// enterBoard places r, its owner's improved best, on bd in one pass over the
// packed rows, keeping one row per player and at most boardSize rows. A
// player's best only improves (an old row of theirs is always worse than r,
// so r lands at or above it), and a player pushed off a full board belongs on
// it again only once they beat its last row: the board stays the exact top
// boardSize of every player's best.
func enterBoard(bd *DayBoard, r Row) {
	s := bd.Rows
	b := make([]byte, 0, len(s)+rowMax)
	placed := false
	n := 0
	for i := 0; i < len(s); {
		old, next := unpackRow(s, i)
		seg := s[i:next]
		i = next
		if old.Owner == r.Owner {
			continue
		}
		if !placed && r.better(&old) {
			b = packRow(b, &r)
			placed = true
			n++
		}
		if n == boardSize {
			break
		}
		b = append(b, seg...)
		n++
	}
	if !placed {
		if n >= boardSize {
			return // not better than a full board's last row
		}
		b = packRow(b, &r)
	}
	bd.Rows = string(b)
}

// noteFloor records run as floor n's best of bd's day if it beats the
// current one.
func noteFloor(bd *DayBoard, n uint8, run FloorRun) {
	if old, ok := floorGet(bd.Floors, n); ok && !run.better(&old) {
		return
	}
	bd.Floors = floorSet(bd.Floors, n, &run)
}

// noteStreak updates rec's deepest and streak after its attempt's latest
// clear.
func noteStreak(rec *Record) {
	if c := rec.cleared(); c > rec.Deepest {
		rec.Deepest = c
	}
	// Counted once per day, by the attempt's day: the clear that brings the
	// attempt onto streakFloor.
	if rec.cleared() != streakFloor-1 || rec.Streak > 0 && rec.Day <= rec.StreakDay {
		return
	}
	if rec.Streak > 0 && rec.StreakDay+1 == rec.Day {
		rec.Streak++
	} else {
		rec.Streak = 1
	}
	rec.StreakDay = rec.Day
	if rec.Streak > rec.Longest {
		rec.Longest = rec.Streak
	}
}

// liveStreak is rec's streak as of day: it lapses once a whole day passes
// without reaching streakFloor.
func liveStreak(rec *Record, day uint32) uint16 {
	if rec.Streak > 0 && rec.StreakDay+1 >= day {
		return rec.Streak
	}
	return 0
}

// prune cuts the oldest day before cutoff(today) not yet cut down to its
// winner: its board keeps one row and its floor bests go. It reports whether
// it cut a day. One day per call is bounded work (one object rewritten) and
// keeps up, since at most one day a day falls past the cutoff; days without a
// board are skipped in the same lookup.
func prune(today uint32) bool {
	c := cutoff(today)
	if pruneFrom >= c {
		return false
	}
	var bd *DayBoard
	boards.Iterate(dayKey(pruneFrom), dayKey(c), func(_ string, v any) bool {
		bd = v.(*DayBoard)
		return true
	})
	if bd == nil {
		pruneFrom = c
		return false
	}
	if bd.Rows != "" {
		_, next := unpackRow(bd.Rows, 0)
		bd.Rows = bd.Rows[:next]
	}
	bd.Floors = ""
	pruneFrom = bd.Day + 1
	return true
}

// cutoff is the oldest day that keeps its detail.
func cutoff(today uint32) uint32 {
	if today < keepDays {
		return 0
	}
	return today - keepDays
}

func boardOf(day uint32, create bool) *DayBoard {
	dk := dayKey(day)
	if v := boards.Get(dk); v != nil {
		return v.(*DayBoard)
	}
	if !create {
		return nil
	}
	bd := &DayBoard{Day: day}
	boards.Set(dk, bd)
	return bd
}

// The ring: Record.Days packs one slot per day of today and the keepDays
// before it, slot d % ringDays for day d, each slotLen bytes big-endian: day
// (4), floors (1), beats (2), damage (1), height (8). A slot whose day is not
// the one asked for is stale (or empty) and reads as no result.
const slotLen = 16

// ringGet returns the best of day packed in s, if s holds one.
func ringGet(s string, day uint32) (Row, bool) {
	i := int(day%ringDays) * slotLen
	if len(s) < i+slotLen || getUint(s, i, 4) != uint64(day) || s[i+4] == 0 {
		return Row{}, false
	}
	return Row{
		Floors: s[i+4],
		Beats:  uint16(getUint(s, i+5, 2)),
		Damage: s[i+7],
		Height: int64(getUint(s, i+8, 8)),
	}, true
}

// ringSet returns s with day's slot set to r (owner aside).
func ringSet(s string, day uint32, r *Row) string {
	if len(s) < ringDays*slotLen {
		s = string(make([]byte, ringDays*slotLen))
	}
	b := make([]byte, 0, slotLen)
	b = putUint(b, uint64(day), 4)
	b = append(b, r.Floors)
	b = putUint(b, uint64(r.Beats), 2)
	b = append(b, r.Damage)
	b = putUint(b, uint64(r.Height), 8)
	i := int(day%ringDays) * slotLen
	return s[:i] + string(b) + s[i+slotLen:]
}

// Packed rows: each is owner length (1), owner, floors (1), beats (2),
// damage (1), height (8), integers big-endian.
const rowMax = 1 + 255 + 12

func packRow(b []byte, r *Row) []byte {
	o := r.Owner.String()
	b = append(b, byte(len(o)))
	b = append(b, o...)
	b = append(b, r.Floors)
	b = putUint(b, uint64(r.Beats), 2)
	b = append(b, r.Damage)
	return putUint(b, uint64(r.Height), 8)
}

// unpackRow decodes the row at offset i of s and returns it with the offset
// of the next row.
func unpackRow(s string, i int) (Row, int) {
	j := i + 1 + int(s[i])
	return Row{
		Owner:  address(s[i+1 : j]),
		Floors: s[j],
		Beats:  uint16(getUint(s, j+1, 2)),
		Damage: s[j+3],
		Height: int64(getUint(s, j+4, 8)),
	}, j + 12
}

// Packed floor bests: gen.Floors slots in floor order, each either a single
// zero byte (no clear yet) or owner length (1, never 0), owner, beats (2),
// damage (1), height (8), relic (1), hp (1), log length (1), log. "" reads as
// every slot empty.

// floorSpan returns s (expanded to empty slots if "") and the bounds of
// floor n's slot in it.
func floorSpan(s string, n uint8) (string, int, int) {
	if s == "" {
		s = string(make([]byte, gen.Floors))
	}
	i := 0
	for k := uint8(1); ; k++ {
		end := i + 1
		if l := int(s[i]); l > 0 {
			end = i + 1 + l + 14 // through the log length byte
			end += int(s[end-1])
		}
		if k == n {
			return s, i, end
		}
		i = end
	}
}

// floorGet returns floor n's best packed in s, if there is one.
func floorGet(s string, n uint8) (FloorRun, bool) {
	s, i, end := floorSpan(s, n)
	if s[i] == 0 {
		return FloorRun{}, false
	}
	j := i + 1 + int(s[i])
	return FloorRun{
		Owner:  address(s[i+1 : j]),
		Beats:  uint16(getUint(s, j, 2)),
		Damage: s[j+2],
		Height: int64(getUint(s, j+3, 8)),
		Relic:  s[j+11],
		HP:     int8(s[j+12]),
		Log:    s[j+14 : end],
	}, true
}

// floorSet returns s with floor n's slot set to f. The owner and log must
// each fit 255 bytes (an address is 40; a log at most gen.DescentMaxBeats).
func floorSet(s string, n uint8, f *FloorRun) string {
	s, i, end := floorSpan(s, n)
	o := f.Owner.String()
	b := make([]byte, 0, 15+len(o)+len(f.Log))
	b = append(b, byte(len(o)))
	b = append(b, o...)
	b = putUint(b, uint64(f.Beats), 2)
	b = append(b, f.Damage)
	b = putUint(b, uint64(f.Height), 8)
	b = append(b, f.Relic, byte(f.HP), byte(len(f.Log)))
	b = append(b, f.Log...)
	return s[:i] + string(b) + s[end:]
}

func getUint(s string, i, n int) uint64 {
	var v uint64
	for k := 0; k < n; k++ {
		v = v<<8 | uint64(s[i+k])
	}
	return v
}

func putUint(b []byte, v uint64, n int) []byte {
	for k := n - 1; k >= 0; k-- {
		b = append(b, byte(v>>(8*uint(k))))
	}
	return b
}

// dayKey is day as 8 lowercase hex digits, so keys sort by day.
func dayKey(day uint32) string {
	return string(appendHex(make([]byte, 0, 8), uint64(day), 8))
}

func appendHex(b []byte, v uint64, digits int) []byte {
	for i := digits - 1; i >= 0; i-- {
		b = append(b, hexDigits[(v>>(4*uint(i)))&0xf])
	}
	return b
}
