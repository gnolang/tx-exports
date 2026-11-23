package ember

import (
	"chain"
	"strings"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/grc20/v0"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/nt/grc20reg/v0"
)

const StarterAmount int64 = 100

var (
	token *grc20.Token
	ledger *grc20.PrivateLedger
	claimed avl.Tree
)

func init(cur realm) {
	token, ledger = grc20.NewToken("Hearthboard Ember", "EMBER", 0, 0, cur)
	grc20reg.Register(cross(cur), token, "")
}

func ClaimStarter(cur realm) {
	caller := cur.Previous()
	if !caller.IsUserCall() {
		panic("use a direct wallet call")
	}
	owner := caller.Address()
	if ClaimedStarter(owner) {
		panic("starter EMBER already claimed")
	}
	check(ledger.Mint(owner, StarterAmount))
	claimed.Set(owner.String(), true)
	chain.Emit("StarterClaimed", "owner", owner.String())
}

func ClaimedStarter(owner address) bool { return claimed.Has(owner.String()) }
func BalanceOf(owner address) int64 { return token.BalanceOf(owner) }
func TotalSupply() int64 { return token.TotalSupply() }
func Allowance(owner, spender address) int64 { return token.Allowance(owner, spender) }

func Transfer(cur realm, to address, amount int64) {
	check(ledger.CallerTeller().Transfer(0, cur, to, amount))
}

func Approve(cur realm, spender address, amount int64) {
	check(ledger.CallerTeller().Approve(0, cur, spender, amount))
}

func TransferFrom(cur realm, from, to address, amount int64) {
	check(ledger.CallerTeller().TransferFrom(0, cur, from, to, amount))
}

func Render(path string) string {
	if path == "" {
		return "# Hearthboard Ember\n\nEMBER is a whole-unit GRC20 test token for quest bounties and tips. It has no monetary value.\n\n" +
			ufmt.Sprintf("**Supply:** %d EMBER · **Starter grant:** %d EMBER once per wallet.\n", TotalSupply(), StarterAmount)
	}
	if strings.HasPrefix(path, "balance/") {
		owner := strings.TrimPrefix(path, "balance/")
		if len(owner) == 40 && strings.HasPrefix(owner, "g1") {
			return ufmt.Sprintf("**Balance:** %d EMBER\n", BalanceOf(address(owner)))
		}
	}
	return "No such token page."
}

func check(err error) {
	if err != nil { panic(err.Error()) }
}
