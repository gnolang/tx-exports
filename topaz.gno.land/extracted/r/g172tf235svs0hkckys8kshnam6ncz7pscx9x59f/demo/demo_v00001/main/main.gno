// Package main implements a STANDALONE demo token realm: platform-issued
// tokenization, self-service detokenization, and holder-to-holder transfer,
// with admin-settable trade rules and a dynamic-attribute record — the same
// token-lifecycle shape the carbon-credit products use, minus everything
// marketplace-related.
//
// ─── STANDALONE: NO DEPENDENCY ON THE REST OF THIS PROJECT ─────────────────────
//
//	This realm and its paired
//	gno.land/r/g172tf235svs0hkckys8kshnam6ncz7pscx9x59f/demo/demo_v00001/ledger realm import NOTHING
//	else from this repository — no `tokenengine`, no `productinterface`, no
//	`market_vXXXXX`, no `orderbook`. Every trade-rule check, admin gate, and
//	unit-formatting helper that the carbon-credit products get from the
//	shared `gno.land/p/promex/core/tokenengine` package is copied here
//	directly instead, as plain package-level functions and vars, so this
//	pair is fully self-contained: read it, deploy it, and understand it
//	without needing anything else in this repo to exist.
//
// ─── NO MARKETPLACE FUNCTIONS AT ALL ───────────────────────────────────────────
//
//	There is no `ConnectMarket`, no capability value, no `Lock`/`Unlock`/
//	`MarketMove`/`MarketSpend`, and the ledger has no locking layer — this
//	demo only shows Tokenize / Detokenize / Transfer and the read-only
//	queries around them. `LockedOf`/`SpendableOf` don't exist here because
//	nothing ever reserves a balance; `SpendableOf` would just equal
//	`BalanceOf`.
//
// ─── THE LEDGER TRUSTS EXACTLY ONE CALLER: THIS REALM ──────────────────────────
//
//	gno.land/r/g172tf235svs0hkckys8kshnam6ncz7pscx9x59f/demo/demo_v00001/ledger owns the actual token
//	balances, tokenized-by audit trail, and dynamic attributes, and accepts
//	mutating calls ONLY from this realm (registered once via
//	`ledger.SetMainRealm`). Every function below that reads or writes
//	balances or attributes is a thin forwarding call into that ledger.
package main

import (
	"chain"
	"chain/runtime/unsafe"
	"strconv"

	"gno.land/p/nt/ufmt/v0"

	ledger "gno.land/r/g172tf235svs0hkckys8kshnam6ncz7pscx9x59f/demo/demo_v00001/ledger"
)

// ─── Fixed Product Attributes ─────────────────────────────────────────────────

const (
	// SKU is this demo product's unique identifier.
	SKU       = "DEMO_V00001"
	TokenName = "Demo Token V00001"

	// UnitName is the trading unit of this demo product. It is what a
	// "unit" means everywhere in this realm.
	UnitName = "DEMO"

	// UnitDecimals / UnitScale define the base unit: the smallest
	// indivisible slice of UnitName this realm can represent. All amounts
	// are integers in base units.
	UnitDecimals = 4
	UnitScale    = 10000 // 10 ** UnitDecimals
)

// ─── State ────────────────────────────────────────────────────────────────────

var (
	admin address

	// TotalSupply is the live circulating supply: always exactly the sum of
	// every balance held in the ledger. It starts at zero and moves only
	// with Tokenize (+) and Detokenize (-); Transfer nets to zero.
	totalSupply uint64

	// BurnedTotal is the cumulative amount ever retired via Detokenize. It
	// only ever grows.
	burnedTotal uint64

	// Trade rules (BASE UNITS), admin-settable.
	minTradeSize uint64 // smallest tradeable amount
	minIncrement uint64 // amounts must sit on this ladder above minTradeSize
)

func init() {
	admin = unsafe.OriginCaller()
	minTradeSize = UnitScale
	minIncrement = UnitScale
}

// ─── Admin ────────────────────────────────────────────────────────────────────

func SetAdmin(cur realm, newAdmin address) {
	assertAdmin()
	admin = newAdmin
}

