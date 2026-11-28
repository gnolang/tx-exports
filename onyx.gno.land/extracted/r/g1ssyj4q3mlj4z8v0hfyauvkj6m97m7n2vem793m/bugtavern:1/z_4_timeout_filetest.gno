// PKGPATH: gno.land/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern/filetests/z_4_timeout

package z_4_timeout

// SEND: 9500000ugnot

import (
	"strconv"

	"chain"
	"testing"

	"gno.land/p/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/tavernrules"
	"gno.land/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern"
)

var sponsor = address("g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m")
var arbiter = address("g1jg8mtutu9khhfwc07njy9r6ny5riv5p96j5pvwg")
var hunter = address("g1x582angdzrqadgv4382j6y7ju6fj5wll6yuuq4")

const title = "Missing access control on Withdraw"
const poc = "https://example.com/poc"
const salt = "saltsaltsaltsalt"

func init(cur realm) {
	realmAddr := chain.PackageAddress("gno.land/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern")
	// Bounty 1: arbiter stays silent past the review window
	// (revealed at 1010, review deadline 73010) -> sponsor decides.
	testing.SetRealm(testing.NewUserRealm(sponsor))
	testing.SetHeight(1000)
	b1 := bugtavern.CreateBounty(cross(cur),
		"TavernVault audit", "Audit the vault realm for access control flaws.",
		5000000, 3000000, 1000000, 500000, arbiter, 24600)
	testing.IssueCoins(realmAddr, chain.Coins{{Denom: "ugnot", Amount: 9500000}})
	testing.SetOriginSend(chain.NewCoins())

	testing.SetRealm(testing.NewUserRealm(hunter))
	testing.SetHeight(1001)
	hash1 := tavernrules.MakeCommitment(b1, tavernrules.SevCritical, title, poc, salt)
	f1 := bugtavern.CommitFinding(cross(cur), b1, hash1, uint8(tavernrules.SevCritical))
	testing.SetHeight(1010)
	bugtavern.RevealFinding(cross(cur), f1, title, poc, salt)

	testing.SetRealm(testing.NewUserRealm(sponsor))
	testing.SetHeight(73011)
	bugtavern.SponsorVerdict(cross(cur), f1, uint8(tavernrules.VerdictAccept), uint8(tavernrules.SevCritical), "arbiter silent, confirmed", 0)
	g1 := bugtavern.GetFinding(f1)
	println("finding 1 status: " + g1.Status().String())
	println("finding 1 paid: " + strconv.FormatInt(g1.PaidAmount(), 10))

	// Bounty 2: arbiter AND sponsor stay silent past both windows
	// (revealed at 73014, review deadline 145014, claimable after
	// 217014) -> hunter claims the payout directly.
	testing.SetRealm(testing.NewUserRealm(sponsor))
	testing.SetHeight(73012)
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin("ugnot", 9500000)))
	b2 := bugtavern.CreateBounty(cross(cur),
		"TavernVault audit 2", "Second audit round.",
		5000000, 3000000, 1000000, 500000, arbiter, 24600)
	testing.IssueCoins(realmAddr, chain.Coins{{Denom: "ugnot", Amount: 9500000}})
	testing.SetOriginSend(chain.NewCoins())

	testing.SetRealm(testing.NewUserRealm(hunter))
	testing.SetHeight(73013)
	hash2 := tavernrules.MakeCommitment(b2, tavernrules.SevCritical, title, poc, salt)
	f2 := bugtavern.CommitFinding(cross(cur), b2, hash2, uint8(tavernrules.SevCritical))
	testing.SetHeight(73014)
	bugtavern.RevealFinding(cross(cur), f2, title, poc, salt)

	testing.SetHeight(217015)
	bugtavern.ClaimPayout(cross(cur), f2)
	g2 := bugtavern.GetFinding(f2)
	println("finding 2 status: " + g2.Status().String())
	println("finding 2 paid: " + strconv.FormatInt(g2.PaidAmount(), 10))
	tot := bugtavern.GetTotals()
	println("locked: " + strconv.FormatInt(tot.Locked, 10))
	println("paid out: " + strconv.FormatInt(tot.PaidOut, 10))
}

