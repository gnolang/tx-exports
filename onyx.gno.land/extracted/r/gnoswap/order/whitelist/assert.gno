package whitelist

import (
	"gno.land/p/gnoswap/order/access/manager/v0"
	pwhitelist "gno.land/p/gnoswap/order/whitelist/v0"
	prbac "gno.land/p/gnoswap/rbac/v1"
	ufmt "gno.land/p/nt/ufmt/v0"

	"gno.land/r/gnoswap/access/v1"
	"gno.land/r/gnoswap/common"
	"gno.land/r/gnoswap/order/keeper"
	"gno.land/r/gnoswap/pool"
)

func assertIsManagerCall(_ int, rlm realm, selector manager.Selector) realm {
	access.AssertIsRlmCurrent(0, rlm)
	common.AssertIsNotHandleNativeCoin()

	prev := rlm.Previous()
	caller := prev.Address()

	if access.IsAuthorized(prbac.ROLE_ADMIN.String(), caller) || access.IsAuthorized(prbac.ROLE_GOVERNANCE.String(), caller) || keeper.IsAuthorized(rlm.PkgPath(), selector, caller) {
		return prev
	}

	panic(makeErrorWithDetails(errUnauthorized, ufmt.Sprintf("caller(%s) selector(%s)", caller.String(), string(selector))).Error())
}

func assertIsValidTarget(target string) {
	if target != TargetDCA && target != TargetLimit {
		panic(makeErrorWithDetails(errInvalidTarget, ufmt.Sprintf("target(%s)", target)).Error())
	}
}

func assertIsExistingPool(poolPath string) {
	if !pool.ExistsPoolPath(poolPath) {
		panic(makeErrorWithDetails(errInvalidPool, ufmt.Sprintf("poolPath(%s) does not exist", poolPath)).Error())
	}
}

func assertIsNotWhitelistedPool(state *pwhitelist.State, target, poolPath string) {
	if state.HasPool(poolPath) {
		panic(makeErrorWithDetails(errInvalidPool, ufmt.Sprintf("target(%s) poolPath(%s) is already whitelisted", target, poolPath)).Error())
	}
}

func assertIsWhitelistedPool(state *pwhitelist.State, target, poolPath string) {
	if !state.HasPool(poolPath) {
		panic(makeErrorWithDetails(errInvalidPool, ufmt.Sprintf("target(%s) poolPath(%s) is not whitelisted", target, poolPath)).Error())
	}
}
