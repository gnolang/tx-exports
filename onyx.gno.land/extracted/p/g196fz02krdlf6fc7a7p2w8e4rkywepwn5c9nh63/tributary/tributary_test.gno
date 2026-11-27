package tributary

import (
	"strings"
	"testing"

	"gno.land/p/nt/testutils/v0"
)

func TestDiamondDAGZeroDustConservation(t *testing.T) {
	eng := NewEngine()
	aApp := testutils.TestAddress("app")
	aAuth := testutils.TestAddress("auth")
	aUI := testutils.TestAddress("ui")
	aCore := testutils.TestAddress("core")
	aDonor := testutils.TestAddress("donor")

	if _, err := eng.RegisterNode("core-crypto", "CoreCrypto", "gno.land/p/demo/core", aCore, aCore, 100); err != nil {
		t.Fatalf("register core: %v", err)
	}
	if _, err := eng.RegisterNode("auth-lib", "AuthLib", "gno.land/p/demo/auth", aAuth, aAuth, 101); err != nil {
		t.Fatalf("register auth: %v", err)
	}
	if _, err := eng.RegisterNode("ui-svg", "UISVG", "gno.land/p/demo/ui", aUI, aUI, 102); err != nil {
		t.Fatalf("register ui: %v", err)
	}
	if _, err := eng.RegisterNode("dex-app", "DexApp", "gno.land/r/demo/dex", aApp, aApp, 103); err != nil {
		t.Fatalf("register app: %v", err)
	}

	// Diamond DAG:
	// dex-app -> 20% auth-lib, 15% ui-svg (keeps 65%)
	// auth-lib -> 30% core-crypto (keeps 70%)
	// ui-svg -> 20% core-crypto (keeps 80%)
	if err := eng.SetSplits("auth-lib", aAuth, []Edge{{TargetID: "core-crypto", BPS: 3000, Label: "hashing"}}); err != nil {
		t.Fatalf("splits auth: %v", err)
	}
	if err := eng.SetSplits("ui-svg", aUI, []Edge{{TargetID: "core-crypto", BPS: 2000, Label: "math"}}); err != nil {
		t.Fatalf("splits ui: %v", err)
	}
	if err := eng.SetSplits("dex-app", aApp, []Edge{
		{TargetID: "auth-lib", BPS: 2000, Label: "auth"},
		{TargetID: "ui-svg", BPS: 1500, Label: "render"},
	}); err != nil {
		t.Fatalf("splits app: %v", err)
	}

	// Deposit a prime number to stress-test zero-dust integer conservation!
	const deposit int64 = 999997
	rcpt, traces, err := eng.Route("dex-app", aDonor, deposit, 200, "launch fees")
	if err != nil {
		t.Fatalf("route: %v", err)
	}
	if rcpt.Amount != deposit || rcpt.Credits != 4 || rcpt.Hops != 4 {
		t.Fatalf("unexpected receipt: %+v", rcpt)
	}
	if len(traces) < 6 {
		t.Fatalf("expected >= 6 trace steps, got %d", len(traces))
	}

	totalPending := eng.PendingOf(aApp) + eng.PendingOf(aAuth) + eng.PendingOf(aUI) + eng.PendingOf(aCore)
	if totalPending != deposit {
		t.Fatalf("ZERO-DUST VIOLATION: sum(pending)=%d != deposit=%d", totalPending, deposit)
	}

	// Verify core-crypto received contributions from BOTH auth-lib (6%) and ui-svg (3%) = ~9% (~89,998 ugnot)
	coreGot := eng.PendingOf(aCore)
	if coreGot < 89990 || coreGot > 90010 {
		t.Fatalf("expected core-crypto ~90000 ugnot from diamond convergence, got %d", coreGot)
	}

	// Claim and verify accounting
	claimed, err := eng.DeductClaim(aCore)
	if err != nil || claimed != coreGot {
		t.Fatalf("deduct claim: got %d, %v", claimed, err)
	}
	if eng.PendingOf(aCore) != 0 || eng.ClaimedOf(aCore) != coreGot {
		t.Fatalf("post-claim accounting mismatch")
	}
	if _, err := eng.DeductClaim(aCore); err != ErrNothingToClaim {
		t.Fatalf("expected ErrNothingToClaim on double claim, got %v", err)
	}

	// Verify effective shares sum to exactly 10,000 BPS
	shares := eng.EffectiveShares("dex-app")
	var sumEff int64
	for _, s := range shares {
		sumEff += s.EffectiveBPS
	}
	if sumEff != ScaleBPS {
		t.Fatalf("effective shares sum=%d != 10000", sumEff)
	}

	// Verify SVG rendering produces a valid data URI image with node names
	svgMD := eng.RenderGraphSVG("dex-app")
	if !strings.HasPrefix(svgMD, "![Tributary DAG: dex-app](data:image/svg+xml;base64,") {
		t.Fatalf("unexpected SVG markdown prefix: %s", svgMD[:60])
	}
}

