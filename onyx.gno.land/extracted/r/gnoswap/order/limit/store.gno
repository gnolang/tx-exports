package limit

import (
	"errors"

	plimit "gno.land/p/gnoswap/order/limit/v0"
	"gno.land/p/gnoswap/store/v1"
	bptree "gno.land/p/nt/bptree/v0"
	ufmt "gno.land/p/nt/ufmt/v0"
)

// NewBPTreeN allocates an empty B+tree in the order/limit realm.
// Implementations create the store trees through it,
// so the trees are owned by the realm that stores them.
func NewBPTreeN(fanout int) *bptree.BPTree {
	return bptree.NewBPTreeN(fanout)
}

// StoreKey is a key of the limit order KV store.
type StoreKey string

func (s StoreKey) String() string {
	return string(s)
}

// Store layout. Tree keys are built by the plimit key helpers.
//
//	orders         OrderKey -> *Order, pending orders only
//	ordersByOwner  OwnerOrderKey -> orderID, pending orders only
//	pendingExecutionFees tokenPath -> int64, held until the protocol fee collector accepts them
//	nextOrderID    uint64
//	config         *Config
const (
	StoreKeyOrders               StoreKey = "orders"
	StoreKeyOrdersByOwner        StoreKey = "ordersByOwner"
	StoreKeyPendingExecutionFees StoreKey = "pendingExecutionFees"
	StoreKeyNextOrderID          StoreKey = "nextOrderID"
	StoreKeyConfig               StoreKey = "config"
)

type limitOrderStore struct {
	kvStore store.KVStore
}

// NewLimitOrderStore wraps the domain KV store.
func NewLimitOrderStore(kvStore store.KVStore) plimit.ILimitOrderStore {
	return &limitOrderStore{kvStore: kvStore}
}

// set writes key after checking that rlm is the current realm.
// The KV store additionally enforces its write ACL for code realms.
func (s *limitOrderStore) set(_ int, rlm realm, key string, value any) error {
	if !rlm.IsCurrent() {
		return errors.New(ErrSpoofedRealm)
	}

	return s.kvStore.Set(0, rlm, key, value)
}

func (s *limitOrderStore) getTree(key StoreKey) *bptree.BPTree {
	tree, err := s.kvStore.GetBPTree(key.String())
	if err != nil {
		panic(err.Error())
	}

	if tree == nil {
		panic(ufmt.Sprintf(errNilValue, key.String()))
	}

	return tree
}

func (s *limitOrderStore) setTree(_ int, rlm realm, key StoreKey, tree *bptree.BPTree) error {
	if !rlm.IsCurrent() {
		return errors.New(ErrSpoofedRealm)
	}

	if tree == nil {
		return ufmt.Errorf(errNilValue, key.String())
	}

	return s.kvStore.Set(0, rlm, key.String(), tree)
}

func (s *limitOrderStore) HasOrders() bool { return s.kvStore.Has(StoreKeyOrders.String()) }

func (s *limitOrderStore) GetOrders() *bptree.BPTree { return s.getTree(StoreKeyOrders) }

func (s *limitOrderStore) SetOrders(_ int, rlm realm, orders *bptree.BPTree) error {
	return s.setTree(0, rlm, StoreKeyOrders, orders)
}

func (s *limitOrderStore) HasOrdersByOwner() bool {
	return s.kvStore.Has(StoreKeyOrdersByOwner.String())
}

func (s *limitOrderStore) GetOrdersByOwner() *bptree.BPTree {
	return s.getTree(StoreKeyOrdersByOwner)
}

func (s *limitOrderStore) SetOrdersByOwner(_ int, rlm realm, ordersByOwner *bptree.BPTree) error {
	return s.setTree(0, rlm, StoreKeyOrdersByOwner, ordersByOwner)
}

func (s *limitOrderStore) HasPendingExecutionFees() bool {
	return s.kvStore.Has(StoreKeyPendingExecutionFees.String())
}

func (s *limitOrderStore) GetPendingExecutionFees() *bptree.BPTree {
	return s.getTree(StoreKeyPendingExecutionFees)
}

func (s *limitOrderStore) SetPendingExecutionFees(_ int, rlm realm, pendingExecutionFees *bptree.BPTree) error {
	return s.setTree(0, rlm, StoreKeyPendingExecutionFees, pendingExecutionFees)
}

func (s *limitOrderStore) HasNextOrderID() bool {
	return s.kvStore.Has(StoreKeyNextOrderID.String())
}

func (s *limitOrderStore) GetNextOrderID() uint64 {
	id, err := s.kvStore.GetUint64(StoreKeyNextOrderID.String())
	if err != nil {
		panic(err.Error())
	}

	return id
}

func (s *limitOrderStore) SetNextOrderID(_ int, rlm realm, id uint64) error {
	return s.set(0, rlm, StoreKeyNextOrderID.String(), id)
}

func (s *limitOrderStore) HasConfig() bool { return s.kvStore.Has(StoreKeyConfig.String()) }

func (s *limitOrderStore) GetConfig() *plimit.Config {
	result, err := s.kvStore.Get(StoreKeyConfig.String())
	if err != nil {
		panic(err.Error())
	}

	config, ok := result.(*plimit.Config)
	if !ok || config == nil {
		panic(ufmt.Sprintf(errInvalidConfigType, result))
	}

	return config
}

func (s *limitOrderStore) SetConfig(_ int, rlm realm, config *plimit.Config) error {
	if !rlm.IsCurrent() {
		return errors.New(ErrSpoofedRealm)
	}

	if config == nil {
		return errors.New(errNilConfig)
	}

	return s.kvStore.Set(0, rlm, StoreKeyConfig.String(), config)
}
