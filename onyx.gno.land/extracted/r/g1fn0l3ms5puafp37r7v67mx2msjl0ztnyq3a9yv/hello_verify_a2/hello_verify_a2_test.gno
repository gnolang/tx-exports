package hello_verify_a2

import (
	"chain"
	"strings"
	"testing"
)

func TestA2CompileAndLocalBehavior(cur realm, t *testing.T) {
	alice := address("g1fn0l3ms5puafp37r7v67mx2msjl0ztnyq3a9yv")
	bob := address("g1syuz534wv9mugk5dnvaxvd9yxrzn05ke9dp0gq")

	// B1: Alice writes blob, Bob deletes blob
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	n := WriteBlob(cross(cur), "k1", 2000)
	if n != 2000 || len(blobs) != 1 {
		t.Fatalf("expected blob size 2000, got %d", n)
	}
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(nil)
	if !DeleteBlob(cross(cur), "k1") || len(blobs) != 0 {
		t.Fatalf("expected blob deleted")
	}

	// Non-payable guard rejects coins
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin("ugnot", 1)))
	if r := revive(func() { WriteBlob(cross(cur), "k2", 10) }); r == nil {
		t.Fatalf("expected non-payable WriteBlob to abort when coins sent")
	}

	// B2: Cross-realm panic aborts
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin("ugnot", 500)))
	r2 := revive(func() {
		DepositMutateAndCallPanicB(cross(cur), "unit-b2")
	})
	if r2 == nil {
		t.Fatalf("expected B2 to abort")
	}

	// B3a: defer/recover() does NOT catch cross-realm panic
	r3a := revive(func() {
		DepositMutateAndTryRecoverB(cross(cur), "unit-b3a")
	})
	if r3a == nil {
		t.Fatalf("expected B3a (recover) to still abort across realm boundary")
	}
	if recoveredMsg != "" {
		t.Fatalf("expected recover() NOT to run across realm boundary, got %q", recoveredMsg)
	}

	// B3b: In local gno test mode, ReviveEnabled=true so revive() catches it (we test on onyx-1 where ReviveEnabled=false!)
	res3b := DepositMutateAndTryReviveB(cross(cur), "unit-b3b")
	if res3b != "revived" {
		t.Fatalf("expected local test mode revive() to return 'revived', got %q", res3b)
	}

	if !strings.Contains(Render("json/state"), `"realm":"hello_verify_a2"`) {
		t.Fatalf("unexpected render: %s", Render("json/state"))
	}
}
