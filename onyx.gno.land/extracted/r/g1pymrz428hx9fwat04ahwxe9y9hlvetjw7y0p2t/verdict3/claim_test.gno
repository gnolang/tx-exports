package verdict3

import (
	"chain"
	"chain/banker"
	"testing"
)

const claimRealmPath = "gno.land/r/g1pymrz428hx9fwat04ahwxe9y9hlvetjw7y0p2t/verdict3"

func fundClaimRealm(amount int64) {
	realmAddress := chain.PackageAddress(claimRealmPath)
	testing.IssueCoins(realmAddress, chain.NewCoins(chain.NewCoin("ugnot", amount)))
}

func realmClaimBalance() int64 {
	readOnly := banker.NewReadonlyBanker()
	return readOnly.GetCoin(chain.PackageAddress(claimRealmPath), "ugnot")
}

func TestClaimRejectsInvalidStatesWithoutMutation(cur realm, t *testing.T) {
	resetCreationState()
	testing.SetHeight(testHeight)
	testing.SetRealm(testRealm)
	testing.IssueCoins(testAddress, chain.NewCoins(chain.NewCoin("ugnot", 1_000_000)))

	id := CreateMarket(cross(cur), testQuestion, testHeight+2, "balance", testAddressString, 1)
	attachBetStake(10)
	Bet(cross(cur), id, true)

	if got := revive(func() { claimFor(cross(cur), id, testAddress) }); got != "market not settled" {
		t.Fatalf("early claim panic %v", got)
	}
	if got := revive(func() { claimFor(cross(cur), 99, testAddress) }); got != "market not found" {
		t.Fatalf("unknown market panic %v", got)
	}

	testing.SetHeight(testHeight + 2)
	Settle(cross(cur), id)
	if got := revive(func() { claimFor(cross(cur), id, address(otherAddressString)) }); got != "no position" {
		t.Fatalf("missing position panic %v", got)
	}
	if got := revive(func() { claimFor(cross(cur), id, address(otherAddressString)) }); got != "no position" {
		t.Fatalf("repeated missing position panic %v", got)
	}
	if position := mustPositionForTest(id, testAddress); position.Claimed {
		t.Fatal("rejected claim marked position claimed")
	}
}

func TestClaimYESWinnerPaysFullPool(cur realm, t *testing.T) {
	resetCreationState()
	testing.SetHeight(testHeight)
	testing.SetRealm(testRealm)
	testing.IssueCoins(testAddress, chain.NewCoins(chain.NewCoin("ugnot", 1_000_000)))

	id := CreateMarket(cross(cur), testQuestion, testHeight+2, "balance", testAddressString, 1)
	attachBetStake(100)
	Bet(cross(cur), id, true)
	testing.SetRealm(testing.NewUserRealm(address(otherAddressString)))
	attachBetStake(300)
	Bet(cross(cur), id, false)
	testing.SetRealm(testRealm)

	testing.SetHeight(testHeight + 2)
	Settle(cross(cur), id)
	fundClaimRealm(400)

	Claim(cross(cur), id)
	market := mustMarketForTest(id)
	if market.RemainingClaimable != 0 || market.RemainingWinningShares != 0 {
		t.Fatalf("remaining accounting %+v", market)
	}
	if position := mustPositionForTest(id, testAddress); !position.Claimed {
		t.Fatal("winner position not claimed")
	}
	participant, ok := participantByAddress(testAddress)
	if !ok || participant.RealizedNet != 300 {
		t.Fatalf("realized net %+v, %v", participant, ok)
	}
	if got := realmClaimBalance(); got != 0 {
		t.Fatalf("realm balance after claim %d, want 0", got)
	}
	if got := revive(func() { claimFor(cross(cur), id, testAddress) }); got != "already claimed" {
		t.Fatalf("repeat claim panic %v", got)
	}
}

