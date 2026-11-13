package whitelist

import (
	ufmt "gno.land/p/nt/ufmt/v0"
)

const (
	errUnauthorized  = "[GNOSWAP-ORDER-WHITELIST-001] unauthorized caller"
	errInvalidPool   = "[GNOSWAP-ORDER-WHITELIST-002] invalid whitelisted pool"
	errInvalidTarget = "[GNOSWAP-ORDER-WHITELIST-003] invalid target"
)

func makeErrorWithDetails(message string, details string) error {
	return ufmt.Errorf("%s || %s", message, details)
}
