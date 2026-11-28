// PKGPATH: gno.land/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern/filetests/z_6_no_double_payout

package z_6_no_double_payout

// SEND: 9500000ugnot

import (
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

	// First Accept pays 5 GNOT. The second Accept must panic: the
	// finding is already in a final state, so no second payout can
	// ever be built (design §7 T2, TestNoDoublePayout).
	testing.SetRealm(testing.NewUserRealm(arbiter))
	testing.SetHeight(1003)
	bugtavern.Verdict(cross(cur), findingID, uint8(tavernrules.VerdictAccept), uint8(tavernrules.SevCritical), "confirmed", 0)
	testing.SetHeight(1004)
	bugtavern.Verdict(cross(cur), findingID, uint8(tavernrules.VerdictAccept), uint8(tavernrules.SevCritical), "confirmed again", 0)
}

func main() {
	println("done")
}

// Error:
// verdict requires a Revealed or Disputed finding
