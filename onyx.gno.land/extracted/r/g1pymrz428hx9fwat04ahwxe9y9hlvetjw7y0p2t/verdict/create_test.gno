package verdict

import (
	"crypto/bech32"
	"strconv"
	"strings"
	"testing"

	verdict "gno.land/p/g1pymrz428hx9fwat04ahwxe9y9hlvetjw7y0p2t/verdict"
	"gno.land/p/nt/avl/v0"
)

// This assignment is checked at compile time: the externally callable boundary
// accepts only the injected realm and primitive values. Interfaces, callbacks,
// realm values, and bankers cannot be passed as resolver arguments.
var _ func(realm, string, int64, string, string, int64) uint64 = CreateMarket

var oversizedBalanceTarget = testAddressString + strings.Repeat("q", 4096-len(testAddressString))

func TestCreateMarketRejectsInvalidQuestions(cur realm, t *testing.T) {
	tests := []struct {
		name     string
		question string
	}{
		{"empty", ""},
		{"whitespace only", " \t\n "},
		{"seven trimmed characters", " 1234567 "},
		{"161 trimmed characters", " " + strings.Repeat("x", 161) + " "},
	}

	testing.SetHeight(testHeight)
	testing.SetRealm(testRealm)
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			resetCreationState()
			assertCreationPanic(t, "invalid question", func() {
				CreateMarket(cross(cur), tt.question, testHeight+1, "counter", "", 1)
			})
			assertNoCreationState(t)
		})
	}
}

func TestCreateMarketAcceptsQuestionLengthBoundaries(cur realm, t *testing.T) {
	tests := []struct {
		name     string
		question string
		want     string
	}{
		{"exactly eight", "12345678", "12345678"},
		{"exactly 160", strings.Repeat("q", 160), strings.Repeat("q", 160)},
		{"160 unicode characters", strings.Repeat("界", 160), strings.Repeat("界", 160)},
	}

	testing.SetHeight(testHeight)
	testing.SetRealm(testRealm)
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			resetCreationState()
			id := CreateMarket(cross(cur), " \t"+tt.question+"\n ", testHeight+1, "counter", "", 1)
			if id != 1 {
				t.Fatalf("market id %d, want 1", id)
			}
			market := mustMarketForTest(id)
			if market.Question != tt.want {
				t.Fatalf("stored question %q, want %q", market.Question, tt.want)
			}
		})
	}
}

func TestCreateMarketValidatesCloseHeight(cur realm, t *testing.T) {
	tests := []struct {
		name        string
		closeHeight int64
		wantPanic   bool
	}{
		{"below current height", testHeight - 1, true},
		{"equal to current height", testHeight, true},
		{"future height", testHeight + 1, false},
	}

	testing.SetHeight(testHeight)
	testing.SetRealm(testRealm)
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			resetCreationState()
			if tt.wantPanic {
				assertCreationPanic(t, "close height must be in the future", func() {
					CreateMarket(cross(cur), testQuestion, tt.closeHeight, "counter", "", 1)
				})
				assertNoCreationState(t)
				return
			}

			id := CreateMarket(cross(cur), testQuestion, tt.closeHeight, "counter", "", 1)
			if id != 1 {
				t.Fatalf("market id %d, want 1", id)
			}
			if got := mustMarketForTest(id).CloseHeight; got != tt.closeHeight {
				t.Fatalf("close height %d, want %d", got, tt.closeHeight)
			}
		})
	}
}

