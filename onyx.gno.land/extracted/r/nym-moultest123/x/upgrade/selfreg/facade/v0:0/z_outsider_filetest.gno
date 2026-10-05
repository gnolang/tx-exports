// PKGPATH: gno.land/r/nym-moultest123/main
package main

import "gno.land/r/nym-moultest123/x/upgrade/selfreg/facade/v0"

// A realm outside the guarded prefix cannot seize the facade. The path is read
// off the crossing frame, so there is no argument to lie about.
func main(cur realm) {
	facade.Register(cross(cur), nil)
}

// Error:
// unauthorized: gno.land/r/nym-moultest123/main is not under gno.land/r/nym-moultest123/x/upgrade/selfreg/impl/
