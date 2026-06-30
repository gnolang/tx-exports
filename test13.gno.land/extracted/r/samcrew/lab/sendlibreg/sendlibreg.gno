package sendlibreg

import (
	"chain/runtime"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/samcrew/lab/lziface"
)

// XXX: could probably be moved in the endpoint

var (
	sendLibs = avl.NewTree()
)

func Register(cur realm, app lziface.SendLib) {
	pkgPath := runtime.PreviousRealm().PkgPath()
	if app == nil {
		sendLibs.Remove(pkgPath)
		return
	}
	sendLibs.Set(pkgPath, app)
}

func Get(pkgPath string) lziface.SendLib {
	iface, ok := sendLibs.Get(pkgPath)
	if !ok {
		return nil
	}
	return iface.(lziface.SendLib)
}
