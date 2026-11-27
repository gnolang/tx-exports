package cask

import (
	"gno.land/p/g15c02s5hhdny9uvr9za3xsyn9sw8p0klptrh6kf/cellar/flag"
	"gno.land/r/g15c02s5hhdny9uvr9za3xsyn9sw8p0klptrh6kf/cellar/hall"
)

var info = flag.Info{
	Slug:       "cask",
	Title:      "Cask Strength",
	Difficulty: flag.Easy,
	Category:   "integer arithmetic",
	Brief: "The cooper sells casks of the 1811 at a price no guest can pay, and every guest starts with " +
		"a purse of 100 shillings. He does the sums himself and he never checks his own arithmetic. " +
		"Own a million casks.",
}

var captures = flag.NewLedger()

type challenge struct{}

func (challenge) Info() flag.Info              { return info }
func (challenge) Captured(player address) bool { return captures.Captured(player) }

// Challenge describes this realm to a hall.
func Challenge() flag.Challenge { return challenge{} }

func init(cur realm) { hall.Enlist(cross(cur), challenge{}) }
