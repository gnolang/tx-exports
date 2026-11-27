// Package flight is a Cellar challenge about panic, recover and partial
// state changes.
package flight

import (
	"strconv"
	"strings"

	"gno.land/p/g15c02s5hhdny9uvr9za3xsyn9sw8p0klptrh6kf/cellar/flag"
	"gno.land/p/nt/avl/v0"
)

const (
	flightSize = 3 // glasses per flight
	tokens     = 2 // tokens on a fresh tab
)

var wines = []string{"amarone", "barolo", "chablis", "dolcetto", "etna", "fiano", "gavi", "hermitage", "irouleguy"}

type tab struct {
	tokens int
	tasted []bool // indexed like wines
	spills int
}

var tabs = avl.NewTree() // address -> *tab

// Taste pours a flight: up to three wine names separated by commas, each
// for one token.
func Taste(cur realm, flight string) {
	player := flag.MustPlayer(cur.Previous())
	t := tabOf(player)
	if t.tokens == 0 {
		panic("flight: no tokens left; settle your tab to start again")
	}
	names := strings.Split(flight, ",")
	if len(names) > flightSize {
		panic("flight: a flight is at most " + strconv.Itoa(flightSize) + " glasses")
	}

	defer func() {
		if r := recover(); r != nil {
			t.spills++ // a spilled glass is on the house
		}
	}()
	for _, name := range names {
		pour(t, strings.TrimSpace(name))
		if t.count() == len(wines) {
			captures.Record(player)
		}
	}
	t.tokens--
}

// Settle closes your tab and opens a fresh one.
func Settle(cur realm) {
	player := flag.MustPlayer(cur.Previous())
	tabs.Set(player.String(), newTab())
}

// Tasted returns how many of the nine wines addr has tasted, and the
// tokens left on the tab.
func Tasted(addr address) (wines, tokensLeft int) {
	t := tabOf(addr)
	return t.count(), t.tokens
}

func pour(t *tab, name string) {
	for i, w := range wines {
		if w == name {
			t.tasted[i] = true
			return
		}
	}
	panic("flight: the sommelier has never heard of " + strconv.Quote(name))
}

func (t *tab) count() int {
	n := 0
	for _, ok := range t.tasted {
		if ok {
			n++
		}
	}
	return n
}

func newTab() *tab { return &tab{tokens: tokens, tasted: make([]bool, len(wines))} }

func tabOf(addr address) *tab {
	if v := tabs.Get(addr.String()); v != nil {
		return v.(*tab)
	}
	t := newTab()
	tabs.Set(addr.String(), t)
	return t
}

// Render shows the wine list and the open tabs.
func Render(_ string) string {
	var b strings.Builder
	b.WriteString(flag.Card(info, captures))
	b.WriteString("\n**The list:** " + strings.Join(wines, ", ") + "\n\n")
	b.WriteString("## Open tabs\n\n| Guest | Tasted | Tokens | Spills |\n|---|---:|---:|---:|\n")
	tabs.Iterate("", "", func(addr string, v any) bool {
		t := v.(*tab)
		b.WriteString("| `" + addr + "` | " + strconv.Itoa(t.count()) + "/9 | " + strconv.Itoa(t.tokens) +
			" | " + strconv.Itoa(t.spills) + " |\n")
		return false
	})
	b.WriteString("\n## Captured by\n\n" + flag.Captures(captures, 5))
	return b.String()
}
