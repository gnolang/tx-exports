// token_factory — Reusable GRC20 Token Factory
// Lets any developer create multiple GRC20 tokens in one realm without writing
// a new contract each time. Each token gets its own symbol, supply, and admin.
//
// Usage:
//   CreateToken("MyToken", "MTK", 6, 1000000, 0)    // create token + mint initial supply
//   Mint("MTK", recipientAddr, 500000)               // mint more (admin only)
//   Transfer("MTK", recipientAddr, 100000)            // transfer tokens
//   BalanceOf("MTK", someAddr)                         // check balance
//   Burn("MTK", someAddr, 50000)                      // burn tokens (admin only)
//   Faucet("MTK")                                      // claim free tokens
//
// Based on the official gno.land/p/demo/tokens/grc20 library.
package token_factory

import (
	"strings"

	"gno.land/p/demo/tokens/grc20"
	"gno.land/p/nt/ownable/v0"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/demo/defi/grc20reg"
)

// TokenInstance holds a single GRC20 token created via the factory.
type TokenInstance struct {
	Token         *grc20.Token
	Ledger        *grc20.PrivateLedger
	Teller        grc20.Teller
	Ownable       *ownable.Ownable
	FaucetAmount  int64 // per-request faucet amount; 0 = disabled
}

// All tokens created via this factory, keyed by symbol.
var tokens map[string]*TokenInstance

func init() {
	tokens = make(map[string]*TokenInstance)
}

// === Token Creation ===

// CreateToken creates a new GRC20 token. Caller becomes the admin.
//   - name:      human-readable name (e.g. "My Token")
//   - symbol:    ticker symbol (e.g. "MTK"), must be unique
//   - decimals:  decimal precision (e.g. 6 for micro-units)
//   - initialMint: amount to mint to admin at creation (0 = no initial mint)
//   - faucetAmount: per-call faucet distribution amount (0 = disabled)
func CreateToken(cur realm, name, symbol string, decimals int, initialMint, faucetAmount int64) string {
	// Validate
	if name == "" {
		panic("name must not be empty")
	}
	if symbol == "" {
		panic("symbol must not be empty")
	}
	if decimals < 0 || decimals > 18 {
		panic("decimals must be 0-18")
	}
	if tokens[symbol] != nil {
		panic("token with symbol '" + symbol + "' already exists")
	}

	caller := cur.Previous().Address()

	// Create GRC20 token via official library
	tok, ledger := grc20.NewToken(name, symbol, decimals, 0, cur)
	teller := ledger.CallerTeller()

	// Set admin ownership
	own := ownable.NewWithAddress(caller)

	// Mint initial supply to admin
	if initialMint > 0 {
		ledger.Mint(caller, initialMint)
	}

	// Store instance
	tokens[symbol] = &TokenInstance{
		Token:        tok,
		Ledger:       ledger,
		Teller:       teller,
		Ownable:      own,
		FaucetAmount: faucetAmount,
	}

	// Register in GRC20 registry for discoverability
	grc20reg.Register(cross(cur), tok, symbol)

	return symbol + " created successfully"
}

// === Token Info (read-only) ===

// TokenExists checks if a token with the given symbol exists.
func TokenExists(symbol string) bool {
	return tokens[symbol] != nil
}

// TokenCount returns the number of tokens created.
func TokenCount() int {
	return len(tokens)
}

// ListTokens returns all token symbols.
func ListTokens() []string {
	syms := make([]string, 0, len(tokens))
	for sym := range tokens {
		syms = append(syms, sym)
	}
	return syms
}

// GetName returns the name of a token.
func GetName(symbol string) string {
	inst := mustGet(symbol)
	return inst.Token.GetName()
}

// GetSymbol returns the symbol of a token.
func GetSymbol(symbol string) string {
	inst := mustGet(symbol)
	return inst.Token.GetSymbol()
}

// GetDecimals returns the decimals of a token.
func GetDecimals(symbol string) int {
	inst := mustGet(symbol)
	return inst.Token.GetDecimals()
}

// GetAdmin returns the admin/owner address of a token.
func GetAdmin(symbol string) string {
	inst := mustGet(symbol)
	return inst.Ownable.Owner().String()
}

// TotalSupply returns the total supply of a token.
func TotalSupply(symbol string) int64 {
	inst := mustGet(symbol)
	return inst.Teller.TotalSupply()
}

// BalanceOf returns the balance of an address for a token.
func BalanceOf(symbol string, owner address) int64 {
	inst := mustGet(symbol)
	return inst.Teller.BalanceOf(owner)
}

// Allowance returns the allowance a spender has from an owner.
func Allowance(symbol string, owner, spender address) int64 {
	inst := mustGet(symbol)
	return inst.Teller.Allowance(owner, spender)
}

// === Token Operations (state-changing, need realm) ===

// Transfer moves tokens from caller to recipient.
func Transfer(cur realm, symbol string, to address, amount int64) {
	inst := mustGet(symbol)
	checkErr(inst.Teller.Transfer(0, cur, to, amount))
}

