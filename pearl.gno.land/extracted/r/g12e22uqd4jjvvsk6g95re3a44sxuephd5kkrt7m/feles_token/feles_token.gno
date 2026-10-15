// Realm: gno.land/r/<addr>/feles_token
//
// The FELES token — a GRC20 whose mint authority is an ADDRESS THAT CAN BE HANDED OVER.
//
// WHY NOT MINT FROM THE DAO REALM ITSELF: gno packages are immutable, and a realm's
// address is derived from its package path. A new DAO version lives at a new path and so
// has a NEW address. A token that hard-bound its authority to today's DAO would be
// orphaned by the first upgrade — the supply would be frozen forever, or worse, still
// controlled by a dead realm. So authority is state, and it is transferable.
//
// Intended lifecycle:
//   1. deploy this realm       — authority = the deployer key
//   2. deploy the DAO realm    — it imports this one
//   3. TransferAuthority(DAO)  — from then on, only a passed Core proposal can mint
//
// After step 3 no personal key can print supply. Until step 3, one can — so do not treat
// the token as governed until authority actually sits with the DAO.
package feles_token

import (
	"errors"

	"gno.land/p/demo/tokens/grc20"
	"gno.land/p/nt/seqid/v0"
	"gno.land/r/demo/defi/grc20reg"
)

const (
	Name     = "Feles"
	Symbol   = "FELES"
	Decimals = 6

	// 1,000,000,000 FELES expressed in base units (10^6 per token). A HARD cap: Mint
	// refuses to cross it and nothing in this realm can raise it. int64 tops out around
	// 9.2e18, so 1e15 leaves plenty of headroom.
	MaxSupply = int64(1_000_000_000) * 1_000_000
)

var (
	token     *grc20.Token
	ledger    *grc20.PrivateLedger
	tokenKey  string
	authority address = "g12e22uqd4jjvvsk6g95re3a44sxuephd5kkrt7m" // deployer; hand to the DAO
)

// Initialize creates the token and registers it. It cannot live in init(): grc20.NewToken
// and grc20reg.Register both need a `cur realm`, which init() does not have. Authority
// only, and once — a second call would orphan the first token and every balance on it.
//
// Deploy step 1a. Do this immediately after deploying, before anything else.
func Initialize(cur realm) {
	assertAuthority(cur)
	if token != nil {
		panic(errors.New("feles_token: already initialized"))
	}
	token, ledger = grc20.NewToken(Name, Symbol, Decimals, seqid.ID(1), cur)
	tokenKey = grc20reg.Register(cross(cur), token, "feles")
}

func assertInitialized() {
	if token == nil {
		panic(errors.New("feles_token: not initialized — call Initialize first"))
	}
}

func assertAuthority(cur realm) {
	if cur.Previous().Address() != authority {
		panic(errors.New("feles_token: not the mint authority"))
	}
}

// Mint creates supply, up to MaxSupply. Authority only.
func Mint(cur realm, to address, amount int64) {
	assertAuthority(cur)
	assertInitialized()
	if amount <= 0 {
		panic(errors.New("feles_token: amount must be positive"))
	}
	if !to.IsValid() {
		panic(errors.New("feles_token: invalid recipient address"))
	}
	if token.TotalSupply()+amount > MaxSupply {
		panic(errors.New("feles_token: mint would exceed max supply"))
	}
	if err := ledger.Mint(to, amount); err != nil {
		panic(err)
	}
}

// Burn destroys supply held by the authority itself. It does NOT let the authority burn
// somebody else's balance — that would make every holder's balance revocable.
func Burn(cur realm, amount int64) {
	assertAuthority(cur)
	assertInitialized()
	if err := ledger.Burn(cur.Previous().Address(), amount); err != nil {
		panic(err)
	}
}

// TransferAuthority hands mint rights to another address — normally the DAO realm.
// One-way in practice: once the DAO holds it, only a passed proposal can move it again.
func TransferAuthority(cur realm, newAuthority address) {
	assertAuthority(cur)
	if !newAuthority.IsValid() {
		panic(errors.New("feles_token: invalid authority address"))
	}
	authority = newAuthority
}

// ---- views ----

func Authority() address { return authority }
func TokenKey() string   { return tokenKey }
func Initialized() bool  { return token != nil }

func TotalSupply() int64 {
	assertInitialized()
	return token.TotalSupply()
}

func Remaining() int64 {
	assertInitialized()
	return MaxSupply - token.TotalSupply()
}

func BalanceOf(a address) int64 {
	assertInitialized()
	return token.BalanceOf(a)
}

func Render(path string) string {
	out := "# FELES\n\n"
	out += "| | |\n|---|---|\n"
	out += "| Symbol | " + Symbol + " |\n"
	out += "| Decimals | 6 |\n"
	out += "| Max supply | 1,000,000,000 FELES |\n"
	out += "| Registry key | `" + tokenKey + "` |\n"
	out += "| Mint authority | `" + authority.String() + "` |\n\n"
	if token == nil {
		out += "_Not initialized._\n"
		return out
	}
	out += token.RenderHome()
	return out
}
