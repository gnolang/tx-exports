package bellica

import (
	"chain"
	"chain/runtime/unsafe"

	"gno.land/p/g1ac3v8vr4ddr2m7g68gkksz3f463v9x95w05pnl/bellica/core/v1"
)

// db is all of Bellica's state. The path and address are captured at deploy
// time, when the current realm is this one (Render can be reached through
// other frames).
var db = func() *core.State {
	r := unsafe.CurrentRealm()
	s := core.NewState(r.PkgPath(), r.Address())
	s.Emit = emit
	return s
}()

// emit is how the Bellica packages record events, so every event carries
// this realm's pkg_path.
func emit(typ string, attrs ...string) { chain.Emit(typ, attrs...) }
