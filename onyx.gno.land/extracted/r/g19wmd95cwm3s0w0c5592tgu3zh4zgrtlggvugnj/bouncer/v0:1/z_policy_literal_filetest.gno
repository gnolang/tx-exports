// PKGPATH: gno.land/r/demo/lending
package lending

// Pins the VM rule that makes Custom() necessary: another realm cannot
// allocate a Bouncer-declared type with a composite literal.

import bouncer "gno.land/r/g19wmd95cwm3s0w0c5592tgu3zh4zgrtlggvugnj/bouncer/v0"

func main(cur realm) {
	_ = bouncer.Check("gno.land/r/demo/vault", bouncer.Policy{MinScore: 10})
}

// Error:
// cannot allocate gno.land/r/g19wmd95cwm3s0w0c5592tgu3zh4zgrtlggvugnj/bouncer/v0.Policy in realm gno.land/r/demo/lending
