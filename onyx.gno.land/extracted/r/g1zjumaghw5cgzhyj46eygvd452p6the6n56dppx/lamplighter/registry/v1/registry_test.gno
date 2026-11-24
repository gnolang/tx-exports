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

const consumerPath = "gno.land/r/test/consumer"

var (
	registryAddr = chain.PackageAddress(realmPath)
	alice        = testutils.TestAddress("alice")
	bob          = testutils.TestAddress("bob")
)

// oil prepares a user sending ugnot along with a Fund call. The test banker
// does not move OriginSend coins by itself, so they are issued to the realm.
// Fund itself has to be called straight from the test function: the test
// runtime decides what an origin call is by counting call frames.
func oil(from address, amount int64) {
	coins := chain.Coins{{Denom, amount}}
	testing.IssueCoins(registryAddr, coins)
	testing.SetRealm(testing.NewUserRealm(from))
	testing.SetOriginSend(coins)
}

func balanceOf(addr address) int64 {
	return banker.NewReadonlyBanker().GetCoin(addr, Denom)
}

func TestRegisterOnlyFromRealm(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsWithMessage(t, cur, "only a realm can register a job", func() {
		Register(cross(cur), "x", 0, 60, 1000, func(realm) error { return nil })
	})
}

func TestRegisterValidation(cur realm, t *testing.T) {
	ok := func(realm) error { return nil }
	testing.SetRealm(testing.NewCodeRealm(consumerPath))

	uassert.AbortsWithMessage(t, cur, "callback must not be nil", func() {
		Register(cross(cur), "x", 0, 60, 1000, nil)
	})
	uassert.AbortsWithMessage(t, cur, "name must be 1 to 80 bytes", func() {
		Register(cross(cur), "", 0, 60, 1000, ok)
	})
	uassert.AbortsWithMessage(t, cur, "interval must be 0 or at least 10 seconds", func() {
		Register(cross(cur), "x", 0, 5, 1000, ok)
	})
	uassert.AbortsWithMessage(t, cur, "reward must be positive", func() {
		Register(cross(cur), "x", 0, 60, 0, ok)
	})
}

func TestRepeatingJob(cur realm, t *testing.T) {
	ticks := 0
	start := time.Now().Unix()

	testing.SetRealm(testing.NewCodeRealm(consumerPath))
	id := Register(cross(cur), "repeat", start+60, 60, 1000, func(realm) error {
		ticks++
		return nil
	})
	uassert.Equal(t, consumerPath, mustJob(id).owner)

	oil(alice, 2500)
	Fund(cross(cur), id)
	testing.SetOriginSend(nil)
	uassert.Equal(t, int64(2500), mustJob(id).balance)

	// Funded but not due.
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.False(t, IsDue(id))
	uassert.AbortsWithMessage(t, cur, "job is not due yet", func() { Exec(cross(cur), id) })

	// 13 blocks of 5s: 65s later, 5s into the first slot.
	testing.SkipHeights(13)
	uassert.True(t, IsDue(id))
	uassert.True(t, strings.Contains(","+DueJobs()+",", ","+utoa(id)+","))

	before := balanceOf(bob)
	testing.SetRealm(testing.NewUserRealm(bob))
	Exec(cross(cur), id)

	uassert.Equal(t, 1, ticks)
	uassert.Equal(t, before+1000, balanceOf(bob))
	j := mustJob(id)
	uassert.Equal(t, int64(1500), j.balance)
	uassert.Equal(t, int64(1), j.runs)
	uassert.Equal(t, bob, j.lastBy)
	// The grid holds: the next slot is start+120, not "now + 60".
	uassert.Equal(t, start+120, j.nextDue)

	// The same slot cannot be run twice.
	uassert.AbortsWithMessage(t, cur, "job is not due yet", func() { Exec(cross(cur), id) })

	// Three slots pass with nobody running the job: it runs once, not three times.
	testing.SkipHeights(36) // +180s, now start+245
	testing.SetRealm(testing.NewUserRealm(bob))
	Exec(cross(cur), id)
	uassert.Equal(t, 2, ticks)
	uassert.Equal(t, start+300, mustJob(id).nextDue)

	// 500 ugnot left cannot pay a 1000 ugnot reward.
	testing.SkipHeights(24)
	uassert.False(t, IsDue(id))
	uassert.AbortsWithMessage(t, cur, "job is out of oil", func() { Exec(cross(cur), id) })

	latest := recentRuns()[0]
	uassert.Equal(t, id, latest.job)
	uassert.Equal(t, bob, latest.by)
	uassert.Equal(t, int64(1000), latest.reward)
	uassert.Equal(t, start+245, latest.at)
}

