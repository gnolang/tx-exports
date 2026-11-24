package tankardtales

import (
	"chain"
	"chain/banker"
	"strconv"
	"testing"

	"gno.land/p/nt/uassert/v0"
)

const pkgPath = "gno.land/r/nym-kaycee042/tankardtales"

// fundRealm gives the realm's own account a working balance, the way a
// real deployment accumulates escrowed tips.
func fundRealm(cur realm, amount int64) {
	realmAddr := chain.PackageAddress(pkgPath)
	testing.IssueCoins(realmAddr, chain.NewCoins(chain.NewCoin("ugnot", amount)))
}

func ugnotBalance(cur realm, addr address) int64 {
	banker_ := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	return banker_.GetCoin(addr, "ugnot")
}

func TestQuestLifecycle(cur realm, t *testing.T) {
	fundRealm(cur, 1_000_000)
	escrowBefore := EscrowUgnot()
	_, bobDone0, bobTips0, _, _ := GetRegular(bob)
	alicePosted0, _, _, _, _ := GetRegular(alice)

	// Alice posts; the internal helper stands in for the payment-checked
	// public entry point (covered separately in TestPostQuestPayment).
	id := postQuest(alice, "Slay the spam bots", "Clear the tavern noticeboard of spam.", 5000)
	idStr := strconv.Itoa(id)

	poster, title, _, tip, status, _, ok := GetQuest(idStr)
	uassert.Equal(t, ok, true)
	uassert.Equal(t, poster, alice)
	uassert.Equal(t, title, "Slay the spam bots")
	uassert.Equal(t, tip, int64(5000))
	uassert.Equal(t, status, StatusOpen)
	uassert.Equal(t, EscrowUgnot(), escrowBefore+5000)

	// Bob claims it.
	testing.SetRealm(testing.NewUserRealm(bob))
	ClaimQuest(cross(cur), idStr)
	_, _, _, _, status, claimer, _ := GetQuest(idStr)
	uassert.Equal(t, status, StatusClaimed)
	uassert.Equal(t, claimer, bob)

	// Alice confirms the work; the tip moves to Bob.
	bobBefore := ugnotBalance(cur, bob)
	testing.SetRealm(testing.NewUserRealm(alice))
	CompleteQuest(cross(cur), idStr)

	_, _, _, _, status, _, _ = GetQuest(idStr)
	uassert.Equal(t, status, StatusCompleted)
	uassert.Equal(t, EscrowUgnot(), escrowBefore)
	uassert.Equal(t, ugnotBalance(cur, bob), bobBefore+5000)

	// Bob's regulars tally tells the story (delta-based: other tests
	// in the package may share realm state within one run).
	_, done, tipsEarned, _, ok := GetRegular(bob)
	uassert.Equal(t, ok, true)
	uassert.Equal(t, done, bobDone0+1)
	uassert.Equal(t, tipsEarned, bobTips0+5000)

	// And Alice is recorded as the poster.
	posted, _, _, _, _ := GetRegular(alice)
	uassert.Equal(t, posted, alicePosted0+1)
}

func TestClaimRules(cur realm, t *testing.T) {
	idStr := strconv.Itoa(postQuest(carol, "Tune the tavern lute", "It has been flat since spring.", 2000))

	// The poster cannot claim their own quest.
	testing.SetRealm(testing.NewUserRealm(carol))
	expectPanic(t, cur, "you cannot claim your own quest", func() {
		ClaimQuest(cross(cur), idStr)
	})

	// Dave claims; now nobody else can.
	testing.SetRealm(testing.NewUserRealm(dave))
	ClaimQuest(cross(cur), idStr)
	testing.SetRealm(testing.NewUserRealm(bob))
	expectPanic(t, cur, "not open for claiming", func() {
		ClaimQuest(cross(cur), idStr)
	})

	// Claiming a quest that does not exist panics too.
	expectPanic(t, cur, "no quest with id", func() {
		ClaimQuest(cross(cur), "999999")
	})
}

