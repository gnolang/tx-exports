package tributary_demo

import (
	"chain"
	"chain/banker"
	"strings"
	"testing"

	"gno.land/p/nt/testutils/v0"
	rtrib "gno.land/r/g196fz02krdlf6fc7a7p2w8e4rkywepwn5c9nh63/tributary"
)

func TestCrossRealmDepositWithBanker(cur realm, t *testing.T) {
	aApp := testutils.TestAddress("demo_app")
	aCore := testutils.TestAddress("demo_core")
	aTrader := testutils.TestAddress("demo_trader")

	demoAddr := chain.PackageAddress("gno.land/r/g196fz02krdlf6fc7a7p2w8e4rkywepwn5c9nh63/tributary_demo")

	// Set up a 2-node DAG in r/tributary: swap-ui -> 30% core-lib
	testing.SetRealm(testing.NewUserRealm(aCore))
	testing.SetOriginCaller(aCore)
	rtrib.Register(cross(cur), "core-lib", "CoreLib", "gno.land/p/demo/core", aCore)

	testing.SetRealm(testing.NewUserRealm(aApp))
	testing.SetOriginCaller(aApp)
	rtrib.Register(cross(cur), "swap-ui", "SwapUI", "gno.land/r/demo/swap", aApp)
	rtrib.SetSplits(cross(cur), "swap-ui", "core-lib:3000:core")

	// Simulate user sending 100,000 ugnot to SwapDemo:
	// 10% (10,000 ugnot) streams cross-realm into r/tributary (7,000 app + 3,000 core), 90,000 refunded to trader!
	const sent int64 = 100000
	testing.IssueCoins(demoAddr, chain.NewCoins(chain.NewCoin(denom, sent)))
	testing.SetRealm(testing.NewUserRealm(aTrader))
	testing.SetOriginCaller(aTrader)
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin(denom, sent)))

	fee := SwapDemo(cross(cur), "live cross-realm test")
	if fee != 10000 {
		t.Fatalf("fee=%d want 10000", fee)
	}

	ro := banker.NewReadonlyBanker()
	if bal := ro.GetCoin(aTrader, denom); bal != 90000 {
		t.Fatalf("trader refund=%d want 90000", bal)
	}
	if got := rtrib.PendingBalance(aApp); got != 7000 {
		t.Fatalf("app pending=%d want 7000", got)
	}
	if got := rtrib.PendingBalance(aCore); got != 3000 {
		t.Fatalf("core pending=%d want 3000", got)
	}

	out := Render("")
	if !strings.Contains(out, "Auto-Streamed to Upstream OSS DAG") || !strings.Contains(out, "10000 ugnot") {
		t.Fatalf("unexpected Render output: %s", out)
	}
}
