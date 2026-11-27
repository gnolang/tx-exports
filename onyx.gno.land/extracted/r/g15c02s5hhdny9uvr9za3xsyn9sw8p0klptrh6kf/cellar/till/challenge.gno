package till

import (
	"gno.land/p/g15c02s5hhdny9uvr9za3xsyn9sw8p0klptrh6kf/cellar/flag"
	"gno.land/r/g15c02s5hhdny9uvr9za3xsyn9sw8p0klptrh6kf/cellar/hall"
)

var info = flag.Info{
	Slug:       "till",
	Title:      "The Empty Till",
	Difficulty: flag.Hard,
	Category:   "coins",
	Brief: "A round at the bar costs 0.1 GNOT, and the barkeep checks the money you sent before he " +
		"pours. At closing, the auditor counts the till after every round: a round poured with less " +
		"than its price in the till is a round stolen. Get yourself into the auditor's book.",
}

var captures = flag.NewLedger()

type challenge struct{}

func (challenge) Info() flag.Info              { return info }
func (challenge) Captured(player address) bool { return captures.Captured(player) }

// Challenge describes this realm to a hall.
func Challenge() flag.Challenge { return challenge{} }

func init(cur realm) { hall.Enlist(cross(cur), challenge{}) }
