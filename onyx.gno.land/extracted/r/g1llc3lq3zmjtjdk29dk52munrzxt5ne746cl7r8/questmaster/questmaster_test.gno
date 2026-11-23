package questmaster

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"strings"
	"testing"

	"gno.land/p/g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8/escrow"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

// Test notes
//
// Coins: in `gno test`, testing.SetOriginSend only sets what
// unsafe.OriginSend() reports; it does not move coins. On chain, a MsgCall
// with -send credits the realm before the call runs. post() below does the
// same by issuing the reward to the realm address just before PostQuest.
// Failing posts get no coins issued, matching a reverted transaction.
//
// Reverts: the test harness does NOT roll back realm state when a call
// panics (checked: a test-only crossing function that changed a variable and
// then panicked left the change in place). On chain the whole transaction
// reverts. So the tests below snapshot all quests, totals and the realm
// balance before every failing call and check they are identical after it.
// This passes because every check (caller, coins, escrow rule) runs before
// the first write.

var (
	alice = testutils.TestAddress("qb_alice")
	bob   = testutils.TestAddress("qb_bob")
	carol = testutils.TestAddress("qb_carol")
	dave  = testutils.TestAddress("qb_dave")

	realmAddr = chain.PackageAddress("gno.land/r/g1llc3lq3zmjtjdk29dk52munrzxt5ne746cl7r8/questmaster")
)

const (
	gnot = int64(1_000_000)
	link = "https://github.com/example/repo/pull/1"
)

func ugnot(n int64) chain.Coins { return chain.Coins{{Denom: "ugnot", Amount: n}} }

func bal(addr address) int64 {
	return banker.NewReadonlyBanker().GetCoin(addr, "ugnot")
}

// resetState gives each test an empty board. The test harness keeps realm
// variables between tests but resets bank balances, so every test starts
// from scratch to keep the balance invariants exact.
func resetState() {
	quests = avl.Tree{}
	byPoster = avl.Tree{}
	byBuilder = avl.Tree{}
	openIDs = avl.Tree{}
	paidIDs = avl.Tree{}
	lastID = 0
	totalPosted, totalLocked, totalPaid, totalRefunded = 0, 0, 0, 0
}

// testing.SetRealm changes the realm of the frame that calls it, so it is
// called inline in each crossing function (test or helper) right before the
// cross(cur) call it is meant for, not from a shared helper.

// post posts a quest from u with reward ugnot, simulating the MsgCall deposit.
func post(cur realm, u address, reward int64, title string) uint64 {
	return postD(cur, u, reward, title, "details")
}

// postD is post with chosen details.
func postD(cur realm, u address, reward int64, title, details string) uint64 {
	testing.SetRealm(testing.NewUserRealm(u))
	testing.SetOriginSend(nil)
	testing.SetOriginSend(ugnot(reward))
	testing.IssueCoins(realmAddr, ugnot(reward))
	id := PostQuest(cross(cur), title, details, 2_000)
	testing.SetOriginSend(nil)
	return id
}

// claimed / submitted set up a quest from alice taken by bob.
func claimed(cur realm, reward int64) uint64 {
	id := post(cur, alice, reward, "claimed quest")
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(nil)
	ClaimQuest(cross(cur), id)
	return id
}

func submitted(cur realm, reward int64) uint64 {
	id := claimed(cur, reward)
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(nil)
	SubmitWork(cross(cur), id, link)
	return id
}

// snapshot is everything a failed call must leave unchanged.
type snapshot struct {
	totals Totals
	quests []QuestView
	realm  int64
	open   string
	paid   string
}

func takeSnapshot() snapshot {
	s := snapshot{totals: GetTotals(), realm: bal(realmAddr)}
	for id := uint64(1); id <= s.totals.Quests; id++ {
		s.quests = append(s.quests, GetQuest(id))
	}
	s.open = idsString(allPages(OpenQuestIDs))
	s.paid = idsString(allPages(PaidQuestIDs))
	return s
}

func sameSnapshot(t *testing.T, a, b snapshot, what string) {
	t.Helper()
	if a.totals != b.totals {
		t.Fatalf("%s: totals changed: %v -> %v", what, a.totals, b.totals)
	}
	if a.realm != b.realm {
		t.Fatalf("%s: realm balance changed: %d -> %d", what, a.realm, b.realm)
	}
	if len(a.quests) != len(b.quests) {
		t.Fatalf("%s: quest count changed", what)
	}
	for i := range a.quests {
		if a.quests[i] != b.quests[i] {
			t.Fatalf("%s: quest %d changed", what, i+1)
		}
	}
	if a.open != b.open || a.paid != b.paid {
		t.Fatalf("%s: open/paid lists changed", what)
	}
}

// fails asserts fn aborts with a message containing substr and changes nothing.
func fails(t *testing.T, rlm realm, substr string, fn func(), what string) {
	t.Helper()
	before := takeSnapshot()
	uassert.AbortsContains(t, rlm, substr, fn, what)
	sameSnapshot(t, before, takeSnapshot(), what)
}

func allPages(list func(offset, limit int) []uint64) []uint64 {
	var out []uint64
	for off := 0; ; off += MaxPageSize {
		p := list(off, MaxPageSize)
		out = append(out, p...)
		if len(p) < MaxPageSize {
			return out
		}
	}
}

