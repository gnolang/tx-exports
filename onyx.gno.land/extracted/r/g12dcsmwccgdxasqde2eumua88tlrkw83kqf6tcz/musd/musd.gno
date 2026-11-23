// Package musd is Mimir USD (mUSD), the GRC20 test dollar Mimir markets stake
// on gno.land. It has 6 decimals, like USDC: 1 mUSD = 1_000_000 units.
//
// Anyone can call Faucet once per FaucetCooldown to receive FaucetAmount.
// It is a testnet token: it has no value and no backing.
package musd

import (
	"chain"
	"strings"
	"time"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/grc20/v0"
	"gno.land/p/nt/ownable/v0"
	"gno.land/p/nt/ufmt/v0"
)

// Deployer owns Mint, used to seed agent and council wallets.
const Deployer = address("g12dcsmwccgdxasqde2eumua88tlrkw83kqf6tcz")

const (
	Decimals       = 6
	Unit           = int64(1_000_000)
	FaucetAmount   = 1_000 * Unit
	FaucetCooldown = 24 * time.Hour
)

var (
	Token      *grc20.Token
	ledger     *grc20.PrivateLedger
	userTeller grc20.Teller
	Ownable    *ownable.Ownable
	// lastDrip: address -> unix seconds of the last faucet payout.
	lastDrip avl.Tree
)

func init(cur realm) {
	Token, ledger = grc20.NewToken("Mimir USD", "mUSD", Decimals, 0, cur)
	userTeller = ledger.CallerTeller()
	Ownable = ownable.NewWithAddress(Deployer)
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

// Faucet pays FaucetAmount to the caller, at most once per FaucetCooldown.
func Faucet(cur realm) {
	caller := cur.Previous().Address()
	now := time.Now().Unix()
	if v := lastDrip.Get(caller.String()); v != nil {
		next := v.(int64) + int64(FaucetCooldown/time.Second)
		if now < next {
			panic(ufmt.Sprintf("faucet: next drip at unix %d", next))
		}
	}
	lastDrip.Set(caller.String(), now)
	check(ledger.Mint(caller, FaucetAmount))
	chain.Emit("Faucet", "to", caller.String(), "amount", ufmt.Sprintf("%d", FaucetAmount))
}

// NextDrip is the unix time from which addr may use the faucet again (0: now).
func NextDrip(addr address) int64 {
	v := lastDrip.Get(addr.String())
	if v == nil {
		return 0
	}
	return v.(int64) + int64(FaucetCooldown/time.Second)
}

// Mint is for the owner, to seed agent and council wallets.
func Mint(cur realm, to address, amount int64) {
	Ownable.AssertOwnedBy(cur.Previous().Address())
	check(ledger.Mint(to, amount))
}

func Render(path string) string {
	parts := strings.Split(path, "/")
	switch {
	case path == "":
		return Token.RenderHome() + "\n" + ufmt.Sprintf(
			"Faucet: %d mUSD per address every %s. Call `Faucet` from your wallet.\n",
			FaucetAmount/Unit, FaucetCooldown.String())
	case len(parts) == 2 && parts[0] == "balance":
		return ufmt.Sprintf("%d\n", userTeller.BalanceOf(address(parts[1])))
	default:
		return "404\n"
	}
}

func check(err error) {
	if err != nil {
		panic(err.Error())
	}
}
