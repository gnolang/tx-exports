package questboard

import (
	"chain"
	"chain/banker"
	"strings"
	"testing"
	"time"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
	"gno.land/p/nt/urequire/v0"
)

var (
	realmAddr = chain.PackageAddress("gno.land/r/g1klfptn25xf37smf27vqr4g6qlmtwc0lz6y5mcj/questboard")
	alice     = testutils.TestAddress("alice") // poster
	bob       = testutils.TestAddress("bob")   // hunter
	carol     = testutils.TestAddress("carol") // hunter
	dave      = testutils.TestAddress("dave")  // backer
)

func reset() {
	quests = avl.Tree{}
	profiles = avl.Tree{}
	lastID = 0
	totalPaid = 0
	totalEscrow = 0
	paidHunters = 0
	settledCount = 0
}

// attach sets the ugnot sent with the next call and issues the coins to the
// realm, mirroring what the chain does with -send. testing.SetRealm must be
// called in the test function itself: it only applies to the calling frame.
func withSend(ugnot int64) {
	if ugnot > 0 {
		testing.SetOriginSend(chain.Coins{{"ugnot", ugnot}})
		testing.IssueCoins(realmAddr, chain.Coins{{"ugnot", ugnot}})
	} else {
		testing.SetOriginSend(nil)
	}
}

func balance(addr address) int64 {
	return banker.NewReadonlyBanker().GetCoin(addr, "ugnot")
}

func TestPostSubmitAward(cur realm, t *testing.T) {
	reset()

	testing.SetRealm(testing.NewUserRealm(alice))
	withSend(5_000_000)
	id := PostQuest(cross(cur), "Write a GRC20 airdrop script", "Script plus README.", 7)
	uassert.Equal(t, 1, id)

	testing.SetRealm(testing.NewUserRealm(bob))
	withSend(0)
	Submit(cross(cur), id, "https://github.com/bob/airdrop")
	testing.SetRealm(testing.NewUserRealm(carol))
	withSend(0)
	Submit(cross(cur), id, "my take: gist link soon")

	bobBefore := balance(bob)
	carolBefore := balance(carol)

	testing.SetRealm(testing.NewUserRealm(alice))
	withSend(0)
	Award(cross(cur), id, bob, 3_000_000, "great work")
	status, remaining, _ := QuestStatus(id)
	uassert.Equal(t, "open", status)
	uassert.Equal(t, int64(2_000_000), remaining)

	Award(cross(cur), id, carol, 2_000_000, "")
	status, remaining, _ = QuestStatus(id)
	uassert.Equal(t, "completed", status)
	uassert.Equal(t, int64(0), remaining)

	uassert.Equal(t, bobBefore+3_000_000, balance(bob))
	uassert.Equal(t, carolBefore+2_000_000, balance(carol))

	wins, earned := HunterStats(bob)
	uassert.Equal(t, 1, wins)
	uassert.Equal(t, int64(3_000_000), earned)
	posted, completed, expired := PosterStats(alice)
	uassert.Equal(t, 1, posted)
	uassert.Equal(t, 1, completed)
	uassert.Equal(t, 0, expired)

	escrow, paid, hunters := Totals()
	uassert.Equal(t, int64(0), escrow)
	uassert.Equal(t, int64(5_000_000), paid)
	uassert.Equal(t, 2, hunters)
}

func TestGuards(cur realm, t *testing.T) {
	reset()

	testing.SetRealm(testing.NewUserRealm(alice))
	withSend(50_000)
	uassert.AbortsWithMessage(t, cur, "send at least 0.1 GNOT as the reward", func() {
		PostQuest(cross(cur), "Too cheap", "", 3)
	})

	testing.SetRealm(testing.NewUserRealm(alice))
	withSend(1_000_000)
	uassert.AbortsWithMessage(t, cur, "title is required", func() {
		PostQuest(cross(cur), "  ", "", 3)
	})
	uassert.AbortsWithMessage(t, cur, "days must be between 1 and 90", func() {
		PostQuest(cross(cur), "Ok", "", 0)
	})
	id := PostQuest(cross(cur), "Translate the README", "", 3)

	// poster cannot hand in to their own quest
	testing.SetRealm(testing.NewUserRealm(alice))
	withSend(0)
	uassert.AbortsWithMessage(t, cur, "posters cannot hand in work for their own quest", func() {
		Submit(cross(cur), id, "self deal")
	})

	// only the poster awards, and only hunters who handed in
	testing.SetRealm(testing.NewUserRealm(bob))
	withSend(0)
	Submit(cross(cur), id, "done")
	uassert.AbortsWithMessage(t, cur, "only the poster can award this quest", func() {
		Award(cross(cur), id, bob, 1_000_000, "")
	})
	testing.SetRealm(testing.NewUserRealm(alice))
	withSend(0)
	uassert.AbortsWithMessage(t, cur, "this address has not handed in work for the quest", func() {
		Award(cross(cur), id, carol, 1_000_000, "")
	})
	uassert.AbortsWithMessage(t, cur, "only 1 GNOT left in escrow", func() {
		Award(cross(cur), id, bob, 2_000_000, "")
	})

	// cannot close early once someone handed in without awarding
	uassert.AbortsWithMessage(t, cur, "hunters have handed in work: award someone, or wait for the deadline to close", func() {
		Close(cross(cur), id)
	})

	// expire is not available before deadline + grace
	testing.SetRealm(testing.NewUserRealm(dave))
	withSend(0)
	uassert.AbortsWithMessage(t, cur, "quest can only be expired 168h0m0s after its deadline", func() {
		Expire(cross(cur), id)
	})
}

