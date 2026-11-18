package dca

import (
	ufmt "gno.land/p/nt/ufmt/v0"
)

// Proxy errors carry no error code; codes belong to the implementation.

// ErrSpoofedRealm is returned when a store write gets a non-current realm.
const ErrSpoofedRealm = "spoofed realm"

// ErrNilInitializer is raised by RegisterInitializer for a nil factory.
const ErrNilInitializer = "nil initializer"

// ErrUpgradeWhileExecuting is raised by UpgradeImpl during a group swap.
const ErrUpgradeWhileExecuting = "cannot upgrade while a group execution is in progress"

// ErrInvalidSwapCallback is returned by a round's swap callback for a call it
// must not pay: not from the pool, outside a round, a second payment, or a
// delta that is not the round's exact input (e.g. a pool without liquidity
// owes nothing).
const ErrInvalidSwapCallback = "invalid swap callback"

const (
	errImplNotInitialized = "implementation is not initialized"
	errInvalidImpl        = "impl is not an IDCAOrder"
	errInvalidDomainStore = "domainStore is not an IDCAOrderStore"
	errNilConfig          = "config is nil"

	// Format strings: the store key name, the config value.
	errNilValue          = "%s is nil"
	errInvalidConfigType = "failed to cast config: %T"
)

func makeErrorWithDetails(message string, details string) error {
	return ufmt.Errorf("%s || %s", message, details)
}
