package pool

import (
	"chain"
	"testing"

	mimir "gno.land/p/g12dcsmwccgdxasqde2eumua88tlrkw83kqf6tcz/mimir"
	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
	"gno.land/r/g12dcsmwccgdxasqde2eumua88tlrkw83kqf6tcz/musd"
)

const (
	usd   = int64(1_000_000)
	block = int64(5) // seconds per test block
)

var (
	alice  = testutils.TestAddress("alice")
	bob    = testutils.TestAddress("bob")
	carol  = testutils.TestAddress("carol")
	dave   = testutils.TestAddress("dave")
	poolAt = chain.PackageAddress("gno.land/r/g12dcsmwccgdxasqde2eumua88tlrkw83kqf6tcz/pool")
)

// Each helper sets the acting user in its own frame, then calls.

func fund(cur realm, user address, amount int64) {
	testing.SetRealm(testing.NewUserRealm(musd.Deployer))
	musd.Mint(cross(cur), user, amount)
	testing.SetRealm(testing.NewUserRealm(user))
	musd.Approve(cross(cur), poolAt, musd.Allowance(user, poolAt)+amount)
}

func open(cur realm, user address, side int, amount, closesIn int64) int64 {
	fund(cur, user, amount)
	testing.SetRealm(testing.NewUserRealm(user))
	return CreateMarket(cross(cur), "Will it rain?", "Yes", "No", "https://example.com", "World",
		now()+closesIn, side, "", amount)
}

func stake(cur realm, user address, id int64, side int, amount int64, referrer string) {
	fund(cur, user, amount)
	testing.SetRealm(testing.NewUserRealm(user))
	Stake(cross(cur), id, side, referrer, amount)
}

func asOracle(cur realm, id int64, outcome int, cutoff int64) {
	testing.SetRealm(testing.NewUserRealm(InitialOracle))
	ResolveWithCutoff(cross(cur), id, outcome, "verdict", "", cutoff)
}

func claim(cur realm, user address, id int64) int64 {
	before := musd.BalanceOf(user)
	testing.SetRealm(testing.NewUserRealm(user))
	Claim(cross(cur), id)
	return musd.BalanceOf(user) - before
}

func skip(seconds int64) { testing.SkipHeights(seconds/block + 1) }

func TestStakeFeesAndProRataPayout(cur realm, t *testing.T) {
	id := open(cur, alice, SideA, 100*usd, 3600)
	stake(cur, bob, id, SideB, 50*usd, "")
	a, b := SideTotals(id)
	uassert.Equal(t, int64(99_500_000), a) // 0.5% entry fee
	uassert.Equal(t, int64(49_750_000), b)
	uassert.Equal(t, int64(750_000), AccruedFees(Deployer))

	testing.SetRealm(testing.NewUserRealm(InitialOracle))
	uassert.AbortsContains(t, cur, "NotExpired", func() { Resolve(cross(cur), id, SideA, "x", "") })
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsContains(t, cur, "NotOracle", func() { Resolve(cross(cur), id, SideA, "x", "") })

	skip(3600)
	asOracle(cur, id, SideA, 0)
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "NotResolved", func() { Claim(cross(cur), id) })
	uassert.AbortsContains(t, cur, "WindowOpen", func() { Finalize(cross(cur), id) })

	skip(DisputeWindow())
	Finalize(cross(cur), id)
	uassert.Equal(t, int64(149_250_000), claim(cur, alice, id))
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "AlreadyClaimed", func() { Claim(cross(cur), id) })
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsContains(t, cur, "NothingToClaim", func() { Claim(cross(cur), id) })

	// The fee recipient pulls its entry fees.
	testing.SetRealm(testing.NewUserRealm(Deployer))
	before := musd.BalanceOf(Deployer)
	ClaimFees(cross(cur))
	uassert.Equal(t, int64(750_000), musd.BalanceOf(Deployer)-before)
}

