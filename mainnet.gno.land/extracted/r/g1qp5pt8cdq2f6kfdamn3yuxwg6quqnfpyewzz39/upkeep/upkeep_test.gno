package upkeep

import (
	"chain"
	"chain/banker"
	"strings"
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"

	subs "gno.land/r/g1qp5pt8cdq2f6kfdamn3yuxwg6quqnfpyewzz39/subscriptions"
	guardian "gno.land/r/g1qp5pt8cdq2f6kfdamn3yuxwg6quqnfpyewzz39/timelock_guardian"
)

var (
	testAdmin = testutils.TestAddress("ukadmin")
	funder    = testutils.TestAddress("ukfunder")
	poker     = testutils.TestAddress("ukpoker")
	mallory   = testutils.TestAddress("ukmallory")
	provider  = testutils.TestAddress("ukprov")
	subber    = testutils.TestAddress("uksubber")
	towner    = testutils.TestAddress("uktowner")
)

// Harness facts, carried from the sibling suites: init runs with an
// empty origin (real deploys capture the signer); realm globals persist
// across tests while the banker resets; SetRealm binds to the CALLING
// frame only, so arming is inlined at every site; SkipHeights advances
// the clock 5s per height AND wipes the origin context.
func init() {
	admin = testAdmin
	sweeper = testAdmin
	self = chain.PackageAddress("gno.land/r/g1qp5pt8cdq2f6kfdamn3yuxwg6quqnfpyewzz39/upkeep")
}

func ugnot(n int64) chain.Coins { return chain.NewCoins(chain.NewCoin(Denom, n)) }

func coinsOf(a address) int64 { return banker.NewReadonlyBanker().GetCoin(a, Denom) }

// conserved asserts the realm's monetary invariant: everything the realm
// holds is either unspent pot or earned-but-unclaimed balance.
func conserved(t *testing.T) {
	t.Helper()
	if Held() != Pot()+UsersTotal() {
		t.Fatalf("conservation violated: Held=%d pot=%d users=%d",
			Held(), Pot(), UsersTotal())
	}
}

// syncHeld re-issues the realm's expected holdings. The harness banker
// resets between tests while realm globals (pot, ledger) persist, so
// each money-touching test starts by making the banker match the books.
func syncHeld() {
	want := Pot() + UsersTotal()
	have := coinsOf(Address())
	if want > have {
		testing.IssueCoins(Address(), ugnot(want-have))
	}
}

func fundAs(cur realm, from address, amount int64) {
	testing.SetRealm(testing.NewUserRealm(from))
	testing.SetOriginCaller(from)
	testing.SetOriginSend(ugnot(amount))
	testing.IssueCoins(Address(), ugnot(amount))
	Fund(cross(cur))
}

func adminSet(cur realm, task string, amount int64) {
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	testing.SetOriginCaller(testAdmin)
	testing.SetOriginSend(nil)
	SetReward(cross(cur), task, amount)
}

// expirableSub drives the REAL subscriptions realm to a state where one
// subscription is past its grace window, and returns its id. This is
// the downstream fixture for the realm-to-realm tests: nothing is
// mocked.
func expirableSub(cur realm, t *testing.T) int64 {
	t.Helper()
	testing.SetRealm(testing.NewUserRealm(provider))
	testing.SetOriginCaller(provider)
	testing.SetOriginSend(nil)
	planID := subs.CreatePlan(cross(cur), "upkeep-fixture", "d", 1, 10, 1000)

	testing.SetRealm(testing.NewUserRealm(subber))
	testing.SetOriginCaller(subber)
	testing.SetOriginSend(ugnot(1))
	testing.IssueCoins(subs.Address(), ugnot(1))
	subID := subs.Subscribe(cross(cur), planID)

	// paidThrough = h+10; expirable at paidThrough+10. Skip well past.
	testing.SkipHeights(25)
	return subID
}

// maturedAction drives the REAL guardian realm to a matured timelocked
// action and returns its id.
var targetSeq int

func maturedAction(cur realm, t *testing.T) string {
	t.Helper()
	targetSeq++
	name := "uktarget" + string(rune('a'+targetSeq%26))
	testing.SetRealm(testing.NewUserRealm(towner))
	testing.SetOriginCaller(towner)
	testing.SetOriginSend(nil)
	guardian.RegisterTarget(cross(cur), name, guardian.MinDelayFloor, "")

	testing.SetRealm(testing.NewUserRealm(towner))
	testing.SetOriginCaller(towner)
	testing.SetOriginSend(nil)
	id := guardian.Schedule(cross(cur), name, "poke-fixture", guardian.MinDelayFloor)

	testing.SkipHeights(13) // 65s at 5s/height >= the 60s floor
	return id
}

