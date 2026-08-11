// Package impl is the v1 implementation of the IBC host logic for the
// gno.land/r/onbloc/ibc/union/core proxy. The proxy keeps the stable identity
// (admin, package address), the Store, and the app registry; this realm holds
// the swappable protocol logic and is injected with the proxy-owned store
// (core.IStore) at install time.
//
// core/v1 implements the client, connection, channel, packet, app registry, and
// query surfaces behind the proxy's ICore interface.
package core

import (
	core "gno.land/r/onbloc/ibc/union/core"
)

// coreV1 holds the injected proxy state and contains the host logic. State writes
// go through the store's borrow-rule setters: c.store.SetXxx(0, rlm, ...).
type coreV1 struct {
	store core.IStore
}

var _ core.ICore = (*coreV1)(nil)

// New constructs a fresh v1 impl. The store is injected by the proxy at install
// time via SetStore, so it is nil until installed.
func NewCoreV1(s core.IStore) core.ICore {
	return &coreV1{store: s}
}

// resolveRelayer defaults an empty relayer string to the authenticated caller.
// The client lifecycle message constructors leave Relayer empty, so without this
// the light-client callbacks would receive the zero address; union likewise
// reuses info.sender as the relayer on the paths that do not carry one.
func resolveRelayer(caller address, relayer string) address {
	if relayer == "" {
		return caller
	}

	return address(relayer)
}
