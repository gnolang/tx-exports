package escrow_v3

// ── NF-2 solvency getters (MAINNET_READINESS.md §3) ───────────────────────────
//
// escrow_v3 pools funds between FundMilestone and release/refund, making it a
// pooled-fund realm. Without a machine-readable liabilities figure the solvency
// monitor can only do a balance-only heuristic. escrow_v3 was the LAST unpublished
// pooled-fund realm without this pair — candidature_v3 and agent_registry_v2
// already shipped on Topaz without it and can never get it now, on immutable
// package paths (§3b). Added before this realm ships to any enforce chain.
//
// Invariant the monitor reconciles: realm balance >= TotalLiabilities().
// totalLiable is maintained in lockstep with every fund-moving mutation in
// escrow.gno: +ms.Amount on FundMilestone, -ms.Amount at every point funds leave
// (ReleaseFunds; ResolveDispute both branches; CancelContract both branches;
// ClaimRefund; ClaimDisputeTimeout both branches) — see escrow_feespine_test.gno
// for the lockstep pin across every one of those paths.

import "chain/runtime/unsafe"

// TotalLiabilities returns the total ugnot the realm owes across all funded and
// disputed milestones (funds that have arrived but not yet left the realm).
func TotalLiabilities() int64 { return totalLiable }

// RealmAddress is the NF-2 canonical name for the realm's own address (the
// solvency monitor pairs it with TotalLiabilities).
func RealmAddress() string { return unsafe.CurrentRealm().Address().String() }
