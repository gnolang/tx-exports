package gnocial

import (
	"chain"
	"chain/banker"
	"strconv"
	"strings"
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
	"gno.land/p/nt/urequire/v0"
)

func resetArena() {
	state = newStore()
	state.admin = testutils.TestAddress("admin")
	state.treasury = testutils.TestAddress("treasury")
}

func ugnots(n int64) chain.Coins {
	if n == 0 {
		return nil
	}
	return chain.Coins{chain.NewCoin("ugnot", n)}
}

func bal(a address) int64 {
	return banker.NewReadonlyBanker().GetCoins(a).AmountOf("ugnot")
}

func mustAbort(t *testing.T, rlm realm, msg string, fn func()) {
	if !uassert.AbortsWithMessage(t, rlm, msg, fn) {
		t.FailNow()
	}
}

func TestCurveMath(t *testing.T) {
	urequire.Equal(t, int64(1), sumSq(1))
	urequire.Equal(t, int64(5), sumSq(2))
	urequire.Equal(t, int64(14), sumSq(3))
	var want int64
	for i := int64(1); i <= 40; i++ {
		want += i * i
		urequire.Equal(t, want, sumSq(i))
	}
	urequire.Equal(t, int64(10_000), curveCost(0, 1))
	urequire.Equal(t, int64(50_000), curveCost(0, 2))
	urequire.Equal(t, int64(40_000), curveCost(1, 1))
	urequire.Equal(t, int64(140_000), curveCost(0, 3))
}

func TestSocial(cur realm, t *testing.T) {
	resetArena()
	alice := testutils.TestAddress("alice")
	bob := testutils.TestAddress("bob")

	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	mustAbort(t, cur, "bad handle", func() {
		Register(cross(cur), "ab", "", "", "")
	})
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	mustAbort(t, cur, "bad handle", func() {
		Register(cross(cur), "admin", "", "", "")
	})
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	mustAbort(t, cur, "bad handle", func() {
		Register(cross(cur), "gnocial", "", "", "")
	})
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(ugnots(1))
	mustAbort(t, cur, "this call takes no payment", func() {
		Register(cross(cur), "alice", "", "", "")
	})

	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	Register(cross(cur), "alice", "Alice", "xin chao", "")

	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	mustAbort(t, cur, "already registered", func() {
		Register(cross(cur), "alice2", "", "", "")
	})
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(nil)
	mustAbort(t, cur, "self referral", func() {
		Register(cross(cur), "bob", "", "", bob.String())
	})

	_, ok := ProfileOf(bob)
	urequire.Equal(t, false, ok)

	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(nil)
	Register(cross(cur), "bob", "", "", alice.String())

	testing.SetRealm(testing.NewUserRealm(testutils.TestAddress("carol")))
	testing.SetOriginSend(nil)
	mustAbort(t, cur, "handle taken", func() {
		Register(cross(cur), "alice", "", "", "")
	})

	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	id := Post(cross(cur), "chao-arena", "")

	got, ok := GetPost(id)
	urequire.Equal(t, true, ok)
	got.Body = "mutated"
	again, _ := GetPost(id)
	urequire.Equal(t, "chao-arena", again.Body)

	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(nil)
	Like(cross(cur), id)
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(nil)
	mustAbort(t, cur, "already liked", func() {
		Like(cross(cur), id)
	})
	Follow(cross(cur), "alice")
	replyID := Reply(cross(cur), id, "tra loi")

	aliceP, _ := ProfileByHandle("alice")
	urequire.Equal(t, 1, aliceP.Followers)
	urequire.Equal(t, 1, aliceP.Posts)
	bobP, _ := ProfileByHandle("bob")
	urequire.Equal(t, 1, bobP.Following)
	post, _ := GetPost(id)
	urequire.Equal(t, 1, post.Likes)
	urequire.Equal(t, 1, post.Replies)
	urequire.Equal(t, true, Following(bob, "alice"))

	feed := Feed(0, 8)
	urequire.Equal(t, "chao-arena", feed[0].Body)
	urequire.Equal(t, false, strings.Contains(Render(""), "chao-arena"))

	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(nil)
	Unlike(cross(cur), id)
	Unfollow(cross(cur), "alice")
	post, _ = GetPost(id)
	urequire.Equal(t, 0, post.Likes)
	aliceP, _ = ProfileByHandle("alice")
	urequire.Equal(t, 0, aliceP.Followers)

	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	Delete(cross(cur), id)
	post, _ = GetPost(id)
	urequire.Equal(t, true, post.Deleted)
	urequire.Equal(t, "", post.Body)
	urequire.Equal(t, false, strings.Contains(Render(""), "chao-arena"))
	reply, ok := GetPost(replyID)
	urequire.Equal(t, true, ok)
	urequire.Equal(t, "tra loi", reply.Body)

	urequire.Equal(t, true, strings.Contains(Render(""), "Gnocial"))
}

