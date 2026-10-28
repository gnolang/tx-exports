package bond

import (
	"testing"
	"time"
)

func TestInitAndNormalBond(cur realm, t *testing.T) {
	// reset via re-init not possible; use fresh package state in isolation
	// In gno test each filetest gets package — use functions after Init once.
	admin := address("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5")
	testing.SetRealm(testing.NewUserRealm(admin))
	// Allow re-init only if not inited — first test in package
	if !inited {
		Init(cross(cur))
	} else {
		// force normal for this suite
		promoEnded = true
		normalBondUgnot = DefaultNormalBondUgnot
	}
	if CurrentBondUgnot() != DefaultNormalBondUgnot {
		t.Fatalf("normal bond=%d", CurrentBondUgnot())
	}
}

func TestPromoWindowAndEnd(cur realm, t *testing.T) {
	admin := address("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5")
	testing.SetRealm(testing.NewUserRealm(admin))
	if !inited {
		Init(cross(cur))
	}
	// 1 hour promo at 20 GNOT
	StartPromo(cross(cur), 20_000_000, 3600)
	if !IsPromoActive() {
		t.Fatal("expected promo active")
	}
	if CurrentBondUgnot() != 20_000_000 {
		t.Fatalf("promo bond=%d", CurrentBondUgnot())
	}
	if PromoSecondsLeft() <= 0 || PromoSecondsLeft() > 3600 {
		t.Fatalf("seconds left=%d", PromoSecondsLeft())
	}
	EndPromo(cross(cur))
	if IsPromoActive() {
		t.Fatal("promo should be ended")
	}
	if CurrentBondUgnot() != normalBondUgnot {
		t.Fatalf("after end bond=%d want %d", CurrentBondUgnot(), normalBondUgnot)
	}
	_ = time.Now()
}

func TestSetBonds(cur realm, t *testing.T) {
	admin := address("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5")
	testing.SetRealm(testing.NewUserRealm(admin))
	if !inited {
		Init(cross(cur))
	}
	EndPromo(cross(cur))
	SetNormalBond(cross(cur), 3_000_000)
	if CurrentBondUgnot() != 3_000_000 {
		t.Fatalf("normal=%d", CurrentBondUgnot())
	}
	SetPromoBond(cross(cur), 40_000_000)
	StartPromo(cross(cur), 0, 100)
	if CurrentBondUgnot() != 40_000_000 {
		t.Fatalf("promo=%d", CurrentBondUgnot())
	}
	// restore defaults for other tests
	SetNormalBond(cross(cur), DefaultNormalBondUgnot)
	EndPromo(cross(cur))
}
