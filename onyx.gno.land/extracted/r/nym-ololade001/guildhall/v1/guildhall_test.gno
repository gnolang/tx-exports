package guildhall

import (
	"strings"
	"testing"

	"chain"
	"chain/banker"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/p/nt/urequire/v0"
	"gno.land/p/nym-ololade001/guild/v0"
)

const (
	pkgPath     = "gno.land/r/nym-ololade001/guildhall/v1"
	questReward = int64(5000000) // 5 GNOT
	lease       = int64(600)
	review      = int64(1200)
	baseH       = int64(1000)
	deadline    = baseH + 10000
)

var (
	poster  = testutils.TestAddress("poster")
	worker  = testutils.TestAddress("worker")
	worker2 = testutils.TestAddress("worker2")
	rando   = testutils.TestAddress("rando")
)

func realmAddr() address {
	return chain.PackageAddress(pkgPath)
}

func resetTestState() {
	quests = avl.NewTree()
	active = avl.NewTree()
	profiles = avl.NewTree()
	questSeq = 0
	escrowTotal = 0
	paidTotal = 0
}

func ugnot(amt int64) chain.Coins {
	return chain.NewCoins(chain.NewCoin("ugnot", amt))
}

func mustQuestTest(t *testing.T, id uint64) *guild.Quest {
	q, ok := quests.Get(questKey(id)).(*guild.Quest)
	urequire.True(t, ok && q != nil, "quest exists")
	return q
}

func balanceOf(a address) int64 {
	return banker.NewReadonlyBanker().GetCoin(a, "ugnot")
}

// NOTE: testing.SetRealm and testing.SetOriginSend only take effect in the
// frame that runs them, so the realm calls below stay inline in the test
// bodies rather than moving behind helpers.

func TestPost(cur realm, t *testing.T) {
	defer resetTestState()
	testing.SetHeight(baseH)

	testing.IssueCoins(realmAddr(), ugnot(questReward))
	testing.SetRealm(testing.NewUserRealm(poster))
	testing.SetOriginSend(ugnot(questReward))
	id := Post(cross(cur), "Test quest", "do the thing", lease, review, deadline)
	uassert.Equal(t, uint64(1), id)
	uassert.Equal(t, questReward, escrowTotal)
	uassert.Equal(t, 1, active.Size())

	q := mustQuestTest(t, id)
	uassert.Equal(t, poster, q.Poster)
	uassert.Equal(t, "Test quest", q.Title)
	uassert.True(t, q.Status == guild.Open)
	uassert.Equal(t, questReward, q.Reward)

	p := findProfile(poster)
	urequire.NotNil(t, p)
	uassert.Equal(t, 1, p.Posted)
	uassert.Equal(t, 1, len(p.PostedIDs))
}

func TestPost_Rejects(cur realm, t *testing.T) {
	defer resetTestState()
	testing.SetHeight(baseH)

	// No send at all.
	testing.SetRealm(testing.NewUserRealm(poster))
	testing.SetOriginSend(nil)
	uassert.AbortsContains(t, cur, "ugnot", func() {
		Post(cross(cur), "t", "", lease, review, deadline)
	})

	// Wrong denom.
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin("foo", 100)))
	uassert.AbortsContains(t, cur, "ugnot", func() {
		Post(cross(cur), "t", "", lease, review, deadline)
	})

	// Two coins, even if one is ugnot.
	testing.SetOriginSend(chain.Coins{
		chain.NewCoin("ugnot", 100),
		chain.NewCoin("foo", 100),
	})
	uassert.AbortsContains(t, cur, "ugnot", func() {
		Post(cross(cur), "t", "", lease, review, deadline)
	})

	// A code realm cannot post even with a send attached: IsUserCall and
	// OriginSend are a pair (maketx run / intermediary realms could spend
	// the envelope first).
	testing.SetRealm(testing.NewCodeRealm(pkgPath))
	testing.SetOriginSend(ugnot(questReward))
	uassert.AbortsWithMessage(t, cur, "Post must be called directly by a user (maketx call)", func() {
		Post(cross(cur), "t", "", lease, review, deadline)
	})

	uassert.Equal(t, 0, quests.Size(), "no quest stored")
	uassert.Equal(t, int64(0), escrowTotal)
}

