// PKGPATH: gno.land/r/demo/main

// A match's moves each tell the player who moves next, and only them.
package main

import (
	"crypto/sha256"
	"encoding/hex"
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/r/nym-gfanton001/gnomepit/arena/v0"
)

const (
	deckA  = "Pickaxe Flurry,Kneecap,Sling Stone,Dodge Roll,Chalk Dust,Double Tap,Momentum,Undermine"
	deckB  = "Stone Guard,Bulwark,Hammer Blow,Cobble Throw,Spiked Shield,Anvil Stomp,Feint,Avalanche"
	saltA  = "0101010101010101010101010101010101010101010101010101010101010101"
	salt1  = "1111111111111111111111111111111111111111111111111111111111111111"
	salt2  = "2222222222222222222222222222222222222222222222222222222222222222"
	picks  = "Pick,Pick,Pick"
	braces = "Brace,Brace,Brace"
)

func seal(salt, text string) string {
	b, _ := hex.DecodeString(salt)
	sum := sha256.Sum256(append(b, text...))
	return hex.EncodeToString(sum[:])
}

func main(cur realm) {
	alice := testutils.TestAddress("alice")
	bob := testutils.TestAddress("bob")

	testing.SetRealm(testing.NewUserRealm(alice))
	id := arena.Challenge(cross(cur), "Pickers", seal(saltA, deckA), seal(salt1, picks), "box1", "")
	testing.SetRealm(testing.NewUserRealm(bob))
	arena.Accept(cross(cur), id, "Ironhide", deckB, braces)
	testing.SetRealm(testing.NewUserRealm(alice))
	arena.Reveal(cross(cur), id, deckA, saltA, picks, salt1, seal(salt2, picks), "box2")
	testing.SetRealm(testing.NewUserRealm(bob))
	arena.Play(cross(cur), id, braces)
}

// Events:
// [
//   {
//     "type": "Board",
//     "attrs": [
//       {
//         "key": "match",
//         "value": "1"
//       },
//       {
//         "key": "text",
//         "value": "Pickers posted a challenge."
//       }
//     ],
//     "pkg_path": "gno.land/r/nym-gfanton001/gnomepit/arena/v0"
//   },
//   {
//     "type": "Board",
//     "attrs": [
//       {
//         "key": "match",
//         "value": "1"
//       },
//       {
//         "key": "text",
//         "value": "Challenge 1 was taken."
//       }
//     ],
//     "pkg_path": "gno.land/r/nym-gfanton001/gnomepit/arena/v0"
//   },
//   {
//     "type": "Turn",
//     "attrs": [
//       {
//         "key": "to",
//         "value": "g1v9kxjcm9ta047h6lta047h6lta047h6lzd40gh"
//       },
//       {
//         "key": "match",
//         "value": "1"
//       },
//       {
//         "key": "text",
//         "value": "Ironhide accepted your challenge. Your move within 24 hours."
//       }
//     ],
//     "pkg_path": "gno.land/r/nym-gfanton001/gnomepit/arena/v0"
//   },
//   {
//     "type": "Turn",
//     "attrs": [
//       {
//         "key": "to",
//         "value": "g1vfhkyh6lta047h6lta047h6lta047h6l03vdhu"
//       },
//       {
//         "key": "match",
//         "value": "1"
//       },
//       {
//         "key": "text",
//         "value": "Round 1 is over: you 15 HP, them 15. Your move within 24 hours."
//       }
//     ],
//     "pkg_path": "gno.land/r/nym-gfanton001/gnomepit/arena/v0"
//   },
//   {
//     "type": "Turn",
//     "attrs": [
//       {
//         "key": "to",
//         "value": "g1v9kxjcm9ta047h6lta047h6lta047h6lzd40gh"
//       },
//       {
//         "key": "match",
//         "value": "1"
//       },
//       {
//         "key": "text",
//         "value": "Ironhide played round 2. Your move within 24 hours."
//       }
//     ],
//     "pkg_path": "gno.land/r/nym-gfanton001/gnomepit/arena/v0"
//   }
// ]
