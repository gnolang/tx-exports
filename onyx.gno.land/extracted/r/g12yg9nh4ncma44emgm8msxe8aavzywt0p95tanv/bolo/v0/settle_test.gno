package bolo

import (
	"chain"
	"chain/banker"
	"math"
	"strconv"
	"testing"

	"gno.land/p/nt/seqid/v0"
	"gno.land/p/nt/testutils/v0"
)

// The helpers' tests come first: a write's test that panics through a crossing call
// ends the package's unit tests.

func TestExitClaim(t *testing.T) {
	for _, k := range []struct{ left, pool, base, want int64 }{
		{100, 150, 300, 50},
		{1, 1, 3, 0}, // rounding down: dust stays in the escrow
		{2, 1, 3, 0},
		{3, math.MaxInt64, 7, 3952873730080618203},
		{math.MaxInt64, math.MaxInt64, math.MaxInt64, math.MaxInt64},
		{math.MaxInt64 / 2, math.MaxInt64 - 1, math.MaxInt64, 4611686018427387902},
		{1_000_000_000_000_000, 1_000_000_000_000_000, 3_000_000_000_000_007, 333333333333332},
		{123456789, 987654321987, 999999999999, 121932631},
		{5, 0, 9, 0},
	} {
		if got := exitClaim(k.left, k.pool, k.base); got != k.want {
			t.Errorf("exitClaim(%d, %d, %d) = %d, want %d", k.left, k.pool, k.base, got, k.want)
		}
	}
	// Neither of Div64's own panics, keyless, is ever reached.
	for name, k := range map[string]struct{ left, pool, base int64 }{
		"a base of 0":            {0, 10, 0},
		"a left above the base":  {11, 10, 10},
		"a negative pool":        {1, -1, 10},
		"a negative base":        {1, 10, -1},
		"past 64 bits otherwise": {math.MaxInt64, math.MaxInt64, math.MaxInt64 - 1},
	} {
		if !panicsWith(func() { exitClaim(k.left, k.pool, k.base) }, ErrBooksMismatch) {
			t.Errorf("%s: not ErrBooksMismatch", name)
		}
	}
}

// exitCampaign is an escrow campaign whose exit window is open: ada, bo and cy gave
// amounts, then withdrawn was taken, and it closed ExitDelay ago. Its escrow holds the
// tracked rest.
func exitCampaign(id seqid.ID, withdrawn int64, amounts ...int64) (*campaign, []address) {
	c := testCampaign(id, modeEscrow, 0)
	donors := []address{testutils.TestAddress("ada"), testutils.TestAddress("bo"), testutils.TestAddress("cy")}
	for i, amount := range amounts {
		c.contributions.Set(donors[i].String(), &contribution{amount: amount})
		c.state.raised += amount
		c.state.donorCount++
	}
	s := c.state
	s.withdrawn, s.everWithdrawn = withdrawn, true
	s.status, s.closedAt = statusClosed, now()-c.params.ExitDelay
	testing.IssueCoins(escrowAddr(c.id), chain.NewCoins(chain.NewCoin("ugnot", s.raised-withdrawn)))
	return c, donors
}