func idsString(ids []uint64) string {
	var sb strings.Builder
	for _, id := range ids {
		sb.WriteString(idStr(id))
		sb.WriteString(",")
	}
	return sb.String()
}

// checkInvariants: rule 12 and the totals identities.
func checkInvariants(t *testing.T, what string) {
	t.Helper()
	tot := GetTotals()
	var held int64
	open, paid := 0, 0
	for id := uint64(1); id <= tot.Quests; id++ {
		q := GetQuest(id)
		if !q.State.IsFinal() {
			held += q.Reward
		}
		if q.State == escrow.Open {
			open++
		}
		if q.State == escrow.Paid {
			paid++
		}
	}
	if b := bal(realmAddr); b != held || held != tot.Locked {
		t.Fatalf("%s: realm balance %d, sum of held rewards %d, locked total %d", what, b, held, tot.Locked)
	}
	if tot.Posted != tot.Locked+tot.Paid+tot.Refunded {
		t.Fatalf("%s: posted %d != locked %d + paid %d + refunded %d", what, tot.Posted, tot.Locked, tot.Paid, tot.Refunded)
	}
	if tot.OpenQuests != open || tot.PaidQuests != paid {
		t.Fatalf("%s: open %d/%d paid %d/%d", what, tot.OpenQuests, open, tot.PaidQuests, paid)
	}
}

// ---------------------------------------------------------------------------
// Plan section 10, case 1: happy path with balances.

func TestHappyPath(cur realm, t *testing.T) {
	resetState()
	before := GetTotals()
	id := post(cur, alice, 5*gnot, "Write a tutorial")
	q := GetQuest(id)
	uassert.Equal(t, escrow.Open.String(), q.State.String())
	uassert.Equal(t, alice.String(), q.Poster.String())
	uassert.Equal(t, 5*gnot, q.Reward)
	uassert.Equal(t, runtime.ChainHeight(), q.CreatedAt)

	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(nil)
	ClaimQuest(cross(cur), id)
	uassert.Equal(t, escrow.Claimed.String(), GetQuest(id).State.String())
	uassert.Equal(t, bob.String(), GetQuest(id).Builder.String())
	SubmitWork(cross(cur), id, link)
	uassert.Equal(t, escrow.Submitted.String(), GetQuest(id).State.String())
	uassert.Equal(t, link, GetQuest(id).WorkLink)

	bobBefore, realmBefore := bal(bob), bal(realmAddr)
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	ApproveWork(cross(cur), id)
	uassert.Equal(t, bobBefore+5*gnot, bal(bob), "builder gets exactly the reward")
	uassert.Equal(t, realmBefore-5*gnot, bal(realmAddr), "realm pays exactly the reward")
	uassert.Equal(t, escrow.Paid.String(), GetQuest(id).State.String())

	after := GetTotals()
	uassert.Equal(t, before.Posted+5*gnot, after.Posted)
	uassert.Equal(t, before.Paid+5*gnot, after.Paid)
	uassert.Equal(t, before.Locked, after.Locked)
	uassert.Equal(t, before.PaidQuests+1, after.PaidQuests)
	checkInvariants(t, "happy path")
}

// Case 2: cancel an open quest refunds the poster.
func TestCancelRefund(cur realm, t *testing.T) {
	resetState()
	id := post(cur, alice, 3*gnot, "To be cancelled")
	before := GetTotals()
	aliceBefore, realmBefore := bal(alice), bal(realmAddr)
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	CancelQuest(cross(cur), id)
	uassert.Equal(t, aliceBefore+3*gnot, bal(alice))
	uassert.Equal(t, realmBefore-3*gnot, bal(realmAddr))
	uassert.Equal(t, escrow.Cancelled.String(), GetQuest(id).State.String())
	after := GetTotals()
	uassert.Equal(t, before.Refunded+3*gnot, after.Refunded)
	uassert.Equal(t, before.Locked-3*gnot, after.Locked)
	uassert.Equal(t, before.OpenQuests-1, after.OpenQuests)
	checkInvariants(t, "cancel")
}

// Case 3: reject reopens, clears the builder, counts; builder history kept.
func TestReject(cur realm, t *testing.T) {
	resetState()
	id := submitted(cur, 2*gnot)
	realmBefore := bal(realmAddr)
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	RejectWork(cross(cur), id, "Tests are missing")
	q := GetQuest(id)
	uassert.Equal(t, escrow.Open.String(), q.State.String())
	uassert.Equal(t, address("").String(), q.Builder.String())
	uassert.Equal(t, "", q.WorkLink)
	uassert.Equal(t, 1, q.RejectCount)
	uassert.Equal(t, "Tests are missing", q.LastRejectReason)
	uassert.Equal(t, realmBefore, bal(realmAddr), "no coins move on reject")
	uassert.True(t, containsID(allPages(OpenQuestIDs), id), "back in the open list")
	uassert.True(t, containsID(QuestIDsByBuilder(bob, 0, MaxPageSize), id), "builder history kept")

	// a second builder can take it; both stay in their own history
	testing.SetRealm(testing.NewUserRealm(carol))
	testing.SetOriginSend(nil)
	ClaimQuest(cross(cur), id)
	uassert.True(t, containsID(QuestIDsByBuilder(carol, 0, MaxPageSize), id))
	uassert.True(t, containsID(QuestIDsByBuilder(bob, 0, MaxPageSize), id))
	uassert.Equal(t, carol.String(), GetQuest(id).Builder.String())
	checkInvariants(t, "reject")
}

