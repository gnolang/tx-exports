package limit

// Proxy errors carry no error code; codes belong to the implementation.

// ErrSpoofedRealm is returned when a store write gets a non-current realm.
const ErrSpoofedRealm = "spoofed realm"

// ErrNilInitializer is raised by RegisterInitializer for a nil factory.
const ErrNilInitializer = "nil initializer"

const (
	errImplNotInitialized                = "implementation is not initialized"
	errInvalidImpl                       = "impl is not an ILimitOrder"
	errInvalidDomainStore                = "domainStore is not an ILimitOrderStore"
	errNilConfig                         = "config is nil"
	errImplDoesNotSupportTargetedCleanup = "implementation does not support targeted expired-order cleanup"
	errImplDoesNotSupportFeeCollection   = "implementation does not support pending execution fee collection"

	// errInvalidSwapCallback is returned by an order's swap callback for a
	// call it must not pay.
	errInvalidSwapCallback = "invalid swap callback"

	// Format strings: the store key name, the config value.
	errNilValue          = "%s is nil"
	errInvalidConfigType = "failed to cast config: %T"
)
