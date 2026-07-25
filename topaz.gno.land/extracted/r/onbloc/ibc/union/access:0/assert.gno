package access

import "gno.land/p/onbloc/access/manager"

func assertIsRlmCurrent(_ int, rlm realm) {
	if !rlm.IsCurrent() {
		panic(ErrSpoofedRealm)
	}
}

// AssertCanCall panics unless caller can call selector on the calling realm's target path.
// Union reference:
// https://github.com/unionlabs/union/blob/8cff0ff34f6baa4cdb1e4650a08985dd05de0c5a/cosmwasm/access-managed/src/restricted.rs#L38-L66
func AssertCanCall(_ int, rlm realm, selector manager.Selector) {
	assertIsRlmCurrent(0, rlm)

	caller := rlm.Previous().Address()
	target := rlm.PkgPath()
	if !accessState.IsAuthorized(caller, target, selector) {
		panic(AccessManagerUnauthorizedCallError(caller, target, selector))
	}
}

func assertCanManageTarget(_ int, rlm realm) {
	caller := rlm.Previous().Address()
	if !accessState.CanManageTarget(caller).Immediate {
		panic(AccessManagerUnauthorizedAccountError(caller, manager.AdminRole))
	}
}

func assertCanAdminRole(_ int, rlm realm, role manager.RoleId) {
	caller := rlm.Previous().Address()
	if !accessState.CanAdminRole(role, caller).Immediate {
		panic(AccessManagerUnauthorizedAccountError(caller, accessState.GetRoleAdmin(role)))
	}
}