func TestInitialState(t *testing.T) {
	if Admin() != testAdmin || Pot() != 0 || Pokes() != 0 || Funded() != 0 {
		t.Fatal("unexpected initial state")
	}
	if RewardFor(TaskSubExpire) != 0 || RewardFor(TaskTimelockExecute) != 0 {
		t.Fatal("rewards must default to 0")
	}
	conserved(t)
}

func TestFundAndRewardConfig(cur realm, t *testing.T) {
	fundAs(cur, funder, 100000)
	if Pot() != 100000 || Funded() != 100000 {
		t.Fatalf("pot=%d funded=%d", Pot(), Funded())
	}
	conserved(t)

	testing.SetRealm(testing.NewUserRealm(mallory))
	testing.SetOriginCaller(mallory)
	testing.SetOriginSend(nil)
	uassert.AbortsWithMessage(t, cur, "admin only", func() {
		SetReward(cross(cur), TaskSubExpire, 100)
	})

	testing.SetRealm(testing.NewUserRealm(testAdmin))
	testing.SetOriginCaller(testAdmin)
	testing.SetOriginSend(nil)
	uassert.AbortsContains(t, cur, "reward must be in", func() {
		SetReward(cross(cur), TaskSubExpire, MaxReward+1)
	})
	uassert.AbortsContains(t, cur, "unknown task", func() {
		SetReward(cross(cur), "nosuch", 1)
	})

	adminSet(cur, TaskSubExpire, 5000)
	adminSet(cur, TaskTimelockExecute, 7000)
	if RewardFor(TaskSubExpire) != 5000 || RewardFor(TaskTimelockExecute) != 7000 {
		t.Fatal("rewards not set")
	}
}

// The realm-to-realm happy path: poke the REAL subscriptions realm.
func TestPokeExpire(cur realm, t *testing.T) {
	syncHeld()
	subID := expirableSub(cur, t)

	// Downstream state before: still Active.
	_, _, _, _, _, _, status := subs.SubInfo(subID)
	if status != "active" {
		t.Fatalf("fixture status %q", status)
	}

	potBefore, balBefore := Pot(), BalanceOf(poker)
	testing.SetRealm(testing.NewUserRealm(poker))
	testing.SetOriginCaller(poker)
	testing.SetOriginSend(nil)
	PokeExpire(cross(cur), subID)

	// Downstream state changed by OUR realm's crossing call...
	_, _, _, _, _, _, status = subs.SubInfo(subID)
	if status != "expired" {
		t.Fatalf("downstream not expired: %q", status)
	}
	// ...and the reward moved pot -> caller balance atomically.
	if Pot() != potBefore-5000 || BalanceOf(poker) != balBefore+5000 {
		t.Fatalf("reward accounting wrong: pot %d->%d bal %d->%d",
			potBefore, Pot(), balBefore, BalanceOf(poker))
	}
	if Pokes() != 1 {
		t.Fatalf("pokes=%d", Pokes())
	}
	conserved(t)
}

// Replay: the downstream realm is the replay guard; a second poke on the
// same subscription aborts THERE and no reward is paid HERE.
func TestPokeExpireReplay(cur realm, t *testing.T) {
	syncHeld()
	potBefore, balBefore := Pot(), BalanceOf(mallory)
	testing.SetRealm(testing.NewUserRealm(mallory))
	testing.SetOriginCaller(mallory)
	testing.SetOriginSend(nil)
	uassert.AbortsContains(t, cur, "subscription is expired", func() {
		PokeExpire(cross(cur), 0) // the sub expired in TestPokeExpire
	})
	if Pot() != potBefore || BalanceOf(mallory) != balBefore || Pokes() != 1 {
		t.Fatal("aborted poke mutated reward state")
	}
	conserved(t)
}

// A premature poke aborts downstream ("not expirable") and pays nothing.
func TestPokeExpirePremature(cur realm, t *testing.T) {
	syncHeld()
	testing.SetRealm(testing.NewUserRealm(provider))
	testing.SetOriginCaller(provider)
	testing.SetOriginSend(nil)
	planID := subs.CreatePlan(cross(cur), "fresh", "d", 1, 5000, 1000)
	testing.SetRealm(testing.NewUserRealm(subber))
	testing.SetOriginCaller(subber)
	testing.SetOriginSend(ugnot(1))
	testing.IssueCoins(subs.Address(), ugnot(1))
	freshID := subs.Subscribe(cross(cur), planID)

	potBefore := Pot()
	testing.SetRealm(testing.NewUserRealm(poker))
	testing.SetOriginCaller(poker)
	testing.SetOriginSend(nil)
	uassert.AbortsContains(t, cur, "not expirable", func() {
		PokeExpire(cross(cur), freshID)
	})
	uassert.AbortsContains(t, cur, "unknown subscription id", func() {
		PokeExpire(cross(cur), 99999)
	})
	if Pot() != potBefore {
		t.Fatal("failed pokes touched the pot")
	}
	conserved(t)
}

