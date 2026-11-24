// PKGPATH: gno.land/r/demo/intruder
package intruder

// A foreign realm cannot attest.

import bouncer "gno.land/r/g19wmd95cwm3s0w0c5592tgu3zh4zgrtlggvugnj/bouncer/v0"

func main(cur realm) {
	h := "0000000000000000000000000000000000000000000000000000000000000000"
	bouncer.Attest(cross(cur), "gno.land/r/demo/vault", h, "0.1.0", h, "x", h, "ipfs://cid", "", 0, 0, 0)
}

// Error:
// attester only
