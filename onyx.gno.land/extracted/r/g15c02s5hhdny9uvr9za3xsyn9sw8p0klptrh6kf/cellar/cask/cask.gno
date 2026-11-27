// Package cask is a Cellar challenge about fixed-width integer arithmetic.
package cask

import (
	"strconv"
	"strings"

	"gno.land/p/g15c02s5hhdny9uvr9za3xsyn9sw8p0klptrh6kf/cellar/flag"
	"gno.land/p/nt/avl/v0"
)

const (
	price int64 = 1_099_511_627_776 // shillings per cask of the 1811
	purse int64 = 100               // what every guest starts with
	goal  int64 = 1_000_000         // casks that make the cellar yours
)

type account struct {
	shillings int64
	casks     int64
}

var accounts = avl.NewTree() // address -> *account

// Buy purchases casks at the cooper's price.
func Buy(cur realm, casks int64) {
	player := flag.MustPlayer(cur.Previous())
	if casks <= 0 {
		panic("cask: buy at least one cask")
	}
	a := accountOf(player)
	cost := casks * price
	if cost > a.shillings {
		panic("cask: the cooper laughs; you cannot afford that")
	}
	a.shillings -= cost
	a.casks += casks
	if a.casks >= goal {
		captures.Record(player)
	}
}

// Holdings returns the purse and casks of addr.
func Holdings(addr address) (shillings, casks int64) {
	a := accountOf(addr)
	return a.shillings, a.casks
}

func accountOf(addr address) *account {
	if v := accounts.Get(addr.String()); v != nil {
		return v.(*account)
	}
	a := &account{shillings: purse}
	accounts.Set(addr.String(), a)
	return a
}

// Render shows the price list and the guests' books.
func Render(_ string) string {
	var b strings.Builder
	b.WriteString(flag.Card(info, captures))
	b.WriteString("\n**Price:** " + strconv.FormatInt(price, 10) + " shillings a cask · **Purse:** " +
		strconv.FormatInt(purse, 10) + " shillings · **Goal:** " + strconv.FormatInt(goal, 10) + " casks\n\n")
	b.WriteString("## The cooper's book\n\n| Guest | Shillings | Casks |\n|---|---:|---:|\n")
	accounts.Iterate("", "", func(addr string, v any) bool {
		a := v.(*account)
		b.WriteString("| `" + addr + "` | " + strconv.FormatInt(a.shillings, 10) + " | " + strconv.FormatInt(a.casks, 10) + " |\n")
		return false
	})
	b.WriteString("\n## Captured by\n\n" + flag.Captures(captures, 5))
	return b.String()
}
