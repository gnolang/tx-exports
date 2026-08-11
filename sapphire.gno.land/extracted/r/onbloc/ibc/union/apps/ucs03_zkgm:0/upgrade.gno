package ucs03_zkgm

import (
	"strings"

	"gno.land/r/onbloc/ibc/union/access"
)

func ProxyPkgPath() string {
	return proxyPkgPath
}

func ProxyAddress() address {
	return proxyAddress
}

// RegisterImpl records an impl constructor under the calling realm's package
// path. It is called from the impl realm's init, so the path is permanent once
// installed: re-registration is rejected. The caller must be a sub-realm of this
// proxy (its path must be prefixed by the proxy path), matching core's host
// registration rule.
func RegisterImpl(cur realm, constructor func(store IStore) IApp) {
	currentPath := cur.PkgPath()
	previousPath := cur.Previous().PkgPath()

	prefix := currentPath + "/"

	if !strings.HasPrefix(previousPath, prefix) {
		panic("previous impl path is not a prefix of the current impl path")
	}

	if _, ok := implConstructors[previousPath]; ok {
		panic("impl already registered")
	}

	implConstructors[previousPath] = constructor
}

// UpdateImpl installs or re-points the implementation following the bootstrap and
// steady-state tiers of the trust model. It is admin-gated and injects the
// proxy-owned store into the registered constructor for path.
func UpdateImpl(cur realm, path string) {
	access.AssertCanCall(0, cur, SelectorUpdateImpl)

	constructor, ok := implConstructors[path]
	if !ok {
		panic("impl constructor not found")
	}

	oldImplPath := currentImplPath
	currentImplPath = path
	currentImpl = constructor(store)
	emitZkgmImplUpdatedEvent(cur.Previous().PkgPath(), oldImplPath, path, []string{path})
}

// mustGetImpl returns the installed impl, panicking until the first UpdateImpl.
func mustGetImpl() IApp {
	if currentImpl == nil {
		panic("implementation not installed")
	}

	return currentImpl
}
