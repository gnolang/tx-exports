package vs

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
	block = int64(5)
)

var (
	alice = testutils.TestAddress("alice")
	bob   = testutils.TestAddress("bob")
	carol = testutils.TestAddress("carol")
	dave  = testutils.TestAddress("dave")
	vsAt  = chain.PackageAddress("gno.land/r/g12dcsmwccgdxasqde2eumua88tlrkw83kqf6tcz/vs")
)

func fund(cur realm, user address, amount int64) {
	testing.SetRealm(testing.NewUserRealm(musd.Deployer))
	musd.Mint(cross(cur), user, amount)
	testing.SetRealm(testing.NewUserRealm(user))
	musd.Approve(cross(cur), vsAt, musd.Allowance(user, vsAt)+amount)
}

func open(cur realm, user address, amount, closesIn int64, odds string, payoutBps int64, private bool) int64 {
	fund(cur, user, amount)
	testing.SetRealm(testing.NewUserRealm(user))
	return CreateClaim(cross(cur), "BTC above 100k on Friday?", "Yes", "No", "https://example.com",
		now()+closesIn, amount, "Crypto", 0, "binary", odds, payoutBps, "", "", 0, private, "")
}

func challenge(cur realm, user address, id, amount int64, referrer string) {
	fund(cur, user, amount)
	testing.SetRealm(testing.NewUserRealm(user))
	ChallengeClaim(cross(cur), id, amount, referrer)
}

func propose(cur realm, id int64, side int) {
	testing.SetRealm(testing.NewUserRealm(InitialOracle))
	ResolveClaimWithCutoff(cross(cur), id, side, "verdict", 90, "", 0)
}

func finalize(cur realm, id int64) {
	skip(DisputeWindow())
	testing.SetRealm(testing.NewUserRealm(dave))
	FinalizeResolution(cross(cur), id)
}

func skip(seconds int64) { testing.SkipHeights(seconds/block + 1) }

func TestPoolOddsChallengersWin(cur realm, t *testing.T) {
	id := open(cur, alice, 100*usd, 3600, "pool", 0, false)
	challenge(cur, bob, id, 20*usd, "")
	challenge(cur, carol, id, 20*usd, "")
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsContains(t, cur, "AlreadyChallenged", func() { ChallengeClaim(cross(cur), id, usd, "") })
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "SelfChallenge", func() { ChallengeClaim(cross(cur), id, usd, "") })
	uassert.AbortsContains(t, cur, "NotOpen", func() { CancelClaim(cross(cur), id) })

	skip(3600)
	propose(cur, id, SideChallengers)
	b0, c0, a0 := musd.BalanceOf(bob), musd.BalanceOf(carol), musd.BalanceOf(alice)
	finalize(cur, id)
	// Creator 99.5 net; challengers 19.9 each; at risk = min(39.8*5, 99.5) = 99.5, split evenly.
	uassert.Equal(t, int64(19_900_000+49_750_000), musd.BalanceOf(bob)-b0)
	uassert.Equal(t, int64(19_900_000+49_750_000), musd.BalanceOf(carol)-c0)
	uassert.Equal(t, int64(0), musd.BalanceOf(alice)-a0)
	w, l := UserStats(bob)
	uassert.Equal(t, int64(1), w)
	uassert.Equal(t, int64(0), l)
}

func TestPoolOddsCreatorWinsAndPoolCap(cur realm, t *testing.T) {
	id := open(cur, alice, 10*usd, 3600, "pool", 0, false)
	fund(cur, bob, 60*usd)
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsContains(t, cur, "PoolFull", func() { ChallengeClaim(cross(cur), id, 60*usd, "") })
	challenge(cur, carol, id, 10*usd, "")
	skip(3600)
	propose(cur, id, SideCreator)
	a0 := musd.BalanceOf(alice)
	finalize(cur, id)
	uassert.Equal(t, int64(19_900_000), musd.BalanceOf(alice)-a0)
}

func TestFixedOddsReservesLiquidity(cur realm, t *testing.T) {
	id := open(cur, alice, 10*usd, 3600, "fixed", 30_000, false) // 3x
	fund(cur, bob, 10*usd)
	testing.SetRealm(testing.NewUserRealm(bob))
	// 3x on 9.95 net needs 19.9 of creator liquidity; only 9.95 exists.
	uassert.AbortsContains(t, cur, "CreatorHasInsufficientLiquidity", func() { ChallengeClaim(cross(cur), id, 10*usd, "") })
	challenge(cur, carol, id, 2*usd, "")
	skip(3600)
	propose(cur, id, SideChallengers)
	c0, a0 := musd.BalanceOf(carol), musd.BalanceOf(alice)
	finalize(cur, id)
	uassert.Equal(t, int64(5_970_000), musd.BalanceOf(carol)-c0)           // 1.99 * 3
	uassert.Equal(t, int64(9_950_000-3_980_000), musd.BalanceOf(alice)-a0) // unreserved remainder
}

func TestCancelAndUnchallengedRefund(cur realm, t *testing.T) {
	id := open(cur, alice, 5*usd, 3600, "pool", 0, false)
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsContains(t, cur, "NotCreator", func() { CancelClaim(cross(cur), id) })
	a0 := musd.BalanceOf(alice)
	testing.SetRealm(testing.NewUserRealm(alice))
	CancelClaim(cross(cur), id)
	uassert.Equal(t, int64(4_975_000), musd.BalanceOf(alice)-a0) // the entry fee stays earned
}

