// Package manager is a pure port of the core permission model of
// OpenZeppelin Contracts AccessManager v5.6.1, taken from
// gno.land/p/onbloc/access/manager (github.com/onbloc/gno-ibc, Apache-2.0).
//
// It is a state transition library, not a realm: it does not own storage,
// inspect realms, or decide who the caller is. A realm stores a State,
// passes the caller address, target, and selector into its methods, and
// exposes the management API it needs (see gno.land/r/gnoswap/order/keeper).
//
// Model:
//   - roles are uint64 identifiers; AdminRole is 0 and PublicRole is
//     uint64 max, which every account holds;
//   - permissions are scoped by target and selector; an unset selector
//     defaults to AdminRole;
//   - a closed target rejects every call;
//   - each role has an admin role, a grant delay, and member records with
//     an activation time.
//
// Delayed operation scheduling (schedule, execute, cancel) is not ported.
// Panics carry string messages so they can cross realm boundaries.
package manager