func TestAbandonAndReclaim(cur realm, t *testing.T) {
	idStr := strconv.Itoa(postQuest(alice, "Polish the tankards", "All forty of them. To a shine.", 3000))

	testing.SetRealm(testing.NewUserRealm(bob))
	ClaimQuest(cross(cur), idStr)

	// Only the claimer may abandon.
	testing.SetRealm(testing.NewUserRealm(carol))
	expectPanic(t, cur, "only the claimer can abandon this quest", func() {
		AbandonQuest(cross(cur), idStr)
	})

	testing.SetRealm(testing.NewUserRealm(bob))
	AbandonQuest(cross(cur), idStr)
	_, _, _, _, status, claimer, _ := GetQuest(idStr)
	uassert.Equal(t, status, StatusOpen)
	uassert.Equal(t, claimer, address(""))

	// Someone else can pick it up afterwards.
	testing.SetRealm(testing.NewUserRealm(carol))
	ClaimQuest(cross(cur), idStr)
	_, _, _, _, status, claimer, _ = GetQuest(idStr)
	uassert.Equal(t, status, StatusClaimed)
	uassert.Equal(t, claimer, carol)
}

func TestCompleteRules(cur realm, t *testing.T) {
	idStr := strconv.Itoa(postQuest(alice, "Mend the tavern roof", "It leaks into the ale.", 4000))

	// An unclaimed quest cannot be completed.
	testing.SetRealm(testing.NewUserRealm(alice))
	expectPanic(t, cur, "not claimed, so it cannot be completed", func() {
		CompleteQuest(cross(cur), idStr)
	})

	testing.SetRealm(testing.NewUserRealm(bob))
	ClaimQuest(cross(cur), idStr)

	// Only the poster can complete it.
	testing.SetRealm(testing.NewUserRealm(carol))
	expectPanic(t, cur, "only the poster can complete this quest", func() {
		CompleteQuest(cross(cur), idStr)
	})
}

func TestCancelQuestRefunds(cur realm, t *testing.T) {
	fundRealm(cur, 1_000_000)
	escrowBefore := EscrowUgnot()

	idStr := strconv.Itoa(postQuest(carol, "Sweep the cellar", "Mind the barrels.", 6000))
	uassert.Equal(t, EscrowUgnot(), escrowBefore+6000)

	// A claimed quest cannot be cancelled from under its adventurer.
	testing.SetRealm(testing.NewUserRealm(dave))
	ClaimQuest(cross(cur), idStr)
	testing.SetRealm(testing.NewUserRealm(carol))
	expectPanic(t, cur, "only an open (unclaimed) quest can be cancelled", func() {
		CancelQuest(cross(cur), idStr)
	})

	// Dave abandons; now Carol can cancel and gets her tip back.
	testing.SetRealm(testing.NewUserRealm(dave))
	AbandonQuest(cross(cur), idStr)

	carolBefore := ugnotBalance(cur, carol)
	testing.SetRealm(testing.NewUserRealm(carol))
	CancelQuest(cross(cur), idStr)

	_, _, _, _, status, _, _ := GetQuest(idStr)
	uassert.Equal(t, status, StatusCancelled)
	uassert.Equal(t, EscrowUgnot(), escrowBefore)
	uassert.Equal(t, ugnotBalance(cur, carol), carolBefore+6000)
}

func TestPostQuestPayment(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(dave))
	escrowBefore := EscrowUgnot()

	// Exact tip attached: quest lands on the board.
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin("ugnot", 7000)))
	idStr := PostQuest(cross(cur), "Fetch the golden tankard", "It is in the cellar. Mind the gnome.", 7000)
	poster, _, _, tip, status, _, ok := GetQuest(idStr)
	uassert.Equal(t, ok, true)
	uassert.Equal(t, poster, dave)
	uassert.Equal(t, tip, int64(7000))
	uassert.Equal(t, status, StatusOpen)
	uassert.Equal(t, EscrowUgnot(), escrowBefore+7000)

	// Sending less than the declared tip is rejected.
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin("ugnot", 1)))
	expectPanic(t, cur, "send exactly the tip amount in ugnot", func() {
		PostQuest(cross(cur), "A dubious quest", "Perfectly normal details.", 7000)
	})

	// A tip under the minimum is rejected even if the send matches.
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin("ugnot", 10)))
	expectPanic(t, cur, "tip is below the minimum", func() {
		PostQuest(cross(cur), "A cheap quest", "Perfectly normal details.", 10)
	})

	// Nothing extra reached the board or the escrow.
	uassert.Equal(t, EscrowUgnot(), escrowBefore+7000)
}
