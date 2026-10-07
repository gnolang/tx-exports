// PKGPATH: gno.land/r/demo/main

package main

import (
	"chain"
	"crypto/sha256"
	"encoding/hex"
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/r/samcrew/connect4"
)

func commit(passphrase string) string {
	h := sha256.Sum256([]byte(passphrase))
	return hex.EncodeToString(h[:])
}

func main(cur realm) {
	alice := testutils.TestAddress("alice")
	bob := testutils.TestAddress("bob")
	carol := testutils.TestAddress("carol")
	c4 := chain.PackageAddress("gno.land/r/samcrew/connect4")
	stake := chain.Coins{{"ugnot", 5_000_000}}

	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(stake)
	testing.IssueCoins(c4, stake)
	g1 := connect4.Offer(cross(cur), "", 15, commit("alice four random words"), 100_000)

	testing.SetRealm(testing.NewUserRealm(carol))
	testing.SetOriginSend(stake)
	testing.IssueCoins(c4, stake)
	connect4.Offer(cross(cur), bob, 5, commit("carol four random words"), 100_000)

	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(stake)
	testing.IssueCoins(c4, stake)
	connect4.Accept(cross(cur), g1, commit("acceptor seed"))

	// Render runs as the realm itself, as it does under gnoweb.
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/samcrew/connect4"))
	println(connect4.Render(""))
	println("-----")
	println(connect4.Render("game/1"))
	println("-----")
	println(connect4.Render("game/2"))
	println("-----")
	println(connect4.Render("new?stake=12.5&validFor=10&opponent=&commitment=5fb8d3d0c4f3b0fe7ab6ab1f7eda42c6e2de0c3c1d4a6c5e3d0f2f5d0e4f5a6b"))
	println("-----")
	println(connect4.Render("game/x"))
	println("-----")
	println(connect4.Render("game/99999999999"))
}

