package descent

import (
	"strconv"

	"gno.land/p/g1tesdl67tx9xv8856gmtsh8mrj26kfjky8jwgcl/torchbeat/gen"
)

// The read API: JSON strings for vm/qeval, in the hub's style. Addresses are
// read as given; an invalid one reads as unknown.

// Today returns {"day":N,"floors":10}: today's UTC day number and the floors
// a descent has.
func Today() string {
	b := []byte{'{'}
	b = appendField(b, "day", true)
	b = appendUint(b, uint64(today()))
	b = appendField(b, "floors", false)
	b = appendInt(b, gen.Floors)
	return string(append(b, '}'))
}

// Board returns day's board, best first, one row per player (their best
// attempt): [{"owner":..,"floors":..,"beats":..,"damage":..,"height":..}],
// at most 50 rows, ranked by floors cleared (more first), then total beats,
// total damage and the commit height of the result (fewer, less, earlier
// first). A day more than 7 days old keeps only its winner. An unknown day
// is [].
func Board(day int) string {
	if day < 0 || day > int(^uint32(0)) {
		return "[]"
	}
	b := []byte{'['}
	if bd := boardOf(uint32(day), false); bd != nil {
		for i := 0; i < len(bd.Rows); {
			if i > 0 {
				b = append(b, ',')
			}
			var r Row
			r, i = unpackRow(bd.Rows, i)
			b = appendRow(b, &r)
		}
	}
	return string(append(b, ']'))
}

// Attempt returns the address's current (or last) attempt:
// {"day":..,"attempt":..,"floor":..,"floors":..,"hp":..,"relic":..,"beats":..,
// "damage":..,"ended":..,"pending":null|{"hash":..,"height":..}}. floor is the
// floor to play next, floors the floors cleared, hp the HP carried into floor,
// ended "" while live else "dead" or "cleared". With no attempt it is null.
func Attempt(addr string) string {
	a := attemptOf(addr)
	if a == nil {
		return "null"
	}
	b := []byte{'{'}
	b = appendField(b, "day", true)
	b = appendUint(b, uint64(a.Day))
	b = appendField(b, "attempt", false)
	b = appendUint(b, uint64(a.N))
	b = appendField(b, "floor", false)
	b = appendInt(b, int(a.Floor))
	b = appendField(b, "floors", false)
	b = appendInt(b, int(a.cleared()))
	b = appendField(b, "hp", false)
	b = appendInt(b, int(a.HP))
	b = appendField(b, "relic", false)
	b = appendInt(b, int(a.Relic))
	b = appendField(b, "beats", false)
	b = appendInt(b, int(a.Beats))
	b = appendField(b, "damage", false)
	b = appendInt(b, int(a.Damage))
	b = appendField(b, "ended", false)
	b = appendQuoted(b, a.Ended)
	b = appendField(b, "pending", false)
	if a.PendingHash == "" {
		b = append(b, "null"...)
	} else {
		b = append(b, '{')
		b = appendField(b, "hash", true)
		b = appendQuoted(b, a.PendingHash)
		b = appendField(b, "height", false)
		b = append(b, strconv.FormatInt(a.PendingHeight, 10)...)
		b = append(b, '}')
	}
	return string(append(b, '}'))
}

