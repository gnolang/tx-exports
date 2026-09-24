package bubblerumble4

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"crypto/sha256"
	"encoding/hex"
	"strings"
	"testing"
	"time"
)

const realmPath = "gno.land/r/g1leu8d2vsplhehcfkjg50mwgdpxdkt8tztu95wr/bubblerumble4"

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
	keeper, keeperSeen, commits, head, voided, late = "", time.Time{}, nil, 0, 0, 0
	heldAtReset = held(chain.PackageAddress(realmPath))
}

// the keeper in these tests is carol; dave (the admin) names her, and she commits
func keeperUp(cur realm, t *testing.T, secrets ...[]byte) {
	t.Helper()
	fund(0)
	testing.SetRealm(testing.NewUserRealm(dave))
	SetKeeper(cross(cur), carol)
	if len(secrets) > 0 {
		commitSecrets(cur, secrets...)
	} else {
		fund(0)
		testing.SetRealm(testing.NewUserRealm(carol))
		Heartbeat(cross(cur))
	}
}

func hashOf(secret []byte) string { sum := sha256.Sum256(secret); return hex.EncodeToString(sum[:]) }

func commitSecrets(cur realm, secrets ...[]byte) {
	hs := []string{}
	for _, s := range secrets {
		hs = append(hs, hashOf(s))
	}
	fund(0)
	testing.SetRealm(testing.NewUserRealm(carol))
	Commit(cross(cur), strings.Join(hs, ","))
}

func secret(n byte) []byte { return []byte{n, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31} }

// a pool with dave's first bid, alice's second carrying a shot; the shot is sold when sold is true (else why says
// what the realm should have refused it for)
func shotPool(cur realm, t *testing.T, shot int64, sold bool, why ...string) (int64, *Pool) {
	t.Helper()
	fund(0)
	testing.SetRealm(testing.NewUserRealm(dave))
	id := CreatePool(cross(cur), "shots", 3600, 1_000_000, 0)
	p := pool(id)
	fund(5_000_000)
	testing.SetRealm(testing.NewUserRealm(dave))
	Bid(cross(cur), id, "", "", 0)
	a0 := held(alice)
	if len(why) > 0 {
		if got := p.shotRefusal(alice, shot); !strings.Contains(got, why[0]) {
			t.Fatalf("refusal %q, want %q", got, why[0])
		}
	}
	fund(1_414_214 + shot)
	testing.SetRealm(testing.NewUserRealm(alice))
	Bid(cross(cur), id, "", "", shot)
	if p.Bids != 2 {
		t.Fatalf("the bid did not land: %+v", *p)
	}
	if sold && (len(p.Shots) != 1 || p.ShotEscrow != shot) {
		t.Fatalf("the shot was not sold: shots %d escrow %d", len(p.Shots), p.ShotEscrow)
	}
	// (a test's fund() issues the coins to the realm; alice's own balance only ever sees what comes back)
	if !sold && (len(p.Shots) != 0 || p.ShotEscrow != 0 || held(alice)-a0 != shot || p.find(alice).Paid != 1_414_214) {
		t.Fatalf("the shot should have come back: shots %d escrow %d alice %d paid %d", len(p.Shots), p.ShotEscrow, held(alice)-a0, p.find(alice).Paid)
	}
	return id, p
}

// The conservation check: every ugnot the realm took in during the scenario is
// either in an open pot or credited to somebody.
func realmHeld() int64 { return held(chain.PackageAddress(realmPath)) - heldAtReset }

