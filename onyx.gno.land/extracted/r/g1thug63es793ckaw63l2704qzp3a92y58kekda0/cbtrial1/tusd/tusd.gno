// Package tusd is "Test Dollar" (tUSD), the dealing currency of the
// Charterbook demonstration fund on the Onyx testnet. It is a GRC20 token
// with 6 decimals. TEST TOKEN: it has no value and is not a stablecoin.
//
// Two ways to get tUSD:
//   - Faucet: anyone can claim 100,000 tUSD, once per 1,200 blocks per address;
//   - issuer desk: the test issuer mints against simulated dollar deposits and
//     holders redeem (burn) against simulated withdrawals. Both carry a
//     reference so the flow can be followed on-chain.
//
// A real stablecoin arriving over IBC can replace tUSD later; the fund only
// knows tUSD by its registry key.
package tusd

import (
	"chain"
	"chain/runtime"
	"strings"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/grc20/v0"
	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/nt/grc20reg/v0"
)

const (
	// FaucetAmount is 100,000 tUSD (ten fund lots).
	FaucetAmount int64 = 100_000 * 1_000_000
	// FaucetCooldown in blocks between claims by the same address.
	FaucetCooldown int64 = 1_200
	maxRefLen            = 64
)

var (
	token     *grc20.Token
	ledger    *grc20.PrivateLedger
	user      grc20.Teller
	tokenKey  string
	owner     address
	issuer    address
	lastClaim = avl.NewTree() // address -> int64 height
	selfPath  string
)

func init(cur realm) {
	token, ledger = grc20.NewToken("Test Dollar", "tUSD", 6, 0, cur)
	user = ledger.CallerTeller()
	tokenKey = grc20reg.Register(cross(cur), token, "")
	owner = cur.Previous().Address()
	issuer = owner
	selfPath = cur.PkgPath()
}

// Path is this realm's package path, so other realms can link to it.
func Path() string { return selfPath }

// TokenKey is this token's key in the grc20reg registry.
func TokenKey() string { return tokenKey }

// Issuer is the address of the test issuer desk.
func Issuer() address { return issuer }

func BalanceOf(a address) int64          { return user.BalanceOf(a) }
func Allowance(o, spender address) int64 { return user.Allowance(o, spender) }
func TotalSupply() int64                 { return user.TotalSupply() }

// Faucet mints FaucetAmount to the caller, at most once per FaucetCooldown
// blocks per address.
func Faucet(cur realm) {
	caller := cur.Previous().Address()
	h := runtime.ChainHeight()
	if v := lastClaim.Get(caller.String()); v != nil {
		if next := v.(int64) + FaucetCooldown; h < next {
			panic(ufmt.Sprintf("faucet: next claim at block %d", next))
		}
	}
	lastClaim.Set(caller.String(), h)
	checkErr(ledger.Mint(caller, FaucetAmount))
	chain.Emit("Faucet", "to", caller.String(), "amount", ufmt.Sprintf("%d", FaucetAmount))
}

func Approve(cur realm, spender address, amount int64) {
	checkErr(user.Approve(0, cur, spender, amount))
}

func Transfer(cur realm, to address, amount int64) {
	checkErr(user.Transfer(0, cur, to, amount))
}

// IssuerMint mints amount to `to` against a simulated deposit. Issuer only.
func IssuerMint(cur realm, to address, amount int64, ref string) {
	if cur.Previous().Address() != issuer {
		panic("issuer only")
	}
	checkRef(ref)
	if amount <= 0 {
		panic("amount must be positive")
	}
	checkErr(ledger.Mint(to, amount))
	chain.Emit("IssuerMint", "to", to.String(), "amount", ufmt.Sprintf("%d", amount), "ref", ref)
}

// Redeem burns amount of the caller's tUSD against a simulated withdrawal.
func Redeem(cur realm, amount int64, ref string) {
	checkRef(ref)
	if amount <= 0 {
		panic("amount must be positive")
	}
	caller := cur.Previous().Address()
	checkErr(ledger.Burn(caller, amount))
	chain.Emit("Redeem", "from", caller.String(), "amount", ufmt.Sprintf("%d", amount), "ref", ref)
}

// SetIssuer hands the issuer desk to another address. Owner only.
func SetIssuer(cur realm, a address) {
	if cur.Previous().Address() != owner {
		panic("owner only")
	}
	if !a.IsValid() {
		panic("invalid address")
	}
	issuer = a
	chain.Emit("SetIssuer", "issuer", a.String())
}

func Render(path string) string {
	if path == "" {
		var b strings.Builder
		b.WriteString("# Test Dollar (tUSD)\n\n")
		b.WriteString("> **Test token on the Onyx testnet. No value. Not a stablecoin.** Not issued or operated by any regulated firm. Unaudited code. Not an offer.\n\n")
		b.WriteString("Dealing currency of the Charterbook demonstration fund.\n\n")
		b.WriteString(ufmt.Sprintf("- Total supply: %s tUSD\n- Issuer desk: %s\n- Registry key: %s\n- Faucet: %s tUSD per claim, once per %d blocks per address\n\n",
			fmtAmount(TotalSupply()), issuer.String(), sanitize.InlineText(tokenKey), fmtAmount(FaucetAmount), FaucetCooldown))
		b.WriteString("[Claim from the faucet](" + strings.TrimPrefix(selfPath, "gno.land") + "$help&func=Faucet)\n")
		return b.String()
	}
	parts := strings.Split(path, "/")
	if len(parts) == 2 && parts[0] == "balance" {
		a := address(parts[1])
		if !a.IsValid() {
			return "invalid address"
		}
		return fmtAmount(user.BalanceOf(a)) + " tUSD"
	}
	return "404"
}

func fmtAmount(v int64) string {
	f := ufmt.Sprintf("%d", v%1_000_000)
	for len(f) < 6 {
		f = "0" + f
	}
	return ufmt.Sprintf("%d", v/1_000_000) + "." + f
}

func checkRef(ref string) {
	if len(ref) == 0 || len(ref) > maxRefLen {
		panic("ref must be 1 to 64 characters")
	}
}

func checkErr(err error) {
	if err != nil {
		panic(err.Error())
	}
}
