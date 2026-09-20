// Parametric GRC20 realm for gno.land.
//
// All configuration (name, symbol, decimals, supply, metadata) lives in
// config.gno. This file holds only the logic, which is not meant to be edited.
//
// The realm:
//   - creates a GRC20 token through gno.land/p/nt/grc20/v0
//   - registers it with gno.land/r/nt/grc20reg/v0 (required to be discoverable
//     by GnoSwap, wallets and explorers)
//   - mints the initial supply to the deploying address
//   - exposes the GRC20 methods as top-level functions callable via MsgCall
//   - enforces a hard ceiling (maxSupply) on minting
//   - lets the owner give up minting forever (DropOwnership)
package gnomic

import (
	"chain/runtime"
	"chain/runtime/unsafe"
	"math"
	"strconv"
	"strings"

	"gno.land/p/nt/grc20/v0"
	"gno.land/p/nt/ownable/v0"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/nt/grc20reg/v0"
)

var (
	// Token is the public handle on the token: other realms can read it, but
	// cannot mutate balances (the PrivateLedger stays private).
	Token *grc20.Token

	// Ownable holds the administrative authority (mint / administrative burn).
	Ownable *ownable.Ownable

	privateLedger *grc20.PrivateLedger
	userTeller    grc20.Teller

	// unit = 10^tokenDecimals, the conversion factor between whole units and
	// base units.
	unit int64

	// hardCap = maxSupply * unit, expressed in base units.
	hardCap int64

	// totalMinted is the CUMULATIVE amount ever minted, and never goes down.
	//
	// The ceiling is checked against this figure rather than against circulating
	// supply, because Burn lowers supply: checking that, burning would reopen
	// minting headroom and "21 million" would become an instantaneous limit
	// instead of a final one. With the cumulative counter burned tokens are gone
	// for good, which is what a fixed supply is supposed to mean.
	totalMinted int64

	// tokenKey is the canonical key in the GRC20 registry: "<pkgpath>.<SYMBOL>".
	// It is the identifier used by GnoSwap and friends.
	tokenKey string

	deployHeight int64
	realmAddr    address
)

func init(cur realm) {
	unit = pow10(tokenDecimals)
	hardCap = mulOrPanic(maxSupply, unit)
	initial := mulOrPanic(initialSupply, unit)
	if initial > hardCap {
		panic("token: initialSupply exceeds maxSupply")
	}

	// Who administers the token:
	//  1. ownerAddress from config.gno, when set (e.g. a multisig or a DAO);
	//  2. otherwise the realm/user that ran the addpkg;
	//  3. otherwise the EOA that signed the deploy transaction.
	owner := address(ownerAddress)
	if !owner.IsValid() {
		owner = cur.Previous().Address()
	}
	if !owner.IsValid() {
		owner = unsafe.OriginCaller()
	}
	if !owner.IsValid() {
		panic("token: cannot determine the owner address")
	}

	Token, privateLedger = grc20.NewToken(tokenName, tokenSymbol, tokenDecimals, 0, cur)
	userTeller = privateLedger.CallerTeller()
	Ownable = ownable.NewWithAddress(owner)

	if initial > 0 {
		if err := privateLedger.Mint(owner, initial); err != nil {
			panic(err)
		}
		totalMinted = initial
	}

	// Registration in the system GRC20 registry. Without this step the token
	// exists but is invisible to GnoSwap, wallets and explorers.
	tokenKey = grc20reg.Register(cross(cur), Token, "")

	realmAddr = cur.Address()
	deployHeight = runtime.ChainHeight()
}

// ---------------------------------------------------------------------------
// Reads (no state cost, queryable with `gnokey query vm/qeval`)
// ---------------------------------------------------------------------------

// Name returns the token name.
func Name() string { return Token.GetName() }

// Symbol returns the ticker.
func Symbol() string { return Token.GetSymbol() }

// Decimals returns the precision.
func Decimals() int { return Token.GetDecimals() }

// TotalSupply returns the circulating supply in base units.
func TotalSupply() int64 { return Token.TotalSupply() }

// MaxSupply returns the hard ceiling in base units: it caps the cumulative
// amount ever minted, not the circulating supply.
func MaxSupply() int64 { return hardCap }

// TotalMinted returns the cumulative amount ever minted. It never goes down,
// not even after a Burn: hardCap - TotalMinted() is the remaining headroom.
func TotalMinted() int64 { return totalMinted }

// Burned returns the total destroyed: cumulative minted minus circulating.
func Burned() int64 { return totalMinted - Token.TotalSupply() }

// Holders returns the number of addresses with a non-zero balance.
func Holders() int { return Token.KnownAccounts() }

// BalanceOf returns the balance of owner in base units.
func BalanceOf(owner address) int64 { return Token.BalanceOf(owner) }

// Allowance returns how much spender may draw from owner.
func Allowance(owner, spender address) int64 { return Token.Allowance(owner, spender) }

// TokenKey returns the token's key in the GRC20 registry ("<pkgpath>.<SYMBOL>"),
// to be used with r/nt/grc20reg and with GnoSwap.
func TokenKey() string { return tokenKey }

// RealmAddress returns the address of the realm itself: the address to send
// funds meant for the contract (an airdrop budget, for instance).
func RealmAddress() address { return realmAddr }

// Owner returns the current administrator ("" once ownership has been dropped).
func Owner() address { return Ownable.Owner() }

// ---------------------------------------------------------------------------
// Standard GRC20 writes
// ---------------------------------------------------------------------------

// Transfer sends amount (base units) from the caller to to.
func Transfer(cur realm, to address, amount int64) {
	checkErr(userTeller.Transfer(0, cur, to, amount))
}