func TestCreateMarketValidatesResolverConfiguration(cur realm, t *testing.T) {
	const bech32mTarget = "g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhusqvvk"
	badChecksum := testAddressString[:len(testAddressString)-1] + "q"
	if len(oversizedBalanceTarget) != 4096 {
		t.Fatalf("oversized target length %d, want 4096", len(oversizedBalanceTarget))
	}
	tests := []struct {
		name         string
		resolverKind string
		target       string
		threshold    int64
		wantPanic    string
	}{
		{"unknown resolver", "fixed", "", 1, "invalid resolver"},
		{"resolver is case sensitive", "Balance", testAddressString, 1, "invalid resolver"},
		{"empty balance target", "balance", "", 1, "invalid resolver target"},
		{"malformed balance target", "balance", "not-an-address", 1, "invalid resolver target"},
		{"oversized balance target", "balance", oversizedBalanceTarget, 1, "invalid resolver target"},
		{"bad balance checksum", "balance", badChecksum, 1, "invalid resolver target"},
		{"bech32m balance target", "balance", bech32mTarget, 1, "invalid resolver target"},
		{"noncanonical balance target", "balance", strings.ToUpper(testAddressString), 1, "invalid resolver target"},
		{"balance realm path", "balance", "gno.land/r/g1pymrz428hx9fwat04ahwxe9y9hlvetjw7y0p2t/verdict_counter", 1, "invalid resolver target"},
		{"counter address target", "counter", testAddressString, 1, "invalid resolver target"},
		{"counter whitespace target", "counter", " ", 1, "invalid resolver target"},
		{"counter realm path", "counter", "gno.land/r/g1pymrz428hx9fwat04ahwxe9y9hlvetjw7y0p2t/verdict_counter", 1, "invalid resolver target"},
		{"zero balance threshold", "balance", testAddressString, 0, "invalid resolver threshold"},
		{"negative balance threshold", "balance", testAddressString, -1, "invalid resolver threshold"},
		{"zero counter threshold", "counter", "", 0, "invalid resolver threshold"},
		{"negative counter threshold", "counter", "", -1, "invalid resolver threshold"},
	}

	hrp, _, version, err := bech32.DecodeGeneric(bech32mTarget)
	if err != nil {
		t.Fatalf("test premise failed: Bech32m target must decode: %v", err)
	}
	if hrp != "g" || version != bech32.VersionM {
		t.Fatalf("test premise failed: Bech32m target has hrp %q and version %v, want g and VersionM", hrp, version)
	}
	if !address(bech32mTarget).IsValid() {
		t.Fatal("test premise failed: lowercase Bech32m target must pass current address validation")
	}

	noncanonical := address(strings.ToUpper(testAddressString))
	if !noncanonical.IsValid() {
		t.Fatal("test premise failed: uppercase Bech32 target must decode as an address")
	}

	testing.SetHeight(testHeight)
	testing.SetRealm(testRealm)
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			resetCreationState()
			assertCreationPanic(t, tt.wantPanic, func() {
				CreateMarket(cross(cur), testQuestion, testHeight+1, tt.resolverKind, tt.target, tt.threshold)
			})
			assertNoCreationState(t)
		})
	}
}

func TestCreateMarketStoresPrimitiveConfigurationAndSequentialIDs(cur realm, t *testing.T) {
	resetCreationState()
	testing.SetHeight(testHeight)
	testing.SetRealm(testRealm)

	balanceID := CreateMarket(cross(cur), " \t"+testQuestion+"\n ", testHeight+1, "balance", testAddressString, testThreshold)
	if balanceID != 1 {
		t.Fatalf("first market id %d, want 1", balanceID)
	}
	wantBalance := Market{
		ID:          1,
		Question:    testQuestion,
		Creator:     testAddress,
		CloseHeight: testHeight + 1,
		Status:      MarketOpen,
		Outcome:     verdict.OutcomeUnresolved,
		Resolver: ResolverConfig{
			Kind:         ResolverBalance,
			Target:       testAddressString,
			TargetAmount: testThreshold,
		},
	}
	if got := mustMarketForTest(balanceID); got != wantBalance {
		t.Fatalf("stored balance market %+v, want %+v", got, wantBalance)
	}

	assertCreationPanic(t, "invalid question", func() {
		CreateMarket(cross(cur), "short", testHeight+1, "counter", "", 1)
	})

	counterID := CreateMarket(cross(cur), testQuestion, testHeight+2, "counter", "", 1)
	if counterID != 2 {
		t.Fatalf("second market id %d, want 2", counterID)
	}
	wantCounter := Market{
		ID:          2,
		Question:    testQuestion,
		Creator:     testAddress,
		CloseHeight: testHeight + 2,
		Status:      MarketOpen,
		Outcome:     verdict.OutcomeUnresolved,
		Resolver: ResolverConfig{
			Kind:         ResolverCounter,
			Target:       "",
			TargetAmount: 1,
		},
	}
	if got := mustMarketForTest(counterID); got != wantCounter {
		t.Fatalf("stored counter market %+v, want %+v", got, wantCounter)
	}
	if markets.Size() != 2 || positions.Size() != 0 || activities.Size() != 0 || participants.Size() != 0 {
		t.Fatalf("unexpected creation state sizes: %d %d %d %d", markets.Size(), positions.Size(), activities.Size(), participants.Size())
	}
}

