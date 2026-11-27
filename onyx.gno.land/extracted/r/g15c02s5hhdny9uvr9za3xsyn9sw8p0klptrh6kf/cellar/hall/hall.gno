// Package hall is the scoreboard of Cellar, a capture-the-flag wargame
// played on gno.land.
//
// Challenge realms enlist themselves here from their init. Players break a
// challenge in its own realm, then Claim it here: the hall asks the
// challenge whether the player captured it, records the solve, awards a
// badge and updates the standings. Points follow the dynamic curve in
// package flag, so a challenge is worth less as more players solve it.
//
// Everything a player sees is in Render, so gnoweb is a complete client.
package hall

import (
	"strings"

	"gno.land/p/nt/avl/v0"
)

// officialPrefix marks the realms of the Cellar team. Challenges enlisted
// from below it are listed at once; everyone else waits for the curator.
const officialPrefix = "gno.land/r/g15c02s5hhdny9uvr9za3xsyn9sw8p0klptrh6kf/cellar/"

// feedSize is how many recent solves the hall remembers for its feed.
const feedSize = 50

var (
	curator  = address("g15c02s5hhdny9uvr9za3xsyn9sw8p0klptrh6kf")
	selfPath string // web path of this realm, e.g. /r/<ns>/cellar/hall

	entries = avl.NewTree() // slug -> *entry
	paths   = avl.NewTree() // challenge realm path -> slug
	order   []string        // slugs in enlistment order
	players = avl.NewTree() // address -> *profile
	handles = avl.NewTree() // handle -> address
	seasons []*season       // the last one is open
	feed    []Solve         // newest last, at most feedSize
)

func init(cur realm) {
	selfPath = strings.TrimPrefix(cur.PkgPath(), "gno.land")
	initBadges(cur)
	seasons = append(seasons, newSeason(1, "First Pressing"))
}

// Curator returns the address allowed to curate the hall.
func Curator() address { return curator }

// TransferCuration hands the curator role to another address.
func TransferCuration(cur realm, to address) {
	assertCurator(cur)
	if !to.IsValid() {
		panic(ErrBadAddress)
	}
	curator = to
}

func assertCurator(cur realm) {
	if cur.Previous().Address() != curator {
		panic(ErrNotCurator)
	}
}
