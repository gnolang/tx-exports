package access

import (
	"strconv"

	"gno.land/p/onbloc/access/manager"
)

const (
	ErrAccessManagerUnauthorizedAccount = "access manager unauthorized account"
	ErrAccessManagerUnauthorizedCall    = "access manager unauthorized call"
	ErrSpoofedRealm                     = "rlm does not match the current crossing frame"
)

// AccessManagerUnauthorizedAccountError formats an account-role authorization error.
// Union references:
// https://github.com/unionlabs/union/blob/8cff0ff34f6baa4cdb1e4650a08985dd05de0c5a/lib/access-manager-types/src/manager/error.rs#L26-L30
// https://github.com/unionlabs/union/blob/8cff0ff34f6baa4cdb1e4650a08985dd05de0c5a/cosmwasm/access-manager/src/contract.rs#L832-L840
func AccessManagerUnauthorizedAccountError(caller address, requiredRole manager.RoleId) string {
	return ErrAccessManagerUnauthorizedAccount +
		": " + caller.String() +
		" must have role " + strconv.FormatUint(uint64(requiredRole), 10)
}

// AccessManagerUnauthorizedCallError formats a target-selector authorization error.
// Union references:
// https://github.com/unionlabs/union/blob/8cff0ff34f6baa4cdb1e4650a08985dd05de0c5a/lib/access-manager-types/src/manager/error.rs#L32-L37
// https://github.com/unionlabs/union/blob/8cff0ff34f6baa4cdb1e4650a08985dd05de0c5a/cosmwasm/access-manager/src/contract.rs#L526-L534
func AccessManagerUnauthorizedCallError(caller address, target string, selector manager.Selector) string {
	return ErrAccessManagerUnauthorizedCall +
		": " + caller.String() +
		" is not authorized to call " + string(selector) +
		" on " + target
}