func TestCreateMarketStoresImmediateCallerAsValue(cur realm, t *testing.T) {
	resetCreationState()
	testing.SetHeight(testHeight)
	testing.SetRealm(testRealm)
	CreateMarket(cross(cur), testQuestion, testHeight+1, "counter", "", 1)

	otherAddress := address(otherAddressString)
	testing.SetRealm(testing.NewUserRealm(otherAddress))
	CreateMarket(cross(cur), testQuestion, testHeight+1, "counter", "", 1)

	first := mustMarketForTest(1)
	second := mustMarketForTest(2)
	if first.Creator != testAddress || second.Creator != otherAddress {
		t.Fatalf("stored creators %v and %v, want %v and %v", first.Creator, second.Creator, testAddress, otherAddress)
	}

	first.Creator = otherAddress
	first.Resolver.Kind = ResolverBalance
	first.Resolver.Target = otherAddressString
	first.Resolver.TargetAmount = 99
	stored := mustMarketForTest(1)
	if stored.Creator != testAddress || stored.Resolver.Kind != ResolverCounter || stored.Resolver.Target != "" || stored.Resolver.TargetAmount != 1 {
		t.Fatalf("caller-mutated copy changed persisted market: %+v", stored)
	}
}

func TestCreateMarketRejectsNonUserAndNonCurrentCallers(cur realm, t *testing.T) {
	testing.SetHeight(testHeight)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/g1pymrz428hx9fwat04ahwxe9y9hlvetjw7y0p2t/verdict_counter"))

	t.Run("interrealm caller", func(t *testing.T) {
		resetCreationState()
		assertCreationPanic(t, "direct user call required", func() {
			CreateMarket(cross(cur), testQuestion, testHeight+1, "counter", "", 1)
		})
		assertNoCreationState(t)
	})

	t.Run("forged non-current realm", func(t *testing.T) {
		resetCreationState()
		user := testing.MakeRealm(testAddress, "", testing.OriginRealm())
		fake := testing.MakeRealm(testAddress, "gno.land/r/g1pymrz428hx9fwat04ahwxe9y9hlvetjw7y0p2t/verdict", user)
		if fake.IsCurrent() || !fake.Previous().IsUserCall() {
			t.Fatal("test premise failed: forged realm must be non-current with a user caller")
		}

		assertSameRealmPanic(t, "direct user call required", func() {
			requireDirectUserCall(0, fake)
		})
		assertNoCreationState(t)
	})
}

func TestCreateMarketGuardsIDOverflow(cur realm, t *testing.T) {
	resetCreationState()
	testing.SetHeight(testHeight)
	testing.SetRealm(testRealm)
	nextMarketID = ^uint64(0)

	assertCreationPanic(t, "market ID overflow", func() {
		CreateMarket(cross(cur), testQuestion, testHeight+1, "counter", "", 1)
	})
	if nextMarketID != ^uint64(0) || markets.Size() != 0 {
		t.Fatalf("overflow changed state: next=%d size=%d", nextMarketID, markets.Size())
	}

	nextMarketID--
	lastID := CreateMarket(cross(cur), testQuestion, testHeight+1, "counter", "", 1)
	if lastID != ^uint64(0) || nextMarketID != ^uint64(0) {
		t.Fatalf("last valid allocation: id=%d next=%d", lastID, nextMarketID)
	}
	assertCreationPanic(t, "market ID overflow", func() {
		CreateMarket(cross(cur), testQuestion, testHeight+1, "counter", "", 1)
	})
	if markets.Size() != 1 {
		t.Fatalf("market count after repeated overflow %d, want 1", markets.Size())
	}
}

