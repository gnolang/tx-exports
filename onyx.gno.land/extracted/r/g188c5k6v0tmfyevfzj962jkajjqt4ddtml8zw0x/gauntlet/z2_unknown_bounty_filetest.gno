// PKGPATH: gno.land/r/g188c5k6v0tmfyevfzj962jkajjqt4ddtml8zw0x/main
package main

import (
	"chain"
	"testing"

	"gno.land/r/g188c5k6v0tmfyevfzj962jkajjqt4ddtml8zw0x/gauntlet"
	_ "gno.land/r/g188c5k6v0tmfyevfzj962jkajjqt4ddtml8zw0x/solvers/rev1"
)

func main(cur realm) {
	poster := address("g1q646ctzhvn60v392yy4ldq5zyr8q5hnxee3zqe")
	alice := address("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5")
	mallory := address("g1dmt3sa5ucvecxuhf3j6ne5r0e3z4x7h6c03xc0")
	boardAddr := chain.PackageAddress("gno.land/r/g188c5k6v0tmfyevfzj962jkajjqt4ddtml8zw0x/gauntlet")
	_, _ = alice, mallory

	coins := chain.Coins{{Denom: "ugnot", Amount: 1_000_000}}
	testing.IssueCoins(boardAddr, coins)
	testing.SetOriginSend(coins)
	testing.SetRealm(testing.NewUserRealm(poster))
	id := gauntlet.Post(cross(cur), "Reverse", "", "abc => cba", 6, 0, 30)

	testing.SetOriginSend(chain.Coins{})
	testing.SetRealm(testing.NewUserRealm(alice))
	hash := gauntlet.HashFor("gno.land/r/g188c5k6v0tmfyevfzj962jkajjqt4ddtml8zw0x/solvers/rev1", "alice-salt")
	gauntlet.Commit(cross(cur), id, hash)
	_ = hash

	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: 5}})
	testing.SetRealm(testing.NewUserRealm(mallory))
	gauntlet.Boost(cross(cur), 999)
}

// Error:
// gauntlet: challenge not found
