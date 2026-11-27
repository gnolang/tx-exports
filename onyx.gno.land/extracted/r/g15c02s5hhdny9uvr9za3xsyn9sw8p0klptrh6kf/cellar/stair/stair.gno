// Package stair is a Cellar challenge about exported non-crossing
// functions in a realm.
package stair

import (
	"chain/runtime"
	"strconv"
	"strings"

	"gno.land/p/g15c02s5hhdny9uvr9za3xsyn9sw8p0klptrh6kf/cellar/flag"
	"gno.land/p/nt/avl/v0"
)

var (
	headSteward = address("g15c02s5hhdny9uvr9za3xsyn9sw8p0klptrh6kf")
	roster      = avl.NewTree() // steward address -> height enrolled
)

// Appoint puts steward on the roster. Only the head steward appoints.
func Appoint(cur realm, steward address) {
	if cur.Previous().Address() != headSteward {
		panic("stair: only the head steward appoints stewards")
	}
	Enroll(steward)
}

// Enroll writes steward on the roster. It is the helper Appoint uses. It
// takes no realm, so no wallet can call it with MsgCall.
func Enroll(steward address) {
	roster.Set(steward.String(), runtime.ChainHeight())
}

// Descend takes a steward down to the old vintages, where the flag is.
func Descend(cur realm) {
	player := flag.MustPlayer(cur.Previous())
	if !roster.Has(player.String()) {
		panic("stair: the door steward does not know you")
	}
	captures.Record(player)
}

// IsSteward reports whether addr is on the roster.
func IsSteward(addr address) bool { return roster.Has(addr.String()) }

// Render shows the roster.
func Render(_ string) string {
	var b strings.Builder
	b.WriteString(flag.Card(info, captures))
	b.WriteString("\n## The roster\n\n")
	if roster.Size() == 0 {
		b.WriteString("*No stewards yet.*\n")
	}
	roster.Iterate("", "", func(addr string, v any) bool {
		b.WriteString("- `" + addr + "` since block " + strconv.FormatInt(v.(int64), 10) + "\n")
		return false
	})
	b.WriteString("\n## Captured by\n\n" + flag.Captures(captures, 5))
	return b.String()
}
