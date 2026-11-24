package registry

import (
	"chain"
	"chain/banker"
	"errors"
	"strings"
	"testing"
	"time"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

const (
	wantPath     = "gno.land/r/g1zjumaghw5cgzhyj46eygvd452p6the6n56dppx/lamplighter/registry/v2"
	consumerPath = "gno.land/r/test/consumer"
)

var (
	registryAddr = chain.PackageAddress(wantPath)
	alice        = testutils.TestAddress("alice")
	bob          = testutils.TestAddress("bob")
)

func nop(realm, uint64) error { return nil }

// settle makes the test bank agree with the realm's books. The test runtime
// starts every test function with empty balances but keeps the realm's state,
// so coins that earlier tests left in open jobs have to be issued again.
func settle() {
	if missing := held - balanceOf(registryAddr); missing > 0 {
		testing.IssueCoins(registryAddr, chain.Coins{{Denom, missing}})
	}
}

// post registers a job as the consumer realm.
func post(cur realm, name string, firstDue, interval, reward int64, cb func(realm, uint64) error) uint64 {
	settle()
	testing.SetRealm(testing.NewCodeRealm(consumerPath))
	return Register(cross(cur), name, firstDue, interval, reward, cb)
}

// oil attaches ugnot to the next Fund call. The test banker does not move
// OriginSend coins by itself, so they are issued to the realm.
//
// Two things have to stay in the test function itself, because the test
// runtime ties them to its call frame: choosing who is calling
// (testing.SetRealm), and the Fund call, which must be a direct one.
func oil(amount int64) {
	coins := chain.Coins{{Denom, amount}}
	testing.IssueCoins(registryAddr, coins)
	testing.SetOriginSend(coins)
}

func balanceOf(addr address) int64 {
	return banker.NewReadonlyBanker().GetCoin(addr, Denom)
}

// checkBooks asserts the invariants everything else rests on: the coins the
// realm really holds cover what its jobs are owed, and every open job is filed
// in the queue under the one key that matches its state.
func checkBooks(t *testing.T) {
	t.Helper()
	var sum int64
	jobs.Iterate("", "", func(_ string, v any) bool {
		j := v.(*job)
		sum += j.balance

		want := parkKey(j.id)
		if !j.done && j.balance >= j.reward {
			want = dueKey(j.nextDue, j.id)
		}
		uassert.Equal(t, want, j.slot, "job "+utoa(j.id)+" is filed under the wrong key")
		filed, _ := queue.Get(j.slot).(*job)
		uassert.True(t, filed == j, "job "+utoa(j.id)+" is not in the queue under its key")
		return false
	})
	uassert.Equal(t, jobs.Size(), queue.Size(), "the queue holds exactly the registered jobs")
	uassert.Equal(t, held, sum, "held must equal the sum of job balances")
	uassert.True(t, balanceOf(registryAddr) >= held,
		"the realm holds "+itoa(balanceOf(registryAddr))+" but its jobs are owed "+itoa(held))
}

func TestPath(t *testing.T) {
	uassert.Equal(t, wantPath, Path())
}

func TestRegisterOnlyFromRealm(cur realm, t *testing.T) {
	// A `maketx run` script is refused too (IsEphemeral), but the test
	// runtime cannot impersonate one; that case is covered on a real chain.
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsWithMessage(t, cur, "only a deployed realm can register a job", func() {
		Register(cross(cur), "x", 0, 60, MinReward, nop)
	})
}

func TestRegisterValidation(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewCodeRealm(consumerPath))
	now := time.Now().Unix()

	uassert.AbortsWithMessage(t, cur, "callback must not be nil", func() {
		Register(cross(cur), "x", 0, 60, MinReward, nil)
	})
	for _, name := range []string{
		"", strings.Repeat("a", MaxNameLen+1), "two\nlines", "tab\there", "bad\xffutf8", "bell\x07",
		"   ", "\u200b\u200b", "next\u0085line",
	} {
		uassert.AbortsWithMessage(t, cur, "name must be 1 to 80 bytes of printable text", func() {
			Register(cross(cur), name, 0, 60, MinReward, nop)
		})
	}
	for _, interval := range []int64{-1, 1, MinInterval - 1, MaxInterval + 1, 1<<63 - 1} {
		uassert.AbortsWithMessage(t, cur, "interval must be 0, or 10 to 315360000 seconds", func() {
			Register(cross(cur), "x", 0, interval, MinReward, nop)
		})
	}
	for _, reward := range []int64{-5, 0, MinReward - 1} {
		uassert.AbortsWithMessage(t, cur, "reward must be at least 1000 ugnot", func() {
			Register(cross(cur), "x", 0, 60, reward, nop)
		})
	}
	for _, firstDue := range []int64{now + MaxDelay + 1, 1<<63 - 1} {
		uassert.AbortsWithMessage(t, cur, "first run is too far in the future", func() {
			Register(cross(cur), "x", firstDue, 60, MinReward, nop)
		})
	}

	// The limits themselves are accepted.
	id := Register(cross(cur), strings.Repeat("a", MaxNameLen), now+MaxDelay, MaxInterval, MinReward, nop)
	uassert.True(t, Exists(id))
	uassert.Equal(t, now+MaxDelay, NextDue(id))
}

