package ucs03_zkgm

import (
	z "gno.land/p/onbloc/ibc/union/zkgm"
	core "gno.land/r/onbloc/ibc/union/core"
)

// RegisterCoreApp registers the proxy App with core under the proxy pkgpath.
// core rejects re-registration, so the App identity is permanent once installed.
func RegisterCoreApp(cur realm) {
	core.RegisterApp(cross(cur), &App{})
}

// RegisterReceiver records the calling realm as an OP_CALL receiver target,
// keyed by its package path. The impl looks it up via store.GetReceiver during
// call dispatch.
func RegisterReceiver(cur realm, receiver z.Zkgmable) {
	receiverPkgPath := cur.Previous().PkgPath()
	store.SetReceiver(0, cur, receiverPkgPath, receiver)
	emitZkgmReceiverRegisteredEvent(receiverPkgPath)
}