func TestClaimAssignsRoundingDustToFinalWinner(cur realm, t *testing.T) {
	resetCreationState()
	testing.SetHeight(testHeight)
	testing.SetRealm(testRealm)
	testing.IssueCoins(testAddress, chain.NewCoins(chain.NewCoin("ugnot", 0)))

	id := CreateMarket(cross(cur), testQuestion, testHeight+2, "balance", testAddressString, 1)
	attachBetStake(1)
	Bet(cross(cur), id, true)
	testing.SetRealm(testing.NewUserRealm(address(otherAddressString)))
	attachBetStake(1)
	Bet(cross(cur), id, false)
	thirdAddress := address("g1m0rgan0rla00ygmdmp55f5m0unvsvknluyg2a4")
	testing.SetRealm(testing.NewUserRealm(thirdAddress))
	attachBetStake(2)
	Bet(cross(cur), id, false)
	testing.SetRealm(testRealm)

	testing.SetHeight(testHeight + 2)
	Settle(cross(cur), id)
	fundClaimRealm(4)

	first := claimFor(cross(cur), id, address(otherAddressString))
	last := claimFor(cross(cur), id, thirdAddress)
	if first+last != 4 {
		t.Fatalf("paid %d, want 4", first+last)
	}
	if first != 1 || last != 3 {
		t.Fatalf("payouts %d and %d, want 1 and 3", first, last)
	}
	if got := revive(func() { claimFor(cross(cur), id, testAddress) }); got != "claim not available" {
		t.Fatalf("losing claim panic %v", got)
	}
	if market := mustMarketForTest(id); market.RemainingClaimable != 0 {
		t.Fatalf("trapped dust %d", market.RemainingClaimable)
	}
}

func TestClaimInvalidMarketRefundsExactStake(cur realm, t *testing.T) {
	resetCreationState()
	testing.SetHeight(testHeight)
	testing.SetRealm(testRealm)
	testing.IssueCoins(testAddress, chain.NewCoins(chain.NewCoin("ugnot", 0)))

	id := CreateMarket(cross(cur), testQuestion, testHeight+2, "balance", testAddressString, 1)
	attachBetStake(11)
	Bet(cross(cur), id, true)
	attachBetStake(7)
	Bet(cross(cur), id, true)

	testing.SetHeight(testHeight + 2)
	Settle(cross(cur), id)
	fundClaimRealm(18)

	if got := claimFor(cross(cur), id, testAddress); got != 18 {
		t.Fatalf("refund %d, want 18", got)
	}
	if market := mustMarketForTest(id); market.RemainingClaimable != 0 || market.RemainingWinningShares != 0 {
		t.Fatalf("invalid market accounting %+v", market)
	}
	participant, ok := participantByAddress(testAddress)
	if !ok || participant.RealizedNet != 0 {
		t.Fatalf("refund should have zero net, got %+v", participant)
	}
}

func TestClaimBothSidesPaysOnlyWinningStake(cur realm, t *testing.T) {
	resetCreationState()
	testing.SetHeight(testHeight)
	testing.SetRealm(testRealm)
	testing.IssueCoins(testAddress, chain.NewCoins(chain.NewCoin("ugnot", 1_000_000)))

	id := CreateMarket(cross(cur), testQuestion, testHeight+2, "balance", testAddressString, 1)
	attachBetStake(2)
	Bet(cross(cur), id, true)
	attachBetStake(3)
	Bet(cross(cur), id, false)
	testing.SetRealm(testing.NewUserRealm(address(otherAddressString)))
	attachBetStake(1)
	Bet(cross(cur), id, false)
	testing.SetRealm(testRealm)

	testing.SetHeight(testHeight + 2)
	Settle(cross(cur), id)
	fundClaimRealm(6)

	// YES stake 2 of winning pool 2 pays the full pool of 6.
	if got := claimFor(cross(cur), id, testAddress); got != 6 {
		t.Fatalf("payout %d, want 6", got)
	}
	participant, ok := participantByAddress(testAddress)
	if !ok || participant.RealizedNet != 1 {
		t.Fatalf("realized net %+v, want 1", participant)
	}
}

func TestClaimEntryPointRejectsInterrealmCaller(cur realm, t *testing.T) {
	resetCreationState()
	testing.SetHeight(testHeight)
	testing.SetRealm(testRealm)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/g1pymrz428hx9fwat04ahwxe9y9hlvetjw7y0p2t/verdict_counter"))
	if got := revive(func() { Claim(cross(cur), 1) }); got != "direct user call required" {
		t.Fatalf("panic %v, want direct user call required", got)
	}
}
