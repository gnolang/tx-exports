package verdict2

import (
	"chain"
	"chain/banker"
	"testing"

	"gno.land/p/nt/avl/v0"
)

const (
	betTestStake = int64(1_000_000)
	maxBetInt64  = int64(1<<63 - 1)
	maxBetUint64 = ^uint64(0)
)

var _ func(realm, uint64, bool) = Bet

type betTreeSnapshot struct {
	keys   []string
	values []any
}

type betStateSnapshot struct {
	markets      betTreeSnapshot
	positions    betTreeSnapshot
	activities   betTreeSnapshot
	participants betTreeSnapshot
	nextMarketID uint64
}

func TestBetRejectsInvalidAttachedStakeWithoutMutation(cur realm, t *testing.T) {
	tests := []struct {
		name string
		send chain.Coins
	}{
		{"no coins", chain.Coins{}},
		{"zero ugnot", chain.Coins{chain.NewCoin("ugnot", 0)}},
		{"negative ugnot", chain.Coins{chain.NewCoin("ugnot", -1)}},
		{"non-ugnot", chain.Coins{chain.NewCoin("gnogno", 1)}},
		{"mixed denominations", chain.Coins{chain.NewCoin("ugnot", 1), chain.NewCoin("gnogno", 2)}},
		{"duplicate ugnot", chain.Coins{chain.NewCoin("ugnot", 1), chain.NewCoin("ugnot", 2)}},
	}

	testing.SetHeight(testHeight)
	testing.SetRealm(testRealm)
	for _, tt := range tests {
		resetCreationState()
		marketID := createOpenBetMarket(cur, testHeight+10)
		seedPopulatedBetState(marketID)
		before := snapshotBetState()

		testing.SetOriginSend(tt.send)
		if got := revive(func() {
			placeBet(cross(cur), marketID, true)
		}); got != "invalid attached stake" {
			t.Fatalf("%s: panic %v, want %q", tt.name, got, "invalid attached stake")
		}
		assertBetStateUnchanged(t, before)
	}
}

func TestBetRejectsMissingMarketAndInactiveMarketsWithoutMutation(cur realm, t *testing.T) {
	resetCreationState()
	testing.SetHeight(testHeight)
	testing.SetRealm(testRealm)
	before := snapshotBetState()
	attachBetStake(1)
	if got := revive(func() {
		placeBet(cross(cur), 99, true)
	}); got != "market not found" {
		t.Fatalf("missing market: panic %v, want %q", got, "market not found")
	}
	assertBetStateUnchanged(t, before)

	resetCreationState()
	testing.SetHeight(testHeight)
	testing.SetRealm(testRealm)
	marketID := createOpenBetMarket(cur, testHeight+10)
	market := mustMarketForTest(marketID)
	market.Status = MarketStatus(99)
	markets.Set(marketKey(marketID), market)
	before = snapshotBetState()
	attachBetStake(1)
	if got := revive(func() {
		placeBet(cross(cur), marketID, true)
	}); got != "unknown market status" {
		t.Fatalf("unknown status: panic %v, want %q", got, "unknown market status")
	}
	assertBetStateUnchanged(t, before)

	resetCreationState()
	testing.SetHeight(testHeight)
	testing.SetRealm(testRealm)
	marketID = createOpenBetMarket(cur, testHeight+10)
	market = mustMarketForTest(marketID)
	market.Status = MarketResolved
	markets.Set(marketKey(marketID), market)
	before = snapshotBetState()
	attachBetStake(1)
	if got := revive(func() {
		placeBet(cross(cur), marketID, false)
	}); got != "market closed" {
		t.Fatalf("resolved market: panic %v, want %q", got, "market closed")
	}
	assertBetStateUnchanged(t, before)

	resetCreationState()
	testing.SetHeight(testHeight)
	testing.SetRealm(testRealm)
	closeHeight := testHeight + 10
	marketID = createOpenBetMarket(cur, closeHeight)
	before = snapshotBetState()
	testing.SetHeight(closeHeight)
	attachBetStake(1)
	if got := revive(func() {
		placeBet(cross(cur), marketID, true)
	}); got != "market closed" {
		t.Fatalf("at close: panic %v, want %q", got, "market closed")
	}
	assertBetStateUnchanged(t, before)

	resetCreationState()
	testing.SetHeight(testHeight)
	testing.SetRealm(testRealm)
	marketID = createOpenBetMarket(cur, closeHeight)
	before = snapshotBetState()
	testing.SetHeight(closeHeight + 1)
	attachBetStake(1)
	if got := revive(func() {
		placeBet(cross(cur), marketID, true)
	}); got != "market closed" {
		t.Fatalf("after close: panic %v, want %q", got, "market closed")
	}
	assertBetStateUnchanged(t, before)
}

