package realmid

import (
	"chain/runtime/unsafe"
	"strings"
)

// Returns the identifier of the previous realm in the call chain.
func Previous() string {
	r := unsafe.PreviousRealm()
	if r.IsUser() {
		return r.Address().String()
	}
	return r.PkgPath()
}

// Returns the identifier of the current realm.
func Current() string {
	r := unsafe.CurrentRealm()
	if r.IsUser() {
		return r.Address().String()
	}
	return r.PkgPath()
}

// Checks if the given identifier is a package path.
// Package paths contain dots (e.g., "gno.land/p/demo/users").
func IsPackage(id string) bool {
	return strings.ContainsRune(id, '.')
}

// Checks if the given identifier is a user address.
// User addresses don't contain dots (e.g., "g1abc...def").
func IsUser(id string) bool {
	return !IsPackage(id)
}