// The second realm-to-realm integration: the REAL guardian realm.
func TestPokeExecute(cur realm, t *testing.T) {
	syncHeld()
	id := maturedAction(cur, t)
	potBefore, balBefore := Pot(), BalanceOf(poker)

	testing.SetRealm(testing.NewUserRealm(poker))
	testing.SetOriginCaller(poker)
	testing.SetOriginSend(nil)
	PokeExecute(cross(cur), id)

	if Pot() != potBefore-7000 || BalanceOf(poker) != balBefore+7000 {
		t.Fatal("timelock reward accounting wrong")
	}
	// Replay refused downstream.
	testing.SetRealm(testing.NewUserRealm(mallory))
	testing.SetOriginCaller(mallory)
	testing.SetOriginSend(nil)
	uassert.AbortsContains(t, cur, "already executed", func() {
		PokeExecute(cross(cur), id)
	})
	uassert.AbortsContains(t, cur, "action not found", func() {
		PokeExecute(cross(cur), "tl-nosuch")
	})
	// Premature: schedule a new one, poke before maturity.
	testing.SetRealm(testing.NewUserRealm(towner))
	testing.SetOriginCaller(towner)
	testing.SetOriginSend(nil)
	guardian.RegisterTarget(cross(cur), "ukearly", guardian.MinDelayFloor, "")
	testing.SetRealm(testing.NewUserRealm(towner))
	testing.SetOriginCaller(towner)
	testing.SetOriginSend(nil)
	early := guardian.Schedule(cross(cur), "ukearly", "x", guardian.MinDelayFloor)
	testing.SetRealm(testing.NewUserRealm(poker))
	testing.SetOriginCaller(poker)
	testing.SetOriginSend(nil)
	uassert.AbortsContains(t, cur, "too early", func() {
		PokeExecute(cross(cur), early)
	})
	conserved(t)
}

// Pot exhaustion refuses BEFORE the downstream call: no valve fires
// unrewarded through this realm. Entering here the pot is deterministic:
// 100000 funded minus the 5000 and 7000 awarded above = 88000, so four
// MaxReward pokes leave 8000 < MaxReward and the next must refuse.
func TestPotExhaustion(cur realm, t *testing.T) {
	syncHeld()
	adminSet(cur, TaskSubExpire, MaxReward)

	// Drain by REAL pokes until the pot no longer covers the reward.
	for i := 0; Pot() >= MaxReward; i++ {
		if i >= 10 {
			t.Fatalf("fixture arithmetic broken: pot=%d after %d pokes", Pot(), i)
		}
		id := expirableSub(cur, t)
		testing.SetRealm(testing.NewUserRealm(poker))
		testing.SetOriginCaller(poker)
		testing.SetOriginSend(nil)
		PokeExpire(cross(cur), id)
	}

	short := expirableSub(cur, t)
	potBefore := Pot()
	testing.SetRealm(testing.NewUserRealm(poker))
	testing.SetOriginCaller(poker)
	testing.SetOriginSend(nil)
	uassert.AbortsContains(t, cur, "reward pot cannot cover", func() {
		PokeExpire(cross(cur), short)
	})
	// Downstream MUST be untouched by the refused poke.
	_, _, _, _, _, _, status := subs.SubInfo(short)
	if status != "active" {
		t.Fatal("refused poke reached the downstream realm")
	}
	if Pot() != potBefore {
		t.Fatal("refused poke touched the pot")
	}
	conserved(t)
	adminSet(cur, TaskSubExpire, 5000) // restore for the later tests
}

