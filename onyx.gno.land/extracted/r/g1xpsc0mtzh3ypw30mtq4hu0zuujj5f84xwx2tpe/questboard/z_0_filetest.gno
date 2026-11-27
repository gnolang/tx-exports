// PKGPATH: gno.land/r/demo/main

package main

import (
	"chain"
	"chain/banker"
	"testing"

	"gno.land/r/g1xpsc0mtzh3ypw30mtq4hu0zuujj5f84xwx2tpe/questboard"
)

// Full quest life cycle: post with escrow, claim, submit, approve and get
// paid; then a second quest that is cancelled and refunded.
//
// This filetest's own realm (main) plays the poster: a realm banker can
// only send from its own address, so main delivers the escrow coins to
// the board, and SetRealm(NewUserRealm(mainAddr)) makes the crossing
// calls look like ordinary user calls from that same address.
func main(cur realm) {
	mainAddr := chain.PackageAddress("gno.land/r/demo/main")
	boardAddr := chain.PackageAddress("gno.land/r/g1xpsc0mtzh3ypw30mtq4hu0zuujj5f84xwx2tpe/questboard")
	claimer := address("g1akeqsvhucjt8gf5yupyzjxsjd29wv8fayng37c")
	banker_ := banker.NewBanker(banker.BankerTypeRealmSend, cur)

	// The poster (main) starts with 2 GNOT.
	testing.IssueCoins(mainAddr, chain.Coins{{Denom: "ugnot", Amount: 2_000_000}})

	// Post quest 1 with 0.6 GNOT: main sends the coins to the board (the
	// escrow delivery), then calls PostQuest as a user with the same
	// amount reported as OriginSend.
	banker_.SendCoins(mainAddr, boardAddr, chain.Coins{{Denom: "ugnot", Amount: 600_000}})
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: 600_000}})
	testing.SetRealm(testing.NewUserRealm(mainAddr))
	id := questboard.PostQuest(cross(cur), "Write the tavern song", "Compose a short song for the tavern wall.")
	println("quest id:", id)
	println("board balance:", banker_.GetCoin(boardAddr, "ugnot"))
	println("poster balance:", banker_.GetCoin(mainAddr, "ugnot"))

	// The claimer takes the quest and marks the work done.
	testing.SetRealm(testing.NewUserRealm(claimer))
	questboard.ClaimQuest(cross(cur), id)
	questboard.SubmitWork(cross(cur), id)
	_, _, _, _, status := questboard.GetQuest(id)
	println("status after submit:", status)

	// The poster approves: the escrow moves to the claimer.
	testing.SetRealm(testing.NewUserRealm(mainAddr))
	questboard.ApproveQuest(cross(cur), id)
	println("board balance after approve:", banker_.GetCoin(boardAddr, "ugnot"))
	println("claimer balance:", banker_.GetCoin(claimer, "ugnot"))
	_, _, _, _, status = questboard.GetQuest(id)
	println("status after approve:", status)

	// Post quest 2 with 0.3 GNOT, then cancel it while it is still open:
	// the escrow is refunded to the poster.
	testing.SetRealm(testing.NewUserRealm(mainAddr))
	banker_.SendCoins(mainAddr, boardAddr, chain.Coins{{Denom: "ugnot", Amount: 300_000}})
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: 300_000}})
	id2 := questboard.PostQuest(cross(cur), "Sharpen the tavern knives", "")
	questboard.CancelQuest(cross(cur), id2)
	println("board balance after cancel:", banker_.GetCoin(boardAddr, "ugnot"))
	println("poster balance after cancel:", banker_.GetCoin(mainAddr, "ugnot"))
	_, _, _, _, status = questboard.GetQuest(id2)
	println("status after cancel:", status)
	println("quest count:", questboard.QuestCount())
}

// Output:
// quest id: 1
// board balance: 600000
// poster balance: 1400000
// status after submit: done
// board balance after approve: 0
// claimer balance: 600000
// status after approve: paid
// board balance after cancel: 0
// poster balance after cancel: 1400000
// status after cancel: cancelled
// quest count: 2