func TestRepeatingJob(cur realm, t *testing.T) {
	ticks := 0
	var gotID uint64
	start := time.Now().Unix()

	id := post(cur, "repeat", start+60, 60, 1000, func(_ realm, job uint64) error {
		ticks++
		gotID = job
		return nil
	})
	uassert.Equal(t, consumerPath, Owner(id))
	uassert.Equal(t, int64(1000), Reward(id))

	testing.SetRealm(testing.NewUserRealm(alice))
	oil(2500)
	Fund(cross(cur), id)
	testing.SetOriginSend(nil)
	uassert.Equal(t, int64(2500), Balance(id))
	checkBooks(t)

	// Funded but not due.
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.False(t, IsDue(id))
	uassert.False(t, strings.Contains(","+DueJobs(0, 0, 0), ","+utoa(id)+":"))
	uassert.AbortsWithMessage(t, cur, "job is not due yet", func() { Exec(cross(cur), id) })

	// 13 blocks of 5s: 65s later, 5s into the first slot.
	testing.SkipHeights(13)
	uassert.True(t, IsDue(id))
	uassert.True(t, strings.Contains(","+DueJobs(0, 0, 0)+",", ","+utoa(id)+":1000:"+itoa(start+60)+","))

	before := balanceOf(bob)
	testing.SetRealm(testing.NewUserRealm(bob))
	Exec(cross(cur), id)

	uassert.Equal(t, 1, ticks)
	uassert.Equal(t, id, gotID, "the callback is told which job is running")
	uassert.Equal(t, before+1000, balanceOf(bob))
	uassert.Equal(t, int64(1500), Balance(id))
	// The grid holds: the next slot is start+120, not "now + 60".
	uassert.Equal(t, start+120, NextDue(id))
	checkBooks(t)

	// The same slot cannot be run twice.
	uassert.AbortsWithMessage(t, cur, "job is not due yet", func() { Exec(cross(cur), id) })

	// Three slots pass with nobody running the job: it runs once, not three times.
	testing.SkipHeights(36) // +180s, now start+245
	testing.SetRealm(testing.NewUserRealm(bob))
	Exec(cross(cur), id)
	uassert.Equal(t, 2, ticks)
	uassert.Equal(t, start+300, NextDue(id))

	// 500 ugnot left cannot pay a 1000 ugnot reward: the job leaves the queue.
	testing.SkipHeights(24)
	uassert.False(t, IsDue(id))
	uassert.False(t, strings.Contains(","+DueJobs(0, 0, 0), ","+utoa(id)+":"))
	uassert.AbortsWithMessage(t, cur, "job is out of oil", func() { Exec(cross(cur), id) })
	checkBooks(t)

	latest := recentRuns()[0]
	uassert.Equal(t, id, latest.job)
	uassert.Equal(t, bob, latest.by)
	uassert.Equal(t, int64(1000), latest.reward)
	uassert.Equal(t, start+245, latest.at)
}

