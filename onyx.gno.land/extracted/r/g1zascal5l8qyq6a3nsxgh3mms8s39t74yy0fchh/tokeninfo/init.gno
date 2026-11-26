package tokeninfo

import (
	"chain/runtime"
	"chain/runtime/unsafe"
	"strings"
)

// selfPath is this realm's gnoweb path, e.g. /r/dexvision/tokeninfo.
var selfPath string

// init runs once, inside the MsgAddPackage that deploys the realm. There, and
// only there, unsafe.PreviousRealm() is the deployer and unsafe.CurrentRealm()
// is this realm (interrealm spec v2, section 12.3). Nothing else in the realm
// uses chain/runtime/unsafe: every crossing function reads cur.Previous().
func init() {
	admin = unsafe.PreviousRealm().Address()
	selfPath = strings.TrimPrefix(unsafe.CurrentRealm().PkgPath(), runtime.ChainDomain())
}
