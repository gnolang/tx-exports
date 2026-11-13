package keeper

import (
	"gno.land/p/gnoswap/order/access/manager/v0"
)

var (
	accessState manager.State

	// roleLabels holds every registered role and its label.
	roleLabels map[manager.RoleId]string
)

func init() {
	resetState()
}

// resetState registers the deployment roles and wires the order realm
// selectors. DCA rounds are restricted to DCAKeeperRole from deployment:
// a public round could be sandwiched in one transaction, since the
// executor sets the swap's minimum output. Admin or governance grants the
// role to keepers, or reassigns ExecuteGroup. DCA keepers also force-cancel
// orders that block their group's rounds.
//
// PoolManagerRole manages both DCA and Limit pool whitelists and DCA's per-token
// minimum order sizes and pair price limits. It is kept apart from the keeper
// role so that neither key alone can both pick the pool and price a round:
// a keeper cannot swap below the manager's price limit,
// and a manager cannot run rounds. Limit fills require LimitKeeperRole.
func resetState() {
	accessState = manager.NewState()
	roleLabels = make(map[manager.RoleId]string)

	registerRole(DCAKeeperRole, DCAKeeperLabel)
	registerRole(LimitKeeperRole, LimitKeeperLabel)
	registerRole(PoolManagerRole, PoolManagerLabel)

	for _, selector := range []manager.Selector{SelectorExecuteGroup, SelectorForceCancelOrder} {
		accessState.SetTargetFunctionRole(DCATarget, selector, DCAKeeperRole)
		emitTargetFunctionRoleUpdated(DCATarget, selector, DCAKeeperRole)
	}

	for _, selector := range []manager.Selector{
		SelectorSetTokenMinAmountPerExecution,
		SelectorSetPairPriceLimit,
	} {
		accessState.SetTargetFunctionRole(DCATarget, selector, PoolManagerRole)
		emitTargetFunctionRoleUpdated(DCATarget, selector, PoolManagerRole)
	}

	for _, selector := range []manager.Selector{SelectorAddWhitelistedPool, SelectorRemoveWhitelistedPool} {
		accessState.SetTargetFunctionRole(WhitelistTarget, selector, PoolManagerRole)
		emitTargetFunctionRoleUpdated(WhitelistTarget, selector, PoolManagerRole)
	}

	accessState.SetTargetFunctionRole(LimitTarget, SelectorExecuteOrder, LimitKeeperRole)
	emitTargetFunctionRoleUpdated(LimitTarget, SelectorExecuteOrder, LimitKeeperRole)
}

func registerRole(role manager.RoleId, label string) {
	roleLabels[role] = label
	emitRoleLabel(role, label)
}

// nextCustomRoleId returns the id after the highest registered role,
// assigned by AddRole.
func nextCustomRoleId() manager.RoleId {
	next := manager.RoleId(1)
	for role := range roleLabels {
		if role >= next {
			next = role + 1
		}
	}

	return next
}

func isRegisteredRole(role manager.RoleId) bool {
	_, found := roleLabels[role]
	return found
}

func isLabelTaken(label string) bool {
	for _, existing := range roleLabels {
		if existing == label {
			return true
		}
	}

	return false
}
