// Package campaign is a near-verbatim copy of the real gems6/campaign
// realm, redeployed here under the test address so this whole
// reveal-delay + gemsartfab prototype is self-contained and testable
// without touching the live gems6 deployment or needing the vesting
// wallet's own key. Logic is unchanged from the original -- see that
// package's own doc comments for the full design rationale (why a
// dedicated prunable realm instead of a Merkle root, the stacking rule
// in grantOne, etc.).
package campaign

// Storage (2026-09-26): every grant lives in ONE map, packed as a single
// int64 (remainingUses*packBase + bps), plus one slice of wallets for
// EntryAt's stable order. The first version kept an avl.Tree of *entry
// pointers: every wallet became its own tree node plus entry object, about
// 2.9 KB each on a local chain (0.29 GNOT per wallet, ~85 GNOT for the
// 284-wallet campaign). A map and a slice are stored as a few objects
// whose size grows by roughly the key and value per wallet.

import (
	unsaferealm "chain/runtime/unsafe"
	"strings"
)

const packBase = 10001 // bps is 0..10000

var (
	collectionOwner  address = "g17cjym5e9hhws46lt6329pv2gtx2ay0503hgems"
	approvedConsumer string
	grants           = map[string]int64{} // wallet -> remainingUses*packBase + bps
	order            []string             // wallets with a grant, for EntryAt
)

func pack(bps, uses int64) int64     { return uses*packBase + bps }
func unpack(v int64) (bps, uses int64) { return v % packBase, v / packBase }

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

// grantOne adds uses to a wallet; a second grant stacks its uses and keeps
// the better (lower) bps.
func grantOne(wallet string, bps int64, maxUses int64) {
	if v, ok := grants[wallet]; ok {
		oldBps, uses := unpack(v)
		if oldBps < bps {
			bps = oldBps
		}
		grants[wallet] = pack(bps, uses+maxUses)
		return
	}
	grants[wallet] = pack(bps, maxUses)
	order = append(order, wallet)
}

func removeOne(wallet string) {
	if _, ok := grants[wallet]; !ok {
		return
	}
	delete(grants, wallet)
	for i, w := range order {
		if w == wallet {
			order[i] = order[len(order)-1]
			order = order[:len(order)-1]
			break
		}
	}
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
	removeOne(wallet.String())
}

func RemoveWalletsBatch(cur realm, walletsCSV string) {
	assertOwner()
	for _, w := range strings.Split(walletsCSV, ",") {
		w = strings.TrimSpace(w)
		if w == "" {
			continue
		}
		removeOne(w)
	}
}

func assertCallerIsApprovedConsumer(cur realm) {
	caller := cur.Previous().PkgPath()
	if approvedConsumer == "" || caller != approvedConsumer {
		panic("unauthorized: caller is not the approved consumer realm")
	}
}

func Peek(wallet address) (bps int64, remainingUses int64, ok bool) {
	v, has := grants[wallet.String()]
	if !has {
		return 0, 0, false
	}
	bps, remainingUses = unpack(v)
	return bps, remainingUses, true
}

func ConsumeDiscount(cur realm, wallet address) (bps int64, ok bool) {
	assertCallerIsApprovedConsumer(cur)
	w := wallet.String()
	v, has := grants[w]
	if !has {
		return 0, false
	}
	bps, uses := unpack(v)
	if uses <= 1 {
		removeOne(w)
	} else {
		grants[w] = pack(bps, uses-1)
	}
	return bps, true
}

func Count() int64 { return int64(len(order)) }

func EntryAt(index int) (wallet string, bps int64, remainingUses int64) {
	wallet = order[index]
	bps, remainingUses = unpack(grants[wallet])
	return wallet, bps, remainingUses
}