func TestGatedBody(cur realm, t *testing.T) {
	resetArena()
	realmAddr := cur.Address()
	alice := testutils.TestAddress("alice")
	bob := testutils.TestAddress("bob")
	const secret = "bi-mat-ve-99"

	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	Register(cross(cur), "alice", "", "", "")
	id := Post(cross(cur), secret, "yes")

	urequire.Equal(t, false, strings.Contains(Render(""), secret))
	urequire.Equal(t, false, strings.Contains(Render("p/"+strconv.Itoa(id)), secret))

	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(nil)
	Register(cross(cur), "bob", "", "", "")
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(nil)
	mustAbort(t, cur, "need a ticket", func() {
		GatedBody(cross(cur), id)
	})

	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	urequire.Equal(t, secret, GatedBody(cross(cur), id))

	due, _, _, _, _ := QuoteBuy("alice", 1)
	testing.IssueCoins(realmAddr, ugnots(due))
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(ugnots(due))
	Buy(cross(cur), "alice", 1)
	testing.SetOriginSend(nil)
	urequire.Equal(t, secret, GatedBody(cross(cur), id))

	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(nil)
	Sell(cross(cur), "alice", 1)
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(nil)
	mustAbort(t, cur, "need a ticket", func() {
		GatedBody(cross(cur), id)
	})
}

func TestTicketRoundTrip(cur realm, t *testing.T) {
	resetArena()
	realmAddr := cur.Address()
	alice := testutils.TestAddress("alice")
	bob := testutils.TestAddress("bob")
	carol := testutils.TestAddress("carol")
	treasury := testutils.TestAddress("treasury")

	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	Register(cross(cur), "alice", "", "", "")
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(nil)
	Register(cross(cur), "bob", "", "", alice.String())
	testing.SetRealm(testing.NewUserRealm(carol))
	testing.SetOriginSend(nil)
	Register(cross(cur), "carol", "", "", "")

	dueA, curveA, _, _, refA := QuoteBuy("alice", 1)
	urequire.Equal(t, int64(10_000), curveA)
	urequire.Equal(t, int64(0), refA)
	urequire.Equal(t, int64(11_000), dueA)

	due, curve, creatorFee, protocolFee, referralFee := QuoteBuy("bob", 1)
	urequire.Equal(t, int64(10_000), curve)
	urequire.Equal(t, int64(500), creatorFee)
	urequire.Equal(t, int64(450), protocolFee)
	urequire.Equal(t, int64(50), referralFee)
	urequire.Equal(t, int64(11_000), due)

	startRealm := bal(realmAddr)
	startAlice := bal(alice)
	startBob := bal(bob)
	startTreasury := bal(treasury)

	testing.IssueCoins(realmAddr, ugnots(due))
	testing.SetRealm(testing.NewUserRealm(carol))
	testing.SetOriginSend(ugnots(due))
	Buy(cross(cur), "bob", 1)

	urequire.Equal(t, 1, SharesOf(carol, "bob"))
	supply, reserve, holders := SupplyOf("bob")
	urequire.Equal(t, 1, supply)
	urequire.Equal(t, int64(10_000), reserve)
	urequire.Equal(t, 1, holders)
	urequire.Equal(t, int64(10_000), TotalReserve())
	urequire.Equal(t, startAlice+50, bal(alice))
	urequire.Equal(t, startBob+500, bal(bob))
	urequire.Equal(t, startTreasury+450, bal(treasury))
	urequire.Equal(t, startRealm+10_000, bal(realmAddr))

	proceeds, _, _, _, _ := QuoteSell("bob", 1)
	urequire.Equal(t, int64(9_000), proceeds)
	startCarol := bal(carol)
	testing.SetRealm(testing.NewUserRealm(carol))
	testing.SetOriginSend(nil)
	Sell(cross(cur), "bob", 1)

	urequire.Equal(t, 0, SharesOf(carol, "bob"))
	supply, reserve, holders = SupplyOf("bob")
	urequire.Equal(t, 0, supply)
	urequire.Equal(t, int64(0), reserve)
	urequire.Equal(t, 0, holders)
	urequire.Equal(t, int64(0), TotalReserve())
	urequire.Equal(t, startCarol+proceeds, bal(carol))
	urequire.Equal(t, startAlice+100, bal(alice))
	urequire.Equal(t, startBob+1_000, bal(bob))
	urequire.Equal(t, startTreasury+900, bal(treasury))
	urequire.Equal(t, startRealm, bal(realmAddr))

	testing.SetRealm(testing.NewUserRealm(carol))
	testing.SetOriginSend(nil)
	mustAbort(t, cur, "not enough tickets", func() {
		Sell(cross(cur), "bob", 1)
	})
}

