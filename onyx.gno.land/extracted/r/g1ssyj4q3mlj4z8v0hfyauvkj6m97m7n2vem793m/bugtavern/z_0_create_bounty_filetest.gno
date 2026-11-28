// PKGPATH: gno.land/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern/filetests/z_0_create_bounty
package z_0_create_bounty

// SEND: 9500000ugnot

import (
	"strconv"

	"chain"
	"chain/banker"
	"testing"

	"gno.land/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern"
)

var sponsor = address("g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m")
var arbiter = address("g1jg8mtutu9khhfwc07njy9r6ny5riv5p96j5pvwg")

func init(cur realm) {
	testing.SetRealm(testing.NewUserRealm(sponsor))
	testing.SetHeight(1000)
	id := bugtavern.CreateBounty(cross(cur),
		"TavernVault audit", "Audit the vault realm for access control flaws.",
		5000000, 3000000, 1000000, 500000, arbiter, 24600)
	println("bounty id: " + strconv.FormatUint(id, 10))
	// Second simulated send: top the pool up by 500000 ugnot.
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin("ugnot", 500000)))
	bugtavern.TopUpBounty(cross(cur), id)
	tot := bugtavern.GetTotals()
	println("bounties: " + strconv.Itoa(tot.Bounties))
	println("locked: " + strconv.FormatInt(tot.Locked, 10))
	b := bugtavern.GetBounty(id)
	println("pool total: " + strconv.FormatInt(b.PoolTotal(), 10))
	println("pool left: " + strconv.FormatInt(b.PoolLeft(), 10))
	// (In the filetest machine the SEND envelope is context only: no
	// bank funds move on a crossing call, so the realm balance reads
	// 0 here. The real bank-balance proof — GetCoin(realm) ==
	// poolTotal — comes from the gnodev live test, scripts/local-flow.sh.)
	realmAddr := chain.PackageAddress("gno.land/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern")
	println("realm balance: " + strconv.FormatInt(banker.NewReadonlyBanker().GetCoin(realmAddr, "ugnot"), 10))
}

func main() {
	println("done")
}

// Output:
// bounty id: 1
// bounties: 1
// locked: 10000000
// pool total: 10000000
// pool left: 10000000
// realm balance: 0
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
//     "type": "BountyToppedUp",
//     "attrs": [
//       {
//         "key": "bounty_id",
//         "value": "1"
//       },
//       {
//         "key": "amount",
//         "value": "500000"
//       },
//       {
//         "key": "pool_total",
//         "value": "10000000"
//       }
//     ],
//     "pkg_path": "gno.land/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern"
//   }
// ]
