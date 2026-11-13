package dca

import (
	pdca "gno.land/p/gnoswap/order/dca/v0"

	"gno.land/r/gnoswap/access/v1"
)

// RegisterInitializer registers an implementation version.
// Each version calls it from init with a factory that receives the shared store.
// Only packages under this realm's path may register,
// and the first registration becomes active.
// A nil initializer is rejected here,
// instead of panicking later when the version is activated.
func RegisterInitializer(cur realm, initializer func(_ int, rlm realm, dcaStore pdca.IDCAOrderStore) pdca.IDCAOrder) {
	if initializer == nil {
		panic(ErrNilInitializer)
	}

	initializerFunc := func(_ int, rlm realm, domainStore any) any {
		access.AssertIsRlmCurrent(0, rlm)

		currentStore, ok := domainStore.(pdca.IDCAOrderStore)
		if !ok {
			panic(errInvalidDomainStore)
		}

		return initializer(0, rlm, currentStore)
	}

	err := versionManager.RegisterInitializer(0, cur, initializerFunc)
	if err != nil {
		panic(err.Error())
	}

	err = updateImplementation()
	if err != nil {
		panic(err.Error())
	}
}

// UpgradeImpl activates a previously registered version by package path.
// Admin or governance only.
func UpgradeImpl(cur realm, packagePath string) {
	caller := cur.Previous().Address()
	access.AssertIsAdminOrGovernance(caller)

	// The running version still writes the accumulator after its swap,
	// so never switch during a round.
	if NewDCAOrderStore(kvStore).IsExecuting() {
		panic(ErrUpgradeWhileExecuting)
	}

	err := versionManager.ChangeImplementation(0, cur, packagePath)
	if err != nil {
		panic(err.Error())
	}

	err = updateImplementation()
	if err != nil {
		panic(err.Error())
	}
}

// GetImplementationPackagePath returns the active implementation path.
func GetImplementationPackagePath() string {
	return versionManager.GetCurrentPackagePath()
}
