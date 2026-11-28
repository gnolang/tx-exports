package torchbeat

import (
	"chain"
	"chain/runtime"
	"strconv"
	"strings"

	"gno.land/p/g1tesdl67tx9xv8856gmtsh8mrj26kfjky8jwgcl/torchbeat/sim"
	"gno.land/r/sys/names"
)

const (
	maxCoord    = 16 // cells lie in [-16, 16] on both axes
	minPar      = 12 // the proof must take at least this many beats
	realmPrefix = "gno.land/r/"
)

// Publish puts the calling room realm on the world map. A user calls a crossing
// function of the room realm, which calls Publish; the room's package path is
// its ID and the user is its author. It panics with a reason code (see check).
func Publish(cur realm, name, objective, grid, props string, cellX, cellY, chestRelic int, proofLog string) {
	prev := cur.Previous()
	if !prev.IsCode() || prev.Subpath() != "" {
		panic("caller")
	}
	pp := prev.Previous()
	if !pp.IsUserCall() {
		panic("caller")
	}
	if why := publish(pp.Address(), prev.PkgPath(), name, objective, grid, props, cellX, cellY, chestRelic, proofLog); why != "" {
		panic(why)
	}
}

// CheckRoom runs Publish's checks for roomID without writing anything and
// returns "" or the reason code Publish would give. The caller is unknown, so
// the namespace is not checked against an author and the launch ring (reserved
// for the hub admin) always reads "cell".
func CheckRoom(roomID, name, objective, grid, props string, cellX, cellY, chestRelic int, proofLog string) string {
	_, why := check("", roomID, name, objective, grid, props, cellX, cellY, chestRelic, proofLog)
	return why
}

// publish checks a room for author and, if it passes, stores it and emits
// RoomOpened. It returns "" or a reason code.
func publish(author address, roomID, name, objective, grid, props string, cellX, cellY, chestRelic int, proofLog string) string {
	st, why := check(author, roomID, name, objective, grid, props, cellX, cellY, chestRelic, proofLog)
	if why != "" {
		return why
	}
	rooms.Set(roomID, &Room{
		ID:     roomID,
		Name:   name,
		Author: author,
		Static: st,
		X:      int8(cellX),
		Y:      int8(cellY),
		Opened: runtime.ChainHeight(),
	})
	world.Set(cellKey(cellX, cellY), roomID)
	canons.Set(canonKey(st.Canon), roomID)
	// Rooms are never removed, so the tree's size is the publish sequence.
	newest.Set(pad4(newest.Size()), roomID)
	chain.Emit("RoomOpened", "room", roomID, "author", author.String(),
		"x", strconv.Itoa(cellX), "y", strconv.Itoa(cellY))
	return ""
}

// check runs every Publish check after the caller's, in order: namespace, dup,
// name, objective, the sim parse/validate codes, cell, canon, chest, proof,
// par. An empty author is an anonymous caller (CheckRoom).
func check(author address, roomID, name, objective, grid, props string, cellX, cellY, chestRelic int, proofLog string) (*RoomStatic, string) {
	ns := namespace(roomID)
	if ns == "" || (author != "" && !names.IsAuthorizedAddressForNamespace(author, ns)) {
		return nil, "namespace"
	}
	if rooms.Has(roomID) {
		return nil, "dup"
	}
	if !validName(name) {
		return nil, "name"
	}
	if objective != "EXIT" && objective != "SLAY" {
		return nil, "objective"
	}
	m, why := sim.Parse(grid, props, objective)
	if why == "" {
		why = sim.Validate(&m)
	}
	if why != "" {
		return nil, why
	}
	if !cellOpen(author, cellX, cellY) {
		return nil, "cell"
	}
	h := sim.CanonHash(&m)
	if canons.Has(canonKey(h)) {
		return nil, "canon"
	}
	if m.HasChest {
		if chestRelic != 1 && chestRelic != 2 {
			return nil, "chest"
		}
	} else if chestRelic != 0 {
		return nil, "chest"
	}
	r := sim.Run(&m, 0, proofLog)
	if !r.Cleared {
		return nil, "proof"
	}
	if r.Beats < minPar {
		return nil, "par"
	}
	return &RoomStatic{
		Map:       m,
		Grid:      normGrid(grid),
		Props:     props,
		Objective: objective,
		Par:       r.Beats,
		Proof:     proofLog,
		Chest:     chestRelic,
		Canon:     h,
	}, ""
}