func TestOneShotJob(cur realm, t *testing.T) {
	fired := 0
	id := post(cur, "once", 0, 0, 1500, func(realm, uint64) error {
		fired++
		return nil
	})

	// A job that runs once can only ever spend one reward.
	uassert.PanicsWithMessage(t, cur, "a job that runs once holds one reward, 1500 ugnot", func() {
		deposit(mustJob(id), 1501)
	})
	testing.SetRealm(testing.NewUserRealm(alice))
	oil(1500)
	Fund(cross(cur), id)
	testing.SetOriginSend(nil)

	testing.SetRealm(testing.NewUserRealm(bob))
	Exec(cross(cur), id)
	uassert.Equal(t, 1, fired)

	// It is done, and stays registered until its owner cancels it: the run
	// itself frees nothing, so it pays its reward and nothing else.
	uassert.True(t, Exists(id))
	uassert.True(t, Done(id))
	uassert.False(t, IsDue(id))
	uassert.Equal(t, int64(0), Balance(id))
	uassert.False(t, strings.Contains(","+DueJobs(0, 0, 0), ","+utoa(id)+":"))
	uassert.AbortsWithMessage(t, cur, "job has already run", func() { Exec(cross(cur), id) })
	uassert.PanicsWithMessage(t, cur, "job has already run", func() { deposit(mustJob(id), 1500) })
	uassert.PanicsWithMessage(t, cur, "unknown job 999999", func() { mustJob(999999) })
	checkBooks(t)

	// The owner cleans it up.
	testing.SetRealm(testing.NewCodeRealm(consumerPath))
	Cancel(cross(cur), id, alice)
	uassert.False(t, Exists(id))
	uassert.False(t, Done(id))
	uassert.PanicsWithMessage(t, cur, "job "+utoa(id)+" was cancelled", func() { mustJob(id) })
	checkBooks(t)
}

func TestFailingCallbackAborts(cur realm, t *testing.T) {
	id := post(cur, "broken", 0, 60, 1000, func(realm, uint64) error {
		return errors.New("tap is jammed")
	})
	testing.SetRealm(testing.NewUserRealm(alice))
	oil(5000)
	Fund(cross(cur), id)
	testing.SetOriginSend(nil)

	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsWithMessage(t, cur, "job failed: tap is jammed", func() { Exec(cross(cur), id) })

	// On chain the abort reverts the whole transaction. The test runtime
	// keeps the half-applied state, so put back what Exec had changed.
	running = 0
	j := mustJob(id)
	j.balance += j.reward
	held += j.reward
	j.runs--
	j.nextDue = time.Now().Unix()
	index(j)
	checkBooks(t)
}

func TestCallbackSeesRegistryAsCaller(cur realm, t *testing.T) {
	seen := ""
	id := post(cur, "who calls", 0, 60, 1000, func(cur realm, _ uint64) error {
		seen = cur.Previous().PkgPath()
		return nil
	})
	testing.SetRealm(testing.NewUserRealm(alice))
	oil(1000)
	Fund(cross(cur), id)
	testing.SetOriginSend(nil)

	testing.SetRealm(testing.NewUserRealm(bob))
	Exec(cross(cur), id)
	uassert.Equal(t, wantPath, seen)
}

// A callback must not be able to run a job, its own or another, or to take
// unaccounted coins, while the registry is in the middle of a run.
func TestReentrancyIsRefused(cur realm, t *testing.T) {
	other := post(cur, "other", 0, 60, 1000, nop)
	testing.SetRealm(testing.NewUserRealm(alice))
	oil(1000)
	Fund(cross(cur), other)
	testing.SetOriginSend(nil)

	var attempt func(cur realm, id uint64)
	id := post(cur, "reenter", 0, 60, 1000, func(cur realm, id uint64) error {
		attempt(cur, id)
		return nil
	})
	testing.SetRealm(testing.NewUserRealm(alice))
	oil(5000)
	Fund(cross(cur), id)
	testing.SetOriginSend(nil)

	attempts := map[string]func(cur realm, id uint64){
		"its own job":    func(cur realm, id uint64) { Exec(cross(cur), id) },
		"another job":    func(cur realm, _ uint64) { Exec(cross(cur), other) },
		"credit":         func(cur realm, id uint64) { Credit(cross(cur), id, 1) },
		"cancel another": func(cur realm, _ uint64) { Cancel(cross(cur), other, alice) },
	}
	for name, fn := range attempts {
		attempt = fn
		testing.SetRealm(testing.NewUserRealm(bob))
		uassert.AbortsWithMessage(t, cur, "reentrant call", func() { Exec(cross(cur), id) }, name)

		// Undo the half-applied run, as the chain would.
		running = 0
		j := mustJob(id)
		j.balance += j.reward
		held += j.reward
		j.runs--
		j.nextDue = time.Now().Unix()
		index(j)
	}
	checkBooks(t)
}

