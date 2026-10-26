// Package echo is gnotif's demo realm: Echo sends a message back to its
// caller as a browser notification.
package echo

import (
	"chain"

	"gno.land/r/nym-gfanton001/gnotif/v1"
)

// This realm's gnotif identity opens its handle and sets its trigger at
// deploy. It keeps no handle, so the trigger never changes.
func init(cur realm) {
	me := cur.Sub(gnotif.Subpath)
	h := gnotif.Open(cross(me))
	h.Set(cross(me), "echo", gnotif.Trigger{Event: "Echo", Param: "to", Title: "Echo", Body: "{msg}", Link: "/"})
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
