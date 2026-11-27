package stair

import (
	"gno.land/p/g15c02s5hhdny9uvr9za3xsyn9sw8p0klptrh6kf/cellar/flag"
	"gno.land/r/g15c02s5hhdny9uvr9za3xsyn9sw8p0klptrh6kf/cellar/hall"
)

var info = flag.Info{
	Slug:       "stair",
	Title:      "The Back Stair",
	Difficulty: flag.Medium,
	Category:   "crossing functions",
	Brief: "The way down to the old vintages is guarded: only stewards on the roster may descend, " +
		"and only the head steward appoints them, through the front door. The staff use a back stair " +
		"that no wallet can reach. Get your name on the roster and descend.",
}

var captures = flag.NewLedger()

type challenge struct{}

func (challenge) Info() flag.Info              { return info }
func (challenge) Captured(player address) bool { return captures.Captured(player) }

// Challenge describes this realm to a hall.
func Challenge() flag.Challenge { return challenge{} }

func init(cur realm) { hall.Enlist(cross(cur), challenge{}) }