// What a callback may do: post a new job. It cannot be run in the same
// transaction, because the registry is still locked.
func TestCallbackMayRegister(cur realm, t *testing.T) {
	var posted uint64
	testing.SetRealm(testing.NewCodeRealm(wantPath))
	settle()
	id := Register(cross(cur), "posts another", 0, 60, 1000, func(cur realm, _ uint64) error {
		posted = Register(cross(cur), "posted from a callback", 0, 60, 1000, nop)
		return nil
	})
	testing.SetRealm(testing.NewUserRealm(alice))
	oil(1000)
	Fund(cross(cur), id)
	testing.SetOriginSend(nil)

	testing.SetRealm(testing.NewUserRealm(bob))
	Exec(cross(cur), id)
	uassert.True(t, Exists(posted))
	uassert.Equal(t, wantPath, Owner(posted))
	checkBooks(t)
}

// A job that runs once may cancel itself from its callback, which frees its
// state in the same transaction. The run is still paid.
func TestOneShotCancelsItself(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewCodeRealm(wantPath))
	settle()
	id := Register(cross(cur), "once, then gone", 0, 0, 1000, func(cur realm, id uint64) error {
		Cancel(cross(cur), id, alice)
		return nil
	})
	testing.SetRealm(testing.NewUserRealm(alice))
	oil(1000)
	Fund(cross(cur), id)
	testing.SetOriginSend(nil)

	before := balanceOf(bob)
	testing.SetRealm(testing.NewUserRealm(bob))
	Exec(cross(cur), id)
	uassert.Equal(t, before+1000, balanceOf(bob))
	uassert.False(t, Exists(id))
	checkBooks(t)
}

// A repeating job may end itself from its own callback. That run is paid and
// the rest of the oil goes where the owner says.
func TestJobCancelsItself(cur realm, t *testing.T) {
	// The callback below is declared in this package, so the realm it runs
	// in, and therefore the only realm that can own the job, is this one.
	settle()
	testing.SetRealm(testing.NewCodeRealm(wantPath))
	id := Register(cross(cur), "last call", 0, 60, 1000, func(cur realm, id uint64) error {
		Cancel(cross(cur), id, alice)
		return nil
	})
	testing.SetRealm(testing.NewUserRealm(alice))
	oil(3000)
	Fund(cross(cur), id)
	testing.SetOriginSend(nil)

	aliceBefore, bobBefore := balanceOf(alice), balanceOf(bob)
	testing.SetRealm(testing.NewUserRealm(bob))
	Exec(cross(cur), id)

	uassert.Equal(t, bobBefore+1000, balanceOf(bob), "the run that cancelled is still paid")
	uassert.Equal(t, aliceBefore+2000, balanceOf(alice), "the remainder is refunded")
	uassert.False(t, Exists(id))
	checkBooks(t)
}

func TestFundTakesOnlyUgnot(cur realm, t *testing.T) {
	uassert.Equal(t, int64(5), oilIn(chain.Coins{{Denom, 5}}))
	for _, sent := range []chain.Coins{nil, {{"other", 5}}, {{Denom, 5}, {"other", 5}}, {{Denom, 0}}} {
		uassert.PanicsWithMessage(t, cur, "send only ugnot", func() { oilIn(sent) })
	}
}

// Fund reads the coins sent with the transaction, which are only the caller's
// own when the transaction called Fund directly.
func TestFundMustBeCalledDirectly(cur realm, t *testing.T) {
	id := post(cur, "direct only", 0, 60, 1000, nop)
	testing.SetRealm(testing.NewUserRealm(alice))
	oil(1000)
	// The closure puts one more call between the transaction and Fund.
	uassert.AbortsWithMessage(t, cur, "invalid non-origin call", func() { Fund(cross(cur), id) })
	testing.SetOriginSend(nil)
	uassert.Equal(t, int64(0), Balance(id))

	// The coins issued for that refused call are still unaccounted: clear them.
	testing.SetRealm(testing.NewCodeRealm(consumerPath))
	Credit(cross(cur), id, Unaccounted())
	checkBooks(t)
}

