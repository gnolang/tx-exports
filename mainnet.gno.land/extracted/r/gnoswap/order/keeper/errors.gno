package keeper

import (
	ufmt "gno.land/p/nt/ufmt/v0"
)

const (
	errUnauthorizedCall = "[GNOSWAP-ORDER-KEEPER-001] unauthorized call"
	errInvalidRole      = "[GNOSWAP-ORDER-KEEPER-002] invalid role"
	errInvalidLabel     = "[GNOSWAP-ORDER-KEEPER-003] invalid role label"
	errInvalidAddress   = "[GNOSWAP-ORDER-KEEPER-004] invalid address"
	errSpoofedRealm     = "[GNOSWAP-ORDER-KEEPER-005] rlm does not match the current crossing frame"
	errInvalidTarget    = "[GNOSWAP-ORDER-KEEPER-006] invalid target"
)

func makeErrorWithDetails(message string, details string) error {
	return ufmt.Errorf("%s || %s", message, details)
}
