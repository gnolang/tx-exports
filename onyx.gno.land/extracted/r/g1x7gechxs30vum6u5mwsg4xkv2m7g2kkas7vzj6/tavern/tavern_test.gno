package tavern

import (
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

// cur is a zero-value realm used as a placeholder when forwarding to
// uassert helpers that take an `rlm realm` param. The test callbacks do
// their crossing inside the callback, so rlm is ignored here.
var cur realm

func TestTokenBasics(cur realm, t *testing.T) {
	admin := address("g1x7gechxs30vum6u5mwsg4xkv2m7g2kkas7vzj6")
	alice := testutils.TestAddress("alice")

	uassert.Equal(t, TotalSupply(), int64(1_000_000*oneALE))
	uassert.Equal(t, BalanceOf(admin), int64(1_000_000*oneALE))
	uassert.Equal(t, BalanceOf(alice), int64(0))
	uassert.Equal(t, Token.GetName(), "Tavern Ale")
	uassert.Equal(t, Token.GetSymbol(), "ALE")
	uassert.Equal(t, Token.GetDecimals(), 6)
}

func TestMenuAndRender(cur realm, t *testing.T) {
	menu := Menu()
	uassert.Equal(t, menu, "- Gnome Stout: 50.000000 ALE\n- Fairy Fizz: 30.000000 ALE\n- Dragon's Breath Ale: 120.000000 ALE\n- Mushroom Mead: 80.000000 ALE\n- Tavern Water: 5.000000 ALE\n")

	home := Render("")
	if !contains(home, "Gnome Tavern") {
		t.Fatalf("home page should mention Gnome Tavern")
	}
	if !contains(home, "Gnome Stout") {
		t.Fatalf("home page should list the menu")
	}
	if !contains(home, "Top patrons") {
		t.Fatalf("home page should list top patrons")
	}
	uassert.Equal(t, Render("nonsense/path/here"), "404\n")
}

func TestFaucet(cur realm, t *testing.T) {
	bob := testutils.TestAddress("bob")

	testing.SetOriginCaller(bob)
	got := Faucet(cross(cur))
	uassert.Equal(t, got, int64(faucetAmount))
	uassert.Equal(t, BalanceOf(bob), int64(100*oneALE))
	uassert.Equal(t, TotalSupply(), int64(1_000_000*oneALE+100*oneALE))
	uassert.Equal(t, FaucetInfo(), "Faucet: 100.000000 ALE claimed of 100000.000000 ALE cap, 100.000000 ALE per claim, one claim per address every 24h.")

	// A second claim in the same block must fail: the 24h cooldown.
	uassert.AbortsContains(t, cur, "faucet cooldown", func() {
		Faucet(cross(cur))
	})
	// ...and the failed claim changed nothing.
	uassert.Equal(t, BalanceOf(bob), int64(100*oneALE))

	// Another address can still claim.
	alice := testutils.TestAddress("alice")
	testing.SetOriginCaller(alice)
	Faucet(cross(cur))
	uassert.Equal(t, BalanceOf(alice), int64(100*oneALE))
}

func TestBuyDrink(cur realm, t *testing.T) {
	admin := address("g1x7gechxs30vum6u5mwsg4xkv2m7g2kkas7vzj6")
	// NOTE: test functions in one file share realm state, so each test
	// uses its own caller address (bob already claimed in TestFaucet).
	carol := testutils.TestAddress("carol")

	testing.SetOriginCaller(carol)
	Faucet(cross(cur))

	msg := BuyDrink(cross(cur), "Gnome Stout")
	uassert.Equal(t, msg, "Enjoy your Gnome Stout! Tab total: 50.000000 ALE.")
	uassert.Equal(t, BalanceOf(carol), int64(50*oneALE))
	// The 50 ALE went to the tavern till (the owner).
	uassert.Equal(t, BalanceOf(admin), int64(1_000_000*oneALE+50*oneALE))

	tab := TabOf(carol)
	if !contains(tab, "Gnome Stout x1") {
		t.Fatalf("tab should list the stout, got: %s", tab)
	}
	if !contains(tab, "50.000000 ALE") {
		t.Fatalf("tab total should be 50 ALE, got: %s", tab)
	}

	// A second round updates the same tab.
	BuyDrink(cross(cur), "Fairy Fizz")
	uassert.Equal(t, BalanceOf(carol), int64(20*oneALE))
	tab = TabOf(carol)
	if !contains(tab, "Gnome Stout x1") || !contains(tab, "Fairy Fizz x1") {
		t.Fatalf("tab should list both drinks, got: %s", tab)
	}
	if !contains(tab, "80.000000 ALE") {
		t.Fatalf("tab total should be 80 ALE, got: %s", tab)
	}

	// The leaderboard names carol.
	top := TopPatrons()
	if !contains(top, carol.String()) {
		t.Fatalf("top patrons should list carol, got: %s", top)
	}

	// An unknown drink aborts and changes nothing.
	uassert.AbortsContains(t, cur, "unknown drink", func() {
		BuyDrink(cross(cur), "Unicorn Tears")
	})
	uassert.Equal(t, BalanceOf(carol), int64(20*oneALE))
}

func TestTransferAndRenderPaths(cur realm, t *testing.T) {
	dave := testutils.TestAddress("dave")
	erin := testutils.TestAddress("erin")

	testing.SetOriginCaller(dave)
	Faucet(cross(cur))
	Transfer(cross(cur), erin, 40*oneALE)
	uassert.Equal(t, BalanceOf(dave), int64(60*oneALE))
	uassert.Equal(t, BalanceOf(erin), int64(40*oneALE))

	// Render sub-pages echo the sanitized address and the live state.
	bal := Render("balance/" + dave.String())
	if !contains(bal, "60.000000 ALE") {
		t.Fatalf("balance page should show 60 ALE, got: %s", bal)
	}
	tab := Render("tab/" + erin.String())
	if !contains(tab, "No tab yet") {
		t.Fatalf("erin has no tab yet, got: %s", tab)
	}
}

func TestMintIsOwnerOnly(cur realm, t *testing.T) {
	frank := testutils.TestAddress("frank")
	testing.SetOriginCaller(frank)
	// Only the tavern keeper (the deployer) may mint.
	uassert.AbortsContains(t, cur, "not owner", func() {
		Mint(cross(cur), frank, 1)
	})
}

func contains(s, sub string) bool {
	if len(sub) == 0 {
		return true
	}
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}
