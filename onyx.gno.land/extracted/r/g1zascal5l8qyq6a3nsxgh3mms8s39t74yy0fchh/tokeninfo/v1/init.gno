package tokeninfo

import (
	"chain/runtime"
	"strings"
)

// selfPath is this realm's gnoweb path, e.g. /r/<addr>/tokeninfo/v1.
var selfPath string

// init runs once, in the transaction that deploys the realm: the previous
// realm is the account that published it, which moderates until it calls
// TransferAdmin.
func init(cur realm) {
	admin = cur.Previous().Address()
	selfPath = strings.TrimPrefix(cur.PkgPath(), runtime.ChainDomain())
}
