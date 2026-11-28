// PKGPATH: gno.land/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern/filetests/z_3_dispute

package z_3_dispute

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
	testing.SetRealm(testing.NewUserRealm(sponsor))
	testing.SetHeight(1000)
	bountyID := bugtavern.CreateBounty(cross(cur),
		"TavernVault audit", "Audit the vault realm for access control flaws.",
		5000000, 3000000, 1000000, 500000, arbiter, 24600)
	testing.IssueCoins(realmAddr, chain.Coins{{Denom: "ugnot", Amount: 9500000}})
	testing.SetOriginSend(chain.NewCoins())

	testing.SetRealm(testing.NewUserRealm(hunter))
	testing.SetHeight(1001)
	hash := tavernrules.MakeCommitment(bountyID, tavernrules.SevCritical, title, poc, salt)
	findingID := bugtavern.CommitFinding(cross(cur), bountyID, hash, uint8(tavernrules.SevCritical))
	testing.SetHeight(1002)
	bugtavern.RevealFinding(cross(cur), findingID, title, poc, salt)

	// Arbiter rejects; hunter disputes inside the window; arbiter
	// re-verdicts Accept (re-verdict window: disputedAt + 72000).
	testing.SetRealm(testing.NewUserRealm(arbiter))
	testing.SetHeight(1003)
	bugtavern.Verdict(cross(cur), findingID, uint8(tavernrules.VerdictReject), uint8(tavernrules.SevCritical), "not reproducible", 0)
	println("status after reject: " + bugtavern.GetFinding(findingID).Status().String())

	testing.SetRealm(testing.NewUserRealm(hunter))
	testing.SetHeight(1004)
	bugtavern.DisputeFinding(cross(cur), findingID, "repro steps attached in PoC")
	println("status after dispute: " + bugtavern.GetFinding(findingID).Status().String())

	testing.SetRealm(testing.NewUserRealm(arbiter))
	testing.SetHeight(1005)
	bugtavern.Verdict(cross(cur), findingID, uint8(tavernrules.VerdictAccept), uint8(tavernrules.SevCritical), "reproduced on second look", 0)
	f := bugtavern.GetFinding(findingID)
	println("status after re-verdict: " + f.Status().String())
	println("paid: " + strconv.FormatInt(f.PaidAmount(), 10))
	tot := bugtavern.GetTotals()
	println("locked: " + strconv.FormatInt(tot.Locked, 10))
	println("paid out: " + strconv.FormatInt(tot.PaidOut, 10))
}

func main() {
	println("done")
}

// Output:
// status after reject: Rejected
// status after dispute: Disputed
// status after re-verdict: Accepted
// paid: 5000000
// locked: 4500000
// paid out: 5000000
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
//         "value": "Reject"
//       },
//       {
//         "key": "by",
//         "value": "g1jg8mtutu9khhfwc07njy9r6ny5riv5p96j5pvwg"
//       }
//     ],
//     "pkg_path": "gno.land/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern"
//   },
//   {
//     "type": "FindingDisputed",
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
//         "value": "g1jg8mtutu9khhfwc07njy9r6ny5riv5p96j5pvwg"
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
//   }
// ]
