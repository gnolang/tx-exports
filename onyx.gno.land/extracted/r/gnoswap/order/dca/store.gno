package dca

import (
	"errors"

	pdca "gno.land/p/gnoswap/order/dca/v0"
	"gno.land/p/gnoswap/store/v1"
	bptree "gno.land/p/nt/bptree/v0"
	ufmt "gno.land/p/nt/ufmt/v0"
)

// NewBPTreeN allocates an empty B+tree in the order/dca realm.
// Implementations create the store trees through it,
// so the trees are owned by the realm that stores them.
func NewBPTreeN(fanout int) *bptree.BPTree {
	return bptree.NewBPTreeN(fanout)
}

// StoreKey is a key of the DCA KV store.
type StoreKey string

func (s StoreKey) String() string {
	return string(s)
}

// Store layout. Tree keys are built by the pdca key helpers.
//
//	orders               OrderKey -> *Order
//	ordersByOwner        OwnerOrderKey -> orderID
//	groups               groupID -> *Group
//	scheduledGroups      ScheduleKey -> groupID, groups with orderAmount > 0 only
//	nextOrderID          uint64
//	config               *Config
//	executing            true while ExecuteGroup is inside its pool swap
//	ordersByGroup        GroupOrderKey -> orderID, active orders only
//	pendingExecutionFees  tokenPath -> int64, fees not yet sent to protocol_fee
//	executionLogs        ExecutionLogKey -> lastRound uint64, unreleased logs of active orders
//	orderAmountsByGroup  GroupOrderAmountKey -> endRound, orders by executionFeeRate, then amountPerExecution
//	tokenMinAmountsPerExecution  tokenPath -> int64, per-token minimum input per execution
//	pairPriceLimits      PairKey -> *PairPriceLimit, minimum pool output per input of a pair direction
const (
	StoreKeyOrders               StoreKey = "orders"
	StoreKeyOrdersByOwner        StoreKey = "ordersByOwner"
	StoreKeyGroups               StoreKey = "groups"
	StoreKeyScheduledGroups      StoreKey = "scheduledGroups"
	StoreKeyNextOrderID          StoreKey = "nextOrderID"
	StoreKeyConfig               StoreKey = "config"
	StoreKeyExecuting            StoreKey = "executing"
	StoreKeyOrdersByGroup        StoreKey = "ordersByGroup"
	StoreKeyPendingExecutionFees StoreKey = "pendingExecutionFees"
	StoreKeyExecutionLogs        StoreKey = "executionLogs"
	StoreKeyOrderAmountsByGroup  StoreKey = "orderAmountsByGroup"

	StoreKeyTokenMinAmountsPerExecution StoreKey = "tokenMinAmountsPerExecution"
	StoreKeyPairPriceLimits             StoreKey = "pairPriceLimits"
)

type dcaOrderStore struct {
	kvStore store.KVStore
}

// NewDCAOrderStore wraps the domain KV store.
func NewDCAOrderStore(kvStore store.KVStore) pdca.IDCAOrderStore {
	return &dcaOrderStore{kvStore: kvStore}
}

func (s *dcaOrderStore) getTree(key StoreKey) *bptree.BPTree {
	tree, err := s.kvStore.GetBPTree(key.String())
	if err != nil {
		panic(err.Error())
	}

	if tree == nil {
		panic(ufmt.Sprintf(errNilValue, key.String()))
	}

	return tree
}

func (s *dcaOrderStore) setTree(_ int, rlm realm, key StoreKey, tree *bptree.BPTree) error {
	if !rlm.IsCurrent() {
		return errors.New(ErrSpoofedRealm)
	}

	if tree == nil {
		return ufmt.Errorf(errNilValue, key.String())
	}

	return s.kvStore.Set(0, rlm, key.String(), tree)
}

func (s *dcaOrderStore) HasOrders() bool { return s.kvStore.Has(StoreKeyOrders.String()) }

func (s *dcaOrderStore) GetOrders() *bptree.BPTree { return s.getTree(StoreKeyOrders) }

func (s *dcaOrderStore) SetOrders(_ int, rlm realm, orders *bptree.BPTree) error {
	return s.setTree(0, rlm, StoreKeyOrders, orders)
}

func (s *dcaOrderStore) HasOrdersByOwner() bool {
	return s.kvStore.Has(StoreKeyOrdersByOwner.String())
}

func (s *dcaOrderStore) GetOrdersByOwner() *bptree.BPTree { return s.getTree(StoreKeyOrdersByOwner) }

func (s *dcaOrderStore) SetOrdersByOwner(_ int, rlm realm, ordersByOwner *bptree.BPTree) error {
	return s.setTree(0, rlm, StoreKeyOrdersByOwner, ordersByOwner)
}

func (s *dcaOrderStore) HasOrdersByGroup() bool {
	return s.kvStore.Has(StoreKeyOrdersByGroup.String())
}

func (s *dcaOrderStore) GetOrdersByGroup() *bptree.BPTree { return s.getTree(StoreKeyOrdersByGroup) }

func (s *dcaOrderStore) SetOrdersByGroup(_ int, rlm realm, ordersByGroup *bptree.BPTree) error {
	return s.setTree(0, rlm, StoreKeyOrdersByGroup, ordersByGroup)
}

func (s *dcaOrderStore) HasGroups() bool { return s.kvStore.Has(StoreKeyGroups.String()) }

func (s *dcaOrderStore) GetGroups() *bptree.BPTree { return s.getTree(StoreKeyGroups) }

func (s *dcaOrderStore) SetGroups(_ int, rlm realm, groups *bptree.BPTree) error {
	return s.setTree(0, rlm, StoreKeyGroups, groups)
}