func TestStateStoresAndReturnsValueCopies(t *testing.T) {
	resetCreationState()

	market := Market{
		ID:          7,
		Question:    testQuestion,
		Creator:     testAddress,
		CloseHeight: 123,
		YesPool:     11,
		NoPool:      12,
		Status:      MarketResolved,
		Outcome:     verdict.OutcomeYes,
		Resolver: ResolverConfig{
			Kind:         ResolverBalance,
			Target:       testAddressString,
			TargetAmount: 55,
		},
		RemainingClaimable:     13,
		RemainingWinningShares: 11,
		NextActivityID:         3,
	}
	position := Position{YesStake: 5, NoStake: 6, Claimed: true}
	activity := Activity{ID: 3, MarketID: 7, Bettor: testAddress, Side: true, Stake: 5, Height: 100}
	participant := Participant{Address: testAddress, RealizedNet: -2}
	wantPosition := position

	markets.Set(marketKey(market.ID), market)
	positions.Set(positionKey(market.ID, testAddress), position)
	activities.Set(activityKey(activity.MarketID, activity.ID), activity)
	participants.Set(participantKey(testAddress), participant)

	market.Question = "changed"
	market.Creator = address(otherAddressString)
	market.Resolver.Target = "changed"
	position.YesStake = 999
	activity.Stake = 999
	participant.RealizedNet = 999

	gotMarket, ok := marketByID(7)
	if !ok || gotMarket.Question != testQuestion || gotMarket.Creator != testAddress || gotMarket.Resolver.Target != testAddressString {
		t.Fatalf("stored market was not copied on write: %+v", gotMarket)
	}
	gotPosition, ok := positionByIDAndAddress(7, testAddress)
	if !ok || gotPosition != wantPosition {
		t.Fatalf("stored position was not copied on write: %+v", gotPosition)
	}
	gotActivity, ok := activityByID(7, 3)
	if !ok || gotActivity.Stake != 5 {
		t.Fatalf("stored activity was not copied on write: %+v", gotActivity)
	}
	gotParticipant, ok := participantByAddress(testAddress)
	if !ok || gotParticipant.RealizedNet != -2 {
		t.Fatalf("stored participant was not copied on write: %+v", gotParticipant)
	}

	gotMarket.Question = "mutated read"
	gotMarket.Resolver.TargetAmount = 999
	gotPosition.Claimed = false
	gotActivity.Bettor = address(otherAddressString)
	gotParticipant.Address = address(otherAddressString)

	storedMarket, _ := marketByID(7)
	storedPosition, _ := positionByIDAndAddress(7, testAddress)
	storedActivity, _ := activityByID(7, 3)
	storedParticipant, _ := participantByAddress(testAddress)
	if storedMarket.Question != testQuestion || storedMarket.Resolver.TargetAmount != 55 {
		t.Fatalf("market read exposed stored value: %+v", storedMarket)
	}
	if storedPosition != wantPosition {
		t.Fatalf("position read exposed stored value: %+v", storedPosition)
	}
	if storedActivity.Stake != 5 || storedActivity.Bettor != testAddress {
		t.Fatalf("activity read exposed stored value: %+v", storedActivity)
	}
	if storedParticipant.Address != testAddress || storedParticipant.RealizedNet != -2 {
		t.Fatalf("participant read exposed stored value: %+v", storedParticipant)
	}

	if _, ok := marketByID(8); ok {
		t.Fatal("missing market reported as present")
	}
	if _, ok := positionByIDAndAddress(8, testAddress); ok {
		t.Fatal("missing position reported as present")
	}
	if _, ok := activityByID(7, 4); ok {
		t.Fatal("missing activity reported as present")
	}
	if _, ok := participantByAddress(address(otherAddressString)); ok {
		t.Fatal("missing participant reported as present")
	}
}