func TestOneSidedAndDrawRefund(cur realm, t *testing.T) {
	id := open(cur, alice, SideA, 10*usd, 3600)
	stake(cur, bob, id, SideA, 10*usd, "")
	skip(3600)
	asOracle(cur, id, SideA, 0)
	skip(DisputeWindow())
	testing.SetRealm(testing.NewUserRealm(carol))
	Finalize(cross(cur), id) // anyone
	uassert.Equal(t, int64(9_950_000), claim(cur, bob, id))

	id = open(cur, alice, SideA, 10*usd, 3600)
	stake(cur, bob, id, SideB, 10*usd, "")
	skip(3600)
	asOracle(cur, id, Draw, 0)
	skip(DisputeWindow())
	testing.SetRealm(testing.NewUserRealm(carol))
	Finalize(cross(cur), id)
	uassert.Equal(t, int64(9_950_000), claim(cur, alice, id))
	uassert.Equal(t, int64(9_950_000), claim(cur, bob, id))
}

func TestDisputeBondReturnedWhenRight(cur realm, t *testing.T) {
	id := open(cur, alice, SideA, 10*usd, 3600)
	stake(cur, bob, id, SideB, 10*usd, "")
	skip(3600)
	asOracle(cur, id, SideA, 0)

	testing.SetRealm(testing.NewUserRealm(carol))
	uassert.AbortsContains(t, cur, "NotParticipant", func() { Dispute(cross(cur), id) })

	fund(cur, bob, DisputeBond)
	testing.SetRealm(testing.NewUserRealm(bob))
	Dispute(cross(cur), id)
	uassert.AbortsContains(t, cur, "NotProposed", func() { Dispute(cross(cur), id) })
	uassert.AbortsContains(t, cur, "NotArbiter", func() { ResolveDispute(cross(cur), id, SideB, "x", "") })

	before := musd.BalanceOf(bob)
	testing.SetRealm(testing.NewUserRealm(InitialArbiter))
	ResolveDispute(cross(cur), id, SideB, "the arbiter disagrees", "")
	uassert.Equal(t, DisputeBond, musd.BalanceOf(bob)-before)
	uassert.Equal(t, int64(19_900_000), claim(cur, bob, id))
}

func TestDisputeBondForfeitedWhenWrong(cur realm, t *testing.T) {
	id := open(cur, alice, SideA, 10*usd, 3600)
	stake(cur, bob, id, SideB, 10*usd, "")
	skip(3600)
	asOracle(cur, id, SideA, 0)
	fund(cur, bob, DisputeBond)
	testing.SetRealm(testing.NewUserRealm(bob))
	Dispute(cross(cur), id)
	feesBefore := AccruedFees(Deployer)
	testing.SetRealm(testing.NewUserRealm(InitialArbiter))
	ResolveDispute(cross(cur), id, SideA, "upheld", "")
	uassert.Equal(t, DisputeBond, AccruedFees(Deployer)-feesBefore)
	uassert.Equal(t, int64(19_900_000), claim(cur, alice, id))
}

func TestSettlementCutoffRefundsLateDeposits(cur realm, t *testing.T) {
	id := open(cur, alice, SideA, 10*usd, 3600)
	stake(cur, bob, id, SideB, 10*usd, "")
	skip(600)
	cutoff := now()
	skip(60)
	stake(cur, carol, id, SideB, 10*usd, "") // after the cutoff
	skip(3600)
	asOracle(cur, id, SideB, cutoff)
	a, b := EligibleTotals(id)
	uassert.Equal(t, int64(9_950_000), a)
	uassert.Equal(t, int64(9_950_000), b)
	skip(DisputeWindow())
	testing.SetRealm(testing.NewUserRealm(dave))
	Finalize(cross(cur), id)
	uassert.Equal(t, int64(19_900_000), claim(cur, bob, id))
	uassert.Equal(t, int64(9_950_000), claim(cur, carol, id)) // principal back
}

