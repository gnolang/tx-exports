package komit

import (
	"chain"
	"chain/banker"
	"strings"
	"testing"
)

var (
	userA = address("g1dmt3sa5ucvecxuhf3j6ne5r0e3z4x7h6c03xc0")
	userB = address("g1akeqsvhucjt8gf5yupyzjxsjd29wv8fayng37c")
)

func resetState() {
	activeByOwner = make(map[address]*Challenge)
	finished = nil
	poolBalance = 0
	activeStaked = 0
	totalStaked = 0
	completedCount = 0
	failedCount = 0
}

// NOTE on SetRealm placement: testing.SetRealm applies the realm override
// to the nearest non-testing caller frame, so it must be called directly in
// the same function that performs the cross(cur) call into the realm --
// wrapping it in another helper lands the override on the helper's frame
// and the public functions then see the realm itself as Previous().

// startViaPublicPath funds the realm exactly like a real payable call and
// then calls the public StartChallenge. On-chain, the bank module moves the
// sent coins into the realm address before the function runs, and the
// function reads them back through the origin-send envelope; a
// BankerTypeRealmSend banker cannot pull coins out of a user account, so
// the test issues the coins straight to the realm address (where the VM
// would have put them) and sets the envelope to match.
func startViaPublicPath(cur realm, user address, habit string, targetDays int, stakeUgnot int64) {
	coins := chain.NewCoins(chain.NewCoin(DenomUgnot, stakeUgnot))
	testing.IssueCoins(cur.Address(), coins)
	testing.SetOriginSend(coins)
	testing.SetRealm(testing.NewUserRealm(user))
	StartChallenge(cross(cur), habit, targetDays)
}

func assertPanics(t *testing.T, label string, fn func()) {
	t.Helper()
	if r := revive(fn); r == nil {
		t.Fatalf("expected panic for case %q, but succeeded", label)
	}
}

func TestStartCheckInClaimHappyPath(cur realm, t *testing.T) {
	resetState()
	ro := banker.NewReadonlyBanker()

	startViaPublicPath(cur, userA, "Meditate", 3, 5_000_000)

	c, ok := activeByOwner[userA]
	if !ok {
		t.Fatalf("expected an active challenge for userA")
	}
	if c.Streak != 0 || c.Stake != 5_000_000 || c.TargetDays != 3 {
		t.Fatalf("unexpected challenge state: streak %d stake %d target %d", c.Streak, c.Stake, c.TargetDays)
	}
	if ActiveStakedUgnot() != 5_000_000 || TotalStakedUgnot() != 5_000_000 {
		t.Fatalf("unexpected accounting: active %d total %d", ActiveStakedUgnot(), TotalStakedUgnot())
	}

	balBefore := ro.GetCoin(userA, DenomUgnot)

	// First check-in on the start day (public path).
	testing.SetRealm(testing.NewUserRealm(userA))
	if streak := CheckIn(cross(cur)); streak != 1 {
		t.Fatalf("expected streak 1 after first check-in, got %d", streak)
	}

	// Double check-in on the same day is rejected.
	assertPanics(t, "double check-in same day", func() {
		testing.SetRealm(testing.NewUserRealm(userA))
		CheckIn(cross(cur))
	})

	// Claiming before the target is rejected.
	assertPanics(t, "claim before target", func() {
		testing.SetRealm(testing.NewUserRealm(userA))
		Claim(cross(cur))
	})

	// Two more consecutive days via the day-parameterised path the public
	// functions wrap.
	day := today()
	if streak, broke := checkInOn(userA, day+1); broke || streak != 2 {
		t.Fatalf("expected streak 2, got %d (broke=%v)", streak, broke)
	}
	if streak, broke := checkInOn(userA, day+2); broke || streak != 3 {
		t.Fatalf("expected streak 3, got %d (broke=%v)", streak, broke)
	}

	// Claim: pool is empty, so payout is exactly the stake back.
	payout := claimOn(cross(cur), userA, day+2)
	if payout != 5_000_000 {
		t.Fatalf("expected payout 5000000, got %d", payout)
	}
	if got := ro.GetCoin(userA, DenomUgnot) - balBefore; got != 5_000_000 {
		t.Fatalf("expected userA balance +5000000 after claim, got %d", got)
	}
	if CompletedCount() != 1 || ActiveChallenges() != 0 || PoolUgnot() != 0 {
		t.Fatalf("unexpected final state: completed %d active %d pool %d",
			CompletedCount(), ActiveChallenges(), PoolUgnot())
	}
}

func TestSecondActiveChallengeRejected(cur realm, t *testing.T) {
	resetState()

	startViaPublicPath(cur, userA, "Stretch", 7, 2_000_000)

	assertPanics(t, "second active challenge", func() {
		startViaPublicPath(cur, userA, "Another habit", 7, 2_000_000)
	})

	if ActiveChallenges() != 1 {
		t.Fatalf("expected exactly 1 active challenge, got %d", ActiveChallenges())
	}
	if c := activeByOwner[userA]; c.Habit != "Stretch" || c.Stake != 2_000_000 {
		t.Fatalf("original challenge was modified: %+v", c)
	}
}