// Approve allows a spender to spend up to `amount` of caller's tokens.
func Approve(cur realm, symbol string, spender address, amount int64) {
	inst := mustGet(symbol)
	checkErr(inst.Teller.Approve(0, cur, spender, amount))
}

// TransferFrom moves tokens from `from` to `to` using allowance.
func TransferFrom(cur realm, symbol string, from, to address, amount int64) {
	inst := mustGet(symbol)
	checkErr(inst.Teller.TransferFrom(0, cur, from, to, amount))
}

// Mint creates new tokens. Only admin can call this.
func Mint(cur realm, symbol string, to address, amount int64) {
	inst := mustGet(symbol)
	inst.Ownable.AssertOwnedBy(cur.Previous().Address())
	checkErr(inst.Ledger.Mint(to, amount))
}

// Burn destroys tokens from a given address. Only admin can call this.
func Burn(cur realm, symbol string, from address, amount int64) {
	inst := mustGet(symbol)
	inst.Ownable.AssertOwnedBy(cur.Previous().Address())
	checkErr(inst.Ledger.Burn(from, amount))
}

// Faucet distributes free tokens for testing.
// Amount is set at token creation via faucetAmount. 0 = disabled.
func Faucet(cur realm, symbol string) {
	inst := mustGet(symbol)
	if inst.FaucetAmount == 0 {
		panic("faucet disabled for this token")
	}
	caller := cur.Previous().Address()
	checkErr(inst.Ledger.Mint(caller, inst.FaucetAmount))
}

// === Render ===

func Render(_ string) string {
	b := strings.Builder{}
	b.WriteString("# GRC20 Token Factory\n\n")
	b.WriteString("Create and manage multiple GRC20 tokens in one realm.\n\n")
	b.WriteString(ufmt.Sprintf("**Tokens Created:** %d\n\n", len(tokens)))

	b.WriteString("## How to Use\n\n")
	b.WriteString("```gno\n")
	b.WriteString("// Create a new token\n")
	b.WriteString("CreateToken(\"My Token\", \"MTK\", 6, 1000000, 0)\n\n")
	b.WriteString("// Mint more tokens (admin only)\n")
	b.WriteString("Mint(\"MTK\", recipientAddr, 500000)\n\n")
	b.WriteString("// Transfer tokens\n")
	b.WriteString("Transfer(\"MTK\", recipientAddr, 100000)\n\n")
	b.WriteString("// Check balance\n")
	b.WriteString("BalanceOf(\"MTK\", someAddr)\n\n")
	b.WriteString("// Enable faucet (set at creation)\n")
	b.WriteString("Faucet(\"MTK\")\n")
	b.WriteString("```\n\n")

	if len(tokens) > 0 {
		b.WriteString("## Tokens\n\n")
		b.WriteString("| Symbol | Name | Decimals | Supply | Admin |\n")
		b.WriteString("|--------|------|----------|---------|-------|\n")
		for sym, inst := range tokens {
			supply := inst.Teller.TotalSupply()
			dec := inst.Token.GetDecimals()
			displaySupply := supply
			if dec > 0 {
				displaySupply = supply / pow10(dec)
			}
			b.WriteString(ufmt.Sprintf("| %s | %s | %d | %d | %s |\n",
				sym,
				inst.Token.GetName(),
				dec,
				displaySupply,
				truncateAddr(inst.Ownable.Owner().String()),
			))
		}
	}

	b.WriteString("\n## Functions\n\n")
	b.WriteString("| Function | Description | Admin Only |\n")
	b.WriteString("|----------|-------------|------------|\n")
	b.WriteString("| `CreateToken(name, symbol, decimals, initialMint, faucetAmount)` | Create a new GRC20 token | No |\n")
	b.WriteString("| `Mint(symbol, to, amount)` | Mint new tokens | Yes |\n")
	b.WriteString("| `Burn(symbol, from, amount)` | Burn tokens | Yes |\n")
	b.WriteString("| `Transfer(symbol, to, amount)` | Transfer tokens | No |\n")
	b.WriteString("| `Approve(symbol, spender, amount)` | Approve spender | No |\n")
	b.WriteString("| `TransferFrom(symbol, from, to, amount)` | Transfer via allowance | No |\n")
	b.WriteString("| `Faucet(symbol)` | Claim free tokens | No |\n")
	b.WriteString("| `BalanceOf(symbol, addr)` | Check balance | No |\n")
	b.WriteString("| `TotalSupply(symbol)` | Get total supply | No |\n")
	b.WriteString("| `ListTokens()` | List all token symbols | No |\n")

	return b.String()
}

// === Helpers ===

func mustGet(symbol string) *TokenInstance {
	inst := tokens[symbol]
	if inst == nil {
		panic("token '" + symbol + "' not found")
	}
	return inst
}

func checkErr(err error) {
	if err != nil {
		panic(err)
	}
}

func truncateAddr(addr string) string {
	if len(addr) <= 12 {
		return addr
	}
	return addr[:8] + "..." + addr[len(addr)-4:]
}

func pow10(n int) int64 {
	result := int64(1)
	for i := 0; i < n; i++ {
		result *= 10
	}
	return result
}
