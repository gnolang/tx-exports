package limit

import (
	_ "gno.land/r/gnoswap/rbac/v1" // registers the roles read through access

	"errors"

	plimit "gno.land/p/gnoswap/order/limit/v0"
	"gno.land/p/gnoswap/store/v1"
	"gno.land/p/gnoswap/version_manager/v1"
)

var (
	currentAddress address
	kvStore        store.KVStore

	versionManager version_manager.VersionManager
	implementation plimit.ILimitOrder
)

func init(cur realm) {
	currentAddress = cur.Address()
	kvStore = store.NewKVStore(currentAddress)

	versionManager = version_manager.NewVersionManager(
		cur.PkgPath(),
		kvStore,
		initializeDomainStore,
	)

	implementation = nil
}

func initializeDomainStore(_ int, _ realm, kvStore store.KVStore) any {
	return NewLimitOrderStore(kvStore)
}

// Address returns the realm address that escrows order funds.
// Users approve it before CreateOrder.
func Address() address {
	return currentAddress
}

func getImplementation() plimit.ILimitOrder {
	if implementation == nil {
		panic(errImplNotInitialized)
	}

	return implementation
}

func updateImplementation() error {
	result := versionManager.GetCurrentImplementation()
	if result == nil {
		return errors.New(errImplNotInitialized)
	}

	impl, ok := result.(plimit.ILimitOrder)
	if !ok {
		return errors.New(errInvalidImpl)
	}

	implementation = impl

	return nil
}