func TestPost_InvalidArgs(cur realm, t *testing.T) {
	defer resetTestState()
	testing.SetHeight(baseH)
	testing.IssueCoins(realmAddr(), ugnot(questReward))
	testing.SetRealm(testing.NewUserRealm(poster))
	testing.SetOriginSend(ugnot(questReward))
	// Deadline inside the first lease window.
	uassert.AbortsContains(t, cur, "deadline", func() {
		Post(cross(cur), "t", "", lease, review, baseH+lease)
	})
	uassert.AbortsContains(t, cur, "lease", func() {
		Post(cross(cur), "t", "", guild.MinBlocks-1, review, deadline)
	})
	uassert.Equal(t, 0, quests.Size())
}

func TestHappyPath(cur realm, t *testing.T) {
	defer resetTestState()
	testing.SetHeight(baseH)

	testing.IssueCoins(realmAddr(), ugnot(questReward))
	testing.SetRealm(testing.NewUserRealm(poster))
	testing.SetOriginSend(ugnot(questReward))
	id := Post(cross(cur), "Test quest", "do the thing", lease, review, deadline)

	testing.SetRealm(testing.NewUserRealm(worker))
	testing.SetOriginSend(nil)
	Claim(cross(cur), id)
	Submit(cross(cur), id, "https://proof.example/1", "done")

	before := balanceOf(worker)
	testing.SetRealm(testing.NewUserRealm(poster))
	Accept(cross(cur), id)

	uassert.Equal(t, before+questReward, balanceOf(worker))
	uassert.Equal(t, int64(0), escrowTotal)
	uassert.Equal(t, questReward, paidTotal)
	uassert.Equal(t, int64(0), balanceOf(realmAddr()))
	uassert.Equal(t, 0, active.Size(), "paid quest leaves active")

	q := mustQuestTest(t, id)
	uassert.True(t, q.Status == guild.Paid)
	uassert.False(t, q.AutoPaid)

	wp := findProfile(worker)
	urequire.NotNil(t, wp)
	uassert.Equal(t, 1, wp.Paid)
	uassert.Equal(t, 1, wp.Accepted)
	uassert.Equal(t, 0, wp.AutoAccepted)
	uassert.Equal(t, questReward, wp.Earned)

	pp := findProfile(poster)
	uassert.Equal(t, questReward, pp.Spent)
}

func TestAutoAccept(cur realm, t *testing.T) {
	defer resetTestState()
	testing.SetHeight(baseH)

	testing.IssueCoins(realmAddr(), ugnot(questReward))
	testing.SetRealm(testing.NewUserRealm(poster))
	testing.SetOriginSend(ugnot(questReward))
	id := Post(cross(cur), "Test quest", "do the thing", lease, review, deadline)

	testing.SetRealm(testing.NewUserRealm(worker))
	testing.SetOriginSend(nil)
	Claim(cross(cur), id)
	Submit(cross(cur), id, "https://proof.example/1", "done")

	// Still inside the review window: worker cannot claim the payout yet.
	uassert.AbortsContains(t, cur, "review window", func() {
		ClaimPayout(cross(cur), id)
	})

	testing.SkipHeights(review + 1)
	ClaimPayout(cross(cur), id)

	q := mustQuestTest(t, id)
	uassert.True(t, q.Status == guild.Paid)
	uassert.True(t, q.AutoPaid)
	uassert.Equal(t, questReward, balanceOf(worker))
	wp := findProfile(worker)
	uassert.Equal(t, 1, wp.AutoAccepted)
}

func TestRejectThenDifferentWorker(cur realm, t *testing.T) {
	defer resetTestState()
	testing.SetHeight(baseH)

	testing.IssueCoins(realmAddr(), ugnot(questReward))
	testing.SetRealm(testing.NewUserRealm(poster))
	testing.SetOriginSend(ugnot(questReward))
	id := Post(cross(cur), "Test quest", "do the thing", lease, review, deadline)

	testing.SetRealm(testing.NewUserRealm(worker))
	testing.SetOriginSend(nil)
	Claim(cross(cur), id)
	Submit(cross(cur), id, "https://proof.example/1", "done")

	testing.SetRealm(testing.NewUserRealm(poster))
	Reject(cross(cur), id, "not quite")

	q := mustQuestTest(t, id)
	uassert.True(t, q.Status == guild.Open)
	uassert.Equal(t, int64(0), balanceOf(worker))

	// A different worker claims, submits and gets paid.
	testing.SetRealm(testing.NewUserRealm(worker2))
	Claim(cross(cur), id)
	Submit(cross(cur), id, "https://proof.example/2", "v2")

	testing.SetRealm(testing.NewUserRealm(poster))
	Accept(cross(cur), id)
	uassert.Equal(t, questReward, balanceOf(worker2))
	uassert.Equal(t, int64(0), balanceOf(worker))
}

