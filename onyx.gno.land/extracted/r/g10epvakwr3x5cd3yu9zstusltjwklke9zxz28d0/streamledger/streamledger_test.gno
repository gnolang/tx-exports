package streamledger

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"strings"
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

func resetRealmForTest() {
	initState()
}

// fundAndCreate simulates a direct EOA MsgCall with attached ugnot.
func fundAndCreate(
	cur realm,
	sender address,
	recipient address,
	amount int64,
	startHeight int64,
	cliffHeight int64,
	endHeight int64,
	cancellable bool,
	label string,
) uint64 {
	pkgAddr := chain.PackageAddress(realmPkgPath)
	coins := chain.NewCoins(chain.NewCoin(DenomUGNOT, amount))
	testing.IssueCoins(pkgAddr, coins)
	testing.SetRealm(testing.NewUserRealm(sender))
	testing.SetOriginSend(coins)
	return CreateStream(cross(cur), recipient, startHeight, cliffHeight, endHeight, cancellable, label)
}

func TestCreateStreamAndEscrowBalance(cur realm, t *testing.T) {
	defer resetRealmForTest()

	alice := testutils.TestAddress("alice_create")
	bob := testutils.TestAddress("bob_create")
	pkgAddr := chain.PackageAddress(realmPkgPath)
	roBanker := banker.NewReadonlyBanker()
	balBefore := roBanker.GetCoin(pkgAddr, DenomUGNOT)

	now := runtime.ChainHeight()
	id := fundAndCreate(cur, alice, bob, 5_000_000, now, now+10, now+100, true, "Core Grant")
	uassert.Equal(t, uint64(1), id)

	balAfter := roBanker.GetCoin(pkgAddr, DenomUGNOT)
	uassert.Equal(t, balBefore+5_000_000, balAfter)

	s := mustGetStream(id)
	uassert.Equal(t, alice, s.Sender)
	uassert.Equal(t, bob, s.Recipient)
	uassert.Equal(t, int64(5_000_000), s.TotalAmount)
	uassert.Equal(t, int64(0), s.Withdrawn)
	uassert.Equal(t, StatusActive, s.Status)
	uassert.Equal(t, "Core Grant", s.Label)
	uassert.True(t, s.Cancellable)

	// Invalid creations must abort
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin(DenomUGNOT, 1_000_000)))
	uassert.AbortsWithMessage(t, cur, "StreamLedger: sender and recipient must differ", func() {
		CreateStream(cross(cur), alice, now, now, now+10, true, "self")
	})
	uassert.AbortsWithMessage(t, cur, "StreamLedger: invalid recipient address", func() {
		CreateStream(cross(cur), "", now, now, now+10, true, "empty")
	})
	testing.SetOriginSend(chain.Coins{})
	uassert.AbortsWithMessage(t, cur, "StreamLedger: must send positive ugnot only", func() {
		CreateStream(cross(cur), bob, now, now, now+10, true, "no coins")
	})
}

func TestCliffEnforcementAndLifecycleWithdrawals(cur realm, t *testing.T) {
	defer resetRealmForTest()

	alice := testutils.TestAddress("alice_cliff")
	bob := testutils.TestAddress("bob_cliff")
	roBanker := banker.NewReadonlyBanker()
	bobStartBal := roBanker.GetCoin(bob, DenomUGNOT)

	start := runtime.ChainHeight()
	cliff := start + 25
	end := start + 100
	const total = int64(10_000_000)

	id := fundAndCreate(cur, alice, bob, total, start, cliff, end, true, "Cliff Vesting")

	// Before cliff (height = start + 24): 0 withdrawable -> must abort
	testing.SkipHeights(24)
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsWithMessage(t, cur, "StreamLedger: nothing withdrawable at current height", func() {
		Withdraw(cross(cur), id)
	})

	// At exact cliff (height = start + 25): 25% = 2_500_000 ugnot unlocks
	testing.SkipHeights(1)
	testing.SetRealm(testing.NewUserRealm(bob))
	claimed1 := Withdraw(cross(cur), id)
	uassert.Equal(t, int64(2_500_000), claimed1)
	uassert.Equal(t, bobStartBal+2_500_000, roBanker.GetCoin(bob, DenomUGNOT))
	uassert.Equal(t, StatusActive, mustGetStream(id).Status)

	// Immediate second withdraw at same height has 0 withdrawable
	uassert.AbortsWithMessage(t, cur, "StreamLedger: nothing withdrawable at current height", func() {
		Withdraw(cross(cur), id)
	})

	// Advance +35 blocks -> height = start + 60 (60% total vested = 6_000_000 -> 3_500_000 newly claimable)
	testing.SkipHeights(35)
	testing.SetRealm(testing.NewUserRealm(bob))
	claimed2 := Withdraw(cross(cur), id)
	uassert.Equal(t, int64(3_500_000), claimed2)
	uassert.Equal(t, bobStartBal+6_000_000, roBanker.GetCoin(bob, DenomUGNOT))

	// Advance past end (+50 blocks -> height = start + 110): remaining 4_000_000 unlocks & completes
	testing.SkipHeights(50)
	testing.SetRealm(testing.NewUserRealm(bob))
	claimed3 := Withdraw(cross(cur), id)
	uassert.Equal(t, int64(4_000_000), claimed3)
	uassert.Equal(t, bobStartBal+total, roBanker.GetCoin(bob, DenomUGNOT))

	s := mustGetStream(id)
	uassert.Equal(t, StatusCompleted, s.Status)
	uassert.Equal(t, total, s.Withdrawn)
	uassert.Equal(t, int64(0), activeCount)
	uassert.Equal(t, int64(1), completedCount)

	// Cannot withdraw from completed stream
	uassert.AbortsWithMessage(t, cur, "StreamLedger: stream is not active", func() {
		Withdraw(cross(cur), id)
	})
}