func TestBetRejectsInterrealmCallerWithoutMutation(cur realm, t *testing.T) {
	resetCreationState()
	testing.SetHeight(testHeight)
	testing.SetRealm(testRealm)
	marketID := createOpenBetMarket(cur, testHeight+10)
	seedPopulatedBetState(marketID)
	before := snapshotBetState()

	testing.SetOriginSend(chain.NewCoins(chain.NewCoin("ugnot", 1)))
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/g1pymrz428hx9fwat04ahwxe9y9hlvetjw7y0p2t/verdict_counter"))
	if got := revive(func() {
		Bet(cross(cur), marketID, true)
	}); got != "direct user call required" {
		t.Fatalf("panic %v, want %q", got, "direct user call required")
	}
	assertBetStateUnchanged(t, before)
}

func TestBetDirectUserGuardRejectsForgedNonCurrentRealm(cur realm, t *testing.T) {
	resetCreationState()
	testing.SetHeight(testHeight)
	testing.SetRealm(testRealm)
	marketID := createOpenBetMarket(cur, testHeight+10)
	seedPopulatedBetState(marketID)
	before := snapshotBetState()
	attachBetStake(1)

	user := testing.MakeRealm(testAddress, "", testing.OriginRealm())
	fake := testing.MakeRealm(testAddress, "gno.land/r/g1pymrz428hx9fwat04ahwxe9y9hlvetjw7y0p2t/verdict2", user)
	if fake.IsCurrent() || !fake.Previous().IsUserCall() {
		t.Fatal("test premise failed: forged realm must be non-current with a user caller")
	}

	// Crossing functions cannot accept forged realms; exercise their shared guard.
	assertSameRealmPanic(t, "direct user call required", func() {
		requireDirectUserCall(0, fake)
	})
	assertBetStateUnchanged(t, before)
}

func TestBetRecordsYESStakeAndActivity(cur realm, t *testing.T) {
	resetCreationState()
	testing.SetHeight(testHeight)
	testing.SetRealm(testRealm)
	marketID := createOpenBetMarket(cur, testHeight+10)
	original := mustMarketForTest(marketID)
	participant := Participant{Address: testAddress, RealizedNet: -2}
	participants.Set(participantKey(testAddress), participant)

	attachBetStake(betTestStake)
	Bet(cross(cur), marketID, true)

	wantMarket := original
	wantMarket.YesPool = betTestStake
	wantMarket.NextActivityID = 1
	if got := mustMarketForTest(marketID); got != wantMarket {
		t.Fatalf("stored market %+v, want %+v", got, wantMarket)
	}
	if got := mustPositionForTest(marketID, testAddress); got != (Position{YesStake: betTestStake}) {
		t.Fatalf("stored position %+v, want YES stake %d", got, betTestStake)
	}
	wantActivity := Activity{
		ID:       1,
		MarketID: marketID,
		Bettor:   testAddress,
		Side:     true,
		Stake:    betTestStake,
		Height:   testHeight,
	}
	if got := mustActivityForTest(marketID, 1); got != wantActivity {
		t.Fatalf("stored activity %+v, want %+v", got, wantActivity)
	}
	if activities.Size() != 1 || positions.Size() != 1 || participants.Size() != 1 {
		t.Fatalf("unexpected state sizes: activities=%d positions=%d participants=%d", activities.Size(), positions.Size(), participants.Size())
	}
	storedParticipant, ok := participantByAddress(testAddress)
	if !ok || storedParticipant != participant {
		t.Fatalf("betting changed participant accounting: %+v, %v", storedParticipant, ok)
	}
}

