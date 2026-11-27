// Package fpmm implements a deterministic, zero-float, overflow-safe
// binary Fixed-Product Market Maker (Constant-Product Market Maker)
// for prediction markets on Gno.land.
//
// # Model
//
// Each unit of collateral backs one complete set of outcome shares
// (1 YES + 1 NO). The market maker maintains reserves (ReserveYes, ReserveNo)
// subject to the constant-product invariant:
//
//	ReserveYes * ReserveNo >= k
//
// Implied probability of YES in basis points is:
//
//	ReserveNo * 10_000 / (ReserveYes + ReserveNo)
//
// # Arithmetic & Rounding Invariants
//
// All intermediate products use exact 128-bit unsigned arithmetic (via math/bits)
// and all rounding favors the pool:
//   - Fees and required pool reserves round UP (ceil).
//   - Share outputs, collateral payouts, LP shares minted, and withdrawn
//     reserves round DOWN (floor).
//   - LP fee debt rounds UP on entry and LP fee entitlement rounds DOWN,
//     preventing retroactive fee extraction and ensuring sum(payouts) <= fees.
//
// All exported functions are pure and stateless. Callers handle coin custody
// and storage persistence.
package fpmm