func TestLeaseExpiry(cur realm, t *testing.T) {
	defer resetTestState()
	testing.SetHeight(baseH)

	testing.IssueCoins(realmAddr(), ugnot(questReward))
	testing.SetRealm(testing.NewUserRealm(poster))
	testing.SetOriginSend(ugnot(questReward))
	id := Post(cross(cur), "Test quest", "do the thing", lease, review, deadline)

	testing.SetRealm(testing.NewUserRealm(worker))
	testing.SetOriginSend(nil)
	Claim(cross(cur), id)

	testing.SkipHeights(lease + 1)

	// The original worker's lease is dead: they cannot submit.
	uassert.AbortsContains(t, cur, "expired", func() {
		Submit(cross(cur), id, "u", "")
	})

	// Another worker picks the quest up.
	testing.SetRealm(testing.NewUserRealm(worker2))
	Claim(cross(cur), id)
	Submit(cross(cur), id, "https://proof.example/2", "v2")

	testing.SetRealm(testing.NewUserRealm(poster))
	Accept(cross(cur), id)
	uassert.Equal(t, questReward, balanceOf(worker2))
	uassert.Equal(t, int64(0), balanceOf(worker))
}

func TestRefund(cur realm, t *testing.T) {
	defer resetTestState()
	testing.SetHeight(baseH)
	posterBefore := balanceOf(poster)

	testing.IssueCoins(realmAddr(), ugnot(questReward))
	testing.SetRealm(testing.NewUserRealm(poster))
	testing.SetOriginSend(ugnot(questReward))
	id := Post(cross(cur), "Test quest", "do the thing", lease, review, deadline)

	// Not before the deadline.
	uassert.AbortsContains(t, cur, "not passed", func() {
		Refund(cross(cur), id)
	})

	testing.SkipHeights(deadline - baseH)
	Refund(cross(cur), id)
	uassert.Equal(t, posterBefore+questReward, balanceOf(poster))
	uassert.Equal(t, int64(0), escrowTotal)
	uassert.Equal(t, 0, active.Size(), "refunded quest leaves active")
	uassert.True(t, mustQuestTest(t, id).Status == guild.Refunded)
}

func TestRefund_StaleClaim(cur realm, t *testing.T) {
	defer resetTestState()
	testing.SetHeight(baseH)

	testing.IssueCoins(realmAddr(), ugnot(questReward))
	testing.SetRealm(testing.NewUserRealm(poster))
	testing.SetOriginSend(ugnot(questReward))
	id := Post(cross(cur), "Test quest", "do the thing", lease, review, deadline)

	testing.SetRealm(testing.NewUserRealm(worker))
	testing.SetOriginSend(nil)
	Claim(cross(cur), id)

	testing.SkipHeights(deadline - baseH)
	testing.SetRealm(testing.NewUserRealm(poster))
	Refund(cross(cur), id)
	uassert.True(t, mustQuestTest(t, id).Status == guild.Refunded)
	uassert.Equal(t, questReward, balanceOf(poster))
}

func TestRefund_RejectedWhileSubmitted(cur realm, t *testing.T) {
	defer resetTestState()
	testing.SetHeight(baseH)

	testing.IssueCoins(realmAddr(), ugnot(questReward))
	testing.SetRealm(testing.NewUserRealm(poster))
	testing.SetOriginSend(ugnot(questReward))
	id := Post(cross(cur), "Test quest", "do the thing", lease, review, deadline)

	testing.SetRealm(testing.NewUserRealm(worker))
	testing.SetOriginSend(nil)
	Claim(cross(cur), id)
	Submit(cross(cur), id, "https://proof.example/1", "done")

	testing.SkipHeights(deadline - baseH)
	testing.SetRealm(testing.NewUserRealm(poster))
	uassert.AbortsContains(t, cur, "pending submission", func() {
		Refund(cross(cur), id)
	})
	uassert.Equal(t, questReward, escrowTotal)
}

func TestCancel(cur realm, t *testing.T) {
	defer resetTestState()
	testing.SetHeight(baseH)
	posterBefore := balanceOf(poster)

	testing.IssueCoins(realmAddr(), ugnot(questReward))
	testing.SetRealm(testing.NewUserRealm(poster))
	testing.SetOriginSend(ugnot(questReward))
	id := Post(cross(cur), "Test quest", "do the thing", lease, review, deadline)

	Cancel(cross(cur), id)
	uassert.True(t, mustQuestTest(t, id).Status == guild.Cancelled)
	uassert.Equal(t, posterBefore+questReward, balanceOf(poster))
	uassert.Equal(t, int64(0), escrowTotal)
	uassert.Equal(t, 0, active.Size(), "cancelled quest leaves active")
}

