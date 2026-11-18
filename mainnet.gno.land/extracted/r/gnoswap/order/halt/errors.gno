package halt

import (
	ufmt "gno.land/p/nt/ufmt/v0"
)

const (
	errInvalidOperation = "[GNOSWAP-ORDER-HALT-001] invalid operation"
	errInvalidTarget    = "[GNOSWAP-ORDER-HALT-002] invalid target"
	errTargetExists     = "[GNOSWAP-ORDER-HALT-003] target already exists"
)

func makeErrorWithDetails(message string, details string) error {
	return ufmt.Errorf("%s || %s", message, details)
}