// Case 4: ClaimPayout fails up to and including the review deadline, pays after.
func TestClaimPayoutTimeout(cur realm, t *testing.T) {
	resetState()
	id := submitted(cur, 4*gnot)
	q := GetQuest(id)
	uassert.Equal(t, q.SubmittedAt+escrow.ReviewBlocks, q.ReviewDeadline)

	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(nil)
	fails(t, cur, "review deadline has not passed", func() { ClaimPayout(cross(cur), id) }, "payout right after submit")
	testing.SkipHeights(q.ReviewDeadline - runtime.ChainHeight() - 1) // deadline - 1
	fails(t, cur, "review deadline has not passed", func() { ClaimPayout(cross(cur), id) }, "payout at deadline-1")
	testing.SkipHeights(1) // exactly at the deadline
	uassert.Equal(t, q.ReviewDeadline, runtime.ChainHeight())
	uassert.False(t, GetQuest(id).CanClaimPayout)
	fails(t, cur, "review deadline has not passed", func() { ClaimPayout(cross(cur), id) }, "payout at deadline")

	testing.SkipHeights(1) // deadline + 1
	uassert.True(t, GetQuest(id).CanClaimPayout)
	bobBefore, realmBefore := bal(bob), bal(realmAddr)
	ClaimPayout(cross(cur), id)
	uassert.Equal(t, bobBefore+4*gnot, bal(bob))
	uassert.Equal(t, realmBefore-4*gnot, bal(realmAddr))
	uassert.Equal(t, escrow.Paid.String(), GetQuest(id).State.String())
	checkInvariants(t, "timeout payout")
}

// Reject is allowed at the review deadline and refused one block after.
func TestRejectAfterReviewDeadline(cur realm, t *testing.T) {
	resetState()
	id := submitted(cur, gnot)
	d := GetQuest(id).ReviewDeadline
	testing.SkipHeights(d - runtime.ChainHeight() + 1)
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	fails(t, cur, "review deadline has passed", func() { RejectWork(cross(cur), id, "late") }, "late reject")
	// approving late still works and pays the builder
	bobBefore := bal(bob)
	ApproveWork(cross(cur), id)
	uassert.Equal(t, bobBefore+gnot, bal(bob))
}

// Case 5: ReleaseQuest fails up to and including the work deadline, works after.
func TestReleaseDeadline(cur realm, t *testing.T) {
	resetState()
	id := claimed(cur, gnot)
	q := GetQuest(id)
	uassert.Equal(t, q.ClaimedAt+2_000, q.WorkDeadline)
	testing.SetRealm(testing.NewUserRealm(dave))
	testing.SetOriginSend(nil)
	fails(t, cur, "work deadline has not passed", func() { ReleaseQuest(cross(cur), id) }, "release right after claim")
	testing.SkipHeights(q.WorkDeadline - runtime.ChainHeight())
	uassert.Equal(t, q.WorkDeadline, runtime.ChainHeight())
	fails(t, cur, "work deadline has not passed", func() { ReleaseQuest(cross(cur), id) }, "release at deadline")
	// the builder may still submit at the deadline block; check on a copy quest instead
	testing.SkipHeights(1)
	uassert.True(t, GetQuest(id).CanRelease)
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(nil)
	fails(t, cur, "work deadline has passed", func() { SubmitWork(cross(cur), id, link) }, "submit after deadline")
	testing.SetRealm(testing.NewUserRealm(dave))
	testing.SetOriginSend(nil)
	ReleaseQuest(cross(cur), id)
	uassert.Equal(t, escrow.Open.String(), GetQuest(id).State.String())
	uassert.Equal(t, address("").String(), GetQuest(id).Builder.String())
	uassert.True(t, containsID(allPages(OpenQuestIDs), id))
	checkInvariants(t, "release")
}

// Unclaim by the builder reopens the quest.
func TestUnclaim(cur realm, t *testing.T) {
	resetState()
	id := claimed(cur, gnot)
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(nil)
	UnclaimQuest(cross(cur), id)
	uassert.Equal(t, escrow.Open.String(), GetQuest(id).State.String())
	uassert.True(t, containsID(allPages(OpenQuestIDs), id))
	uassert.True(t, containsID(QuestIDsByBuilder(bob, 0, MaxPageSize), id), "history kept after unclaim")
	checkInvariants(t, "unclaim")
}

