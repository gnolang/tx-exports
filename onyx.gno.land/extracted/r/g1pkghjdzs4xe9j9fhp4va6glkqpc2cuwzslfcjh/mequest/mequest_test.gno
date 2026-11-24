package mequest

import (
	"chain"
	"chain/banker"
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
	"gno.land/p/nt/urequire/v0"
)

var (
	alice = testutils.TestAddress("alice") // rich quester
	bob   = testutils.TestAddress("bob")   // broke quester
	proj  = testutils.TestAddress("proj")  // project
	self  = chain.PackageAddress("gno.land/r/g1pkghjdzs4xe9j9fhp4va6glkqpc2cuwzslfcjh/mequest")
)

// SetRealm only sticks in the calling frame, so tests call it inline.
func as(who address, ugnot int64) {
	testing.SetOriginCaller(who)
	if ugnot > 0 {
		testing.SetOriginSend(chain.Coins{{"ugnot", ugnot}})
		testing.IssueCoins(self, chain.Coins{{"ugnot", ugnot}}) // coins land in the realm
	} else {
		testing.SetOriginSend(nil)
	}
}

func bal(a address) int64 { return banker.NewReadonlyBanker().GetCoin(a, "ugnot") }

func TestFlow(cur realm, t *testing.T) {
	testing.IssueCoins(alice, chain.Coins{{"ugnot", 5_000_000}})

	// project locks 2 GNOT for 2 winners (1 GNOT each), hold-check quest
	testing.SetRealm(testing.NewUserRealm(proj))
	as(proj, 2_000_000)
	var id int
	urequire.NotPanics(t, cur, func() {
		id = CreateQuest(cross(cur), "Hold 1 GNOT", "Prove you hold GNOT", "wallet", Common, KindHold, "1000000", PayFixed, 2, 7)
	})
	uassert.Equal(t, 1, id)

	// common project cannot create Epic
	testing.SetRealm(testing.NewUserRealm(proj))
	as(proj, 1_000_000)
	uassert.AbortsContains(t, cur, "approved projects", func() {
		CreateQuest(cross(cur), "x", "", "wallet", Epic, KindManual, "", PayFixed, 1, 7)
	})

	// alice passes the check and is paid instantly
	testing.SetRealm(testing.NewUserRealm(alice))
	as(alice, 0)
	urequire.NotPanics(t, cur, func() { Claim(cross(cur), 1) })
	uassert.Equal(t, int64(6_000_000), bal(alice))
	uassert.True(t, HasCard(alice, 1))
	uassert.Equal(t, int64(10), PointsOf(alice))
	uassert.Equal(t, Common, BestRarity(alice))

	// double claim blocked
	uassert.AbortsContains(t, cur, "already claimed", func() { Claim(cross(cur), 1) })

	// bob fails the check
	testing.SetRealm(testing.NewUserRealm(bob))
	as(bob, 0)
	uassert.AbortsContains(t, cur, "check failed", func() { Claim(cross(cur), 1) })

	// refund is locked until expiry
	testing.SetRealm(testing.NewUserRealm(proj))
	as(proj, 0)
	uassert.AbortsContains(t, cur, "locked", func() { Refund(cross(cur), 1) })

	// manual quest: submit -> funder approves -> paid
	testing.SetRealm(testing.NewUserRealm(proj))
	as(proj, 3_000_000)
	CreateQuest(cross(cur), "Post on X", "Share your passport", "wallet", Common, KindManual, "", PayFixed, 3, 7)
	testing.SetRealm(testing.NewUserRealm(bob))
	as(bob, 0)
	urequire.NotPanics(t, cur, func() { Submit(cross(cur), 2, "https://x.com/bob/status/1") })
	testing.SetRealm(testing.NewUserRealm(alice))
	as(alice, 0)
	uassert.AbortsContains(t, cur, "funder", func() { Review(cross(cur), 2, bob, true) })
	testing.SetRealm(testing.NewUserRealm(proj))
	as(proj, 0)
	urequire.NotPanics(t, cur, func() { Review(cross(cur), 2, bob, true) })
	uassert.Equal(t, int64(1_000_000), bal(bob))

	// legendary needs approval + an Epic first
	testing.SetRealm(testing.NewUserRealm(admin))
	as(admin, 0)
	ApproveProject(cross(cur), proj, true)
	testing.SetRealm(testing.NewUserRealm(proj))
	as(proj, 10_000_000)
	CreateQuest(cross(cur), "Legend", "", "wallet", Legendary, KindManual, "", PaySplit, 10, 1)
	testing.SetRealm(testing.NewUserRealm(alice))
	as(alice, 0)
	Submit(cross(cur), 3, "proof")
	testing.SetRealm(testing.NewUserRealm(proj))
	as(proj, 0)
	uassert.AbortsContains(t, cur, "Epic card first", func() { Review(cross(cur), 3, alice, true) })

	// quest chain: needs card from quest 1 (alice has it, bob doesn't)
	testing.SetRealm(testing.NewUserRealm(proj))
	as(proj, 2_000_000)
	CreateQuest(cross(cur), "Chain step 2", "", "wallet", Rare, KindCard, "1", PayFixed, 2, 7)
	testing.SetRealm(testing.NewUserRealm(bob))
	as(bob, 0)
	uassert.AbortsContains(t, cur, "quest #1 first", func() { Claim(cross(cur), 4) })
	testing.SetRealm(testing.NewUserRealm(alice))
	as(alice, 0)
	urequire.NotPanics(t, cur, func() { Claim(cross(cur), 4) })
	uassert.True(t, HasRarity(alice, Rare))

	// username check
	testing.SetRealm(testing.NewUserRealm(proj))
	as(proj, 1_000_000)
	CreateQuest(cross(cur), "Get a name", "", "wallet", Common, KindName, "", PayFixed, 1, 7)
	testing.SetRealm(testing.NewUserRealm(bob))
	as(bob, 0)
	uassert.AbortsContains(t, cur, "username", func() { Claim(cross(cur), 5) })

	// after expiry: refund leftover of quest 1, settle split quest 3
	testing.SkipHeights(200_000) // ~11 days of blocks
	testing.SetRealm(testing.NewUserRealm(bob))
	as(bob, 0)
	uassert.AbortsContains(t, cur, "expired", func() { Claim(cross(cur), 1) })
	before := bal(proj)
	testing.SetRealm(testing.NewUserRealm(proj))
	as(proj, 0)
	urequire.NotPanics(t, cur, func() { Refund(cross(cur), 1) })
	uassert.Equal(t, before+1_000_000, bal(proj))
	urequire.NotPanics(t, cur, func() { Settle(cross(cur), 3) })
	uassert.Equal(t, before+11_000_000, bal(proj)) // no winners: whole split pool back

	// pages render
	uassert.True(t, len(Render("")) > 0)
	uassert.True(t, len(Render("q/1")) > 0)
	uassert.True(t, len(Render("p/"+string(alice))) > 0)
	uassert.True(t, len(Render("top")) > 0)
	for _, path := range []string{"api/stats", "api/quests", "api/q/2", "api/p/" + string(alice), "api/top", "api/feed", "api/projects", "api/receipts"} {
		println("JSON " + Render(path))
	}
}

func TestFormat(t *testing.T) {
	uassert.Equal(t, "2.5 GNOT", gnot(2_500_000))
	uassert.Equal(t, "3 GNOT", gnot(3_000_000))
}