func TestPrivateInvites(cur realm, t *testing.T) {
	id := open(cur, alice, 5*usd, 3600, "pool", 0, true)
	fund(cur, bob, usd)
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsContains(t, cur, "NotInvited", func() { ChallengeClaim(cross(cur), id, usd, "") })
	uassert.AbortsContains(t, cur, "BadInvite", func() { SetInvited(cross(cur), id, bob.String(), true) })
	testing.SetRealm(testing.NewUserRealm(alice))
	SetInvited(cross(cur), id, bob.String()+", "+carol.String(), true)
	uassert.True(t, Invited(id, carol))
	testing.SetRealm(testing.NewUserRealm(bob))
	ChallengeClaim(cross(cur), id, usd, "")
	uassert.True(t, HasChallenged(id, bob))
}

func TestDisputeAndRuling(cur realm, t *testing.T) {
	id := open(cur, alice, 10*usd, 3600, "pool", 0, false)
	challenge(cur, bob, id, 10*usd, "")
	skip(3600)
	propose(cur, id, SideCreator)
	testing.SetRealm(testing.NewUserRealm(carol))
	uassert.AbortsContains(t, cur, "NotAParticipant", func() { DisputeResolution(cross(cur), id) })
	fund(cur, bob, DisputeBond)
	testing.SetRealm(testing.NewUserRealm(bob))
	DisputeResolution(cross(cur), id)
	b0 := musd.BalanceOf(bob)
	testing.SetRealm(testing.NewUserRealm(InitialArbiter))
	ResolveDisputeWithCutoff(cross(cur), id, SideChallengers, "overturned", 80, "", 0)
	uassert.Equal(t, int64(19_900_000)+DisputeBond, musd.BalanceOf(bob)-b0)
}

func TestCutoffRefundsLateChallenger(cur realm, t *testing.T) {
	id := open(cur, alice, 10*usd, 3600, "pool", 0, false)
	challenge(cur, bob, id, 10*usd, "")
	skip(600)
	cutoff := now()
	skip(60)
	challenge(cur, carol, id, 10*usd, "")
	skip(3600)
	testing.SetRealm(testing.NewUserRealm(InitialOracle))
	ResolveClaimWithCutoff(cross(cur), id, SideChallengers, "late entry excluded", 95, "", cutoff)
	_, eb := EligibleTotals(id)
	uassert.Equal(t, int64(9_950_000), eb)
	b0, c0 := musd.BalanceOf(bob), musd.BalanceOf(carol)
	finalize(cur, id)
	uassert.Equal(t, int64(19_900_000), musd.BalanceOf(bob)-b0)
	uassert.Equal(t, int64(9_950_000), musd.BalanceOf(carol)-c0)
}

func TestRefundExpiredAndCopyFees(cur realm, t *testing.T) {
	id := open(cur, alice, 10*usd, 3600, "pool", 0, false)
	challenge(cur, bob, id, 10*usd, "")
	skip(3600 + ResolutionGraceSeconds)
	a0, b0 := musd.BalanceOf(alice), musd.BalanceOf(bob)
	testing.SetRealm(testing.NewUserRealm(carol))
	RefundExpired(cross(cur), id)
	uassert.Equal(t, int64(9_950_000), musd.BalanceOf(alice)-a0)
	uassert.Equal(t, int64(9_950_000), musd.BalanceOf(bob)-b0)

	// A copied winner pays 1% of profit to the referrer and 1% to the platform.
	id = open(cur, alice, 100*usd, 3600, "pool", 0, false)
	challenge(cur, bob, id, 100*usd, dave.String())
	skip(3600)
	propose(cur, id, SideChallengers)
	b0 = musd.BalanceOf(bob)
	r0 := AccruedFees(dave)
	finalize(cur, id)
	uassert.Equal(t, int64(199_000_000-1_990_000), musd.BalanceOf(bob)-b0)
	uassert.Equal(t, int64(995_000), AccruedFees(dave)-r0)
	testing.SetRealm(testing.NewUserRealm(dave))
	ClaimFees(cross(cur))
}

func TestRematchAndGuards(cur realm, t *testing.T) {
	parent := open(cur, alice, 5*usd, 3600, "fixed", 15_000, false)
	fund(cur, bob, 5*usd)
	testing.SetRealm(testing.NewUserRealm(bob))
	id := CreateRematch(cross(cur), parent, now()+7200, 5*usd)
	uassert.True(t, len(ClaimJSON(id)) > 0)
	uassert.True(t, len(ChallengersJSON(id)) >= 2)
	uassert.True(t, len(ClaimsJSON(0, 5)) > 2)
	uassert.True(t, len(Render("")) > 0)
	uassert.True(t, len(Render("1")) > 0)

	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsContains(t, cur, "PayoutTooHigh", func() {
		CreateClaim(cross(cur), "q", "a", "b", "", now()+3600, MinStake, "", 0, "", "fixed", 200_000, "", "", 0, false, "")
	})
	uassert.AbortsContains(t, cur, "DeadlineInPast", func() {
		CreateClaim(cross(cur), "q", "a", "b", "", now(), MinStake, "", 0, "", "", 0, "", "", 0, false, "")
	})
	testing.SetRealm(testing.NewUserRealm(Deployer))
	SetPaused(cross(cur), true)
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsContains(t, cur, "IsPaused", func() { ChallengeClaim(cross(cur), parent, MinStake, "") })
	testing.SetRealm(testing.NewUserRealm(Deployer))
	SetPaused(cross(cur), false)
	skip(mimir.TimelockSeconds)
}