func TestCancel_RejectedAfterClaim(cur realm, t *testing.T) {
	defer resetTestState()
	testing.SetHeight(baseH)

	testing.IssueCoins(realmAddr(), ugnot(questReward))
	testing.SetRealm(testing.NewUserRealm(poster))
	testing.SetOriginSend(ugnot(questReward))
	id := Post(cross(cur), "Test quest", "do the thing", lease, review, deadline)

	testing.SetRealm(testing.NewUserRealm(worker))
	testing.SetOriginSend(nil)
	Claim(cross(cur), id)

	testing.SetRealm(testing.NewUserRealm(poster))
	uassert.AbortsContains(t, cur, "not open", func() {
		Cancel(cross(cur), id)
	})
}

func TestAuth(cur realm, t *testing.T) {
	defer resetTestState()
	testing.SetHeight(baseH)

	testing.IssueCoins(realmAddr(), ugnot(questReward))
	testing.SetRealm(testing.NewUserRealm(poster))
	testing.SetOriginSend(ugnot(questReward))
	id := Post(cross(cur), "Test quest", "do the thing", lease, review, deadline)

	uassert.AbortsContains(t, cur, "own quest", func() { Claim(cross(cur), id) })

	// While open, poster-only actions reject other callers.
	testing.SetRealm(testing.NewUserRealm(rando))
	uassert.AbortsContains(t, cur, "not the poster", func() {
		Refund(cross(cur), id)
	})
	uassert.AbortsContains(t, cur, "not the poster", func() {
		Cancel(cross(cur), id)
	})

	testing.SetRealm(testing.NewUserRealm(worker))
	testing.SetOriginSend(nil)
	Claim(cross(cur), id)

	// While claimed, only the worker may submit.
	testing.SetRealm(testing.NewUserRealm(rando))
	uassert.AbortsContains(t, cur, "not the worker", func() {
		Submit(cross(cur), id, "u", "")
	})
	uassert.AbortsContains(t, cur, "not open", func() {
		Cancel(cross(cur), id)
	})

	testing.SetRealm(testing.NewUserRealm(worker))
	Submit(cross(cur), id, "https://proof.example/1", "done")

	// While submitted, poster-only review actions reject other callers.
	testing.SetRealm(testing.NewUserRealm(rando))
	uassert.AbortsContains(t, cur, "not the poster", func() {
		Accept(cross(cur), id)
	})
	uassert.AbortsContains(t, cur, "not the poster", func() {
		Reject(cross(cur), id, "x")
	})
	uassert.AbortsContains(t, cur, "pending submission", func() {
		Refund(cross(cur), id)
	})

	// Only the worker may claim the payout.
	testing.SetRealm(testing.NewUserRealm(poster))
	uassert.AbortsContains(t, cur, "not the worker", func() {
		ClaimPayout(cross(cur), id)
	})

	testing.SetRealm(testing.NewUserRealm(rando))
	uassert.AbortsContains(t, cur, "quest not found", func() {
		Accept(cross(cur), 999)
	})
}

func TestDoublePayout(cur realm, t *testing.T) {
	defer resetTestState()
	testing.SetHeight(baseH)

	testing.IssueCoins(realmAddr(), ugnot(questReward))
	testing.SetRealm(testing.NewUserRealm(poster))
	testing.SetOriginSend(ugnot(questReward))
	id := Post(cross(cur), "Test quest", "do the thing", lease, review, deadline)

	testing.SetRealm(testing.NewUserRealm(worker))
	testing.SetOriginSend(nil)
	Claim(cross(cur), id)
	Submit(cross(cur), id, "https://proof.example/1", "done")

	testing.SetRealm(testing.NewUserRealm(poster))
	Accept(cross(cur), id)
	uassert.Equal(t, questReward, balanceOf(worker))

	// Second Accept and late ClaimPayout both fail: quest is Paid.
	uassert.AbortsContains(t, cur, "not submitted", func() {
		Accept(cross(cur), id)
	})

	testing.SkipHeights(review + 1)
	testing.SetRealm(testing.NewUserRealm(worker))
	uassert.AbortsContains(t, cur, "not submitted", func() {
		ClaimPayout(cross(cur), id)
	})
	uassert.Equal(t, questReward, balanceOf(worker), "paid exactly once")
	uassert.Equal(t, questReward, paidTotal)
}

