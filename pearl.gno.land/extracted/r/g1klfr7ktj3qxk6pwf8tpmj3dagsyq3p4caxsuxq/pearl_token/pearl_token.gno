package pearl_token

import (
	"strings"

	"gno.land/p/demo/tokens/grc20"
	"gno.land/p/nt/ownable/v0"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/demo/defi/grc20reg"
)

var (
	Token         *grc20.Token
	privateLedger *grc20.PrivateLedger
	userTeller    grc20.Teller
	Ownable       *ownable.Ownable
)

func init(cur realm) {
	Token, privateLedger = grc20.NewToken("PearlToken", "PEARL", 6, 0, cur)
	userTeller = privateLedger.CallerTeller()
	Ownable = ownable.NewWithAddress(cur.Previous().Address())
	privateLedger.Mint(Ownable.Owner(), 10_000_000*1_000_000)
	grc20reg.Register(cross(cur), Token, "")
}

func TotalSupply() int64 { return userTeller.TotalSupply() }
func BalanceOf(owner address) int64 { return userTeller.BalanceOf(owner) }
func Allowance(owner, spender address) int64 { return userTeller.Allowance(owner, spender) }
func Name() string { return Token.GetName() }
func Symbol() string { return Token.GetSymbol() }
func Decimals() int { return Token.GetDecimals() }

func Transfer(cur realm, to address, amount int64) {
	checkErr(userTeller.Transfer(0, cur, to, amount))
}
func Approve(cur realm, spender address, amount int64) {
	checkErr(userTeller.Approve(0, cur, spender, amount))
}
func TransferFrom(cur realm, from, to address, amount int64) {
	checkErr(userTeller.TransferFrom(0, cur, from, to, amount))
}
func Faucet(cur realm) {
	caller := cur.Previous().Address()
	checkErr(privateLedger.Mint(caller, 1_000_000))
}
func Mint(cur realm, to address, amount int64) {
	Ownable.AssertOwnedBy(cur.Previous().Address())
	checkErr(privateLedger.Mint(to, amount))
}
func Burn(cur realm, from address, amount int64) {
	Ownable.AssertOwnedBy(cur.Previous().Address())
	checkErr(privateLedger.Burn(from, amount))
}

func Render(path string) string {
	b := strings.Builder{}
	b.WriteString("# PearlToken (PEARL)\n\n")
	b.WriteString(ufmt.Sprintf("**Total Supply:** %d PEARL\n", TotalSupply()/1_000_000))
	b.WriteString(ufmt.Sprintf("**Decimals:** %d\n", Decimals()))
	b.WriteString(ufmt.Sprintf("**Owner:** %s\n\n", Ownable.Owner()))
	return b.String()
}

func checkErr(err error) {
	if err != nil { panic(err) }
}
