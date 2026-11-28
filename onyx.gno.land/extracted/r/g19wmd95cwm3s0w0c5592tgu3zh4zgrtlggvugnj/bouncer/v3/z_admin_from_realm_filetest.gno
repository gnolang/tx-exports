// PKGPATH: gno.land/r/demo/intruder
package intruder

// A foreign realm cannot use admin functions: the caller seen by Bouncer
// is this realm's address, which is not the admin.

import bouncer "gno.land/r/g19wmd95cwm3s0w0c5592tgu3zh4zgrtlggvugnj/bouncer/v3"

func main(cur realm) {
	bouncer.AddAttester(cross(cur), cur.Address())
}

// Error:
// admin only