// A realm funds a job by sending coins here and calling Credit for the amount.
func TestCredit(cur realm, t *testing.T) {
	id := post(cur, "credit me", 0, 60, 1000, nop)
	once := post(cur, "credit me once", 0, 0, 1500, nop)
	uassert.Equal(t, int64(0), Unaccounted())

	testing.SetRealm(testing.NewCodeRealm(consumerPath))
	refused := "credit more than 0 and no more than the 0 ugnot not yet accounted to a job"
	uassert.AbortsWithMessage(t, cur, refused, func() { Credit(cross(cur), id, 1) })

	testing.IssueCoins(registryAddr, chain.Coins{{Denom, 4000}}) // a banker send from another realm
	uassert.Equal(t, int64(4000), Unaccounted())
	uassert.False(t, IsDue(id))
	for _, bad := range []int64{0, -5, 4001} {
		uassert.AbortsWithMessage(t, cur,
			"credit more than 0 and no more than the 4000 ugnot not yet accounted to a job",
			func() { Credit(cross(cur), id, bad) })
	}
	Credit(cross(cur), id, 2500)
	uassert.Equal(t, int64(2500), Balance(id))
	uassert.True(t, IsDue(id), "a credited job joins the queue")
	uassert.Equal(t, int64(1500), Unaccounted())

	// Coins a stranger leaves here must not get in the way of funding a job
	// that takes an exact amount: the caller says how much, and gets that.
	testing.IssueCoins(registryAddr, chain.Coins{{Denom, 1}})
	Credit(cross(cur), once, 1500)
	uassert.Equal(t, int64(1500), Balance(once))
	uassert.Equal(t, int64(1), Unaccounted(), "the stranger's coin is still nobody's")
	uassert.AbortsWithMessage(t, cur, "a job that runs once holds one reward, 1500 ugnot",
		func() { Credit(cross(cur), once, 1) })
	checkBooks(t)

	Credit(cross(cur), id, 1) // sweep the stray coin so later tests start clean
}

func TestCancel(cur realm, t *testing.T) {
	id := post(cur, "cancel me", 0, 60, 1000, nop)
	testing.SetRealm(testing.NewUserRealm(alice))
	oil(3000)
	Fund(cross(cur), id)
	testing.SetOriginSend(nil)

	// A user, and another realm, are both refused.
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsWithMessage(t, cur, "only the owner realm can cancel a job", func() {
		Cancel(cross(cur), id, bob)
	})
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/test/other"))
	uassert.AbortsWithMessage(t, cur, "only the owner realm can cancel a job", func() {
		Cancel(cross(cur), id, bob)
	})
	testing.SetRealm(testing.NewCodeRealm(consumerPath))
	uassert.AbortsWithMessage(t, cur, "invalid refund address", func() {
		Cancel(cross(cur), id, address("nonsense"))
	})

	before := balanceOf(alice)
	testing.SetRealm(testing.NewCodeRealm(consumerPath))
	Cancel(cross(cur), id, alice)
	uassert.Equal(t, before+3000, balanceOf(alice))
	uassert.False(t, Exists(id))
	uassert.False(t, IsDue(id))
	checkBooks(t)

	gone := "job " + utoa(id) + " was cancelled"
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsWithMessage(t, cur, gone, func() { Exec(cross(cur), id) })
	testing.SetRealm(testing.NewCodeRealm(consumerPath))
	uassert.AbortsWithMessage(t, cur, gone, func() { Cancel(cross(cur), id, alice) })
}

