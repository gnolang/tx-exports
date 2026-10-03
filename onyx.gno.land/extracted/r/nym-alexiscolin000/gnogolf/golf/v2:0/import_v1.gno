package golf

import (
	"chain"
	"strconv"
	"strings"

	v1 "gno.land/r/nym-alexiscolin000/gnogolf/golf"
)

// The migration (onyx only: stage.sh leaves this file out of the mainnet
// deploy): v1's course holes and records, read from v1 on chain in the same
// call that writes them, so no one types a value in. Not replayed: v1 already
// replayed each with this same physics. A hole keeps v1's id, so its weather
// and its records fit it.

// EventImported is a v1 record copied in; EventNotImported one left on v1, a
// shot of it finer than v2 takes (validShot): its ghost would not replay here.
const (
	EventImported    = "Imported"
	EventNotImported = "NotImported"
)

// ImportHole copies v1's current version of a course slot, by its id
// ("garden/7/v3"): its data, provenance (by, height, note), plays and wear.
// Only the owner can, into a slot v2 has nothing in yet.
func ImportHole(cur realm, id string) string {
	begin()
	r := importHoleNow(cur, id)
	flush(cur) // (only once it went through: a refusal writes nothing)
	return r
}

func importHoleNow(cur realm, id string) string {
	if !isOwner(cur.Previous().Address()) {
		panic("golf: only the owner can import a course hole")
	}
	cut := strings.LastIndex(id, "/v")
	if cut < 0 || v1.Current(id[:cut]) != id {
		panic("golf: " + id + " is not a course slot's current version on v1")
	}
	slot := id[:cut]
	key, ok := slotKeyOf(slot)
	if !ok {
		panic("golf: " + slot + " is not a course slot")
	}
	return importHole(id, key, v1.HoleData(id), jobject(v1.Versions(slot), id), jobject(v1.Holes(), id), v1.HoleState(id))
}

// importHole keeps the version id of slot key as v1 lists it: its data (hex),
// its row of Versions (ver), of Holes (row) and its HoleState (state).
func importHole(id, key, hexData, ver, row, state string) string {
	cut := strings.LastIndex(id, "/v")
	slot := id[:cut]
	if slots.Has(key) {
		panic("golf: " + slot + " already has a version here")
	}
	h, data, sum := decodeData(hexData)
	if own := h.World + "/" + strconv.Itoa(int(h.Order)); own != slot {
		panic("golf: v1's data of " + id + " is " + own) // v1 checked it at publish: cannot happen
	}
	e := dataEntry(slot, atoi(id[cut+2:]), h, address(jget(ver, "by")), sum, jget(ver, "note"))
	e.height = atoi64(jget(ver, "height"))
	e.plays = atoi(jget(row, "plays"))
	e.official = true
	saveEntry(e)
	holeData.Set(e.id, data)
	slots.Set(key, e.id)
	for i, c := range strings.Split(jget(state, "cells"), ",") {
		if c != "0" && c != "" && i < wearCells {
			e.wear().Set(pad(i, 3), itoa(atoi(c)))
		}
	}
	chain.Emit(EventHolePublished, "hole", e.id, "slot", slot, "sha", sum, "by", e.by.String(), "official", "true")
	return e.id
}

// ImportRecord copies a player's v1 best on an imported hole in a mode
// (v1's Ghost: strokes, height, period, shots) and seats it as a finish
// would, onto the hole imported from v1 (the same data: its sha is v1's). Only
// the owner can, as the migration's script runs it: v1 plays on, with no
// near-copy rule, so a round played there later is not one to rank here.
// Idempotent: a record already as good stays; a better v1 one takes its
// place. A record with a shot finer than 0.01 (never one the game sends)
// stays on v1. It answers whether it copied anything.
func ImportRecord(cur realm, hole, mode string, player address) bool {
	begin()
	r := importRecordNow(cur, hole, mode, player)
	flush(cur) // (only once it went through: a refusal writes nothing)
	return r
}

