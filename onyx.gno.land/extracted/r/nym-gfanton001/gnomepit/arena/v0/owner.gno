package arena

import (
	"chain/runtime"

	"gno.land/p/nt/ownable/v0"
	"gno.land/r/nym-gfanton001/gnomepit/standings/v0"
)

var (
	owner   *ownable.Ownable
	retired bool
)

func init(cur realm) {
	owner = ownable.NewWithAddress(cur.Previous().Address())
}

// Retire closes the arena to new challenges and acceptances, for good. Matches already
// running play out and are rated, and an open challenge can still be withdrawn. Owner
// only.
func Retire(cur realm) {
	refuseSession()
	owner.AssertOwnedBy(cur.Previous().Address())
	retired = true
}

// TransferOwnership makes newOwner the owner. Owner only.
func TransferOwnership(cur realm, newOwner address) {
	refuseSession()
	if err := owner.TransferOwnership(0, cur, newOwner); err != nil {
		panic(err.Error())
	}
}

// Retired reports whether the owner has retired the arena.
func Retired() bool {
	return retired
}

// Owner is the address that may retire the arena.
func Owner() address {
	return owner.Owner()
}

// refuseSession refuses a call signed with a session key: the page signs a match's moves
// with one, so an owner who plays from the owner's wallet must not hand it the owner's calls.
func refuseSession() {
	if _, _, _, isSession := runtime.GetSessionInfo(); isSession {
		panic("sign with the owner's own key, not a session key")
	}
}

// mustBeOpen refuses a new match on a retired arena, or on one the standings realm takes no
// results from.
func mustBeOpen() {
	if retired {
		panic("arena retired")
	}
	if !standings.IsWriter(self) {
		panic("arena not open")
	}
}
