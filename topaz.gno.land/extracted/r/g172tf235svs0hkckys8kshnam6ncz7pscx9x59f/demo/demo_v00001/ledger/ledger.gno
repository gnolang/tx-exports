// Package ledger is demo_v00001's dedicated STORAGE realm: it owns the
// token balances, the tokenized-by audit trail, and the dynamic attribute
// map for the standalone demo token. It holds no issuance LOGIC of its own
// — trade rules, admin gating of Tokenize/Detokenize/Transfer, and unit
// formatting all live in the paired
// gno.land/r/g172tf235svs0hkckys8kshnam6ncz7pscx9x59f/demo/demo_v00001/main realm.
//
// ─── STANDALONE: NO DEPENDENCY ON THE REST OF THIS PROJECT ─────────────────────
//
//	This realm and its paired `main` realm are a self-contained demo pair:
//	neither imports anything else from this repository (no `tokenengine`, no
//	`productinterface`, no `market_vXXXXX`, no `orderbook`). Every field and
//	function here is a from-scratch copy of the same shape used by the
//	carbon-credit products' own `<sku>_ledger` realms, kept intentionally
//	independent so this pair can be read, deployed, and understood entirely
//	on its own. There is no locking layer and no marketplace-facing
//	Lock/Unlock/MarketMove/MarketSpend here at all — this demo only
//	showcases tokenization, detokenization, and holder-to-holder transfer;
//	see `main.gno`'s package doc.
//
// ─── EXACTLY ONE TRUSTED CALLER ────────────────────────────────────────────────
//
//	Every mutating function here is gated on the same check: the immediate
//	calling realm must be this pair's own `main` realm, registered once via
//	SetMainRealm. This realm never trusts anything else.
package ledger

import (
	"chain"
	"chain/runtime/unsafe"
	"strconv"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
)

var (
	admin address

	// mainRealm is the ONE realm allowed to call every mutating function
	// below: gno.land/r/g172tf235svs0hkckys8kshnam6ncz7pscx9x59f/demo/demo_v00001/main.
	mainRealm    address
	mainRealmSet bool

	dynamicAttrs  *avl.Tree // key(string) → value(string)
	tokenBalances *avl.Tree // address.String() → uint64 (total balance)
	tokenizedBy   *avl.Tree // address.String() → uint64 (cumulative gross issuance)
)

func init() {
	admin = unsafe.OriginCaller()
	dynamicAttrs = avl.NewTree()
	dynamicAttrs.Set("status", "active")
	dynamicAttrs.Set("unit", "DEMO")
	tokenBalances = avl.NewTree()
	tokenizedBy = avl.NewTree()
}

// ─── Admin / wiring ─────────────────────────────────────────────────────────────

func SetAdmin(cur realm, newAdmin address) {
	assertAdmin()
	admin = newAdmin
}

func GetAdmin() string { return admin.String() }

// SetMainRealm points this ledger's write access at `m`, this pair's paired
// `main` realm. Admin-only. Must be called once after both this realm and
// `main` are deployed, before ANY mutating call here can succeed.
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
	val := dynamicAttrs.Get(key)
	if val == nil {
		return ""
	}
	return val.(string)
}

func HasDynamicAttr(key string) bool {
	return dynamicAttrs.Has(key)
}

func DynamicAttrCount() int { return dynamicAttrs.Size() }

// RenderDynamicAttrs returns a Markdown table of every dynamic attribute, for
// the main realm's own Render(path) to embed directly.
func RenderDynamicAttrs() string {
	out := "| Key | Value |\n|:----|:------|\n"
	dynamicAttrs.Iterate("", "", func(key string, value interface{}) bool {
		out += ufmt.Sprintf("| %s | %s |\n", key, value.(string))
		return false
	})
	return out
}

// ─── Balances (main-realm-only mutations) ────────────────────────────────────────

// MintTo credits `amount` base units to `addr`. Called by `main` from
// Tokenize (new issuance) or as one half of Transfer (net zero).
func MintTo(cur realm, addr address, amount uint64) {
	assertMainRealm()
	mintTo(addr, amount)
}

// BurnFrom debits `amount` base units from `addr`. Called by `main` from
// Detokenize (retirement) or as one half of Transfer (net zero).
func BurnFrom(cur realm, addr address, amount uint64) {
	assertMainRealm()
	burnFrom(addr, amount)
}

// AddTokenized raises addr's cumulative gross issuance figure by `amount`.
// Called by `main` from Tokenize only.
func AddTokenized(cur realm, addr address, amount uint64) {
	assertMainRealm()
	tokenizedBy.Set(addr.String(), TokenizedByOf(addr)+amount)
}

// ─── Queries (plain reads, ungated) ──────────────────────────────────────────────

func BalanceOf(addr address) uint64 {
	val := tokenBalances.Get(addr.String())
	if val == nil {
		return 0
	}
	return val.(uint64)
}

// TokenizedByOf returns the CUMULATIVE GROSS amount ever issued to `addr`.
func TokenizedByOf(addr address) uint64 {
	val := tokenizedBy.Get(addr.String())
	if val == nil {
		return 0
	}
	return val.(uint64)
}

// ─── Internal helpers ─────────────────────────────────────────────────────────

func assertAdmin() {
	if unsafe.OriginCaller() != admin {
		panic("unauthorized: caller is not the admin")
	}
}

// assertMainRealm authorizes every mutating function above, checked against
// the IMMEDIATE calling realm via unsafe.PreviousRealm() (a stack-walker;
// NOT cur.Previous(), which is unimplemented on this toolchain). Safe here
// because `main` always calls this ledger directly, with no intervening
// indirection — there is no capability/marketplace hop in this demo pair.
func assertMainRealm() {
	if !mainRealmSet {
		panic("main realm not registered")
	}
	if unsafe.PreviousRealm().Address() != mainRealm {
		panic("unauthorized: caller is not the registered main realm")
	}
}

func mintTo(addr address, amount uint64) {
	cur := BalanceOf(addr)
	tokenBalances.Set(addr.String(), cur+amount)
}

func burnFrom(addr address, amount uint64) {
	cur := BalanceOf(addr)
	if cur < amount {
		panic("insufficient balance: have " + strconv.FormatUint(cur, 10) +
			", need " + strconv.FormatUint(amount, 10))
	}
	tokenBalances.Set(addr.String(), cur-amount)
}