func TestRefundExpired(cur realm, t *testing.T) {
	// Never resolved: a full refund after the grace.
	id := open(cur, alice, SideA, 10*usd, 3600)
	stake(cur, bob, id, SideB, 10*usd, "")
	skip(3600)
	testing.SetRealm(testing.NewUserRealm(carol))
	uassert.AbortsContains(t, cur, "GraceNotOver", func() { RefundExpired(cross(cur), id) })
	skip(ResolutionGraceSeconds)
	testing.SetRealm(testing.NewUserRealm(InitialOracle))
	uassert.AbortsContains(t, cur, "GraceOver", func() { Resolve(cross(cur), id, SideA, "late", "") })
	testing.SetRealm(testing.NewUserRealm(carol))
	RefundExpired(cross(cur), id)
	uassert.Equal(t, int64(9_950_000), claim(cur, alice, id))

	// An unruled dispute settles to the proposal; the bond is forfeited.
	id = open(cur, alice, SideA, 10*usd, 3600)
	stake(cur, bob, id, SideB, 10*usd, "")
	skip(3600)
	asOracle(cur, id, SideA, 0)
	fund(cur, bob, DisputeBond)
	testing.SetRealm(testing.NewUserRealm(bob))
	Dispute(cross(cur), id)
	skip(ResolutionGraceSeconds)
	testing.SetRealm(testing.NewUserRealm(carol))
	RefundExpired(cross(cur), id)
	uassert.Equal(t, int64(19_900_000), claim(cur, alice, id))
}

func TestVetoRefundsIfUnruled(cur realm, t *testing.T) {
	id := open(cur, alice, SideA, 10*usd, 3600)
	stake(cur, bob, id, SideB, 10*usd, "")
	skip(3600)
	asOracle(cur, id, SideA, 0)
	testing.SetRealm(testing.NewUserRealm(Deployer))
	VetoProposal(cross(cur), id)
	skip(ResolutionGraceSeconds)
	testing.SetRealm(testing.NewUserRealm(carol))
	RefundExpired(cross(cur), id)
	uassert.Equal(t, int64(9_950_000), claim(cur, bob, id))
}

func TestPauseHoldsWinnersNotRefunds(cur realm, t *testing.T) {
	id := open(cur, alice, SideA, 10*usd, 3600)
	stake(cur, bob, id, SideB, 10*usd, "")
	skip(3600)
	asOracle(cur, id, SideA, 0)
	skip(DisputeWindow())
	testing.SetRealm(testing.NewUserRealm(carol))
	Finalize(cross(cur), id)

	testing.SetRealm(testing.NewUserRealm(Deployer))
	SetPaused(cross(cur), true)
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "IsPaused", func() { Claim(cross(cur), id) })
	uassert.AbortsContains(t, cur, "IsPaused", func() {
		CreateMarket(cross(cur), "q", "a", "b", "", "", now()+3600, SideA, "", MinStake)
	})
	testing.SetRealm(testing.NewUserRealm(Deployer))
	SetPaused(cross(cur), false)
	uassert.Equal(t, int64(19_900_000), claim(cur, alice, id))
}

func TestCopyTradeFees(cur realm, t *testing.T) {
	id := open(cur, alice, SideB, 100*usd, 3600)
	stake(cur, bob, id, SideA, 100*usd, dave.String()) // bob copies dave
	skip(3600)
	asOracle(cur, id, SideA, 0)
	skip(DisputeWindow())
	testing.SetRealm(testing.NewUserRealm(carol))
	Finalize(cross(cur), id)
	refBefore := AccruedFees(dave)
	// Profit 99.5; 1% to dave, 1% to the platform.
	uassert.Equal(t, int64(199_000_000-1_990_000), claim(cur, bob, id))
	uassert.Equal(t, int64(995_000), AccruedFees(dave)-refBefore)
}

