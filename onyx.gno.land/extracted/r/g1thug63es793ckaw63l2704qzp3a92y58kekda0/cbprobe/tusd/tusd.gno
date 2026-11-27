// Package tusd is the Charterbook skeleton probe's test token: "Probe Dollar"
// (PUSD), 6 decimals. Test-only, no value. It exists to check, on Onyx, that
// a GRC20 realm passes package approval and works with a fund realm.
package tusd

import (
	"strings"

	"gno.land/p/nt/grc20/v0"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/nt/grc20reg/v0"
)

const faucetAmount int64 = 50_000 * 1_000_000 // 50,000 PUSD

var (
	token    *grc20.Token
	ledger   *grc20.PrivateLedger
	user     grc20.Teller
	tokenKey string
)

func init(cur realm) {
	token, ledger = grc20.NewToken("Probe Dollar", "PUSD", 6, 0, cur)
	user = ledger.CallerTeller()
	tokenKey = grc20reg.Register(cross(cur), token, "")
}

// TokenKey returns this token's key in the grc20reg registry.
func TokenKey() string { return tokenKey }

func BalanceOf(owner address) int64 { return user.BalanceOf(owner) }

func Allowance(owner, spender address) int64 { return user.Allowance(owner, spender) }

func TotalSupply() int64 { return user.TotalSupply() }

// Faucet mints 50,000 PUSD to the caller. Test token: no limit by design.
func Faucet(cur realm) {
	checkErr(ledger.Mint(cur.Previous().Address(), faucetAmount))
}

func Approve(cur realm, spender address, amount int64) {
	checkErr(user.Approve(0, cur, spender, amount))
}

func Transfer(cur realm, to address, amount int64) {
	checkErr(user.Transfer(0, cur, to, amount))
}

func Render(path string) string {
	parts := strings.Split(path, "/")
	if path == "" {
		return "# Probe Dollar (PUSD)\n\nTest token for the Charterbook skeleton probe on Onyx. No value.\n\n" + token.RenderHome()
	}
	if len(parts) == 2 && parts[0] == "balance" {
		return ufmt.Sprintf("%d", user.BalanceOf(address(parts[1])))
	}
	return "404"
}

func checkErr(err error) {
	if err != nil {
		panic(err.Error())
	}
}