// Case 6: a stranger cannot approve, reject, cancel, submit, unclaim or claim payout.
func TestStranger(cur realm, t *testing.T) {
	resetState()
	open := post(cur, alice, gnot, "open")
	cl := claimed(cur, gnot)
	sub := submitted(cur, gnot)
	testing.SetRealm(testing.NewUserRealm(carol))
	testing.SetOriginSend(nil)
	fails(t, cur, "only the poster", func() { CancelQuest(cross(cur), open) }, "stranger cancel")
	fails(t, cur, "only the builder", func() { SubmitWork(cross(cur), cl, link) }, "stranger submit")
	fails(t, cur, "only the builder", func() { UnclaimQuest(cross(cur), cl) }, "stranger unclaim")
	fails(t, cur, "only the poster", func() { ApproveWork(cross(cur), sub) }, "stranger approve")
	fails(t, cur, "only the poster", func() { RejectWork(cross(cur), sub, "no") }, "stranger reject")
	testing.SkipHeights(escrow.ReviewBlocks + 1)
	fails(t, cur, "only the builder", func() { ClaimPayout(cross(cur), sub) }, "stranger claim payout")
	// roles do not cross either
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(nil)
	fails(t, cur, "only the poster", func() { ApproveWork(cross(cur), sub) }, "builder approve")
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	fails(t, cur, "only the builder", func() { ClaimPayout(cross(cur), sub) }, "poster claim payout")
	fails(t, cur, "only the builder", func() { SubmitWork(cross(cur), cl, link) }, "poster submit")
}

// Case 7: the poster cannot claim their own quest.
func TestPosterCannotClaim(cur realm, t *testing.T) {
	resetState()
	id := post(cur, alice, gnot, "mine")
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	fails(t, cur, "cannot claim their own quest", func() { ClaimQuest(cross(cur), id) }, "poster claim")
}

// Case 8: post with a wrong coin, several coins, no coins or too small a reward.
func TestPostCoins(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	cases := []struct {
		name string
		sent chain.Coins
		want string
	}{
		{"no coins", nil, ErrNoCoins},
		{"wrong denom", chain.Coins{{Denom: "uatom", Amount: 5 * gnot}}, ErrWrongDenom},
		{"two coins", chain.Coins{{Denom: "ugnot", Amount: 5 * gnot}, {Denom: "uatom", Amount: 1}}, ErrSeveralCoins},
		{"two ugnot entries", chain.Coins{{Denom: "ugnot", Amount: gnot}, {Denom: "ugnot", Amount: gnot}}, ErrSeveralCoins},
		{"below minimum", ugnot(MinReward - 1), ErrRewardTooLow},
		{"zero", ugnot(0), ErrRewardTooLow},
	}
	for _, c := range cases {
		testing.SetOriginSend(c.sent)
		fails(t, cur, c.want, func() { PostQuest(cross(cur), "title", "", 2_000) }, c.name)
	}
	testing.SetOriginSend(nil)

	// exactly the minimum works, and the stored reward is the amount sent
	id := post(cur, alice, MinReward, "minimum")
	uassert.Equal(t, MinReward, GetQuest(id).Reward)
	checkInvariants(t, "post coins")
}

// Rule 3: every function that does not take money refuses coins, even when the
// call would otherwise succeed.
func TestNoCoinsOnOtherCalls(cur realm, t *testing.T) {
	resetState()
	open := post(cur, alice, gnot, "open")
	cl := claimed(cur, gnot)
	sub := submitted(cur, gnot)
	one := ugnot(1)
	type call struct {
		who  address
		name string
		fn   func()
	}
	calls := []call{
		{bob, "ClaimQuest", func() { ClaimQuest(cross(cur), open) }},
		{alice, "CancelQuest", func() { CancelQuest(cross(cur), open) }},
		{bob, "SubmitWork", func() { SubmitWork(cross(cur), cl, link) }},
		{bob, "UnclaimQuest", func() { UnclaimQuest(cross(cur), cl) }},
		{alice, "ApproveWork", func() { ApproveWork(cross(cur), sub) }},
		{alice, "RejectWork", func() { RejectWork(cross(cur), sub, "no") }},
	}
	for _, c := range calls {
		testing.SetRealm(testing.NewUserRealm(c.who))
		testing.SetOriginSend(nil)
		testing.SetOriginSend(one)
		fails(t, cur, ErrCoinsNotTaken, c.fn, c.name+" with coins")
	}
	// the two time-gated moves, past their deadlines
	testing.SkipHeights(escrow.ReviewBlocks + 2_001)
	testing.SetRealm(testing.NewUserRealm(dave))
	testing.SetOriginSend(nil)
	testing.SetOriginSend(one)
	fails(t, cur, ErrCoinsNotTaken, func() { ReleaseQuest(cross(cur), cl) }, "ReleaseQuest with coins")
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(nil)
	testing.SetOriginSend(one)
	fails(t, cur, ErrCoinsNotTaken, func() { ClaimPayout(cross(cur), sub) }, "ClaimPayout with coins")
	testing.SetOriginSend(nil)

	// without coins the same calls succeed
	ClaimPayout(cross(cur), sub)
	testing.SetRealm(testing.NewUserRealm(dave))
	testing.SetOriginSend(nil)
	ReleaseQuest(cross(cur), cl)
	checkInvariants(t, "no coins")
}