func GetAdmin() string { return admin.String() }

// Address returns this realm's own on-chain address — what this realm's
// admin passes to ledger.SetMainRealm.
func Address() string { return unsafe.CurrentRealm().Address().String() }

// LedgerAddress returns this pair's ledger realm's own on-chain address,
// once that ledger has registered this realm via SetMainRealm (empty string
// until then).
func LedgerAddress() string { return ledger.GetMainRealm() }

// ─── Trade rules ──────────────────────────────────────────────────────────────

// SetTradeRules configures the product's minimum trade size and minimum
// increment, both in BASE UNITS. Admin-only.
//
//	1 unit minimum, 1 unit increment   → SetTradeRules(10000, 10000)
//	1 unit minimum, 0.2 unit increment → SetTradeRules(10000, 2000)
//
// The rules apply to EVERY amount that moves: Tokenize, Detokenize, and
// Transfer.
func SetTradeRules(cur realm, newMinTradeSize, newMinIncrement uint64) {
	assertAdmin()
	if newMinTradeSize == 0 {
		panic("minTradeSize must be greater than 0")
	}
	if newMinIncrement == 0 {
		panic("minIncrement must be greater than 0")
	}
	minTradeSize = newMinTradeSize
	minIncrement = newMinIncrement

	chain.Emit("TradeRulesUpdated",
		"sku", SKU,
		"minTradeSize", FormatUnits(newMinTradeSize),
		"minIncrement", FormatUnits(newMinIncrement),
	)
}

func MinTradeSize() uint64 { return minTradeSize }
func MinIncrement() uint64 { return minIncrement }

// IsValidTradeAmount reports whether `amount` (base units) satisfies the
// product's trade rules: at least minTradeSize, and on the minIncrement
// ladder above it.
func IsValidTradeAmount(amount uint64) bool {
	if amount == 0 || amount < minTradeSize {
		return false
	}
	if minIncrement == 0 {
		return false
	}
	return (amount-minTradeSize)%minIncrement == 0
}

// CheckTradeAmount panics with a descriptive message unless `amount`
// satisfies the product's trade rules. Every amount-moving entry point
// calls it.
func CheckTradeAmount(amount uint64) {
	if amount == 0 {
		panic("amount must be greater than 0")
	}
	if amount < minTradeSize {
		panic("amount below minimum trade size: min " +
			FormatUnits(minTradeSize) + " " + UnitName +
			", got " + FormatUnits(amount) + " " + UnitName)
	}
	if (amount-minTradeSize)%minIncrement != 0 {
		panic("amount not on the increment ladder: min " +
			FormatUnits(minTradeSize) + " " + UnitName +
			" plus a multiple of " + FormatUnits(minIncrement) + " " + UnitName +
			", got " + FormatUnits(amount) + " " + UnitName)
	}
}

// ─── Dynamic Attribute CRUD ───────────────────────────────────────────────────

func SetDynamicAttr(cur realm, key, value string) {
	if unsafe.OriginCaller() != address(GetAdmin()) {
		panic("unauthorized: caller is not the admin")
	}
	ledger.SetDynamicAttr(cross(cur), key, value)
}

func RemoveDynamicAttr(cur realm, key string) {
	if unsafe.OriginCaller() != address(GetAdmin()) {
		panic("unauthorized: caller is not the admin")
	}
	ledger.RemoveDynamicAttr(cross(cur), key)
}

func GetDynamicAttr(key string) string { return ledger.GetDynamicAttr(key) }

func HasDynamicAttr(key string) bool { return ledger.HasDynamicAttr(key) }

func DynamicAttrCount() int { return ledger.DynamicAttrCount() }

// ─── Tokenization (admin-only, issued straight to the holder) ─────────────────

