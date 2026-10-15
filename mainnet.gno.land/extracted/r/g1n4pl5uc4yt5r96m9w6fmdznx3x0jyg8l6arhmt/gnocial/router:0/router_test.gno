package router

import (
	"chain"
	"strings"
	"testing"
	"time"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
	"gno.land/p/nt/urequire/v0"
)

const (
	gns    = "gno.land/r/gnoswap/gns.gns"
	route1 = "gno.land/r/gnoland/wugnot.wugnot:gno.land/r/gnoswap/gns.gns:500"
)

func mustAbort(t *testing.T, rlm realm, msg string, fn func()) {
	if !uassert.AbortsWithMessage(t, rlm, msg, fn) {
		t.FailNow()
	}
}

func mustPanic(t *testing.T, rlm realm, msg string, fn func()) {
	if !uassert.PanicsWithMessage(t, rlm, msg, fn) {
		t.FailNow()
	}
}

func TestSplit(t *testing.T) {
	fee, swapAmt := Split(10_000)
	urequire.Equal(t, int64(1), fee)
	urequire.Equal(t, int64(9999), swapAmt)
	fee, swapAmt = Split(9999)
	urequire.Equal(t, int64(0), fee)
	urequire.Equal(t, int64(9999), swapAmt)
	fee, swapAmt = Split(1)
	urequire.Equal(t, int64(0), fee)
	urequire.Equal(t, int64(1), swapAmt)
	urequire.Equal(t, "g1n4pl5uc4yt5r96m9w6fmdznx3x0jyg8l6arhmt", FeeTo())
	urequire.Equal(t, "g1vc883gshu5z7ytk5cdynhc8c2dh67pdp4cszkp", GnoSwapRouter())
	if !address(Address()).IsValid() {
		t.Fatalf("address %s", Address())
	}
}

func TestSplitRejectsEmpty(cur realm, t *testing.T) {
	mustPanic(t, cur, "amount must be positive", func() { Split(0) })
	mustPanic(t, cur, "amount must be positive", func() { Split(-1) })
}

func TestRender(t *testing.T) {
	if !strings.Contains(Render(""), "0.01%") {
		t.Fatal("home")
	}
	if !strings.Contains(Render("nope"), "not a page") {
		t.Fatal("path")
	}
}

func TestQuoteRejectsBadAmount(cur realm, t *testing.T) {
	mustPanic(t, cur, "amount is not valid", func() {
		Quote(Wugnot, gns, "12x", route1, "100")
	})
	mustPanic(t, cur, "same token", func() {
		Quote(Wugnot, Wugnot, "100", route1, "100")
	})
}

func TestSwapRejectsRealmAndCoins(cur realm, t *testing.T) {
	alice := testutils.TestAddress("alice")
	deadline := time.Now().Unix() + 600
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/attacker/mid"))
	mustAbort(t, cur, "direct wallet call only", func() {
		Swap(cross(cur), Wugnot, gns, 10_000, route1, "100", 1, deadline)
	})
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(chain.Coins{chain.NewCoin("ugnot", 1)})
	mustAbort(t, cur, "send no coins", func() {
		Swap(cross(cur), Wugnot, gns, 10_000, route1, "100", 1, deadline)
	})
}

func TestSwapRejectsBadArgs(cur realm, t *testing.T) {
	alice := testutils.TestAddress("alice")
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	deadline := time.Now().Unix() + 600
	mustAbort(t, cur, "same token", func() {
		Swap(cross(cur), Wugnot, Wugnot, 10_000, route1, "100", 1, deadline)
	})
	mustAbort(t, cur, "token path is not valid", func() {
		Swap(cross(cur), "gno.land/r/../x", gns, 10_000, route1, "100", 1, deadline)
	})
	mustAbort(t, cur, "route is not valid", func() {
		Swap(cross(cur), Wugnot, gns, 10_000, "", "100", 1, deadline)
	})
	mustAbort(t, cur, "minimum output must be positive", func() {
		Swap(cross(cur), Wugnot, gns, 10_000, route1, "100", 0, deadline)
	})
	mustAbort(t, cur, "route expired", func() {
		Swap(cross(cur), Wugnot, gns, 10_000, route1, "100", 1, time.Now().Unix()-1)
	})
	mustAbort(t, cur, "amount must be positive", func() {
		Swap(cross(cur), Wugnot, gns, 0, route1, "100", 1, deadline)
	})
}