func TestBetAccumulatesNOAndBothSidesForSameBettor(cur realm, t *testing.T) {
	resetCreationState()
	testing.SetHeight(testHeight)
	testing.SetRealm(testRealm)
	marketID := createOpenBetMarket(cur, testHeight+100)
	steps := []struct {
		side  bool
		stake int64
	}{
		{true, 10},
		{false, 20},
		{true, 30},
		{false, 40},
	}
	var yesStake, noStake int64

	for i, step := range steps {
		height := testHeight + int64(i)
		testing.SetHeight(height)
		attachBetStake(step.stake)
		Bet(cross(cur), marketID, step.side)
		if step.side {
			yesStake += step.stake
		} else {
			noStake += step.stake
		}

		market := mustMarketForTest(marketID)
		if market.YesPool != yesStake || market.NoPool != noStake || market.NextActivityID != uint64(i+1) {
			t.Fatalf("after bet %d: pools=%d/%d next=%d, want %d/%d next=%d", i+1, market.YesPool, market.NoPool, market.NextActivityID, yesStake, noStake, i+1)
		}
		position := mustPositionForTest(marketID, testAddress)
		if position.YesStake != yesStake || position.NoStake != noStake || position.Claimed {
			t.Fatalf("after bet %d: position %+v, want YES=%d NO=%d Claimed=false", i+1, position, yesStake, noStake)
		}
		if activities.Size() != i+1 {
			t.Fatalf("after bet %d: activity count %d, want %d", i+1, activities.Size(), i+1)
		}
		for j := 0; j <= i; j++ {
			want := Activity{
				ID:       uint64(j + 1),
				MarketID: marketID,
				Bettor:   testAddress,
				Side:     steps[j].side,
				Stake:    steps[j].stake,
				Height:   testHeight + int64(j),
			}
			if got := mustActivityForTest(marketID, uint64(j+1)); got != want {
				t.Fatalf("activity %d after bet %d: %+v, want %+v", j+1, i+1, got, want)
			}
		}
	}
	if participants.Size() != 0 {
		t.Fatalf("betting created %d participant records", participants.Size())
	}
}