// Output:
// # Connect 4
//
// Both players stake the same amount; the winner takes the pot minus the house fee shown on each offer (0.1 GNOT for new offers). 90s per move: run out and you forfeit. If the first mover never moves, both stakes are refunded.
//
// **[Post an offer](/r/samcrew/connect4:new)** · open a game below to play it
//
// ## Open offers
//
// | Game | Stake | Fee | Creator | For | Expires in | |
// |---|---|---|---|---|---|---|
// | [#2](/r/samcrew/connect4:game/2) | 5 GNOT | 0.1 GNOT | g1vdshymmvta047h6lta047h6lta047h6l2asz94 | g1vfhkyh6lta047h6lta047h6lta047h6l03vdhu | 5m0s | [Accept](/r/samcrew/connect4$help&func=Accept&.send=5000000ugnot&id=2&seedCommitment=) |
//
// ## Live games
//
// | Game | Pot | Turn | Time left |
// |---|---|---|---|
// | [#1](/r/samcrew/connect4:game/1) | 10 GNOT | g1v9kxjcm9ta047h6lta047h6lta047h6lzd40gh (reveal) | 1m30s |
//
// ## Most games won
//
// No finished games yet.
//
// ## Most gnot won
//
// No finished games yet.
//
//
// -----
// # Game #1 — playing
//
// [← Lobby](/r/samcrew/connect4)
//
// 🔴 g1v9kxjcm9ta047h6lta047h6lta047h6lzd40gh
// 🟡 g1vfhkyh6lta047h6lta047h6lta047h6l03vdhu
// Stake: 5 GNOT each · fee 0.1 GNOT
//
// ![board: column 1: empty empty empty empty empty empty; column 2: empty empty empty empty empty empty; column 3: empty empty empty empty empty empty; column 4: empty empty empty empty empty empty; column 5: empty empty empty empty empty empty; column 6: empty empty empty empty empty empty; column 7: empty empty empty empty empty empty;](data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHdpZHRoPSIzMzYiIGhlaWdodD0iMzA4IiB2aWV3Qm94PSIwIDAgMzM2IDMwOCI+PHJlY3QgeD0iMCIgeT0iMCIgd2lkdGg9IjQ4IiBoZWlnaHQ9IjMwOCIgcng9IjAiIHJ5PSIwIiBmaWxsPSIjMTU2NWMwIiBjbGFzcz0iY29sIi8+PHRleHQgeD0iMjAiIHk9IjE1IiBkeD0iMCIgZHk9IjAiIHJvdGF0ZT0iIiBmaWxsPSIjZmZmZmZmIiA+MTwvdGV4dD48Y2lyY2xlIGN4PSIyNCIgY3k9IjI4NCIgcj0iMTkiIGZpbGw9IiNmZmZmZmYiIC8+PGNpcmNsZSBjeD0iMjQiIGN5PSIyMzYiIHI9IjE5IiBmaWxsPSIjZmZmZmZmIiAvPjxjaXJjbGUgY3g9IjI0IiBjeT0iMTg4IiByPSIxOSIgZmlsbD0iI2ZmZmZmZiIgLz48Y2lyY2xlIGN4PSIyNCIgY3k9IjE0MCIgcj0iMTkiIGZpbGw9IiNmZmZmZmYiIC8+PGNpcmNsZSBjeD0iMjQiIGN5PSI5MiIgcj0iMTkiIGZpbGw9IiNmZmZmZmYiIC8+PGNpcmNsZSBjeD0iMjQiIGN5PSI0NCIgcj0iMTkiIGZpbGw9IiNmZmZmZmYiIC8+PHJlY3QgeD0iNDgiIHk9IjAiIHdpZHRoPSI0OCIgaGVpZ2h0PSIzMDgiIHJ4PSIwIiByeT0iMCIgZmlsbD0iIzE1NjVjMCIgY2xhc3M9ImNvbCIvPjx0ZXh0IHg9IjY4IiB5PSIxNSIgZHg9IjAiIGR5PSIwIiByb3RhdGU9IiIgZmlsbD0iI2ZmZmZmZiIgPjI8L3RleHQ+PGNpcmNsZSBjeD0iNzIiIGN5PSIyODQiIHI9IjE5IiBmaWxsPSIjZmZmZmZmIiAvPjxjaXJjbGUgY3g9IjcyIiBjeT0iMjM2IiByPSIxOSIgZmlsbD0iI2ZmZmZmZiIgLz48Y2lyY2xlIGN4PSI3MiIgY3k9IjE4OCIgcj0iMTkiIGZpbGw9IiNmZmZmZmYiIC8+PGNpcmNsZSBjeD0iNzIiIGN5PSIxNDAiIHI9IjE5IiBmaWxsPSIjZmZmZmZmIiAvPjxjaXJjbGUgY3g9IjcyIiBjeT0iOTIiIHI9IjE5IiBmaWxsPSIjZmZmZmZmIiAvPjxjaXJjbGUgY3g9IjcyIiBjeT0iNDQiIHI9IjE5IiBmaWxsPSIjZmZmZmZmIiAvPjxyZWN0IHg9Ijk2IiB5PSIwIiB3aWR0aD0iNDgiIGhlaWdodD0iMzA4IiByeD0iMCIgcnk9IjAiIGZpbGw9IiMxNTY1YzAiIGNsYXNzPSJjb2wiLz48dGV4dCB4PSIxMTYiIHk9IjE1IiBkeD0iMCIgZHk9IjAiIHJvdGF0ZT0iIiBmaWxsPSIjZmZmZmZmIiA+MzwvdGV4dD48Y2lyY2xlIGN4PSIxMjAiIGN5PSIyODQiIHI9IjE5IiBmaWxsPSIjZmZmZmZmIiAvPjxjaXJjbGUgY3g9IjEyMCIgY3k9IjIzNiIgcj0iMTkiIGZpbGw9IiNmZmZmZmYiIC8+PGNpcmNsZSBjeD0iMTIwIiBjeT0iMTg4IiByPSIxOSIgZmlsbD0iI2ZmZmZmZiIgLz48Y2lyY2xlIGN4PSIxMjAiIGN5PSIxNDAiIHI9IjE5IiBmaWxsPSIjZmZmZmZmIiAvPjxjaXJjbGUgY3g9IjEyMCIgY3k9IjkyIiByPSIxOSIgZmlsbD0iI2ZmZmZmZiIgLz48Y2lyY2xlIGN4PSIxMjAiIGN5PSI0NCIgcj0iMTkiIGZpbGw9IiNmZmZmZmYiIC8+PHJlY3QgeD0iMTQ0IiB5PSIwIiB3aWR0aD0iNDgiIGhlaWdodD0iMzA4IiByeD0iMCIgcnk9IjAiIGZpbGw9IiMxNTY1YzAiIGNsYXNzPSJjb2wiLz48dGV4dCB4PSIxNjQiIHk9IjE1IiBkeD0iMCIgZHk9IjAiIHJvdGF0ZT0iIiBmaWxsPSIjZmZmZmZmIiA+NDwvdGV4dD48Y2lyY2xlIGN4PSIxNjgiIGN5PSIyODQiIHI9IjE5IiBmaWxsPSIjZmZmZmZmIiAvPjxjaXJjbGUgY3g9IjE2OCIgY3k9IjIzNiIgcj0iMTkiIGZpbGw9IiNmZmZmZmYiIC8+PGNpcmNsZSBjeD0iMTY4IiBjeT0iMTg4IiByPSIxOSIgZmlsbD0iI2ZmZmZmZiIgLz48Y2lyY2xlIGN4PSIxNjgiIGN5PSIxNDAiIHI9IjE5IiBmaWxsPSIjZmZmZmZmIiAvPjxjaXJjbGUgY3g9IjE2OCIgY3k9IjkyIiByPSIxOSIgZmlsbD0iI2ZmZmZmZiIgLz48Y2lyY2xlIGN4PSIxNjgiIGN5PSI0NCIgcj0iMTkiIGZpbGw9IiNmZmZmZmYiIC8+PHJlY3QgeD0iMTkyIiB5PSIwIiB3aWR0aD0iNDgiIGhlaWdodD0iMzA4IiByeD0iMCIgcnk9IjAiIGZpbGw9IiMxNTY1YzAiIGNsYXNzPSJjb2wiLz48dGV4dCB4PSIyMTIiIHk9IjE1IiBkeD0iMCIgZHk9IjAiIHJvdGF0ZT0iIiBmaWxsPSIjZmZmZmZmIiA+NTwvdGV4dD48Y2lyY2xlIGN4PSIyMTYiIGN5PSIyODQiIHI9IjE5IiBmaWxsPSIjZmZmZmZmIiAvPjxjaXJjbGUgY3g9IjIxNiIgY3k9IjIzNiIgcj0iMTkiIGZpbGw9IiNmZmZmZmYiIC8+PGNpcmNsZSBjeD0iMjE2IiBjeT0iMTg4IiByPSIxOSIgZmlsbD0iI2ZmZmZmZiIgLz48Y2lyY2xlIGN4PSIyMTYiIGN5PSIxNDAiIHI9IjE5IiBmaWxsPSIjZmZmZmZmIiAvPjxjaXJjbGUgY3g9IjIxNiIgY3k9IjkyIiByPSIxOSIgZmlsbD0iI2ZmZmZmZiIgLz48Y2lyY2xlIGN4PSIyMTYiIGN5PSI0NCIgcj0iMTkiIGZpbGw9IiNmZmZmZmYiIC8+PHJlY3QgeD0iMjQwIiB5PSIwIiB3aWR0aD0iNDgiIGhlaWdodD0iMzA4IiByeD0iMCIgcnk9IjAiIGZpbGw9IiMxNTY1YzAiIGNsYXNzPSJjb2wiLz48dGV4dCB4PSIyNjAiIHk9IjE1IiBkeD0iMCIgZHk9IjAiIHJvdGF0ZT0iIiBmaWxsPSIjZmZmZmZmIiA+NjwvdGV4dD48Y2lyY2xlIGN4PSIyNjQiIGN5PSIyODQiIHI9IjE5IiBmaWxsPSIjZmZmZmZmIiAvPjxjaXJjbGUgY3g9IjI2NCIgY3k9IjIzNiIgcj0iMTkiIGZpbGw9IiNmZmZmZmYiIC8+PGNpcmNsZSBjeD0iMjY0IiBjeT0iMTg4IiByPSIxOSIgZmlsbD0iI2ZmZmZmZiIgLz48Y2lyY2xlIGN4PSIyNjQiIGN5PSIxNDAiIHI9IjE5IiBmaWxsPSIjZmZmZmZmIiAvPjxjaXJjbGUgY3g9IjI2NCIgY3k9IjkyIiByPSIxOSIgZmlsbD0iI2ZmZmZmZiIgLz48Y2lyY2xlIGN4PSIyNjQiIGN5PSI0NCIgcj0iMTkiIGZpbGw9IiNmZmZmZmYiIC8+PHJlY3QgeD0iMjg4IiB5PSIwIiB3aWR0aD0iNDgiIGhlaWdodD0iMzA4IiByeD0iMCIgcnk9IjAiIGZpbGw9IiMxNTY1YzAiIGNsYXNzPSJjb2wiLz48dGV4dCB4PSIzMDgiIHk9IjE1IiBkeD0iMCIgZHk9IjAiIHJvdGF0ZT0iIiBmaWxsPSIjZmZmZmZmIiA+NzwvdGV4dD48Y2lyY2xlIGN4PSIzMTIiIGN5PSIyODQiIHI9IjE5IiBmaWxsPSIjZmZmZmZmIiAvPjxjaXJjbGUgY3g9IjMxMiIgY3k9IjIzNiIgcj0iMTkiIGZpbGw9IiNmZmZmZmYiIC8+PGNpcmNsZSBjeD0iMzEyIiBjeT0iMTg4IiByPSIxOSIgZmlsbD0iI2ZmZmZmZiIgLz48Y2lyY2xlIGN4PSIzMTIiIGN5PSIxNDAiIHI9IjE5IiBmaWxsPSIjZmZmZmZmIiAvPjxjaXJjbGUgY3g9IjMxMiIgY3k9IjkyIiByPSIxOSIgZmlsbD0iI2ZmZmZmZiIgLz48Y2lyY2xlIGN4PSIzMTIiIGN5PSI0NCIgcj0iMTkiIGZpbGw9IiNmZmZmZmYiIC8+PC9zdmc+)
//
// Waiting for the creator to reveal the passphrase.
//
// Time left: 1m30s
//
// **[Reveal](/r/samcrew/connect4$help&func=Reveal&id=1&passphrase=)** (creator)
//
// [Resign](/r/samcrew/connect4$help&func=Resign&id=1)
//
// -----
// # Game #2 — open
//
// [← Lobby](/r/samcrew/connect4)
//
// 🔴 g1vdshymmvta047h6lta047h6lta047h6l2asz94
// 🟡 waiting for opponent
// Stake: 5 GNOT each · fee 0.1 GNOT
//
// ![board: column 1: empty empty empty empty empty empty; column 2: empty empty empty empty empty empty; column 3: empty empty empty empty empty empty; column 4: empty empty empty empty empty empty; column 5: empty empty empty empty empty empty; column 6: empty empty empty empty empty empty; column 7: empty empty empty empty empty empty;](data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHdpZHRoPSIzMzYiIGhlaWdodD0iMzA4IiB2aWV3Qm94PSIwIDAgMzM2IDMwOCI+PHJlY3QgeD0iMCIgeT0iMCIgd2lkdGg9IjQ4IiBoZWlnaHQ9IjMwOCIgcng9IjAiIHJ5PSIwIiBmaWxsPSIjMTU2NWMwIiBjbGFzcz0iY29sIi8+PHRleHQgeD0iMjAiIHk9IjE1IiBkeD0iMCIgZHk9IjAiIHJvdGF0ZT0iIiBmaWxsPSIjZmZmZmZmIiA+MTwvdGV4dD48Y2lyY2xlIGN4PSIyNCIgY3k9IjI4NCIgcj0iMTkiIGZpbGw9IiNmZmZmZmYiIC8+PGNpcmNsZSBjeD0iMjQiIGN5PSIyMzYiIHI9IjE5IiBmaWxsPSIjZmZmZmZmIiAvPjxjaXJjbGUgY3g9IjI0IiBjeT0iMTg4IiByPSIxOSIgZmlsbD0iI2ZmZmZmZiIgLz48Y2lyY2xlIGN4PSIyNCIgY3k9IjE0MCIgcj0iMTkiIGZpbGw9IiNmZmZmZmYiIC8+PGNpcmNsZSBjeD0iMjQiIGN5PSI5MiIgcj0iMTkiIGZpbGw9IiNmZmZmZmYiIC8+PGNpcmNsZSBjeD0iMjQiIGN5PSI0NCIgcj0iMTkiIGZpbGw9IiNmZmZmZmYiIC8+PHJlY3QgeD0iNDgiIHk9IjAiIHdpZHRoPSI0OCIgaGVpZ2h0PSIzMDgiIHJ4PSIwIiByeT0iMCIgZmlsbD0iIzE1NjVjMCIgY2xhc3M9ImNvbCIvPjx0ZXh0IHg9IjY4IiB5PSIxNSIgZHg9IjAiIGR5PSIwIiByb3RhdGU9IiIgZmlsbD0iI2ZmZmZmZiIgPjI8L3RleHQ+PGNpcmNsZSBjeD0iNzIiIGN5PSIyODQiIHI9IjE5IiBmaWxsPSIjZmZmZmZmIiAvPjxjaXJjbGUgY3g9IjcyIiBjeT0iMjM2IiByPSIxOSIgZmlsbD0iI2ZmZmZmZiIgLz48Y2lyY2xlIGN4PSI3MiIgY3k9IjE4OCIgcj0iMTkiIGZpbGw9IiNmZmZmZmYiIC8+PGNpcmNsZSBjeD0iNzIiIGN5PSIxNDAiIHI9IjE5IiBmaWxsPSIjZmZmZmZmIiAvPjxjaXJjbGUgY3g9IjcyIiBjeT0iOTIiIHI9IjE5IiBmaWxsPSIjZmZmZmZmIiAvPjxjaXJjbGUgY3g9IjcyIiBjeT0iNDQiIHI9IjE5IiBmaWxsPSIjZmZmZmZmIiAvPjxyZWN0IHg9Ijk2IiB5PSIwIiB3aWR0aD0iNDgiIGhlaWdodD0iMzA4IiByeD0iMCIgcnk9IjAiIGZpbGw9IiMxNTY1YzAiIGNsYXNzPSJjb2wiLz48dGV4dCB4PSIxMTYiIHk9IjE1IiBkeD0iMCIgZHk9IjAiIHJvdGF0ZT0iIiBmaWxsPSIjZmZmZmZmIiA+MzwvdGV4dD48Y2lyY2xlIGN4PSIxMjAiIGN5PSIyODQiIHI9IjE5IiBmaWxsPSIjZmZmZmZmIiAvPjxjaXJjbGUgY3g9IjEyMCIgY3k9IjIzNiIgcj0iMTkiIGZpbGw9IiNmZmZmZmYiIC8+PGNpcmNsZSBjeD0iMTIwIiBjeT0iMTg4IiByPSIxOSIgZmlsbD0iI2ZmZmZmZiIgLz48Y2lyY2xlIGN4PSIxMjAiIGN5PSIxNDAiIHI9IjE5IiBmaWxsPSIjZmZmZmZmIiAvPjxjaXJjbGUgY3g9IjEyMCIgY3k9IjkyIiByPSIxOSIgZmlsbD0iI2ZmZmZmZiIgLz48Y2lyY2xlIGN4PSIxMjAiIGN5PSI0NCIgcj0iMTkiIGZpbGw9IiNmZmZmZmYiIC8+PHJlY3QgeD0iMTQ0IiB5PSIwIiB3aWR0aD0iNDgiIGhlaWdodD0iMzA4IiByeD0iMCIgcnk9IjAiIGZpbGw9IiMxNTY1YzAiIGNsYXNzPSJjb2wiLz48dGV4dCB4PSIxNjQiIHk9IjE1IiBkeD0iMCIgZHk9IjAiIHJvdGF0ZT0iIiBmaWxsPSIjZmZmZmZmIiA+NDwvdGV4dD48Y2lyY2xlIGN4PSIxNjgiIGN5PSIyODQiIHI9IjE5IiBmaWxsPSIjZmZmZmZmIiAvPjxjaXJjbGUgY3g9IjE2OCIgY3k9IjIzNiIgcj0iMTkiIGZpbGw9IiNmZmZmZmYiIC8+PGNpcmNsZSBjeD0iMTY4IiBjeT0iMTg4IiByPSIxOSIgZmlsbD0iI2ZmZmZmZiIgLz48Y2lyY2xlIGN4PSIxNjgiIGN5PSIxNDAiIHI9IjE5IiBmaWxsPSIjZmZmZmZmIiAvPjxjaXJjbGUgY3g9IjE2OCIgY3k9IjkyIiByPSIxOSIgZmlsbD0iI2ZmZmZmZiIgLz48Y2lyY2xlIGN4PSIxNjgiIGN5PSI0NCIgcj0iMTkiIGZpbGw9IiNmZmZmZmYiIC8+PHJlY3QgeD0iMTkyIiB5PSIwIiB3aWR0aD0iNDgiIGhlaWdodD0iMzA4IiByeD0iMCIgcnk9IjAiIGZpbGw9IiMxNTY1YzAiIGNsYXNzPSJjb2wiLz48dGV4dCB4PSIyMTIiIHk9IjE1IiBkeD0iMCIgZHk9IjAiIHJvdGF0ZT0iIiBmaWxsPSIjZmZmZmZmIiA+NTwvdGV4dD48Y2lyY2xlIGN4PSIyMTYiIGN5PSIyODQiIHI9IjE5IiBmaWxsPSIjZmZmZmZmIiAvPjxjaXJjbGUgY3g9IjIxNiIgY3k9IjIzNiIgcj0iMTkiIGZpbGw9IiNmZmZmZmYiIC8+PGNpcmNsZSBjeD0iMjE2IiBjeT0iMTg4IiByPSIxOSIgZmlsbD0iI2ZmZmZmZiIgLz48Y2lyY2xlIGN4PSIyMTYiIGN5PSIxNDAiIHI9IjE5IiBmaWxsPSIjZmZmZmZmIiAvPjxjaXJjbGUgY3g9IjIxNiIgY3k9IjkyIiByPSIxOSIgZmlsbD0iI2ZmZmZmZiIgLz48Y2lyY2xlIGN4PSIyMTYiIGN5PSI0NCIgcj0iMTkiIGZpbGw9IiNmZmZmZmYiIC8+PHJlY3QgeD0iMjQwIiB5PSIwIiB3aWR0aD0iNDgiIGhlaWdodD0iMzA4IiByeD0iMCIgcnk9IjAiIGZpbGw9IiMxNTY1YzAiIGNsYXNzPSJjb2wiLz48dGV4dCB4PSIyNjAiIHk9IjE1IiBkeD0iMCIgZHk9IjAiIHJvdGF0ZT0iIiBmaWxsPSIjZmZmZmZmIiA+NjwvdGV4dD48Y2lyY2xlIGN4PSIyNjQiIGN5PSIyODQiIHI9IjE5IiBmaWxsPSIjZmZmZmZmIiAvPjxjaXJjbGUgY3g9IjI2NCIgY3k9IjIzNiIgcj0iMTkiIGZpbGw9IiNmZmZmZmYiIC8+PGNpcmNsZSBjeD0iMjY0IiBjeT0iMTg4IiByPSIxOSIgZmlsbD0iI2ZmZmZmZiIgLz48Y2lyY2xlIGN4PSIyNjQiIGN5PSIxNDAiIHI9IjE5IiBmaWxsPSIjZmZmZmZmIiAvPjxjaXJjbGUgY3g9IjI2NCIgY3k9IjkyIiByPSIxOSIgZmlsbD0iI2ZmZmZmZiIgLz48Y2lyY2xlIGN4PSIyNjQiIGN5PSI0NCIgcj0iMTkiIGZpbGw9IiNmZmZmZmYiIC8+PHJlY3QgeD0iMjg4IiB5PSIwIiB3aWR0aD0iNDgiIGhlaWdodD0iMzA4IiByeD0iMCIgcnk9IjAiIGZpbGw9IiMxNTY1YzAiIGNsYXNzPSJjb2wiLz48dGV4dCB4PSIzMDgiIHk9IjE1IiBkeD0iMCIgZHk9IjAiIHJvdGF0ZT0iIiBmaWxsPSIjZmZmZmZmIiA+NzwvdGV4dD48Y2lyY2xlIGN4PSIzMTIiIGN5PSIyODQiIHI9IjE5IiBmaWxsPSIjZmZmZmZmIiAvPjxjaXJjbGUgY3g9IjMxMiIgY3k9IjIzNiIgcj0iMTkiIGZpbGw9IiNmZmZmZmYiIC8+PGNpcmNsZSBjeD0iMzEyIiBjeT0iMTg4IiByPSIxOSIgZmlsbD0iI2ZmZmZmZiIgLz48Y2lyY2xlIGN4PSIzMTIiIGN5PSIxNDAiIHI9IjE5IiBmaWxsPSIjZmZmZmZmIiAvPjxjaXJjbGUgY3g9IjMxMiIgY3k9IjkyIiByPSIxOSIgZmlsbD0iI2ZmZmZmZiIgLz48Y2lyY2xlIGN4PSIzMTIiIGN5PSI0NCIgcj0iMTkiIGZpbGw9IiNmZmZmZmYiIC8+PC9zdmc+)
//
// Open offer for g1vfhkyh6lta047h6lta047h6lta047h6l03vdhu, expires in 5m0s.
//
// **[Accept for 5 GNOT](/r/samcrew/connect4$help&func=Accept&.send=5000000ugnot&id=2&seedCommitment=)** with the sha256 of a fresh random seed (`openssl rand -hex 32`). Keep the seed: you reveal it after the creator, within 90s, or forfeit.
//
// [Cancel offer](/r/samcrew/connect4$help&func=Cancel&id=2) (creator)
//
// -----
// # Post an offer
//
// [← Lobby](/r/samcrew/connect4)
//
// Generate a fresh random passphrase for every offer and keep it: once someone accepts you have 90s to reveal it, or you forfeit. A guessable one lets an opponent work out who moves first. Paste only its sha256 below, never the passphrase itself:
//
//     pass=$(openssl rand -hex 32); echo "$pass"
//     printf %s "$pass" | shasum -a 256
//
// <gno-form path="new">
// <gno-input name="stake" type="text" placeholder="Stake in GNOT, e.g. 10 (min 1)" />
// <gno-input name="validFor" type="number" placeholder="Minutes the offer stays open, 1-60 (default 15)" />
// <gno-input name="opponent" type="text" placeholder="Opponent address (optional, leave empty for anyone)" />
// <gno-input name="commitment" type="text" placeholder="sha256 of your passphrase (64 hex chars)" />
// </gno-form>
//
// ## Ready
//
// Stake 12.5 GNOT, open to anyone for 10 min, house fee at most 0.1 GNOT, commitment `5fb8d3d0c4f3b0fe7ab6ab1f7eda42c6e2de0c3c1d4a6c5e3d0f2f5d0e4f5a6b`. Check it is the sha256 of your own passphrase before signing.
//
// **[Post offer for 12.5 GNOT](/r/samcrew/connect4$help&func=Offer&.send=12500000ugnot&commitment=5fb8d3d0c4f3b0fe7ab6ab1f7eda42c6e2de0c3c1d4a6c5e3d0f2f5d0e4f5a6b&maxFee=100000&opponent=&validFor=10)**
//
// -----
// # Not found
//
// -----
// # Not found
