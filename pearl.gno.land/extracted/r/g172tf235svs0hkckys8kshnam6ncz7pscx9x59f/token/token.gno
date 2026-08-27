// Package token implements a demo tokenized asset: admin-settable trade
// rules, a dynamic-attribute record, platform-issued and
// voucher-authorized tokenization, self-service detokenization, and a
// GRC-20-shaped Transfer/Approve/Allowance/TransferFrom surface.
//
// Trade-rule validation, voucher verification, and unit formatting are
// implemented directly in this realm. The actual token ledger — balances,
// the tokenized-by audit trail, and dynamic attributes — lives in this
// realm's own paired ledger realm, which trusts ONLY this realm
// (registered once via SetMainRealm).
//
// There is no marketplace integration and no trading-fee configuration:
// those concepts only apply once a marketplace is settling a trade, which
// this realm never does — BalanceOf is always the full, freely-movable
// amount.
package token

import (
	"crypto/ed25519"
	"crypto/sha256"
	"strconv"
	"time"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"

	"chain"
	"chain/runtime/unsafe"

	ledger "gno.land/r/g172tf235svs0hkckys8kshnam6ncz7pscx9x59f/ledger"
)

// ─── Fixed Product Attributes ─────────────────────────────────────────────────

const (
	// SKU is this token's unique identifier.
	SKU       = "DEMO"
	TokenName = "Demo Token"

	// UnitName is the trading unit of this token. It is what a "unit"
	// means everywhere in this realm.
	UnitName = "UNIT"

	// UnitDecimals / UnitScale define the base unit: the smallest
	// indivisible slice of UnitName this realm can represent. All amounts
	// are integers in base units.
	UnitDecimals = 4
	UnitScale    = 10000 // 10 ** UnitDecimals

	// DefaultVoucherValidityMs is how long a newly-issued voucher stays
	// valid after its issuedAtMs timestamp, until the admin configures
	// otherwise — 60 seconds. See the voucher section below.
	DefaultVoucherValidityMs = 60000
)

// ─── State ────────────────────────────────────────────────────────────────────

var (
	admin address

	// totalSupply is the live circulating supply: always exactly the sum of
	// every balance held in the ledger. It starts at zero and moves only
	// with TokenizeByPlatform/TokenizeWithVoucher (+) and Detokenize (-);
	// Transfer and TransferFrom net to zero.
	totalSupply uint64

	// burnedTotal is the cumulative amount ever retired via Detokenize. It
	// only ever grows.
	burnedTotal uint64

	// Trade rules (BASE UNITS), admin-settable.
	minTradeSize uint64 // smallest tradeable amount
	minIncrement uint64 // amounts must sit on this ladder above minTradeSize

	// allowances backs Approve/Allowance/TransferFrom (the GRC-20
	// spender-authorization surface). Keyed by
	// owner.String()+":"+spender.String(); an absent key means an
	// allowance of 0, never a panic.
	allowances *avl.Tree

	// ── Voucher-based tokenization authorization — see the section below ──

	// voucherSigner is the admin's DEDICATED ed25519 public key for
	// authorizing TokenizeWithVoucher — deliberately NOT the realm's own
	// admin gno account key (secp256k1; Gno's crypto/ecdsa is not yet
	// available for on-realm verification). Empty disables voucher issuance.
	voucherSigner []byte

	// voucherValidityMs is how long a signed voucher remains valid after
	// its issuedAtMs timestamp. Admin-settable via SetVoucherValidityMs.
	voucherValidityMs int64

	// usedVoucherNonces replay-protects verifyAndConsumeVoucher:
	// nonce(string) → expiresAtMs(int64), so expired entries can be pruned
	// instead of the tree growing forever.
	usedVoucherNonces *avl.Tree
)

