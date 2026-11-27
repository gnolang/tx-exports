// PKGPATH: gno.land/r/gnometavern/main

// End-to-end happy path: post a quest with an escrowed reward, a
// second user accepts it, the poster completes it and the adventurer
// gets paid. NOTE: authored against the pattern of
// examples/gno.land/r/demo/disperse/filetests; pending first execution
// once the local toolchain's GNOROOT stdlib is available (see
// ../../RESEARCH.md, "Toolchain status").
package main

import (
	"chain"
	"chain/banker"
	"testing"
	"time"

	qb "gno.land/r/g13fd5s4h9ap0cggkgxnkqf0wawm9ew8x2kvnlv5/questboard"
)

func main(cur realm) {
	mainAddr := chain.PackageAddress("gno.land/r/gnometavern/main")
	qbAddr := chain.PackageAddress("gno.land/r/g13fd5s4h9ap0cggkgxnkqf0wawm9ew8x2kvnlv5/questboard")
	adventurer := address("g1dmt3sa5ucvecxuhf3j6ne5r0e3z4x7h6c03xc0")
	reward := int64(5000000)

	ro := banker.NewReadonlyBanker()
	banker_ := banker.NewBanker(banker.BankerTypeRealmSend, cur)

	// Fund the poster (the main realm plays the user) and stage the
	// send envelope for the PostQuest call.
	testing.IssueCoins(mainAddr, chain.Coins{{Denom: "ugnot", Amount: reward}})
	testing.SetRealm(testing.NewUserRealm(mainAddr))
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: reward}})
	banker_.SendCoins(mainAddr, qbAddr, chain.Coins{{Denom: "ugnot", Amount: reward}})

	deadline := time.Now().Unix() + 86400
	id := qb.PostQuest(cross(cur),
		"Slay the spam goblins", "Clear the tavern cellar of spam goblins.",
		reward, deadline)
	println("quest id:", id)
	println("escrowed after post:", qb.EscrowedTotal())
	println("board balance after post:", ro.GetCoin(qbAddr, "ugnot"))

	// A different user accepts the quest.
	testing.SetRealm(testing.NewUserRealm(adventurer))
	qb.AcceptQuest(cross(cur), id)
	println("open quests after accept:", qb.OpenQuestCount())

	// The poster completes it; escrow pays the adventurer.
	testing.SetRealm(testing.NewUserRealm(mainAddr))
	qb.CompleteQuest(cross(cur), id)
	println("adventurer balance after complete:", ro.GetCoin(adventurer, "ugnot"))
	println("board balance after complete:", ro.GetCoin(qbAddr, "ugnot"))
	println("escrowed after complete:", qb.EscrowedTotal())
}

// Output:
// quest id: 1
// escrowed after post: 5000000
// board balance after post: 5000000
// open quests after accept: 0
// adventurer balance after complete: 5000000
// board balance after complete: 0
// escrowed after complete: 0
