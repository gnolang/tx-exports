// Package wbubble is wrapped BUBBLE: the Bubble Rumble token as a registered GRC20, backed one to one by BUBBLE
// held in this realm. It exists for gnoswap, which pools only tokens registered in gno.land/r/nt/grc20reg/v0 —
// and the registry takes only a *grc20.Token made by grc20.NewToken inside the registering realm. BUBBLE
// (gno.land/r/g1leu8d2vsplhehcfkjg50mwgdpxdkt8tztu95wr/bubble) keeps its ledger in kourt's grc20votes, not a
// grc20.Token, and a realm cannot be redeployed; so this realm holds BUBBLE and issues a registered token for
// it, the way gno.land/r/gnoland/wugnot wraps ugnot (ref/ holds the mainnet sources this mirrors).
//
// Wrap pulls BUBBLE from the caller — an allowance the caller granted THIS realm on the bubble realm, spent by
// this realm as itself — and mints the same amount of wrapped BUBBLE to the caller. Unwrap burns the caller's
// wrapped BUBBLE and sends the same amount of BUBBLE back. Nothing else mints or burns, and nothing here is a
// setting: no admin, no pause, no minter. The reserve (this realm's BUBBLE balance) covers the wrapped supply
// after every call, and a call that would leave it short aborts.
//
// Votes. BUBBLE carries a vote in its own realm; wrapped BUBBLE carries none. The BUBBLE held here is
// self-delegated, inside the bubble ledger, to this realm's own address — the ledger's default for every holder —
// and this realm never delegates it or votes with it, so that weight is never cast. Unwrap to vote.
package wbubble

import (
	"chain"
	"strconv"
	"strings"

	"gno.land/p/nt/grc20/v0"
	"gno.land/r/g1leu8d2vsplhehcfkjg50mwgdpxdkt8tztu95wr/bubble"
	"gno.land/r/nt/grc20reg/v0"
)

// Token is the registered token, exported as wugnot exports its own: a *grc20.Token carries no spend
// authority (its tellers act only for the realm that builds them, and only with an allowance), and the registry
// hands the same pointer to anyone. ledger is the mint and burn, and it never leaves this package.
var (
	Token  *grc20.Token
	ledger *grc20.PrivateLedger
)

const (
	tokenName     = "Bubble Rumble BUBBLE (wrapped)"
	tokenSymbol   = "BUBBLE"
	tokenDecimals = 6
	pkgPath       = "gno.land/r/g1leu8d2vsplhehcfkjg50mwgdpxdkt8tztu95wr/wbubble" // must match gnomod.toml
	// RegistryKey is what gno.land/r/nt/grc20reg/v0 knows this token as: the realm path and the symbol.
	RegistryKey = pkgPath + "." + tokenSymbol

	one = int64(1_000_000) // one BUBBLE in base units
)

func init(cur realm) {
	// wbubble only ever creates this one token, so id 0 can't collide.
	Token, ledger = grc20.NewToken(tokenName, tokenSymbol, tokenDecimals, 0, cur)
	if key := grc20reg.Register(cross(cur), Token, ""); key != RegistryKey {
		panic("wbubble: registered as " + key + ", not " + RegistryKey + ": the package path is not the one in the source")
	}
}

// Address is this realm's own address: the spender to approve on the bubble realm before Wrap, and the holder of
// the reserve.
func Address() address { return chain.PackageAddress(pkgPath) }

// Reserve is the BUBBLE this realm holds. It covers TotalSupply after every call (checkReserve).
func Reserve() int64 { return bubble.BalanceOf(Address()) }

// Wrap takes amount BUBBLE from the caller and mints as much wrapped BUBBLE to them. First, on the bubble realm,
// the caller approves THIS realm for the amount (bubble.Approve with spender Address()): bubble reads its own
// caller as the spender, and its caller here is this realm, not the user. A failure inside bubble panics across
// the realm boundary and aborts the whole transaction, so nothing is minted for BUBBLE that did not arrive.
func Wrap(cur realm, amount int64) {
	require(amount > 0, "wbubble: the amount must be positive")
	// The security guide's rule (gno-security-guide.md §5.6, §8): read the caller from cur only after IsCurrent.
	// Under interrealm v2 (gno-interrealm-v2.md §5.2) a crossing function's own cur is always current, so this
	// refuses nobody; it is kept so the realm meets both documents.
	if !cur.IsCurrent() {
		panic("wbubble: spoofed realm")
	}
	caller := cur.Previous().Address()
	self := cur.Address()
	before := bubble.BalanceOf(self)
	bubble.TransferFrom(cross(cur), caller, self, amount)
	checkErr(ledger.Mint(caller, amount))
	checkReserve(self, before+amount)
}

// Unwrap burns amount of the caller's wrapped BUBBLE and sends them as much BUBBLE. The burn goes first: a caller
// without the wrapped tokens is refused before anything moves.
func Unwrap(cur realm, amount int64) {
	require(amount > 0, "wbubble: the amount must be positive")
	if !cur.IsCurrent() { // see Wrap
		panic("wbubble: spoofed realm")
	}
	caller := cur.Previous().Address()
	self := cur.Address()
	before := bubble.BalanceOf(self)
	checkErr(ledger.Burn(caller, amount))
	bubble.Transfer(cross(cur), caller, amount)
	checkReserve(self, before-amount)
}

