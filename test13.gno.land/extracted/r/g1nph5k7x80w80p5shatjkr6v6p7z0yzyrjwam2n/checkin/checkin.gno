// Package checkin is a public check-in board: anyone can check in once,
// the board records their address, and Render lists everyone so far.
package checkin

import (
	"strconv"
	"strings"

	"chain"

	"gno.land/p/nt/avl/v0"
)

var (
	checkins avl.Tree // caller address (bech32 string) -> arrival number (int)
	total    int      // check-ins so far; assigns arrival numbers
)

// CheckIn records the caller's address on the board. Anyone may check in —
// an EOA or another realm — but only once; a second check-in reverts.
func CheckIn(cur realm) {
	if !cur.IsCurrent() {
		panic("invalid realm")
	}
	caller := cur.Previous().Address().String()
	if checkins.Has(caller) {
		panic("already checked in")
	}
	total++
	checkins.Set(caller, total)
	chain.Emit("CheckIn", "address", caller, "n", strconv.Itoa(total))
}

// Total returns the number of addresses checked in so far.
func Total() int {
	return checkins.Size()
}

// HasCheckedIn reports whether addr has checked in.
func HasCheckedIn(addr address) bool {
	return checkins.Has(addr.String())
}

// Render lists everyone checked in so far, sorted by address, with each
// entry's arrival number. Only the home path is served.
func Render(path string) string {
	if path != "" {
		return "> [!WARNING]\n> Path not found. Only the home page exists.\n"
	}
	var b strings.Builder
	b.WriteString("# Check-in board\n\n")
	if checkins.Size() == 0 {
		b.WriteString("Nobody has checked in yet. Call `CheckIn` to be the first.\n")
		return b.String()
	}
	b.WriteString(strconv.Itoa(checkins.Size()) + " checked in so far:\n\n")
	checkins.Iterate("", "", func(key string, value any) bool {
		b.WriteString("- `" + key + "` (#" + strconv.Itoa(value.(int)) + ")\n")
		return false
	})
	return b.String()
}