// TestExitRefunds: the first claim freezes the pool and the base, each donor claims
// once, pro-rata, and the claims never add up to more than the pool (INV-17). The pool
// is the tracked balance: coins sent outside Bolo aren't the donors'. The first model
// is the reviewer's: three gifts of 100, 150 withdrawn, 50 each — where a claim
// repeated against a recomputed pool once drained about 100.
func TestExitRefunds(t *testing.T) {
	for i, k := range []struct {
		withdrawn       int64
		amounts, claims []int64
	}{
		{150, []int64{100, 100, 100}, []int64{50, 50, 50}},
		{300, []int64{100, 200, 300}, []int64{50, 100, 150}},
		{100, []int64{100, 100, 101}, []int64{66, 66, 67}}, // rounded down: 2 stay in the escrow
	} {
		c, donors := exitCampaign(seqid.ID(9501+100*i), k.withdrawn, k.amounts...)
		testing.IssueCoins(escrowAddr(c.id), chain.NewCoins(chain.NewCoin("ugnot", 7))) // sent outside Bolo
		id, unstore := storeCampaign(c)
		pool, base := c.state.raised-k.withdrawn, c.state.raised
		checkBooks(t, c)
		if v := GetContribution(id, donors[1]); v.Window != windowExit || v.RefundableNow != k.claims[1] {
			t.Errorf("model %d, bo before any claim: %v", i, v)
		}
		var paid int64
		for j, want := range k.claims {
			r := bookRefund(c, donors[j])
			checkBooks(t, c)
			if r.amount != want || r.kind != windowExit {
				t.Errorf("model %d, claim %d = %v, want %d", i, j, *r, want)
			}
			paid += r.amount
			// The snapshot is the first claim's, never recomputed (INV-17).
			if s := c.state; !s.exitFrozen || s.exitPool != pool || s.exitBase != base {
				t.Errorf("model %d, after claim %d: frozen %t, pool %d, base %d", i, j, s.exitFrozen, s.exitPool, s.exitBase)
			}
			if !panicsWith(func() { bookRefund(c, donors[j]) }, ErrRefundWindowClosed) {
				t.Errorf("model %d, a second claim by donor %d: not ErrRefundWindowClosed", i, j)
			}
			if v := GetContribution(id, donors[j]); v.Window != "" || v.RefundableNow != 0 || !v.ExitClaimed {
				t.Errorf("model %d, donor %d after their claim: %v", i, j, v)
			}
		}
		if paid > pool {
			t.Errorf("model %d: the claims add up to %d, past the pool %d", i, paid, pool)
		}
		unstore()
	}
}

// TestExitClaimCap: a claim above the tracked balance is ErrBooksMismatch, whatever
// the snapshot says (INV-17).
func TestExitClaimCap(t *testing.T) {
	c, donors := exitCampaign(9520, 150, 100, 100, 100)
	s := c.state
	s.exitFrozen, s.exitPool, s.exitBase = true, 300, 100 // ada's claim: 300, the tracked balance 150
	if !panicsWith(func() { bookRefund(c, donors[0]) }, ErrBooksMismatch) {
		t.Errorf("a claim above the tracked balance: not ErrBooksMismatch")
	}
}

// TestExitBase: the base is what is left of every record when the first claim comes,
// Raised − Refunded: an open-window refund before the withdrawal is taken out of it.
func TestExitBase(t *testing.T) {
	c := testCampaign(9502, modeEscrow, 0)
	ada, bo, cy := testutils.TestAddress("ada"), testutils.TestAddress("bo"), testutils.TestAddress("cy")
	c.contributions.Set(ada.String(), &contribution{amount: 400})
	c.contributions.Set(bo.String(), &contribution{amount: 200})
	c.contributions.Set(cy.String(), &contribution{amount: 300, refunded: 300}) // all back, in the open window
	s := c.state
	s.raised, s.refunded, s.withdrawn, s.everWithdrawn = 900, 300, 300, true
	s.status, s.closedAt = statusClosed, now()-c.params.ExitDelay
	testing.IssueCoins(escrowAddr(c.id), chain.NewCoins(chain.NewCoin("ugnot", 300)))
	checkBooks(t, c)
	// Tracked 300, base 600 — ada's 400 and bo's 200: ada claims 400 × 300 / 600.
	if r := bookRefund(c, ada); r.amount != 200 || s.exitBase != 600 || s.exitPool != 300 {
		t.Errorf("ada's claim %d; base %d, pool %d", r.amount, s.exitBase, s.exitPool)
	}
	checkBooks(t, c)
}

