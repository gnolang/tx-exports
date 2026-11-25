// PKGPATH: gno.land/r/demo/hunter
package hunter

import (
	ground "gno.land/r/g19wmd95cwm3s0w0c5592tgu3zh4zgrtlggvugnj/bouncer/grounds/b01"
)

func main(cur realm) {
	println(ground.Broken())
	// Break it: credit this realm through the leaked tree.
	ground.Ledger().Set(string(cur.Address()), int64(1000000))
	println(ground.Broken())
	ground.Claim(cross(cur))
	hs := ground.Hunters()
	println(len(hs), hs[0].Addr == cur.Address(), hs[0].Credited, hs[0].Paid)
}

// Output:
// false
// true
// 1 true 1000000 0
