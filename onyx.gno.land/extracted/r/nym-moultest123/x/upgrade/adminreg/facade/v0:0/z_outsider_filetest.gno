// PKGPATH: gno.land/r/nym-moultest123/main
package main

import "gno.land/r/nym-moultest123/x/upgrade/adminreg/facade/v0"

// Nominating is bounded by path even though accepting is bounded by owner: a
// realm outside the prefix cannot even fill the candidate list with noise.
func main(cur realm) {
	facade.Propose(cross(cur), nil)
}

// Error:
// unauthorized: gno.land/r/nym-moultest123/main is not under gno.land/r/nym-moultest123/x/upgrade/adminreg/impl/
