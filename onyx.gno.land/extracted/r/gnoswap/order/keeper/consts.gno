package keeper

import (
	"gno.land/p/gnoswap/order/access/manager/v0"
)

// Roles registered at deployment.
const (
	DCAKeeperRole   manager.RoleId = 1
	LimitKeeperRole manager.RoleId = 2
	PoolManagerRole manager.RoleId = 3
)

// Role labels registered at deployment.
const (
	DCAKeeperLabel   = "DCA_ORDER_KEEPER"
	LimitKeeperLabel = "LIMIT_ORDER_KEEPER"
	PoolManagerLabel = "POOL_MANAGER"
)

// Order realm targets and keeper selectors.
const (
	DCATarget                                      = "gno.land/r/gnoswap/order/dca"
	SelectorExecuteGroup          manager.Selector = "ExecuteGroup"
	SelectorAddWhitelistedPool    manager.Selector = "AddWhitelistedPool"
	SelectorRemoveWhitelistedPool manager.Selector = "RemoveWhitelistedPool"
	SelectorForceCancelOrder      manager.Selector = "ForceCancelOrder"

	SelectorSetTokenMinAmountPerExecution manager.Selector = "SetTokenMinAmountPerExecution"
	SelectorSetPairPriceLimit             manager.Selector = "SetPairPriceLimit"

	LimitTarget                           = "gno.land/r/gnoswap/order/limit"
	SelectorExecuteOrder manager.Selector = "ExecuteOrder"

	WhitelistTarget = "gno.land/r/gnoswap/order/whitelist"
)

// maxLabelLength bounds a role label.
const maxLabelLength = 64
