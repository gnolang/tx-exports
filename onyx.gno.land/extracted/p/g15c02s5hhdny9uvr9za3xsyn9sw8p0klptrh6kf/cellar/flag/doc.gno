// Package flag is the shared vocabulary of Cellar, a capture-the-flag
// wargame played on gno.land.
//
// A challenge is a realm that holds a deliberate weakness. When a player
// exploits it, the realm records a capture in a Ledger. A hall (a
// scoreboard realm) learns about the challenge through the Challenge
// interface and asks it, on claim, whether a given player captured it.
//
// Anyone can author a challenge by importing this package:
//
//	package riddle
//
//	import (
//		"gno.land/p/<ns>/cellar/flag"
//		"gno.land/r/<ns>/cellar/hall"
//	)
//
//	var captures = flag.NewLedger()
//
//	type challenge struct{}
//
//	func (challenge) Info() flag.Info { return info }
//	func (challenge) Captured(p address) bool { return captures.Captured(p) }
//
//	func init(cur realm) { hall.Enlist(cross(cur), challenge{}) }
//
// The package also carries the scoring curve (Value) and the rule that
// maps a caller to the player who gets the credit (Player).
package flag