func importRecordNow(cur realm, hole, mode string, player address) bool {
	if !isOwner(cur.Previous().Address()) {
		panic("golf: only the owner can import a record")
	}
	e, m := mustHole(hole), modeOf(mode)
	if !e.official || e.next != "" {
		panic("golf: " + hole + " is not a current course hole here")
	}
	// (Versions lists a slot's newest 100: a version past them would be refused,
	// never wrongly let in; v1's slots have a few each)
	if jget(jobject(v1.Versions(e.slot), e.id), "sha") != e.sha {
		panic("golf: " + hole + " here is not v1's " + hole)
	}
	// v1's standing of the player, for its tie-break: the page of Players
	// that starts just before their key
	p, at := player.String(), int64(0)
	if row := v1.Players(mode, p[:len(p)-1], 1); jget(row, "player") == p {
		at = atoi64(jget(row, "height"))
	}
	return importRecord(e, m, p, v1.Ghost(hole, mode, player), at)
}

// importRecord copies p's best on e in mode m as v1's Ghost (g) has it; at is
// v1's standing's height (the course ranking's tie-break: the finish that last
// improved it, perhaps on a version since archived), 0 for none.
func importRecord(e *entry, m int, p, g string, at int64) bool {
	if g == "null" {
		return false
	}
	strokes, shots := atoi(jget(g, "strokes")), jget(g, "shots")
	if strokes < 1 || jget(g, "hole") != e.id {
		panic("golf: v1's record of " + e.id + " does not read") // v1 writes them: cannot happen
	}
	for _, s := range strings.Split(shots, ";") {
		if a, pw, _ := parseShot(s); !cents(a) || !cents(pw) {
			chain.Emit(EventNotImported, "hole", e.id, "player", p, "mode", modeNames[m], "shot", s)
			return false
		}
	}
	best, _ := e.bests(m).Get(p)
	was, wasCopy := bestStrokes(best), e.copies(m).Has(p)
	if was > 0 && was <= strokes && !wasCopy { // (their own, from v1, replaces a copy played here)
		return false
	}
	if wasCopy { // a copy played here: never counted, never on the board
		e.copies(m).Remove(p)
		was = 0
	} else if was > 0 {
		e.board(m).Remove(boardKey(best, p))
	}
	best = itoa(strokes) + " " + i64(atoi64(jget(g, "height"))) + " " + i64(atoi64(jget(g, "period"))) + " " + shots
	e.bests(m).Set(p, best)
	r := &row{player: p}
	if v, ok := totals[m].Get(p); ok {
		r = decodeRow(v)
	}
	if at == 0 { // (no standing on v1: its finishes, not this call)
		at = atoi64(jget(g, "height"))
	}
	if at < r.height { // (a finish here since: the later one)
		at = r.height
	}
	if was == 0 {
		setRow(m, r, r.holes+1, r.strokes+strokes, r.par+e.par, at)
	} else {
		setRow(m, r, r.holes, r.strokes+strokes-was, r.par, at)
	}
	if named(p) {
		seat(e, m, p, best)
	}
	saveEntry(e)
	chain.Emit(EventImported, "hole", e.id, "player", p, "mode", modeNames[m], "strokes", itoa(strokes))
	return true
}

// jobject is a v1 list from the object whose "id" is id on ("" if none):
// jget then reads that object's fields, which every object of the list has.
func jobject(j, id string) string {
	i := strings.Index(j, `{"id":`+jstr(id)+`,`)
	if i < 0 {
		return ""
	}
	return j[i:]
}

// jget is a field of v1's JSON, as v1 writes it (jstr): a string's value,
// unescaped, or a number's or an array's inside, "" if absent.
func jget(j, k string) string {
	i := strings.Index(j, `"`+k+`":`)
	if i < 0 {
		return ""
	}
	v := j[i+len(k)+3:]
	switch {
	case v == "":
		return ""
	case v[0] == '"':
		end := 1
		for end < len(v) && v[end] != '"' {
			if v[end] == '\\' {
				end++
			}
			end++
		}
		s, err := strconv.Unquote(v[:end+1])
		if err != nil {
			panic("golf: v1's " + k + " does not read")
		}
		return s
	case v[0] == '[':
		return v[1:strings.Index(v, "]")]
	}
	return v[:strings.IndexAny(v, ",}]")]
}