func TestTipForwards(cur realm, t *testing.T) {
	resetArena()
	realmAddr := cur.Address()
	alice := testutils.TestAddress("alice")
	bob := testutils.TestAddress("bob")

	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	Register(cross(cur), "alice", "", "", "")
	id := Post(cross(cur), "tip me", "")
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(nil)
	Register(cross(cur), "bob", "", "", "")

	startRealm := bal(realmAddr)
	startAlice := bal(alice)
	testing.IssueCoins(realmAddr, ugnots(25_000))
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(ugnots(25_000))
	Tip(cross(cur), id)

	urequire.Equal(t, startRealm, bal(realmAddr))
	urequire.Equal(t, startAlice+25_000, bal(alice))
	post, _ := GetPost(id)
	urequire.Equal(t, int64(25_000), post.Tips)
	aliceP, _ := ProfileByHandle("alice")
	urequire.Equal(t, int64(25_000), aliceP.TipsIn)
	bobP, _ := ProfileByHandle("bob")
	urequire.Equal(t, int64(25_000), bobP.TipsOut)
}

func TestPaymentGuards(cur realm, t *testing.T) {
	resetArena()
	alice := testutils.TestAddress("alice")
	bob := testutils.TestAddress("bob")

	testing.SetRealm(testing.NewCodeRealm("gno.land/r/evil/proxy"))
	testing.SetOriginSend(ugnots(11_000))
	mustAbort(t, cur, "direct user call only", func() {
		Buy(cross(cur), "alice", 1)
	})

	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	Register(cross(cur), "alice", "", "", "")
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(nil)
	Register(cross(cur), "bob", "", "", "")

	due, _, _, _, _ := QuoteBuy("alice", 1)
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(ugnots(1))
	mustAbort(t, cur, "send exactly "+strconv.FormatInt(due, 10)+"ugnot", func() {
		Buy(cross(cur), "alice", 1)
	})
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(chain.Coins{chain.NewCoin("atom", due)})
	mustAbort(t, cur, "send ugnot only", func() {
		Buy(cross(cur), "alice", 1)
	})
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(chain.Coins{
		chain.NewCoin("atom", 1),
		chain.NewCoin("ugnot", due),
	})
	mustAbort(t, cur, "send ugnot only", func() {
		Buy(cross(cur), "alice", 1)
	})

	// A rejected buy must not mint tickets.
	urequire.Equal(t, 0, SharesOf(bob, "alice"))
	urequire.Equal(t, int64(0), TotalReserve())
}