func owedAll() int64 {
	var sum int64
	for _, p := range pools {
		if !p.Paid {
			sum += p.Pot + p.ShotEscrow
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


func TestPkgPath(t *testing.T) {
	if !strings.HasSuffix(pkgPath, "/bubblerumble4") || realmPath != pkgPath {
		t.Fatalf("pkgPath %q realmPath %q", pkgPath, realmPath)
	}
}

func TestKeeperAndCommits(cur realm, t *testing.T) {
	reset()
	// the keeper is named by the deployer alone
	fund(0)
	testing.SetRealm(testing.NewUserRealm(alice))
	aborts(t, "only the deployer", func() { SetKeeper(cross(cur), alice) })
	fund(0)
	testing.SetRealm(testing.NewUserRealm(dave))
	aborts(t, "bad address", func() { SetKeeper(cross(cur), address("nope")) })
	// nobody commits or heartbeats but the keeper — not even the deployer
	fund(0)
	testing.SetRealm(testing.NewUserRealm(dave))
	aborts(t, "only the keeper", func() { Commit(cross(cur), hashOf(secret(1))) })
	aborts(t, "only the keeper", func() { Heartbeat(cross(cur)) })
	keeperUp(cur, t, secret(1), secret(2))
	if len(commits) != 2 || head != 0 || keeperSeen.IsZero() || commitHead() != hashOf(secret(1)) {
		t.Fatalf("commits %d head %d seen %v", len(commits), head, keeperSeen)
	}
	fund(0)
	testing.SetRealm(testing.NewUserRealm(alice))
	aborts(t, "only the keeper", func() { Commit(cross(cur), hashOf(secret(3))) })
	fund(0)
	testing.SetRealm(testing.NewUserRealm(carol))
	aborts(t, "64 hex", func() { Commit(cross(cur), "abc") })
	aborts(t, "already committed", func() { Commit(cross(cur), hashOf(secret(2))) })
	many := []string{}
	for i := 0; i < CommitBatch+1; i++ {
		many = append(many, hashOf(secret(byte(100+i))))
	}
	aborts(t, "hashes", func() { Commit(cross(cur), strings.Join(many, ",")) })
	// the unused list, for a keeper that starts and must know what it holds
	if c := Render("commits"); !strings.Contains(c, hashOf(secret(1))+"\",\""+hashOf(secret(2))) {
		t.Fatalf("commits: %s", c)
	}
	// retire clamps, is the keeper's or the deployer's, and is no sign of life
	seen := keeperSeen
	testing.SkipHeights(2)
	fund(0)
	testing.SetRealm(testing.NewUserRealm(alice))
	aborts(t, "only the keeper or the deployer", func() { Retire(cross(cur), 1) })
	fund(0)
	testing.SetRealm(testing.NewUserRealm(dave))
	Retire(cross(cur), 5)
	if len(commits) != 0 || keeperSeen != seen {
		t.Fatalf("retire: %d left, seen moved %v", len(commits), keeperSeen != seen)
	}
	// a new keeper drops what the old one queued
	commitSecrets(cur, secret(7))
	fund(0)
	testing.SetRealm(testing.NewUserRealm(dave))
	SetKeeper(cross(cur), bob)
	if len(commits) != 0 || keeper != bob {
		t.Fatalf("set keeper: %d commits, keeper %s", len(commits), keeper)
	}
	// the queue's bound
	reset()
	keeperUp(cur, t)
	for i := 0; i < MaxCommits/CommitBatch; i++ {
		hs := []string{}
		for j := 0; j < CommitBatch; j++ {
			hs = append(hs, hashOf([]byte{byte(i), byte(j), 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32}))
		}
		fund(0)
		testing.SetRealm(testing.NewUserRealm(carol))
		Commit(cross(cur), strings.Join(hs, ","))
	}
	fund(0)
	testing.SetRealm(testing.NewUserRealm(carol))
	aborts(t, "at most", func() { Commit(cross(cur), hashOf(secret(9))) })
	// compaction: past CommitCompact used ones, the queue is rebuilt from the head
	head = CommitCompact + 1
	fund(0)
	testing.SetRealm(testing.NewUserRealm(carol))
	Commit(cross(cur), hashOf(secret(9)))
	if head != 0 || len(commits) != MaxCommits-CommitCompact-1+1 {
		t.Fatalf("compaction: head %d len %d", head, len(commits))
	}
}

func TestShotSoldPricedOnTake(cur realm, t *testing.T) {
	reset()
	keeperUp(cur, t, secret(1))
	id, p := shotPool(cur, t, 1_000_000, true)
	sh := p.Shots[0]
	// the odds: on the pot a pop would pay from (the shot in, the tip out), against the most alice could take —
	// dave alone is the team, so the 35% cut counts as hers, and nothing has slid: the take is the pot
	potThen := p.Pot + 1_000_000 - RevealTip
	if sh.Take != potThen || sh.Bps != ShotBps(1_000_000-RevealTip, potThen) || sh.Bps == 0 || sh.Bps > ShotMaxBps {
		t.Fatalf("shot: %+v pot %d", *sh, p.Pot)
	}
	if sh.Hash != commits[0] || head != 1 || sh.CommitH != runtime.ChainHeight() || p.find(alice).Paid != 1_414_214+1_000_000 {
		t.Fatalf("commitment: %+v head %d", *sh, head)
	}
	if _, cut := p.payout(alice, potThen, false); p.Take(alice, potThen) != potThen-0 || cut != potThen*TeamShare/100 {
		t.Fatalf("take %d cut %d of %d", p.Take(alice, potThen), cut, potThen)
	}
	conserved(t)
	_ = id
}

func TestShotComesBack(cur realm, t *testing.T) {
	// no commitment free: the bid stands, the shot's money comes back
	reset()
	keeperUp(cur, t)
	shotPool(cur, t, 1_000_000, false, "no commitment free")
	// the keeper not seen for KeeperFresh: the same
	reset()
	keeperUp(cur, t, secret(1))
	testing.SkipHeights(KeeperFresh/5 + 1)
	shotPool(cur, t, 1_000_000, false, "not been seen")
	// under MinShot
	reset()
	keeperUp(cur, t, secret(1))
	shotPool(cur, t, MinShot-1, false, "smallest shot")
	// shots off
	reset()
	keeperUp(cur, t, secret(1))
	fund(0)
	testing.SetRealm(testing.NewUserRealm(dave))
	SetShots(cross(cur), false)
	shotPool(cur, t, 1_000_000, false, "shots are off")
	// the keeper itself never shoots
	reset()
	keeperUp(cur, t, secret(1))
	fund(0)
	testing.SetRealm(testing.NewUserRealm(dave))
	id := CreatePool(cross(cur), "keeper", 3600, 1_000_000, 0)
	p := pool(id)
	fund(1_000_000 + 1_000_000)
	testing.SetRealm(testing.NewUserRealm(carol))
	Bid(cross(cur), id, "", "", 1_000_000)
	if len(p.Shots) != 0 || p.Bids != 1 || p.find(carol).Paid != 1_000_000 {
		t.Fatalf("the keeper's shot should come back: %+v", *p)
	}
	// a shot that buys no chance at all: a pot so large that MinShot is under one basis point
	reset()
	keeperUp(cur, t, secret(1))
	fund(0)
	testing.SetRealm(testing.NewUserRealm(dave))
	id = CreatePool(cross(cur), "huge", 3600, 1_000_000, 0)
	p = pool(id)
	fund(2_000_000_000_000) // a 2,000,000 GNOT seed
	testing.SetRealm(testing.NewUserRealm(dave))
	Bid(cross(cur), id, "", "", 0)
	fund(1_414_214 + MinShot)
	testing.SetRealm(testing.NewUserRealm(alice))
	Bid(cross(cur), id, "", "", MinShot)
	if len(p.Shots) != 0 || p.ShotEscrow != 0 || p.Bids != 2 || p.find(alice).Paid != 1_414_214 {
		t.Fatalf("a chanceless shot should come back: %+v", *p)
	}
	conserved(t)
	// the winner's share slid under the floor: a 1h window, a 90-minute life; bob keeps the clock alive at 50 minutes,
	// and 70 minutes in the live share is 2222 bps
	reset()
	keeperUp(cur, t, secret(1))
	fund(0)
	testing.SetRealm(testing.NewUserRealm(dave))
	id = CreatePool(cross(cur), "late life", 3600, 1_000_000, 5400)
	p = pool(id)
	fund(1_000_000)
	testing.SetRealm(testing.NewUserRealm(dave))
	Bid(cross(cur), id, "", "", 0)
	testing.SkipHeights(600) // 50 minutes
	fund(1_414_214)
	testing.SetRealm(testing.NewUserRealm(bob))
	Bid(cross(cur), id, "", "", 0)
	testing.SkipHeights(240) // 70 minutes in all
	fund(0)
	testing.SetRealm(testing.NewUserRealm(carol))
	Heartbeat(cross(cur))
	if p.LiveBps() >= LiveFloor || p.Over() {
		t.Fatalf("live %d over %v", p.LiveBps(), p.Over())
	}
	if got := p.shotRefusal(alice, 1_000_000); !strings.Contains(got, "slid under a quarter") {
		t.Fatalf("refusal %q", got)
	}
	fund(1_732_051 + 1_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	Bid(cross(cur), id, "", "", 1_000_000)
	if len(p.Shots) != 0 || p.ShotEscrow != 0 || p.Bids != 3 {
		t.Fatalf("a shot in the last quarter should come back: %+v", *p)
	}
	conserved(t)
}

func TestRevealHitOrMiss(cur realm, t *testing.T) {
	reset()
	keeperUp(cur, t, secret(1))
	id, p := shotPool(cur, t, 1_000_000, true)
	sh := p.Shots[0]
	s1 := hex.EncodeToString(secret(1))
	// too early: nothing to reveal yet
	fund(0)
	testing.SetRealm(testing.NewUserRealm(carol))
	aborts(t, "nothing revealed", func() { Reveal(cross(cur), itoa(id)+":1:"+s1) })
	testing.SkipHeights(ShotDelay)
	h := runtime.ChainHeight()
	fund(0)
	testing.SetRealm(testing.NewUserRealm(carol))
	aborts(t, "nothing revealed", func() { Reveal(cross(cur), itoa(id)+":1:"+hex.EncodeToString(secret(2))) })
	aborts(t, "pool:shot:secret", func() { Reveal(cross(cur), "1:1") })
	aborts(t, "no such shot", func() { Reveal(cross(cur), itoa(id)+":2:"+s1) })
	pot0, k0 := p.Pot, owed(carol)
	want := shotHits(seedFor(id, sh, secret(1), h), sh.Bps) // the same inputs the realm hashes, in the same block
	fund(0)
	testing.SetRealm(testing.NewUserRealm(bob)) // anyone may reveal; the tip is still the keeper's
	Reveal(cross(cur), itoa(id)+":1:"+s1)
	if !sh.Resolved || sh.Void || sh.Won != want || sh.DrawH != h || sh.Revealer != bob || p.ShotEscrow != 0 || p.Pot != pot0+1_000_000-RevealTip || owed(carol)-k0 != RevealTip || p.Late != 0 {
		t.Fatalf("revealed: %+v pot %d→%d carol +%d", *sh, pot0, p.Pot, owed(carol)-k0)
	}
	if want {
		if !p.Popped || p.LastBidder != alice || !p.Over() || p.Misses != 0 || player(alice).Hits != 1 {
			t.Fatalf("a hit pops: %+v", *p)
		}
	} else if p.Popped || p.LastBidder != alice || p.Misses != 1 {
		t.Fatalf("a miss is counted and changes nothing else: %+v", *p)
	}
	fund(0)
	testing.SetRealm(testing.NewUserRealm(carol))
	aborts(t, "nothing revealed", func() { Reveal(cross(cur), itoa(id)+":1:"+s1) }) // twice: skipped
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
	// the two outcomes, made sure of: a shot that cannot miss pops the pool and Claim pays the shooter as any
	// winner (dave, the only other bidder, is the team); one that cannot hit is a miss and the pool goes on
	for _, sure := range []int64{10000, 0} {
		reset()
		keeperUp(cur, t, secret(1))
		id, p := shotPool(cur, t, 1_000_000, true)
		p.Shots[0].Bps = sure
		testing.SkipHeights(ShotDelay)
		pot0 := p.Pot
		fund(0)
		testing.SetRealm(testing.NewUserRealm(carol))
		Reveal(cross(cur), itoa(id)+":1:"+hex.EncodeToString(secret(1)))
		if sure == 0 {
			if p.Popped || p.Misses != 1 || p.Over() || p.Pot != pot0+1_000_000-RevealTip {
				t.Fatalf("sure miss: %+v", *p)
			}
			conserved(t)
			continue
		}
		if !p.Popped || p.LastBidder != alice || !p.Over() || player(alice).Hits != 1 || p.Pot != pot0+1_000_000-RevealTip {
			t.Fatalf("sure hit: %+v", *p)
		}
		// a bid after the pop is refunded whole, shot included
		b0 := held(bob)
		fund(2_000_000 + 500_000)
		testing.SetRealm(testing.NewUserRealm(bob))
		Bid(cross(cur), id, "", "", 500_000)
		if held(bob)-b0 != 2_500_000 || p.Bids != 2 {
			t.Fatalf("after the pop: bob %d, bids %d", held(bob)-b0, p.Bids)
		}
		fund(0)
		testing.SetRealm(testing.NewUserRealm(bob))
		Claim(cross(cur), id)
		// the team's cut to dave, and the sliver of the slide the few blocks since the first bid moved his way too
		cut := p.Pot * TeamShare / 100
		if owed(alice) != p.Pot-cut-p.SharedPaid || p.TeamPaid != cut || p.WinnerPaid != owed(alice) || owed(dave) != cut+424_264+p.SharedPaid || p.SharedPaid > cut/100 {
			t.Fatalf("popped payout: alice owed %d of %d, team %d, shared %d, dave %d", owed(alice), p.Pot, p.TeamPaid, p.SharedPaid, owed(dave))
		}
		conserved(t)
	}
}

func TestRevealOrderAndMany(cur realm, t *testing.T) {
	reset()
	keeperUp(cur, t, secret(1), secret(2))
	id, p := shotPool(cur, t, 1_000_000, true)
	fund(1_732_051 + 1_000_000)
	testing.SetRealm(testing.NewUserRealm(bob))
	Bid(cross(cur), id, "", "", 1_000_000)
	if len(p.Shots) != 2 || p.Shots[1].Hash != commits[1] || head != 2 || p.ShotEscrow != 2_000_000 {
		t.Fatalf("two shots: %d escrow %d head %d", len(p.Shots), p.ShotEscrow, head)
	}
	testing.SkipHeights(ShotDelay)
	s1, s2 := hex.EncodeToString(secret(1)), hex.EncodeToString(secret(2))
	// the second alone waits for the first
	fund(0)
	testing.SetRealm(testing.NewUserRealm(carol))
	aborts(t, "nothing revealed", func() { Reveal(cross(cur), itoa(id)+":2:"+s2) })
	if p.Shots[1].Resolved {
		t.Fatal("out of order")
	}
	// both in one call, in order; a hit on the first closes the pool and voids the second as closed
	fund(0)
	testing.SetRealm(testing.NewUserRealm(carol))
	Reveal(cross(cur), itoa(id)+":1:"+s1+","+itoa(id)+":2:"+s2)
	if !p.Shots[0].Resolved || !p.Shots[1].Resolved || p.ShotEscrow != 0 {
		t.Fatalf("both: %+v %+v", *p.Shots[0], *p.Shots[1])
	}
	if p.Shots[0].Won && (!p.Shots[1].Void || p.Voided != 1) {
		t.Fatalf("a shot after the pop is void: %+v", *p.Shots[1])
	}
	if !p.Shots[0].Won && p.Shots[1].Void {
		t.Fatalf("the second should have been drawn: %+v", *p.Shots[1])
	}
	conserved(t)
	// and made sure of: a first shot that cannot miss voids the second as closed, in the same call
	reset()
	keeperUp(cur, t, secret(1), secret(2))
	id, p = shotPool(cur, t, 1_000_000, true)
	fund(1_732_051 + 1_000_000)
	testing.SetRealm(testing.NewUserRealm(bob))
	Bid(cross(cur), id, "", "", 1_000_000)
	p.Shots[0].Bps = 10000
	testing.SkipHeights(ShotDelay)
	pot0 := p.Pot
	fund(0)
	testing.SetRealm(testing.NewUserRealm(carol))
	Reveal(cross(cur), itoa(id)+":1:"+s1+","+itoa(id)+":2:"+s2)
	if !p.Popped || !p.Shots[1].Void || p.Voided != 1 || p.ShotEscrow != 0 || p.Pot != pot0+2_000_000-RevealTip {
		t.Fatalf("pop then void: %+v %+v pot %d→%d", *p.Shots[0], *p.Shots[1], pot0, p.Pot)
	}
	conserved(t)
}

func TestVoidsAndLate(cur realm, t *testing.T) {
	// unrevealed past the window: Settle voids it into the pot, no tip, a miss
	reset()
	keeperUp(cur, t, secret(1), secret(2), secret(3))
	id, p := shotPool(cur, t, 1_000_000, true)
	testing.SkipHeights(ShotDelay + ShotWindow + 1)
	pot0, k0 := p.Pot, owed(carol)
	fund(0)
	testing.SetRealm(testing.NewUserRealm(bob))
	Settle(cross(cur), id)
	sh := p.Shots[0]
	if !sh.Resolved || !sh.Void || sh.Won || p.Misses != 1 || p.Voided != 1 || voided != 1 || p.Pot != pot0+1_000_000 || p.ShotEscrow != 0 || owed(carol) != k0 {
		t.Fatalf("void: %+v pot %d→%d", *sh, pot0, p.Pot)
	}
	// a reveal that comes late is a void too, whoever sends it
	fund(1_732_051 + 1_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	Bid(cross(cur), id, "", "", 1_000_000)
	testing.SkipHeights(ShotDelay + ShotWindow + 1)
	fund(0)
	testing.SetRealm(testing.NewUserRealm(carol))
	aborts(t, "nothing revealed", func() { Reveal(cross(cur), itoa(id)+":2:"+hex.EncodeToString(secret(2))) }) // on chain the abort reverts its own settling
	fund(0)
	testing.SetRealm(testing.NewUserRealm(carol))
	Settle(cross(cur), id)
	if !p.Shots[1].Void || p.Voided != 2 || p.Misses != 2 || owed(carol) != k0 {
		t.Fatalf("late reveal: %+v", *p.Shots[1])
	}
	// the last block of the window still draws, and counts as late
	fund(2_000_000 + 1_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	Bid(cross(cur), id, "", "", 1_000_000)
	testing.SkipHeights(ShotDelay + ShotWindow)
	fund(0)
	testing.SetRealm(testing.NewUserRealm(carol))
	Reveal(cross(cur), itoa(id)+":3:"+hex.EncodeToString(secret(3)))
	if !p.Shots[2].Resolved || p.Shots[2].Void || p.Late != 1 || late != 1 || p.Shots[2].DrawH != runtime.ChainHeight() {
		t.Fatalf("window end: %+v late %d", *p.Shots[2], p.Late)
	}
	conserved(t)

	// a pool that closes with a shot pending: Claim settles it first, into the pot the winner takes
	reset()
	keeperUp(cur, t, secret(4))
	fund(0)
	testing.SetRealm(testing.NewUserRealm(dave))
	id = CreatePool(cross(cur), "closing", 60, 1_000_000, 0)
	p = pool(id)
	fund(1_000_000)
	testing.SetRealm(testing.NewUserRealm(dave))
	Bid(cross(cur), id, "", "", 0)
	// a shot that would be due: planted, since MinClock keeps a real one clear of the close
	p.Shots = append(p.Shots, &Shot{N: 1, Bidder: alice, Paid: 500_000, Take: p.Pot, Bps: 100, CommitH: runtime.ChainHeight(), Hash: commits[0]})
	p.ShotEscrow += 500_000
	testing.IssueCoins(chain.PackageAddress(realmPath), chain.Coins{{"ugnot", 500_000}})
	testing.SkipHeights(13) // the clock ran out
	fund(0)
	testing.SetRealm(testing.NewUserRealm(carol))
	aborts(t, "nothing revealed", func() { Reveal(cross(cur), itoa(id)+":1:"+hex.EncodeToString(secret(4))) }) // the pool closed first
	fund(0)
	testing.SetRealm(testing.NewUserRealm(carol))
	Settle(cross(cur), id)
	if !p.Shots[0].Void || p.ShotEscrow != 0 || p.Pot != 950_000+500_000 { // the creator's 5% left the pot at the bid
		t.Fatalf("closed first: %+v pot %d", *p.Shots[0], p.Pot)
	}
	fund(0)
	testing.SetRealm(testing.NewUserRealm(bob))
	Claim(cross(cur), id)
	if owed(dave) != p.Pot || !p.Paid {
		t.Fatalf("the pot, shot included, is the winner's: owed %d of %d", owed(dave), p.Pot)
	}
	conserved(t)
}

func TestTakeCountsTeamAndSlide(cur realm, t *testing.T) {
	reset()
	keeperUp(cur, t, secret(1))
	// alice under TV, bob under TV with a small bid, dave flagless: a pop for alice pays her the pot less what has
	// slid; the team's 35% goes to bob, and the take counts it as hers
	fund(0)
	testing.SetRealm(testing.NewUserRealm(dave))
	id := CreatePool(cross(cur), "team", 3600, 1_000_000, 7200)
	p := pool(id)
	fund(1_000_000)
	testing.SetRealm(testing.NewUserRealm(dave))
	Bid(cross(cur), id, "", "", 0)
	fund(1_414_214)
	testing.SetRealm(testing.NewUserRealm(bob))
	Bid(cross(cur), id, "", "TV", 0)
	fund(1_732_051)
	testing.SetRealm(testing.NewUserRealm(alice))
	Bid(cross(cur), id, "", "TV", 0)
	pot := p.Pot
	toWinner, cut := p.payout(alice, pot, false)
	if cut != pot*TeamShare/100 || toWinner != pot-cut || p.Take(alice, pot) != pot {
		t.Fatalf("fresh pool: toWinner %d cut %d take %d of %d", toWinner, cut, p.Take(alice, pot), pot)
	}
	// halfway through the life, half the rest has slid to the roster by paid-in: the take is the pot less the others' part
	testing.SkipHeights(720)
	if p.LiveBps() > 5000 || p.LiveBps() < 4990 {
		t.Fatalf("live %d", p.LiveBps())
	}
	toWinner, cut = p.payout(alice, pot, false)
	rest := pot - cut
	shared := rest - mulDiv(rest, p.LiveBps(), 10000)
	var total, others int64
	for _, m := range p.Roster {
		total += m.Paid
		if m.Addr != alice {
			others += mulDiv(shared, m.Paid, total)
		}
	}
	_ = others
	if p.Take(alice, pot) != toWinner+cut || toWinner >= pot-cut || p.Take(alice, pot) <= pot/2 {
		t.Fatalf("slid: toWinner %d cut %d take %d of %d", toWinner, cut, p.Take(alice, pot), pot)
	}
	// a shooter alone on the roster takes everything
	reset()
	keeperUp(cur, t, secret(1))
	fund(0)
	testing.SetRealm(testing.NewUserRealm(dave))
	id = CreatePool(cross(cur), "alone", 3600, 1_000_000, 0)
	p = pool(id)
	fund(1_000_000 + 1_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	Bid(cross(cur), id, "", "", 1_000_000)
	if len(p.Shots) != 1 || p.Shots[0].Take != p.Pot+1_000_000-RevealTip {
		t.Fatalf("alone: %+v pot %d", *p.Shots[0], p.Pot)
	}
	conserved(t)
}

func TestRender(cur realm, t *testing.T) {
	reset()
	keeperUp(cur, t, secret(1))
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
	for _, want := range []string{"\"split\":{\"pot\":55,\"div\":30,\"ref\":10,\"creator\":5,\"team\":35,\"roster\":100,\"shotMaxBps\":100,\"shotFair\":8000,\"shotDelay\":3,\"shotWindow\":2,\"minClock\":300,\"minShot\":100000,\"revealTip\":20000,\"keeperFresh\":300,\"liveFloor\":2500}", "\"shotsOn\":true", "\"keeper\":\"" + carol.String() + "\"", "\"keeperSeen\":", "\"commitsFree\":0,\"commitHead\":\"\",\"voided\":0,\"late\":0", "\"bidders\":2", "\"flag\":\"US\"", "\"liveBps\":", "\"lastDay\":", "\"shots\":1,\"misses\":0,\"voided\":0,\"late\":0,\"pending\":1,\"escrow\":200000", "\"height\":"} {
		if !strings.Contains(all, want) {
			t.Errorf("json missing %s in %s", want, all)
		}
	}
	one := Render("json/1")
	for _, want := range []string{"\"shot\":200000", "\"shotlog\":[{\"n\":1", "\"commit\":\"" + hashOf(secret(1)) + "\"", "\"revealAt\":", "\"revealBy\":", "\"hit\":false,\"void\":false", "\"take\":"} {
		if !strings.Contains(one, want) {
			t.Errorf("detail missing %s in %s", want, one)
		}
	}
	me := Render("me/" + alice.String())
	if !strings.Contains(me, "\"owed\":424264") || !strings.Contains(me, "\"withdrawn\":0") {
		t.Errorf("me: %s", me)
	}
	if !strings.Contains(Render(""), "Bubble Rumble v4") || !strings.Contains(Render("1"), "a 0.2 GNOT shot") || !strings.Contains(Render("1"), "unrevealed: 0") {
		t.Errorf("markdown: %s", Render("1"))
	}
	if !strings.Contains(Render("commits"), "\"commits\":[]") {
		t.Errorf("commits: %s", Render("commits"))
	}
}
