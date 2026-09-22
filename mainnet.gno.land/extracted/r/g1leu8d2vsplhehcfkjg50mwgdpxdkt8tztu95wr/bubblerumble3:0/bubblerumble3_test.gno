package bubblerumble3

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"strings"
	"testing"
)

const realmPath = "gno.land/r/g1leu8d2vsplhehcfkjg50mwgdpxdkt8tztu95wr/bubblerumble3"

var (
	alice = address("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5")
	bob   = address("g1dmt3sa5ucvecxuhf3j6ne5r0e3z4x7h6c03xc0")
	carol = address("g1akeqsvhucjt8gf5yupyzjxsjd29wv8fayng37c")
	dave  = address("g1leu8d2vsplhehcfkjg50mwgdpxdkt8tztu95wr") // also the admin
)

func aborts(t *testing.T, want string, f func()) {
	t.Helper()
	r := revive(f)
	if r == nil {
		t.Fatalf("expected an abort containing %q, got none", want)
	}
	msg := ""
	switch e := r.(type) {
	case error:
		msg = e.Error()
	case string:
		msg = e
	}
	if !strings.Contains(msg, want) {
		t.Fatalf("abort %q does not contain %q", msg, want)
	}
}

func held(who address) int64 {
	return banker.NewReadonlyBanker().GetCoins(who).AmountOf("ugnot")
}

// fund attaches ugnot to the next call the way a transaction would. The caller
// is set with testing.SetRealm in the test body: it binds to the calling frame.
func fund(ugnot int64) {
	if ugnot > 0 {
		testing.IssueCoins(chain.PackageAddress(realmPath), chain.Coins{{"ugnot", ugnot}})
		testing.SetOriginSend(chain.Coins{{"ugnot", ugnot}})
	} else {
		testing.SetOriginSend(nil)
	}
}

// heldAtReset is what the realm held when the scenario began: coins from
// earlier scenarios stay in the test realm after reset() forgets their pools.
var heldAtReset int64

func reset() {
	pools = nil
	players = map[address]*Player{}
	teamPaid = map[string]int64{}
	teamWon = map[string]int64{}
	teamSize = map[string]int64{}
	shotsOn = true
	heldAtReset = held(chain.PackageAddress(realmPath))
}

// The conservation check: every ugnot the realm took in during the scenario is
// either in an open pot or credited to somebody.
func realmHeld() int64 { return held(chain.PackageAddress(realmPath)) - heldAtReset }

func owedAll() int64 {
	var sum int64
	for _, p := range pools {
		if !p.Paid {
			sum += p.Pot
		}
	}
	for _, pl := range players {
		sum += pl.Owed
	}
	return sum
}

func conserved(t *testing.T) {
	t.Helper()
	if realmHeld() != owedAll() {
		t.Fatalf("realm holds %d, pots and credits account for %d", realmHeld(), owedAll())
	}
}

func owed(a address) int64 { return player(a).Owed }

