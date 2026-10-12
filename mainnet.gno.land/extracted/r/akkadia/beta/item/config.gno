package item

import (
	"chain"
	"strconv"
	"strings"

	"gno.land/p/akkadia/beta/accesscontrol"
	"gno.land/p/nt/bptree/v0"
	"gno.land/r/akkadia/beta/admin"
)

const (
	SetListLimitEvent     = "SetListLimit"
	SetMinterRealmEvent   = "SetMinterRealm"
	UnsetMinterRealmEvent = "UnsetMinterRealm"
)

var (
	listLimit    int = 100 // Max items per ListByOwner page
	minterRealms *bptree.BPTree
)

func SetListLimit(cur realm, limit int) {
	accesscontrol.AssertIsAdmin(0, cur, admin.IsAdmin)
	if limit < 1 {
		panic("limit must be at least 1")
	}

	oldLimit := listLimit
	listLimit = limit

	chain.Emit(
		SetListLimitEvent,
		"oldLimit", strconv.Itoa(oldLimit),
		"newLimit", strconv.Itoa(limit),
	)
}

func GetListLimit() int {
	return listLimit
}

func SetMinterRealm(cur realm, pkgPath string) {
	accesscontrol.AssertIsAdmin(0, cur, admin.IsAdmin)
	addr := minterRealmAddress(pkgPath)
	minterRealms.Set(addr.String(), true)
	chain.Emit(
		SetMinterRealmEvent,
		"pkgPath", pkgPath,
		"address", addr.String(),
	)
}

func UnsetMinterRealm(cur realm, pkgPath string) {
	accesscontrol.AssertIsAdmin(0, cur, admin.IsAdmin)
	addr := minterRealmAddress(pkgPath)
	if !minterRealms.Has(addr.String()) {
		panic("package path is not a minter realm")
	}
	minterRealms.Remove(addr.String())
	chain.Emit(
		UnsetMinterRealmEvent,
		"pkgPath", pkgPath,
		"address", addr.String(),
	)
}

func IsMinterRealm(addr address) bool {
	return minterRealms.Has(addr.String())
}

func minterRealmAddress(pkgPath string) address {
	if pkgPath == "" {
		panic("package path is required")
	}
	if !strings.HasPrefix(pkgPath, "gno.land/r/") || pkgPath == "gno.land/r/" {
		panic("invalid package path")
	}
	return chain.PackageAddress(pkgPath)
}
