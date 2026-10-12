package accesscontrol

import "chain/runtime/unsafe"

// AuthCheck must be owned by the calling realm/package.
// Do not pass callbacks received from untrusted callers.
type AuthCheck func(address) bool

func AssertCurrentRealm(_ int, rlm realm) {
	if !rlm.IsCurrent() {
		panic("spoofed realm")
	}
}

func AssertIsAdmin(_ int, rlm realm, isAdmin AuthCheck) {
	MustGetAdminCaller(0, rlm, isAdmin)
}

func MustGetAdminCaller(_ int, rlm realm, isAdmin AuthCheck) address {
	assertAuthCheck(isAdmin, "admin auth check is nil")
	AssertCurrentRealm(0, rlm)

	caller := rlm.Previous().Address()
	if !isAdmin(caller) {
		panic("admin access required")
	}
	return caller
}

func MustGetUserCaller(_ int, rlm realm) address {
	AssertCurrentRealm(0, rlm)

	prev := rlm.Previous()
	if !prev.IsUserCall() {
		panic("contract calls not allowed: function must be called directly by user")
	}
	return prev.Address()
}

// AssertIsAdminOrigin checks the transaction signer, not the direct caller realm.
// Use it only for explicit delegation APIs that intentionally allow code-realm relays.
func AssertIsAdminOrigin(isAdmin AuthCheck) {
	MustGetAdminOrigin(isAdmin)
}

// MustGetAdminOrigin checks the transaction signer, not the direct caller realm.
// Use it only for explicit delegation APIs that intentionally allow code-realm relays.
func MustGetAdminOrigin(isAdmin AuthCheck) address {
	assertAuthCheck(isAdmin, "admin auth check is nil")

	caller := unsafe.OriginCaller()
	if !isAdmin(caller) {
		panic("admin access required")
	}
	return caller
}

func AssertIsAdminOrOperator(_ int, rlm realm, isAdmin AuthCheck, isOperator AuthCheck) {
	MustGetAdminOrOperatorCaller(0, rlm, isAdmin, isOperator)
}

func MustGetAdminOrOperatorCaller(_ int, rlm realm, isAdmin AuthCheck, isOperator AuthCheck) address {
	assertAuthCheck(isAdmin, "admin auth check is nil")
	assertAuthCheck(isOperator, "operator auth check is nil")
	AssertCurrentRealm(0, rlm)

	caller := rlm.Previous().Address()
	if !isAdmin(caller) && !isOperator(caller) {
		panic("admin or operator access required")
	}
	return caller
}

func assertAuthCheck(check AuthCheck, msg string) {
	if check == nil {
		panic(msg)
	}
}
