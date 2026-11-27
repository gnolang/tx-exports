// Package livery is a Cellar challenge about the difference between the
// realm that is acting and the code that is running.
package livery

import (
	"chain/runtime/unsafe"
	"strings"

	"gno.land/p/g15c02s5hhdny9uvr9za3xsyn9sw8p0klptrh6kf/cellar/flag"
	"gno.land/p/nt/avl/v0"
)

// StewardPath is the only realm allowed to hand out the livery.
const StewardPath = "gno.land/r/g15c02s5hhdny9uvr9za3xsyn9sw8p0klptrh6kf/cellar/steward"

var dressed = avl.NewTree() // guest address -> true

// Dress puts guest in the house livery. The wardrobe only obeys the
// steward: it checks that the steward is the realm currently acting.
func Dress(guest address) {
	if unsafe.CurrentRealm().PkgPath() != StewardPath {
		panic("livery: only the steward hands out the livery")
	}
	dressed.Set(guest.String(), true)
}

// Enter lets a guest in livery into the private cellar, where the flag is.
func Enter(cur realm) {
	player := flag.MustPlayer(cur.Previous())
	if !dressed.Has(player.String()) {
		panic("livery: guests in livery only")
	}
	captures.Record(player)
}

// InLivery reports whether addr wears the livery.
func InLivery(addr address) bool { return dressed.Has(addr.String()) }

// Render shows who wears the livery.
func Render(_ string) string {
	var b strings.Builder
	b.WriteString(flag.Card(info, captures))
	b.WriteString("\n## In livery\n\n")
	if dressed.Size() == 0 {
		b.WriteString("*Nobody yet.*\n")
	}
	dressed.Iterate("", "", func(addr string, _ any) bool {
		b.WriteString("- `" + addr + "`\n")
		return false
	})
	b.WriteString("\n## Captured by\n\n" + flag.Captures(captures, 5))
	return b.String()
}