// Case 9: a payout cannot happen twice.
func TestNoDoublePayout(cur realm, t *testing.T) {
	resetState()
	// approve twice, then approve -> claim payout
	a := submitted(cur, gnot)
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	ApproveWork(cross(cur), a)
	fails(t, cur, "not allowed in the quest's current state", func() { ApproveWork(cross(cur), a) }, "approve twice")
	testing.SkipHeights(escrow.ReviewBlocks + 1)
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(nil)
	fails(t, cur, "not allowed in the quest's current state", func() { ClaimPayout(cross(cur), a) }, "approve then claim payout")

	// claim payout twice, then claim payout -> approve
	b := submitted(cur, gnot)
	testing.SkipHeights(escrow.ReviewBlocks + 1)
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(nil)
	ClaimPayout(cross(cur), b)
	fails(t, cur, "not allowed in the quest's current state", func() { ClaimPayout(cross(cur), b) }, "claim payout twice")
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	fails(t, cur, "not allowed in the quest's current state", func() { ApproveWork(cross(cur), b) }, "claim payout then approve")

	// cancel twice
	c := post(cur, alice, gnot, "cancel twice")
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	CancelQuest(cross(cur), c)
	fails(t, cur, "not allowed in the quest's current state", func() { CancelQuest(cross(cur), c) }, "cancel twice")
	checkInvariants(t, "double payout")
}

// Case 10: cancel after Claimed (or Submitted) fails.
// Case 10: cancelling a Claimed or Submitted quest refunds nothing: it only
// marks the quest as closing.
func TestCancelAfterClaimOnlyCloses(cur realm, t *testing.T) {
	resetState()
	cl := claimed(cur, gnot)
	sub := submitted(cur, gnot)
	before := takeSnapshot()
	aliceBefore := bal(alice)
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	CancelQuest(cross(cur), cl)
	CancelQuest(cross(cur), sub)
	after := takeSnapshot()
	uassert.Equal(t, before.realm, after.realm, "no coins move on close")
	uassert.Equal(t, aliceBefore, bal(alice))
	uassert.True(t, before.totals == after.totals, "totals unchanged on close")
	uassert.True(t, GetQuest(cl).Closing)
	uassert.True(t, GetQuest(sub).Closing)
	uassert.Equal(t, escrow.Claimed.String(), GetQuest(cl).State.String())
	fails(t, cur, "already closing", func() { CancelQuest(cross(cur), cl) }, "close twice")
	testing.SetRealm(testing.NewUserRealm(carol))
	testing.SetOriginSend(nil)
	fails(t, cur, "only the poster", func() { CancelQuest(cross(cur), sub) }, "stranger close")
	checkInvariants(t, "close")
}

// The squatting attack from the security review: a squatter claims, the
// poster closes, the squatter holds until the work deadline; then anyone can
// end it, the poster is refunded exactly once and nobody can claim again.
func TestCloseStopsSquatting(cur realm, t *testing.T) {
	resetState()
	eve := testutils.TestAddress("qb_eve")
	mal := testutils.TestAddress("qb_mal")
	id := post(cur, alice, 5*gnot, "real task")
	testing.SetRealm(testing.NewUserRealm(eve))
	testing.SetOriginSend(nil)
	ClaimQuest(cross(cur), id)

	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	CancelQuest(cross(cur), id)
	uassert.False(t, containsID(allPages(OpenQuestIDs), id), "closing quest is not open")
	checkInvariants(t, "closed")

	d := GetQuest(id).WorkDeadline
	testing.SkipHeights(d - runtime.ChainHeight())
	testing.SetRealm(testing.NewUserRealm(mal))
	testing.SetOriginSend(nil)
	fails(t, cur, "work deadline has not passed", func() { ReleaseQuest(cross(cur), id) }, "release at the deadline")
	testing.SkipHeights(1)

	aliceBefore, malBefore, realmBefore := bal(alice), bal(mal), bal(realmAddr)
	totBefore := GetTotals()
	ReleaseQuest(cross(cur), id)
	uassert.Equal(t, aliceBefore+5*gnot, bal(alice), "poster refunded once")
	uassert.Equal(t, malBefore, bal(mal), "the caller gets nothing")
	uassert.Equal(t, realmBefore-5*gnot, bal(realmAddr))
	uassert.Equal(t, escrow.Cancelled.String(), GetQuest(id).State.String())
	uassert.Equal(t, totBefore.Refunded+5*gnot, GetTotals().Refunded)
	uassert.Equal(t, totBefore.OpenQuests, GetTotals().OpenQuests)
	uassert.False(t, containsID(allPages(OpenQuestIDs), id))
	fails(t, cur, "not allowed in the quest's current state", func() { ClaimQuest(cross(cur), id) }, "re-claim after close")
	fails(t, cur, "not allowed in the quest's current state", func() { ReleaseQuest(cross(cur), id) }, "release twice")
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	fails(t, cur, "not allowed in the quest's current state", func() { CancelQuest(cross(cur), id) }, "cancel after refund")
	checkInvariants(t, "squat released")
}

func TestCloseThenUnclaim(cur realm, t *testing.T) {
	resetState()
	id := claimed(cur, 3*gnot)
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	CancelQuest(cross(cur), id)
	aliceBefore := bal(alice)
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(nil)
	UnclaimQuest(cross(cur), id)
	uassert.Equal(t, aliceBefore+3*gnot, bal(alice))
	uassert.Equal(t, escrow.Cancelled.String(), GetQuest(id).State.String())
	uassert.False(t, containsID(allPages(OpenQuestIDs), id))
	checkInvariants(t, "close then unclaim")
}

