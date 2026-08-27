// Package ledger is this token's dedicated storage realm: it owns the
// token balances, the tokenized-by audit trail, and the dynamic attribute
// map. It holds no issuance logic of its own — trade rules, admin gating,
// and unit formatting live in the paired token realm.
//
// Every mutating function here accepts calls ONLY from that paired token
// realm, registered once via SetMainRealm.
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
	// below: this pair's own token realm.
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

// ─── Balances (main-realm-only mutations) ────────────────────────────────────────

// MintTo credits `amount` base units to `addr`. Called by the token realm
// from TokenizeByPlatform/TokenizeWithVoucher (new issuance) or as one half
// of Transfer/TransferFrom (net zero).
func MintTo(cur realm, addr address, amount uint64) {
	assertMainRealm()
	mintTo(addr, amount)
}

// BurnFrom debits `amount` base units from `addr`. Called by the token
// realm from Detokenize (retirement) or as one half of Transfer/TransferFrom
// (net zero).
func BurnFrom(cur realm, addr address, amount uint64) {
	assertMainRealm()
	burnFrom(addr, amount)
}

// AddTokenized raises addr's cumulative gross issuance figure by `amount`.
// Called by the token realm from TokenizeByPlatform/TokenizeWithVoucher only.
func AddTokenized(cur realm, addr address, amount uint64) {
	assertMainRealm()
	tokenizedBy.Set(addr.String(), TokenizedByOf(addr)+amount)
}

// ─── Queries (plain reads, ungated) ──────────────────────────────────────────────

func BalanceOf(addr address) uint64 {
	val, ok := tokenBalances.Get(addr.String()).(uint64)
	if !ok {
		return 0
	}
	return val
}

// TokenizedByOf returns the CUMULATIVE GROSS amount ever issued to `addr`.
func TokenizedByOf(addr address) uint64 {
	val, ok := tokenizedBy.Get(addr.String()).(uint64)
	if !ok {
		return 0
	}
	return val
}

// ─── Internal helpers ─────────────────────────────────────────────────────────

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
