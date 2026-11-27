package hello_verify_a

import (
	"chain"
	"chain/banker"
	"strings"
	"testing"
)

func assertAborts(t *testing.T, name string, wantSubstr string, fn func()) {
	t.Helper()
	r := revive(fn)
	if r == nil {
		t.Fatalf("%s: expected abort/panic, but did not abort", name)
	}
	if s, ok := r.(string); ok {
		if wantSubstr != "" && !strings.Contains(s, wantSubstr) {
			t.Fatalf("%s: expected abort containing %q, got %q", name, wantSubstr, s)
		}
	}
}

func TestVerifyAllCompileAndLocalLogic(cur realm, t *testing.T) {
	alice := address("g1fn0l3ms5puafp37r7v67mx2msjl0ztnyq3a9yv")
	bob := address("g1syuz534wv9mugk5dnvaxvd9yxrzn05ke9dp0gq")

	admin = alice

	// 0. Mint secondary realm denom for realistic wrong-denom / multi-coin tests
	testing.SetRealm(testing.NewUserRealm(alice))
	dummyDenom := MintTestDenom(cross(cur), 5000)
	if !strings.HasSuffix(dummyDenom, ":dummy") {
		t.Fatalf("unexpected dummy denom: %s", dummyDenom)
	}

	// 1. Exact single ugnot deposit succeeds
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin("ugnot", 1000)))
	out := DepositExact(cross(cur), 1000)
	if !strings.Contains(out, "accepted=1000") {
		t.Fatalf("unexpected DepositExact output: %s", out)
	}

	// 2. Excess amount aborts
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin("ugnot", 1500)))
	assertAborts(t, "excess amount", "exact amount mismatch", func() {
		DepositExact(cross(cur), 1000)
	})

	// 3. Wrong denom aborts
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin(dummyDenom, 1000)))
	assertAborts(t, "wrong denom", "invalid denom", func() {
		DepositExact(cross(cur), 1000)
	})

	// 4. Multi-coin aborts
	testing.SetOriginSend(chain.NewCoins(
		chain.NewCoin("ugnot", 1000),
		chain.NewCoin(dummyDenom, 500),
	))
	assertAborts(t, "multi coin", "must send exactly one coin", func() {
		DepositExact(cross(cur), 1000)
	})

	// 5. InspectSend records multi-coin raw
	rawOut := InspectSend(cross(cur), "multi-raw")
	if !strings.Contains(rawOut, "len=2") {
		t.Fatalf("expected len=2 in InspectSend, got: %s", rawOut)
	}

	// 6. DepositThenPanic aborts
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin("ugnot", 777)))
	assertAborts(t, "deposit then panic", "intentional panic after receiving coins", func() {
		DepositThenPanic(cross(cur))
	})

	// 6b. Non-EOA code realm call to DepositExact aborts (anti-MITM guard)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/g1fn0l3ms5puafp37r7v67mx2msjl0ztnyq3a9yv/hello_verify_b"))
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin("ugnot", 1000)))
	assertAborts(t, "non-EOA deposit", "must be called directly by EOA", func() {
		DepositExact(cross(cur), 1000)
	})
	testing.SetRealm(testing.NewUserRealm(alice))

	// 7. Banker SendFromRealm transfers ugnot to bob
	testing.IssueCoins(realmAddr, chain.NewCoins(chain.NewCoin("ugnot", 5000)))
	testing.SetOriginSend(nil)
	beforeBob := banker.NewReadonlyBanker().GetCoin(bob, "ugnot")
	SendFromRealm(cross(cur), bob, 2000)
	afterBob := banker.NewReadonlyBanker().GetCoin(bob, "ugnot")
	if afterBob-beforeBob != 2000 {
		t.Fatalf("expected bob balance +2000, got delta=%d", afterBob-beforeBob)
	}

	// 8. Cross-realm call A -> B records prevPkg = hello_verify_a and origin = alice
	crossOut := CallCrossB(cross(cur), "unit")
	if !strings.Contains(crossOut, "prevIsEOA=false") {
		t.Fatalf("expected prevIsEOA=false on cross call, got: %s", crossOut)
	}
	if !strings.Contains(crossOut, "prevPkg=gno.land/r/g1fn0l3ms5puafp37r7v67mx2msjl0ztnyq3a9yv/hello_verify_a") {
		t.Fatalf("expected prevPkg=hello_verify_a, got: %s", crossOut)
	}
	if !strings.Contains(crossOut, "origin="+alice.String()) {
		t.Fatalf("expected origin=%s, got: %s", alice.String(), crossOut)
	}

	// 9. RecordTimestamp & Render
	ts := RecordTimestamp(cross(cur), "t1")
	if ts <= 0 {
		t.Fatalf("expected positive timestamp, got %d", ts)
	}
	if !strings.Contains(Render("json/state"), `"realm":"hello_verify_a"`) {
		t.Fatalf("unexpected json render: %s", Render("json/state"))
	}
}
