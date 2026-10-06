package gnofly

import "gno.land/r/g1t2kg2vtr3fukg43eujkn6x53gfdyakhngt4sfd/gnofly/game/v0"

// The market keeps no roles of its own: its admins are the game realm's,
// asked again at every call, as the planes and skins realms do.

// authority is the one question this realm asks about roles.
type authority interface {
	IsAdmin(addr address) bool
}

// gameRoles answers with the roles of the game realm.
type gameRoles struct{}

func (gameRoles) IsAdmin(addr address) bool { return game.IsAdmin(addr) }

// roles is the authority of this realm. It is a variable only so that the
// tests can answer for the game realm, which has no admin under `gno test`.
var roles authority = gameRoles{}

// callerOf returns the verified caller of a crossing function; rlm must be
// its live cur.
func callerOf(_ int, rlm realm) address {
	if !rlm.IsCurrent() {
		panic(errSpoofedRealm)
	}
	return rlm.Previous().Address()
}

// userOf returns the caller, who must be a wallet calling directly: never a
// realm, so that no contract can act in a user's name or wrap a purchase.
func userOf(_ int, rlm realm) address {
	caller := callerOf(0, rlm)
	if !rlm.Previous().IsUserCall() {
		panic(errNotUserCall)
	}
	return caller
}

// assertAdmin panics unless the caller is an admin of the game realm.
func assertAdmin(_ int, rlm realm) address {
	caller := callerOf(0, rlm)
	if !roles.IsAdmin(caller) {
		panic(errNotAdmin)
	}
	return caller
}
