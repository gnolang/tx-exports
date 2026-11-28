package idox

import (
	"chain"
	"strings"
	"testing"

	"gno.land/p/nt/testutils/v0"
)

func TestCreateVaultCSV(cur realm, t *testing.T) {
	sponsor := testutils.TestAddress("csv_sponsor")
	contractor := testutils.TestAddress("csv_contractor")

	testing.IssueCoins(cur.Address(), chain.Coins{chain.NewCoin("ugnot", 70_000_000)})
	testing.SetOriginCaller(sponsor)
	testing.SetRealm(testing.NewUserRealm(sponsor))
	testing.SetOriginSend(chain.Coins{chain.NewCoin("ugnot", 70_000_000)})

	vaultID := CreateVaultCSV(
		cross(cur),
		"Alachua Rental Rehab (CSV)",
		contractor,
		"Tranche 1: Framing & Dry-In | Tranche 2: Rough Electrical",
		"gc_license | electrical_master",
		"30000000 | 40000000",
	)
	testing.SetOriginSend(nil)

	if vaultID == 0 {
		t.Fatalf("expected non-zero vaultID")
	}
	if got := GetVaultReleased(vaultID); got != 0 {
		t.Fatalf("expected 0 released initially, got %d", got)
	}
	if !strings.Contains(Render(""), "Alachua Rental Rehab (CSV)") {
		t.Fatalf("expected CSV-created vault in Render() output")
	}

	// Mismatched pipe counts should panic
	testing.SetOriginCaller(sponsor)
	testing.SetRealm(testing.NewUserRealm(sponsor))
	if rec := revive(func() {
		CreateVaultCSV(cross(cur), "Bad Vault", contractor, "Only One", "gc_license|extra", "1000000")
	}); rec == nil {
		t.Fatalf("expected panic on mismatched pipe-delimited counts")
	}
}
