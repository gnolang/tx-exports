// Package dxv is DexVision Demo (DXV), a testnet token with no value. It
// exists so anyone can try DexVision end to end on a chain where everything is
// free: claim some DXV, trade it on Gnoswap, and see its on-chain profile.
package dxv

import (
	"chain/runtime"
	"strings"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/grc20/v0"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/nt/grc20reg/v0"
)

const (
	decimals    = 6
	unit        = 1_000_000         // 1 DXV
	supply      = 10_000_000 * unit // minted to the publisher
	faucetDrop  = 1_000 * unit      // per claim
	faucetEvery = int64(17_280)     // blocks, about a day at 5 s
	faucetCap   = 5_000_000 * unit  // total the faucet may ever mint
)

var (
	Token      *grc20.Token
	ledger     *grc20.PrivateLedger
	userTeller grc20.Teller
	lastClaim  = avl.NewTree() // address -> block height
	dropped    int64
)

func init(cur realm) {
	Token, ledger = grc20.NewToken("DexVision Demo", "DXV", decimals, 0, cur)
	userTeller = ledger.CallerTeller()
	// The publisher gets the supply to seed a Gnoswap pool. Unit tests run init
	// with no publisher, hence the check.
	if publisher := cur.Previous().Address(); publisher.IsValid() {
		checkErr(ledger.Mint(publisher, supply))
	}
	grc20reg.Register(cross(cur), Token, "")
}

func TotalSupply() int64                     { return userTeller.TotalSupply() }
func BalanceOf(owner address) int64          { return userTeller.BalanceOf(owner) }
func Allowance(owner, spender address) int64 { return userTeller.Allowance(owner, spender) }

func Transfer(cur realm, to address, amount int64) {
	checkErr(userTeller.Transfer(0, cur, to, amount))
}

func Approve(cur realm, spender address, amount int64) {
	checkErr(userTeller.Approve(0, cur, spender, amount))
}

func TransferFrom(cur realm, from, to address, amount int64) {
	checkErr(userTeller.TransferFrom(0, cur, from, to, amount))
}

// Faucet gives the caller 1,000 DXV, once a day per account.
func Faucet(cur realm) {
	prev := cur.Previous()
	if !prev.IsUser() {
		panic("dxv: claim from an account, not a contract")
	}
	who := prev.Address()
	now := runtime.ChainHeight()
	if v := lastClaim.Get(who.String()); v != nil && now-v.(int64) < faucetEvery {
		panic(ufmt.Sprintf("dxv: next claim at block %d", v.(int64)+faucetEvery))
	}
	if dropped+faucetDrop > faucetCap {
		panic("dxv: the faucet is empty")
	}
	lastClaim.Set(who.String(), now)
	dropped += faucetDrop
	checkErr(ledger.Mint(who, faucetDrop))
}

func Render(path string) string {
	if strings.HasPrefix(path, "balance/") {
		addr := address(strings.TrimPrefix(path, "balance/"))
		if !addr.IsValid() {
			return "Not an address."
		}
		return ufmt.Sprintf("%s has %s DXV.", addr.String(), formatDXV(userTeller.BalanceOf(addr)))
	}
	return "# DexVision Demo (DXV)\n\nA testnet token with no value, for trying [DexVision](https://dexvision.pro/?network=onyx) end to end.\n\n" +
		Token.RenderHome() + "\nClaim 1,000 DXV a day with `Faucet`.\n"
}

func checkErr(err error) {
	if err != nil {
		panic(err)
	}
}

// formatDXV writes base units as DXV, e.g. 1500000 -> 1.500000.
func formatDXV(n int64) string {
	return ufmt.Sprintf("%d.%06d", n/unit, n%unit)
}
