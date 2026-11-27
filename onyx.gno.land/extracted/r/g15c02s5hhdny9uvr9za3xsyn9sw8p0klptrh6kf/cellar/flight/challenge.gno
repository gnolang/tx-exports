package flight

import (
	"gno.land/p/g15c02s5hhdny9uvr9za3xsyn9sw8p0klptrh6kf/cellar/flag"
	"gno.land/r/g15c02s5hhdny9uvr9za3xsyn9sw8p0klptrh6kf/cellar/hall"
)

var info = flag.Info{
	Slug:       "flight",
	Title:      "The Spilled Flight",
	Difficulty: flag.Medium,
	Category:   "panic and recover",
	Brief: "Nine wines on the list. A tasting token buys a flight of up to three glasses, and you hold two " +
		"tokens. The sommelier is generous about accidents: a spilled glass is never charged. " +
		"Taste all nine.",
}

var captures = flag.NewLedger()

type challenge struct{}

func (challenge) Info() flag.Info              { return info }
func (challenge) Captured(player address) bool { return captures.Captured(player) }

// Challenge describes this realm to a hall.
func Challenge() flag.Challenge { return challenge{} }

func init(cur realm) { hall.Enlist(cross(cur), challenge{}) }
