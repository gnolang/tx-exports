package vintage

import (
	"gno.land/p/g15c02s5hhdny9uvr9za3xsyn9sw8p0klptrh6kf/cellar/flag"
	"gno.land/r/g15c02s5hhdny9uvr9za3xsyn9sw8p0klptrh6kf/cellar/hall"
)

var info = flag.Info{
	Slug:       "vintage",
	Title:      "Counterfeit Vintage",
	Difficulty: flag.Hard,
	Category:   "interfaces",
	Brief: "The appraiser certifies bottles older than 1900, but she only handles bottles from this " +
		"cellar: every Bottle carries the cellar's seal, an unexported method no other realm can " +
		"write. The house only pours the 2024. Get a bottle from before 1900 certified in your name.",
}

var captures = flag.NewLedger()

type challenge struct{}

func (challenge) Info() flag.Info              { return info }
func (challenge) Captured(player address) bool { return captures.Captured(player) }

// Challenge describes this realm to a hall.
func Challenge() flag.Challenge { return challenge{} }

func init(cur realm) { hall.Enlist(cross(cur), challenge{}) }
