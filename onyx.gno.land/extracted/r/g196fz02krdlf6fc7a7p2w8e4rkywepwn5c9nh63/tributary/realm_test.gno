package tributary

import (
	"chain"
	"chain/banker"
	"strings"
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

func TestRealmEndToEndWaterfallAndClaim(cur realm, t *testing.T) {
	aApp := testutils.TestAddress("realm_app")
	aLibA := testutils.TestAddress("realm_libA")
	aLibB := testutils.TestAddress("realm_libB")
	aCore := testutils.TestAddress("realm_core")
	aDonor := testutils.TestAddress("realm_donor")

	realmAddr := chain.PackageAddress("gno.land/r/g196fz02krdlf6fc7a7p2w8e4rkywepwn5c9nh63/tributary")

	// Register 4-node diamond dependency graph
	testing.SetRealm(testing.NewUserRealm(aCore))
	testing.SetOriginCaller(aCore)
	Register(cross(cur), "core-math", "CoreMath", "gno.land/p/demo/math", aCore)

	testing.SetRealm(testing.NewUserRealm(aLibA))
	testing.SetOriginCaller(aLibA)
	Register(cross(cur), "avl-tree", "AVLTree", "gno.land/p/demo/avl", aLibA)
	SetSplits(cross(cur), "avl-tree", "core-math:2500:primitives")

	testing.SetRealm(testing.NewUserRealm(aLibB))
	testing.SetOriginCaller(aLibB)
	Register(cross(cur), "svg-kit", "SVGKit", "gno.land/p/demo/svg", aLibB)
	SetSplits(cross(cur), "svg-kit", "core-math:2000:geometry")

	testing.SetRealm(testing.NewUserRealm(aApp))
	testing.SetOriginCaller(aApp)
	Register(cross(cur), "swap-ui", "SwapUI", "gno.land/r/demo/swap", aApp)
	SetSplits(cross(cur), "swap-ui", "avl-tree:2000:storage,svg-kit:1000:charts")
	Lock(cross(cur), "swap-ui")

	// Verify locked node rejects any subsequent split edits
	uassert.AbortsWithMessage(t, cur, "tributary: node graph is permanently locked", func() {
		SetSplits(cross(cur), "swap-ui", "")
	})

	// Verify cycle attack from core-math -> swap-ui is rejected
	testing.SetRealm(testing.NewUserRealm(aCore))
	testing.SetOriginCaller(aCore)
	uassert.AbortsWithMessage(t, cur, "tributary: cycle detected in dependency graph", func() {
		SetSplits(cross(cur), "core-math", "swap-ui:1000:cycle")
	})

	// Verify Deposit rejects zero-coin call
	testing.SetRealm(testing.NewUserRealm(aDonor))
	testing.SetOriginCaller(aDonor)
	testing.SetOriginSend(nil)
	uassert.AbortsWithMessage(t, cur, "tributary: attach positive ugnot coins to Deposit", func() {
		Deposit(cross(cur), "swap-ui", "empty")
	})

	// Fund realm escrow to simulate attached OriginSend coins of 1,000,000 ugnot (1 GNOT)
	const deposit int64 = 1000000
	testing.IssueCoins(realmAddr, chain.NewCoins(chain.NewCoin(denom, deposit)))
	testing.SetRealm(testing.NewUserRealm(aDonor))
	testing.SetOriginCaller(aDonor)
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin(denom, deposit)))

	Deposit(cross(cur), "swap-ui", "Q4 protocol fees")

	// Verify exact diamond-DAG splits:
	// swap-ui keeps 70% = 700,000
	// avl-tree gets 200,000 -> forwards 25% (50,000) to core-math, keeps 150,000
	// svg-kit gets 100,000 -> forwards 20% (20,000) to core-math, keeps 80,000
	// core-math gets 50,000 + 20,000 = 70,000
	if got := PendingBalance(aApp); got != 700000 {
		t.Fatalf("aApp pending=%d want 700000", got)
	}
	if got := PendingBalance(aLibA); got != 150000 {
		t.Fatalf("aLibA pending=%d want 150000", got)
	}
	if got := PendingBalance(aLibB); got != 80000 {
		t.Fatalf("aLibB pending=%d want 80000", got)
	}
	if got := PendingBalance(aCore); got != 70000 {
		t.Fatalf("aCore pending=%d want 70000", got)
	}

	// Maintainer aCore claims real ugnot via banker
	testing.SetRealm(testing.NewUserRealm(aCore))
	testing.SetOriginCaller(aCore)
	testing.SetOriginSend(nil)
	gotClaim := Claim(cross(cur))
	if gotClaim != 70000 {
		t.Fatalf("claimed=%d want 70000", gotClaim)
	}
	if PendingBalance(aCore) != 0 || ClaimedBalance(aCore) != 70000 {
		t.Fatalf("claim accounting mismatch")
	}

	ro := banker.NewReadonlyBanker()
	if bal := ro.GetCoin(aCore, denom); bal != 70000 {
		t.Fatalf("on-chain coin balance of aCore=%d want 70000", bal)
	}

	// Verify Render outputs home, node detail with SVG, and address ledger cleanly
	home := Render("")
	if !strings.Contains(home, "Tributary") || !strings.Contains(home, "data:image/svg+xml;base64,") {
		t.Fatalf("home render missing header or SVG")
	}
	nodeView := Render("node/swap-ui")
	if !strings.Contains(nodeView, "PERMANENTLY LOCKED") || !strings.Contains(nodeView, "core-math") {
		t.Fatalf("node render missing lock status or upstream share")
	}
	addrView := Render("addr/" + aCore.String())
	if !strings.Contains(addrView, "70000 ugnot") {
		t.Fatalf("addr render missing claimed amount: %s", addrView)
	}

	// Test permissionless ClaimFor: aDonor pays gas to flush aLibA's 150,000 ugnot directly to aLibA
	testing.SetRealm(testing.NewUserRealm(aDonor))
	testing.SetOriginCaller(aDonor)
	flushed := ClaimFor(cross(cur), aLibA)
	if flushed != 150000 || ro.GetCoin(aLibA, denom) != 150000 || PendingBalance(aLibA) != 0 {
		t.Fatalf("ClaimFor failed: flushed=%d bal=%d pending=%d", flushed, ro.GetCoin(aLibA, denom), PendingBalance(aLibA))
	}

	// Test SetBeneficiary on unlocked node (avl-tree) and verify non-owner is rejected
	newBen := testutils.TestAddress("realm_libA_treasury")
	testing.SetRealm(testing.NewUserRealm(aDonor))
	testing.SetOriginCaller(aDonor)
	uassert.AbortsWithMessage(t, cur, "tributary: caller is not node owner", func() {
		SetBeneficiary(cross(cur), "avl-tree", newBen)
	})
	testing.SetRealm(testing.NewUserRealm(aLibA))
	testing.SetOriginCaller(aLibA)
	SetBeneficiary(cross(cur), "avl-tree", newBen)

	// Test DepositWithBanker rejects non-canonical fake banker
	uassert.AbortsWithMessage(t, cur, "tributary: non-canonical banker rejected", func() {
		DepositWithBanker(cross(cur), "swap-ui", "spoof", fakeBanker{}, 1000)
	})

	// Second prime deposit (500,003 ugnot) verifies newBen gets AVLTree's retained share with 0 dust
	const dep2 int64 = 500003
	testing.IssueCoins(realmAddr, chain.NewCoins(chain.NewCoin(denom, dep2)))
	testing.SetRealm(testing.NewUserRealm(aDonor))
	testing.SetOriginCaller(aDonor)
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin(denom, dep2)))
	Deposit(cross(cur), "swap-ui", "prime stress #2")

	if TotalRouted() != deposit+dep2 {
		t.Fatalf("TotalRouted=%d want %d", TotalRouted(), deposit+dep2)
	}
	if PendingBalance(newBen) <= 0 {
		t.Fatalf("expected newBen to receive AVLTree retained share, got %d", PendingBalance(newBen))
	}
}

type fakeBanker struct{}

func (fakeBanker) GetCoins(address) chain.Coins        { return nil }
func (fakeBanker) GetCoin(address, string) int64       { return 0 }
func (fakeBanker) SendCoins(address, address, chain.Coins) {}
func (fakeBanker) TotalCoin(string) int64              { return 0 }
func (fakeBanker) IssueCoin(address, string, int64)    {}
func (fakeBanker) RemoveCoin(address, string, int64)   {}
