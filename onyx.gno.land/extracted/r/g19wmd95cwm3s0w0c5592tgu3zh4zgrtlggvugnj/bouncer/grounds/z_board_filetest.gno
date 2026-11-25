// PKGPATH: gno.land/r/demo/hunter
package hunter

import (
	"gno.land/r/g19wmd95cwm3s0w0c5592tgu3zh4zgrtlggvugnj/bouncer/grounds"
	"gno.land/r/g19wmd95cwm3s0w0c5592tgu3zh4zgrtlggvugnj/bouncer/grounds/b01"
)

func main(cur realm) {
	b01.Ledger().Set(string(cur.Address()), int64(7))
	b01.Claim(cross(cur))
	board := grounds.Board()
	println(len(board), board[0].Ground, board[0].Hunter == cur.Address())
}

// Output:
// 1 B01 true