func init() {
	admin = unsafe.OriginCaller()
	minTradeSize = UnitScale
	minIncrement = UnitScale
	voucherValidityMs = DefaultVoucherValidityMs
	allowances = avl.NewTree()
	usedVoucherNonces = avl.NewTree()
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
// once that ledger has registered this realm via SetMainRealm (empty
// string until then).
func LedgerAddress() string { return ledger.GetMainRealm() }

func assertAdmin() {
	if unsafe.OriginCaller() != admin {
		panic("unauthorized: caller is not the admin")
	}
}

// ─── Trade rules ──────────────────────────────────────────────────────────────

// SetTradeRules configures the token's minimum trade size and minimum
// increment, both in BASE UNITS. Admin-only.
//
//	1 unit minimum, 1 unit increment   → SetTradeRules(10000, 10000)
//	1 unit minimum, 0.2 unit increment → SetTradeRules(10000, 2000)
//
// The rules apply to EVERY amount that moves: TokenizeByPlatform,
// TokenizeWithVoucher, Detokenize, Transfer, and TransferFrom.
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
// token's trade rules: at least minTradeSize, and on the minIncrement
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
// satisfies the token's trade rules. Every amount-moving entry point calls
// it.
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

// ─── Tokenization (admin-direct, or user-initiated against an admin voucher) ───

// TokenizeByPlatform mints `amount` base units DIRECTLY into `holder`'s
// wallet and raises the circulating supply by the same amount.
//
// ADMIN-ONLY. Ownership is immediate: the tokens are credited to `holder` in
// this same transaction, so there is no window in which the admin holds
// them.
//
// There is NO on-chain supply ceiling. `amount` is in BASE UNITS and must
// satisfy the token's trade rules.
//
// See TokenizeWithVoucher below for the alternative, user-paid issuance path
// that authorizes off-chain instead of requiring this admin transaction.
func TokenizeByPlatform(cur realm, holder address, amount uint64) {
	if unsafe.OriginCaller() != address(GetAdmin()) {
		panic("unauthorized: caller is not the admin")
	}
	if holder == address("") {
		panic("holder must not be empty")
	}
	CheckTradeAmount(amount)

	doTokenize(cur, holder, amount, "direct", "")
}

// ─── Voucher-authorized tokenization ───────────────────────────────────────────
//
// The admin signs a one-time voucher OFF-CHAIN with its dedicated ed25519
// key (SetVoucherSigner below), hands `(issuedAtMs, nonce, sig)` to the
// intended holder out of band (zero gas, zero tx), and the holder — or
// anyone relaying on the holder's behalf, since the mint always lands on
// `holder`, never the caller — submits it on-chain within
// VoucherValidityMs, paying that one transaction's gas.

// SetVoucherSigner sets/rotates/disables the ed25519 public key that
// authorizes TokenizeWithVoucher. Admin-only.
func SetVoucherSigner(cur realm, pubKey []byte) {
	assertAdmin()
	if len(pubKey) != 0 && len(pubKey) != 32 { // ed25519 public keys are always 32 bytes
		panic("pubKey must be exactly 32 bytes (ed25519), or empty to disable voucher issuance")
	}
	voucherSigner = pubKey
}

// HasVoucherSigner reports whether voucher-based issuance is currently enabled.
func HasVoucherSigner() bool { return len(voucherSigner) != 0 }

// SetVoucherValidityMs changes how long a NEWLY-issued voucher stays valid
// after its issuedAtMs timestamp. Admin-only. Does not retroactively affect
// vouchers already consumed.
func SetVoucherValidityMs(cur realm, ms int64) {
	assertAdmin()
	if ms <= 0 {
		panic("voucher validity must be greater than 0ms")
	}
	voucherValidityMs = ms
}

// VoucherValidityMs returns the CURRENT voucher validity window, in milliseconds.
func VoucherValidityMs() int64 { return voucherValidityMs }

// IsVoucherUsed reports whether `nonce` is CURRENTLY on record as consumed.
func IsVoucherUsed(nonce string) bool { return usedVoucherNonces.Has(nonce) }

// voucherMessage reconstructs the exact bytes an off-chain signer must sign
// for a voucher on this realm's own pkgPath, issued at `issuedAtMs` (Unix
// milliseconds):
//
//	sha256(`{"realm":"<pkgPath>","holder":"<holder>","amount":<amount>,"issuedAt":<issuedAtMs>,"nonce":"<nonce>"}`)
//
// FIELD ORDER AND FORMAT ARE PART OF THE PROTOCOL — an off-chain signer must
// match this exactly, byte-for-byte.
func voucherMessage(pkgPath string, holder address, amount uint64, issuedAtMs int64, nonce string) []byte {
	h := sha256.Sum256([]byte(
		`{"realm":"` + pkgPath +
			`","holder":"` + holder.String() +
			`","amount":` + strconv.FormatUint(amount, 10) +
			`,"issuedAt":` + strconv.FormatInt(issuedAtMs, 10) +
			`,"nonce":"` + nonce + `"}`,
	))
	return h[:]
}

// TokenizeWithVoucher mints `amount` base units to `holder`, authorized by
// an admin-signed voucher instead of a live admin transaction (see the
// section doc above). `issuedAtMs` is a Unix MILLISECOND timestamp (when
// the admin signed it, not a chain height) — the voucher is valid for
// VoucherValidityMs() milliseconds after that. `nonce` must be unique per
// voucher — reusing one panics, even against a resubmitted but
// otherwise-valid voucher. Callable by anyone: the mint always lands on
// `holder`, never the caller, so a relayer may submit on the holder's behalf.
func TokenizeWithVoucher(cur realm, holder address, amount uint64, issuedAtMs int64, nonce string, sig []byte) {
	verifyAndConsumeVoucher(unsafe.CurrentRealm().PkgPath(), holder, amount, issuedAtMs, nonce, sig)
	CheckTradeAmount(amount)

	doTokenize(cur, holder, amount, "voucher", nonce)
}

// verifyAndConsumeVoucher checks a voucher — signer configured, holder/nonce
// non-empty, not expired, nonce not already used, signature valid — and,
// ONLY if every check passes, marks the nonce used. Panics (never returns
// false) so a caller can't accidentally ignore a failure. Every call also
// prunes every expired entry from the replay-protection tree first,
// regardless of whether THIS voucher itself checks out, so the tree never
// grows without bound.
func verifyAndConsumeVoucher(pkgPath string, holder address, amount uint64, issuedAtMs int64, nonce string, sig []byte) {
	nowMs := time.Now().UnixMilli()
	pruneExpiredVouchers(nowMs)

	if !HasVoucherSigner() {
		panic("voucher issuance not enabled")
	}
	if holder == address("") {
		panic("holder must not be empty")
	}
	if nonce == "" {
		panic("nonce must not be empty")
	}
	expiresAtMs := issuedAtMs + voucherValidityMs
	if nowMs > expiresAtMs {
		panic("approval expired")
	}
	if IsVoucherUsed(nonce) {
		panic("approval already used")
	}
	if !ed25519.Verify(voucherSigner, voucherMessage(pkgPath, holder, amount, issuedAtMs, nonce), sig) {
		panic("invalid approval signature")
	}
	usedVoucherNonces.Set(nonce, expiresAtMs) // effects BEFORE the mint
}

// pruneExpiredVouchers removes every usedVoucherNonces entry whose validity
// window has passed as of `nowMs`. avl.Tree forbids mutating while
// iterating, so this collects the expired keys in a read-only pass first,
// then removes them in a second pass.
func pruneExpiredVouchers(nowMs int64) {
	var expired []string
	usedVoucherNonces.Iterate("", "", func(key string, value interface{}) bool {
		if expiresAtMs, ok := value.(int64); ok && nowMs > expiresAtMs {
			expired = append(expired, key)
		}
		return false
	})
	for _, key := range expired {
		usedVoucherNonces.Remove(key)
	}
}

// doTokenize is the shared minting body for both TokenizeByPlatform and
// TokenizeWithVoucher — both have already finished their own authorization
// and trade-rule checks by the time they call this. `method`/`nonce` are
// purely for the emitted event's audit trail ("direct"/"" or
// "voucher"/<nonce>).
func doTokenize(cur realm, holder address, amount uint64, method, nonce string) {
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
		"method", method,
		"nonce", nonce,
		"totalSupply", strconv.FormatUint(totalSupply, 10),
		"tokenizedByHolder", strconv.FormatUint(TokenizedBy(holder), 10),
	)
}

