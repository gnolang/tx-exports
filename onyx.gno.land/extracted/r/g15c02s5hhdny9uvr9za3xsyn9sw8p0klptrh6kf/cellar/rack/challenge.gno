package rack

import (
	"gno.land/p/g15c02s5hhdny9uvr9za3xsyn9sw8p0klptrh6kf/cellar/flag"
	"gno.land/r/g15c02s5hhdny9uvr9za3xsyn9sw8p0klptrh6kf/cellar/hall"
)

var info = flag.Info{
	Slug:       "rack",
	Title:      "The Open Rack",
	Difficulty: flag.Medium,
	Category:   "storage authority",
	Brief: "The reserve rack is posted on the cellar door for every realm to read. Gno makes other " +
		"realms' objects read-only, so the keeper sleeps soundly. Nobody has ever reserved the " +
		"1811 Château d'Yquem. Collect it in your name.",
}

var captures = flag.NewLedger()

type challenge struct{}

func (challenge) Info() flag.Info              { return info }
func (challenge) Captured(player address) bool { return captures.Captured(player) }

// Challenge describes this realm to a hall.
func Challenge() flag.Challenge { return challenge{} }

func init(cur realm) { hall.Enlist(cross(cur), challenge{}) }