func TestOneShotJob(cur realm, t *testing.T) {
	fired := 0
	testing.SetRealm(testing.NewCodeRealm(consumerPath))
	id := Register(cross(cur), "once", 0, 0, 700, func(realm) error {
		fired++
		return nil
	})
	oil(alice, 700)
	Fund(cross(cur), id)
	testing.SetOriginSend(nil)

	testing.SetRealm(testing.NewUserRealm(bob))
	Exec(cross(cur), id)
	uassert.Equal(t, 1, fired)
	uassert.True(t, mustJob(id).finished)

	uassert.AbortsWithMessage(t, cur, "job has already run", func() { Exec(cross(cur), id) })
	uassert.PanicsWithMessage(t, cur, "job is no longer open", func() {
		deposit(id, chain.Coins{{Denom, 1}})
	})
}

func TestFailingCallbackAborts(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewCodeRealm(consumerPath))
	id := Register(cross(cur), "broken", 0, 60, 1000, func(realm) error {
		return errors.New("tap is jammed")
	})
	oil(alice, 5000)
	Fund(cross(cur), id)
	testing.SetOriginSend(nil)

	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsWithMessage(t, cur, "job failed: tap is jammed", func() { Exec(cross(cur), id) })

	// On chain the abort reverts the whole transaction. The test runtime
	// keeps the half-applied state, so undo the lock by hand.
	busy = false
}

func TestCallbackSeesRegistryAsCaller(cur realm, t *testing.T) {
	seen := ""
	testing.SetRealm(testing.NewCodeRealm(consumerPath))
	id := Register(cross(cur), "who calls", 0, 60, 1000, func(cur realm) error {
		seen = cur.Previous().PkgPath()
		return nil
	})
	oil(alice, 1000)
	Fund(cross(cur), id)
	testing.SetOriginSend(nil)

	testing.SetRealm(testing.NewUserRealm(bob))
	Exec(cross(cur), id)
	uassert.Equal(t, realmPath, seen)
}

// The refusals are tested on deposit, the part of Fund after the origin-call
// check: the test runtime only treats a call made straight from the test
// function as an origin call, which rules out wrapping Fund in an assertion.
func TestFundRejectsOtherCoins(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewCodeRealm(consumerPath))
	id := Register(cross(cur), "fund me", 0, 60, 1000, func(realm) error { return nil })

	uassert.PanicsWithMessage(t, cur, "send only ugnot", func() {
		deposit(id, chain.Coins{{"other", 5}})
	})
	uassert.PanicsWithMessage(t, cur, "send only ugnot", func() {
		deposit(id, chain.Coins{{Denom, 5}, {"other", 5}})
	})
	uassert.PanicsWithMessage(t, cur, "send only ugnot", func() { deposit(id, nil) })
	uassert.PanicsWithMessage(t, cur, "unknown job 999999", func() {
		deposit(999999, chain.Coins{{Denom, 5}})
	})
	uassert.Equal(t, int64(0), mustJob(id).balance)
}

func TestCancel(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewCodeRealm(consumerPath))
	id := Register(cross(cur), "cancel me", 0, 60, 1000, func(realm) error { return nil })
	oil(alice, 3000)
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

	before := balanceOf(alice)
	testing.SetRealm(testing.NewCodeRealm(consumerPath))
	Cancel(cross(cur), id, alice)
	uassert.Equal(t, before+3000, balanceOf(alice))
	uassert.True(t, mustJob(id).closed)
	uassert.False(t, IsDue(id))

	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsWithMessage(t, cur, "job is closed", func() { Exec(cross(cur), id) })
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

func TestNextSlot(t *testing.T) {
	cases := []struct {
		due, interval, now, want int64
	}{
		{100, 60, 100, 160}, // run exactly on time
		{100, 60, 159, 160}, // run late within the slot
		{100, 60, 160, 220}, // run exactly one slot late
		{100, 60, 400, 460}, // five slots missed: skip them
		{100, 60, 50, 160},  // defensive: run before due
	}
	for _, c := range cases {
		uassert.Equal(t, c.want, nextSlot(c.due, c.interval, c.now))
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
	uassert.Equal(t, "a/b (c)", cell("a|b [c]"))
}

func TestRender(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewCodeRealm(consumerPath))
	id := Register(cross(cur), "render | me", 0, 3600, 1000, func(realm) error { return nil })
	oil(alice, 1000)
	Fund(cross(cur), id)
	testing.SetOriginSend(nil)

	home := Render("")
	uassert.True(t, strings.Contains(home, "# Lamplighter"))
	uassert.True(t, strings.Contains(home, "render / me"))
	uassert.True(t, strings.Contains(home, "**due now**"))

	testing.SetRealm(testing.NewUserRealm(bob))
	Exec(cross(cur), id)
	uassert.True(t, strings.Contains(Render(""), "| "+bob.String()+" | 0.001 GNOT |"))

	page := Render("job/" + utoa(id))
	uassert.True(t, strings.Contains(page, "`"+consumerPath+"`"))
	uassert.True(t, strings.Contains(page, "Last run:"))

	uassert.True(t, strings.Contains(Render("job/999999"), "404"))
	uassert.True(t, strings.Contains(Render("nope"), "404"))
}
