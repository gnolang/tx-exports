// Package echo is gnotif's demo realm: Echo sends a message back to its
// caller as a browser notification.
package echo

import (
	"chain"

	"gno.land/r/g1rzgxl6njyu4c2x89gxvaa9cswrt73rz8mlp7l6/alpha3/gnotif/v0"
)

// The registry sees this realm as the caller, so the trigger is verified.
func init(cur realm) {
	gnotif.Declare(cross(cur), cur.PkgPath(), "Echo", "", "to", "Echo", "{msg}", "/")
}

// Echo sends msg to the browsers that opted in with the caller's address.
// The recipient is always the caller, so nobody can notify another address.
func Echo(cur realm, msg string) {
	chain.Emit("Echo", "to", cur.Previous().Address().String(), "msg", msg)
}

// Render serves one page for every path: what Echo does and where to try it.
func Render(_ string) string {
	return "# Echo\n\n" +
		"Call `Echo` with a message, and gnotif shows it as a notification in the browsers " +
		"that turned on notifications for your own address. Nobody else can send one to you.\n\n" +
		"Try it on [demo.gnotif.xyz](https://demo.gnotif.xyz).\n"
}