func TestStateKeysPreserveNumericOrder(t *testing.T) {
	resetCreationState()
	for _, id := range []uint64{100, 9, 99, 10} {
		markets.Set(marketKey(id), Market{ID: id})
	}

	want := []uint64{9, 10, 99, 100}
	got := make([]uint64, 0, len(want))
	markets.Iterate("", "", func(_ string, value any) bool {
		market, ok := value.(Market)
		if !ok {
			t.Fatalf("stored market has type %T", value)
		}
		got = append(got, market.ID)
		return false
	})
	if len(got) != len(want) {
		t.Fatalf("observed market IDs %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("market ID at index %d is %d, want %v", i, got[i], want)
		}
	}
}

func TestStateKeysSeparateMarketsAndAddresses(t *testing.T) {
	resetCreationState()
	otherAddress := address(otherAddressString)
	positions.Set(positionKey(1, testAddress), Position{YesStake: 1})
	positions.Set(positionKey(1, otherAddress), Position{YesStake: 2})
	positions.Set(positionKey(2, testAddress), Position{YesStake: 3})

	for _, tt := range []struct {
		marketID uint64
		bettor   address
		want     int64
	}{
		{1, testAddress, 1},
		{1, otherAddress, 2},
		{2, testAddress, 3},
	} {
		position, ok := positionByIDAndAddress(tt.marketID, tt.bettor)
		if !ok || position.YesStake != tt.want {
			t.Fatalf("position (%d,%v) = %+v, %v; want stake %d", tt.marketID, tt.bettor, position, ok, tt.want)
		}
	}
	if positionKey(1, testAddress) != "00000000000000000001:"+testAddressString {
		t.Fatalf("unexpected position key %q", positionKey(1, testAddress))
	}

	t.Run("activities", func(t *testing.T) {
		activities.Set(activityKey(1, 1), Activity{ID: 1, MarketID: 1, Stake: 4})
		activities.Set(activityKey(2, 1), Activity{ID: 1, MarketID: 2, Stake: 5})

		for _, tt := range []struct {
			marketID uint64
			want     int64
		}{
			{1, 4},
			{2, 5},
		} {
			activity, ok := activityByID(tt.marketID, 1)
			if !ok || activity.MarketID != tt.marketID || activity.Stake != tt.want {
				t.Fatalf("activity for market %d = %+v, %v; want market %d with stake %d", tt.marketID, activity, ok, tt.marketID, tt.want)
			}
		}
	})

	if activityKey(2, 10) != "00000000000000000002:00000000000000000010" {
		t.Fatalf("unexpected activity key %q", activityKey(2, 10))
	}
}

func resetCreationState() {
	markets = avl.Tree{}
	positions = avl.Tree{}
	activities = avl.Tree{}
	participants = avl.Tree{}
	nextMarketID = 0
}

func assertNoCreationState(t *testing.T) {
	t.Helper()
	if nextMarketID != 0 || markets.Size() != 0 || positions.Size() != 0 || activities.Size() != 0 || participants.Size() != 0 {
		t.Fatalf("rejected creation changed state: next=%d sizes=%d/%d/%d/%d", nextMarketID, markets.Size(), positions.Size(), activities.Size(), participants.Size())
	}
}

func assertCreationPanic(t *testing.T, want string, fn func()) {
	t.Helper()
	if got := revive(fn); got != want {
		t.Fatalf("panic %v, want %q", got, want)
	}
}

func assertSameRealmPanic(t *testing.T, want string, fn func()) {
	t.Helper()
	defer func() {
		if got := recover(); got != want {
			t.Fatalf("panic %v, want %q", got, want)
		}
	}()
	fn()
}

func mustMarketForTest(id uint64) Market {
	market, ok := marketByID(id)
	if !ok {
		panic("test market missing: " + strconv.FormatUint(id, 10))
	}
	return market
}