func TestLimits(cur realm, t *testing.T) {
	fund(cur, alice, 10*usd)
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "StakeTooSmall", func() {
		CreateMarket(cross(cur), "q", "a", "b", "", "", now()+3600, SideA, "", MinStake-1)
	})
	uassert.AbortsContains(t, cur, "BadDeadline", func() {
		CreateMarket(cross(cur), "q", "a", "b", "", "", now()+30, SideA, "", MinStake)
	})
	uassert.AbortsContains(t, cur, "EmptyQuestion", func() {
		CreateMarket(cross(cur), "", "a", "b", "", "", now()+3600, SideA, "", MinStake)
	})
	uassert.AbortsContains(t, cur, "BadSide", func() {
		CreateMarket(cross(cur), "q", "a", "b", "", "", now()+3600, 3, "", MinStake)
	})

	// Betting closes LockSeconds before the deadline, or at an earlier lock.
	id := open(cur, alice, SideA, usd, 600)
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsContains(t, cur, "BadLock", func() { SetLockAt(cross(cur), id, now()+100) })
	testing.SetRealm(testing.NewUserRealm(alice))
	SetLockAt(cross(cur), id, now()+100)
	uassert.AbortsContains(t, cur, "BadLock", func() { SetLockAt(cross(cur), id, now()+200) })
	skip(100)
	fund(cur, bob, usd)
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsContains(t, cur, "BettingClosed", func() { Stake(cross(cur), id, SideB, "", usd) })

	// Caps gate new stakes only.
	testing.SetRealm(testing.NewUserRealm(Deployer))
	SetCaps(cross(cur), 0, 5*usd)
	id = open(cur, alice, SideA, usd, 3600)
	fund(cur, bob, 10*usd)
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsContains(t, cur, "CapExceeded", func() { Stake(cross(cur), id, SideB, "", 10*usd) })
	testing.SetRealm(testing.NewUserRealm(Deployer))
	SetCaps(cross(cur), 0, 0)
}

func TestRolesAndTimelocks(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsContains(t, cur, "NotOwner", func() { SetPaused(cross(cur), true) })

	testing.SetRealm(testing.NewUserRealm(Deployer))
	uassert.AbortsContains(t, cur, "RoleCollision", func() { QueueOracle(cross(cur), InitialArbiter) })
	uassert.AbortsContains(t, cur, "RoleCollision", func() { SetArbiter(cross(cur), InitialOracle) })
	SetAuditAgent(cross(cur), carol.String())
	uassert.AbortsContains(t, cur, "RoleCollision", func() { SetArbiter(cross(cur), carol) })

	QueueOracle(cross(cur), dave)
	uassert.AbortsContains(t, cur, "Timelocked", func() { ExecuteOracle(cross(cur)) })
	RevokeOracle(cross(cur))
	uassert.Equal(t, address(""), Oracle())
	skip(mimir.TimelockSeconds)
	testing.SetRealm(testing.NewUserRealm(bob))
	ExecuteOracle(cross(cur)) // permissionless once due
	uassert.Equal(t, dave, Oracle())

	// Restore the oracle for later tests.
	testing.SetRealm(testing.NewUserRealm(Deployer))
	QueueOracle(cross(cur), InitialOracle)
	skip(mimir.TimelockSeconds)
	ExecuteOracle(cross(cur))
	SetAuditAgent(cross(cur), "")
}

func TestViews(cur realm, t *testing.T) {
	id := open(cur, alice, SideA, 2*usd, 3600)
	uassert.True(t, len(MarketJSON(id)) > 0)
	uassert.True(t, len(MarketsJSON(0, 5)) > 2)
	uassert.True(t, len(PositionJSON(id, alice)) > 0)
	uassert.True(t, len(ConfigJSON()) > 0)
	uassert.True(t, len(Render("")) > 0)
	uassert.True(t, len(Render("1")) > 0)
}