func TestEscrowTotals(cur realm, t *testing.T) {
	defer resetTestState()
	testing.SetHeight(baseH)

	testing.IssueCoins(realmAddr(), ugnot(questReward+2000000))
	testing.SetRealm(testing.NewUserRealm(poster))
	testing.SetOriginSend(ugnot(questReward))
	id1 := Post(cross(cur), "Quest one", "", lease, review, deadline)

	testing.SetOriginSend(ugnot(2000000))
	id2 := Post(cross(cur), "Quest two", "", lease, review, deadline)
	uassert.Equal(t, questReward+2000000, escrowTotal)

	testing.SetRealm(testing.NewUserRealm(worker))
	testing.SetOriginSend(nil)
	Claim(cross(cur), id1)
	Submit(cross(cur), id1, "https://proof.example/1", "done")

	testing.SetRealm(testing.NewUserRealm(poster))
	Accept(cross(cur), id1)
	uassert.Equal(t, int64(2000000), escrowTotal)
	uassert.Equal(t, questReward, paidTotal)

	Cancel(cross(cur), id2)
	uassert.Equal(t, int64(0), escrowTotal)
	uassert.Equal(t, questReward, paidTotal)
}

func TestRender(cur realm, t *testing.T) {
	defer resetTestState()
	testing.SetHeight(baseH)

	testing.IssueCoins(realmAddr(), ugnot(questReward))
	testing.SetRealm(testing.NewUserRealm(poster))
	testing.SetOriginSend(ugnot(questReward))
	id := Post(cross(cur), "Test quest", "do the thing", lease, review, deadline)

	testing.SetRealm(testing.NewUserRealm(worker))
	testing.SetOriginSend(nil)
	Claim(cross(cur), id)

	board := Render("")
	uassert.True(t, strings.Contains(board, "Guildhall"), "board title")
	uassert.True(t, strings.Contains(board, "In progress"), "in-progress row")
	uassert.True(t, strings.Contains(board, "claimed by"), "claim row")

	page := Render("q/1")
	uassert.True(t, strings.Contains(page, "Test quest"), "quest title")
	uassert.True(t, strings.Contains(page, "claimed"), "quest status")
	uassert.True(t, strings.Contains(page, "5 GNOT"), "reward")
	uassert.True(t, strings.Contains(page, worker.String()), "worker link")
	uassert.True(t, strings.Contains(page, "maketx call"), "commands")
	uassert.True(t, strings.Contains(page, "-func Submit"), "submit command")

	profile := Render("u/" + poster.String())
	uassert.True(t, strings.Contains(profile, "Quests posted"), "profile")
	uassert.True(t, strings.Contains(profile, "quest 1"), "posted id")

	about := Render("about")
	uassert.True(t, strings.Contains(about, "state machine"), "about")

	nf := Render("no/such/page")
	uassert.True(t, strings.Contains(nf, "Not found"), "not found")
	nfq := Render("q/notanumber")
	uassert.True(t, strings.Contains(nfq, "Not found"), "bad quest id")
	nfu := Render("u/notanaddress")
	uassert.True(t, strings.Contains(nfu, "Not found"), "bad address")
}

func TestRender_OpenQuestOnBoard(cur realm, t *testing.T) {
	defer resetTestState()
	testing.SetHeight(baseH)

	testing.IssueCoins(realmAddr(), ugnot(questReward))
	testing.SetRealm(testing.NewUserRealm(poster))
	testing.SetOriginSend(ugnot(questReward))
	Post(cross(cur), "Open quest", "", lease, review, deadline)

	board := Render("")
	uassert.True(t, strings.Contains(board, "Open quest"), "quest on board")
	uassert.True(t, strings.Contains(board, "1 open quests"), "open count")
	uassert.True(t, strings.Contains(board, "5 GNOT in escrow"), "escrow total")
	uassert.True(t, strings.Contains(board, "0 GNOT paid out"), "paid total")
}

