// Package memba_points_migration_v1 is a one-time, owner-gated importer of legacy backend XP into the
// soulbound memba_points_v1 ledger. It holds NO funds and mints NO points itself — it calls the audited
// awarder path (memba_points_v1.Award) so every migrated grant lands as a normal PointsAwarded event
// (source = this realm, reason = "xp_migration"). Idempotent per-address + permanently finalizable.
//
// The parsing / validation / dedup logic lives in the pure, unit-tested
// p/samcrew/memba_points_migration_core_v1 package; this realm is the thin state + effect shell
// (owner gate, migrated set, finalize latch, the Award loop). It can't be unit-tested under bare
// `gno test` because it imports the unpublished points_v1 — its logic is covered by the core tests
// plus a test13 ceremony dry-run.
//
// Rollout (owner ceremony, after points_v1 is deployed): points_v1.AddAwarder(this realm) →
// MigrateBatch × N → FinalizeMigration → points_v1.RemoveAwarder(this realm). See README.md.
package memba_points_migration_v1

import (
	"chain"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
	core "gno.land/p/samcrew/memba_points_migration_core_v1"
	points "gno.land/r/samcrew/memba_points_v1"
)

// AdminAddress inits owner — the samcrew-core deploy multisig (same as memba_points_v1). Hand it to the
// memba_dao executor post-deploy via a 2-step transfer if desired.
const AdminAddress = "g1x7k4628w93a7wzdhqc06atzx0v50rnshweuxu0"

const (
	// MaxBatch bounds entries per MigrateBatch tx (gas).
	MaxBatch = 100
	// reasonXPMigration tags every migrated grant in the points_v1 audit trail.
	reasonXPMigration = "xp_migration"
)

var (
	owner     address
	migrated  = avl.NewTree() // addr string -> true  (idempotency ledger)
	finalized bool            // once true, MigrateBatch refuses forever
)

func init() { owner = address(AdminAddress) }

// assertOwner uses the interrealm-v2 sanctioned primitives (statically scoped to this crossing frame,
// cannot be spoofed) — matching the hardened memba_points_v1.
func assertOwner(cur realm) {
	if !cur.IsCurrent() {
		panic("spoofed realm")
	}
	if cur.Previous().Address() != owner {
		panic("unauthorized: owner only")
	}
}

// MigrateBatch imports a batch of legacy XP as points. Owner only. `entries` is
// "addr:amount,addr:amount" (≤ MaxBatch). Malformed input fails the whole tx (fail-fast); an
// already-migrated address is skipped; the call is refused once finalized. Each fresh entry is awarded
// through the audited memba_points_v1 awarder path.
func MigrateBatch(cur realm, entries string) {
	assertOwner(cur)
	plan := core.PlanBatch(entries, points.MaxAward, MaxBatch, finalized, func(a string) bool {
		return migrated.Has(a)
	})
	for _, e := range plan {
		points.Award(cross(cur), address(e.Addr), e.Amount, reasonXPMigration)
		migrated.Set(e.Addr, true)
		chain.Emit("XPMigrated", "addr", e.Addr, "amount", ufmt.Sprintf("%d", e.Amount))
	}
}

// FinalizeMigration permanently closes the migration — no further MigrateBatch. Owner only, irreversible.
func FinalizeMigration(cur realm) {
	assertOwner(cur)
	finalized = true
	chain.Emit("MigrationFinalized")
}

// IsMigrated reports whether an address has already been imported.
func IsMigrated(addr string) bool { return migrated.Has(addr) }

// IsFinalized reports whether the migration is permanently closed.
func IsFinalized() bool { return finalized }

// Render — minimal gnoweb status (owner is a fixed const-derived address; no untrusted input).
func Render(_ string) string {
	return ufmt.Sprintf("# Memba Points — XP Migration\n\n- Finalized: **%t**\n- Owner: `%s`\n",
		finalized, owner.String())
}
