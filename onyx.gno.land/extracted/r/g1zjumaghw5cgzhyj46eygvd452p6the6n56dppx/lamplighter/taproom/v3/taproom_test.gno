package taproom

import (
	"chain"
	"chain/banker"
	"strings"
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
	"gno.land/r/g1zjumaghw5cgzhyj46eygvd452p6the6n56dppx/lamplighter/registry/v2"
)

var (
	registryAddr = chain.PackageAddress(registry.Path())
	patron       = testutils.TestAddress("patron")
	lighter      = testutils.TestAddress("lighter")
)

func ugnotOf(addr address) int64 {
	return banker.NewReadonlyBanker().GetCoin(addr, registry.Denom)
}

// restock gives the registry back the coins the taproom's job holds. The test
// runtime starts every test function with empty balances but keeps realm
// state, so the oil an earlier test left in the job has to be issued again.
func restock() {
	if left := registry.Balance(JobID()); left > 0 {
		testing.IssueCoins(registryAddr, chain.Coins{{registry.Denom, left}})
	}
}

// Nothing is posted until the keeper opens the taproom, and only the keeper
// can, once.
func TestOnlyTheKeeperOpens(cur realm, t *testing.T) {
	uassert.Equal(t, uint64(0), JobID())
	uassert.True(t, strings.Contains(Render(""), "The taproom has not opened yet"))
	uassert.False(t, strings.Contains(Render(""), "/lamplighter/registry/v2:job/"))

	testing.SetRealm(testing.NewUserRealm(lighter))
	uassert.AbortsWithMessage(t, cur, "only the keeper can open the taproom", func() { Open(cross(cur)) })
	testing.SetRealm(testing.NewUserRealm(keeper))
	uassert.AbortsWithMessage(t, cur, "the taproom is not open", func() { Close(cross(cur)) })
	uassert.Equal(t, uint64(0), JobID())

	Open(cross(cur))
	uassert.True(t, JobID() != 0)
	uassert.True(t, registry.Exists(JobID()))
	uassert.Equal(t, registry.NextDue(JobID()), since+rotateEvery)
	uassert.AbortsWithMessage(t, cur, "the taproom is already open", func() { Open(cross(cur)) })
}

// The whole point of the project in one test: this realm registered a
// callback with another realm, and a stranger calling that other realm
// changes this realm's state and is paid for it.
func TestStrangerRotatesTheTap(cur realm, t *testing.T) {
	uassert.Equal(t, "Gnomish Amber", OnTap())
	uassert.Equal(t, int64(0), Rotations())
	uassert.True(t, strings.Contains(Render(""), "The job is out of oil"))

	// A patron funds three rotations.
	oil := chain.Coins{{registry.Denom, 3 * reward}}
	testing.IssueCoins(registryAddr, oil)
	testing.SetRealm(testing.NewUserRealm(patron))
	testing.SetOriginSend(oil)
	registry.Fund(cross(cur), JobID())
	testing.SetOriginSend(nil)
	uassert.True(t, strings.Contains(Render(""), "Next change in 300 seconds"))

	// Too early.
	testing.SetRealm(testing.NewUserRealm(lighter))
	uassert.False(t, registry.IsDue(JobID()))
	uassert.AbortsWithMessage(t, cur, "job is not due yet", func() {
		registry.Exec(cross(cur), JobID())
	})

	// 61 blocks of 5s is 305s, past the 300s rotation.
	testing.SkipHeights(61)
	uassert.True(t, registry.IsDue(JobID()))
	uassert.True(t, strings.Contains(Render(""), "The next change is due now"))

	before := ugnotOf(lighter)
	testing.SetRealm(testing.NewUserRealm(lighter))
	registry.Exec(cross(cur), JobID())

	uassert.Equal(t, "Deep Root Stout", OnTap())
	uassert.Equal(t, int64(1), Rotations())
	uassert.Equal(t, before+reward, ugnotOf(lighter))

	// Same slot again is refused; the next slot works.
	uassert.AbortsWithMessage(t, cur, "job is not due yet", func() {
		registry.Exec(cross(cur), JobID())
	})
	testing.SkipHeights(60)
	testing.SetRealm(testing.NewUserRealm(lighter))
	registry.Exec(cross(cur), JobID())
	uassert.Equal(t, "Mushroom Mead", OnTap())
	uassert.Equal(t, int64(2), Rotations())
}

// Nobody but the registry, running the taproom's own job, can reach the callback.
func TestRotateRefusesOtherCallers(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(lighter))
	uassert.True(t, rotate(cross(cur), JobID()) != nil, "a user")

	testing.SetRealm(testing.NewCodeRealm("gno.land/r/test/impostor"))
	uassert.True(t, rotate(cross(cur), JobID()) != nil, "another realm")
}

func TestRender(t *testing.T) {
	out := Render("")
	uassert.True(t, strings.Contains(out, "# The Taproom"))
	uassert.True(t, strings.Contains(out, "## On tap: "+OnTap()))
	uassert.True(t, strings.Contains(out, "/lamplighter/registry/v2:job/"))
}

// Close ends the job the tests above use.
func TestOnlyTheKeeperCloses(cur realm, t *testing.T) {
	restock()

	testing.SetRealm(testing.NewUserRealm(lighter))
	uassert.AbortsWithMessage(t, cur, "only the keeper can close the taproom", func() { Close(cross(cur)) })

	left := registry.Balance(JobID())
	uassert.True(t, left > 0)
	before := ugnotOf(keeper)

	testing.SetRealm(testing.NewUserRealm(keeper))
	Close(cross(cur))
	uassert.Equal(t, before+left, ugnotOf(keeper), "the unspent oil comes back")
	uassert.False(t, registry.Exists(JobID()))
	uassert.True(t, strings.Contains(Render(""), "The taproom is closed"))

	uassert.AbortsWithMessage(t, cur, "the taproom is already closed", func() { Close(cross(cur)) })
	uassert.AbortsWithMessage(t, cur, "the taproom is closed for good", func() { Open(cross(cur)) })
}

// The registry runs any callback for anyone. Another realm that gets hold of
// this one's callback and posts it as a job of its own, on its own schedule,
// must get nowhere: the job id is not the taproom's.
//
// This test is last because the refused run aborts mid-way. On chain that
// reverts the transaction; the test runtime keeps the registry's lock set.
func TestAnotherRealmCannotScheduleTheTap(cur realm, t *testing.T) {
	restock()
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/test/attacker"))
	hijack := registry.Register(cross(cur), "hijack", 0, 10, registry.MinReward, rotate)
	uassert.True(t, hijack != JobID())

	testing.IssueCoins(registryAddr, chain.Coins{{registry.Denom, 10 * registry.MinReward}})
	registry.Credit(cross(cur), hijack, 10*registry.MinReward)
	uassert.True(t, registry.IsDue(hijack))

	before := Rotations()
	testing.SetRealm(testing.NewUserRealm(lighter))
	uassert.AbortsWithMessage(t, cur,
		"job failed: only the taproom's own lamplighter job may change the tap",
		func() { registry.Exec(cross(cur), hijack) })
	uassert.Equal(t, before, Rotations())
}
