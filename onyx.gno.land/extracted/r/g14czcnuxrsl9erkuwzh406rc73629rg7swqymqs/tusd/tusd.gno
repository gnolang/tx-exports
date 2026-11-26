// Package tusd is a testnet dollar for Kite's checkout. It has no value.
package tusd

import (
	"strings"
	"time"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/grc20/v0"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/nt/grc20reg/v0"
)

const (
	FaucetAmount   = 1_000 * 1_000_000
	FaucetCooldown = 24 * time.Hour
)

var (
	Token      *grc20.Token
	ledger     *grc20.PrivateLedger
	userTeller grc20.Teller
	lastClaim  avl.Tree
	owner      address
)

func init(cur realm) {
	Token, ledger = grc20.NewToken("Test USD", "tUSD", 6, 0, cur)
	userTeller = ledger.CallerTeller()
	grc20reg.Register(cross(cur), Token, "")
	owner = address(strings.Split(cur.PkgPath(), "/")[2])
}

func TotalSupply() int64                     { return userTeller.TotalSupply() }
func BalanceOf(owner address) int64          { return userTeller.BalanceOf(owner) }
func Allowance(owner, spender address) int64 { return userTeller.Allowance(owner, spender) }

func Transfer(cur realm, to address, amount int64) {
	check(userTeller.Transfer(0, cur, to, amount))
}

func Approve(cur realm, spender address, amount int64) {
	check(userTeller.Approve(0, cur, spender, amount))
}

func TransferFrom(cur realm, from, to address, amount int64) {
	check(userTeller.TransferFrom(0, cur, from, to, amount))
}

// Faucet mints 1,000 tUSD to the caller, once a day.
func Faucet(cur realm) {
	caller := cur.Previous().Address()
	now := time.Now().Unix()
	if last := lastClaim.Get(caller.String()); last != nil && now < last.(int64)+int64(FaucetCooldown/time.Second) {
		panic("tusd: come back tomorrow")
	}
	lastClaim.Set(caller.String(), now)
	check(ledger.Mint(caller, FaucetAmount))
}

// Mint lets the deployer seed liquidity pools.
func Mint(cur realm, to address, amount int64) {
	if cur.Previous().Address() != owner {
		panic("tusd: only the deployer can mint")
	}
	check(ledger.Mint(to, amount))
}

func Render(path string) string {
	parts := strings.Split(path, "/")
	if len(parts) == 2 && parts[0] == "balance" {
		return ufmt.Sprintf("%d\n", userTeller.BalanceOf(address(parts[1])))
	}
	return Token.RenderHome() + "\nA test dollar with no value, for Kite on testnet. Call `Faucet` for 1,000 tUSD a day.\n"
}

func check(err error) {
	if err != nil {
		panic(err.Error())
	}
}
