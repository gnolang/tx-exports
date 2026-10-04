package game

import "chain"

// Roles: one owner, a set of admins, a set of referees.
//
//   - The owner manages the admins and the treasury, and can hand the realm
//     over. The owner is always an admin.
//   - Admins tune the game and manage the referees.
//   - Referees are the game servers. They record kills and nothing else.

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

// assertOwner panics unless the caller is the owner, and returns the caller.
func assertOwner(_ int, rlm realm) address {
	caller := callerOf(0, rlm)
	if !owner.OwnedBy(caller) {
		panic(errNotOwner)
	}
	return caller
}

// assertAdmin panics unless the caller is an admin, and returns the caller.
func assertAdmin(_ int, rlm realm) address {
	caller := callerOf(0, rlm)
	if !IsAdmin(caller) {
		panic(errNotAdmin)
	}
	return caller
}

// assertReferee panics unless the caller is a referee, and returns the caller.
func assertReferee(_ int, rlm realm) address {
	caller := callerOf(0, rlm)
	if !IsReferee(caller) {
		panic(errNotReferee)
	}
	return caller
}

// TransferOwnership hands the realm over to newOwner. Owner only.
//
// The previous owner keeps no privilege, unless it was also added to the
// admin or referee lists.
func TransferOwnership(cur realm, newOwner address) {
	// ownable checks the caller and the address. It would take the address
	// written in capitals though, and an owner under that key could never be
	// matched to a caller again: see validAddress.
	if newOwner.IsValid() && !validAddress(newOwner) {
		panic(errInvalidAddress)
	}
	if err := owner.TransferOwnership(0, cur, newOwner); err != nil {
		panic(err)
	}
	bump()
}

// AddAdmin adds addr to the admin list. Owner only.
func AddAdmin(cur realm, addr address) {
	assertOwner(0, cur)
	if !validAddress(addr) {
		panic(errInvalidAddress)
	}
	if admins.Set(addr.String(), nil) {
		panic(errAlreadyAdmin)
	}
	bump()
	chain.Emit("AdminAdded", "address", addr.String())
}

// RemoveAdmin removes addr from the admin list. Owner only.
//
// The owner is an admin by definition and cannot be demoted this way, use
// TransferOwnership.
func RemoveAdmin(cur realm, addr address) {
	assertOwner(0, cur)
	if _, removed := admins.Remove(addr.String()); !removed {
		panic(errNoSuchAdmin)
	}
	bump()
	chain.Emit("AdminRemoved", "address", addr.String())
}

// SetTreasury sets the address the sales of skins and planes are forwarded
// to. Owner only.
func SetTreasury(cur realm, addr address) {
	assertOwner(0, cur)
	if !validAddress(addr) {
		panic(errInvalidAddress)
	}
	// Coins sent to the realm's own address would be stuck: nothing here
	// ever spends the realm balance.
	if addr == cur.Address() {
		panic(errTreasurySelf)
	}
	treasury = addr
	bump()
	chain.Emit("TreasurySet", "address", addr.String())
}

// AddReferee allows addr to submit kills. Admin only.
func AddReferee(cur realm, addr address) {
	assertAdmin(0, cur)
	if !validAddress(addr) {
		panic(errInvalidAddress)
	}
	if referees.Set(addr.String(), nil) {
		panic(errAlreadyReferee)
	}
	bump()
	chain.Emit("RefereeAdded", "address", addr.String())
}

// RemoveReferee stops addr from submitting kills. Admin only.
func RemoveReferee(cur realm, addr address) {
	assertAdmin(0, cur)
	if _, removed := referees.Remove(addr.String()); !removed {
		panic(errNoSuchReferee)
	}
	bump()
	chain.Emit("RefereeRemoved", "address", addr.String())
}

// Owner returns the owner of the realm.
func Owner() address {
	return owner.Owner()
}

// Treasury returns the address the sales of skins and planes are forwarded
// to.
func Treasury() address {
	return treasury
}

// IsAdmin reports whether addr is an admin. The owner always is.
func IsAdmin(addr address) bool {
	return owner.OwnedBy(addr) || admins.Has(addr.String())
}

// IsReferee reports whether addr may submit kills.
func IsReferee(addr address) bool {
	return referees.Has(addr.String())
}
