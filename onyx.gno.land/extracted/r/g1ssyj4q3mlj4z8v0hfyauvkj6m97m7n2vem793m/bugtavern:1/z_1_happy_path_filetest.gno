// PKGPATH: gno.land/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern/filetests/z_1_happy_path

package z_1_happy_path

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
	// Design §6.4 happy path: create -> commit -> reveal -> verdict
	// Accept (Critical, 5 GNOT) -> MarkFixed (disclosure).
	testing.SetRealm(testing.NewUserRealm(sponsor))
	testing.SetHeight(1000)
	bountyID := bugtavern.CreateBounty(cross(cur),
		"TavernVault audit", "Audit the vault realm for access control flaws.",
		5000000, 3000000, 1000000, 500000, arbiter, 24600)
	println("bounty id: " + strconv.FormatUint(bountyID, 10))
	// Fund the realm in the filetest machine so the verdict's
	// SendCoins has coins to move (testing.IssueCoins, the same
	// mechanism the disperse filetests use). The // SEND: envelope
	// above is context only and moves no bank funds — see README.
	// No bank balance is asserted here: the real balance proof is
	// the gnodev run (README, day 5).
	testing.IssueCoins(realmAddr, chain.Coins{{Denom: "ugnot", Amount: 9500000}})
	testing.SetOriginSend(chain.NewCoins())

	testing.SetRealm(testing.NewUserRealm(hunter))
	testing.SetHeight(1001)
	hash := tavernrules.MakeCommitment(bountyID, tavernrules.SevCritical, title, poc, salt)
	findingID := bugtavern.CommitFinding(cross(cur), bountyID, hash, uint8(tavernrules.SevCritical))
	println("finding id: " + strconv.FormatUint(findingID, 10))
	println("status after commit: " + bugtavern.GetFinding(findingID).Status().String())

	testing.SetHeight(1002)
	bugtavern.RevealFinding(cross(cur), findingID, title, poc, salt)
	println("status after reveal: " + bugtavern.GetFinding(findingID).Status().String())

	testing.SetRealm(testing.NewUserRealm(arbiter))
	testing.SetHeight(1003)
	bugtavern.Verdict(cross(cur), findingID, uint8(tavernrules.VerdictAccept), uint8(tavernrules.SevCritical), "confirmed, drains vault", 0)
	f := bugtavern.GetFinding(findingID)
	println("status after verdict: " + f.Status().String())
	println("paid: " + strconv.FormatInt(f.PaidAmount(), 10))
	tot := bugtavern.GetTotals()
	println("locked: " + strconv.FormatInt(tot.Locked, 10))
	println("paid out: " + strconv.FormatInt(tot.PaidOut, 10))

	testing.SetRealm(testing.NewUserRealm(sponsor))
	testing.SetHeight(1004)
	bugtavern.MarkFixed(cross(cur), bountyID)
	println("status after mark fixed: " + bugtavern.GetFinding(findingID).Status().String())
}

func main() {
	println("done")
}

// Output:
// bounty id: 1
// finding id: 1
// status after commit: Committed
// status after reveal: Revealed
// status after verdict: Accepted
// paid: 5000000
// locked: 4500000
// paid out: 5000000
// status after mark fixed: Disclosed
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
//   },
//   {
//     "type": "BountyFixed",
//     "attrs": [
//       {
//         "key": "bounty_id",
//         "value": "1"
//       },
//       {
//         "key": "disclosed",
//         "value": "1"
//       }
//     ],
//     "pkg_path": "gno.land/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern"
//   }
// ]