func TestInvalidStartsRejected(cur realm, t *testing.T) {
	resetState()

	// Zero stake: no coins sent with the call.
	testing.SetOriginSend(chain.NewCoins())
	assertPanics(t, "zero stake", func() {
		testing.SetRealm(testing.NewUserRealm(userA))
		StartChallenge(cross(cur), "Read", 7)
	})

	// Below the 1 GNOT minimum.
	assertPanics(t, "stake below minimum", func() {
		startViaPublicPath(cur, userA, "Read", 7, 500_000)
	})

	// Above the 100 GNOT maximum.
	assertPanics(t, "stake above maximum", func() {
		startViaPublicPath(cur, userA, "Read", 7, 100_000_001)
	})

	// Target below the 3-day minimum and above the 90-day maximum.
	assertPanics(t, "target too small", func() {
		startViaPublicPath(cur, userA, "Read", 2, 2_000_000)
	})
	assertPanics(t, "target too large", func() {
		startViaPublicPath(cur, userA, "Read", 91, 2_000_000)
	})

	// Empty habit.
	assertPanics(t, "empty habit", func() {
		startViaPublicPath(cur, userA, "   ", 7, 2_000_000)
	})

	if ActiveChallenges() != 0 || TotalStakedUgnot() != 0 {
		t.Fatalf("no challenge should have been recorded: active %d total %d",
			ActiveChallenges(), TotalStakedUgnot())
	}
}

func TestMissedDayBreaksAndForfeits(cur realm, t *testing.T) {
	resetState()
	ro := banker.NewReadonlyBanker()

	// userA starts at day 100, checks in, then misses day 101. The internal
	// start moves no coins, so back its stake at the realm address the way
	// a real payable call would have.
	startChallenge(userA, "Run", 5, 5_000_000, 100)
	testing.IssueCoins(cur.Address(), chain.NewCoins(chain.NewCoin(DenomUgnot, 5_000_000)))
	if streak, broke := checkInOn(userA, 100); broke || streak != 1 {
		t.Fatalf("expected streak 1, got %d (broke=%v)", streak, broke)
	}
	if streak, broke := checkInOn(userA, 102); !broke || streak != 0 {
		t.Fatalf("expected break at day 102, got streak %d broke=%v", streak, broke)
	}
	if ActiveChallenges() != 0 || FailedCount() != 1 {
		t.Fatalf("expected challenge closed as failed: active %d failed %d", ActiveChallenges(), FailedCount())
	}
	if PoolUgnot() != 5_000_000 {
		t.Fatalf("expected pool 5000000 after forfeit, got %d", PoolUgnot())
	}
	if ActiveStakedUgnot() != 0 {
		t.Fatalf("expected active staked 0, got %d", ActiveStakedUgnot())
	}

	// userB completes a 3-day challenge with a 2 GNOT stake and claims
	// stake + min(pool, stake) = 2 + 2 = 4 GNOT.
	startViaPublicPath(cur, userB, "Read", 3, 2_000_000)
	day := today()
	checkInOn(userB, day)
	checkInOn(userB, day+1)
	if streak, broke := checkInOn(userB, day+2); broke || streak != 3 {
		t.Fatalf("expected userB streak 3, got %d (broke=%v)", streak, broke)
	}
	balBefore := ro.GetCoin(userB, DenomUgnot)
	payout := claimOn(cross(cur), userB, day+2)
	if payout != 4_000_000 {
		t.Fatalf("expected payout 4000000 (stake + bonus), got %d", payout)
	}
	if got := ro.GetCoin(userB, DenomUgnot) - balBefore; got != 4_000_000 {
		t.Fatalf("expected userB balance +4000000, got %d", got)
	}
	if PoolUgnot() != 3_000_000 || CompletedCount() != 1 {
		t.Fatalf("expected pool 3000000 and 1 completion, got pool %d completed %d", PoolUgnot(), CompletedCount())
	}

	// A claim that arrives after a missed day forfeits instead of paying.
	startChallenge(userA, "Swim", 3, 1_000_000, 300)
	checkInOn(userA, 300)
	if payout := claimOn(cross(cur), userA, 302); payout != 0 {
		t.Fatalf("expected stale claim to pay 0, got %d", payout)
	}
	if FailedCount() != 2 || PoolUgnot() != 4_000_000 {
		t.Fatalf("expected failed 2 and pool 4000000, got failed %d pool %d", FailedCount(), PoolUgnot())
	}
}

func TestStartBreaksStalePrevious(cur realm, t *testing.T) {
	resetState()

	startChallenge(userA, "Code", 5, 1_000_000, 100)
	// Five days later with no check-ins: starting again breaks the stale
	// challenge (forfeiting its stake) and records the new one.
	c := startChallenge(userA, "Code daily", 5, 2_000_000, 105)

	if FailedCount() != 1 || PoolUgnot() != 1_000_000 {
		t.Fatalf("expected stale challenge forfeited: failed %d pool %d", FailedCount(), PoolUgnot())
	}
	if c.StartDay != 105 || c.Stake != 2_000_000 || ActiveChallenges() != 1 {
		t.Fatalf("unexpected new challenge: %+v", c)
	}
}

func TestRenderContainsKeyContent(cur realm, t *testing.T) {
	resetState()

	startChallenge(userA, "Meditate", 7, 5_000_000, today())
	out := Render("")

	for _, want := range []string{"Komit", "Leaderboard", "StartChallenge", "CheckIn", "Claim", "Meditate", "onyx-1", "Reward pool"} {
		if !strings.Contains(out, want) {
			t.Fatalf("render output missing %q", want)
		}
	}
}