// ─── Detokenize (retire tokens) ────────────────────────────────────────────────

// Detokenize burns `amount` base units from the CALLER's own wallet,
// lowering the circulating supply.
//
// HOLDER-ONLY and self-service: there is no holder parameter, so an address
// can only ever retire its own tokens. Not even the admin can retire someone
// else's.
//
// `deliveryAddr` is an arbitrary off-chain destination string (e.g. for a
// retirement certificate) — this realm does not interpret it.
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
// must satisfy the token's trade rules.
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

// Approve authorizes `spender` to move up to `amount` base units out of the
// caller's balance via TransferFrom. Overwrites any previous allowance for
// this owner/spender pair — it does not add to it (standard GRC-20 semantics).
func Approve(cur realm, spender address, amount uint64) {
	owner := unsafe.OriginCaller()
	allowances.Set(allowanceKey(owner, spender), amount)

	chain.Emit("Approval",
		"sku", SKU,
		"owner", owner.String(),
		"spender", spender.String(),
		"amount", strconv.FormatUint(amount, 10),
	)
}

// Allowance returns the remaining amount `spender` may move out of `owner`'s
// balance via TransferFrom. An unset pair returns 0; it never panics.
func Allowance(owner, spender address) uint64 {
	v, ok := allowances.Get(allowanceKey(owner, spender)).(uint64)
	if !ok {
		return 0
	}
	return v
}