func main() {
	println("done")
}

// Output:
// finding 1 status: Accepted
// finding 1 paid: 5000000
// finding 2 status: Accepted
// finding 2 paid: 5000000
// locked: 9000000
// paid out: 10000000
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
//     "type": "FindingCommitted",
//     "attrs": [
//       {
//         "key": "finding_id",
//         "value": "1"
//       },
//       {
//         "key": "bounty_id",
//         "value": "1"
//       },
//       {
//         "key": "hunter",
//         "value": "g1x582angdzrqadgv4382j6y7ju6fj5wll6yuuq4"
//       },
//       {
//         "key": "severity",
//         "value": "Critical"
//       }
//     ],
//     "pkg_path": "gno.land/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern"
//   },
//   {
//     "type": "FindingRevealed",
//     "attrs": [
//       {
//         "key": "finding_id",
//         "value": "1"
//       },
//       {
//         "key": "bounty_id",
//         "value": "1"
//       },
//       {
//         "key": "hunter",
//         "value": "g1x582angdzrqadgv4382j6y7ju6fj5wll6yuuq4"
//       }
//     ],
//     "pkg_path": "gno.land/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern"
//   },
//   {
//     "type": "VerdictGiven",
//     "attrs": [
//       {
//         "key": "finding_id",
//         "value": "1"
//       },
//       {
//         "key": "bounty_id",
//         "value": "1"
//       },
//       {
//         "key": "verdict",
//         "value": "Accept"
//       },
//       {
//         "key": "by",
//         "value": "g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m"
//       }
//     ],
//     "pkg_path": "gno.land/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern"
//   },
//   {
//     "type": "FindingPaid",
//     "attrs": [
//       {
//         "key": "finding_id",
//         "value": "1"
//       },
//       {
//         "key": "bounty_id",
//         "value": "1"
//       },
//       {
//         "key": "to",
//         "value": "g1x582angdzrqadgv4382j6y7ju6fj5wll6yuuq4"
//       },
//       {
//         "key": "amount",
//         "value": "5000000"
//       },
//       {
//         "key": "how",
//         "value": "accepted"
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
//     "type": "FindingCommitted",
//     "attrs": [
//       {
//         "key": "finding_id",
//         "value": "2"
//       },
//       {
//         "key": "bounty_id",
//         "value": "2"
//       },
//       {
//         "key": "hunter",
//         "value": "g1x582angdzrqadgv4382j6y7ju6fj5wll6yuuq4"
//       },
//       {
//         "key": "severity",
//         "value": "Critical"
//       }
//     ],
//     "pkg_path": "gno.land/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern"
//   },
//   {
//     "type": "FindingRevealed",
//     "attrs": [
//       {
//         "key": "finding_id",
//         "value": "2"
//       },
//       {
//         "key": "bounty_id",
//         "value": "2"
//       },
//       {
//         "key": "hunter",
//         "value": "g1x582angdzrqadgv4382j6y7ju6fj5wll6yuuq4"
//       }
//     ],
//     "pkg_path": "gno.land/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern"
//   },
//   {
//     "type": "FindingPaid",
//     "attrs": [
//       {
//         "key": "finding_id",
//         "value": "2"
//       },
//       {
//         "key": "bounty_id",
//         "value": "2"
//       },
//       {
//         "key": "to",
//         "value": "g1x582angdzrqadgv4382j6y7ju6fj5wll6yuuq4"
//       },
//       {
//         "key": "amount",
//         "value": "5000000"
//       },
//       {
//         "key": "how",
//         "value": "timeout"
//       }
//     ],
//     "pkg_path": "gno.land/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern"
//   }
// ]