// Tokenize mints `amount` base units DIRECTLY into `holder`'s wallet and
// raises the circulating supply by the same amount.
//
// ADMIN-ONLY. Ownership is immediate: the tokens are credited to `holder` in
// this same transaction, so there is no window in which the admin holds
// them.
//
// There is NO on-chain supply ceiling. `amount` is in BASE UNITS and must
// satisfy the product's trade rules.
func Tokenize(cur realm, holder address, amount uint64) {
	if unsafe.OriginCaller() != address(GetAdmin()) {
		panic("unauthorized: caller is not the admin")
	}
	if holder == address("") {
		panic("holder must not be empty")
	}
	CheckTradeAmount(amount)

	ledger.MintTo(cross(cur), holder, amount) // credited straight to the holder
	ledger.AddTokenized(cross(cur), holder, amount)
	totalSupply += amount

	chain.Emit("Tokenized",
		"sku", SKU,
		"unit", UnitName,
		"amount", strconv.FormatUint(amount, 10),
		"amountFormatted", FormatUnits(amount),
		"holder", holder.String(),
		"recipient", holder.String(),
		"issuer", GetAdmin(),
		"totalSupply", strconv.FormatUint(totalSupply, 10),
		"tokenizedByHolder", strconv.FormatUint(TokenizedBy(holder), 10),
	)
}

// Detokenize burns `amount` base units from the CALLER's own wallet,
// lowering the circulating supply.
//
// HOLDER-ONLY and self-service: there is no holder parameter, so an address
// can only ever retire its own tokens. Not even the admin can retire someone
// else's.
//
// `deliveryAddr` is an arbitrary off-chain destination string (e.g. for a
// retirement certificate) — this demo does not interpret it.
func Detokenize(cur realm, amount uint64, deliveryAddr string) {
	if deliveryAddr == "" {
		panic("deliveryAddr must not be empty")
	}
	CheckTradeAmount(amount)

	holder := unsafe.OriginCaller()
	if BalanceOf(holder) < amount {
		panic("amount exceeds balance")
	}
	ledger.BurnFrom(cross(cur), holder, amount)
	totalSupply -= amount
	burnedTotal += amount

	chain.Emit("Detokenized",
		"sku", SKU,
		"unit", UnitName,
		"amount", strconv.FormatUint(amount, 10),
		"amountFormatted", FormatUnits(amount),
		"holder", holder.String(),
		"redeemer", holder.String(),
		"deliveryAddr", deliveryAddr,
		"totalSupply", strconv.FormatUint(totalSupply, 10),
		"burnedTotal", strconv.FormatUint(burnedTotal, 10),
	)
}

// ─── Token Operations ─────────────────────────────────────────────────────────

// Transfer sends `amount` base units from the caller to `to`. The amount
// must satisfy the product's trade rules.
func Transfer(cur realm, to address, amount uint64) {
	CheckTradeAmount(amount)
	from := unsafe.OriginCaller()
	if from == to {
		panic("cannot transfer to self")
	}
	if BalanceOf(from) < amount {
		panic("amount exceeds balance")
	}
	ledger.BurnFrom(cross(cur), from, amount)
	ledger.MintTo(cross(cur), to, amount)

	chain.Emit("Transfer",
		"sku", SKU,
		"unit", UnitName,
		"from", from.String(),
		"to", to.String(),
		"amount", strconv.FormatUint(amount, 10),
		"amountFormatted", FormatUnits(amount),
	)
}

// ─── Token Queries ────────────────────────────────────────────────────────────

// TotalSupply is the live circulating supply, in base units. It starts at
// zero, rises with Tokenize, and falls with Detokenize.
func TotalSupply() uint64 { return totalSupply }

// BurnedTotal is the cumulative amount ever retired via Detokenize.
func BurnedTotal() uint64 { return burnedTotal }

func BalanceOf(addr address) uint64 { return ledger.BalanceOf(addr) }

// TokenizedBy returns the CUMULATIVE GROSS amount ever issued to `addr`. It
// never decreases (transfers and retirements do not reduce it).
func TokenizedBy(addr address) uint64 { return ledger.TokenizedByOf(addr) }

func SKU_() string       { return SKU }
func TokenName_() string { return TokenName }
func UnitName_() string  { return UnitName }
func UnitScale_() uint64 { return UnitScale }

// ─── Unit formatting ──────────────────────────────────────────────────────────

