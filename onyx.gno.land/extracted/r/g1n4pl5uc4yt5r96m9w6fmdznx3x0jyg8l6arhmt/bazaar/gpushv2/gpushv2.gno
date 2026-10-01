package gpushv2

import (
	factory "gno.land/r/g1n4pl5uc4yt5r96m9w6fmdznx3x0jyg8l6arhmt/bazaar/bazaarv5"
)

// Sync writes one wallet's Genesis FeeDiscount into factory.HolderDiscount.
// Called from the Genesis collection on mint/transfer. Previous realm is this pusher.
func Sync(cur realm, owner string, bps int64) {
	if !cur.Previous().IsCode() {
		panic("gpush: collection realm")
	}
	factory.NoteHolderDiscount(cross(cur), owner, bps)
}