func TestPaymentsMustBeDirect(cur realm, t *testing.T) {
	reset()

	// a code realm forwarding a call cannot claim the origin send
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/someone/wrapper"))
	testing.SetOriginSend(chain.Coins{{"ugnot", 1_000_000}})
	uassert.AbortsWithMessage(t, cur, "rewards must be sent with a direct call (gnokey maketx call or a wallet)", func() {
		PostQuest(cross(cur), "Sneaky", "", 3)
	})
}

func TestCrowdfundRefundProRata(cur realm, t *testing.T) {
	reset()

	testing.SetRealm(testing.NewUserRealm(alice))
	withSend(3_000_000)
	id := PostQuest(cross(cur), "Build a gnoweb theme", "", 5)
	testing.SetRealm(testing.NewUserRealm(dave))
	withSend(1_000_000)
	Fund(cross(cur), id)

	_, remaining, _ := QuestStatus(id)
	uassert.Equal(t, int64(4_000_000), remaining)

	testing.SetRealm(testing.NewUserRealm(bob))
	withSend(0)
	Submit(cross(cur), id, "https://example.com/theme")

	// alice pays half, then closes: the other 2 GNOT go back 3:1
	aliceBefore := balance(alice)
	daveBefore := balance(dave)
	testing.SetRealm(testing.NewUserRealm(alice))
	withSend(0)
	Award(cross(cur), id, bob, 2_000_000, "")
	Close(cross(cur), id)

	uassert.Equal(t, aliceBefore+1_500_000, balance(alice))
	uassert.Equal(t, daveBefore+500_000, balance(dave))

	status, remaining, _ := QuestStatus(id)
	uassert.Equal(t, "completed", status)
	uassert.Equal(t, int64(0), remaining)
}

func TestExpireRefundsEveryone(cur realm, t *testing.T) {
	reset()

	testing.SetRealm(testing.NewUserRealm(alice))
	withSend(2_000_000)
	id := PostQuest(cross(cur), "Ghosted quest", "", 1)
	testing.SetRealm(testing.NewUserRealm(dave))
	withSend(1_000_000)
	Fund(cross(cur), id)
	testing.SetRealm(testing.NewUserRealm(bob))
	withSend(0)
	Submit(cross(cur), id, "work")

	// jump past deadline + grace
	getQuest(id).Deadline = time.Now().Add(-GracePeriod - time.Hour)

	aliceBefore := balance(alice)
	daveBefore := balance(dave)
	testing.SetRealm(testing.NewUserRealm(carol))
	withSend(0) // anyone may expire
	Expire(cross(cur), id)

	uassert.Equal(t, aliceBefore+2_000_000, balance(alice))
	uassert.Equal(t, daveBefore+1_000_000, balance(dave))
	status, _, _ := QuestStatus(id)
	uassert.Equal(t, "cancelled", status)
	_, _, expired := PosterStats(alice)
	uassert.Equal(t, 1, expired)
}

func TestSplitProRataIsExact(t *testing.T) {
	var contribs avl.Tree
	backers := []address{alice, bob, carol}
	contribs.Set(alice.String(), int64(1))
	contribs.Set(bob.String(), int64(1))
	contribs.Set(carol.String(), int64(1))

	shares := splitProRata(100, 3, backers, &contribs)
	uassert.Equal(t, int64(34), shares[0]) // poster takes the dust
	uassert.Equal(t, int64(33), shares[1])
	uassert.Equal(t, int64(33), shares[2])

	// large values do not overflow
	uassert.Equal(t, int64(4_000_000_000_000_000), mulDiv(8_000_000_000_000_000, 1_000_000_000_000, 2_000_000_000_000))
}

func TestRender(cur realm, t *testing.T) {
	reset()

	home := Render("")
	urequire.True(t, strings.Contains(home, "The board is empty"), home)

	testing.SetRealm(testing.NewUserRealm(alice))
	withSend(1_000_000)
	id := PostQuest(cross(cur), "Fix [link](javascript:alert(1)) *bold*", "Details with <script>x</script>", 7)
	testing.SetRealm(testing.NewUserRealm(bob))
	withSend(0)
	Submit(cross(cur), id, "javascript:alert(1)")
	testing.SetRealm(testing.NewUserRealm(alice))
	withSend(0)
	Award(cross(cur), id, bob, 1_000_000, "thanks")

	home = Render("")
	uassert.True(t, strings.Contains(home, "Top hunters"))
	uassert.False(t, strings.Contains(home, "](javascript:"), home)

	q := Render("quest/1")
	uassert.True(t, strings.Contains(q, "Quest #1"))
	uassert.False(t, strings.Contains(q, "](javascript:"), q)
	uassert.False(t, strings.Contains(q, "<script>"), q)

	p := Render("u/" + bob.String())
	uassert.True(t, strings.Contains(p, "Apprentice"), p)
	uassert.True(t, strings.Contains(p, "data:image/svg+xml;base64,"), p)

	uassert.True(t, strings.Contains(Render("quest/99"), "Quest not found"))
	uassert.True(t, strings.Contains(Render("u/notanaddress"), "Unknown adventurer"))
}