func TestUnauthorizedWithdrawAndCancel(cur realm, t *testing.T) {
	defer resetRealmForTest()

	alice := testutils.TestAddress("alice_auth")
	bob := testutils.TestAddress("bob_auth")
	mallory := testutils.TestAddress("mallory_auth")

	start := runtime.ChainHeight()
	id := fundAndCreate(cur, alice, bob, 4_000_000, start, start, start+100, true, "Auth Test")

	testing.SkipHeights(50)

	// Sender (alice) cannot withdraw
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsWithMessage(t, cur, "StreamLedger: only recipient can withdraw", func() {
		Withdraw(cross(cur), id)
	})

	// Random third party (mallory) cannot withdraw or cancel
	testing.SetRealm(testing.NewUserRealm(mallory))
	uassert.AbortsWithMessage(t, cur, "StreamLedger: only recipient can withdraw", func() {
		Withdraw(cross(cur), id)
	})
	uassert.AbortsWithMessage(t, cur, "StreamLedger: only sender can cancel", func() {
		CancelStream(cross(cur), id)
	})

	// Recipient (bob) cannot cancel
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsWithMessage(t, cur, "StreamLedger: only sender can cancel", func() {
		CancelStream(cross(cur), id)
	})
}

func TestNonCancellableStreamRejection(cur realm, t *testing.T) {
	defer resetRealmForTest()

	alice := testutils.TestAddress("alice_noncan")
	bob := testutils.TestAddress("bob_noncan")

	start := runtime.ChainHeight()
	id := fundAndCreate(cur, alice, bob, 2_000_000, start, start, start+100, false, "Irrevocable Grant")

	testing.SkipHeights(20)
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsWithMessage(t, cur, "StreamLedger: stream is non-cancellable", func() {
		CancelStream(cross(cur), id)
	})
}

func TestCancelStreamZeroDustConservation(cur realm, t *testing.T) {
	defer resetRealmForTest()

	alice := testutils.TestAddress("alice_cancel")
	bob := testutils.TestAddress("bob_cancel")
	pkgAddr := chain.PackageAddress(realmPkgPath)
	roBanker := banker.NewReadonlyBanker()

	aliceStart := roBanker.GetCoin(alice, DenomUGNOT)
	bobStart := roBanker.GetCoin(bob, DenomUGNOT)
	pkgStart := roBanker.GetCoin(pkgAddr, DenomUGNOT)

	// Prime non-divisible total across 97 blocks
	const total = int64(1_000_003)
	start := runtime.ChainHeight()
	id := fundAndCreate(cur, alice, bob, total, start, start+10, start+97, true, "Zero Dust Stream")

	// Recipient withdraws partially at height +30
	testing.SkipHeights(30)
	testing.SetRealm(testing.NewUserRealm(bob))
	firstClaim := Withdraw(cross(cur), id)
	uassert.True(t, firstClaim > 0)

	// Sender cancels at height +63 (33 blocks later)
	testing.SkipHeights(33)
	testing.SetRealm(testing.NewUserRealm(alice))
	toRec, toSnd := CancelStream(cross(cur), id)

	// Strict zero-dust conservation: firstClaim + toRec + toSnd == total
	uassert.Equal(t, total, firstClaim+toRec+toSnd)

	// Verify exact bank balances moved
	uassert.Equal(t, bobStart+firstClaim+toRec, roBanker.GetCoin(bob, DenomUGNOT))
	uassert.Equal(t, aliceStart+toSnd, roBanker.GetCoin(alice, DenomUGNOT))
	uassert.Equal(t, pkgStart, roBanker.GetCoin(pkgAddr, DenomUGNOT))

	s := mustGetStream(id)
	uassert.Equal(t, StatusCancelled, s.Status)
	uassert.Equal(t, firstClaim+toRec, s.Withdrawn)
	uassert.Equal(t, toSnd, s.Refunded)
	uassert.Equal(t, int64(0), activeCount)
	uassert.Equal(t, int64(1), cancelledCount)

	// Second cancel or withdraw must abort
	uassert.AbortsWithMessage(t, cur, "StreamLedger: stream is not active", func() {
		CancelStream(cross(cur), id)
	})
}