// TransferFrom moves `amount` base units from `from` to `to`, spending down
// the CALLER's allowance over `from`'s balance by the same amount. Subject
// to the same trade-rule and balance checks as Transfer.
func TransferFrom(cur realm, from, to address, amount uint64) {
	CheckTradeAmount(amount)
	spender := unsafe.OriginCaller()
	key := allowanceKey(from, spender)
	remaining, _ := allowances.Get(key).(uint64)
	if remaining < amount {
		panic("amount exceeds allowance")
	}
	if BalanceOf(from) < amount {
		panic("amount exceeds balance")
	}
	allowances.Set(key, remaining-amount)
	ledger.BurnFrom(cross(cur), from, amount)
	ledger.MintTo(cross(cur), to, amount)

	chain.Emit("Transfer",
		"sku", SKU,
		"unit", UnitName,
		"from", from.String(),
		"to", to.String(),
		"amount", strconv.FormatUint(amount, 10),
		"amountFormatted", FormatUnits(amount),
		"spender", spender.String(),
	)
}

// allowanceKey is the avl.Tree key for an owner/spender allowance pair.
func allowanceKey(owner, spender address) string { return owner.String() + ":" + spender.String() }

// ─── Token Queries ────────────────────────────────────────────────────────────

// TotalSupply is the live circulating supply, in base units. It starts at
// zero, rises with TokenizeByPlatform/TokenizeWithVoucher, and falls with
// Detokenize.
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

// GetName / GetSymbol / GetDecimals mirror TokenName_/SKU_/UnitDecimals
// under the standard token-metadata getter names.
func GetName() string   { return TokenName }
func GetSymbol() string { return SKU }
func GetDecimals() uint { return uint(UnitDecimals) }

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
// places than the token supports, rather than silently rounding.
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
	out += ufmt.Sprintf("| Voucher issuance enabled | %t |\n", HasVoucherSigner())

	out += "\n## Trade Rules\n\n"
	out += "| Field          | Value |\n"
	out += "|:---------------|:------|\n"
	out += "| Min trade size | " + FormatUnits(minTradeSize) + " " + UnitName + " |\n"
	out += "| Min increment  | " + FormatUnits(minIncrement) + " " + UnitName + " |\n"

	out += "\n## Dynamic Attributes\n\n"
	out += ledger.RenderDynamicAttrs()

	out += ufmt.Sprintf("\n_Total dynamic attributes: %d_\n", DynamicAttrCount())
	out += "\n---\n_Deployed on gno.land_\n"
	return out
}
