package core

import (
	"gno.land/p/onbloc/ibc/union/app"
)

// RegisterApp registers an IBC application at the caller realm's package path,
// delegating to the installed mustGetImpl().
func RegisterApp(cur realm, app app.IApp) {
	mustGetImpl().RegisterApp(0, cur, app)
}

// HasApp reports whether an app is registered at portId.
func HasApp(portId []byte) bool {
	_, ok := store.ports[string(portId)]
	return ok
}
