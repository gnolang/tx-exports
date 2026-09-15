// Package campaign is a near-verbatim copy of the real gems6/campaign
// realm, redeployed here under the test address so this whole
// reveal-delay + gemsartfab prototype is self-contained and testable
// without touching the live gems6 deployment or needing the vesting
// wallet's own key. Logic is unchanged from the original -- see that
// package's own doc comments for the full design rationale (why a
// dedicated prunable realm instead of a Merkle root, the stacking rule
// in grantOne, etc.).
package campaign

import (
	unsaferealm "chain/runtime/unsafe"
	"strings"

	"gno.land/p/g1gn6t0q9wenwhdda47rkrpfd63kcxjvyp7eqwku/avl"
)

var (
	collectionOwner  address = "g1gn6t0q9wenwhdda47rkrpfd63kcxjvyp7eqwku"
	approvedConsumer string
	entries          avl.Tree // wallet.String() -> *entry
)

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

func grantOne(wallet string, bps int64, maxUses int64) {
	if raw := entries.Get(wallet); raw != nil {
		if e, ok := raw.(*entry); ok {
			e.RemainingUses += maxUses
			if bps < e.Bps {
				e.Bps = bps
			}
			entries.Set(wallet, e)
			return
		}
	}
	entries.Set(wallet, &entry{Bps: bps, RemainingUses: maxUses})
}

func AddWallet(cur realm, wallet address, bps int64, maxUses int64) {
	assertOwner()
	validateBps(bps)
	validateMaxUses(maxUses)
	grantOne(wallet.String(), bps, maxUses)
}

func AddWalletsBatch(cur realm, walletsCSV string, bps int64, maxUses int64) {
	assertOwner()
	validateBps(bps)
	validateMaxUses(maxUses)
	for _, w := range strings.Split(walletsCSV, ",") {
		w = strings.TrimSpace(w)
		if w == "" {
			continue
		}
		grantOne(w, bps, maxUses)
	}
}

func RemoveWallet(cur realm, wallet address) {
	assertOwner()
	entries.Remove(wallet.String())
}

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

func Peek(wallet address) (bps int64, remainingUses int64, ok bool) {
	raw := entries.Get(wallet.String())
	e, isEntry := raw.(*entry)
	if !isEntry {
		return 0, 0, false
	}
	return e.Bps, e.RemainingUses, true
}

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
