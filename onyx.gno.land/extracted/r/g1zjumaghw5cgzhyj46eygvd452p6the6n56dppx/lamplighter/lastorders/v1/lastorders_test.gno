package lastorders

import (
	"chain"
	"chain/banker"
	"strings"
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
	"gno.land/r/g1zjumaghw5cgzhyj46eygvd452p6the6n56dppx/lamplighter/registry/v2"
)

const selfPath = "gno.land/r/g1zjumaghw5cgzhyj46eygvd452p6the6n56dppx/lamplighter/lastorders/v1"

var (
	selfAddr = chain.PackageAddress(selfPath)
	seller   = testutils.TestAddress("seller")
	ann      = testutils.TestAddress("ann")
	ben      = testutils.TestAddress("ben")
	lighter  = testutils.TestAddress("lighter")
)

func ugnotOf(addr address) int64 {
	return banker.NewReadonlyBanker().GetCoin(addr, denom)
}

// sending attaches coins to the next call into this realm. The test banker
// does not move those coins by itself, so they are issued to the realm.
//
// Two things have to stay in the test function itself, because the test
// runtime ties them to its call frame: choosing who is calling
// (testing.SetRealm), and the call that is meant to be a direct one.
func sending(amount int64) {
	coins := chain.Coins{{denom, amount}}
	testing.IssueCoins(selfAddr, coins)
	testing.SetOriginSend(coins)
}

// Every test settles the rounds it opens, so that no coins are owed across
// test functions: the test runtime empties all balances between them.

// The whole flow: a round is opened and funds its own job, two bidders
// compete, and a stranger running the job at closing time moves the money.
func TestALamplighterSettlesTheRound(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(seller))
	sending(LampFee)
	id := Open(cross(cur), "Friday's last round", 300)
	testing.SetOriginSend(nil)

	job := JobOf(id)
	uassert.Equal(t, selfPath, registry.Owner(job))
	uassert.Equal(t, LampFee, registry.Balance(job), "the realm funded its own job from the seller's fee")
	uassert.Equal(t, int64(0), ugnotOf(selfAddr), "the fee went to the registry, not into this realm")
	uassert.False(t, registry.IsDue(job))

	testing.SetRealm(testing.NewUserRealm(ann))
	sending(100000)
	Bid(cross(cur), id, "To absent friends")
	testing.SetOriginSend(nil)

	annBefore := ugnotOf(ann)
	testing.SetRealm(testing.NewUserRealm(ben))
	sending(105000)
	Bid(cross(cur), id, "To the lamplighters")
	testing.SetOriginSend(nil)
	uassert.Equal(t, annBefore+100000, ugnotOf(ann), "the outbid bidder is refunded at once")
	leader, bid := Leader(id)
	uassert.Equal(t, ben, leader)
	uassert.Equal(t, int64(105000), bid)
	uassert.True(t, strings.Contains(Render(""), "## Open rounds"))

	// Nothing can settle it early.
	testing.SetRealm(testing.NewUserRealm(lighter))
	uassert.AbortsWithMessage(t, cur, "job is not due yet", func() { registry.Exec(cross(cur), job) })

	testing.SkipHeights(61) // 305s: past closing time
	uassert.True(t, registry.IsDue(job))
	uassert.True(t, strings.Contains(Render(""), "to settle it"))

	sellerBefore, lighterBefore := ugnotOf(seller), ugnotOf(lighter)
	testing.SetRealm(testing.NewUserRealm(lighter))
	registry.Exec(cross(cur), job)

	uassert.True(t, Settled(id))
	uassert.Equal(t, sellerBefore+105000, ugnotOf(seller), "the winning bid reaches the seller")
	uassert.Equal(t, lighterBefore+LampFee, ugnotOf(lighter), "the lamplighter is paid the fee")
	uassert.Equal(t, int64(0), ugnotOf(selfAddr), "nothing is left behind")
	uassert.True(t, registry.Done(job), "the job is done and waits for its owner to clean it up")

	page := Render("")
	uassert.True(t, strings.Contains(page, "## The wall"))
	uassert.True(t, strings.Contains(page, "To the lamplighters"))

	// The seller frees the finished job, which is what releases the storage
	// deposit that opening the round locked. Nobody else can.
	testing.SetRealm(testing.NewUserRealm(ann))
	uassert.AbortsWithMessage(t, cur, "only the seller can reclaim the deposit of a round", func() { Reclaim(cross(cur), id) })
	testing.SetRealm(testing.NewUserRealm(seller))
	Reclaim(cross(cur), id)
	uassert.False(t, registry.Exists(job))
	uassert.AbortsWithMessage(t, cur, "already reclaimed", func() { Reclaim(cross(cur), id) })
}

