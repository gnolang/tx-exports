// Package lounge is a VIP guestbook: a pure Barkeep consumer. Only patrons
// with at least the Regular tier may sign; it never attests anyone.
package lounge

import (
	"chain/runtime"
	"strconv"
	"strings"

	"gno.land/p/g1dmwvymew9ku97tp30xka70w4tnn8cydh2tct9p/renown/v0"
	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/r/g1dmwvymew9ku97tp30xka70w4tnn8cydh2tct9p/barkeep/v0"
)

const (
	MinScore   = renown.RegularMin // Regular tier
	MaxMsgLen  = 100
	MaxEntries = 20 // ring buffer: oldest entry is overwritten
)

type entry struct {
	who    address
	tier   string
	msg    string
	height int64
}

var (
	book  []entry
	next  int // ring position of the next write once full
	total int // signatures ever written
)

// Sign adds a line to the guestbook. It panics for Strangers and for
// messages that are empty, too long or not printable ASCII.
func Sign(cur realm, msg string) {
	who := cur.Previous().Address()
	if !barkeep.HasMinScore(who, MinScore) {
		panic("lounge: Regulars only, come back with a Barkeep score of " + strconv.FormatInt(MinScore, 10))
	}
	msg = strings.TrimSpace(msg)
	if len(msg) == 0 || len(msg) > MaxMsgLen {
		panic("lounge: message must be 1-100 characters")
	}
	for i := 0; i < len(msg); i++ {
		if msg[i] < 0x20 || msg[i] > 0x7e {
			panic("lounge: message must be printable ASCII")
		}
	}
	add(entry{who: who, tier: barkeep.TierOf(who), msg: msg, height: runtime.ChainHeight()})
}

// add writes e into the ring buffer.
func add(e entry) {
	if len(book) < MaxEntries {
		book = append(book, e)
	} else {
		book[next] = e
		next = (next + 1) % MaxEntries
	}
	total++
}

// Signatures returns how many times the book was signed.
func Signatures() int { return total }

// Render lists the kept entries, newest first.
func Render(_ string) string {
	var b strings.Builder
	b.WriteString("# The Lounge\n\nVIP guestbook for Regulars and above, gated by [Barkeep](/r/g1dmwvymew9ku97tp30xka70w4tnn8cydh2tct9p/barkeep/v0).\n\n")
	if len(book) == 0 {
		return b.String() + "_Nobody has signed yet._\n"
	}
	b.WriteString("| Block | Patron | Tier | Message |\n|---|---|---|---|\n")
	for i := 0; i < len(book); i++ {
		e := book[(next-1-i+2*len(book))%len(book)]
		b.WriteString("| " + strconv.FormatInt(e.height, 10) + " | " + e.who.String() + " | " + e.tier + " | " + sanitize.TableCell(e.msg) + " |\n")
	}
	return b.String()
}