func TestRender_EscapesMaliciousInput(cur realm, t *testing.T) {
	defer resetTestState()
	testing.SetHeight(baseH)
	testing.IssueCoins(realmAddr(), ugnot(questReward))
	testing.SetRealm(testing.NewUserRealm(poster))
	testing.SetOriginSend(ugnot(questReward))
	evil := "[x](javascript:alert(1)) <script>|\n# injected heading"
	Post(cross(cur), evil, "spec with <script> and\n\n# heading", lease, review, deadline)

	board := Render("")
	uassert.False(t, strings.Contains(board, "<script>"), "raw html in board")
	uassert.False(t, strings.Contains(board, "](javascript:"), "live js link in board")

	page := Render("q/1")
	uassert.False(t, strings.Contains(page, "<script>"), "raw html in page")
	uassert.False(t, strings.Contains(page, "](javascript:"), "live js link in page")
}

func TestQuestKeyOrdering(cur realm, t *testing.T) {
	defer resetTestState()
	testing.SetHeight(baseH)
	testing.IssueCoins(realmAddr(), ugnot(questReward*11))
	testing.SetRealm(testing.NewUserRealm(poster))
	for i := 1; i <= 11; i++ {
		testing.SetOriginSend(ugnot(questReward))
		Post(cross(cur), ufmt.Sprintf("Quest %d", i), "", lease, review, deadline)
	}
	uassert.Equal(t, 11, active.Size())

	// AVL keys iterate in numeric id order: 2 comes before 10.
	prev := uint64(0)
	active.Iterate("", "", func(key string, value any) bool {
		q := value.(*guild.Quest)
		uassert.True(t, q.ID > prev, "iteration order is numeric")
		prev = q.ID
		return false
	})

	board := Render("")
	i2 := strings.Index(board, "Quest 2")
	i10 := strings.Index(board, "Quest 10")
	uassert.True(t, i2 >= 0 && i10 >= 0, "both quests listed")
	uassert.True(t, i2 < i10, "quest 2 is listed before quest 10")

	page := Render("q/10")
	uassert.True(t, strings.Contains(page, "Quest 10"), "quest 10 page renders")
}

func TestRender_AbsoluteLinks(cur realm, t *testing.T) {
	defer resetTestState()
	testing.SetHeight(baseH)
	testing.IssueCoins(realmAddr(), ugnot(questReward))
	testing.SetRealm(testing.NewUserRealm(poster))
	testing.SetOriginSend(ugnot(questReward))
	id := Post(cross(cur), "Link quest", "", lease, review, deadline)

	testing.SetRealm(testing.NewUserRealm(worker))
	testing.SetOriginSend(nil)
	Claim(cross(cur), id)

	board := Render("")
	uassert.True(t, strings.Contains(board, "(/r/nym-ololade001/guildhall/v1:q/1)"), "absolute quest link")
	uassert.True(t, strings.Contains(board, "(/r/nym-ololade001/guildhall/v1:u/"+worker.String()+")"), "absolute worker link")
	uassert.True(t, strings.Contains(board, "(/r/nym-ololade001/guildhall/v1:about)"), "absolute about link")

	page := Render("q/1")
	uassert.True(t, strings.Contains(page, "(/r/nym-ololade001/guildhall/v1:u/"+poster.String()+")"), "absolute poster link")
	uassert.True(t, strings.Contains(page, "](/r/nym-ololade001/guildhall/v1)"), "absolute board link")

	profile := Render("u/" + poster.String())
	uassert.True(t, strings.Contains(profile, "(/r/nym-ololade001/guildhall/v1:q/1)"), "absolute quest link in profile")

	nf := Render("q/404")
	uassert.True(t, strings.Contains(nf, "](/r/nym-ololade001/guildhall/v1)"), "absolute board link in 404")
}

func TestBoard_DropsTerminalQuests(cur realm, t *testing.T) {
	defer resetTestState()
	testing.SetHeight(baseH)
	testing.IssueCoins(realmAddr(), ugnot(questReward*2))
	testing.SetRealm(testing.NewUserRealm(poster))
	testing.SetOriginSend(ugnot(questReward))
	Post(cross(cur), "Stays open", "", lease, review, deadline)
	testing.SetOriginSend(ugnot(questReward))
	id2 := Post(cross(cur), "Gets cancelled", "", lease, review, deadline)
	uassert.Equal(t, 2, active.Size())

	Cancel(cross(cur), id2)
	uassert.Equal(t, 1, active.Size())

	board := Render("")
	uassert.True(t, strings.Contains(board, "Stays open"), "open quest stays on board")
	uassert.False(t, strings.Contains(board, "Gets cancelled"), "cancelled quest leaves board")
	uassert.True(t, strings.Contains(board, "1 open quests"), "open count drops")

	// The quest page still renders for terminal quests.
	page := Render("q/2")
	uassert.True(t, strings.Contains(page, "cancelled"), "terminal quest page renders")
}
