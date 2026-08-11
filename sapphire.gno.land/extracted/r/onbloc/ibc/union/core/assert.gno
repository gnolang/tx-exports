package core

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
