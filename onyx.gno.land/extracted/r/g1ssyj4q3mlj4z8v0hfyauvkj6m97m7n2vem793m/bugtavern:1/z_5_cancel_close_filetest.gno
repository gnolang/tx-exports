// PKGPATH: gno.land/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern/filetests/z_5_cancel_close

package z_5_cancel_close

// SEND: 9500000ugnot

import (
	"strconv"

	"chain"
	"testing"

	"gno.land/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern"
)

var sponsor = address("g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m")
var arbiter = address("g1jg8mtutu9khhfwc07njy9r6ny5riv5p96j5pvwg")

func init(cur realm) {
	realmAddr := chain.PackageAddress("gno.land/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern")
	// Bounty 1: sponsor cancels while nothing is in flight — the
	// whole pool is refunded.
	testing.SetRealm(testing.NewUserRealm(sponsor))
	testing.SetHeight(1000)
	b1 := bugtavern.CreateBounty(cross(cur),
		"TavernVault audit", "Audit the vault realm for access control flaws.",
		5000000, 3000000, 1000000, 500000, arbiter, 24600)
	testing.IssueCoins(realmAddr, chain.Coins{{Denom: "ugnot", Amount: 9500000}})
	testing.SetOriginSend(chain.NewCoins())

	testing.SetHeight(1001)
	bugtavern.CancelBounty(cross(cur), b1)
	println("bounty 1 status: " + bugtavern.GetBounty(b1).Status().String())
	tot := bugtavern.GetTotals()
	println("locked after cancel: " + strconv.FormatInt(tot.Locked, 10))
	println("refunded after cancel: " + strconv.FormatInt(tot.Refunded, 10))

	// Bounty 2: sponsor closes after the deadline (created at 1002,
	// deadline 25602) — the remaining pool is refunded.
	testing.SetHeight(1002)
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin("ugnot", 9500000)))
	b2 := bugtavern.CreateBounty(cross(cur),
		"TavernVault audit 2", "Second audit round.",
		5000000, 3000000, 1000000, 500000, arbiter, 24600)
	testing.IssueCoins(realmAddr, chain.Coins{{Denom: "ugnot", Amount: 9500000}})
	testing.SetOriginSend(chain.NewCoins())

	testing.SetHeight(25603)
	bugtavern.CloseBounty(cross(cur), b2)
	println("bounty 2 status: " + bugtavern.GetBounty(b2).Status().String())
	tot = bugtavern.GetTotals()
	println("locked after close: " + strconv.FormatInt(tot.Locked, 10))
	println("refunded after close: " + strconv.FormatInt(tot.Refunded, 10))
}

func main() {
	println("done")
}

// Output:
// bounty 1 status: Cancelled
// locked after cancel: 0
// refunded after cancel: 9500000
// bounty 2 status: Closed
// locked after close: 0
// refunded after close: 19000000
// done

// Events:
// [
//   {
//     "type": "BountyCreated",
//     "attrs": [
//       {
//         "key": "bounty_id",
//         "value": "1"
//       },
//       {
//         "key": "sponsor",
//         "value": "g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m"
//       },
//       {
//         "key": "pool_total",
//         "value": "9500000"
//       }
//     ],
//     "pkg_path": "gno.land/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern"
//   },
//   {
//     "type": "BountyCancelled",
//     "attrs": [
//       {
//         "key": "bounty_id",
//         "value": "1"
//       },
//       {
//         "key": "refund",
//         "value": "9500000"
//       }
//     ],
//     "pkg_path": "gno.land/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern"
//   },
//   {
//     "type": "BountyCreated",
//     "attrs": [
//       {
//         "key": "bounty_id",
//         "value": "2"
//       },
//       {
//         "key": "sponsor",
//         "value": "g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m"
//       },
//       {
//         "key": "pool_total",
//         "value": "9500000"
//       }
//     ],
//     "pkg_path": "gno.land/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern"
//   },
//   {
//     "type": "BountyClosed",
//     "attrs": [
//       {
//         "key": "bounty_id",
//         "value": "2"
//       },
//       {
//         "key": "refund",
//         "value": "9500000"
//       }
//     ],
//     "pkg_path": "gno.land/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern"
//   }
// ]
