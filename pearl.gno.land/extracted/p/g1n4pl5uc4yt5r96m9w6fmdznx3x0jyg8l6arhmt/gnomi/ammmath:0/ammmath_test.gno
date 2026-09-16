package ammmath

import "testing"

func TestApplyFee(t *testing.T) {
	f := ApplyFee(10000, 120, 4000, 4000)
	if f.Fee != 120 {
		t.Fatalf("fee=%d want 120", f.Fee)
	}
	if f.Net != 9880 {
		t.Fatalf("net=%d want 9880", f.Net)
	}
	if f.Creator != 48 {
		t.Fatalf("creator=%d want 48", f.Creator)
	}
	if f.Protocol != 48 {
		t.Fatalf("protocol=%d want 48", f.Protocol)
	}
	if f.Remainder != 24 {
		t.Fatalf("remainder=%d want 24", f.Remainder)
	}
}

func TestBuySellRoundtripApprox(t *testing.T) {
	vu := int64(30000000)
	vt := int64(1073000191)
	tokens, vu2, vt2 := BuyTokens(vu, vt, 1000000)
	if tokens <= 0 {
		t.Fatal("expected tokens out")
	}
	if vu2 != vu+1000000 {
		t.Fatalf("vu2=%d", vu2)
	}
	half := tokens / 2
	if half <= 0 {
		t.Fatal("half")
	}
	ugnotOut, vu3, vt3 := SellTokens(vu2, vt2, half)
	if ugnotOut <= 0 {
		t.Fatal("expected ugnot out")
	}
	if vu3 >= vu2 || vt3 <= vt2 {
		t.Fatalf("reserves did not move correctly vu3=%d vt3=%d", vu3, vt3)
	}
}

func TestPoolSwap(t *testing.T) {
	pu, pt := int64(85000000), int64(200000000)
	tokOut, pu2, pt2 := PoolSwapUgnotForToken(pu, pt, 1000000, 0)
	if tokOut <= 0 {
		t.Fatal("tokens")
	}
	if pu2 != pu+1000000 {
		t.Fatalf("pu2=%d", pu2)
	}
	if pt2 != pt-tokOut {
		t.Fatalf("pt2=%d", pt2)
	}
	ugOut, pu3, pt3 := PoolSwapTokenForUgnot(pu2, pt2, tokOut/2)
	if ugOut <= 0 {
		t.Fatal("ugnot")
	}
	if pu3 >= pu2 || pt3 <= pt2 {
		t.Fatal("pool direction")
	}
}

func TestCanGraduate(t *testing.T) {
	if CanGraduate(84, 85) {
		t.Fatal("should not graduate")
	}
	if !CanGraduate(85, 85) {
		t.Fatal("should graduate")
	}
}

func TestSpotPrice(t *testing.T) {
	// 30e6 ugnot / 1e9 tokens * 1e6 scale = 30000
	p := SpotPriceUgnotPerToken(30000000, 1000000000)
	if p != 30000 {
		t.Fatalf("spot=%d want 30000", p)
	}
}