// Player returns the address's records: {"deepest":N,"streak":N,"longest":N,
// "total":N,"played":N,"days":[{"day":..,"floors":..,"beats":..,"damage":..,
// "height":..}]}. deepest is the most floors cleared in one attempt, ever;
// streak the run of consecutive UTC days (by attempt day) that reached floor
// 3, 0 once a whole day has passed without; longest the longest such run;
// total the floors of every day's best attempt added up; played the days with
// a floor cleared. days lists the best
// attempt of each day still kept (today and the 7 before), newest first.
func Player(addr string) string {
	var p Record
	if v := recordOf(addr, false); v != nil {
		p = *v
	}
	t := today()
	b := []byte{'{'}
	b = appendField(b, "deepest", true)
	b = appendInt(b, int(p.Deepest))
	b = appendField(b, "streak", false)
	b = appendInt(b, int(liveStreak(&p, t)))
	b = appendField(b, "longest", false)
	b = appendInt(b, int(p.Longest))
	b = appendField(b, "total", false)
	b = appendInt(b, int(p.Total))
	b = appendField(b, "played", false)
	b = appendInt(b, int(p.Played))
	b = appendField(b, "days", false)
	b = append(b, '[')
	first := true
	for d := t; ; d-- {
		if r, ok := ringGet(p.Days, d); ok {
			if !first {
				b = append(b, ',')
			}
			first = false
			b = append(b, '{')
			b = appendField(b, "day", true)
			b = appendUint(b, uint64(d))
			b = appendBestFields(b, &r)
			b = append(b, '}')
		}
		if d == cutoff(t) {
			break
		}
	}
	return string(append(b, ']', '}'))
}

// FloorBest returns the best clear of floor (1..10) on day: {"owner":..,
// "beats":..,"damage":..,"height":..,"log":..,"relic":..,"hp":..} with the
// relic and HP the run started the floor with, for ghosts and dares; ties go
// to less damage, then the earlier commit. null when there is none (or the
// day was pruned).
func FloorBest(day, floor int) string {
	if day < 0 || day > int(^uint32(0)) || floor < 1 || floor > gen.Floors {
		return "null"
	}
	bd := boardOf(uint32(day), false)
	if bd == nil {
		return "null"
	}
	r, ok := floorGet(bd.Floors, uint8(floor))
	if !ok {
		return "null"
	}
	b := []byte{'{'}
	b = appendField(b, "owner", true)
	b = appendQuoted(b, r.Owner.String())
	b = appendField(b, "beats", false)
	b = appendInt(b, int(r.Beats))
	b = appendField(b, "damage", false)
	b = appendInt(b, int(r.Damage))
	b = appendField(b, "height", false)
	b = append(b, strconv.FormatInt(r.Height, 10)...)
	b = appendField(b, "log", false)
	b = appendQuoted(b, r.Log)
	b = appendField(b, "relic", false)
	b = appendInt(b, int(r.Relic))
	b = appendField(b, "hp", false)
	b = appendInt(b, int(r.HP))
	return string(append(b, '}'))
}

func appendRow(b []byte, r *Row) []byte {
	b = append(b, '{')
	b = appendField(b, "owner", true)
	b = appendQuoted(b, r.Owner.String())
	b = appendBestFields(b, r)
	return append(b, '}')
}

func appendBestFields(b []byte, r *Row) []byte {
	b = appendField(b, "floors", false)
	b = appendInt(b, int(r.Floors))
	b = appendField(b, "beats", false)
	b = appendInt(b, int(r.Beats))
	b = appendField(b, "damage", false)
	b = appendInt(b, int(r.Damage))
	b = appendField(b, "height", false)
	return append(b, strconv.FormatInt(r.Height, 10)...)
}

// ---- JSON helpers (as in the hub's json.gno) ----

const hexDigits = "0123456789abcdef"

// appendQuoted appends s as a JSON string: quote and backslash are
// backslash-escaped, control characters become \u00XX.
func appendQuoted(b []byte, s string) []byte {
	b = append(b, '"')
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c == '"' || c == '\\':
			b = append(b, '\\', c)
		case c < 0x20:
			b = append(b, '\\', 'u', '0', '0', hexDigits[c>>4], hexDigits[c&0xf])
		default:
			b = append(b, c)
		}
	}
	return append(b, '"')
}

// appendField appends `"key":`, preceded by a comma unless first.
func appendField(b []byte, key string, first bool) []byte {
	if !first {
		b = append(b, ',')
	}
	b = append(b, '"')
	b = append(b, key...)
	return append(b, '"', ':')
}

func appendInt(b []byte, n int) []byte { return append(b, strconv.Itoa(n)...) }

func appendUint(b []byte, n uint64) []byte { return append(b, strconv.FormatUint(n, 10)...) }
