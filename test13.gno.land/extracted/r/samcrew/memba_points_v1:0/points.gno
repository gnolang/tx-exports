// Package memba_points_v1 is a soulbound (non-transferable), no-banker on-chain reputation ledger
// for the Memba ecosystem. Addresses accrue non-transferable "Memba Points" (MP) via authorized
// awarders (the owner or whitelisted awarder realms); MP is READ by other surfaces for status
// tiers, feature gating, and leaderboards.
//
// SAFETY: there is NO transfer, NO banker, and NO OriginSend anywhere — the entire fund-drain risk
// class (the OriginSend/IsUserCall/F-1 family) simply does not apply. The ONLY trust boundary is
// who may Award/Revoke (the owner ∪ whitelisted awarder realms); every mint/burn emits an event.
// Non-transferability is by construction: there is no Transfer/Send/Approve, so points can never be
// bought, sold, or wash-traded — MP is reputation, not money ($MEMBA is the money).
package memba_points_v1

import (
	"chain"
	"chain/runtime"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
)

// AdminAddress is the samcrew-core deploy multisig (same as the other Memba realms). It inits
// `owner`; hand it to the memba_dao executor post-deploy via the 2-step ownership transfer.
const AdminAddress = "g1x7k4628w93a7wzdhqc06atzx0v50rnshweuxu0"

const (
	// MaxAward caps a single Award/Revoke amount — a fat-finger + int64-overflow guard.
	MaxAward = int64(1_000_000_000)
	maxInt64 = int64(9223372036854775807)
)

// Account is one address's soulbound points balance.
type Account struct {
	Points    int64
	UpdatedAt int64 // block height of last change
}

var (
	owner        address
	pendingOwner address
	paused       bool
	accounts     = avl.NewTree() // addr string -> *Account
	awarders     = avl.NewTree() // awarder realm pkgpath -> bool
	totalPoints  int64           // Σ current points across all accounts (O(1))
	holderCount  int             // number of accounts with a positive balance
)

func init() { owner = address(AdminAddress) }

func assertOwner(cur realm) {
	if !cur.IsCurrent() {
		panic("spoofed realm")
	}
	if cur.Previous().Address() != owner {
		panic("unauthorized: owner only")
	}
}

func assertNotPaused() {
	if paused {
		panic("points awarding is paused")
	}
}

func isAwarder(pkgpath string) bool {
	_, ok := awarders.Get(pkgpath)
	return ok
}

// assertAwardAuth is the single trust boundary: only the owner (a direct signer) or a whitelisted
// awarder realm may mint/burn points. Anti-sybil lives in the awarder's own verified flow — this
// realm only enforces that the source is trusted.
func assertAwardAuth(cur realm) {
	if !cur.IsCurrent() {
		panic("spoofed realm")
	}
	pr := cur.Previous()
	if pr.Address() != owner && !isAwarder(pr.PkgPath()) {
		panic("unauthorized: owner or whitelisted awarder realm only")
	}
}

// mustAccount returns the account for `a`, or a fresh zero-value one (not yet stored).
func mustAccount(a address) *Account {
	v, ok := accounts.Get(a.String())
	if !ok {
		return &Account{}
	}
	return v.(*Account)
}

// Award grants `amount` non-transferable points to `to`. Owner or a whitelisted awarder realm only.
// Bounded amount + int64 overflow guard. Emits PointsAwarded (with the awarding source realm).
func Award(cur realm, to address, amount int64, reason string) {
	assertNotPaused()
	assertAwardAuth(cur)
	if to == "" {
		panic("recipient must be non-empty")
	}
	if amount <= 0 || amount > MaxAward {
		panic("amount out of range (1..MaxAward)")
	}
	a := mustAccount(to)
	if a.Points > maxInt64-amount {
		panic("points overflow")
	}
	if totalPoints > maxInt64-amount {
		panic("total points overflow")
	}
	old := a.Points
	a.Points += amount
	a.UpdatedAt = runtime.ChainHeight()
	accounts.Set(to.String(), a)
	totalPoints += amount
	if old == 0 {
		holderCount++
	}
	rankApply(to.String(), old, a.Points)
	chain.Emit("PointsAwarded", "to", to.String(), "amount", itoa64(amount),
		"reason", reason, "source", cur.Previous().PkgPath())
}

// Revoke removes up to `amount` points from `from`, clamped at zero (never negative). Owner or a
// whitelisted awarder realm only — moderation / clawback. A no-op on a zero balance. Emits
// PointsRevoked with the amount actually removed.
func Revoke(cur realm, from address, amount int64, reason string) {
	assertNotPaused()
	assertAwardAuth(cur)
	if amount <= 0 || amount > MaxAward {
		panic("amount out of range (1..MaxAward)")
	}
	a := mustAccount(from)
	removed := amount
	if removed > a.Points {
		removed = a.Points
	}
	if removed == 0 {
		return
	}
	old := a.Points
	a.Points -= removed
	a.UpdatedAt = runtime.ChainHeight()
	accounts.Set(from.String(), a)
	totalPoints -= removed
	if a.Points == 0 {
		holderCount--
	}
	rankApply(from.String(), old, a.Points)
	chain.Emit("PointsRevoked", "from", from.String(), "amount", itoa64(removed), "reason", reason)
}

// GetPoints returns an address's current points (0 if unknown). Pure.
func GetPoints(a string) int64 {
	v, ok := accounts.Get(a)
	if !ok {
		return 0
	}
	return v.(*Account).Points
}

func itoa64(n int64) string { return ufmt.Sprintf("%d", n) }