// normGrid normalizes a grid as sim.Parse does: CRLF becomes LF, then one
// leading and one trailing newline are dropped. Parse rejects any other CR, so
// a stored grid never holds one.
func normGrid(s string) string {
	s = strings.ReplaceAll(s, "\r\n", "\n")
	s = strings.TrimPrefix(s, "\n")
	return strings.TrimSuffix(s, "\n")
}

// namespace returns <ns> from "gno.land/r/<ns>/<rest>", or "" for any other
// shape.
func namespace(roomID string) string {
	if !strings.HasPrefix(roomID, realmPrefix) {
		return ""
	}
	rest := roomID[len(realmPrefix):]
	i := strings.IndexByte(rest, '/')
	if i <= 0 || i == len(rest)-1 {
		return ""
	}
	return rest[:i]
}

// validName accepts 3 to 24 chars of [A-Za-z0-9 -], not starting or ending
// with a space.
func validName(s string) bool {
	n := len(s)
	if n < 3 || n > 24 || s[0] == ' ' || s[n-1] == ' ' {
		return false
	}
	for i := 0; i < n; i++ {
		c := s[i]
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == ' ' || c == '-') {
			return false
		}
	}
	return true
}

// cellOpen reports whether author may open a room at (x, y): in bounds, not the
// hub, free, orthogonally next to the hub or a room (hidden ones included), and
// outside the launch ring (the 8 cells around the hub) unless author is the
// hub admin.
func cellOpen(author address, x, y int) bool {
	if x < -maxCoord || x > maxCoord || y < -maxCoord || y > maxCoord || (x == 0 && y == 0) {
		return false
	}
	if world.Has(cellKey(x, y)) {
		return false
	}
	if x >= -1 && x <= 1 && y >= -1 && y <= 1 && (author == "" || !owner.OwnedBy(author)) {
		return false
	}
	return occupied(x+1, y) || occupied(x-1, y) || occupied(x, y+1) || occupied(x, y-1)
}

// occupied reports whether (x, y) is the hub or holds a room.
func occupied(x, y int) bool {
	return (x == 0 && y == 0) || world.Has(cellKey(x, y))
}

func cellKey(x, y int) string {
	return strconv.Itoa(x) + "," + strconv.Itoa(y)
}

func canonKey(h uint32) string {
	return strconv.FormatUint(uint64(h), 16)
}

// World returns every room as a JSON array sorted by ID:
// [{"id":..,"name":..,"x":..,"y":..,"clears":..,"hidden":..}].
func World() string {
	b := []byte{'['}
	rooms.Iterate("", "", func(_ string, v any) bool {
		r := v.(*Room)
		if len(b) > 1 {
			b = append(b, ',')
		}
		b = append(b, '{')
		b = appendField(b, "id", true)
		b = appendQuoted(b, r.ID)
		b = appendField(b, "name", false)
		b = appendQuoted(b, r.Name)
		b = appendField(b, "x", false)
		b = appendInt(b, int(r.X))
		b = appendField(b, "y", false)
		b = appendInt(b, int(r.Y))
		b = appendField(b, "clears", false)
		b = appendInt(b, r.Clears)
		b = appendField(b, "hidden", false)
		b = appendBool(b, r.Hidden)
		b = append(b, '}')
		return false
	})
	return string(append(b, ']'))
}

// RoomData returns a room as JSON (grid, props, objective, par, author, x, y,
// clears, uniques, chest), or "{}" for an unknown room.
func RoomData(roomID string) string {
	v := rooms.Get(roomID)
	if v == nil {
		return "{}"
	}
	r := v.(*Room)
	s := r.Static
	b := []byte{'{'}
	b = appendField(b, "grid", true)
	b = appendQuoted(b, s.Grid)
	b = appendField(b, "props", false)
	b = appendQuoted(b, s.Props)
	b = appendField(b, "objective", false)
	b = appendQuoted(b, s.Objective)
	b = appendField(b, "par", false)
	b = appendInt(b, int(s.Par))
	b = appendField(b, "author", false)
	b = appendQuoted(b, r.Author.String())
	b = appendField(b, "x", false)
	b = appendInt(b, int(r.X))
	b = appendField(b, "y", false)
	b = appendInt(b, int(r.Y))
	b = appendField(b, "clears", false)
	b = appendInt(b, r.Clears)
	b = appendField(b, "uniques", false)
	b = appendInt(b, r.Uniques)
	b = appendField(b, "chest", false)
	b = appendInt(b, s.Chest)
	return string(append(b, '}'))
}