func (s *dcaOrderStore) HasScheduledGroups() bool {
	return s.kvStore.Has(StoreKeyScheduledGroups.String())
}

func (s *dcaOrderStore) GetScheduledGroups() *bptree.BPTree {
	return s.getTree(StoreKeyScheduledGroups)
}

func (s *dcaOrderStore) SetScheduledGroups(_ int, rlm realm, groups *bptree.BPTree) error {
	return s.setTree(0, rlm, StoreKeyScheduledGroups, groups)
}

func (s *dcaOrderStore) HasNextOrderID() bool { return s.kvStore.Has(StoreKeyNextOrderID.String()) }

func (s *dcaOrderStore) GetNextOrderID() uint64 {
	id, err := s.kvStore.GetUint64(StoreKeyNextOrderID.String())
	if err != nil {
		panic(err.Error())
	}

	return id
}

func (s *dcaOrderStore) SetNextOrderID(_ int, rlm realm, id uint64) error {
	if !rlm.IsCurrent() {
		return errors.New(ErrSpoofedRealm)
	}

	return s.kvStore.Set(0, rlm, StoreKeyNextOrderID.String(), id)
}

func (s *dcaOrderStore) HasConfig() bool { return s.kvStore.Has(StoreKeyConfig.String()) }

func (s *dcaOrderStore) GetConfig() *pdca.Config {
	result, err := s.kvStore.Get(StoreKeyConfig.String())
	if err != nil {
		panic(err.Error())
	}

	config, ok := result.(*pdca.Config)
	if !ok || config == nil {
		panic(ufmt.Sprintf(errInvalidConfigType, result))
	}

	return config
}

func (s *dcaOrderStore) SetConfig(_ int, rlm realm, config *pdca.Config) error {
	if !rlm.IsCurrent() {
		return errors.New(ErrSpoofedRealm)
	}

	if config == nil {
		return errors.New(errNilConfig)
	}

	return s.kvStore.Set(0, rlm, StoreKeyConfig.String(), config)
}

// IsExecuting reports whether a group execution is inside its swap.
// The flag is in the proxy store,
// so every version and UpgradeImpl share the same re-entrancy guard.
func (s *dcaOrderStore) IsExecuting() bool {
	if !s.kvStore.Has(StoreKeyExecuting.String()) {
		return false
	}

	executing, err := s.kvStore.GetBool(StoreKeyExecuting.String())
	if err != nil {
		panic(err.Error())
	}

	return executing
}

func (s *dcaOrderStore) SetExecuting(_ int, rlm realm, executing bool) error {
	if !rlm.IsCurrent() {
		return errors.New(ErrSpoofedRealm)
	}

	return s.kvStore.Set(0, rlm, StoreKeyExecuting.String(), executing)
}

func (s *dcaOrderStore) HasPendingExecutionFees() bool {
	return s.kvStore.Has(StoreKeyPendingExecutionFees.String())
}

func (s *dcaOrderStore) GetPendingExecutionFees() *bptree.BPTree {
	return s.getTree(StoreKeyPendingExecutionFees)
}

func (s *dcaOrderStore) SetPendingExecutionFees(_ int, rlm realm, pendingExecutionFees *bptree.BPTree) error {
	return s.setTree(0, rlm, StoreKeyPendingExecutionFees, pendingExecutionFees)
}

func (s *dcaOrderStore) HasExecutionLogs() bool {
	return s.kvStore.Has(StoreKeyExecutionLogs.String())
}

func (s *dcaOrderStore) GetExecutionLogs() *bptree.BPTree {
	return s.getTree(StoreKeyExecutionLogs)
}

func (s *dcaOrderStore) SetExecutionLogs(_ int, rlm realm, executionLogs *bptree.BPTree) error {
	return s.setTree(0, rlm, StoreKeyExecutionLogs, executionLogs)
}

func (s *dcaOrderStore) HasOrderAmountsByGroup() bool {
	return s.kvStore.Has(StoreKeyOrderAmountsByGroup.String())
}

func (s *dcaOrderStore) GetOrderAmountsByGroup() *bptree.BPTree {
	return s.getTree(StoreKeyOrderAmountsByGroup)
}

func (s *dcaOrderStore) SetOrderAmountsByGroup(_ int, rlm realm, orderAmountsByGroup *bptree.BPTree) error {
	return s.setTree(0, rlm, StoreKeyOrderAmountsByGroup, orderAmountsByGroup)
}

func (s *dcaOrderStore) HasTokenMinAmountsPerExecution() bool {
	return s.kvStore.Has(StoreKeyTokenMinAmountsPerExecution.String())
}

func (s *dcaOrderStore) GetTokenMinAmountsPerExecution() *bptree.BPTree {
	return s.getTree(StoreKeyTokenMinAmountsPerExecution)
}

func (s *dcaOrderStore) SetTokenMinAmountsPerExecution(_ int, rlm realm, tokenMinAmounts *bptree.BPTree) error {
	return s.setTree(0, rlm, StoreKeyTokenMinAmountsPerExecution, tokenMinAmounts)
}

func (s *dcaOrderStore) HasPairPriceLimits() bool {
	return s.kvStore.Has(StoreKeyPairPriceLimits.String())
}

func (s *dcaOrderStore) GetPairPriceLimits() *bptree.BPTree {
	return s.getTree(StoreKeyPairPriceLimits)
}

func (s *dcaOrderStore) SetPairPriceLimits(_ int, rlm realm, pairPriceLimits *bptree.BPTree) error {
	return s.setTree(0, rlm, StoreKeyPairPriceLimits, pairPriceLimits)
}
