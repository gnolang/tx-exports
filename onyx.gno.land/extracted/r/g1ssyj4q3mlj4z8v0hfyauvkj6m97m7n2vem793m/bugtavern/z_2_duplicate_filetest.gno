// PKGPATH: gno.land/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern/filetests/z_2_duplicate

package z_2_duplicate

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
var hunter2 = address("g1r4aw43kagaaquhegxw6xr346h9f2qu2ezf0jar")

const title = "Missing access control on Withdraw"
const poc = "https://example.com/poc"
const salt = "saltsaltsaltsalt"
const salt2 = "othersaltothersalt"

func init(cur realm) {
	realmAddr := chain.PackageAddress("gno.land/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern")
	testing.SetRealm(testing.NewUserRealm(sponsor))
	testing.SetHeight(1000)
	bountyID := bugtavern.CreateBounty(cross(cur),
		"TavernVault audit", "Audit the vault realm for access control flaws.",
		5000000, 3000000, 1000000, 500000, arbiter, 24600)
	testing.IssueCoins(realmAddr, chain.Coins{{Denom: "ugnot", Amount: 9500000}})
	testing.SetOriginSend(chain.NewCoins())

	// First hunter reports the bug.
	testing.SetRealm(testing.NewUserRealm(hunter))
	testing.SetHeight(1001)
	hash1 := tavernrules.MakeCommitment(bountyID, tavernrules.SevCritical, title, poc, salt)
	f1 := bugtavern.CommitFinding(cross(cur), bountyID, hash1, uint8(tavernrules.SevCritical))
	testing.SetHeight(1002)
	bugtavern.RevealFinding(cross(cur), f1, title, poc, salt)

	// Second hunter reports the same bug (different salt, so a
	// different commit hash — the same hash would be rejected as a
	// squat by the rules).
	testing.SetRealm(testing.NewUserRealm(hunter2))
	testing.SetHeight(1003)
	hash2 := tavernrules.MakeCommitment(bountyID, tavernrules.SevCritical, title, poc, salt2)
	f2 := bugtavern.CommitFinding(cross(cur), bountyID, hash2, uint8(tavernrules.SevCritical))
	testing.SetHeight(1004)
	bugtavern.RevealFinding(cross(cur), f2, title, poc, salt2)

	// Arbiter accepts the first, marks the second a duplicate of it.
	testing.SetRealm(testing.NewUserRealm(arbiter))
	testing.SetHeight(1005)
	bugtavern.Verdict(cross(cur), f1, uint8(tavernrules.VerdictAccept), uint8(tavernrules.SevCritical), "confirmed, drains vault", 0)
	testing.SetHeight(1006)
	bugtavern.Verdict(cross(cur), f2, uint8(tavernrules.VerdictDuplicate), uint8(tavernrules.SevCritical), "same bug as finding 1", f1)

	g1 := bugtavern.GetFinding(f1)
	g2 := bugtavern.GetFinding(f2)
	println("finding 1 status: " + g1.Status().String())
	println("finding 1 paid: " + strconv.FormatInt(g1.PaidAmount(), 10))
	println("finding 2 status: " + g2.Status().String())
	println("finding 2 paid: " + strconv.FormatInt(g2.PaidAmount(), 10))
	println("finding 2 duplicate of: " + strconv.FormatUint(g2.DuplicateOf(), 10))
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
// finding 2 status: Duplicate
// finding 2 paid: 0
// finding 2 duplicate of: 1
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
//     "type": "FindingCommitted",
//     "attrs": [
//       {
//         "key": "finding_id",
//         "value": "2"
//       },
//       {
//         "key": "bounty_id",
//         "value": "1"
//       },
//       {
//         "key": "hunter",
//         "value": "g1r4aw43kagaaquhegxw6xr346h9f2qu2ezf0jar"
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
//         "value": "1"
//       },
//       {
//         "key": "hunter",
//         "value": "g1r4aw43kagaaquhegxw6xr346h9f2qu2ezf0jar"
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
//     "type": "VerdictGiven",
//     "attrs": [
//       {
//         "key": "finding_id",
//         "value": "2"
//       },
//       {
//         "key": "bounty_id",
//         "value": "1"
//       },
//       {
//         "key": "verdict",
//         "value": "Duplicate"
//       },
//       {
//         "key": "by",
//         "value": "g1jg8mtutu9khhfwc07njy9r6ny5riv5p96j5pvwg"
//       }
//     ],
//     "pkg_path": "gno.land/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern"
//   }
// ]