// DueJobs lists only jobs that can run now, the longest overdue first, and
// reads on from wherever the caller left off.
func TestDueJobsOrderAndPaging(cur realm, t *testing.T) {
	// Drain what earlier tests left runnable, so the list starts empty.
	settle()
	jobs.Iterate("", "", func(_ string, v any) bool {
		j := v.(*job)
		held -= j.balance
		j.balance = 0
		index(j)
		return false
	})
	uassert.Equal(t, "", DueJobs(0, 0, 0))
	checkBooks(t)

	now := time.Now().Unix()
	late := post(cur, "due in 100s", now+100, 60, 3000, nop)
	soon := post(cur, "due in 50s", now+50, 60, 2000, nop)
	never := post(cur, "far away", now+100000, 60, 1000, nop)
	unfunded := post(cur, "no oil", now+50, 60, 1000, nop)
	for _, id := range []uint64{late, soon, never} {
		testing.IssueCoins(registryAddr, chain.Coins{{Denom, 5000}})
		testing.SetRealm(testing.NewCodeRealm(consumerPath))
		Credit(cross(cur), id, 5000)
	}
	checkBooks(t)

	uassert.Equal(t, "", DueJobs(0, 0, 0), "nothing is due yet")
	testing.SkipHeights(12) // +60s
	first := utoa(soon) + ":2000:" + itoa(now+50)
	second := utoa(late) + ":3000:" + itoa(now+100)
	uassert.Equal(t, first, DueJobs(0, 0, 0))
	testing.SkipHeights(12) // +120s
	uassert.Equal(t, first+","+second, DueJobs(0, 0, 0), "longest overdue first; unfunded and future jobs are absent")
	uassert.Equal(t, first+","+second, DueJobs(0, 0, 100000), "a silly limit is clamped")

	// Reading on: one entry at a time, each call starting after the last entry seen.
	uassert.Equal(t, first, DueJobs(0, 0, 1))
	uassert.Equal(t, second, DueJobs(now+50, soon, 1))
	uassert.Equal(t, "", DueJobs(now+100, late, 1))
	// A cursor that names no existing entry still lands in the right place.
	uassert.Equal(t, second, DueJobs(now+75, 0, 5))
	uassert.Equal(t, first+","+second, DueJobs(-9, 0, 5))

	uassert.False(t, IsDue(unfunded))
	uassert.False(t, IsDue(never))
}

func TestNextSlot(t *testing.T) {
	cases := []struct {
		due, interval, now, want int64
	}{
		{100, 60, 100, 160}, // run exactly on time
		{100, 60, 159, 160}, // run late within the slot
		{100, 60, 160, 220}, // run exactly one slot late
		{100, 60, 400, 460}, // five slots missed: skip them
	}
	for _, c := range cases {
		uassert.Equal(t, c.want, nextSlot(c.due, c.interval, c.now))
	}

	// The widest values Register accepts stay far from overflow.
	far := time.Now().Unix() + MaxDelay
	uassert.True(t, nextSlot(far, MaxInterval, far) > far)
}

func TestRecentRunsRing(t *testing.T) {
	// Write more runs than the ring holds: only the newest survive, newest first.
	for i := int64(1); i <= recentSize+3; i++ {
		remember(uint64(100+i), alice, 5000+i, i)
	}
	runs := recentRuns()
	uassert.Equal(t, recentSize, len(runs))
	uassert.Equal(t, uint64(100+recentSize+3), runs[0].job)
	uassert.Equal(t, uint64(100+4), runs[recentSize-1].job)
	for i := 1; i < len(runs); i++ {
		uassert.True(t, runs[i-1].at > runs[i].at)
	}
}

func TestFormatting(t *testing.T) {
	uassert.Equal(t, "0 GNOT", gnot(0))
	uassert.Equal(t, "1 GNOT", gnot(1000000))
	uassert.Equal(t, "0.1 GNOT", gnot(100000))
	uassert.Equal(t, "2.000001 GNOT", gnot(2000001))
	uassert.Equal(t, "0s", span(0))
	uassert.Equal(t, "30s", span(30))
	uassert.Equal(t, "1m30s", span(90))
	uassert.Equal(t, "1h", span(3600))
	uassert.Equal(t, "1d1h", span(90061))
	uassert.Equal(t, "0 runs", plural(0, "run"))
	uassert.Equal(t, "1 run", plural(1, "run"))
	uassert.Equal(t, "2 runs", plural(2, "run"))
	uassert.Equal(t, "1970-01-01 00:01:40 UTC", clock(100))
	uassert.Equal(t, "[/r/demo/x](/r/demo/x)", realmLink("gno.land/r/demo/x"))
	uassert.Equal(t,
		"[/r/g1zjum…dppx/tap/v2](/r/g1zjumaghw5cgzhyj46eygvd452p6the6n56dppx/tap/v2)",
		realmLink("gno.land/r/g1zjumaghw5cgzhyj46eygvd452p6the6n56dppx/tap/v2"))
}

