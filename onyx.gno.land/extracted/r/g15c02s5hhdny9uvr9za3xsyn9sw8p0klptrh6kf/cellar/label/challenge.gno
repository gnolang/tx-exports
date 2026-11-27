package label

import (
	"gno.land/p/g15c02s5hhdny9uvr9za3xsyn9sw8p0klptrh6kf/cellar/flag"
	"gno.land/r/g15c02s5hhdny9uvr9za3xsyn9sw8p0klptrh6kf/cellar/hall"
)

var info = flag.Info{
	Slug:       "label",
	Title:      "The Forged Label",
	Difficulty: flag.Easy,
	Category:   "render",
	Brief: "The cellar keeps a register by the door. Any guest may chalk a note on it, and the cellar master " +
		"lists the tasters she has sealed. When asked, she reads the whole register aloud and believes every word. " +
		"Get her to read a seal in your name that she never granted.",
}

var captures = flag.NewLedger()

type challenge struct{}

func (challenge) Info() flag.Info              { return info }
func (challenge) Captured(player address) bool { return captures.Captured(player) }

// Challenge describes this realm to a hall.
func Challenge() flag.Challenge { return challenge{} }

func init(cur realm) { hall.Enlist(cross(cur), challenge{}) }
