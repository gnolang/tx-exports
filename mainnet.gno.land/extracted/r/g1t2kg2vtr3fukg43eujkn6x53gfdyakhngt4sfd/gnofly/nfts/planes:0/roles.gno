package planes

import "gno.land/r/g1t2kg2vtr3fukg43eujkn6x53gfdyakhngt4sfd/gnofly/game/v0"

// The planes realm keeps no roles of its own. Who administers it and where
// its money goes are the answers of the game realm, asked again at every
// call: an admin removed there is refused here in the same block, and a
// treasury moved there receives the next mint.

// authority is the set of questions this realm asks about roles.
type authority interface {
	IsAdmin(addr address) bool
	Treasury() address
}

// gameRoles answers with the roles of the game realm.
type gameRoles struct{}

func (gameRoles) IsAdmin(addr address) bool { return game.IsAdmin(addr) }
func (gameRoles) Treasury() address         { return game.Treasury() }

// roles is the authority of this realm: the game realm, always.
//
// It is a variable for one reason. Under `gno test` an imported realm is
// initialized without a deployer, and a test of this package has no way to
// become an admin of the game realm, so the tests put their own answers
// here. Nothing outside the test files assigns it, and there is no setter.
var roles authority = gameRoles{}

// callerOf returns the verified caller of a crossing function. rlm must be
// the cur of the crossing function calling this helper: a stale or forged
// realm value fails IsCurrent, and Previous is only meaningful on a live one.
//
// It takes the realm in second position on purpose, like p/nt/ownable does:
// a function whose first parameter is a realm is a crossing function.
func callerOf(_ int, rlm realm) address {
	if !rlm.IsCurrent() {
		panic(errSpoofedRealm)
	}
	return rlm.Previous().Address()
}

// assertAdmin panics unless the caller is an admin of the game realm, and
// returns the caller.
func assertAdmin(_ int, rlm realm) address {
	caller := callerOf(0, rlm)
	if !roles.IsAdmin(caller) {
		panic(errNotAdmin)
	}
	return caller
}