func TestOpenAndBidRules(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(seller))
	sending(LampFee)
	id := Open(cross(cur), "Rules", 300)
	testing.SetOriginSend(nil)

	testing.SetRealm(testing.NewUserRealm(ann))
	sending(200000)
	Bid(cross(cur), id, "First")
	testing.SetOriginSend(nil)

	// 5% over 200000, rounded up, is the least the next bid may be.
	uassert.Equal(t, int64(210000), minNextBid(mustRound(id)))
	uassert.Equal(t, int64(MinBid), minNextBid(&round{}))
	uassert.Equal(t, int64(105), minNextBid(&round{bid: 100}))
	uassert.Equal(t, int64(107), minNextBid(&round{bid: 101}), "the raise rounds up")

	uassert.True(t, printable("Cheers!", maxToastLen))
	for _, bad := range []string{"", strings.Repeat("a", maxToastLen+1), "two\nlines", "bad\xffutf8", "bell\x07"} {
		uassert.False(t, printable(bad, maxToastLen))
	}
	uassert.PanicsWithMessage(t, cur, "unknown round 999999", func() { mustRound(999999) })

	testing.SetRealm(testing.NewUserRealm(seller))
	uassert.AbortsWithMessage(t, cur, "the round is not settled yet", func() { Reclaim(cross(cur), id) })

	// Close it out. Running the job is open to everyone, the seller included.
	testing.SkipHeights(61)
	testing.SetRealm(testing.NewUserRealm(seller))
	registry.Exec(cross(cur), JobOf(id))
	uassert.True(t, Settled(id))
}

// The callback settles only rounds of this realm, only for the registry, and
// only once they are closed.
func TestSettleJobGuards(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(seller))
	sending(LampFee)
	id := Open(cross(cur), "Guarded", 60)
	testing.SetOriginSend(nil)
	job := JobOf(id)

	testing.SetRealm(testing.NewUserRealm(lighter))
	uassert.True(t, settleJob(cross(cur), job) != nil, "a user calling the callback")
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/test/impostor"))
	uassert.True(t, settleJob(cross(cur), job) != nil, "another realm calling the callback")
	uassert.False(t, Settled(id))

	// Another realm posts this realm's callback as a job of its own. The job
	// id is not one this realm posted, so it settles nothing.
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/test/attacker"))
	hijack := registry.Register(cross(cur), "hijack", 0, 10, registry.MinReward, settleJob)
	testing.IssueCoins(chain.PackageAddress(registry.Path()), chain.Coins{{denom, registry.MinReward}})
	registry.Credit(cross(cur), hijack, registry.MinReward)
	testing.SetRealm(testing.NewCodeRealm(registry.Path()))
	err := settleJob(cross(cur), hijack)
	uassert.True(t, err != nil && strings.Contains(err.Error(), "not a job of this realm"))
	uassert.False(t, Settled(id))

	// The registry itself, but before closing time.
	err = settleJob(cross(cur), job)
	uassert.True(t, err != nil && strings.Contains(err.Error(), "is still open"))

	testing.SkipHeights(13)
	testing.SetRealm(testing.NewUserRealm(lighter))
	registry.Exec(cross(cur), job)
	uassert.True(t, Settled(id))
}