// TestExitUneven: forty donors with uneven gifts, some refunded in the open window,
// then a withdrawal, more gifts from half of them and others, and every donor's claim
// in a scrambled order. Each claim is paid from the tracked balance, the claims never
// pass the pool, and what is left is rounding dust, under one ugnot a claim (INV-17).
func TestExitUneven(t *testing.T) {
	c := testCampaign(9519, modeEscrow, 0)
	x := int64(12345)
	next := func() int64 { // a fixed sequence of amounts from 1 to about a million
		x = (x*1103515245 + 12345) % 2147483648
		return x%1_000_003 + 1
	}
	donors := make([]address, 40)
	for i := range donors {
		donors[i] = testutils.TestAddress("donor" + strconv.Itoa(i))
	}
	s := c.state
	for i := 0; i < 20; i++ {
		if i%7 == 3 { // refunded in full in the open window: the coins went back
			a := next()
			c.contributions.Set(donors[i].String(), &contribution{amount: a, refunded: a})
			s.raised, s.refunded, s.donorCount = s.raised+a, s.refunded+a, s.donorCount+1
			continue
		}
		fund(c, donors[i], next())
	}
	bookWithdrawal(c)
	for i := 10; i < 40; i++ {
		fund(c, donors[i], next())
	}
	s.status, s.closedAt = statusClosed, now()-c.params.ExitDelay
	checkBooks(t, c)
	pool := trackedBalance(c)
	var paid, claims int64
	for i := 0; i < 40; i++ {
		d := donors[i*17%40] // every donor once: 17 and 40 share no factor
		if k := contributionOf(c, d); k.amount == k.refunded {
			continue
		}
		left := trackedBalance(c)
		r := bookRefund(c, d)
		checkBooks(t, c)
		if r.amount > left || r.amount <= 0 {
			t.Errorf("a claim of %d against a tracked %d", r.amount, left)
		}
		paid += r.amount
		claims++
	}
	if paid > pool || pool-paid >= claims || claims != 39 { // all but donor 3: refunded in full, never gave again
		t.Errorf("%d claims paid %d of a pool %d", claims, paid, pool)
	}
}

// TestExitWindow: the exit window needs a withdrawal, a close, ExitDelay passed and a
// tracked balance; a claim that rounds to 0 uses nothing.
func TestExitWindow(t *testing.T) {
	c, donors := exitCampaign(9503, 300, 100, 200, 300)
	c.state.closedAt = now() - c.params.ExitDelay + 1
	if !panicsWith(func() { checkRefund(c, donors[0]) }, ErrRefundWindowClosed) {
		t.Errorf("a second before the exit window: not ErrRefundWindowClosed")
	}
	c.state.closedAt = now() - c.params.ExitDelay
	checkRefund(c, donors[0])
	c.state.status = statusSettled
	checkRefund(c, donors[0]) // settlement closes no window (INV-16)
	c.state.status = statusOpen
	if !panicsWith(func() { checkRefund(c, donors[0]) }, ErrRefundWindowClosed) {
		t.Errorf("open: not ErrRefundWindowClosed")
	}
	c.state.status = statusClosed
	c.state.withdrawn = 600 // nothing tracked left
	if !panicsWith(func() { checkRefund(c, donors[0]) }, ErrRefundWindowClosed) {
		t.Errorf("no tracked balance: not ErrRefundWindowClosed")
	}

	// Dust: a gift of 1 against a pool far smaller than the base claims 0.
	d := testCampaign(9504, modeEscrow, 0)
	tiny, big := testutils.TestAddress("tiny"), testutils.TestAddress("big")
	d.contributions.Set(tiny.String(), &contribution{amount: 1})
	d.contributions.Set(big.String(), &contribution{amount: 1000})
	d.state.raised, d.state.withdrawn, d.state.everWithdrawn = 1001, 1000, true
	d.state.status, d.state.closedAt = statusClosed, now()-d.params.ExitDelay
	if !panicsWith(func() { checkRefund(d, tiny) }, ErrNothingToRefund) {
		t.Errorf("a claim of 0: not ErrNothingToRefund")
	}
	if contributionOf(d, tiny).exitClaimed {
		t.Errorf("a claim of 0 used the claim")
	}
	dustID, unstoreDust := storeCampaign(d)
	if v := GetContribution(dustID, tiny); v.Window != "" || v.RefundableNow != 0 {
		t.Errorf("a claim of 0 shows a window Refund refuses: %v", v)
	}
	unstoreDust()

	// GetContribution counts a passed deadline as recorded: the stored status is open.
	e := testCampaign(9505, modeEscrow, now()-61*secondsPerDay)
	e.contributions.Set(tiny.String(), &contribution{amount: 100})
	e.contributions.Set(big.String(), &contribution{amount: 100})
	e.state.raised, e.state.withdrawn, e.state.everWithdrawn = 200, 100, true
	id, unstore := storeCampaign(e)
	defer unstore()
	if v := GetContribution(id, tiny); v.Window != windowExit || v.RefundableNow != 50 {
		t.Errorf("past an unrecorded deadline and its exit delay: %v", v)
	}
}

