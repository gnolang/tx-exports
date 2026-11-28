// PKGPATH: gno.land/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern/filetests/z_7_require_no_coins

package z_7_require_no_coins

// SEND: 9500000ugnot

import (
	"chain"
	"testing"

	"gno.land/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern"
)

var sponsor = address("g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m")
var hunter = address("g1x582angdzrqadgv4382j6y7ju6fj5wll6yuuq4")
var arbiter = address("g1jg8mtutu9khhfwc07njy9r6ny5riv5p96j5pvwg")

func init(cur realm) {
	testing.SetRealm(testing.NewUserRealm(sponsor))
	testing.SetHeight(1000)
	bountyID := bugtavern.CreateBounty(cross(cur),
		"TavernVault audit", "Audit the vault realm for access control flaws.",
		5000000, 3000000, 1000000, 500000, arbiter, 24600)
	// Coins attached to a non-payment call must abort the
	// transaction instead of getting stuck in the realm (design
	// §7 T14). The hash below is never reached.
	testing.SetRealm(testing.NewUserRealm(hunter))
	testing.SetHeight(1001)
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin("ugnot", 1000)))
	bugtavern.CommitFinding(cross(cur), bountyID,
		"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
		uint8(4))
}

func main() {
	println("done")
}

// Error:
// this function does not accept coins