// The refusal boundary, deterministic: unknown task, zero reward, and
// pot-short all refuse before any downstream effect.
func TestPokeRefusals(cur realm, t *testing.T) {
	adminSet(cur, TaskSubExpire, 0)
	testing.SetRealm(testing.NewUserRealm(poker))
	testing.SetOriginCaller(poker)
	testing.SetOriginSend(nil)
	uassert.AbortsContains(t, cur, "no reward configured", func() {
		PokeExpire(cross(cur), 0)
	})
	adminSet(cur, TaskSubExpire, 5000)

	testing.SetRealm(testing.NewUserRealm(poker))
	testing.SetOriginCaller(poker)
	testing.SetOriginSend(ugnot(5))
	uassert.AbortsWithMessage(t, cur, "this function does not accept coins", func() {
		PokeExpire(cross(cur), 0)
	})
	testing.SetRealm(testing.NewUserRealm(poker))
	testing.SetOriginCaller(poker)
	testing.SetOriginSend(ugnot(5))
	uassert.AbortsWithMessage(t, cur, "this function does not accept coins", func() {
		PokeExecute(cross(cur), "x")
	})
}

func TestClaims(cur realm, t *testing.T) {
	syncHeld()
	earned := BalanceOf(poker)
	if earned == 0 {
		t.Fatal("fixture: poker should have earnings")
	}
	before := coinsOf(poker)
	testing.SetRealm(testing.NewUserRealm(poker))
	testing.SetOriginCaller(poker)
	testing.SetOriginSend(nil)
	ClaimAll(cross(cur))
	if coinsOf(poker)-before != earned || BalanceOf(poker) != 0 {
		t.Fatal("claim did not move the earned balance")
	}
	testing.SetRealm(testing.NewUserRealm(mallory))
	testing.SetOriginCaller(mallory)
	testing.SetOriginSend(nil)
	uassert.AbortsWithMessage(t, cur, "nothing to claim", func() {
		ClaimAll(cross(cur))
	})
	uassert.AbortsContains(t, cur, "insufficient balance", func() {
		Claim(cross(cur), 1)
	})
	conserved(t)
}

func TestSweepReserve(cur realm, t *testing.T) {
	syncHeld()
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	testing.SetOriginCaller(testAdmin)
	testing.SetOriginSend(nil)
	uassert.AbortsContains(t, cur, "no surplus to sweep", func() {
		SweepDenom(cross(cur), Denom)
	})
	testing.IssueCoins(Address(), ugnot(77))
	reserveBefore := Pot() + UsersTotal()
	got := coinsOf(testAdmin)
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	testing.SetOriginCaller(testAdmin)
	testing.SetOriginSend(nil)
	SweepDenom(cross(cur), Denom)
	if coinsOf(testAdmin)-got != 77 {
		t.Fatal("sweep amount wrong")
	}
	if Pot()+UsersTotal() != reserveBefore {
		t.Fatal("sweep touched the reserve")
	}
	testing.SetRealm(testing.NewUserRealm(mallory))
	testing.SetOriginCaller(mallory)
	testing.SetOriginSend(nil)
	uassert.AbortsWithMessage(t, cur, "sweeper only", func() {
		SweepDenom(cross(cur), Denom)
	})
	conserved(t)
}

func TestAdminHandover(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	testing.SetOriginCaller(testAdmin)
	testing.SetOriginSend(nil)
	TransferAdmin(cross(cur), funder)
	testing.SetRealm(testing.NewUserRealm(mallory))
	testing.SetOriginCaller(mallory)
	testing.SetOriginSend(nil)
	uassert.AbortsWithMessage(t, cur, "only the staged successor may accept", func() {
		AcceptAdmin(cross(cur))
	})
	testing.SetRealm(testing.NewUserRealm(funder))
	testing.SetOriginCaller(funder)
	testing.SetOriginSend(nil)
	AcceptAdmin(cross(cur))
	if Admin() != funder {
		t.Fatal("authority did not move")
	}
	// Former admin locked out; sweeper moved with admin.
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	testing.SetOriginCaller(testAdmin)
	testing.SetOriginSend(nil)
	uassert.AbortsWithMessage(t, cur, "admin only", func() {
		SetReward(cross(cur), TaskSubExpire, 1)
	})
	uassert.AbortsWithMessage(t, cur, "sweeper only", func() {
		SweepDenom(cross(cur), Denom)
	})
	// Hand back.
	testing.SetRealm(testing.NewUserRealm(funder))
	testing.SetOriginCaller(funder)
	testing.SetOriginSend(nil)
	TransferAdmin(cross(cur), testAdmin)
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	testing.SetOriginCaller(testAdmin)
	testing.SetOriginSend(nil)
	AcceptAdmin(cross(cur))
}

func TestRender(t *testing.T) {
	out := Render("")
	if !strings.Contains(out, "sub_expire") || !strings.Contains(out, "timelock_execute") {
		t.Fatal("render missing task lines")
	}
	if Render("x") == Render("") {
		t.Fatal("unknown path fell through")
	}
}