func TestPauseStillSells(cur realm, t *testing.T) {
	resetArena()
	realmAddr := cur.Address()
	alice := testutils.TestAddress("alice")
	bob := testutils.TestAddress("bob")
	admin := testutils.TestAddress("admin")

	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	Register(cross(cur), "alice", "", "", "")
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(nil)
	Register(cross(cur), "bob", "", "", "")

	due, _, _, _, _ := QuoteBuy("alice", 1)
	testing.IssueCoins(realmAddr, ugnots(due))
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(ugnots(due))
	Buy(cross(cur), "alice", 1)

	testing.SetRealm(testing.NewUserRealm(admin))
	testing.SetOriginSend(nil)
	SetPaused(cross(cur), "yes")
	urequire.Equal(t, true, Paused())

	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	mustAbort(t, cur, "paused", func() {
		Post(cross(cur), "nope", "")
	})
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(ugnots(due))
	mustAbort(t, cur, "paused", func() {
		Buy(cross(cur), "alice", 1)
	})

	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(nil)
	Sell(cross(cur), "alice", 1)
	urequire.Equal(t, 0, SharesOf(bob, "alice"))
	urequire.Equal(t, int64(0), TotalReserve())
}

func TestSweepKeepsReserve(cur realm, t *testing.T) {
	resetArena()
	realmAddr := cur.Address()
	alice := testutils.TestAddress("alice")
	bob := testutils.TestAddress("bob")
	admin := testutils.TestAddress("admin")
	treasury := testutils.TestAddress("treasury")

	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	Register(cross(cur), "alice", "", "", "")
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(nil)
	Register(cross(cur), "bob", "", "", "")

	due, _, _, _, _ := QuoteBuy("alice", 1)
	testing.IssueCoins(realmAddr, ugnots(due))
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(ugnots(due))
	Buy(cross(cur), "alice", 1)
	urequire.Equal(t, int64(10_000), TotalReserve())

	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(nil)
	mustAbort(t, cur, "admin only", func() {
		Sweep(cross(cur), "sweep")
	})
	testing.SetRealm(testing.NewUserRealm(admin))
	testing.SetOriginSend(nil)
	mustAbort(t, cur, "confirm sweep", func() {
		Sweep(cross(cur), "please")
	})

	testing.IssueCoins(realmAddr, ugnots(77))
	beforeT := bal(treasury)
	surplus := bal(realmAddr) - TotalReserve()
	testing.SetRealm(testing.NewUserRealm(admin))
	testing.SetOriginSend(nil)
	Sweep(cross(cur), "sweep")
	urequire.Equal(t, TotalReserve(), bal(realmAddr))
	urequire.Equal(t, beforeT+surplus, bal(treasury))
	urequire.Equal(t, int64(10_000), TotalReserve())
	supply, reserve, _ := SupplyOf("alice")
	urequire.Equal(t, 1, supply)
	urequire.Equal(t, int64(10_000), reserve)
}

