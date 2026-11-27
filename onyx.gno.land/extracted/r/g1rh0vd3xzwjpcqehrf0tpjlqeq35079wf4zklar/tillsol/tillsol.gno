// Package tillsol buys a round with an envelope that never reaches the till.
package tillsol

import (
	"chain/runtime/unsafe"

	"gno.land/r/g15c02s5hhdny9uvr9za3xsyn9sw8p0klptrh6kf/cellar/hall"
	"gno.land/r/g15c02s5hhdny9uvr9za3xsyn9sw8p0klptrh6kf/cellar/till"
)

// Solve must be called with -send 100000ugnot. The coins land here, so this
// realm reads the envelope (the chain refuses a send nobody observes), then
// lets the barkeep read the very same envelope.
func Solve(cur realm) {
	if unsafe.OriginSend().AmountOf("ugnot") < till.Price {
		panic("send the price of a round with the call")
	}
	till.BuyRound(cross(cur))
	hall.Claim(cross(cur), "till")
}