func TestSplitSelfRebidFlagLockAndWithdraw(cur realm, t *testing.T) {
	reset()
	fund(0)
	testing.SetRealm(testing.NewUserRealm(dave))
	id := CreatePool(cross(cur), "split", 3600, 1_000_000, 0)
	p := pool(id)
	if p.Life != 10*3600 {
		t.Fatalf("default life is ten windows: %d", p.Life)
	}

	// first bid: dividends and the inviter's cut fall back into the pot, the creator is paid 5% at once
	d0 := held(dave)
	fund(1_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	Bid(cross(cur), id, "", "kr", 0)
	if p.Pot != 950_000 || held(dave)-d0 != 50_000 || p.DivPaid != 0 || p.FirstBidAt.IsZero() {
		t.Fatalf("first bid: pot %d creator +%d div %d", p.Pot, held(dave)-d0, p.DivPaid)
	}

	// bob, invited by alice, bids 2 GNOT: alice is credited all the dividends and paid 10% as inviter at once
	a0 := held(alice)
	fund(2_000_000)
	testing.SetRealm(testing.NewUserRealm(bob))
	Bid(cross(cur), id, alice.String(), "us", 0)
	if owed(alice) != 600_000 || held(alice)-a0 != 200_000 || p.Pot != 950_000+2_000_000-600_000-200_000-100_000 {
		t.Fatalf("second bid: alice owed %d, +%d in hand, pot %d", owed(alice), held(alice)-a0, p.Pot)
	}
	if player(bob).Referrer != alice || player(alice).Recruits != 1 || p.find(alice).Earned != 600_000 {
		t.Fatalf("inviter: %+v", *player(bob))
	}

	// bob rebids on himself, switching his flag to KR: allowed; his dividends go
	// to alice, not himself; his flag in THIS pool stays US (locked at his first bid)
	b1 := held(bob)
	fund(2_000_000)
	testing.SetRealm(testing.NewUserRealm(bob))
	Bid(cross(cur), id, "", "kr", 0)
	if p.LastBidder != bob || p.Bids != 3 || owed(alice) != 1_200_000 || owed(bob) != 0 || b1-held(bob) != 0 {
		t.Fatalf("self rebid: last %s bids %d alice owed %d bob owed %d", p.LastBidder, p.Bids, owed(alice), owed(bob))
	}
	if player(bob).Flag != "KR" || p.find(bob).Flag != "US" || p.History[2].Flag != "US" {
		t.Fatalf("flag lock: player %s member %s history %s", player(bob).Flag, p.find(bob).Flag, p.History[2].Flag)
	}
	conserved(t)

	// alice withdraws what she is owed; a second withdraw has nothing
	a1 := held(alice)
	fund(0)
	testing.SetRealm(testing.NewUserRealm(alice))
	if got := Withdraw(cross(cur)); got != 1_200_000 || held(alice)-a1 != 1_200_000 || owed(alice) != 0 || player(alice).Withdrawn != 1_200_000 {
		t.Fatalf("withdraw: %d, +%d, owed %d", got, held(alice)-a1, owed(alice))
	}
	aborts(t, "nothing to withdraw", func() { Withdraw(cross(cur)) })
	conserved(t)

	// in a new pool, bob's locked flag is his current one
	fund(0)
	testing.SetRealm(testing.NewUserRealm(dave))
	id2 := CreatePool(cross(cur), "next", 3600, 1_000_000, 0)
	fund(1_000_000)
	testing.SetRealm(testing.NewUserRealm(bob))
	Bid(cross(cur), id2, "", "", 0)
	if pool(id2).find(bob).Flag != "KR" {
		t.Fatalf("new pool flag %s", pool(id2).find(bob).Flag)
	}
}

func TestBoostFloor(t *testing.T) {
	if c := ClockFor(3600, 100, 1000); c != 360 {
		t.Fatalf("ten times the price on an hour: %d", c)
	}
	if c := ClockFor(600, 100, 1000); c != MinClock {
		t.Fatalf("ten times the price on ten minutes floors at five: %d", c)
	}
	if c := ClockFor(60, 100, 100); c != 60 {
		t.Fatalf("a plain bid on a one-minute window keeps the window: %d", c)
	}
	if c := ClockFor(60, 100, 1000); c != 60 {
		t.Fatalf("no boost can shorten a window under the floor: %d", c)
	}
	if mulDiv(80_000_000_000, 3_000_000_000, 7_000_000_000) != 34_285_714_285 {
		t.Fatal("mulDiv on numbers whose product passes int64")
	}
}

func TestLastDaySlidesToProRata(cur realm, t *testing.T) {
	reset()
	fund(0)
	testing.SetRealm(testing.NewUserRealm(dave))
	// a one-hour window and a 90-minute life: the life ends before the second clock would
	id := CreatePool(cross(cur), "slide", 3600, 1_000_000, 5400)
	p := pool(id)
	fund(1_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	Bid(cross(cur), id, "", "FR", 0)
	if p.LiveBps() != 10000 {
		t.Fatalf("fresh pool live %d", p.LiveBps())
	}
	// 50 minutes pass (5s a block), bob bids exactly the price (more would shorten
	// his clock): 2400 of 5400 seconds of life are left
	testing.SkipHeights(600)
	fund(1_414_214)
	testing.SetRealm(testing.NewUserRealm(bob))
	Bid(cross(cur), id, "", "US", 0)
	if p.LiveBps() != 10000*2400/5400 {
		t.Fatalf("live %d", p.LiveBps())
	}
	if !p.Deadline().Equal(p.LastDay()) {
		t.Fatalf("deadline %v should be the last day %v, not the clock", p.Deadline(), p.LastDay())
	}
	// the last day comes with time still on bob's clock: the pool is over anyway
	testing.SkipHeights(600)
	if !p.Over() || p.LiveBps() != 0 {
		t.Fatalf("over %v live %d", p.Over(), p.LiveBps())
	}
	pot := p.Pot
	a0, b0 := owed(alice), owed(bob) // alice already holds dividends from bob's bid
	fund(0)
	testing.SetRealm(testing.NewUserRealm(carol))
	Claim(cross(cur), id)
	// bob (US) won alone under his flag, so the team share goes to the other bidder,
	// alice; nothing is live, so the rest is split by paid-in
	cut := pot * TeamShare / 100
	rest := pot - cut
	total := p.find(alice).Paid + p.find(bob).Paid
	wantA := cut + rest*p.find(alice).Paid/total
	if owed(alice)-a0 != wantA || owed(bob)-b0 != pot-wantA {
		t.Fatalf("alice +%d (want %d) bob +%d (want %d)", owed(alice)-a0, wantA, owed(bob)-b0, pot-wantA)
	}
	if p.TeamPaid != cut || p.SharedPaid != rest*p.find(alice).Paid/total || p.WinnerPaid != pot-wantA {
		t.Fatalf("bookkeeping: team %d shared %d winner %d", p.TeamPaid, p.SharedPaid, p.WinnerPaid)
	}
	conserved(t)

	// a pool that closes early with a single bidder credits them everything
	reset()
	fund(0)
	testing.SetRealm(testing.NewUserRealm(dave))
	id = CreatePool(cross(cur), "quick", 60, 1_000_000, 7200)
	p = pool(id)
	fund(1_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	Bid(cross(cur), id, "", "FR", 0)
	testing.SkipHeights(13) // 65s: the clock ran out, the life barely started
	fund(0)
	testing.SetRealm(testing.NewUserRealm(bob))
	Claim(cross(cur), id)
	if owed(alice) != p.Pot || p.SharedPaid != 0 || p.TeamPaid != 0 {
		t.Fatalf("solo: alice owed %d of %d, shared %d team %d", owed(alice), p.Pot, p.SharedPaid, p.TeamPaid)
	}
	conserved(t)
}

func TestFlagWar(cur realm, t *testing.T) {
	reset()
	fund(0)
	testing.SetRealm(testing.NewUserRealm(dave))
	id := CreatePool(cross(cur), "team", 3600, 1_000_000, 0)
	p := pool(id)
	fund(20_000_000)
	testing.SetRealm(testing.NewUserRealm(dave))
	Bid(cross(cur), id, "", "FR", 0)
	fund(1_414_214)
	testing.SetRealm(testing.NewUserRealm(alice))
	Bid(cross(cur), id, "", "FR", 0)
	fund(1_732_051)
	testing.SetRealm(testing.NewUserRealm(carol))
	Bid(cross(cur), id, "", "US", 0)
	fund(2_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	Bid(cross(cur), id, "", "", 0) // alice on top, FR
	testing.SkipHeights(721)
	pot := p.Pot
	live := p.LiveBps()
	if live == 0 || live == 10000 {
		t.Fatalf("live %d should be partway", live)
	}
	a0, d0, c0 := owed(alice), owed(dave), owed(carol)
	fund(0)
	testing.SetRealm(testing.NewUserRealm(bob))
	Claim(cross(cur), id)
	// the team share goes to dave, the only OTHER FR bidder; the winner takes none of it
	cut := pot * TeamShare / 100
	rest := pot - cut
	shared := rest - rest*live/10000
	total := p.find(alice).Paid + p.find(dave).Paid + p.find(carol).Paid
	daveShare, carolShare := shared*p.find(dave).Paid/total, shared*p.find(carol).Paid/total
	if owed(dave)-d0 != cut+daveShare {
		t.Fatalf("dave: +%d want team %d + share %d", owed(dave)-d0, cut, daveShare)
	}
	if owed(carol)-c0 != carolShare {
		t.Fatalf("carol (US) gets only her pro-rata share: +%d want %d", owed(carol)-c0, carolShare)
	}
	if owed(alice)-a0 != pot-cut-daveShare-carolShare {
		t.Fatalf("alice: +%d want %d", owed(alice)-a0, pot-cut-daveShare-carolShare)
	}
	if p.WinnerFlag != "FR" || teamWon["FR"] != pot || p.TeamPaid != cut || p.SharedPaid != daveShare+carolShare {
		t.Fatalf("bookkeeping: %+v", *p)
	}
	conserved(t)
	aborts(t, "already paid out", func() { Claim(cross(cur), id) })

	// a private flag buys nothing: a winner nobody else flew with hands the team
	// share to all the other bidders, pro-rata
	reset()
	fund(0)
	testing.SetRealm(testing.NewUserRealm(dave))
	id = CreatePool(cross(cur), "lone", 60, 1_000_000, 0)
	p = pool(id)
	fund(1_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	Bid(cross(cur), id, "", "FR", 0)
	fund(1_414_214)
	testing.SetRealm(testing.NewUserRealm(carol))
	Bid(cross(cur), id, "", "US", 0)
	fund(1_732_051)
	testing.SetRealm(testing.NewUserRealm(bob))
	Bid(cross(cur), id, "", "AQ", 0) // bob, alone under AQ, on top
	testing.SkipHeights(13)
	pot = p.Pot
	a0, c0, b0 := owed(alice), owed(carol), owed(bob)
	fund(0)
	testing.SetRealm(testing.NewUserRealm(dave))
	Claim(cross(cur), id)
	cut = pot * TeamShare / 100
	others := p.find(alice).Paid + p.find(carol).Paid
	// the life (ten minutes) had 65 seconds on it: a sliver of the rest is shared too
	rest = pot - cut
	shared = rest - rest*p.LiveBps()/10000
	total = others + p.find(bob).Paid
	wantA := cut*p.find(alice).Paid/others + shared*p.find(alice).Paid/total
	wantC := cut*p.find(carol).Paid/others + shared*p.find(carol).Paid/total
	if owed(alice)-a0 != wantA || owed(carol)-c0 != wantC || owed(bob)-b0 != pot-wantA-wantC {
		t.Fatalf("lone flag: alice +%d (want %d) carol +%d (want %d) bob +%d", owed(alice)-a0, wantA, owed(carol)-c0, wantC, owed(bob)-b0)
	}
	conserved(t)
}

func TestShots(cur realm, t *testing.T) {
	reset()
	fund(0)
	testing.SetRealm(testing.NewUserRealm(dave))
	id := CreatePool(cross(cur), "shots", 3600, 1_000_000, 0)
	p := pool(id)
	fund(5_000_000)
	testing.SetRealm(testing.NewUserRealm(dave))
	Bid(cross(cur), id, "", "", 0)

	// the shot must leave the price covered, and must buy some chance
	fund(1_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	aborts(t, "for the bid", func() { Bid(cross(cur), id, "", "", 500_000) })
	fund(1_414_214 + 1)
	testing.SetRealm(testing.NewUserRealm(alice))
	aborts(t, "too small for any chance", func() { Bid(cross(cur), id, "", "", 1) })
	heldAtReset += 1_000_000 + 1_414_215 // coins attached to the two aborted calls never reach a real realm

	// a 0.1 GNOT shot at a ~6 GNOT pot: 0.8 × 0.1/6.7 ≈ 1.2%, capped at 1%; the shot goes into the pot whole
	pot0 := p.Pot
	fund(1_414_214 + 100_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	Bid(cross(cur), id, "", "", 100_000)
	if len(p.Shots) != 1 || p.Shots[0].Bps != ShotMaxBps || p.Shots[0].Resolved {
		t.Fatalf("shot: %+v", *p.Shots[0])
	}
	// dividends (30%) credited to dave, the inviter's 10% back into the pot, creator 5% out, the shot in whole
	if toPot := int64(1_414_214 - 424_264 - 141_421 - 70_710 + 141_421); p.Pot != pot0+toPot+100_000 || owed(dave) != 424_264 {
		t.Fatalf("pot %d, dave owed %d", p.Pot, owed(dave))
	}
	sh := p.Shots[0]
	if sh.Prize != p.Pot || sh.Prize > ShotCap || p.find(alice).Paid != 1_414_214+100_000 {
		t.Fatalf("prize %d pot %d paid %d", sh.Prize, p.Pot, p.find(alice).Paid)
	}
	// the odds of a small shot: 0.02 GNOT at 5 GNOT is 0.8 × 0.02/5 = 0.32%
	if bps := ShotBps(20_000, 5_000_000); bps != 32 {
		t.Fatalf("bps %d", bps)
	}
	// not drawn before the delay
	Draw(cross(cur), id)
	if sh.Resolved {
		t.Fatal("drawn too early")
	}
	testing.SkipHeights(ShotDelay)
	h := runtime.ChainHeight()
	fund(0)
	testing.SetRealm(testing.NewUserRealm(bob))
	want := shotHits(seedFor(id, sh, h), sh.Bps) // the same inputs the realm hashes
	Draw(cross(cur), id)
	if !sh.Resolved || sh.DrawH != h || sh.Won != want {
		t.Fatalf("drawn: %+v want hit=%v", *sh, want)
	}
	if want {
		if !p.Popped || p.LastBidder != alice || !p.Over() || p.Misses != 0 {
			t.Fatalf("a hit pops: %+v", *p)
		}
	} else if p.Popped || p.LastBidder != alice || p.Misses != 1 {
		t.Fatalf("a miss is counted and changes nothing else: %+v", *p)
	}
	Draw(cross(cur), id) // a second draw is a no-op
	if p.Misses > 1 {
		t.Fatal("drawn twice")
	}
	conserved(t)

	// the draw itself: over every seed in a cycle, the chance is exactly bps in 10000
	hits := 0
	for s := uint64(0); s < 10000; s++ {
		if shotHits(s, 32) {
			hits++
		}
	}
	if hits != 32 {
		t.Fatalf("32 bps should hit 32 of 10000 seeds, got %d", hits)
	}

	// a shot nobody draws in its window is void: counted as a miss, never a hit
	reset()
	fund(0)
	testing.SetRealm(testing.NewUserRealm(dave))
	id = CreatePool(cross(cur), "late", 3600, 1_000_000, 0)
	p = pool(id)
	fund(5_000_000)
	testing.SetRealm(testing.NewUserRealm(dave))
	Bid(cross(cur), id, "", "", 0)
	fund(1_414_214 + 1_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	Bid(cross(cur), id, "", "", 1_000_000) // 1% anyway
	testing.SkipHeights(ShotDelay + ShotWindow + 1)
	Draw(cross(cur), id)
	if !p.Shots[0].Resolved || p.Shots[0].Won || p.Misses != 1 || p.Popped {
		t.Fatalf("void: %+v misses %d", *p.Shots[0], p.Misses)
	}
	// the last block of the window still draws
	fund(1_732_051 + 1_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	Bid(cross(cur), id, "", "", 1_000_000)
	testing.SkipHeights(ShotDelay + ShotWindow)
	Draw(cross(cur), id)
	if !p.Shots[1].Resolved || p.Shots[1].DrawH != runtime.ChainHeight() {
		t.Fatalf("window end: %+v", *p.Shots[1])
	}
	conserved(t)

	// the switch: only the admin, and a shot is refused while it is off
	fund(0)
	testing.SetRealm(testing.NewUserRealm(alice))
	aborts(t, "only the deployer", func() { SetShots(cross(cur), false) })
	fund(0)
	testing.SetRealm(testing.NewUserRealm(dave))
	SetShots(cross(cur), false)
	fund(2_000_000 + 1_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	aborts(t, "shots are off", func() { Bid(cross(cur), id, "", "", 1_000_000) })
	if !strings.Contains(Render("json"), "\"shotsOn\":false") {
		t.Error("json should say shots are off")
	}
}

func TestSliceOnABigPot(cur realm, t *testing.T) {
	reset()
	fund(0)
	testing.SetRealm(testing.NewUserRealm(dave))
	id := CreatePool(cross(cur), "big", 3600, 1_000_000, 0)
	p := pool(id)
	fund(50 * ShotCap) // 500 GNOT
	testing.SetRealm(testing.NewUserRealm(dave))
	Bid(cross(cur), id, "", "", 0)
	fund(1_414_214 + 1_000_000) // a 1 GNOT shot: 0.8 × 1/10 = 8%, capped at 1% of a 10 GNOT slice
	testing.SetRealm(testing.NewUserRealm(alice))
	Bid(cross(cur), id, "", "", 1_000_000)
	sh := p.Shots[0]
	if sh.Prize != ShotCap || sh.Bps != ShotMaxBps {
		t.Fatalf("shot at a big pot: %+v", *sh)
	}
	testing.SkipHeights(ShotDelay)
	h := runtime.ChainHeight()
	fund(0)
	testing.SetRealm(testing.NewUserRealm(bob))
	pot0, a0 := p.Pot, owed(alice)
	hit := shotHits(seedFor(id, sh, h), sh.Bps)
	Draw(cross(cur), id)
	if hit {
		if p.Popped || p.Pot != pot0-ShotCap || owed(alice)-a0 != ShotCap || p.ShotPaid != ShotCap {
			t.Fatalf("slice: %+v alice +%d", *p, owed(alice)-a0)
		}
	} else if p.Pot != pot0 || owed(alice) != a0 || p.Misses != 1 {
		t.Fatalf("a miss at a big pot changes nothing but the tally: misses %d", p.Misses)
	}
	conserved(t)
}

func TestBidAfterPopRefunds(cur realm, t *testing.T) {
	reset()
	fund(0)
	testing.SetRealm(testing.NewUserRealm(dave))
	id := CreatePool(cross(cur), "pop", 3600, 1_000_000, 0)
	p := pool(id)
	fund(1_000_000)
	testing.SetRealm(testing.NewUserRealm(dave))
	Bid(cross(cur), id, "", "", 0)
	// a shot that cannot miss is due: the next bid draws it, finds the pool popped, and refunds
	p.Shots = append(p.Shots, &Shot{N: 1, Bidder: alice, Paid: 1, Prize: p.Pot, Bps: 10000, CommitH: runtime.ChainHeight() - ShotDelay})
	b0 := held(bob)
	fund(2_000_000)
	testing.SetRealm(testing.NewUserRealm(bob))
	Bid(cross(cur), id, "", "", 0)
	if !p.Popped || p.LastBidder != alice || p.Bids != 1 || held(bob)-b0 != 2_000_000 { // refunded in full
		t.Fatalf("after pop: %+v bob %d→%d", *p, b0, held(bob))
	}
	conserved(t)
	// and the pop credits alice as the winner; dave, the only other bidder, is the team
	fund(0)
	testing.SetRealm(testing.NewUserRealm(carol))
	Claim(cross(cur), id)
	cut := p.Pot * TeamShare / 100
	if owed(alice) != p.Pot-cut || p.TeamPaid != cut || owed(dave) != cut {
		t.Fatalf("popped payout: alice owed %d of %d, team %d, dave owed %d", owed(alice), p.Pot, p.TeamPaid, owed(dave))
	}
	conserved(t)

	// a closed, unpopped pool refuses a bid outright
	reset()
	fund(0)
	testing.SetRealm(testing.NewUserRealm(dave))
	id = CreatePool(cross(cur), "closed", 60, 1_000_000, 0)
	fund(1_000_000)
	testing.SetRealm(testing.NewUserRealm(dave))
	Bid(cross(cur), id, "", "", 0)
	testing.SkipHeights(13)
	fund(2_000_000)
	testing.SetRealm(testing.NewUserRealm(bob))
	aborts(t, "pool is closed", func() { Bid(cross(cur), id, "", "", 0) })
}

func TestRosterCapAndCreateBounds(cur realm, t *testing.T) {
	reset()
	fund(0)
	testing.SetRealm(testing.NewUserRealm(dave))
	id := CreatePool(cross(cur), "cap", 3600, 1_000, 0)
	p := pool(id)
	p.Roster = nil
	for i := 0; i < RosterMax; i++ {
		p.Roster = append(p.Roster, &Member{Addr: address("g1x" + itoa(int64(i))), Paid: 1})
	}
	fund(1_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	Bid(cross(cur), id, "", "", 0)
	if len(p.Roster) != RosterMax || p.Roster[len(p.Roster)-1].Addr != alice || p.Roster[0].Addr != address("g1x1") {
		t.Fatalf("roster cap: len %d first %s last %s", len(p.Roster), p.Roster[0].Addr, p.Roster[len(p.Roster)-1].Addr)
	}
	fund(0)
	testing.SetRealm(testing.NewUserRealm(dave))
	aborts(t, "life must be at least the window", func() { CreatePool(cross(cur), "x", 7200, 1_000_000, 3600) })
	aborts(t, "life must be between", func() { CreatePool(cross(cur), "x", 3600, 1_000_000, 31*24*3600) })
	id = CreatePool(cross(cur), "x", 20*24*3600, 1_000_000, 0)
	if pool(id).Life != MaxLife {
		t.Fatalf("ten windows past the maximum life is the maximum: %d", pool(id).Life)
	}
	id = CreatePool(cross(cur), "y", 10, 1_000_000, 0)
	if pool(id).Life != MinLife {
		t.Fatalf("ten windows under the minimum life is the minimum: %d", pool(id).Life)
	}
}

func TestRender(cur realm, t *testing.T) {
	reset()
	fund(0)
	testing.SetRealm(testing.NewUserRealm(dave))
	id := CreatePool(cross(cur), "r", 3600, 1_000_000, 0)
	fund(1_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	Bid(cross(cur), id, "", "FR", 0)
	fund(1_414_214 + 200_000)
	testing.SetRealm(testing.NewUserRealm(bob))
	Bid(cross(cur), id, alice.String(), "US", 200_000)
	all := Render("json")
	for _, want := range []string{"\"split\":{\"pot\":55,\"div\":30,\"ref\":10,\"creator\":5,\"team\":35,\"roster\":100,\"shotCap\":10000000,\"shotMaxBps\":100,\"shotFair\":8000,\"shotDelay\":3,\"shotWindow\":2,\"minClock\":300}", "\"shotsOn\":true", "\"bidders\":2", "\"flag\":\"US\"", "\"liveBps\":", "\"lastDay\":", "\"shots\":1,\"misses\":0,\"pending\":1", "\"height\":"} {
		if !strings.Contains(all, want) {
			t.Errorf("json missing %s in %s", want, all)
		}
	}
	one := Render("json/1")
	if !strings.Contains(one, "\"shot\":200000") || !strings.Contains(one, "\"shotlog\":[{\"n\":1") || !strings.Contains(one, "\"hit\":false") {
		t.Errorf("detail: %s", one)
	}
	me := Render("me/" + alice.String())
	if !strings.Contains(me, "\"owed\":424264") || !strings.Contains(me, "\"withdrawn\":0") {
		t.Errorf("me: %s", me)
	}
	if !strings.Contains(Render(""), "last day") || !strings.Contains(Render("1"), "a 0.2 GNOT shot") {
		t.Errorf("markdown: %s", Render("1"))
	}
}
