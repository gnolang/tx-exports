package ucs03_zkgm

import "gno.land/r/onbloc/ibc/union/access"

// assert.gno holds the proxy's trust gates. The App receiver surface is reachable
// only through core (assertIsCoreRealm), while governance entrypoints use the app's
// access manager state. State writes are gated by the interrealm borrow rule on
// the injected store, so no separate impl-realm gate is needed here.

func assertIsCoreRealm(cur realm) {
	if cur.Previous().PkgPath() != access.CoreRealmPath {
		panic(ErrNotCoreRealm)
	}
}

func assertIsRlmCurrent(_ int, rlm realm) {
	if !rlm.IsCurrent() {
		panic(ErrSpoofedRealm)
	}
}

func assertIsProxyRealm(_ int, rlm realm) {
	if rlm.PkgPath() != proxyPkgPath {
		panic(ErrNotProxyRealm)
	}
}

func assertIsNotPaused() {
	if paused {
		panic("paused")
	}
}