func TestCheckFinalizable(t *testing.T) {
	c := testCampaign(9506, modeEscrow, 0)
	if !panicsWith(func() { checkFinalizable(c) }, ErrNotFinalizable) {
		t.Errorf("open: not ErrNotFinalizable")
	}
	c.state.status, c.state.closedAt = statusClosed, now()
	checkFinalizable(c) // nothing tracked
	c.state.raised = 10
	if !panicsWith(func() { checkFinalizable(c) }, ErrNotFinalizable) {
		t.Errorf("a tracked balance before the exit window: not ErrNotFinalizable")
	}
	c.state.closedAt = now() - c.params.ExitDelay
	checkFinalizable(c) // the exit window is open
	d := testCampaign(9507, modeDirect, 0)
	d.state.status, d.state.closedAt = statusClosed, now()
	checkFinalizable(d) // direct: at once
}

// TestFinalizeBooks: the first call settles; untracked coins go to the beneficiary,
// the tracked balance never; the bond address's coins to the organizer, but a bond on
// hold; the bond once its hold ends, unless slashed; later calls forward what arrives.
func TestFinalizeBooks(t *testing.T) {
	c := testCampaign(9508, modeEscrow, 0)
	fund(c, testutils.TestAddress("donor"), 500) // tracked, the donors'
	testing.IssueCoins(escrowAddr(c.id), chain.NewCoins(chain.NewCoin("ugnot", 70)))
	testing.IssueCoins(bondAddr(c.id), chain.NewCoins(chain.NewCoin("ugnot", 1000+300)))
	c.state.bond = 300
	c.state.status, c.state.closedAt = statusClosed, now()-c.params.ExitDelay
	f := bookFinalize(c)
	if !f.settled || c.state.status != statusSettled || f.toBeneficiary != 70 || f.toOrganizer != 1300 || f.released != 300 || !c.state.bondReleased {
		// ExitDelay (60 days) is past BondHold (30): the bond goes too.
		t.Errorf("first call: %v", f)
	}

	// On hold: a campaign closed now keeps its bond at the bond address.
	d := testCampaign(9509, modeDirect, 0)
	testing.IssueCoins(bondAddr(d.id), chain.NewCoins(chain.NewCoin("ugnot", 1000+300)))
	d.state.bond = 300
	d.state.status, d.state.closedAt = statusClosed, now()
	f = bookFinalize(d)
	if !f.settled || f.toOrganizer != 1000 || f.released != 0 || d.state.bondReleased {
		t.Errorf("bond on hold: %v", f)
	}
	// The coins don't move here; a later call, before the hold ends, has the same
	// 1000 to forward and still holds the bond, without settling again.
	if f = bookFinalize(d); f.settled || f.toOrganizer != 1000 || f.released != 0 {
		t.Errorf("a second call on hold: %v", f)
	}
	// A slashed bond is never released: the slash took it, and the deposit is left.
	e := testCampaign(9518, modeDirect, 0)
	testing.IssueCoins(bondAddr(e.id), chain.NewCoins(chain.NewCoin("ugnot", 1000)))
	e.state.bond, e.state.bondSlashed = 300, true
	e.state.status, e.state.closedAt = statusClosed, now()-e.params.BondHold
	if f = bookFinalize(e); f.released != 0 || e.state.bondReleased || f.toOrganizer != 1000 {
		t.Errorf("slashed: %v", f)
	}
	// Within the hold too: the slash took the bond, so the deposit goes at once.
	s := testCampaign(9530, modeDirect, 0)
	testing.IssueCoins(bondAddr(s.id), chain.NewCoins(chain.NewCoin("ugnot", 1000)))
	s.state.bond, s.state.bondSlashed = 300, true
	s.state.status, s.state.closedAt = statusClosed, now()
	if f = bookFinalize(s); !f.settled || f.released != 0 || f.toOrganizer != 1000 {
		t.Errorf("slashed, within the hold: %v", f)
	}

	// A bond address holding less than the bond on hold stops it (INV-7).
	h := testCampaign(9521, modeDirect, 0)
	testing.IssueCoins(bondAddr(h.id), chain.NewCoins(chain.NewCoin("ugnot", 200)))
	h.state.bond = 300
	h.state.status, h.state.closedAt = statusClosed, now()
	if !panicsWith(func() { bookFinalize(h) }, ErrBooksMismatch) {
		t.Errorf("a bond above the bond address's coins: not ErrBooksMismatch")
	}

	// Books above the bank stop it (INV-1).
	g := testCampaign(9510, modeEscrow, 0)
	g.state.raised = 5
	g.state.status, g.state.closedAt = statusClosed, now()-g.params.ExitDelay
	if !panicsWith(func() { bookFinalize(g) }, ErrBooksMismatch) {
		t.Errorf("books above the bank: not ErrBooksMismatch")
	}
}

