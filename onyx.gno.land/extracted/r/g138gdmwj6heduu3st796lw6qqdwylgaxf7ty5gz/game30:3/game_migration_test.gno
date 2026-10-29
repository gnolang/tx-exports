package game30

import (
	"strconv"
	"testing"
	"time"
)

// TestClaimBuckets_LazyMigration verifies that a player whose claimBuckets
// entries are in the old per-rarity format (addr+":"+r) are automatically
// migrated to the packed format on the next ClaimAndMint.
func TestClaimBuckets_LazyMigration(cur realm, t *testing.T) {
	setup()
	p := ta("migrate-player")

	// Write old-format per-rarity bucket entries directly.
	nowTs := time.Now().Unix()
	for r := 0; r < 7; r++ {
		oldKey := p.String() + ":" + strconv.Itoa(r)
		// Write a non-default value so we can verify it survived migration.
		claimBuckets.Set(oldKey, "9999:"+strconv.FormatInt(nowTs-100, 10))
	}

	// Confirm old keys exist.
	for r := 0; r < 7; r++ {
		if !claimBuckets.Has(p.String() + ":" + strconv.Itoa(r)) {
			t.Fatalf("setup: old key r=%d missing", r)
		}
	}

	// Trigger a ClaimAndMint — this calls loadPackedBuckets which lazy-migrates.
	n, e, s := voucher(t, "claim", p, `[["grin","1"]]`)
	testing.SetRealm(testing.NewUserRealm(p))
	ClaimAndMint(cross(cur), `[["grin","1"]]`, n, e, s)

	// Old keys must be gone.
	for r := 0; r < 7; r++ {
		if claimBuckets.Has(p.String() + ":" + strconv.Itoa(r)) {
			t.Errorf("old key r=%d still exists after migration", r)
		}
	}

	// New packed key must exist.
	if !claimBuckets.Has(p.String()) {
		t.Error("packed key missing after migration")
	}
}

// TestClaimBuckets_NewPlayerSingleKey verifies a brand-new player creates
// exactly one claimBuckets key (the packed format) on first ClaimAndMint.
func TestClaimBuckets_NewPlayerSingleKey(cur realm, t *testing.T) {
	setup()
	p := ta("new-player-bucket")

	// Confirm no bucket state exists yet.
	if claimBuckets.Has(p.String()) {
		t.Fatal("setup: packed key should not exist yet")
	}
	for r := 0; r < 7; r++ {
		if claimBuckets.Has(p.String() + ":" + strconv.Itoa(r)) {
			t.Fatalf("setup: old key r=%d should not exist", r)
		}
	}

	// First claim.
	n, e, s := voucher(t, "claim", p, `[["grin","1"]]`)
	testing.SetRealm(testing.NewUserRealm(p))
	ClaimAndMint(cross(cur), `[["grin","1"]]`, n, e, s)

	// Exactly one key for this player in claimBuckets.
	if !claimBuckets.Has(p.String()) {
		t.Error("packed key missing after first claim")
	}
	for r := 0; r < 7; r++ {
		if claimBuckets.Has(p.String() + ":" + strconv.Itoa(r)) {
			t.Errorf("old-format key r=%d unexpectedly created", r)
		}
	}
}
