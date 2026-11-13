package limit

import (
	plimit "gno.land/p/gnoswap/order/limit/v0"

	"gno.land/r/gnoswap/access/v1"
)

// RegisterInitializer registers an implementation version.
// Each version calls it from init with a factory that receives the shared store.
// Only packages under this realm's path may register,
// and the first registration becomes active.
// A nil initializer is rejected before its version path is registered.
func RegisterInitializer(cur realm, initializer func(_ int, rlm realm, orderStore plimit.ILimitOrderStore) plimit.ILimitOrder) {
	if initializer == nil {
		panic(ErrNilInitializer)
	}

	initializerFunc := func(_ int, rlm realm, domainStore any) any {
		access.AssertIsRlmCurrent(0, rlm)

		orderStore, ok := domainStore.(plimit.ILimitOrderStore)
		if !ok {
			panic(errInvalidDomainStore)
		}

		return initializer(0, rlm, orderStore)
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
