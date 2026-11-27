// Package tavern is a demo GRC20 token used to show SEALED launches.
//
// It is a plain p/nt/grc20 token, registered in r/nt/grc20reg so that any
// realm (SEALED included) can find it by key. Faucet is open on purpose:
// this token exists for testnet and local demos only.
package tavern

import (
	"strings"

	"gno.land/p/nt/grc20/v0"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/nt/grc20reg/v0"
)

// FaucetAmount is how many TAVERN a single Faucet call mints.
const FaucetAmount int64 = 10_000

var (
	Token  *grc20.Token
	ledger *grc20.PrivateLedger

	// Key is the grc20reg key of this token, e.g. "gno.land/r/g15xk7p2u3q6epjq5kfyew2lku5epakfnat7fj40/tavern/v1.TAVERN".
	// Pass it as the `token` argument of sealed.CreateAuction.
	Key string
)

func init(cur realm) {
	// Decimals = 0: one unit is one whole token, which keeps auction
	// prices readable ("1.2 GNOT per TAVERN").
	Token, ledger = grc20.NewToken("Tavern Token", "TAVERN", 0, 0, cur)
	Key = grc20reg.Register(cross(cur), Token, "")
}

// Faucet mints FaucetAmount TAVERN to the caller. Demo only.
func Faucet(cur realm) {
	checkErr(ledger.Mint(cur.Previous().Address(), FaucetAmount))
}

func Transfer(cur realm, to address, amount int64) {
	checkErr(ledger.CallerTeller().Transfer(0, cur, to, amount))
}

// Approve lets `spender` (for example the SEALED realm address) move up to
// `amount` of the caller's TAVERN.
func Approve(cur realm, spender address, amount int64) {
	checkErr(ledger.CallerTeller().Approve(0, cur, spender, amount))
}

func TransferFrom(cur realm, from, to address, amount int64) {
	checkErr(ledger.CallerTeller().TransferFrom(0, cur, from, to, amount))
}

func BalanceOf(owner address) int64 { return Token.BalanceOf(owner) }

func Allowance(owner, spender address) int64 { return Token.Allowance(owner, spender) }

func TotalSupply() int64 { return Token.TotalSupply() }

func Render(path string) string {
	parts := strings.Split(path, "/")
	if len(parts) == 2 && parts[0] == "balance" {
		return ufmt.Sprintf("%d", Token.BalanceOf(address(parts[1])))
	}
	return "# Tavern Token (TAVERN)\n\n" +
		"Demo GRC20 for [SEALED](/r/g15xk7p2u3q6epjq5kfyew2lku5epakfnat7fj40/sealed/v1) launches. Testnet only.\n\n" +
		ufmt.Sprintf("- Registry key: `%s`\n", Key) +
		ufmt.Sprintf("- Total supply: %d\n", Token.TotalSupply()) +
		ufmt.Sprintf("- Holders: %d\n", Token.KnownAccounts()) +
		ufmt.Sprintf("- Faucet: `Faucet()` mints %d TAVERN to the caller\n", FaucetAmount)
}

func checkErr(err error) {
	if err != nil {
		panic(err)
	}
}
