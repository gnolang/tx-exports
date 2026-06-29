package admin

import (
	"chain"
	"chain/runtime/unsafe"

	"gno.land/p/akkadia/v0/accesscontrol"
)

const (
	TransferAdminEvent  = "TransferAdmin"
	AcceptAdminEvent    = "AcceptAdmin"
	CancelAdminEvent    = "CancelAdmin"
	SetExplorerURLEvent = "SetExplorerURL"
)

var (
	admin        address
	pendingAdmin address
	explorerURL  string = "https://app.alpha.akkadia.land"
)

func init() {
	caller := unsafe.OriginCaller()
	admin = caller
}

func GetAdmin() address {
	return admin
}

func GetPendingAdmin() address {
	return pendingAdmin
}

func TransferAdmin(cur realm, newAdmin address) {
	assertNotFrozen()
	assertTransferAdminCaller(0, cur)
	assertValidAddress(newAdmin)
	if pendingAdmin.IsValid() {
		panic("pending admin transfer already exists")
	}

	pendingAdmin = newAdmin

	chain.Emit(
		TransferAdminEvent,
		"from", admin.String(),
		"to", newAdmin.String(),
	)
}

func assertTransferAdminCaller(_ int, rlm realm) {
	if !admin.IsValid() {
		// The admin realm normally initializes admin from OriginCaller during
		// package deployment, so a live on-chain admin should be a valid address.
		// An empty admin is a bootstrap-only state observed by cross-package tests:
		// dependent realm tests can import admin before a real deploy signer exists,
		// leaving admin as address(""). In that state there is no valid user address
		// that can satisfy direct caller authorization, so requiring AssertIsAdmin
		// would make those tests unable to promote a real test admin at all.
		//
		// Keep the legacy OriginCaller check only for this invalid-admin bootstrap
		// state. This preserves the narrow test/bootstrap path where the current
		// placeholder admin is address(""), while ensuring that once a real admin is
		// accepted every subsequent admin transfer is direct-caller-only. In other
		// words, code-realm relays cannot borrow a valid admin signer's authority to
		// change pendingAdmin; the exception exists solely to escape the empty
		// imported-test initialization state.
		accesscontrol.AssertCurrentRealm(0, rlm)
		accesscontrol.AssertIsAdminOrigin(IsAdmin)
		return
	}

	accesscontrol.AssertIsAdmin(0, rlm, IsAdmin)
}

func AcceptAdmin(cur realm) {
	assertNotFrozen()
	if !pendingAdmin.IsValid() {
		panic("invalid pending admin address")
	}
	caller := mustGetPendingAdminUserCaller(0, cur)

	prevAdmin := admin
	admin = caller
	pendingAdmin = address("")

	chain.Emit(
		AcceptAdminEvent,
		"from", prevAdmin.String(),
		"to", admin.String(),
	)
}

func CancelAdminTransfer(cur realm) {
	assertNotFrozen()
	accesscontrol.AssertIsAdmin(0, cur, IsAdmin)
	if !pendingAdmin.IsValid() {
		panic("invalid pending admin address")
	}

	canceledAdmin := pendingAdmin
	pendingAdmin = address("")

	chain.Emit(
		CancelAdminEvent,
		"admin", admin.String(),
		"pendingAdmin", canceledAdmin.String(),
	)
}

func IsAdmin(address address) bool {
	return address == admin
}

// SetExplorerURL sets the explorer base URL (admin only)
func SetExplorerURL(cur realm, url string) {
	assertNotFrozen()
	accesscontrol.AssertIsAdmin(0, cur, IsAdmin)

	normalizedURL := normalizeExplorerURL(url)
	oldURL := explorerURL
	explorerURL = normalizedURL

	chain.Emit(
		SetExplorerURLEvent,
		"admin", admin.String(),
		"oldURL", oldURL,
		"newURL", normalizedURL,
	)
}

// GetExplorerURL returns the explorer base URL
func GetExplorerURL() string {
	return explorerURL
}
