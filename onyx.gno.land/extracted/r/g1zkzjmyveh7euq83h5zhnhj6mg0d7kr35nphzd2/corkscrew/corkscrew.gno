// Package corkscrew is a community challenge for the Cellar, written by
// a player to show how any realm can join the hall by importing the flag
// package. It is about the order in which an avl.Tree iterates.
package corkscrew

import (
	"strconv"
	"strings"

	"gno.land/p/g15c02s5hhdny9uvr9za3xsyn9sw8p0klptrh6kf/cellar/flag"
	"gno.land/p/nt/avl/v0"
	"gno.land/r/g15c02s5hhdny9uvr9za3xsyn9sw8p0klptrh6kf/cellar/hall"
)

var info = flag.Info{
	Slug:       "corkscrew",
	Title:      "The Corkscrew",
	Difficulty: flag.Easy,
	Category:   "avl trees",
	Brief: "The cellar opens its oldest bottle first. The register is kept by year, and only bottles " +
		"younger than 1900 may be added. Get your own bottle opened first.",
}

var (
	captures = flag.NewLedger()
	shelf    = avl.NewTree() // year as decimal string -> owner address
)

func init(cur realm) {
	shelf.Set("1811", cur.Address()) // the house bottle belongs to the realm
	hall.Enlist(cross(cur), challenge{})
}

type challenge struct{}

func (challenge) Info() flag.Info              { return info }
func (challenge) Captured(player address) bool { return captures.Captured(player) }

// Shelve adds your bottle of the given year to the shelf.
func Shelve(cur realm, year int) {
	if year <= 1900 {
		panic("corkscrew: only bottles after 1900 may be shelved")
	}
	key := strconv.Itoa(year)
	if shelf.Has(key) {
		panic("corkscrew: a bottle of that year is already shelved")
	}
	shelf.Set(key, cur.Previous().Address())
}

// Open opens the oldest bottle on the shelf: the first one the register
// lists. If it is yours, the flag is yours.
func Open(cur realm) {
	player := flag.MustPlayer(cur.Previous())
	_, owner := shelf.GetByIndex(0)
	if owner.(address) != player {
		panic("corkscrew: the oldest bottle is not yours")
	}
	captures.Record(player)
}

// Render shows the shelf in register order.
func Render(_ string) string {
	var b strings.Builder
	b.WriteString(flag.Card(info, captures))
	b.WriteString("\n## The shelf, oldest first\n\n")
	shelf.Iterate("", "", func(year string, v any) bool {
		b.WriteString("- " + year + ": `" + v.(address).String() + "`\n")
		return false
	})
	b.WriteString("\n## Captured by\n\n" + flag.Captures(captures, 5))
	return b.String()
}