func TestCycleAndLockGuards(t *testing.T) {
	eng := NewEngine()
	u := testutils.TestAddress("owner")
	other := testutils.TestAddress("other")

	_, _ = eng.RegisterNode("n1", "N1", "", u, u, 1)
	_, _ = eng.RegisterNode("n2", "N2", "", u, u, 1)
	_, _ = eng.RegisterNode("n3", "N3", "", u, u, 1)

	// Self-loop rejected
	if err := eng.SetSplits("n1", u, []Edge{{TargetID: "n1", BPS: 1000}}); err != ErrCycleDetected {
		t.Fatalf("expected ErrCycleDetected on self-loop, got %v", err)
	}

	// Build n1 -> n2 -> n3
	if err := eng.SetSplits("n1", u, []Edge{{TargetID: "n2", BPS: 5000}}); err != nil {
		t.Fatalf("n1->n2 failed: %v", err)
	}
	if err := eng.SetSplits("n2", u, []Edge{{TargetID: "n3", BPS: 5000}}); err != nil {
		t.Fatalf("n2->n3 failed: %v", err)
	}

	// Indirect 3-node cycle n3 -> n1 MUST be rejected
	if err := eng.SetSplits("n3", u, []Edge{{TargetID: "n1", BPS: 1000}}); err != ErrCycleDetected {
		t.Fatalf("expected ErrCycleDetected on n3->n1, got %v", err)
	}

	// Unauthorized update rejected
	if err := eng.SetSplits("n1", other, []Edge{{TargetID: "n3", BPS: 1000}}); err != ErrUnauthorized {
		t.Fatalf("expected ErrUnauthorized, got %v", err)
	}

	// Over-10000 BPS rejected
	if err := eng.SetSplits("n1", u, []Edge{
		{TargetID: "n2", BPS: 6000},
		{TargetID: "n3", BPS: 5000},
	}); err != ErrInvalidBPS {
		t.Fatalf("expected ErrInvalidBPS, got %v", err)
	}

	// Lock freezes splits and beneficiary permanently
	if err := eng.Lock("n1", u); err != nil {
		t.Fatalf("lock failed: %v", err)
	}
	if err := eng.SetSplits("n1", u, nil); err != ErrNodeLocked {
		t.Fatalf("expected ErrNodeLocked after lock, got %v", err)
	}
	if err := eng.SetBeneficiary("n1", u, other); err != ErrNodeLocked {
		t.Fatalf("expected ErrNodeLocked on beneficiary change, got %v", err)
	}
}

func TestMaxDepthGuard(t *testing.T) {
	eng := NewEngine()
	u := testutils.TestAddress("owner")

	// Create 10 nodes d0..d9 (depth 9 exceeds MaxDepth=8)
	ids := []string{"d0", "d1", "d2", "d3", "d4", "d5", "d6", "d7", "d8", "d9"}
	for _, id := range ids {
		if _, err := eng.RegisterNode(id, id, "", u, u, 1); err != nil {
			t.Fatalf("register %s: %v", id, err)
		}
	}
	for i := 0; i < 8; i++ {
		if err := eng.SetSplits(ids[i], u, []Edge{{TargetID: ids[i+1], BPS: 5000}}); err != nil {
			t.Fatalf("edge %d->%d failed: %v", i, i+1, err)
		}
	}
	// Adding the 9th hop must fail with ErrMaxDepthExceeded
	if err := eng.SetSplits("d8", u, []Edge{{TargetID: "d9", BPS: 5000}}); err != ErrMaxDepthExceeded {
		t.Fatalf("expected ErrMaxDepthExceeded at depth 9, got %v", err)
	}
}