func TestCloseThenReject(cur realm, t *testing.T) {
	resetState()
	id := submitted(cur, 4*gnot)
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	CancelQuest(cross(cur), id)
	aliceBefore, bobBefore := bal(alice), bal(bob)
	RejectWork(cross(cur), id, "not what I asked")
	uassert.Equal(t, aliceBefore+4*gnot, bal(alice))
	uassert.Equal(t, bobBefore, bal(bob))
	q := GetQuest(id)
	uassert.Equal(t, escrow.Cancelled.String(), q.State.String())
	uassert.Equal(t, 1, q.RejectCount)
	uassert.False(t, containsID(allPages(OpenQuestIDs), id))
	checkInvariants(t, "close then reject")
}

// While closing, the builder keeps every right.
func TestCloseStillPaysBuilder(cur realm, t *testing.T) {
	resetState()
	a := claimed(cur, 2*gnot)
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	CancelQuest(cross(cur), a)
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(nil)
	SubmitWork(cross(cur), a, link)
	bobBefore := bal(bob)
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	ApproveWork(cross(cur), a)
	uassert.Equal(t, bobBefore+2*gnot, bal(bob), "approve while closing pays the builder")

	b := submitted(cur, 3*gnot)
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	CancelQuest(cross(cur), b)
	testing.SkipHeights(escrow.ReviewBlocks + 1)
	bobBefore = bal(bob)
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(nil)
	ClaimPayout(cross(cur), b)
	uassert.Equal(t, bobBefore+3*gnot, bal(bob), "timeout payout while closing pays the builder")
	checkInvariants(t, "close still pays")
}

// The timeout rule, documented: a builder who submits anything is paid after
// the review window if the poster does nothing; a reject at the last block of
// the window prevents it.
func TestJunkSubmissionTimeout(cur realm, t *testing.T) {
	resetState()
	id := claimed(cur, 5*gnot)
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(nil)
	SubmitWork(cross(cur), id, "https://x")
	testing.SkipHeights(GetQuest(id).ReviewDeadline - runtime.ChainHeight() + 1)
	bobBefore := bal(bob)
	ClaimPayout(cross(cur), id)
	uassert.Equal(t, bobBefore+5*gnot, bal(bob), "silent poster: builder paid")

	id2 := claimed(cur, 5*gnot)
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(nil)
	SubmitWork(cross(cur), id2, "https://x")
	testing.SkipHeights(GetQuest(id2).ReviewDeadline - runtime.ChainHeight())
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	RejectWork(cross(cur), id2, "junk")
	testing.SkipHeights(1)
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(nil)
	fails(t, cur, "not allowed in the quest's current state", func() { ClaimPayout(cross(cur), id2) }, "payout after reject")
	checkInvariants(t, "junk timeout")
}

// Case 11: text over the limits and bad links fail at realm level.
func TestTextLimits(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	bad := []struct{ title, details, want string }{
		{"", "", "title is empty"},
		{strings.Repeat("a", escrow.MaxTitleLen+1), "", "title is too long"},
		{"two\nlines", "", "control characters"},
		{"ok", strings.Repeat("d", escrow.MaxDetailsLen+1), "details are too long"},
	}
	for _, c := range bad {
		testing.SetOriginSend(ugnot(gnot))
		fails(t, cur, c.want, func() { PostQuest(cross(cur), c.title, c.details, 2_000) }, "post: "+c.want)
	}
	testing.SetOriginSend(ugnot(gnot))
	fails(t, cur, "work window is below", func() { PostQuest(cross(cur), "t", "", escrow.MinWorkBlocks-1) }, "work window low")
	fails(t, cur, "work window is above", func() { PostQuest(cross(cur), "t", "", escrow.MaxWorkBlocks+1) }, "work window high")
	testing.SetOriginSend(nil)

	cl := claimed(cur, gnot)
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(nil)
	for _, l := range []string{"http://example.com", "example.com", "https://", "https://a b", "https://" + strings.Repeat("a", escrow.MaxLinkLen)} {
		fails(t, cur, "escrow: work link", func() { SubmitWork(cross(cur), cl, l) }, "link "+l)
	}
	SubmitWork(cross(cur), cl, link)
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	fails(t, cur, "reject reason is too long", func() { RejectWork(cross(cur), cl, strings.Repeat("r", escrow.MaxReasonLen+1)) }, "long reason")
	fails(t, cur, "reject reason is empty", func() { RejectWork(cross(cur), cl, "") }, "empty reason")
}

// Non-user callers (other realms, maketx run scripts) are refused everywhere.
func TestCodeRealmRefused(cur realm, t *testing.T) {
	resetState()
	open := post(cur, alice, gnot, "open")
	cl := claimed(cur, gnot)
	sub := submitted(cur, gnot)
	callers := []runtime.Realm{
		testing.NewCodeRealm("gno.land/r/evil/proxy"),
		// a `gnokey maketx run` script runs as an ephemeral realm
		runtime.NewRealm(alice, "gno.land/e/"+alice.String()+"/run"),
	}
	for _, c := range callers {
		testing.SetRealm(c)
		testing.SetOriginSend(ugnot(gnot))
		fails(t, cur, ErrNotUserCall, func() { PostQuest(cross(cur), "t", "", 2_000) }, "PostQuest")
		testing.SetOriginSend(nil)
		fails(t, cur, ErrNotUserCall, func() { ClaimQuest(cross(cur), open) }, "ClaimQuest")
		fails(t, cur, ErrNotUserCall, func() { CancelQuest(cross(cur), open) }, "CancelQuest")
		fails(t, cur, ErrNotUserCall, func() { SubmitWork(cross(cur), cl, link) }, "SubmitWork")
		fails(t, cur, ErrNotUserCall, func() { UnclaimQuest(cross(cur), cl) }, "UnclaimQuest")
		fails(t, cur, ErrNotUserCall, func() { ReleaseQuest(cross(cur), cl) }, "ReleaseQuest")
		fails(t, cur, ErrNotUserCall, func() { ApproveWork(cross(cur), sub) }, "ApproveWork")
		fails(t, cur, ErrNotUserCall, func() { RejectWork(cross(cur), sub, "no") }, "RejectWork")
		fails(t, cur, ErrNotUserCall, func() { ClaimPayout(cross(cur), sub) }, "ClaimPayout")
	}
}