func TestRender(cur realm, t *testing.T) {
	// A name made to look like a status, a link and a table break.
	id := post(cur, "**due now** [x](http://evil) | row", 0, 3600, 1000, nop)
	testing.SetRealm(testing.NewUserRealm(alice))
	oil(1000)
	Fund(cross(cur), id)
	testing.SetOriginSend(nil)

	home := Render("")
	uassert.True(t, strings.Contains(home, "# Lamplighter"))
	uassert.True(t, strings.Contains(home, "## Post a job from your realm"))
	uassert.True(t, strings.Contains(home, `import "`+wantPath+`"`))
	uassert.False(t, strings.Contains(home, "(http://evil)"), "a name cannot plant a link")
	uassert.False(t, strings.Contains(home, "[**due now** "), "a name cannot fake a status")

	prefix := "/r/g1zjumaghw5cgzhyj46eygvd452p6the6n56dppx/lamplighter/registry/v2"
	page := Render("job/" + utoa(id))
	uassert.True(t, strings.Contains(page, "**Status:** **due now**"))
	uassert.True(t, strings.Contains(page, "("+prefix+"$help&func=Exec&id="+utoa(id)+")"), "the run link names this realm")
	uassert.True(t, strings.Contains(page, prefix+"$help&func=Fund&"), "the fund link names this realm")
	uassert.True(t, strings.Contains(page, "-max-deposit 10000ugnot"))
	uassert.True(t, strings.Contains(page, "[/r/test/consumer](/r/test/consumer)"))

	testing.SetRealm(testing.NewUserRealm(bob))
	Exec(cross(cur), id)
	uassert.True(t, strings.Contains(Render(""), "| "+bob.String()+" | 0.001 GNOT |"))
	uassert.True(t, strings.Contains(Render("job/"+utoa(id)), "**Last run:**"))

	once := post(cur, "gone soon", 0, 0, 1000, nop)
	// The fund link of a job that runs once offers exactly what it still needs.
	uassert.True(t, strings.Contains(Render("job/"+utoa(once)), ".send=1000ugnot"))
	testing.IssueCoins(registryAddr, chain.Coins{{Denom, 1000}})
	testing.SetRealm(testing.NewCodeRealm(consumerPath))
	Credit(cross(cur), once, 1000)
	uassert.True(t, strings.Contains(Render("job/"+utoa(once)), "already holds its reward"))
	uassert.False(t, strings.Contains(Render("job/"+utoa(once)), "func=Fund"))
	testing.SetRealm(testing.NewUserRealm(bob))
	Exec(cross(cur), once)
	uassert.True(t, strings.Contains(Render("job/"+utoa(once)), "ran once and is done"))
	uassert.True(t, strings.Contains(Render(""), "| done |"))
	testing.SetRealm(testing.NewCodeRealm(consumerPath))
	Cancel(cross(cur), once, alice)
	uassert.True(t, strings.Contains(Render("job/"+utoa(once)), "This job was cancelled"))

	uassert.True(t, strings.Contains(Render("job/999999"), "# 404"))
	uassert.True(t, strings.Contains(Render("job/abc"), "# 404"))
	uassert.True(t, strings.Contains(Render("page/0"), "# 404"))
	uassert.True(t, strings.Contains(Render("nope"), "# 404"))
}

func TestRenderPages(cur realm, t *testing.T) {
	for jobs.Size() <= 2*pageSize {
		post(cur, "filler", 0, 3600, 1000, nop)
	}
	first := Render("")
	uassert.True(t, strings.Contains(first, "Page 1 of 3"))
	uassert.True(t, strings.Contains(first, ":page/2)"))
	uassert.False(t, strings.Contains(first, "previous"))

	last := Render("page/3")
	uassert.True(t, strings.Contains(last, "Page 3 of 3"))
	uassert.True(t, strings.Contains(last, "previous"))
	uassert.False(t, strings.Contains(last, "[next]"))
	// A full page lists exactly pageSize jobs, each with two links to its page.
	table, _, _ := strings.Cut(first, "## Recent runs")
	uassert.Equal(t, 2*pageSize, strings.Count(table, ":job/"))

	uassert.True(t, strings.Contains(Render("page/99"), "No such page"))
}
