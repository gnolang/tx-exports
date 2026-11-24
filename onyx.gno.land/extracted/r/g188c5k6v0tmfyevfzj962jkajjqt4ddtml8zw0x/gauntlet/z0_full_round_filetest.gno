// PKGPATH: gno.land/r/g188c5k6v0tmfyevfzj962jkajjqt4ddtml8zw0x/main
package main

import (
	"chain"
	"chain/banker"
	"testing"

	"gno.land/r/g188c5k6v0tmfyevfzj962jkajjqt4ddtml8zw0x/gauntlet"
	"gno.land/r/g188c5k6v0tmfyevfzj962jkajjqt4ddtml8zw0x/solvers/rev1"
)

// A full round: a poster funds a bounty, a solver commits, deploys and
// reveals, the realm grades the code on-chain and pays out.
//
// IssueCoins plus SetOriginSend stand in for what `gnokey maketx call -send`
// does on chain: the coins land at the realm's address and the realm reads
// the envelope with OriginSend.
func main(cur realm) {
	poster := address("g1q646ctzhvn60v392yy4ldq5zyr8q5hnxee3zqe")
	solver := address("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5")
	boardAddr := chain.PackageAddress("gno.land/r/g188c5k6v0tmfyevfzj962jkajjqt4ddtml8zw0x/gauntlet")
	bk := banker.NewReadonlyBanker()

	// The poster funds a 2 GNOT bounty: 12 hours, 0.5 GNOT bond, 30 minute window.
	fund(boardAddr, 2_000_000)
	testing.SetRealm(testing.NewUserRealm(poster))
	id := gauntlet.Post(cross(cur), "Reverse a string",
		"Return the input reversed.", "abc => cba\nhello => olleh", 12, 500_000, 30)
	println("challenge:", id)
	println("board holds:", bk.GetCoin(boardAddr, "ugnot"))

	// The solver commits the hash of their realm path and a secret salt.
	hash := gauntlet.HashFor("gno.land/r/g188c5k6v0tmfyevfzj962jkajjqt4ddtml8zw0x/solvers/rev1", "my-secret")
	fund(boardAddr, 500_000)
	testing.SetRealm(testing.NewUserRealm(solver))
	gauntlet.Commit(cross(cur), id, hash)
	println("board holds after commit:", bk.GetCoin(boardAddr, "ugnot"))

	// The solver's deployed realm reveals. Solve runs here, on-chain.
	testing.SetOriginSend(chain.Coins{})
	rev1.Submit(cross(cur), id, "my-secret")

	println("board holds after payout:", bk.GetCoin(boardAddr, "ugnot"))
	println("solver holds:", bk.GetCoin(solver, "ugnot"))
	println(gauntlet.ChallengeJSON(id))
}

// fund delivers coins to the realm and sets the send envelope, the way
// `gnokey maketx call -send` does.
func fund(to address, amount int64) {
	coins := chain.Coins{{Denom: "ugnot", Amount: amount}}
	testing.IssueCoins(to, coins)
	testing.SetOriginSend(coins)
}

// Output:
// challenge: 1
// board holds: 2000000
// board holds after commit: 2500000
// board holds after payout: 0
// solver holds: 2500000
// {"id":1,"title":"Reverse a string","spec":"Return the input reversed.","status":"won","poster":"g1q646ctzhvn60v392yy4ldq5zyr8q5hnxee3zqe","reward":2000000,"pot":2000000,"bond":500000,"boosts":0,"forfeited":0,"created":1234567890,"deadline":1234611090,"window":1800,"judge":"","cases":[{"in":"abc","want":"cba"},{"in":"hello","want":"olleh"}],"attempts":[{"seq":1,"solver":"g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5","hash":"507b14b79bff05d8d070068c833d2fbc865a5accd85e4fc45f9cd16edc4802d1","committed":1234567890,"state":"passed","pkgpath":"gno.land/r/g188c5k6v0tmfyevfzj962jkajjqt4ddtml8zw0x/solvers/rev1","passed":2,"total":2,"failIn":"","failGot":"","failWant":"","winner":true}]}
