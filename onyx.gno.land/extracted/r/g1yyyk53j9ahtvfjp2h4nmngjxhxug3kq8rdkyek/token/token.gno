// token is a GRC20 tip token for the Gnome Tavern Hackathon: "Gnome Tavern
// Tip" (TIP). The hackathon wallet owns the token and is the only minter;
// anyone can hold TIP and tip others with Transfer/Tip. It follows the
// canonical pattern of gno.land/r/demo/defi/foo20 (grc20.NewToken +
// CallerTeller + ownable-gated Mint/Burn).
package token

import (
	"strings"

	"chain/runtime/unsafe"

	"gno.land/p/nt/grc20/v0"
	"gno.land/p/nt/ownable/v0"
	"gno.land/p/nt/ufmt/v0"
)

const (
	tokenName     = "Gnome Tavern Tip"
	tokenSymbol   = "TIP"
	tokenDecimals = 6
	// One TIP = 10^6 base units; initial supply is 1,000,000 TIP to the owner.
	initialSupply = 1_000_000 * 1_000_000
)

var (
	Token         *grc20.Token
	privateLedger *grc20.PrivateLedger
	userTeller    grc20.Teller
	// Owner is the Gnome Tavern hackathon wallet; only it can mint/burn.
	Ownable = ownable.NewWithAddress("g1yyyk53j9ahtvfjp2h4nmngjxhxug3kq8rdkyek")
)

func init(cur realm) {
	Token, privateLedger = grc20.NewToken(tokenName, tokenSymbol, tokenDecimals, 0, cur)
	userTeller = privateLedger.CallerTeller()
	privateLedger.Mint(Ownable.Owner(), initialSupply)
}

func TotalSupply() int64 {
	return userTeller.TotalSupply()
}

func BalanceOf(owner address) int64 {
	return userTeller.BalanceOf(owner)
}

func Allowance(owner, spender address) int64 {
	return userTeller.Allowance(owner, spender)
}

func Transfer(cur realm, to address, amount int64) {
	checkErr(userTeller.Transfer(0, cur, to, amount))
}

// Tip sends TIP to another address — same as Transfer, named for the
// tipping use case this token is built for.
func Tip(cur realm, to address, amount int64) {
	checkErr(userTeller.Transfer(0, cur, to, amount))
}

func Approve(cur realm, spender address, amount int64) {
	checkErr(userTeller.Approve(0, cur, spender, amount))
}

func TransferFrom(cur realm, from, to address, amount int64) {
	checkErr(userTeller.TransferFrom(0, cur, from, to, amount))
}

// Mint creates new TIP for `to`. Only the owner (hackathon wallet) can mint.
func Mint(cur realm, to address, amount int64) {
	Ownable.AssertOwnedBy(cur.Previous().Address())
	checkErr(privateLedger.Mint(to, amount))
}

// Burn destroys TIP held by `from`. Only the owner (hackathon wallet) can burn.
func Burn(cur realm, from address, amount int64) {
	Ownable.AssertOwnedBy(cur.Previous().Address())
	checkErr(privateLedger.Burn(from, amount))
}

// Render shows token info and the viewer's balance on the home page, or a
// single balance at /balance/<address>.
func Render(path string) string {
	parts := strings.Split(path, "/")
	c := len(parts)

	switch {
	case path == "":
		out := Token.RenderHome()
		// unsafe.OriginCaller is the viewer here (Render has no `cur realm`);
		// it is only used to display a balance, never for authorization.
		// NOTE: `import "std"` does not exist in this toolchain version
		// (gno v1.8.0) — std.GetOrigCaller() was replaced by this call.
		caller := unsafe.OriginCaller()
		out += ufmt.Sprintf("* **Your balance**: %d $%s\n", userTeller.BalanceOf(caller), tokenSymbol)
		return out
	case c == 2 && parts[0] == "balance":
		owner := address(parts[1])
		if !owner.IsValid() {
			return "404\n"
		}
		return ufmt.Sprintf("%d\n", userTeller.BalanceOf(owner))
	default:
		return "404\n"
	}
}

func checkErr(err error) {
	if err != nil {
		panic(err.Error())
	}
}
