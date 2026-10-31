// Package mover is the market-shaped half of spike (b)/(c): a separate realm
// that moves a spike/subtoken token it was approved for, through
// RealmTeller — the exact call market/v1.Buy makes on core tokens. It shows
// (1) the approval path works across realms for a sub-realm-created token
// and (2) the lock extension still vetoes the move before reveal.
package mover

import (
	"gno.land/p/nt/grc721/v0"

	"gno.land/r/g19dzk54hhsdc3gllpksuj6gu4a3e6fl8cr6rn4w/minhwa/spike/subtoken"
)

// Move transfers tid from -> to, acting as this realm's own address. The
// ledger only lets that succeed if `from` approved this realm.
func Move(cur realm, tid string, from, to address) {
	if err := subtoken.Token().RealmTeller(0, cur).TransferFrom(0, cur, from, to, grc721.TokenID(tid)); err != nil {
		panic(err)
	}
}