func TestCreatorFeeSchedule(cur realm, t *testing.T) {
	resetArena()
	realmAddr := cur.Address()
	alice := testutils.TestAddress("alice")
	bob := testutils.TestAddress("bob")
	carol := testutils.TestAddress("carol")
	dave := testutils.TestAddress("dave")
	eve := testutils.TestAddress("eve")
	treasury := testutils.TestAddress("treasury")

	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	Register(cross(cur), "alice", "", "", "")
	aliceP, _ := ProfileByHandle("alice")
	urequire.Equal(t, CreatorFeeDefaultBps, aliceP.CreatorFee)

	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(nil)
	Register(cross(cur), "bob", "", "", alice.String())
	testing.SetRealm(testing.NewUserRealm(carol))
	testing.SetOriginSend(nil)
	Register(cross(cur), "carol", "", "", "")
	testing.SetRealm(testing.NewUserRealm(dave))
	testing.SetOriginSend(nil)
	Register(cross(cur), "dave", "", "", alice.String())

	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	SetCreatorFee(cross(cur), 100)
	dueAlice, _, cf, pf, rf := QuoteBuy("alice", 1)
	urequire.Equal(t, int64(11_000), dueAlice)
	urequire.Equal(t, int64(100), cf)
	urequire.Equal(t, int64(900), pf)
	urequire.Equal(t, int64(0), rf)

	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	SetCreatorFee(cross(cur), 700)
	_, _, cf, pf, rf = QuoteBuy("alice", 1)
	urequire.Equal(t, int64(700), cf)
	urequire.Equal(t, int64(300), pf)
	urequire.Equal(t, int64(0), rf)

	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	mustAbort(t, cur, "fee", func() {
		SetCreatorFee(cross(cur), 99)
	})
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	mustAbort(t, cur, "fee", func() {
		SetCreatorFee(cross(cur), 701)
	})
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(ugnots(1))
	mustAbort(t, cur, "this call takes no payment", func() {
		SetCreatorFee(cross(cur), 500)
	})
	testing.SetRealm(testing.NewUserRealm(eve))
	testing.SetOriginSend(nil)
	mustAbort(t, cur, "register first", func() {
		SetCreatorFee(cross(cur), 500)
	})

	testing.SetRealm(testing.NewUserRealm(carol))
	testing.SetOriginSend(nil)
	SetCreatorFee(cross(cur), 100)
	bobP, _ := ProfileByHandle("bob")
	urequire.Equal(t, int64(500), bobP.CreatorFee)
	carolP, _ := ProfileByHandle("carol")
	urequire.Equal(t, int64(100), carolP.CreatorFee)

	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(nil)
	SetCreatorFee(cross(cur), 700)
	due, curve, cf, pf, rf := QuoteBuyFor("bob", dave.String(), 1)
	urequire.Equal(t, int64(10_000), curve)
	urequire.Equal(t, int64(11_000), due)
	urequire.Equal(t, int64(700), cf)
	urequire.Equal(t, int64(200), pf)
	urequire.Equal(t, int64(100), rf)
	same, _, _, _, _ := QuoteBuy("bob", 1)
	urequire.Equal(t, due, same)
	_, _, _, pf, rf = QuoteBuyFor("bob", eve.String(), 1)
	urequire.Equal(t, int64(250), pf)
	urequire.Equal(t, int64(50), rf)
	if !uassert.PanicsWithMessage(t, cur, "bad address", func() {
		QuoteBuyFor("bob", "not-an-address", 1)
	}) {
		t.FailNow()
	}

	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(nil)
	SetCreatorFee(cross(cur), 500)
	due, _, cf, pf, rf = QuoteBuyFor("bob", dave.String(), 1)
	urequire.Equal(t, int64(500), cf)
	urequire.Equal(t, int64(400), pf)
	urequire.Equal(t, int64(100), rf)

	startRealm := bal(realmAddr)
	startAlice := bal(alice)
	startBob := bal(bob)
	startTreasury := bal(treasury)
	testing.IssueCoins(realmAddr, ugnots(due))
	testing.SetRealm(testing.NewUserRealm(dave))
	testing.SetOriginSend(ugnots(due))
	Buy(cross(cur), "bob", 1)
	urequire.Equal(t, startAlice+100, bal(alice))
	urequire.Equal(t, startBob+500, bal(bob))
	urequire.Equal(t, startTreasury+400, bal(treasury))
	urequire.Equal(t, startRealm+10_000, bal(realmAddr))

	proceeds, _, _, _, _ := QuoteSellFor("bob", dave.String(), 1)
	urequire.Equal(t, int64(9_000), proceeds)
	testing.SetRealm(testing.NewUserRealm(dave))
	testing.SetOriginSend(nil)
	Sell(cross(cur), "bob", 1)
	urequire.Equal(t, startAlice+200, bal(alice))
	urequire.Equal(t, startBob+1_000, bal(bob))
	urequire.Equal(t, startTreasury+800, bal(treasury))
	urequire.Equal(t, startRealm, bal(realmAddr))
	urequire.Equal(t, int64(0), TotalReserve())
}