func TestTopUpStream(cur realm, t *testing.T) {
	defer resetRealmForTest()

	alice := testutils.TestAddress("alice_topup")
	bob := testutils.TestAddress("bob_topup")
	pkgAddr := chain.PackageAddress(realmPkgPath)
	roBanker := banker.NewReadonlyBanker()
	bobStart := roBanker.GetCoin(bob, DenomUGNOT)

	start := runtime.ChainHeight()
	id := fundAndCreate(cur, alice, bob, 2_000_000, start, start, start+100, true, "Retainer")

	// Advance 50 blocks, unauthorized user cannot top up
	testing.SkipHeights(50)
	topUpCoins := chain.NewCoins(chain.NewCoin(DenomUGNOT, 3_000_000))
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(topUpCoins)
	uassert.AbortsWithMessage(t, cur, "StreamLedger: only sender can top up", func() {
		TopUpStream(cross(cur), id)
	})

	// Sender tops up +3_000_000 -> total becomes 5_000_000
	testing.IssueCoins(pkgAddr, topUpCoins)
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(topUpCoins)
	TopUpStream(cross(cur), id)
	uassert.Equal(t, int64(5_000_000), mustGetStream(id).TotalAmount)

	// At 50% progress, recipient can withdraw 2_500_000
	testing.SetRealm(testing.NewUserRealm(bob))
	claimed := Withdraw(cross(cur), id)
	uassert.Equal(t, int64(2_500_000), claimed)

	// At/after end height, TopUpStream must abort
	testing.SkipHeights(50)
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(topUpCoins)
	uassert.AbortsWithMessage(t, cur, "StreamLedger: cannot top up stream at or after end height", func() {
		TopUpStream(cross(cur), id)
	})

	// Final withdraw claims remaining 2_500_000
	testing.SetRealm(testing.NewUserRealm(bob))
	finalClaim := Withdraw(cross(cur), id)
	uassert.Equal(t, int64(2_500_000), finalClaim)
	uassert.Equal(t, bobStart+5_000_000, roBanker.GetCoin(bob, DenomUGNOT))
	uassert.Equal(t, StatusCompleted, mustGetStream(id).Status)
}

func TestRenderAndJSONEndpoints(cur realm, t *testing.T) {
	defer resetRealmForTest()

	alice := testutils.TestAddress("alice_render")
	bob := testutils.TestAddress("bob_render")

	// Empty state render
	emptyHome := Render("")
	uassert.True(t, strings.Contains(emptyHome, "# StreamLedger"))
	uassert.True(t, strings.Contains(emptyHome, "No streams created yet"))

	start := runtime.ChainHeight()
	id := fundAndCreate(cur, alice, bob, 12_500_000, start, start+10, start+100, true, "Audit Bounty")
	testing.SkipHeights(50)

	// Dashboard render
	home := Render("")
	uassert.True(t, strings.Contains(home, "12.500000 GNOT"))
	uassert.True(t, strings.Contains(home, "Audit Bounty"))
	uassert.True(t, strings.Contains(home, "50.0%"))
	uassert.True(t, strings.Contains(home, ":stream/1"))

	// Stream detail render
	detail := Render("stream/1")
	uassert.True(t, strings.Contains(detail, "# Stream #1 — Audit Bounty"))
	uassert.True(t, strings.Contains(detail, "6.250000 GNOT")) // 50% of 12.5 GNOT
	uassert.True(t, strings.Contains(detail, "$help&func=Withdraw"))
	uassert.True(t, strings.Contains(detail, "$help&func=CancelStream"))
	uassert.True(t, strings.Contains(detail, "Zero-Dust Conservation Check"))

	// Address portfolio render (both recipient and sender)
	bobPage := Render("addr/" + bob.String())
	uassert.True(t, strings.Contains(bobPage, "Incoming Streams (1)"))
	uassert.True(t, strings.Contains(bobPage, "6.250000 GNOT"))

	alicePage := Render("addr/" + alice.String())
	uassert.True(t, strings.Contains(alicePage, "Outgoing Streams (1)"))
	uassert.True(t, strings.Contains(alicePage, "Audit Bounty"))

	// Unknown route & missing stream
	uassert.True(t, strings.Contains(Render("stream/999"), "Not Found"))
	uassert.True(t, strings.Contains(Render("unknown/path"), "Not Found"))

	// JSON endpoints
	streamJSON := GetStreamJSON(id)
	uassert.True(t, strings.Contains(streamJSON, `"id":1`))
	uassert.True(t, strings.Contains(streamJSON, `"totalAmountUgnot":12500000`))
	uassert.True(t, strings.Contains(streamJSON, `"vestedUgnot":6250000`))
	uassert.True(t, strings.Contains(streamJSON, `"withdrawableUgnot":6250000`))
	uassert.True(t, strings.Contains(streamJSON, `"progressBps":5000`))
	uassert.True(t, strings.Contains(streamJSON, `"status":"ACTIVE"`))

	uassert.Equal(t, `{"error":"stream not found"}`, GetStreamJSON(999))

	statsJSON := StatsJSON()
	uassert.True(t, strings.Contains(statsJSON, `"totalStreams":1`))
	uassert.True(t, strings.Contains(statsJSON, `"activeStreams":1`))
	uassert.True(t, strings.Contains(statsJSON, `"tvlUgnot":12500000`))
}
