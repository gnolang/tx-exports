// PKGPATH: gno.land/r/gnometavern/main

// End-to-end cancel path: post a quest, then the poster cancels it
// while it is still open and receives the full escrow back.
// NOTE: authored against the pattern of
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
	reward := int64(3000000)

	ro := banker.NewReadonlyBanker()
	banker_ := banker.NewBanker(banker.BankerTypeRealmSend, cur)

	testing.IssueCoins(mainAddr, chain.Coins{{Denom: "ugnot", Amount: reward}})
	testing.SetRealm(testing.NewUserRealm(mainAddr))
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: reward}})
	banker_.SendCoins(mainAddr, qbAddr, chain.Coins{{Denom: "ugnot", Amount: reward}})

	deadline := time.Now().Unix() + 86400
	id := qb.PostQuest(cross(cur),
		"Polish the tavern mugs", "Every mug. Twice.",
		reward, deadline)
	println("poster balance after post:", ro.GetCoin(mainAddr, "ugnot"))
	println("escrowed after post:", qb.EscrowedTotal())

	qb.CancelQuest(cross(cur), id)
	println("poster balance after cancel:", ro.GetCoin(mainAddr, "ugnot"))
	println("board balance after cancel:", ro.GetCoin(qbAddr, "ugnot"))
	println("escrowed after cancel:", qb.EscrowedTotal())
}

// Output:
// poster balance after post: 0
// escrowed after post: 3000000
// poster balance after cancel: 3000000
// board balance after cancel: 0
// escrowed after cancel: 0
