package gun

import (
	"chain"
	"chain/banker"
	"strings"
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

var (
	realmAddr = chain.PackageAddress(pkgPath)
	ayse      = testutils.TestAddress("ayse")
	mehmet    = testutils.TestAddress("mehmet")
	zeynep    = testutils.TestAddress("zeynep")
	outsider  = testutils.TestAddress("outsider")
)

const gnot1 = int64(1_000_000)

// send attaches ugnot to the next call. The coins are issued to the realm to
// mirror what the chain does with -send. (testing.SetRealm must be called in
// the test function itself: it applies to the frame that calls it.)
func send(send int64) {
	if send > 0 {
		testing.SetOriginSend(chain.Coins{{denom, send}})
		testing.IssueCoins(realmAddr, chain.Coins{{denom, send}})
	} else {
		testing.SetOriginSend(nil)
	}
}

func balance(a address) int64 {
	return banker.NewReadonlyBanker().GetCoin(a, denom)
}

func reset() {
	circles = newTree()
	byMember = newTree()
	lastID = 0
	totalHeld = 0
}

func members() string {
	return ayse.String() + ", " + mehmet.String() + " " + zeynep.String()
}

func TestFullCircle(cur realm, t *testing.T) {
	reset()
	testing.SetRealm(testing.NewUserRealm(ayse))
	send(0)
	id := Create(cross(cur), "Salı günü", gnot1, 60, 2, 3600, members())
	uassert.Equal(t, 1, id)

	for _, a := range []address{ayse, mehmet, zeynep} {
		testing.SetRealm(testing.NewUserRealm(a))
		send(2 * gnot1)
		Join(cross(cur), id)
	}
	c := mustGet(id)
	uassert.Equal(t, "active", c.Status().String())
	uassert.Equal(t, 6*gnot1, totalHeld)

	for round := 0; round < 3; round++ {
		for _, a := range []address{ayse, mehmet, zeynep} {
			testing.SetRealm(testing.NewUserRealm(a))
			send(gnot1)
			Pay(cross(cur), id)
		}
		testing.SkipHeights(13) // 65 s: next round
	}
	uassert.Equal(t, "completed", c.Status().String())
	// Each member: 3 GNOT pot + 2 GNOT collateral back.
	uassert.Equal(t, 15*gnot1, totalHeld)

	for _, a := range []address{ayse, mehmet, zeynep} {
		before := balance(a)
		testing.SetRealm(testing.NewUserRealm(a))
		send(0)
		Withdraw(cross(cur), id)
		uassert.Equal(t, before+5*gnot1, balance(a))
	}
	uassert.Equal(t, int64(0), totalHeld)
	uassert.AbortsWithMessage(t, cur, "rosca: nothing to withdraw", func() { Withdraw(cross(cur), id) })

	page := Render("c/1")
	uassert.True(t, strings.Contains(page, "# Salı günü"), page)
	uassert.True(t, strings.Contains(page, "Fully secured"), page)
	uassert.True(t, strings.Contains(page, "`PPP`"), page)
	uassert.True(t, strings.Contains(page, "completed"), page)
}

func TestPaymentGuards(cur realm, t *testing.T) {
	reset()
	testing.SetRealm(testing.NewUserRealm(ayse))
	send(0)
	id := Create(cross(cur), "guards", gnot1, 60, 1, 3600, members())

	// Wrong amount.
	testing.SetRealm(testing.NewUserRealm(ayse))
	send(gnot1 - 1)
	uassert.AbortsWithMessage(t, cur, "rosca: wrong amount sent", func() { Join(cross(cur), id) })

	// Other denoms are refused outright.
	testing.SetRealm(testing.NewUserRealm(ayse))
	testing.SetOriginSend(chain.Coins{{"uatom", gnot1}})
	uassert.AbortsWithMessage(t, cur, "gun: only ugnot is accepted", func() { Join(cross(cur), id) })

	// A code realm in between could keep the coins and still pass an
	// OriginSend check; it must be refused.
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/attacker/wrapper"))
	testing.SetOriginSend(chain.Coins{{denom, gnot1}})
	uassert.AbortsWithMessage(t, cur, "gun: call Join directly from your account", func() { Join(cross(cur), id) })

	// Strangers cannot join.
	testing.SetRealm(testing.NewUserRealm(outsider))
	send(gnot1)
	uassert.AbortsWithMessage(t, cur, "rosca: not a member of this circle", func() { Join(cross(cur), id) })

	uassert.AbortsWithMessage(t, cur, "gun: no circle with id 99", func() { Join(cross(cur), 99) })
	uassert.Equal(t, int64(0), totalHeld)
}

func TestCreateValidation(cur realm, t *testing.T) {
	reset()
	testing.SetRealm(testing.NewUserRealm(outsider))
	send(0)
	uassert.AbortsWithMessage(t, cur, "rosca: the organizer must be one of the members",
		func() { Create(cross(cur), "x", gnot1, 60, 0, 3600, members()) })
	testing.SetRealm(testing.NewUserRealm(ayse))
	send(0)
	uassert.AbortsWithMessage(t, cur, "rosca: invalid member address",
		func() { Create(cross(cur), "x", gnot1, 60, 0, 3600, ayse.String()+",not-an-address") })
	many := ayse.String()
	for i := 0; i < 20; i++ {
		many += " " + testutils.TestAddress("m"+string(rune('a'+i))).String()
	}
	uassert.AbortsWithMessage(t, cur, "rosca: a circle needs 2 to 12 members",
		func() { Create(cross(cur), "x", gnot1, 60, 0, 3600, many) })
}

func TestSettleAndBreak(cur realm, t *testing.T) {
	reset()
	testing.SetRealm(testing.NewUserRealm(ayse))
	send(0)
	id := Create(cross(cur), "no collateral", gnot1, 60, 0, 3600, members())
	for _, a := range []address{ayse, mehmet, zeynep} {
		testing.SetRealm(testing.NewUserRealm(a))
		send(0)
		Join(cross(cur), id)
	}
	testing.SetRealm(testing.NewUserRealm(ayse))
	send(gnot1)
	Pay(cross(cur), id)
	testing.SetRealm(testing.NewUserRealm(mehmet))
	send(gnot1)
	Pay(cross(cur), id)

	testing.SetRealm(testing.NewUserRealm(outsider))
	send(0)
	uassert.AbortsWithMessage(t, cur, "rosca: the round is not due yet", func() { Settle(cross(cur), id) })
	testing.SkipHeights(13)
	Settle(cross(cur), id) // anyone can settle; Zeynep has no collateral
	c := mustGet(id)
	uassert.Equal(t, "broken", c.Status().String())
	// Ayşe and Mehmet get their payments back.
	uassert.Equal(t, 2*gnot1, totalHeld)
	page := Render("c/1")
	uassert.True(t, strings.Contains(page, "`PPX`"), page)
	uassert.True(t, strings.Contains(page, "not formed"), page)
	uassert.True(t, strings.Contains(page, "· defaulted"), page)
}

func TestRenderPages(cur realm, t *testing.T) {
	reset()
	home := Render("")
	uassert.True(t, strings.Contains(home, "No circles yet."), home)

	testing.SetRealm(testing.NewUserRealm(ayse))
	send(0)
	for i := 0; i < 12; i++ {
		Create(cross(cur), "circle *"+string(rune('a'+i))+"*", gnot1, 60, 1, 3600, members())
	}
	home = Render("")
	uassert.True(t, strings.Contains(home, "page 1 of 2"), home)
	uassert.True(t, strings.Contains(home, ":c/12)"), "newest first")
	uassert.False(t, strings.Contains(home, ":c/2)"), "second page item on first page")
	page2 := Render("?page=2")
	uassert.True(t, strings.Contains(page2, ":c/1)"), page2)
	uassert.True(t, strings.Contains(Render("?page=999"), "page 2 of 2"), "clamped")

	// Names are user input: markdown in them must not render.
	uassert.False(t, strings.Contains(home, "circle *a*"), home)

	uassert.True(t, strings.Contains(Render("u/"+ayse.String()), ":c/12)"), "organizer index")
	uassert.True(t, strings.Contains(Render("u/"+mehmet.String()), "Not in any circle yet"), "invite is not consent")
	for _, bad := range []string{"c/0", "c/x", "c/13", "u/nope", "zzz"} {
		uassert.True(t, strings.Contains(Render(bad), "# Not found"), bad)
	}
	c1 := Render("c/1")
	uassert.True(t, strings.Contains(c1, "$help&func=Join&id=1&.send=1000000ugnot"), c1)
	uassert.True(t, strings.Contains(c1, "Covers 1 missed payments per member"), c1)
}

func TestGnotFormat(t *testing.T) {
	uassert.Equal(t, "0 GNOT", gnot(0))
	uassert.Equal(t, "1 GNOT", gnot(1_000_000))
	uassert.Equal(t, "1.5 GNOT", gnot(1_500_000))
	uassert.Equal(t, "0.000001 GNOT", gnot(1))
	uassert.Equal(t, "-2.25 GNOT", gnot(-2_250_000))
}
