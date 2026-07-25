package core

import (
	"gno.land/p/onbloc/ibc/union/app"
	"gno.land/p/onbloc/ibc/union/types"
	core "gno.land/r/onbloc/ibc/union/core"
)

// app.gno: the IBC application registry. RegisterApp installs the calling realm's
// app under its package path; re-registration is rejected by the store.
func (c *coreV1) RegisterApp(_ int, rlm realm, a app.IApp) {
	assertIsRlmCurrent(0, rlm)

	caller := rlm.Previous().PkgPath()
	portId := types.Bytes(caller)
	c.store.RegisterAppAtPort(0, rlm, portId, a)
	core.EmitAppRegistered(0, rlm, portId, caller, false)
}
