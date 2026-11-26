package sample_consumer

import (
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

func TestCheckSpend(t *testing.T) {
	bar := testutils.TestAddress("bartender")
	thief := testutils.TestAddress("thief")
	uassert.Equal(t, "OK", CheckSpend(bar, bar, "Tip", 50))
	uassert.Equal(t, "DENIED: aegis: target not in allowlist", CheckSpend(bar, thief, "Tip", 5))
	uassert.Equal(t, "DENIED: aegis: amount exceeds per-tx cap", CheckSpend(bar, bar, "Tip", 51))
}

func TestPracticeDuelAndVIPGate(cur realm, t *testing.T) {
	uassert.Equal(t, 1, PracticeDuel(cross(cur), "SFG", "FGS"))
	newbie := testutils.TestAddress("newbie")
	testing.SetRealm(testing.NewUserRealm(newbie))
	uassert.AbortsContains(t, cur, "win a ranked match", func() {
		EnterVIP(cross(cur))
	})
}