// An unknown quest id panics cleanly on every function that takes an id.
func TestUnknownID(cur realm, t *testing.T) {
	resetState()
	missing := GetTotals().Quests + 1000
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	fails(t, cur, ErrUnknownQuest, func() { ClaimQuest(cross(cur), missing) }, "ClaimQuest")
	fails(t, cur, ErrUnknownQuest, func() { UnclaimQuest(cross(cur), missing) }, "UnclaimQuest")
	fails(t, cur, ErrUnknownQuest, func() { ReleaseQuest(cross(cur), missing) }, "ReleaseQuest")
	fails(t, cur, ErrUnknownQuest, func() { SubmitWork(cross(cur), missing, link) }, "SubmitWork")
	fails(t, cur, ErrUnknownQuest, func() { ApproveWork(cross(cur), missing) }, "ApproveWork")
	fails(t, cur, ErrUnknownQuest, func() { RejectWork(cross(cur), missing, "no") }, "RejectWork")
	fails(t, cur, ErrUnknownQuest, func() { CancelQuest(cross(cur), missing) }, "CancelQuest")
	fails(t, cur, ErrUnknownQuest, func() { ClaimPayout(cross(cur), missing) }, "ClaimPayout")
	uassert.PanicsContains(t, cur, ErrUnknownQuest, func() { GetQuest(missing) }, "GetQuest")
	uassert.PanicsContains(t, cur, ErrUnknownQuest, func() { GetQuest(0) }, "GetQuest(0)")
}

// Read functions return copies: changing a returned value or slice does not
// change stored state. The exported API (see questmaster.gno) has no function
// or variable that returns *escrow.Quest or an avl tree; package variables
// are all unexported.
func TestNoPointerLeak(cur realm, t *testing.T) {
	resetState()
	id := post(cur, alice, gnot, "original title")
	v := GetQuest(id)
	v.Title = "changed"
	v.Reward = 1
	v.State = escrow.Paid
	uassert.Equal(t, "original title", GetQuest(id).Title)
	uassert.Equal(t, gnot, GetQuest(id).Reward)
	uassert.Equal(t, escrow.Open.String(), GetQuest(id).State.String())

	ids := QuestIDsByPoster(alice, 0, 1)
	ids[0] = 999999
	uassert.Equal(t, id, QuestIDsByPoster(alice, 0, 1)[0])

	tot := GetTotals()
	tot.Locked = 0
	uassert.NotEqual(t, int64(0), GetTotals().Locked)
}

// Lists: newest first, offset, and a hard cap of MaxPageSize per call.
func TestLists(cur realm, t *testing.T) {
	resetState()
	var mine []uint64
	for i := 0; i < MaxPageSize+5; i++ {
		mine = append(mine, post(cur, dave, gnot, "bulk"))
	}
	first := QuestIDsByPoster(dave, 0, 1000)
	uassert.Equal(t, MaxPageSize, len(first), "capped")
	uassert.Equal(t, mine[len(mine)-1], first[0], "newest first")
	second := QuestIDsByPoster(dave, MaxPageSize, 1000)
	uassert.Equal(t, 5, len(second))
	uassert.Equal(t, mine[0], second[4], "oldest last")
	uassert.Equal(t, 3, len(QuestIDsByPoster(dave, 0, 3)))
	uassert.Equal(t, MaxPageSize, len(QuestIDsByPoster(dave, -5, 0)), "bad offset/limit fall back to defaults")
	uassert.Equal(t, 0, len(QuestIDsByPoster(dave, 10_000, 10)))
	uassert.Equal(t, MaxPageSize+5, CountByPoster(dave))
	uassert.Equal(t, 0, len(QuestIDsByBuilder(testutils.TestAddress("nobody"), 0, 10)))
	uassert.Equal(t, 0, CountByBuilder(testutils.TestAddress("nobody")))
	uassert.Equal(t, MaxPageSize, len(AllQuestIDs(0, 0)))
	uassert.Equal(t, GetTotals().Quests, AllQuestIDs(0, 1)[0])

	// tidy up so later tests see fewer open quests
	testing.SetRealm(testing.NewUserRealm(dave))
	testing.SetOriginSend(nil)
	for _, id := range mine {
		CancelQuest(cross(cur), id)
	}
	checkInvariants(t, "lists")
}

