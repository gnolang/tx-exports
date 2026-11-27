package hearth

// HEARTH is the HearthCouncil governance token (GRC20, decimals 0).
//
// Distribution model (fixed supply, no admin mint):
//   - The full supply is minted once, at deploy time, into this realm's
//     own reserve.
//   - Claim: one-time airdrop of ClaimAmount per address.
//   - Faucet: demo tap of FaucetAmount per call, until the reserve runs out.
//   - The HearthCouncil DAO pulls deposits from holders via TransferFrom
//     (allowance), so voting power is escrowed HEARTH, never spendable
//     twice: tokens that voted cannot be transferred away while the
//     proposal is active (the DAO locks them, see hearthcouncil).

import (
	"strconv"

	"chain"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/grc20/v0"
	"gno.land/p/nt/seqid/v0"
)

const (
	// InitialSupply is the total HEARTH ever minted (decimals = 0).
	InitialSupply = 1_000_000
	// ClaimAmount is the one-time airdrop per address.
	ClaimAmount = 1_000
	// FaucetAmount is the per-call demo tap amount.
	FaucetAmount = 1_000
)

var (
	token     *grc20.Token
	ledger    *grc20.PrivateLedger
	nextID    seqid.ID
	claimed   avl.Tree // address string -> true (Claim already used)
	realmAddr address  // this realm's own address; holds the reserve
)

func init(cur realm) {
	token, ledger = grc20.NewToken("HEARTH", "HEARTH", 0, nextID.Next(), cur)
	realmAddr = cur.Address()
	ledger.Mint(realmAddr, InitialSupply)
}

// ---- read-only ----

func Name() string {
	return token.GetName()
}

func Symbol() string {
	return token.GetSymbol()
}

func Decimals() int {
	return token.GetDecimals()
}

func TotalSupply() int64 {
	return token.TotalSupply()
}

func BalanceOf(addr address) int64 {
	return token.BalanceOf(addr)
}

func Allowance(owner, spender address) int64 {
	return token.ReadonlyTeller().Allowance(owner, spender)
}

// Reserve returns the HEARTH still held by this realm (undistributed).
func Reserve() int64 {
	return token.BalanceOf(realmAddr)
}

// RealmAddress returns this realm's own address (the reserve holder).
func RealmAddress() address {
	return realmAddr
}

// HasClaimed reports whether addr already took its one-time Claim.
func HasClaimed(addr address) bool {
	return claimed.Has(addr.String())
}

// ---- user token operations (crossing functions) ----

// Transfer moves amount HEARTH from the caller to `to`.
func Transfer(cur realm, to address, amount int64) {
	mustPositive(amount)
	teller := ledger.CallerTeller()
	mustNoErr(teller.Transfer(0, cur, to, amount))
}

// Approve lets `spender` move up to amount HEARTH on the caller's behalf.
func Approve(cur realm, spender address, amount int64) {
	mustNonNegative(amount)
	teller := ledger.CallerTeller()
	mustNoErr(teller.Approve(0, cur, spender, amount))
}

// TransferFrom moves amount HEARTH from `from` to `to`, spending the
// caller's allowance over `from`'s tokens. The DAO uses this to pull
// deposits (the caller must first Approve the DAO realm).
func TransferFrom(cur realm, from, to address, amount int64) {
	mustPositive(amount)
	teller := ledger.CallerTeller()
	mustNoErr(teller.TransferFrom(0, cur, from, to, amount))
}

// Claim gives every address a one-time airdrop of ClaimAmount HEARTH,
// drawn from the realm reserve.
func Claim(cur realm) {
	caller := cur.Previous().Address()
	if claimed.Has(caller.String()) {
		panic("HEARTH already claimed by this address")
	}
	claimed.Set(caller.String(), true)
	disburse(cur, caller, ClaimAmount)
	chain.Emit("Claim", "to", caller.String(), "amount", strconv.Itoa(ClaimAmount))
}

// Faucet is the demo tap: anyone may draw FaucetAmount HEARTH per call
// until the reserve is empty (then the transfer fails and the call
// panics, which is the intended stop condition).
func Faucet(cur realm) {
	caller := cur.Previous().Address()
	disburse(cur, caller, FaucetAmount)
	chain.Emit("Faucet", "to", caller.String(), "amount", strconv.Itoa(FaucetAmount))
}

// disburse moves amount HEARTH from the realm reserve to `to`.
func disburse(cur realm, to address, amount int64) {
	teller := token.RealmTeller(0, cur)
	mustNoErr(teller.Transfer(0, cur, to, amount))
}

func mustPositive(amount int64) {
	if amount <= 0 {
		panic("amount must be positive")
	}
}

func mustNonNegative(amount int64) {
	if amount < 0 {
		panic("amount must not be negative")
	}
}

func mustNoErr(err error) {
	if err != nil {
		panic(err)
	}
}
