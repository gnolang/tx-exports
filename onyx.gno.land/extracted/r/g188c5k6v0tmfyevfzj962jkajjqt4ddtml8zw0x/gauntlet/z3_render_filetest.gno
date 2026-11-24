// PKGPATH: gno.land/r/g188c5k6v0tmfyevfzj962jkajjqt4ddtml8zw0x/main
package main

import (
	"chain"
	"testing"

	"gno.land/r/g188c5k6v0tmfyevfzj962jkajjqt4ddtml8zw0x/gauntlet"
	"gno.land/r/g188c5k6v0tmfyevfzj962jkajjqt4ddtml8zw0x/solvers/rev1"
)

// The gnoweb pages, rendered from real state.
func main(cur realm) {
	poster := address("g1q646ctzhvn60v392yy4ldq5zyr8q5hnxee3zqe")
	alice := address("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5")
	boardAddr := chain.PackageAddress("gno.land/r/g188c5k6v0tmfyevfzj962jkajjqt4ddtml8zw0x/gauntlet")

	coins := chain.Coins{{Denom: "ugnot", Amount: 3_000_000}}
	testing.IssueCoins(boardAddr, coins)
	testing.SetOriginSend(coins)
	testing.SetRealm(testing.NewUserRealm(poster))
	id := gauntlet.Post(cross(cur), "Reverse a string",
		"Return the input reversed. Runes, not bytes.", "abc => cba\nhello => olleh", 48, 0, 30)

	testing.SetOriginSend(chain.Coins{})
	testing.SetRealm(testing.NewUserRealm(alice))
	gauntlet.Commit(cross(cur), id, gauntlet.HashFor("gno.land/r/g188c5k6v0tmfyevfzj962jkajjqt4ddtml8zw0x/solvers/rev1", "s"))

	println("=== board ===")
	println(gauntlet.Render(""))
	println("=== challenge, open ===")
	println(gauntlet.Render("c/1"))

	rev1.Submit(cross(cur), id, "s")
	println("=== challenge, won ===")
	println(gauntlet.Render("c/1"))
	println("=== leaderboard ===")
	println(gauntlet.Render("leaderboard"))
	println("=== profile ===")
	println(gauntlet.Render("u/" + alice.String()))
	println("=== unknown path ===")
	println(gauntlet.Render("nope"))
}