// Case 12: a long mixed run over many quests and users. After every step the
// realm balance equals the sum of rewards still held, equals the locked
// total, and posted == locked + paid + refunded. Coins are conserved across
// users and the realm.
func TestMixedRunInvariant(cur realm, t *testing.T) {
	resetState()
	users := []address{alice, bob, carol, dave}
	start := int64(0)
	for _, u := range users {
		start += bal(u)
	}
	start += bal(realmAddr)
	issued := int64(0)

	seed := uint64(42)
	rnd := func(n int) int {
		seed = seed*6364136223846793005 + 1442695040888963407
		return int((seed >> 33) % uint64(n))
	}
	var ids []uint64
	done := map[string]int{}

	for step := 0; step < 300; step++ {
		var id uint64
		var active []uint64
		for _, x := range ids {
			if !GetQuest(x).State.IsFinal() {
				active = append(active, x)
			}
		}
		if len(active) > 0 && rnd(8) != 0 {
			id = active[rnd(len(active))] // mostly quests still in play
		} else if len(ids) > 0 {
			id = ids[rnd(len(ids))] // sometimes a finished one (must fail)
		}
		action := rnd(10)
		if len(active) < 3 || action == 0 {
			reward := gnot + int64(rnd(5))*250_000
			ids = append(ids, post(cur, users[rnd(len(users))], reward, "mixed"))
			issued += reward
			done["post"]++
			checkInvariants(t, "mixed post")
			continue
		}
		q := GetQuest(id)
		// pick a legal actor most of the time, a random one otherwise
		poster, builder := q.Poster, q.Builder
		pick := func(want address) address {
			if rnd(8) == 0 || want == "" {
				return users[rnd(len(users))]
			}
			return want
		}
		var name string
		var fn func()
		switch q.State {
		case escrow.Open:
			if rnd(4) == 0 {
				testing.SetRealm(testing.NewUserRealm(pick(poster)))
				testing.SetOriginSend(nil)
				name, fn = "cancel", func() { CancelQuest(cross(cur), id) }
			} else {
				testing.SetRealm(testing.NewUserRealm(users[rnd(len(users))]))
				testing.SetOriginSend(nil)
				name, fn = "claim", func() { ClaimQuest(cross(cur), id) }
			}
		case escrow.Claimed:
			switch rnd(5) {
			case 4:
				testing.SetRealm(testing.NewUserRealm(pick(poster)))
				testing.SetOriginSend(nil)
				name, fn = "close", func() { CancelQuest(cross(cur), id) }
			case 0:
				testing.SetRealm(testing.NewUserRealm(pick(builder)))
				testing.SetOriginSend(nil)
				name, fn = "unclaim", func() { UnclaimQuest(cross(cur), id) }
			case 1:
				testing.SkipHeights(q.WorkDeadline - runtime.ChainHeight() + 1)
				testing.SetRealm(testing.NewUserRealm(users[rnd(len(users))]))
				testing.SetOriginSend(nil)
				name, fn = "release", func() { ReleaseQuest(cross(cur), id) }
			default:
				testing.SetRealm(testing.NewUserRealm(pick(builder)))
				testing.SetOriginSend(nil)
				name, fn = "submit", func() { SubmitWork(cross(cur), id, link) }
			}
		case escrow.Submitted:
			switch k := rnd(5); {
			case k == 4:
				testing.SetRealm(testing.NewUserRealm(pick(poster)))
				testing.SetOriginSend(nil)
				name, fn = "close", func() { CancelQuest(cross(cur), id) }
			case k == 0 || (k < 3 && runtime.ChainHeight() > q.ReviewDeadline):
				testing.SetRealm(testing.NewUserRealm(pick(poster)))
				testing.SetOriginSend(nil)
				name, fn = "approve", func() { ApproveWork(cross(cur), id) }
			case k < 3:
				testing.SetRealm(testing.NewUserRealm(pick(poster)))
				testing.SetOriginSend(nil)
				name, fn = "reject", func() { RejectWork(cross(cur), id, "again") }
			default:
				testing.SkipHeights(q.ReviewDeadline - runtime.ChainHeight() + 1)
				testing.SetRealm(testing.NewUserRealm(pick(builder)))
				testing.SetOriginSend(nil)
				name, fn = "timeout", func() { ClaimPayout(cross(cur), id) }
			}
		default:
			testing.SetRealm(testing.NewUserRealm(pick(poster)))
			testing.SetOriginSend(nil)
			name, fn = "final-cancel", func() { CancelQuest(cross(cur), id) }
		}
		before := takeSnapshot()
		r := revive(fn)
		if r != nil {
			sameSnapshot(t, before, takeSnapshot(), "failed "+name)
			done["failed"]++
		} else {
			done[name]++
			if q.Closing && (name == "unclaim" || name == "release" || name == "reject") {
				done["closed-refund"]++
			}
		}
		checkInvariants(t, name)

		total := bal(realmAddr)
		for _, u := range users {
			total += bal(u)
		}
		if total != start+issued {
			t.Fatalf("step %d %s: coins not conserved: %d != %d", step, name, total, start+issued)
		}
	}
	for _, k := range []string{"post", "claim", "cancel", "unclaim", "release", "submit", "approve", "reject", "timeout", "failed", "close", "closed-refund"} {
		if done[k] == 0 {
			t.Errorf("mixed run never did %q: %v", k, done)
		}
	}
	println("mixed run moves:", done)
}

func containsID(ids []uint64, id uint64) bool {
	for _, x := range ids {
		if x == id {
			return true
		}
	}
	return false
}
