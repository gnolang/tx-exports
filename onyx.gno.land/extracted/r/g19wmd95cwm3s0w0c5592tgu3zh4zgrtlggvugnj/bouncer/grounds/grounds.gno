// Package grounds is the Training Grounds front page and hunters board:
// who broke which practice target. It only reads the targets; it holds no
// state of its own and has no write functions.
package grounds

import (
	"strconv"
	"strings"

	"gno.land/r/g19wmd95cwm3s0w0c5592tgu3zh4zgrtlggvugnj/bouncer/grounds/b01"
	"gno.land/r/g19wmd95cwm3s0w0c5592tgu3zh4zgrtlggvugnj/bouncer/grounds/b05"
)

const base = "/r/g19wmd95cwm3s0w0c5592tgu3zh4zgrtlggvugnj/bouncer"

// Entry is one claim on the hunters board.
type Entry struct {
	Hunter address
	Ground string // rule ID, such as B01
	Height int64
}

// Board returns every claim, oldest first (by block, then ground).
func Board() []Entry {
	var out []Entry
	for _, h := range b01.Hunters() {
		out = append(out, Entry{Hunter: h.Addr, Ground: "B01", Height: h.Height})
	}
	for _, h := range b05.Hunters() {
		out = append(out, Entry{Hunter: h.Addr, Ground: "B05", Height: h.Height})
	}
	// Insertion sort: the board is small, and this keeps it deterministic.
	for i := 1; i < len(out); i++ {
		for j := i; j > 0 && less(out[j], out[j-1]); j-- {
			out[j], out[j-1] = out[j-1], out[j]
		}
	}
	return out
}

func less(a, b Entry) bool {
	if a.Height != b.Height {
		return a.Height < b.Height
	}
	return a.Ground < b.Ground
}

func Render(_ string) string {
	var b strings.Builder
	b.WriteString("# Training Grounds\n\n")
	b.WriteString("Practice targets with a real bug each, on purpose. Bouncer finds and proves each one; now try it yourself. " +
		"Break a target, then call its `Claim` from the address that broke it.\n\n")
	b.WriteString("| Ground | Bug | Status | Hunters |\n| --- | --- | --- | --- |\n")
	row := func(rule, name, bug string, broken bool, n int) {
		status := "🟢 Holds"
		if broken {
			status = "🔴 Broken"
		}
		b.WriteString("| [" + rule + ": " + name + "](" + base + "/grounds/" + strings.ToLower(rule) + ") | " + bug + " | " + status + " | " + strconv.Itoa(n) + " |\n")
	}
	row("B01", "the leaky ledger", "a getter returns the live `*avl.Tree` (guide §5.1)", b01.Broken(), len(b01.Hunters()))
	row("B05", "the trusting tip jar", "`IsUser()` guards an `OriginSend` payment (guide §5.5)", b05.Broken(), len(b05.Hunters()))
	b.WriteString("\n## Hunters\n\n")
	board := Board()
	if len(board) == 0 {
		b.WriteString("Nobody has broken a ground yet.\n")
		return b.String()
	}
	b.WriteString("| Block | Hunter | Ground |\n| --- | --- | --- |\n")
	for _, e := range board {
		b.WriteString("| " + strconv.FormatInt(e.Height, 10) + " | `" + e.Hunter.String() + "` | " + e.Ground + " |\n")
	}
	return b.String()
}
