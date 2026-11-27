// Package vintage is a Cellar challenge about trusting interface values.
package vintage

import (
	"strconv"
	"strings"

	"gno.land/p/g15c02s5hhdny9uvr9za3xsyn9sw8p0klptrh6kf/cellar/flag"
	"gno.land/p/nt/markdown/sanitize/v0"
)

const maxLabel = 60

// Bottle is a bottle from this cellar. The seal method is unexported, so
// no other package can declare a type that implements Bottle.
type Bottle interface {
	Vintage() int
	Label() string
	seal()
}

type bottle struct {
	vintage int
	label   string
}

func (b *bottle) Vintage() int  { return b.vintage }
func (b *bottle) Label() string { return b.label }
func (b *bottle) seal()         {}

// Uncork pours the house wine.
func Uncork() Bottle { return &bottle{vintage: 2024, label: "House red"} }

var certified []string // labels of certified bottles, for the window

// Appraise certifies b if it was bottled before 1900.
func Appraise(cur realm, b Bottle) {
	player := flag.MustPlayer(cur.Previous())
	if b == nil {
		panic("vintage: the appraiser needs a bottle")
	}
	if b.Vintage() >= 1900 {
		panic("vintage: a " + strconv.Itoa(b.Vintage()) + " is young. Come back with something older")
	}
	label := b.Label()
	if len(label) > maxLabel {
		label = label[:maxLabel]
	}
	certified = append(certified, label+" ("+strconv.Itoa(b.Vintage())+")")
	captures.Record(player)
}

// Render shows the appraiser's window.
func Render(_ string) string {
	var b strings.Builder
	b.WriteString(flag.Card(info, captures))
	b.WriteString("\n## In the window\n\n")
	if len(certified) == 0 {
		b.WriteString("*No bottle has been certified.*\n")
	}
	for i := len(certified) - 1; i >= 0 && i >= len(certified)-10; i-- {
		b.WriteString("- certified: " + sanitize.InlineText(certified[i]) + "\n")
	}
	b.WriteString("\n## Captured by\n\n" + flag.Captures(captures, 5))
	return b.String()
}
