package planes

import (
	"strings"

	"gno.land/p/nt/grc721/v0"
)

// plane is one row of the table: what a plane looks like. Nothing here is
// stored per token, the table is the only copy.
type plane struct {
	id     int64
	name   string
	model  string // a model the client draws, see models
	pilot  string // none or gnome
	body   string // colours, "#rrggbb"; on the super-gnome: cape, suit, emblem
	wing   string
	accent string
	tier   string // common, rare, epic, legendary
	laser  string // the colour of its shots, "#rrggbb"
}

// The table is one string of 777 lines,
// "id|name|model|pilot|body|wing|accent|tier|laser",
// in id order (see table.gno). It is kept as a string and read in place
// because storage is paid per byte at deploy: 777 structs would cost about
// ten times as much as the text, and a plane is read far less often than it
// is paid for.
//
// A row is found by bisection on the offsets of the string: from any offset,
// the start of its line is at most a line's length back. Ten steps of a
// hundred bytes each, where walking the lines from the top would be forty
// thousand.

// row returns the line of plane id, or "" when there is no such row.
func row(id int64) string {
	if id < 1 || id > supply {
		return ""
	}
	lo, hi := 0, len(table)-1
	for lo <= hi {
		mid := (lo + hi) / 2
		start, end := lineAt(mid)
		n := idAt(start, end)
		switch {
		case n == id:
			return table[start:end]
		case n < id:
			lo = end + 1
		default:
			hi = start - 1
		}
	}
	return ""
}

// lineAt returns the bounds of the line containing offset i: start is its
// first byte, end the offset of its newline, or len(table) for the last line.
func lineAt(i int) (start, end int) {
	start = i
	for start > 0 && table[start-1] != '\n' {
		start--
	}
	end = i
	for end < len(table) && table[end] != '\n' {
		end++
	}
	return start, end
}

// rowID reads the id of the line containing offset i, or 0 when the line
// does not start with a number.
func rowID(i int) int64 {
	start, end := lineAt(i)
	return idAt(start, end)
}

// idAt reads the id at the start of the line table[start:end].
func idAt(start, end int) int64 {
	n := int64(0)
	for j := start; j < end; j++ {
		c := table[j]
		if c == '|' {
			return n
		}
		if c < '0' || c > '9' || j-start > 3 {
			return 0
		}
		n = n*10 + int64(c-'0')
	}
	return 0
}

// parsePlane turns a row into a plane. It checks the shape of the row, not
// its values: those are the table's promise, checked by the tests.
func parsePlane(line string) (plane, bool) {
	f := strings.Split(line, "|")
	if len(f) != 9 {
		return plane{}, false
	}
	id := int64(0)
	for i := 0; i < len(f[0]); i++ {
		id = id*10 + int64(f[0][i]-'0')
	}
	return plane{id: id, name: f[1], model: f[2], pilot: f[3], body: f[4], wing: f[5], accent: f[6], tier: f[7], laser: f[8]}, true
}

// getPlane returns plane id from the table, or false when the id is out of
// range.
func getPlane(id int64) (plane, bool) {
	line := row(id)
	if line == "" {
		return plane{}, false
	}
	p, ok := parsePlane(line)
	if !ok {
		panic(errCorruptRow)
	}
	return p, true
}

// mustPlane returns plane id from the table, or panics.
func mustPlane(id int64) plane {
	p, ok := getPlane(id)
	if !ok {
		panic(errUnknownPlane)
	}
	return p
}

// tokenID is the GRC721 id of plane id: its number, in decimal.
func tokenID(id int64) grc721.TokenID {
	return grc721.TokenID(itoa(id))
}

// valid reports whether p respects every rule of the table. The tests run it
// on all 777 rows; the realm trusts the table after that, which is what
// makes the hand-built JSON and markdown of this realm safe.
func (p plane) valid() bool {
	return p.id >= 1 && p.id <= supply &&
		validName(p.name) &&
		oneOf(p.model, models) &&
		oneOf(p.pilot, pilots) &&
		validColor(p.body) && validColor(p.wing) && validColor(p.accent) && validColor(p.laser) &&
		oneOf(p.tier, tiers)
}

// validName reports whether s matches [A-Za-z0-9 -]{1,24}.
func validName(s string) bool {
	if len(s) == 0 || len(s) > 24 {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !(c >= 'a' && c <= 'z') && !(c >= 'A' && c <= 'Z') && !(c >= '0' && c <= '9') && c != ' ' && c != '-' {
			return false
		}
	}
	return true
}

// validColor reports whether s is "#rrggbb" with lowercase hex digits.
func validColor(s string) bool {
	if len(s) != 7 || s[0] != '#' {
		return false
	}
	for i := 1; i < len(s); i++ {
		c := s[i]
		if !(c >= '0' && c <= '9') && !(c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}

// validBase reports whether s can be an image base: an https URL ending in
// "/", 12 to 200 characters of [A-Za-z0-9./_-:]. The charset keeps it safe
// in JSON and markdown without escaping.
func validBase(s string) bool {
	if len(s) < 12 || len(s) > 200 || !strings.HasPrefix(s, "https://") || s[len(s)-1] != '/' {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !(c >= 'a' && c <= 'z') && !(c >= 'A' && c <= 'Z') && !(c >= '0' && c <= '9') &&
			c != '.' && c != '/' && c != '_' && c != '-' && c != ':' {
			return false
		}
	}
	return true
}

// validAddress reports whether addr is a valid address in its canonical,
// lowercase form, the only form the game realm and this one key on.
func validAddress(addr address) bool {
	return addr.IsValid() && addr[0] == 'g'
}

// oneOf reports whether s is one of the comma-separated words of list.
func oneOf(s, list string) bool {
	for _, w := range strings.Split(list, ",") {
		if s == w {
			return true
		}
	}
	return false
}
