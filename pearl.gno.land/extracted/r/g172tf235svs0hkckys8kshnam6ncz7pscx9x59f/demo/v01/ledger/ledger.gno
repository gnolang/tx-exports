// Package ledger is this token's dedicated storage realm: it owns the
// token balances and allowances (via a gno.land/p/demo/tokens/grc20 token,
// registered with gno.land/r/demo/defi/grc20reg for discoverability), the
// tokenized-by audit trail, and the dynamic attribute map. It holds no
// issuance logic of its own — trade rules, admin gating, and unit
// formatting live in the paired token realm.
//
// Every mutating function here accepts calls ONLY from that paired token
// realm, registered once via SetMainRealm.
package ledger

import (
	"chain"
	"chain/runtime/unsafe"

	"gno.land/p/demo/tokens/grc20"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"

	grc20reg "gno.land/r/demo/defi/grc20reg"
)

var (
	admin address

	// mainRealm is the ONE realm allowed to call every mutating function
	// below: this pair's own token realm.
	mainRealm    address
	mainRealmSet bool

	dynamicAttrs *avl.Tree // key(string) → value(string)
	tokenizedBy  *avl.Tree // address.String() → uint64 (cumulative gross issuance)

	// tok/privateLedger are this token's canonical grc20 identity and
	// balance/allowance store. Both are allocated here (this realm's own
	// `cur`), so this realm is the only one that may mutate privateLedger —
	// see the interrealm storage=authority rule: an object's allocating
	// realm is its sole mutator. `name`/`symbol`/`decimals` here MUST stay
	// in sync with token.gno's TokenName/SKU/UnitDecimals consts.
	tok           *grc20.Token
	privateLedger *grc20.PrivateLedger
)

func init(cur realm) {
	admin = unsafe.OriginCaller()
	dynamicAttrs = avl.NewTree()
	dynamicAttrs.Set("status", "active")
	dynamicAttrs.Set("unit", "DEMO")
	tokenizedBy = avl.NewTree()

	tok, privateLedger = grc20.NewToken("DemoToken01", "DEMO", 4, 0, cur)
	grc20reg.Register(cross(cur), tok, "")
}

// ─── Admin / wiring ─────────────────────────────────────────────────────────────

func SetAdmin(cur realm, newAdmin address) {
	assertAdmin()
	admin = newAdmin
}

func GetAdmin() string { return admin.String() }

// SetMainRealm points this ledger's write access at `m`, this pair's paired
// token realm. Admin-only. Must be called once after both this realm and
// the token realm are deployed, before ANY mutating call here can succeed.
func SetMainRealm(cur realm, m address) {
	assertAdmin()
	mainRealm = m
	mainRealmSet = true
	chain.Emit("MainRealmChanged", "mainRealm", m.String())
}

func GetMainRealm() string {
	if !mainRealmSet {
		return ""
	}
	return mainRealm.String()
}

func assertAdmin() {
	if unsafe.OriginCaller() != admin {
		panic("unauthorized: caller is not the admin")
	}
}

// assertMainRealm authorizes every mutating function below, checked against
// the IMMEDIATE calling realm via unsafe.PreviousRealm() (a stack-walker).
// Safe here because the token realm always calls this ledger directly, with
// no intervening indirection.
func assertMainRealm() {
	if !mainRealmSet {
		panic("main realm not registered")
	}
	if unsafe.PreviousRealm().Address() != mainRealm {
		panic("unauthorized: caller is not the registered main realm")
	}
}

// ─── Dynamic attribute CRUD (main-realm-only) ────────────────────────────────────

func SetDynamicAttr(cur realm, key, value string) {
	assertMainRealm()
	if key == "" {
		panic("key must not be empty")
	}
	dynamicAttrs.Set(key, value)
}

func RemoveDynamicAttr(cur realm, key string) {
	assertMainRealm()
	dynamicAttrs.Remove(key)
}

func GetDynamicAttr(key string) string {
	val, ok := dynamicAttrs.Get(key).(string)
	if !ok {
		return ""
	}
	return val
}

func HasDynamicAttr(key string) bool { return dynamicAttrs.Has(key) }

func DynamicAttrCount() int { return dynamicAttrs.Size() }

// RenderDynamicAttrs returns a Markdown table of every dynamic attribute,
// for the token realm's own Render(path) to embed directly.
func RenderDynamicAttrs() string {
	out := "| Key | Value |\n|:----|:------|\n"
	dynamicAttrs.Iterate("", "", func(key string, value interface{}) bool {
		out += ufmt.Sprintf("| %s | %s |\n", key, value.(string))
		return false
	})
	return out
}

// ─── Balances & allowances (main-realm-only mutations) ────────────────────────────
//
// Every function below is a thin, error-to-panic wrapper around this
// token's *grc20.PrivateLedger — see gno.land/p/demo/tokens/grc20 for the
// underlying balance/allowance/overflow logic (this realm no longer hand-rolls
// any of that itself).

// MintTo credits `amount` base units to `addr`. Called by the token realm
// from TokenizeByPlatform/TokenizeWithVoucher (new issuance).
func MintTo(cur realm, addr address, amount uint64) {
	assertMainRealm()
	if err := privateLedger.Mint(addr, int64(amount)); err != nil {
		panic(err)
	}
}

// BurnFrom debits `amount` base units from `addr`. Called by the token
// realm from Detokenize (retirement).
func BurnFrom(cur realm, addr address, amount uint64) {
	assertMainRealm()
	if err := privateLedger.Burn(addr, int64(amount)); err != nil {
		panic(err)
	}
}

// Transfer moves `amount` base units from `from` to `to` atomically. Called
// by the token realm from Transfer.
func Transfer(cur realm, from, to address, amount uint64) {
	assertMainRealm()
	if err := privateLedger.Transfer(from, to, int64(amount)); err != nil {
		panic(err)
	}
}

// Approve sets `spender`'s allowance over `owner`'s balance. Called by the
// token realm from Approve.
func Approve(cur realm, owner, spender address, amount uint64) {
	assertMainRealm()
	if err := privateLedger.Approve(owner, spender, int64(amount)); err != nil {
		panic(err)
	}
}

// TransferFrom moves `amount` base units from `owner` to `to`, spending
// down `spender`'s allowance atomically. Called by the token realm from
// TransferFrom.
func TransferFrom(cur realm, owner, spender, to address, amount uint64) {
	assertMainRealm()
	if err := privateLedger.TransferFrom(owner, spender, to, int64(amount)); err != nil {
		panic(err)
	}
}

// AddTokenized raises addr's cumulative gross issuance figure by `amount`.
// Called by the token realm from TokenizeByPlatform/TokenizeWithVoucher only.
// This audit trail is this project's own addition — grc20 has no equivalent.
func AddTokenized(cur realm, addr address, amount uint64) {
	assertMainRealm()
	tokenizedBy.Set(addr.String(), TokenizedByOf(addr)+amount)
}

// ─── Queries (plain reads, ungated) ──────────────────────────────────────────────

func BalanceOf(addr address) uint64 { return uint64(tok.BalanceOf(addr)) }

func Allowance(owner, spender address) uint64 { return uint64(tok.Allowance(owner, spender)) }

// TotalSupply is the live circulating supply, in base units — always
// exactly the sum of every balance grc20's PrivateLedger holds.
func TotalSupply() uint64 { return uint64(tok.TotalSupply()) }

// TokenizedByOf returns the CUMULATIVE GROSS amount ever issued to `addr`.
func TokenizedByOf(addr address) uint64 {
	val, ok := tokenizedBy.Get(addr.String()).(uint64)
	if !ok {
		return 0
	}
	return val
}
