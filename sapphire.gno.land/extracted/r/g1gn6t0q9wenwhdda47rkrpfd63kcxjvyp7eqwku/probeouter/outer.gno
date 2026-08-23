// The payable outer realm, standing in for a marketplace Buy().
package probeouter

import (
	"chain/runtime/unsafe"

	"gno.land/r/g1gn6t0q9wenwhdda47rkrpfd63kcxjvyp7eqwku/probeinner"
)

var Outer, Inner string

// Buy takes coins, then calls into another realm exactly the way a
// marketplace would have to call nslogic.TransferFrom.
func Buy(cur realm) string {
	s := unsafe.OriginSend()
	if s.IsZero() {
		Outer = "zero"
	} else {
		Outer = s.String()
	}
	Inner = probeinner.Note(cross(cur))
	return "outer=" + Outer + " inner=" + Inner
}

func Render(path string) string { return "outer=" + Outer + " inner=" + Inner }
