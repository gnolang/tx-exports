// Package bubble is BUBBLE, the Bubble Rumble token: a GRC20 that remembers voting power (kourt's grc20votes),
// minted by the box for referrals under hard caps, and governed by kourt's governor on the same ledger.
//
// What is fixed here and what is not. The identity, the decimals, the max supply, the premine and the split
// between the referral pool and the reserve are constants: a realm cannot be redeployed at its path, so a number
// that must never move is a constant, not a setting. Who administers, who mints, whether minting is paused and
// how much may be minted a day are settings — the admin's until the holders vote them away (kinds.gno).
//
// The box (presence/bubble.go) decides which referral earns what; this realm only enforces the walls: the
// supply, the pools, the daily ceiling, the batch shape. See growth/BUBBLE.md.
package bubble

import (
	grc20votes "gno.land/p/g1leu8d2vsplhehcfkjg50mwgdpxdkt8tztu95wr/grc20votes/v0"
)

const (
	tokenName     = "Bubble"
	tokenSymbol   = "BUBBLE"
	tokenDecimals = 6
	pkgPath       = "gno.land/r/g1leu8d2vsplhehcfkjg50mwgdpxdkt8tztu95wr/bubble" // must match gnomod.toml
	tokenID       = pkgPath + "." + tokenSymbol

	// One BUBBLE in base units.
	one = int64(1_000_000)

	// epochBlocks quantises the voting snapshots: about 55 minutes at gnoland-1's 3.3 s blocks (kourt uses 720 at
	// the 5 s it was measured at). A vote is weighed at the last sealed epoch, so weight bought after a question is
	// asked does not count.
	epochBlocks = int64(1000)
)

// ledger is the token. Unexported and never handed out: whoever holds a *Ledger can mint.
var ledger = grc20votes.NewLedger(tokenName, tokenSymbol, tokenDecimals, epochBlocks)

// ---------------------------------------------------------------- reading --

func GetName() string    { return ledger.Name() }
func GetSymbol() string  { return ledger.Symbol() }
func GetDecimals() int   { return ledger.Decimals() }
func TotalSupply() int64 { return ledger.TotalSupply() }

func BalanceOf(owner address) int64          { return ledger.BalanceOf(owner) }
func Allowance(owner, spender address) int64 { return ledger.Allowance(owner, spender) }
func VotesOf(who address) int64              { return ledger.VotesOf(who) }
func DelegateOf(who address) address         { return ledger.DelegateOf(who) }
func PastVotes(who address, at uint32) int64 { return ledger.PastVotes(who, at) }
func PastTotalVotes(at uint32) int64         { return ledger.PastTotal(at) }
func Epoch() uint32                          { return ledger.Epoch() }

// ---------------------------------------------------------------- writing --
//
// Refuse a stale realm value, read who is calling, hand the ledger an address: kourt's three lines, because the
// ledger (a /p/ package) has no caller to read.

const errStaleRealm = "bubble: that realm value is not live; pass your own cur"

func caller(cur realm) address {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	return cur.Previous().Address()
}

// Transfer moves the caller's own tokens.
func Transfer(cur realm, to address, amount int64) { ledger.Transfer(caller(cur), to, amount) }

// Approve lets a spender move some of the caller's balance.
func Approve(cur realm, spender address, amount int64) { ledger.Approve(caller(cur), spender, amount) }

// TransferFrom spends an allowance.
func TransferFrom(cur realm, from, to address, amount int64) {
	ledger.TransferFrom(caller(cur), from, to, amount)
}

// Burn destroys the caller's own tokens. What is burned is gone from the supply and never re-minted: the pools
// count what was minted, not what exists.
func Burn(cur realm, amount int64) { ledger.Burn(caller(cur), amount) }

// Delegate points the caller's voting power at someone else (one hop; self is the default).
func Delegate(cur realm, to address) { ledger.Delegate(caller(cur), to) }
