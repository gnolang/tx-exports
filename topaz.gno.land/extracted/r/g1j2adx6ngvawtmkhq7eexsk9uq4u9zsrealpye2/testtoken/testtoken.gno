// Package testtoken is a throwaway compatibility-test fixture -- NOT a
// candidate design for the real project. It exists only to verify
// whether registering with gno.land/r/demo/defi/grc20reg makes a token
// show up in gno-observer's cache, since neither of the real candidate
// designs (self-implemented token.gno / tokenfactory.gno) can register
// at all -- grc20reg.Register requires an actual *grc20.Token object
// from the canonical shared package, which neither design creates.
package testtoken

import (
	"gno.land/p/demo/tokens/grc20"

	"gno.land/r/demo/defi/grc20reg"
)

const tokenID = 0

var (
	token         *grc20.Token
	privateLedger *grc20.PrivateLedger
	userTeller    grc20.Teller
	creator       address = "g1j2adx6ngvawtmkhq7eexsk9uq4u9zsrealpye2"
)

func init(cur realm) {
	token, privateLedger = grc20.NewToken("Prueba", "PRUEBA", 6, tokenID, cur)
	userTeller = token.CallerTeller()
	privateLedger.Mint(creator, 1_000_000)
	grc20reg.Register(cross(cur), token, "")
}

func Name() string       { return token.GetName() }
func Symbol() string     { return token.GetSymbol() }
func Decimals() int      { return token.GetDecimals() }
func TotalSupply() int64 { return token.TotalSupply() }

func BalanceOf(owner address) int64 {
	return token.BalanceOf(owner)
}

func Allowance(owner, spender address) int64 {
	return token.Allowance(owner, spender)
}

func Transfer(cur realm, to address, amount int64) {
	checkErr(userTeller.Transfer(0, cur, to, amount))
}

func Approve(cur realm, spender address, amount int64) {
	checkErr(userTeller.Approve(0, cur, spender, amount))
}

func TransferFrom(cur realm, from, to address, amount int64) {
	checkErr(userTeller.TransferFrom(0, cur, from, to, amount))
}

func Render(path string) string {
	return token.RenderHome()
}

func checkErr(err error) {
	if err != nil {
		panic(err)
	}
}
