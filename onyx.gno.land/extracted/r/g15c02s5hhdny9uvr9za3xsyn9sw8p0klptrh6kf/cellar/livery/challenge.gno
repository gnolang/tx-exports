package livery

import (
	"gno.land/p/g15c02s5hhdny9uvr9za3xsyn9sw8p0klptrh6kf/cellar/flag"
	"gno.land/r/g15c02s5hhdny9uvr9za3xsyn9sw8p0klptrh6kf/cellar/hall"
)

var info = flag.Info{
	Slug:       "livery",
	Title:      "Borrowed Livery",
	Difficulty: flag.Hard,
	Category:   "realm context",
	Brief: "Only the steward may dress a guest in the house livery, and the wardrobe checks that the " +
		"steward is the realm acting before it hands one over. The steward is a busy realm with a soft " +
		"spot for toasts. Wear the livery and enter the private cellar.",
}

var captures = flag.NewLedger()

type challenge struct{}

func (challenge) Info() flag.Info              { return info }
func (challenge) Captured(player address) bool { return captures.Captured(player) }

// Challenge describes this realm to a hall.
func Challenge() flag.Challenge { return challenge{} }

func init(cur realm) { hall.Enlist(cross(cur), challenge{}) }