// checkReserve is the invariant after every move: the reserve moved by exactly the amount, and it covers the
// supply. Not `reserve == supply`: anyone can send BUBBLE straight to this realm's address, and a wrapper that
// demanded equality would then refuse every Wrap and Unwrap for good. Such a gift only puts the reserve over the
// supply; it belongs to nobody and stays.
func checkReserve(self address, want int64) {
	have := bubble.BalanceOf(self)
	if have != want {
		panic("wbubble: the reserve moved by the wrong amount")
	}
	if have < Token.TotalSupply() {
		panic("wbubble: the reserve is short of the wrapped supply")
	}
}

// ------------------------------------------------------------ the GRC20 --
//
// wugnot's surface, line for line: the reads on the Token, the writes through the ledger's caller teller, which
// acts for whoever crossed into this realm and works nowhere but here.

func TotalSupply() int64 {
	return Token.TotalSupply()
}

func BalanceOf(owner address) int64 {
	return Token.BalanceOf(owner)
}

func Allowance(owner, spender address) int64 {
	return Token.Allowance(owner, spender)
}

func Transfer(cur realm, to address, amount int64) {
	userTeller := ledger.CallerTeller()
	checkErr(userTeller.Transfer(0, cur, to, amount))
}

func Approve(cur realm, spender address, amount int64) {
	userTeller := ledger.CallerTeller()
	checkErr(userTeller.Approve(0, cur, spender, amount))
}

func TransferFrom(cur realm, from, to address, amount int64) {
	userTeller := ledger.CallerTeller()
	checkErr(userTeller.TransferFrom(0, cur, from, to, amount))
}

// ----------------------------------------------------------------- pages --

// Render: "" the token's page; "balance/<addr>" one wrapped balance as a number (wugnot's path); "json" the
// figures for the box.
func Render(path string) string {
	parts := strings.Split(path, "/")
	switch {
	case path == "":
		return home()
	case path == "json":
		return json()
	case len(parts) == 2 && parts[0] == "balance":
		return strconv.FormatInt(Token.BalanceOf(address(parts[1])), 10)
	default:
		return "404"
	}
}

func home() string {
	self := Address()
	supply, reserve := Token.TotalSupply(), bubble.BalanceOf(self)
	var b strings.Builder
	b.WriteString("Wrapped BUBBLE, symbol " + tokenSymbol + ", " + strconv.Itoa(tokenDecimals) + " decimals: the Bubble Rumble token as a registered GRC20, for gnoswap and every realm that reads the token registry.\n\n")
	b.WriteString("Wrapped in circulation: " + amount(supply) + " BUBBLE. Reserve held by this realm at " + self.String() + ": " + amount(reserve) + " BUBBLE")
	switch {
	case reserve == supply:
		b.WriteString(", exactly the supply.\n\n")
	case reserve > supply:
		b.WriteString(", " + amount(reserve-supply) + " over the supply (BUBBLE sent here directly; it belongs to nobody).\n\n")
	default:
		b.WriteString(" — SHORT of the supply by " + amount(supply-reserve) + "; this must never print.\n\n")
	}
	b.WriteString("Registry key: " + RegistryKey + " (gno.land/r/nt/grc20reg/v0).\n\n")
	b.WriteString("To wrap: on the bubble realm call Approve with spender " + self.String() + " and the amount in base units, then call Wrap here with the same amount.\n")
	b.WriteString("To unwrap: call Unwrap here with the amount; the BUBBLE comes back to your address.\n\n")
	b.WriteString("Votes: BUBBLE carries a vote in its own realm and wrapped BUBBLE carries none. What this realm holds is self-delegated to the realm's own address inside the bubble ledger and is never cast. Unwrap to vote.\n")
	return b.String()
}

func json() string {
	return `{"name":"` + tokenName + `","symbol":"` + tokenSymbol + `","decimals":` + strconv.Itoa(tokenDecimals) +
		`,"supply":` + strconv.FormatInt(Token.TotalSupply(), 10) + `,"reserve":` + strconv.FormatInt(Reserve(), 10) +
		`,"address":"` + Address().String() + `","key":"` + RegistryKey + `"}`
}

// amount prints base units as BUBBLE with up to six decimals, trailing zeros dropped.
func amount(n int64) string {
	whole, frac := n/one, n%one
	if frac == 0 {
		return strconv.FormatInt(whole, 10)
	}
	f := strconv.FormatInt(frac, 10)
	for len(f) < tokenDecimals {
		f = "0" + f
	}
	return strconv.FormatInt(whole, 10) + "." + strings.TrimRight(f, "0")
}

func require(condition bool, msg string) {
	if !condition {
		panic(msg)
	}
}

func checkErr(err error) {
	if err != nil {
		panic("wbubble: " + err.Error())
	}
}