func TestCanFinalize(t *testing.T) {
	open := testCampaign(9511, modeEscrow, 0)
	waiting := testCampaign(9512, modeEscrow, 0)
	fund(waiting, testutils.TestAddress("donor"), 10)
	waiting.state.status, waiting.state.closedAt = statusClosed, now()
	ready := testCampaign(9513, modeDirect, 0)
	ready.state.status, ready.state.closedAt = statusClosed, now()
	passed := testCampaign(9514, modeDirect, now()-1) // past its deadline, unrecorded
	exit := testCampaign(9522, modeEscrow, 0)
	fund(exit, testutils.TestAddress("donor"), 10)
	exit.state.status, exit.state.closedAt = statusClosed, now()-exit.params.ExitDelay // its exit window opens now
	settled := testCampaign(9515, modeDirect, 0)
	settled.state.status, settled.state.closedAt = statusSettled, now()
	stray := testCampaign(9516, modeDirect, 0)
	stray.state.status, stray.state.closedAt = statusSettled, now()
	testing.IssueCoins(escrowAddr(stray.id), chain.NewCoins(chain.NewCoin("ugnot", 3)))
	for _, k := range []struct {
		name string
		c    *campaign
		ok   bool
		why  string
	}{
		{"open", open, false, statusOpen},
		{"waiting for the exit window", waiting, false, "not_yet"},
		{"closed, direct", ready, true, "settle"},
		{"past an unrecorded deadline", passed, true, "settle"},
		{"at the exit window", exit, true, "settle"},
		{"settled, nothing to move", settled, false, statusSettled},
		{"settled, coins arrived", stray, true, "forward"},
	} {
		id, unstore := storeCampaign(k.c)
		ok, why := CanFinalize(id)
		unstore()
		if ok != k.ok || why != k.why {
			t.Errorf("%s: CanFinalize = %t, %q, want %t, %q", k.name, ok, why, k.ok, k.why)
		}
	}
}

// TestFinalize settles as anyone, straight from the test's body, and moves the coins
// bookFinalize names: the untracked to the beneficiary, the deposit to the organizer,
// the tracked balance nowhere (INV-16), which a donor still claims after (API §3.4).
func TestFinalize(cur realm, t *testing.T) {
	rb := banker.NewReadonlyBanker()
	c, donors := exitCampaign(9517, 300, 100, 200, 300)
	id, unstore := storeCampaign(c)
	defer unstore()
	testing.IssueCoins(escrowAddr(c.id), chain.NewCoins(chain.NewCoin("ugnot", 40))) // sent outside Bolo
	testing.IssueCoins(bondAddr(c.id), chain.NewCoins(chain.NewCoin("ugnot", 1000))) // the deposit
	checkBooks(t, c)
	beneficiary, organizer := rb.GetCoin(c.beneficiary, "ugnot"), rb.GetCoin(c.organizer, "ugnot")
	testing.SetRealm(testing.NewUserRealm(testutils.TestAddress("passerby")))
	Finalize(cross(cur), id)
	checkBooks(t, c)
	if got := rb.GetCoin(c.beneficiary, "ugnot") - beneficiary; got != 40 {
		t.Errorf("the beneficiary got %d, want the untracked 40", got)
	}
	if got := rb.GetCoin(c.organizer, "ugnot") - organizer; got != 1000 {
		t.Errorf("the organizer got %d, want the deposit 1000", got)
	}
	if got := rb.GetCoin(escrowAddr(c.id), "ugnot"); got != 300 || c.state.status != statusSettled {
		t.Errorf("the escrow holds %d; status %s", got, c.state.status)
	}
	// Claims still paid after settlement (INV-16).
	testing.SetRealm(testing.NewUserRealm(donors[2]))
	if got := Refund(cross(cur), id); got != 150 {
		t.Errorf("cy's exit claim after settlement = %d, want 150", got)
	}
	checkBooks(t, c)
}
