package bolo

import (
	"chain"
	"chain/runtime"
)

// assertCurrent is the first statement of every crossing function (API C2).
func assertCurrent(cur realm) {
	if !cur.IsCurrent() {
		panic("bolo registry: not the current realm")
	}
}

// assertCodeCaller refuses any caller but a deployed realm (API C11). A maketx run
// script is ephemeral and code at once: it is refused here, as is a user.
func assertCodeCaller(cur realm) {
	if p := cur.Previous(); !p.IsCode() || p.IsEphemeral() {
		panic(ErrNotUserCall)
	}
}

// assertSigner runs right after C11's branch in every write: no session key, in
// either branch (C11), then the caller must be who (API §3.7).
func assertSigner(cur realm, who address) {
	if _, _, _, isSession := runtime.GetSessionInfo(); isSession {
		panic(ErrSessionKey)
	}
	if cur.Previous().Address() != who {
		panic(ErrNotAdmin)
	}
}

// checkCandidate refuses, with ErrSetting, a malformed address (C12: exactly 40
// characters, a lowercase "g" first, then IsValid) and the registry's own address
// and storage-deposit address, which can never accept the admin role (API §3.7).
func checkCandidate(a address) {
	if len(a) != 40 || a[0] != 'g' || !a.IsValid() {
		panic(ErrSetting)
	}
	if a == chain.PackageAddress(registryPath) || a == chain.DeriveStorageDepositAddr(registryPath) {
		panic(ErrSetting)
	}
}
