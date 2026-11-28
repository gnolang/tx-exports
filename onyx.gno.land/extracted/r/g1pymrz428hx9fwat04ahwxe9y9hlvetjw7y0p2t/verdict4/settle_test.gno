package verdict4

import (
	"chain"
	"testing"

	verdict "gno.land/p/g1pymrz428hx9fwat04ahwxe9y9hlvetjw7y0p2t/verdict"
	counter "gno.land/r/g1pymrz428hx9fwat04ahwxe9y9hlvetjw7y0p2t/verdict_counter"
)

func TestSettleRejectsUnknownEarlyAndRepeatedCalls(cur realm, t *testing.T) {
	resetCreationState()
	testing.SetHeight(testHeight)
	testing.SetRealm(testRealm)

	if got := revive(func() { Settle(cross(cur), 99) }); got != "market not found" {
		t.Fatalf("unknown market panic %v", got)
	}

	testing.IssueCoins(testAddress, chain.NewCoins(chain.NewCoin("ugnot", 1)))
	id := CreateMarket(cross(cur), testQuestion, testHeight+5, "balance", testAddressString, 1)
	if got := revive(func() { Settle(cross(cur), id) }); got != "settlement not ready" {
		t.Fatalf("early settlement panic %v", got)
	}
	if market := mustMarketForTest(id); market.Status != MarketOpen || market.Outcome != 0 {
		t.Fatalf("early settlement changed market: %+v", market)
	}

	attachBetStake(10)
	Bet(cross(cur), id, true)
	testing.SetHeight(testHeight + 5)
	Settle(cross(cur), id)

	market := mustMarketForTest(id)
	if market.Status != MarketResolved || market.RemainingClaimable != 10 || market.RemainingWinningShares != 10 {
		t.Fatalf("settled accounting %+v", market)
	}
	if got := revive(func() { Settle(cross(cur), id) }); got != "market already settled" {
		t.Fatalf("repeat settlement panic %v", got)
	}
}

func TestSettleBalanceResolverAtThreshold(cur realm, t *testing.T) {
	resetCreationState()
	testing.SetHeight(testHeight)
	testing.SetRealm(testRealm)
	testing.IssueCoins(testAddress, chain.NewCoins(chain.NewCoin("ugnot", 5_000_000)))

	id := CreateMarket(cross(cur), testQuestion, testHeight+1, "balance", testAddressString, 5_000_000)
	attachBetStake(7)
	Bet(cross(cur), id, true)
	attachBetStake(3)
	Bet(cross(cur), id, false)

	testing.SetHeight(testHeight + 1)
	Settle(cross(cur), id)
	market := mustMarketForTest(id)
	if market.Outcome != verdict.OutcomeYes || market.RemainingClaimable != 10 || market.RemainingWinningShares != 7 {
		t.Fatalf("settled market %+v", market)
	}
}

func TestSettleBalanceResolverBelowThreshold(cur realm, t *testing.T) {
	resetCreationState()
	testing.SetHeight(testHeight)
	testing.SetRealm(testRealm)
	testing.IssueCoins(testAddress, chain.NewCoins(chain.NewCoin("ugnot", 4_999_999)))

	id := CreateMarket(cross(cur), testQuestion, testHeight+1, "balance", testAddressString, 5_000_000)
	attachBetStake(7)
	Bet(cross(cur), id, true)
	attachBetStake(3)
	Bet(cross(cur), id, false)

	testing.SetHeight(testHeight + 1)
	Settle(cross(cur), id)
	market := mustMarketForTest(id)
	if market.Outcome != verdict.OutcomeNo || market.RemainingClaimable != 10 || market.RemainingWinningShares != 3 {
		t.Fatalf("settled market %+v", market)
	}
}

func TestSettleCounterResolverReadsCompanionRealm(cur realm, t *testing.T) {
	resetCreationState()
	testing.SetHeight(testHeight)
	testing.SetRealm(testRealm)
	counter.Increment(cross(cur))
	counter.Increment(cross(cur))

	id := CreateMarket(cross(cur), testQuestion, testHeight+1, "counter", "", 2)
	attachBetStake(4)
	Bet(cross(cur), id, true)
	testing.SetHeight(testHeight + 1)
	Settle(cross(cur), id)

	market := mustMarketForTest(id)
	if market.Outcome != verdict.OutcomeYes {
		t.Fatalf("outcome %d, want YES", market.Outcome)
	}
	if market.RemainingWinningShares != 4 {
		t.Fatalf("remaining shares %d, want 4", market.RemainingWinningShares)
	}
}

func TestSettleConvertsEmptyWinningPoolToInvalid(cur realm, t *testing.T) {
	resetCreationState()
	testing.SetHeight(testHeight)
	testing.SetRealm(testRealm)
	testing.IssueCoins(testAddress, chain.NewCoins(chain.NewCoin("ugnot", 0)))

	id := CreateMarket(cross(cur), testQuestion, testHeight+1, "balance", testAddressString, 1_000_000)
	attachBetStake(9)
	Bet(cross(cur), id, true)
	testing.SetHeight(testHeight + 1)
	Settle(cross(cur), id)

	market := mustMarketForTest(id)
	if market.Outcome != verdict.OutcomeInvalid {
		t.Fatalf("outcome %d, want invalid", market.Outcome)
	}
	if market.RemainingWinningShares != 0 || market.RemainingClaimable != 9 {
		t.Fatalf("invalid accounting %+v", market)
	}
}

func TestSettleLocksOutcomeAgainstLaterStateChanges(cur realm, t *testing.T) {
	resetCreationState()
	testing.SetHeight(testHeight)
	testing.SetRealm(testRealm)
	testing.IssueCoins(testAddress, chain.NewCoins(chain.NewCoin("ugnot", 10_000_000)))

	id := CreateMarket(cross(cur), testQuestion, testHeight+1, "balance", testAddressString, 1_000_000)
	attachBetStake(5)
	Bet(cross(cur), id, true)
	testing.SetHeight(testHeight + 1)
	Settle(cross(cur), id)
	testing.IssueCoins(testAddress, chain.NewCoins(chain.NewCoin("ugnot", 0)))

	if got := mustMarketForTest(id).Outcome; got != verdict.OutcomeYes {
		t.Fatalf("outcome changed after settlement: %d", got)
	}
}

func TestSettleRejectsInterrealmCaller(cur realm, t *testing.T) {
	resetCreationState()
	testing.SetHeight(testHeight)
	testing.SetRealm(testRealm)
	id := CreateMarket(cross(cur), testQuestion, testHeight+1, "counter", "", 1)

	testing.SetRealm(testing.NewCodeRealm("gno.land/r/g1pymrz428hx9fwat04ahwxe9y9hlvetjw7y0p2t/verdict_counter"))
	if got := revive(func() { Settle(cross(cur), id) }); got != "direct user call required" {
		t.Fatalf("panic %v, want direct user call required", got)
	}
}
