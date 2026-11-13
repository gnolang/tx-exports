package keeper

import (
	"gno.land/p/gnoswap/order/access/manager/v0"
	ufmt "gno.land/p/nt/ufmt/v0"

	"gno.land/r/gnoswap/access/v1"
)

// AssertIsAuthorizedCaller panics unless the caller of rlm may call selector
// on the realm of rlm. Order realms call it with their own realm value,
// so a realm can only assert for itself.
func AssertIsAuthorizedCaller(_ int, rlm realm, selector manager.Selector) {
	if !rlm.IsCurrent() {
		panic(errSpoofedRealm)
	}

	caller := rlm.Previous().Address()

	target := rlm.PkgPath()
	if !accessState.IsAuthorized(caller, target, selector) {
		panic(makeErrorWithDetails(
			errUnauthorizedCall,
			ufmt.Sprintf("%s cannot call %s on %s", caller.String(), string(selector), target),
		).Error())
	}
}

// assertIsAdminOrGovernance checks that the caller of cur is the GnoSwap
// admin or governance.
func assertIsAdminOrGovernance(cur realm) {
	access.AssertIsAdminOrGovernance(cur.Previous().Address())
}

// assertIsRegisteredRole rejects roles that were never registered.
// manager.AdminRole is never registered here.
func assertIsRegisteredRole(role manager.RoleId) {
	if !isRegisteredRole(role) {
		panic(makeErrorWithDetails(errInvalidRole, ufmt.Sprintf("role(%s) is not registered", role.String())).Error())
	}
}

// assertIsAssignableRole accepts a registered role or PublicRole.
func assertIsAssignableRole(role manager.RoleId) {
	if role != manager.PublicRole {
		assertIsRegisteredRole(role)
	}
}

func assertIsAvailableLabel(label string) {
	if label == "" || len(label) > maxLabelLength {
		panic(makeErrorWithDetails(errInvalidLabel, ufmt.Sprintf("label(%s) must be 1 to %d bytes", label, maxLabelLength)).Error())
	}

	if isLabelTaken(label) {
		panic(makeErrorWithDetails(errInvalidLabel, ufmt.Sprintf("label(%s) already exists", label)).Error())
	}
}

func assertIsValidAddress(account address) {
	if !account.IsValid() {
		panic(makeErrorWithDetails(errInvalidAddress, ufmt.Sprintf("account(%s)", account.String())).Error())
	}
}

func assertIsValidTarget(target string) {
	if target == "" {
		panic(makeErrorWithDetails(errInvalidTarget, "empty target").Error())
	}
}
