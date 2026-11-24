// PKGPATH: gno.land/r/nym-ololade001/guildhall/v1/filetests/z_happy_path_filetest

package z_happy_path_filetest

import (
	"testing"

	"chain"

	"gno.land/p/nt/testutils/v0"
	"gno.land/r/nym-ololade001/guildhall/v1"
)

var (
	poster = testutils.TestAddress("poster")
	worker = testutils.TestAddress("worker")
)

func realmAddr() address {
	return chain.PackageAddress("gno.land/r/nym-ololade001/guildhall/v1")
}

func ugnot(amt int64) chain.Coins {
	return chain.NewCoins(chain.NewCoin("ugnot", amt))
}

func init(cur realm) {
	testing.SetHeight(1000)
	testing.IssueCoins(realmAddr(), ugnot(5000000))
	testing.SetRealm(testing.NewUserRealm(poster))
	testing.SetOriginSend(ugnot(5000000))
	id := guildhall.Post(cross(cur), "Write a haiku", "three lines about gno", 600, 1200, 20000)
	println("posted", id)
}

func main(cur realm) {
	testing.SetHeight(1100)
	testing.SetOriginSend(nil)
	testing.SetRealm(testing.NewUserRealm(worker))
	guildhall.Claim(cross(cur), 1)
	guildhall.Submit(cross(cur), 1, "https://example.com/haiku", "done")

	testing.SetRealm(testing.NewUserRealm(poster))
	guildhall.Accept(cross(cur), 1)
	println(guildhall.Render("q/1"))
}

// Output:
// posted 1
// # Write a haiku
//
// - **Status:** paid
// - **Reward:** 5 GNOT
// - **Poster:** [g1wphhxar9wf047h6lta047h6lta047h6l054qau](/r/nym-ololade001/guildhall/v1:u/g1wphhxar9wf047h6lta047h6lta047h6l054qau)
// - **Worker:** [g1wahhy6m9wf047h6lta047h6lta047h6ltyyhl8](/r/nym-ololade001/guildhall/v1:u/g1wahhy6m9wf047h6lta047h6lta047h6ltyyhl8)
// - **Lease:** 600 blocks
// - **Review window:** 1200 blocks
// - **Deadline:** block 20000
// - **Proof:** [https://example\.com/haiku](https://example.com/haiku)
// - **Note:** done
//
// ## Spec
//
//
// three lines about gno
//
//
//
// ## History
//
// - block 1000 — `g1wphhxar9wf047h6lta047h6lta047h6l054qau` posted
// - block 1100 — `g1wahhy6m9wf047h6lta047h6lta047h6ltyyhl8` claimed
// - block 1100 — `g1wahhy6m9wf047h6lta047h6lta047h6ltyyhl8` submitted — https://example\.com/haiku
// - block 1100 — `g1wphhxar9wf047h6lta047h6lta047h6l054qau` accepted
//
// [Back to the board](/r/nym-ololade001/guildhall/v1)
