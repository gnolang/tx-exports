// Package campaign is a small, deliberately TEMPORARY realm: it holds
// a wallet allowlist for discounted gems4 mints (wallet -> {bps,
// remainingUses}), separate from ../stable (which never intends to
// shrink) specifically so this list can be pruned and its storage
// deposit recovered once a campaign ends.
//
// Why a dedicated realm instead of a Merkle root (the gems3 approach)
// or a bigger avl.Tree inside stable itself: a real avl.Tree entry
// here costs ~0.22 GNOT in storage deposit (measured live on Pearl,
// 2026-09-14) -- for a few hundred wallets that's real money (~99
// GNOT for the original 441-wallet list), which is exactly why gems3
// moved to a Merkle root instead. But that deposit is NOT a burn: gno
// refunds it automatically the instant the underlying bytes are
// deleted (same mechanism ../stable's own Burn relies on). So each
// wallet's entry self-refunds the moment it's fully redeemed
// (ConsumeDiscount deletes it once RemainingUses hits zero), and
// anything left unredeemed when the campaign closes can be swept with
// RemoveWalletsBatch to recover the rest. Net effect: closer to a
// refundable deposit than a real cost, in exchange for a much simpler
// mint-time check (a direct lookup, no proofs, no off-chain file to
// host or keep in sync).
package campaign

import (
	unsaferealm "chain/runtime/unsafe"
	"strings"

	"gno.land/p/g1gn6t0q9wenwhdda47rkrpfd63kcxjvyp7eqwku/avl"
)

var (
	// collectionOwner is the only address allowed to manage the
	// allowlist. Same address as gems4/stable's own collectionOwner.
	collectionOwner address = "g1gn6t0q9wenwhdda47rkrpfd63kcxjvyp7eqwku"

	// approvedConsumer is the one realm allowed to call
	// ConsumeDiscount -- set once to gems4/stable's own pkgpath (never
	// gems4/v1's), specifically so this gate never needs to change on
	// a future mint-mechanics version swap. stable is the permanent
	// half of the split; pinning the gate there means campaign's own
	// wiring survives v1 -> v2 -> ... redeploys with zero changes.
	approvedConsumer string

	entries avl.Tree // wallet.String() -> *entry
)

// entry is stored BY POINTER so ConsumeDiscount can decrement
// RemainingUses in place; every mutation still goes through
// entries.Set to guarantee the change persists regardless of how gno's
// realm storage treats pointer aliasing internally.
type entry struct {
	Bps           int64
	RemainingUses int64
}

func callerAddress() address {
	return unsaferealm.PreviousRealm().Address()
}

func assertOwner() {
	if callerAddress() != collectionOwner {
		panic("unauthorized: caller is not the collection owner")
	}
}

// SetApprovedConsumer is called once, right after gems4/stable is
// deployed, to point this realm's discount-consuming gate at it.
func SetApprovedConsumer(cur realm, pkgpath string) {
	assertOwner()
	approvedConsumer = pkgpath
}

func validateBps(bps int64) {
	if bps < 0 || bps > 10000 {
		panic("bps must be between 0 and 10000")
	}
}

func validateMaxUses(maxUses int64) {
	if maxUses <= 0 {
		panic("maxUses must be positive")
	}
}

// AddWallet grants (or replaces) one wallet's discount: bps off the
// standard price, usable maxUses times before falling back to
// standard pricing.
func AddWallet(cur realm, wallet address, bps int64, maxUses int64) {
	assertOwner()
	validateBps(bps)
	validateMaxUses(maxUses)
	entries.Set(wallet.String(), &entry{Bps: bps, RemainingUses: maxUses})
}

// AddWalletsBatch grants the SAME (bps, maxUses) pair to every wallet
// in a comma-separated list -- for populating one tier (e.g. all
// Tardigrade holders) in as few transactions as possible. Keep
// batches small enough to fit gno_call's default deposit ceiling; see
// this project's own notes on gnomcp's missing max_deposit control.
func AddWalletsBatch(cur realm, walletsCSV string, bps int64, maxUses int64) {
	assertOwner()
	validateBps(bps)
	validateMaxUses(maxUses)
	for _, w := range strings.Split(walletsCSV, ",") {
		w = strings.TrimSpace(w)
		if w == "" {
			continue
		}
		entries.Set(w, &entry{Bps: bps, RemainingUses: maxUses})
	}
}

// RemoveWallet deletes one wallet's entry outright (whether or not
// they've used it), refunding its storage deposit to whoever calls
// this.
func RemoveWallet(cur realm, wallet address) {
	assertOwner()
	entries.Remove(wallet.String())
}

// RemoveWalletsBatch sweeps a batch of wallets at once -- for closing
// out a campaign and recovering deposit from everyone who never
// redeemed. Batched for the same reason AddWalletsBatch is: a single
// call covering hundreds of wallets can exceed gno_call's default
// deposit/gas ceiling.
func RemoveWalletsBatch(cur realm, walletsCSV string) {
	assertOwner()
	for _, w := range strings.Split(walletsCSV, ",") {
		w = strings.TrimSpace(w)
		if w == "" {
			continue
		}
		entries.Remove(w)
	}
}

func assertCallerIsApprovedConsumer(cur realm) {
	caller := cur.Previous().PkgPath()
	if approvedConsumer == "" || caller != approvedConsumer {
		panic("unauthorized: caller is not the approved consumer realm")
	}
}

// Peek reports wallet's current discount WITHOUT consuming it -- for
// computing a price preview before a real mint actually happens. Pure
// read, callable by anyone/anything (no gate): looking at the price
// list isn't a privileged action, only spending an entry is.
func Peek(wallet address) (bps int64, remainingUses int64, ok bool) {
	raw := entries.Get(wallet.String())
	e, isEntry := raw.(*entry)
	if !isEntry {
		return 0, 0, false
	}
	return e.Bps, e.RemainingUses, true
}

// ConsumeDiscount spends one use of wallet's discount, called only by
// the approved consumer (gems4/stable) atomically during a real mint.
// Deletes the entry once uses reach zero -- that deletion is what
// triggers gno's automatic storage-deposit refund (see this package's
// own doc comment), so a fully-redeemed wallet's deposit comes back on
// its own, no manual sweep needed. Returns ok=false with no state
// change if wallet has no entry (e.g. they paid standard price, or
// used stable's separate individual-override list instead).
func ConsumeDiscount(cur realm, wallet address) (bps int64, ok bool) {
	assertCallerIsApprovedConsumer(cur)
	raw := entries.Get(wallet.String())
	e, isEntry := raw.(*entry)
	if !isEntry {
		return 0, false
	}
	e.RemainingUses--
	if e.RemainingUses <= 0 {
		entries.Remove(wallet.String())
	} else {
		entries.Set(wallet.String(), e)
	}
	return e.Bps, true
}

func Count() int64 { return int64(entries.Size()) }

func EntryAt(index int) (wallet string, bps int64, remainingUses int64) {
	w, v := entries.GetByIndex(index)
	e := v.(*entry)
	return w, e.Bps, e.RemainingUses
}
