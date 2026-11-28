// Tests for the Tavern Odds market lifecycle.
//
// These tests assert BEHAVIOUR, not exact LMSR values, so they must pass
// against the real fixed-point LMSR — no assertion depends on the
// pricing curve, except the 1:1 redemption (1 winning share = 1 ugnot),
// which is a property of the market, not of the pricing.
//
// Test clock: gno test runs with a fixed block time,
// 2009-02-13T23:31:30Z (unix 1234567890). Tests set it explicitly via
// setTime and advance it the same way. Coins sent with a call are only
// an envelope record in tests (testing.SetOriginSend); the realm's
// spendable balance is funded separately with testing.IssueCoins,
// mirroring what `-send` credits on-chain.
//
// IMPORTANT: testing.SetRealm must be called DIRECTLY from the test
// function, never via a helper. The realm override attaches to the
// frame SetRealm is called from and mutates that frame's `cur`; called
// from a helper it overrides the helper's frame and the test's `cur`
// keeps the tavernodds code realm, so every EOA-guarded call panics.
// Helpers below therefore never touch the realm — each test sets its
// caller inline before calling them.
package tavernodds

import (
	"chain"
	"chain/banker"
	"strings"
	"testing"
	"time"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

// testNow is the fixed gno-test block time (2009-02-13T23:31:30Z).
const testNow = 1234567890

const testB = 1000000 // liquidity b used by most tests

func resetState() {
	markets = nil
	nextMarketID = 0
	nextTokenID = 0
}

func setTime(unix int64) {
	ctx := testing.GetContext()
	ctx.Time = time.Unix(unix, 0)
	testing.SetContext(ctx)
}

func sendCoins(amount int64) {
	testing.SetOriginSend(chain.Coins{{Denom: ugnotDenom, Amount: amount}})
}

// fundRealm credits the realm's spendable ugnot balance, simulating
// what `-send` receipts do on-chain.
func fundRealm(amount int64) {
	testing.IssueCoins(realmAddr(), chain.Coins{{Denom: ugnotDenom, Amount: amount}})
}

func traderBalance(addr address) int64 {
	return banker.NewReadonlyBanker().GetCoin(addr, ugnotDenom)
}

func minSeed() int64 {
	return lmsrMinSeed(testB)
}

// createTestMarket creates a market closing 1h after testNow, funded
// with the given seed (must be >= minSeed), and funds the realm with
// the seed. Caller must have set the creator realm first (testing.SetRealm, inline).
// Returns the market ID.
func createTestMarket(cur realm, resolver address, seed int64) uint64 {
	sendCoins(seed)
	id := CreateMarket(cross(cur), "Will it rain tomorrow?", testNow+3600, testB, resolver)
	fundRealm(seed)
	return id
}

// buyTestShares quotes, sends, buys, and funds the realm with the cost.
// Caller must have set the buyer realm first (testing.SetRealm, inline).
func buyTestShares(cur realm, id uint64, outcome int, shares int64) int64 {
	cost := QuoteBuy(id, outcome, shares)
	sendCoins(cost)
	return Buy(cross(cur), id, outcome, shares, cost)
}

func TestCreateMarket(cur realm, t *testing.T) {
	defer resetState()
	setTime(testNow)
	creator := testutils.TestAddress("creator1")
	resolver := testutils.TestAddress("resolver1")

	// Happy path with the exact minimum seed.
	testing.SetRealm(testing.NewUserRealm(creator))
	testing.SetOriginSend(chain.Coins{})
	sendCoins(minSeed())
	id := CreateMarket(cross(cur), "Will it rain tomorrow?", testNow+3600, testB, resolver)
	uassert.Equal(t, uint64(1), id)
	v := GetMarket(id)
	uassert.Equal(t, "Will it rain tomorrow?", v.Question)
	uassert.Equal(t, creator, v.Creator)
	uassert.Equal(t, resolver, v.Resolver)
	uassert.Equal(t, int64(testNow+3600), v.CloseTime)
	uassert.Equal(t, int64(testB), v.LiquidityB)
	uassert.Equal(t, int64(0), v.QYes)
	uassert.Equal(t, int64(0), v.QNo)
	uassert.False(t, v.Resolved)
	uassert.Equal(t, OutcomeUnresolved, v.Outcome)
	uassert.Equal(t, minSeed(), v.SeededCollateral)
	uassert.Equal(t, int64(5000), v.YesPriceBps)
	uassert.Equal(t, int64(5000), v.NoPriceBps)
	uassert.Equal(t, 1, MarketCount())

	// Bad inputs, each must abort with the exact panic message.
	// (AbortsWithMessage matches exactly, not by substring.)
	testing.SetRealm(testing.NewUserRealm(creator))
	testing.SetOriginSend(chain.Coins{})
	sendCoins(minSeed())
	uassert.AbortsWithMessage(t, cur, "question must be 1..128 bytes", func() {
		CreateMarket(cross(cur), "", testNow+3600, testB, resolver)
	})
	uassert.AbortsWithMessage(t, cur, "question must be 1..128 bytes", func() {
		CreateMarket(cross(cur), strings.Repeat("x", 129), testNow+3600, testB, resolver)
	})
	uassert.AbortsWithMessage(t, cur, "close time must be in the future", func() {
		CreateMarket(cross(cur), "Q?", testNow, testB, resolver)
	})
	uassert.AbortsWithMessage(t, cur, "close time must be in the future", func() {
		CreateMarket(cross(cur), "Q?", testNow-1, testB, resolver)
	})
	uassert.AbortsWithMessage(t, cur, "liquidity b out of range", func() {
		CreateMarket(cross(cur), "Q?", testNow+3600, MinB-1, resolver)
	})
	uassert.AbortsWithMessage(t, cur, "liquidity b out of range", func() {
		CreateMarket(cross(cur), "Q?", testNow+3600, MaxB+1, resolver)
	})
	uassert.AbortsWithMessage(t, cur, "resolver address invalid", func() {
		CreateMarket(cross(cur), "Q?", testNow+3600, testB, address(""))
	})
	// Seed one ugnot short of the minimum.
	testing.SetRealm(testing.NewUserRealm(creator))
	testing.SetOriginSend(chain.Coins{})
	sendCoins(minSeed() - 1)
	uassert.AbortsWithMessage(t, cur, "seed below b*ln(2): vault could not cover winners", func() {
		CreateMarket(cross(cur), "Q?", testNow+3600, testB, resolver)
	})
	// Non-EOA caller (intermediate code realm) must be rejected even
	// with a big enough envelope.
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/g1lm95v9pqlxtxwc9k8m0rw87agjx5nk3d7waz6l/attacker"))
	testing.SetOriginSend(chain.Coins{{Denom: ugnotDenom, Amount: minSeed()}})
	uassert.AbortsWithMessage(t, cur, "must be called directly by a user (maketx call)", func() {
		CreateMarket(cross(cur), "Q?", testNow+3600, testB, resolver)
	})
}

func TestBuyYesAndNo(cur realm, t *testing.T) {
	defer resetState()
	setTime(testNow)
	creator := testutils.TestAddress("creator2")
	resolver := testutils.TestAddress("resolver2")
	alice := testutils.TestAddress("alice2")
	bob := testutils.TestAddress("bob2")
	testing.SetRealm(testing.NewUserRealm(creator))
	testing.SetOriginSend(chain.Coins{})
	id := createTestMarket(cur, resolver, minSeed()+100000)

	// Alice buys a large YES position: YES price must rise above 50%.
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(chain.Coins{})
	costYes := buyTestShares(cur, id, OutcomeYes, 100000)
	uassert.True(t, costYes > 0)
	uassert.Equal(t, int64(100000), BalanceOf(id, alice, true))
	uassert.Equal(t, int64(0), BalanceOf(id, alice, false))
	uassert.Equal(t, int64(100000), GetMarket(id).QYes)
	uassert.True(t, PriceBps(id, true) > 5000)
	uassert.True(t, PriceBps(id, false) < 5000)

	// Bob buys NO: the market balances again at 50/50.
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(chain.Coins{})
	costNo := buyTestShares(cur, id, OutcomeNo, 100000)
	uassert.True(t, costNo > 0)
	uassert.Equal(t, int64(100000), BalanceOf(id, bob, false))
	uassert.Equal(t, int64(100000), GetMarket(id).QNo)
	uassert.Equal(t, int64(5000), PriceBps(id, true))
	uassert.Equal(t, int64(5000), PriceBps(id, false))

	// Wrong payment, slippage, and bad inputs must abort.
	cost := QuoteBuy(id, OutcomeYes, 1000)
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(chain.Coins{})
	sendCoins(cost - 1)
	uassert.AbortsWithMessage(t, cur, "must send exactly the cost in ugnot", func() {
		Buy(cross(cur), id, OutcomeYes, 1000, cost)
	})
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(chain.Coins{})
	sendCoins(cost)
	uassert.AbortsWithMessage(t, cur, "cost exceeds maxCost", func() {
		Buy(cross(cur), id, OutcomeYes, 1000, cost-1)
	})
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(chain.Coins{})
	sendCoins(1)
	uassert.AbortsWithMessage(t, cur, "shares must be > 0", func() {
		Buy(cross(cur), id, OutcomeYes, 0, 1)
	})
	uassert.AbortsWithMessage(t, cur, "outcome must be YES (1) or NO (2)", func() {
		Buy(cross(cur), id, 3, 1000, 1000000)
	})
	uassert.AbortsWithMessage(t, cur, "market not found", func() {
		Buy(cross(cur), 999, OutcomeYes, 1000, 1000000)
	})
}

func TestSell(cur realm, t *testing.T) {
	defer resetState()
	setTime(testNow)
	creator := testutils.TestAddress("creator3")
	resolver := testutils.TestAddress("resolver3")
	alice := testutils.TestAddress("alice3")
	testing.SetRealm(testing.NewUserRealm(creator))
	testing.SetOriginSend(chain.Coins{})
	id := createTestMarket(cur, resolver, minSeed()+100000)

	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(chain.Coins{})
	cost := buyTestShares(cur, id, OutcomeYes, 100000)
	uassert.True(t, cost > 0)

	// Sell half: refund is positive but less than the full buy cost,
	// balance and outstanding shares drop by exactly the sold amount.
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(chain.Coins{})
	refund := Sell(cross(cur), id, OutcomeYes, 50000, 0)
	uassert.True(t, refund > 0)
	uassert.True(t, refund < cost)
	uassert.Equal(t, int64(50000), BalanceOf(id, alice, true))
	uassert.Equal(t, int64(50000), GetMarket(id).QYes)
	uassert.Equal(t, refund, traderBalance(alice))

	// Oversell, minOut too high, and bad inputs must abort.
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(chain.Coins{})
	uassert.AbortsWithMessage(t, cur, "not enough shares", func() {
		Sell(cross(cur), id, OutcomeYes, 50001, 0)
	})
	uassert.AbortsWithMessage(t, cur, "refund below minOut", func() {
		Sell(cross(cur), id, OutcomeYes, 1000, 1000000000)
	})
	uassert.AbortsWithMessage(t, cur, "shares must be > 0", func() {
		Sell(cross(cur), id, OutcomeYes, 0, 0)
	})
	uassert.AbortsWithMessage(t, cur, "outcome must be YES (1) or NO (2)", func() {
		Sell(cross(cur), id, 0, 1000, 0)
	})
}

func TestResolve(cur realm, t *testing.T) {
	defer resetState()
	setTime(testNow)
	creator := testutils.TestAddress("creator4")
	resolver := testutils.TestAddress("resolver4")
	alice := testutils.TestAddress("alice4")
	testing.SetRealm(testing.NewUserRealm(creator))
	testing.SetOriginSend(chain.Coins{})
	id := createTestMarket(cur, resolver, minSeed())

	// Too early: the market has not closed yet.
	testing.SetRealm(testing.NewUserRealm(resolver))
	testing.SetOriginSend(chain.Coins{})
	uassert.AbortsWithMessage(t, cur, "market not closed yet", func() {
		Resolve(cross(cur), id, OutcomeYes)
	})
	// Non-resolver cannot resolve, even after close.
	setTime(testNow + 3601)
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(chain.Coins{})
	uassert.AbortsWithMessage(t, cur, "only the designated resolver can resolve", func() {
		Resolve(cross(cur), id, OutcomeYes)
	})
	// Bad outcome.
	testing.SetRealm(testing.NewUserRealm(resolver))
	testing.SetOriginSend(chain.Coins{})
	uassert.AbortsWithMessage(t, cur, "outcome must be YES (1) or NO (2)", func() {
		Resolve(cross(cur), id, 0)
	})
	// Happy path: dispute window opens at resolve time.
	testing.SetRealm(testing.NewUserRealm(resolver))
	testing.SetOriginSend(chain.Coins{})
	Resolve(cross(cur), id, OutcomeYes)
	v := GetMarket(id)
	uassert.True(t, v.Resolved)
	uassert.Equal(t, OutcomeYes, v.Outcome)
	uassert.Equal(t, int64(testNow+3601), v.ResolveTime)
	uassert.Equal(t, int64(testNow+3601+DisputeWindow), v.DisputeEndTime)
	// Double resolve must abort.
	testing.SetRealm(testing.NewUserRealm(resolver))
	testing.SetOriginSend(chain.Coins{})
	uassert.AbortsWithMessage(t, cur, "market already resolved", func() {
		Resolve(cross(cur), id, OutcomeNo)
	})
}

func TestRedeem(cur realm, t *testing.T) {
	defer resetState()
	setTime(testNow)
	creator := testutils.TestAddress("creator5")
	resolver := testutils.TestAddress("resolver5")
	alice := testutils.TestAddress("alice5")
	bob := testutils.TestAddress("bob5")
	seed := minSeed() + 100000
	testing.SetRealm(testing.NewUserRealm(creator))
	testing.SetOriginSend(chain.Coins{})
	id := createTestMarket(cur, resolver, seed)

	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(chain.Coins{})
	buyTestShares(cur, id, OutcomeYes, 100000)
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(chain.Coins{})
	buyTestShares(cur, id, OutcomeNo, 100000)

	// Redeem before resolution must abort.
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(chain.Coins{})
	uassert.AbortsWithMessage(t, cur, "market not resolved yet", func() {
		Redeem(cross(cur), id)
	})

	// Resolve YES, then redeem inside the dispute window must abort.
	setTime(testNow + 3601)
	testing.SetRealm(testing.NewUserRealm(resolver))
	testing.SetOriginSend(chain.Coins{})
	Resolve(cross(cur), id, OutcomeYes)
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(chain.Coins{})
	uassert.AbortsWithMessage(t, cur, "dispute window still open", func() {
		Redeem(cross(cur), id)
	})

	// After the window: winner gets exactly 1 ugnot per YES share,
	// loser gets 0, and a second redeem is blocked for both.
	setTime(testNow + 3601 + DisputeWindow)
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(chain.Coins{})
	payout := Redeem(cross(cur), id)
	uassert.Equal(t, int64(100000), payout)
	uassert.Equal(t, int64(100000), traderBalance(alice))
	uassert.Equal(t, int64(0), BalanceOf(id, alice, true))
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(chain.Coins{})
	uassert.AbortsWithMessage(t, cur, "already redeemed", func() {
		Redeem(cross(cur), id)
	})

	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(chain.Coins{})
	payout = Redeem(cross(cur), id)
	uassert.Equal(t, int64(0), payout)
	uassert.Equal(t, int64(0), traderBalance(bob))
	uassert.Equal(t, int64(100000), BalanceOf(id, bob, false))
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(chain.Coins{})
	uassert.AbortsWithMessage(t, cur, "already redeemed", func() {
		Redeem(cross(cur), id)
	})
}

func TestBuyAfterClose(cur realm, t *testing.T) {
	defer resetState()
	setTime(testNow)
	creator := testutils.TestAddress("creator6")
	resolver := testutils.TestAddress("resolver6")
	alice := testutils.TestAddress("alice6")
	testing.SetRealm(testing.NewUserRealm(creator))
	testing.SetOriginSend(chain.Coins{})
	id := createTestMarket(cur, resolver, minSeed())

	// Trading works right up to the close...
	setTime(testNow + 3599)
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(chain.Coins{})
	buyTestShares(cur, id, OutcomeYes, 1000)
	// ...and stops at/after it. Selling stops too.
	setTime(testNow + 3600)
	cost := QuoteBuy(id, OutcomeYes, 1000)
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(chain.Coins{})
	sendCoins(cost)
	uassert.AbortsWithMessage(t, cur, "market closed", func() {
		Buy(cross(cur), id, OutcomeYes, 1000, cost)
	})
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(chain.Coins{})
	uassert.AbortsWithMessage(t, cur, "market closed", func() {
		Sell(cross(cur), id, OutcomeYes, 1000, 0)
	})
}

func TestRender(cur realm, t *testing.T) {
	defer resetState()
	setTime(testNow)
	creator := testutils.TestAddress("creator7")
	resolver := testutils.TestAddress("resolver7")
	alice := testutils.TestAddress("alice7")

	home := Render("")
	uassert.True(t, strings.Contains(home, "Tavern Odds"))
	uassert.True(t, strings.Contains(home, "No markets yet"))

	testing.SetRealm(testing.NewUserRealm(creator))
	testing.SetOriginSend(chain.Coins{})
	id := createTestMarket(cur, resolver, minSeed())
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(chain.Coins{})
	buyTestShares(cur, id, OutcomeYes, 100000)

	home = Render("")
	uassert.True(t, strings.Contains(home, "Will it rain tomorrow?"))
	uassert.True(t, strings.Contains(home, "52.50%"))
	uassert.True(t, strings.Contains(home, "OPEN"))

	detail := Render("/1")
	uassert.True(t, strings.Contains(detail, "Will it rain tomorrow?"))
	uassert.True(t, strings.Contains(detail, "Trade"))
	uassert.True(t, strings.Contains(detail, "gnokey maketx call"))

	uassert.True(t, strings.Contains(Render("/999"), "not found"))
	// A non-numeric path falls back to the home page, never panics.
	uassert.True(t, strings.Contains(Render("/abc"), "Tavern Odds"))
	uassert.True(t, strings.Contains(Render("/1/extra"), "Will it rain tomorrow?"))
}