func TestBetKeepsBettorsAndMarketActivitySequencesIndependent(cur realm, t *testing.T) {
	resetCreationState()
	testing.SetHeight(testHeight)
	testing.SetRealm(testRealm)
	firstMarketID := createOpenBetMarket(cur, testHeight+10)
	secondMarketID := createOpenBetMarket(cur, testHeight+10)
	otherAddress := address(otherAddressString)

	attachBetStake(10)
	Bet(cross(cur), firstMarketID, true)

	testing.SetHeight(testHeight + 1)
	testing.SetRealm(testing.NewUserRealm(otherAddress))
	attachBetStake(20)
	Bet(cross(cur), firstMarketID, false)

	testing.SetHeight(testHeight + 2)
	testing.SetRealm(testRealm)
	attachBetStake(30)
	Bet(cross(cur), firstMarketID, true)

	testing.SetHeight(testHeight + 3)
	testing.SetRealm(testing.NewUserRealm(otherAddress))
	attachBetStake(40)
	Bet(cross(cur), secondMarketID, false)

	firstMarket := mustMarketForTest(firstMarketID)
	if firstMarket.YesPool != 40 || firstMarket.NoPool != 20 || firstMarket.NextActivityID != 3 {
		t.Fatalf("first market pools/sequence = %d/%d/%d, want 40/20/3", firstMarket.YesPool, firstMarket.NoPool, firstMarket.NextActivityID)
	}
	secondMarket := mustMarketForTest(secondMarketID)
	if secondMarket.YesPool != 0 || secondMarket.NoPool != 40 || secondMarket.NextActivityID != 1 {
		t.Fatalf("second market pools/sequence = %d/%d/%d, want 0/40/1", secondMarket.YesPool, secondMarket.NoPool, secondMarket.NextActivityID)
	}
	if got := mustPositionForTest(firstMarketID, testAddress); got != (Position{YesStake: 40}) {
		t.Fatalf("first bettor position %+v, want YES=40", got)
	}
	if got := mustPositionForTest(firstMarketID, otherAddress); got != (Position{NoStake: 20}) {
		t.Fatalf("second bettor first-market position %+v, want NO=20", got)
	}
	if got := mustPositionForTest(secondMarketID, otherAddress); got != (Position{NoStake: 40}) {
		t.Fatalf("second bettor second-market position %+v, want NO=40", got)
	}
	if _, ok := positionByIDAndAddress(secondMarketID, testAddress); ok {
		t.Fatal("first bettor received a position in the second market")
	}

	wantFirst := []Activity{
		{ID: 1, MarketID: firstMarketID, Bettor: testAddress, Side: true, Stake: 10, Height: testHeight},
		{ID: 2, MarketID: firstMarketID, Bettor: otherAddress, Side: false, Stake: 20, Height: testHeight + 1},
		{ID: 3, MarketID: firstMarketID, Bettor: testAddress, Side: true, Stake: 30, Height: testHeight + 2},
	}
	for _, want := range wantFirst {
		if got := mustActivityForTest(firstMarketID, want.ID); got != want {
			t.Fatalf("first market activity %+v, want %+v", got, want)
		}
	}
	wantSecond := Activity{ID: 1, MarketID: secondMarketID, Bettor: otherAddress, Side: false, Stake: 40, Height: testHeight + 3}
	if got := mustActivityForTest(secondMarketID, 1); got != wantSecond {
		t.Fatalf("second market activity %+v, want %+v", got, wantSecond)
	}
	if activities.Size() != 4 || positions.Size() != 3 || participants.Size() != 0 {
		t.Fatalf("unexpected state sizes: activities=%d positions=%d participants=%d", activities.Size(), positions.Size(), participants.Size())
	}
}

func TestBetPoolGuardRejectsCombinedOverflow(t *testing.T) {
	market := Market{YesPool: maxBetInt64 - 100, NoPool: 100}
	assertSameRealmPanic(t, "pool overflow", func() {
		assertPoolAdditionSafe(market, true, 10)
	})
}

func TestBetRejectsOverflowWithoutMutation(cur realm, t *testing.T) {
	tests := []struct {
		name           string
		side           bool
		amount         int64
		yesPool        int64
		noPool         int64
		hasPosition    bool
		positionYes    int64
		positionNo     int64
		claimed        bool
		nextActivityID uint64
		wantPanic      string
	}{
		{"combined pool overflow with fitting selected pool", true, 10, maxBetInt64 - 100, 100, false, 0, 0, false, 0, "pool overflow"},
		{"selected YES pool overflow", true, 10, maxBetInt64 - 5, 0, false, 0, 0, false, 0, "pool overflow"},
		{"selected NO pool overflow", false, 10, 0, maxBetInt64 - 5, false, 0, 0, false, 0, "pool overflow"},
		{"position overflow from inconsistent state", true, 10, 0, 0, true, maxBetInt64 - 5, 7, true, 0, "position overflow"},
		{"activity ID overflow", true, 1, 0, 0, false, 0, 0, false, maxBetUint64, "activity ID overflow"},
	}

	testing.SetHeight(testHeight)
	testing.SetRealm(testRealm)
	for _, tt := range tests {
		resetCreationState()
		testing.SetHeight(testHeight)
		testing.SetRealm(testRealm)
		marketID := createOpenBetMarket(cur, testHeight+10)
		market := mustMarketForTest(marketID)
		market.YesPool = tt.yesPool
		market.NoPool = tt.noPool
		market.NextActivityID = tt.nextActivityID
		markets.Set(marketKey(marketID), market)
		if tt.hasPosition {
			positions.Set(positionKey(marketID, testAddress), Position{YesStake: tt.positionYes, NoStake: tt.positionNo, Claimed: tt.claimed})
		}
		before := snapshotBetState()

		attachBetStake(tt.amount)
		if got := revive(func() {
			placeBet(cross(cur), marketID, tt.side)
		}); got != tt.wantPanic {
			t.Fatalf("%s: panic %v, want %q", tt.name, got, tt.wantPanic)
		}
		assertBetStateUnchanged(t, before)
	}
}

