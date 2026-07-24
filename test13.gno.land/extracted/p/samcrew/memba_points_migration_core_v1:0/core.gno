// Package memba_points_migration_core_v1 holds the pure, unit-testable logic for the one-time XP
// migration into memba_points_v1: parsing + validating the owner-submitted batch, and planning which
// entries to award (skipping already-migrated addresses, refusing once finalized). It imports no realm
// and holds no state — the realm (r/samcrew/memba_points_migration_v1) owns the state + the Award call.
// Splitting it out this way is what makes the migration's risky logic testable under bare `gno test`
// (the realm itself can't be, since it imports the unpublished points_v1).
package memba_points_migration_core_v1

import "strings"

// Entry is one validated (address, amount) grant.
type Entry struct {
	Addr   string
	Amount int64
}

// PlanBatch parses a "addr:amount,addr:amount,..." batch and returns the entries to award:
//   - panics if finalized (migration permanently closed)
//   - panics on any malformed entry (bad format, non-address, amount outside 1..maxAward) — fail-fast,
//     so a botched export never half-applies
//   - caps the batch at maxEntries (per-tx gas bound)
//   - drops entries whose Addr already satisfies isMigrated (idempotent re-runs)
func PlanBatch(csv string, maxAward int64, maxEntries int, finalized bool, isMigrated func(string) bool) []Entry {
	if finalized {
		panic("migration finalized")
	}
	all := ParseBatch(csv, maxAward, maxEntries)
	out := make([]Entry, 0, len(all))
	for _, e := range all {
		if isMigrated(e.Addr) {
			continue
		}
		out = append(out, e)
	}
	return out
}

// ParseBatch parses + validates the batch (no dedup against prior runs). Exposed for testing + reuse.
func ParseBatch(csv string, maxAward int64, maxEntries int) []Entry {
	if len(csv) == 0 {
		panic("empty batch")
	}
	parts := strings.Split(csv, ",")
	if len(parts) > maxEntries {
		panic("batch exceeds maxEntries")
	}
	out := make([]Entry, 0, len(parts))
	seen := make(map[string]bool)
	for _, p := range parts {
		kv := strings.Split(p, ":")
		if len(kv) != 2 {
			panic("entry must be addr:amount")
		}
		addr := kv[0]
		if !isValidAddress(addr) {
			panic("invalid address in batch")
		}
		if seen[addr] {
			panic("duplicate address in batch")
		}
		amt, ok := parseAmount(kv[1])
		if !ok || amt < 1 || amt > maxAward {
			panic("amount out of range (1..maxAward)")
		}
		seen[addr] = true
		out = append(out, Entry{Addr: addr, Amount: amt})
	}
	return out
}

// isValidAddress does a cheap structural check for a gno bech32 address ("g1" + 38 lowercase-alnum
// chars). Deep checksum validation is unnecessary: the batch is owner-submitted from a trusted export,
// and memba_points_v1.Award is the ultimate authority on the address. Loose-accepts (never false-rejects
// a real address); a slightly-malformed one is an owner/export bug caught at the ceremony dry-run.
func isValidAddress(s string) bool {
	if len(s) != 40 || s[0] != 'g' || s[1] != '1' {
		return false
	}
	for i := 2; i < len(s); i++ {
		c := s[i]
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'z')) {
			return false
		}
	}
	return true
}

// parseAmount parses a non-negative base-10 int64 (no strconv dep, overflow-guarded).
func parseAmount(s string) (int64, bool) {
	if len(s) == 0 || len(s) > 19 {
		return 0, false
	}
	var n int64
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c < '0' || c > '9' {
			return 0, false
		}
		n = n*10 + int64(c-'0')
		if n < 0 {
			return 0, false
		}
	}
	return n, true
}