// Approve authorises spender to draw up to amount from the caller.
func Approve(cur realm, spender address, amount int64) {
	checkErr(userTeller.Approve(0, cur, spender, amount))
}

// TransferFrom moves amount from from to to, consuming the caller's allowance.
func TransferFrom(cur realm, from, to address, amount int64) {
	checkErr(userTeller.TransferFrom(0, cur, from, to, amount))
}

// Burn destroys amount of the caller's tokens, reducing the supply.
func Burn(cur realm, amount int64) {
	checkErr(privateLedger.Burn(cur.Previous().Address(), amount))
}

// ---------------------------------------------------------------------------
// Administration
// ---------------------------------------------------------------------------

// Mint creates amount (base units) in favour of to. Owner only, and never
// beyond maxSupply. After DropOwnership this function is unusable forever: the
// supply becomes immutable upwards.
func Mint(cur realm, to address, amount int64) {
	Ownable.AssertOwnedBy(cur.Previous().Address())
	if amount <= 0 {
		panic("token: amount must be positive")
	}
	if totalMinted > hardCap-amount {
		panic("token: mint would exceed maxSupply")
	}
	totalMinted += amount
	checkErr(privateLedger.Mint(to, amount))
}

// TransferOwnership hands administration over to newOwner.
func TransferOwnership(cur realm, newOwner address) {
	checkErr(Ownable.TransferOwnership(0, cur, newOwner))
}

// DropOwnership gives up administration for good: no future mint will ever be
// possible. The operation cannot be undone.
func DropOwnership(cur realm) {
	checkErr(Ownable.DropOwnership(0, cur))
}

// ---------------------------------------------------------------------------
// Render
// ---------------------------------------------------------------------------

func Render(path string) string {
	parts := strings.Split(path, "/")

	switch {
	case path == "":
		return renderHome()
	case len(parts) == 2 && parts[0] == "balance":
		addr := address(parts[1])
		if !addr.IsValid() {
			return "invalid address\n"
		}
		return ufmt.Sprintf("%s %s\n", format(Token.BalanceOf(addr)), tokenSymbol)
	default:
		return "404\n"
	}
}

func renderHome() string {
	s := ""
	if tokenLogoURI != "" {
		s += ufmt.Sprintf("![%s](%s)\n\n", tokenSymbol, tokenLogoURI)
	}
	s += ufmt.Sprintf("# %s ($%s)\n\n", tokenName, tokenSymbol)
	if tokenDescription != "" {
		s += tokenDescription + "\n\n"
	}
	s += "| | |\n|---|---|\n"
	s += ufmt.Sprintf("| Symbol | %s |\n", tokenSymbol)
	s += ufmt.Sprintf("| Decimals | %d |\n", tokenDecimals)
	s += ufmt.Sprintf("| Circulating supply | %s |\n", format(Token.TotalSupply()))
	s += ufmt.Sprintf("| Max supply | %s |\n", format(hardCap))
	s += ufmt.Sprintf("| Minted in total | %s |\n", format(totalMinted))
	s += ufmt.Sprintf("| Burned | %s |\n", format(Burned()))
	s += ufmt.Sprintf("| Holders | %d |\n", Token.KnownAccounts())
	s += ufmt.Sprintf("| Registry key | `%s` |\n", tokenKey)
	s += ufmt.Sprintf("| Mint | %s |\n", mintStatus())
	s += ufmt.Sprintf("| Deployed at block | %d |\n", deployHeight)
	s += "\n"
	if tokenWebsite != "" {
		s += ufmt.Sprintf("- Website: %s\n", tokenWebsite)
	}
	if tokenTwitter != "" {
		s += ufmt.Sprintf("- X: %s\n", tokenTwitter)
	}
	s += "\nLook up a balance: `:balance/<address>`\n"
	return s
}

func mintStatus() string {
	if !Ownable.Owner().IsValid() {
		return "**closed for good** (ownership dropped)"
	}
	if totalMinted >= hardCap {
		return "**exhausted**: the mint ceiling is reached, no further token can be created"
	}
	return ufmt.Sprintf("%s left, controlled by %s",
		format(hardCap-totalMinted), Ownable.Owner().String())
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

// format turns base units into a readable decimal string.
//
// The sign is applied at the end rather than by negating v: for |v| < unit the
// whole part is 0, so the minus would be lost (format(-500000) gave "0.5").
// Negating v directly is no good either, because -math.MinInt64 overflows;
// instead the whole part and the remainder are negated, both safe in magnitude.
func format(v int64) string {
	if unit == 1 {
		return strconv.FormatInt(v, 10)
	}
	neg := v < 0
	whole := v / unit
	frac := v % unit
	if whole < 0 {
		whole = -whole
	}
	if frac < 0 {
		frac = -frac
	}

	fs := strconv.FormatInt(frac, 10)
	for len(fs) < tokenDecimals {
		fs = "0" + fs
	}
	fs = strings.TrimRight(fs, "0")

	out := strconv.FormatInt(whole, 10)
	if fs != "" {
		out += "." + fs
	}
	if neg {
		out = "-" + out
	}
	return out
}

func pow10(n int) int64 {
	r := int64(1)
	for i := 0; i < n; i++ {
		r *= 10
	}
	return r
}

func mulOrPanic(a, b int64) int64 {
	if a < 0 || b <= 0 {
		panic("token: invalid supply parameters")
	}
	if a > math.MaxInt64/b {
		panic("token: supply * 10^decimals exceeds int64")
	}
	return a * b
}

func checkErr(err error) {
	if err != nil {
		panic(err.Error())
	}
}