func TestBetAcceptsLastActivityIDThenRejectsWraparound(cur realm, t *testing.T) {
	resetCreationState()
	testing.SetHeight(testHeight)
	testing.SetRealm(testRealm)
	marketID := createOpenBetMarket(cur, testHeight+10)
	market := mustMarketForTest(marketID)
	market.NextActivityID = maxBetUint64 - 1
	markets.Set(marketKey(marketID), market)

	attachBetStake(1)
	Bet(cross(cur), marketID, true)

	market = mustMarketForTest(marketID)
	if market.NextActivityID != maxBetUint64 || market.YesPool != 1 || activities.Size() != 1 {
		t.Fatalf("last valid bet state: next=%d YES=%d activities=%d", market.NextActivityID, market.YesPool, activities.Size())
	}
	wantActivity := Activity{ID: maxBetUint64, MarketID: marketID, Bettor: testAddress, Side: true, Stake: 1, Height: testHeight}
	if got := mustActivityForTest(marketID, maxBetUint64); got != wantActivity {
		t.Fatalf("last activity %+v, want %+v", got, wantActivity)
	}
	before := snapshotBetState()

	attachBetStake(1)
	if got := revive(func() {
		placeBet(cross(cur), marketID, true)
	}); got != "activity ID overflow" {
		t.Fatalf("panic %v, want %q", got, "activity ID overflow")
	}
	assertBetStateUnchanged(t, before)
}

func TestBetPreservesOtherPositionSide(cur realm, t *testing.T) {
	resetCreationState()
	testing.SetHeight(testHeight)
	testing.SetRealm(testRealm)
	marketID := createOpenBetMarket(cur, testHeight+10)
	market := mustMarketForTest(marketID)
	market.YesPool = 5
	market.NoPool = 7
	markets.Set(marketKey(marketID), market)
	positions.Set(positionKey(marketID, testAddress), Position{YesStake: 5, NoStake: 7})

	attachBetStake(3)
	Bet(cross(cur), marketID, true)

	market = mustMarketForTest(marketID)
	if market.YesPool != 8 || market.NoPool != 7 {
		t.Fatalf("pools %d/%d, want 8/7", market.YesPool, market.NoPool)
	}
	if got := mustPositionForTest(marketID, testAddress); got != (Position{YesStake: 8, NoStake: 7}) {
		t.Fatalf("position %+v, want YES=8 NO=7", got)
	}
}