// Output:
// === board ===
// # Gauntlet
//
// **Coding bounties graded by the chain, not by people.** Post a challenge with a GNOT reward. Solvers deploy a function, this realm runs the tests on-chain, and the earliest passing commit is paid instantly. No reviewer can refuse to pay, and copying someone's deployed code never wins.
//
// [Board](/r/g188c5k6v0tmfyevfzj962jkajjqt4ddtml8zw0x/gauntlet) · [Leaderboard](/r/g188c5k6v0tmfyevfzj962jkajjqt4ddtml8zw0x/gauntlet:leaderboard) · [Judges](/r/g188c5k6v0tmfyevfzj962jkajjqt4ddtml8zw0x/gauntlet:judges) · [How to solve](/r/g188c5k6v0tmfyevfzj962jkajjqt4ddtml8zw0x/gauntlet:solve)
//
// | Open bounties | In escrow | Paid to solvers | Players |
// |---|---|---|---|
// | 1 | 3 GNOT | 0 GNOT | 2 |
//
// ## Open bounties
//
// | # | Challenge | Reward | Graded by | Attempts | Time |
// |---|---|---|---|---|---|
// | 1 | [Reverse a string](/r/g188c5k6v0tmfyevfzj962jkajjqt4ddtml8zw0x/gauntlet:c/1) | 3 GNOT | 2 tests | 1 | 2 days left |
//
// ## Recent winners
//
// _Nobody has won yet. Be first._
//
// ## Finished
//
// _None yet._
//
// ---
//
// [Post a bounty with test cases](/r/g188c5k6v0tmfyevfzj962jkajjqt4ddtml8zw0x/gauntlet$help&func=Post) · [Post a judged bounty](/r/g188c5k6v0tmfyevfzj962jkajjqt4ddtml8zw0x/gauntlet$help&func=PostJudged)
//
// === challenge, open ===
// # #1 Reverse a string
//
// [Board](/r/g188c5k6v0tmfyevfzj962jkajjqt4ddtml8zw0x/gauntlet) · [Leaderboard](/r/g188c5k6v0tmfyevfzj962jkajjqt4ddtml8zw0x/gauntlet:leaderboard) · [Judges](/r/g188c5k6v0tmfyevfzj962jkajjqt4ddtml8zw0x/gauntlet:judges) · [How to solve](/r/g188c5k6v0tmfyevfzj962jkajjqt4ddtml8zw0x/gauntlet:solve)
//
// > **Open** · reward **3 GNOT** · commits close Feb 15, 23:31 UTC (2 days left)
//
// | Reward | Bond per commit | Reveal window | Posted by | Posted |
// |---|---|---|---|---|
// | 3 GNOT | 0 GNOT | 30m0s | [g1q646ct…3zqe](/r/g188c5k6v0tmfyevfzj962jkajjqt4ddtml8zw0x/gauntlet:u/g1q646ctzhvn60v392yy4ldq5zyr8q5hnxee3zqe) | Feb 13, 23:31 UTC |
//
// ## The challenge
//
//
//
// Return the input reversed. Runes, not bytes.
//
//
//
// Write `func Solve(in string) string`.
//
// ## How it is graded
//
// Every one of these must match exactly:
//
// ```
// Solve("abc")
// // want "cba"
// ```
//
// ```
// Solve("hello")
// // want "olleh"
// ```
//
// ## Enter
//
// 1. Pick a realm path for your solution, e.g. `gno.land/r/<your-address>/solve1`, and a secret salt.
// 2. Get your hash: `HashFor("<your realm path>", "<salt>")` and [commit it](/r/g188c5k6v0tmfyevfzj962jkajjqt4ddtml8zw0x/gauntlet$help&func=Commit&.send=0ugnot&id=1) with the 0 GNOT bond.
// 3. Deploy your realm (template below), then call its `Submit(1, "<salt>")` within 30m0s.
//
// ```go
// package solve1
//
// import "gno.land/r/g188c5k6v0tmfyevfzj962jkajjqt4ddtml8zw0x/gauntlet"
//
// func Solve(in string) string {
// 	// your code
// 	return in
// }
//
// func Submit(cur realm, id uint64, salt string) {
// 	gauntlet.Reveal(cross(cur), id, salt, Solve)
// }
// ```
//
//
// [Boost the reward](/r/g188c5k6v0tmfyevfzj962jkajjqt4ddtml8zw0x/gauntlet$help&func=Boost&id=1) · [Settle](/r/g188c5k6v0tmfyevfzj962jkajjqt4ddtml8zw0x/gauntlet$help&func=Settle&id=1)
//
// ## Queue
//
// Earlier commits always rank first. A later commit cannot win while an earlier one can still reveal.
//
// | Place | Solver | Committed | Result | Solution |
// |---|---|---|---|---|
// | 1 | [g1jg8mtu…sqf5](/r/g188c5k6v0tmfyevfzj962jkajjqt4ddtml8zw0x/gauntlet:u/g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5) | Feb 13, 23:31 UTC | pending | — |
//
// === challenge, won ===
// # #1 Reverse a string
//
// [Board](/r/g188c5k6v0tmfyevfzj962jkajjqt4ddtml8zw0x/gauntlet) · [Leaderboard](/r/g188c5k6v0tmfyevfzj962jkajjqt4ddtml8zw0x/gauntlet:leaderboard) · [Judges](/r/g188c5k6v0tmfyevfzj962jkajjqt4ddtml8zw0x/gauntlet:judges) · [How to solve](/r/g188c5k6v0tmfyevfzj962jkajjqt4ddtml8zw0x/gauntlet:solve)
//
// > **Won** by [g1jg8mtu…sqf5](/r/g188c5k6v0tmfyevfzj962jkajjqt4ddtml8zw0x/gauntlet:u/g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5) for **3 GNOT**. Winning code: [/r/g188c5k6v0tmfyevfzj962jkajjqt4ddtml8zw0x/solvers/rev1](/r/g188c5k6v0tmfyevfzj962jkajjqt4ddtml8zw0x/solvers/rev1$source)
//
// | Reward | Bond per commit | Reveal window | Posted by | Posted |
// |---|---|---|---|---|
// | 3 GNOT | 0 GNOT | 30m0s | [g1q646ct…3zqe](/r/g188c5k6v0tmfyevfzj962jkajjqt4ddtml8zw0x/gauntlet:u/g1q646ctzhvn60v392yy4ldq5zyr8q5hnxee3zqe) | Feb 13, 23:31 UTC |
//
// ## The challenge
//
//
//
// Return the input reversed. Runes, not bytes.
//
//
//
// Write `func Solve(in string) string`.
//
// ## How it is graded
//
// Every one of these must match exactly:
//
// ```
// Solve("abc")
// // want "cba"
// ```
//
// ```
// Solve("hello")
// // want "olleh"
// ```
//
// ## Queue
//
// Earlier commits always rank first. A later commit cannot win while an earlier one can still reveal.
//
// | Place | Solver | Committed | Result | Solution |
// |---|---|---|---|---|
// | 1 | [g1jg8mtu…sqf5](/r/g188c5k6v0tmfyevfzj962jkajjqt4ddtml8zw0x/gauntlet:u/g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5) | Feb 13, 23:31 UTC | **winner** passed (2/2) | [source](/r/g188c5k6v0tmfyevfzj962jkajjqt4ddtml8zw0x/solvers/rev1$source) |
//
// === leaderboard ===
// # Leaderboard
//
// [Board](/r/g188c5k6v0tmfyevfzj962jkajjqt4ddtml8zw0x/gauntlet) · [Leaderboard](/r/g188c5k6v0tmfyevfzj962jkajjqt4ddtml8zw0x/gauntlet:leaderboard) · [Judges](/r/g188c5k6v0tmfyevfzj962jkajjqt4ddtml8zw0x/gauntlet:judges) · [How to solve](/r/g188c5k6v0tmfyevfzj962jkajjqt4ddtml8zw0x/gauntlet:solve)
//
// | Rank | Solver | Solved | Earned |
// |---|---|---|---|
// | 1 | [g1jg8mtu…sqf5](/r/g188c5k6v0tmfyevfzj962jkajjqt4ddtml8zw0x/gauntlet:u/g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5) | 1 | 3 GNOT |
//
// === profile ===
// # g1jg8mtu…sqf5
//
// [Board](/r/g188c5k6v0tmfyevfzj962jkajjqt4ddtml8zw0x/gauntlet) · [Leaderboard](/r/g188c5k6v0tmfyevfzj962jkajjqt4ddtml8zw0x/gauntlet:leaderboard) · [Judges](/r/g188c5k6v0tmfyevfzj962jkajjqt4ddtml8zw0x/gauntlet:judges) · [How to solve](/r/g188c5k6v0tmfyevfzj962jkajjqt4ddtml8zw0x/gauntlet:solve)
//
// `g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5`
//
// | Solved | Earned | Attempts | Posted | Funded |
// |---|---|---|---|---|
// | 1 | 3 GNOT | 1 | 0 | 0 GNOT |
//
// ## Wins
//
// - [Reverse a string](/r/g188c5k6v0tmfyevfzj962jkajjqt4ddtml8zw0x/gauntlet:c/1) · 3 GNOT
//
// === unknown path ===
// # Not found
//
// [Back to the board](/r/g188c5k6v0tmfyevfzj962jkajjqt4ddtml8zw0x/gauntlet)
