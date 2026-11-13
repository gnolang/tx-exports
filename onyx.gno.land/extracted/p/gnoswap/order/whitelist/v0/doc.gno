// Package whitelist holds the pool membership state used by the GnoSwap
// order whitelist realm.
//
// Files:
//   - state.gno: State, a poolPath -> true B+tree with membership updates and queries
//
// Each NewState creates an independent whitelist. Pools exposes membership
// and iteration through a read-only tree, without mutable tree access.
// This package does not validate pool existence or authorize callers; those
// checks and the separately managed DCA and Limit states live in
// gno.land/r/gnoswap/order/whitelist.
package whitelist