func TestBetLeavesPrefundedRealmBankBalanceUnchanged(cur realm, t *testing.T) {
	resetCreationState()
	testing.SetHeight(testHeight)
	testing.SetRealm(testRealm)
	marketID := createOpenBetMarket(cur, testHeight+10)
	realmAddress := chain.PackageAddress("gno.land/r/g1pymrz428hx9fwat04ahwxe9y9hlvetjw7y0p2t/verdict2")
	const initialBalance = int64(4_000_000)
	testing.IssueCoins(realmAddress, chain.NewCoins(chain.NewCoin("ugnot", initialBalance)))
	readonly := banker.NewReadonlyBanker()
	before := readonly.GetCoin(realmAddress, "ugnot")
	if before != initialBalance {
		t.Fatalf("prefunded realm balance %d, want %d", before, initialBalance)
	}

	attachBetStake(betTestStake)
	Bet(cross(cur), marketID, true)

	after := readonly.GetCoin(realmAddress, "ugnot")
	if after != before {
		t.Fatalf("Bet moved realm bank funds: before=%d after=%d", before, after)
	}
	if market := mustMarketForTest(marketID); market.YesPool != betTestStake {
		t.Fatalf("YES pool %d, want %d", market.YesPool, betTestStake)
	}
	if position := mustPositionForTest(marketID, testAddress); position.YesStake != betTestStake {
		t.Fatalf("YES stake %d, want %d", position.YesStake, betTestStake)
	}
}

func createOpenBetMarket(cur realm, closeHeight int64) uint64 {
	return CreateMarket(cross(cur), testQuestion, closeHeight, "counter", "", 1)
}

func attachBetStake(amount int64) {
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin("ugnot", amount)))
}

func mustPositionForTest(marketID uint64, bettor address) Position {
	position, ok := positionByIDAndAddress(marketID, bettor)
	if !ok {
		panic("test position missing")
	}
	return position
}

func mustActivityForTest(marketID, id uint64) Activity {
	activity, ok := activityByID(marketID, id)
	if !ok {
		panic("test activity missing")
	}
	return activity
}

func seedPopulatedBetState(marketID uint64) {
	market := mustMarketForTest(marketID)
	market.YesPool = 11
	market.NoPool = 12
	market.NextActivityID = 2
	markets.Set(marketKey(marketID), market)
	positions.Set(positionKey(marketID, testAddress), Position{YesStake: 5, NoStake: 6, Claimed: true})
	activities.Set(activityKey(marketID, 1), Activity{ID: 1, MarketID: marketID, Bettor: testAddress, Side: true, Stake: 5, Height: testHeight - 1})
	participants.Set(participantKey(testAddress), Participant{Address: testAddress, RealizedNet: -2})
}

func snapshotBetState() betStateSnapshot {
	return betStateSnapshot{
		markets:      snapshotBetTree(&markets),
		positions:    snapshotBetTree(&positions),
		activities:   snapshotBetTree(&activities),
		participants: snapshotBetTree(&participants),
		nextMarketID: nextMarketID,
	}
}

func snapshotBetTree(tree *avl.Tree) betTreeSnapshot {
	snapshot := betTreeSnapshot{}
	tree.Iterate("", "", func(key string, value any) bool {
		snapshot.keys = append(snapshot.keys, key)
		snapshot.values = append(snapshot.values, value)
		return false
	})
	return snapshot
}

func assertBetStateUnchanged(t *testing.T, want betStateSnapshot) {
	t.Helper()
	got := snapshotBetState()
	if got.nextMarketID != want.nextMarketID {
		t.Fatalf("nextMarketID changed: got %d want %d", got.nextMarketID, want.nextMarketID)
	}
	assertBetTreeUnchanged(t, "markets", want.markets, got.markets)
	assertBetTreeUnchanged(t, "positions", want.positions, got.positions)
	assertBetTreeUnchanged(t, "activities", want.activities, got.activities)
	assertBetTreeUnchanged(t, "participants", want.participants, got.participants)
}

func assertBetTreeUnchanged(t *testing.T, name string, want, got betTreeSnapshot) {
	t.Helper()
	if len(got.keys) != len(want.keys) || len(got.values) != len(want.values) {
		t.Fatalf("%s size changed: got %d/%d want %d/%d", name, len(got.keys), len(got.values), len(want.keys), len(want.values))
	}
	for i := range want.keys {
		if got.keys[i] != want.keys[i] || got.values[i] != want.values[i] {
			t.Fatalf("%s entry %d changed: got %q=%v want %q=%v", name, i, got.keys[i], got.values[i], want.keys[i], want.values[i])
		}
	}
}