// FormatUnits renders base units as a decimal string in UnitName terms:
// 10000 → "1", 2000 → "0.2". Trailing zeros are trimmed.
func FormatUnits(base uint64) string {
	whole := base / UnitScale
	frac := base % UnitScale
	out := strconv.FormatUint(whole, 10)
	if frac == 0 {
		return out
	}
	fs := strconv.FormatUint(frac, 10)
	for len(fs) < UnitDecimals {
		fs = "0" + fs
	}
	for len(fs) > 0 && fs[len(fs)-1] == '0' {
		fs = fs[:len(fs)-1]
	}
	return out + "." + fs
}

// ParseUnits converts a decimal string in UnitName terms to base units:
// "1" → 10000, "0.2" → 2000. Panics on malformed input or on more decimal
// places than the product supports, rather than silently rounding.
func ParseUnits(s string) uint64 {
	if s == "" {
		panic("malformed amount: empty")
	}
	intPart := s
	fracPart := ""
	dot := -1
	for i := 0; i < len(s); i++ {
		if s[i] == '.' {
			if dot >= 0 {
				panic("malformed amount: multiple decimal points in " + s)
			}
			dot = i
		}
	}
	if dot >= 0 {
		intPart = s[:dot]
		fracPart = s[dot+1:]
	}
	if intPart == "" {
		panic("malformed amount: no integer part in " + s)
	}
	assertDigits(intPart, s)
	if len(fracPart) > UnitDecimals {
		panic("too many decimal places for " + UnitName + " (max " +
			strconv.Itoa(UnitDecimals) + "): " + s)
	}
	whole, err := strconv.ParseUint(intPart, 10, 64)
	if err != nil {
		panic("malformed amount: out of range in " + s)
	}
	frac := uint64(0)
	if fracPart != "" {
		assertDigits(fracPart, s)
		padded := fracPart
		for len(padded) < UnitDecimals {
			padded += "0"
		}
		frac, err = strconv.ParseUint(padded, 10, 64)
		if err != nil {
			panic("malformed amount: bad fraction in " + s)
		}
	}
	return whole*UnitScale + frac
}

func assertDigits(part, whole string) {
	for i := 0; i < len(part); i++ {
		if part[i] < '0' || part[i] > '9' {
			panic("malformed amount: non-numeric in " + whole)
		}
	}
}

// ─── Internal helpers ─────────────────────────────────────────────────────────

func assertAdmin() {
	if unsafe.OriginCaller() != admin {
		panic("unauthorized: caller is not the admin")
	}
}

// ─── Render ───────────────────────────────────────────────────────────────────

func Render(path string) string {
	out := "# 🧪 Demo Token — " + SKU + "\n\n"

	out += "## Token\n\n"
	out += "| Field          | Value |\n"
	out += "|:---------------|:------|\n"
	out += "| Name           | " + TokenName + " |\n"
	out += "| Trading unit   | " + UnitName + " |\n"
	out += ufmt.Sprintf("| Unit decimals  | %d |\n", UnitDecimals)
	out += "| Total supply   | " + FormatUnits(totalSupply) + " " + UnitName + " |\n"
	out += "| Retired to date| " + FormatUnits(burnedTotal) + " " + UnitName + " |\n"

	out += "\n_This is a standalone demo realm: no marketplace integration, no\n"
	out += "dependency on any other realm in this project. It only demonstrates\n"
	out += "tokenization, detokenization, and holder-to-holder transfer._\n"

	out += "\n## Trade Rules\n\n"
	out += "| Field          | Value |\n"
	out += "|:---------------|:------|\n"
	out += "| Min trade size | " + FormatUnits(minTradeSize) + " " + UnitName + " |\n"
	out += "| Min increment  | " + FormatUnits(minIncrement) + " " + UnitName + " |\n"

	out += "\n## Dynamic Attributes\n\n"
	out += ledger.RenderDynamicAttrs()

	out += ufmt.Sprintf("\n_Total dynamic attributes: %d_\n", DynamicAttrCount())
	out += "\n---\n_Deployed on gno.land · standalone demo realm_\n"
	return out
}
