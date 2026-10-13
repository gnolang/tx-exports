package bolo

import (
	"chain"
	"chain/banker"
	"testing"

	"gno.land/p/nt/seqid/v0"
	"gno.land/p/nt/testutils/v0"
)

// checkBooks holds c's books against the bank (INV-1) and against its own records:
// the contributions add up to Raised and Refunded. Money tests run it after every
// step.
func checkBooks(t *testing.T, c *campaign) {
	s := c.state
	if trackedBalance(c) < 0 {
		t.Errorf("campaign %d: balance %d, below 0 (INV-2)", uint64(c.id), trackedBalance(c))
	}
	if bank := banker.NewReadonlyBanker().GetCoin(escrowAddr(c.id), "ugnot"); bank < trackedBalance(c) {
		t.Errorf("campaign %d: books %d, bank %d (INV-1)", uint64(c.id), trackedBalance(c), bank)
	}
	if c.mode == modeDirect && trackedBalance(c) != 0 {
		t.Errorf("campaign %d, direct: balance %d (INV-2)", uint64(c.id), trackedBalance(c))
	}
	var amount, refunded int64
	c.contributions.Iterate("", "", func(_ string, v any) bool {
		amount += v.(*contribution).amount
		refunded += v.(*contribution).refunded
		return false
	})
	if amount != s.raised || refunded != s.refunded {
		t.Errorf("campaign %d: contributions %d given, %d refunded; books %d, %d", uint64(c.id), amount, refunded, s.raised, s.refunded)
	}
}

// fund records a gift of amount by donor in c's books and issues the coins to its
// escrow, as Donate leaves them, without a crossing call.
func fund(c *campaign, donor address, amount int64) {
	k := contributionOf(c, donor)
	if k == nil {
		k = &contribution{}
		c.contributions.Set(donor.String(), k)
		c.state.donorCount++
	}
	k.amount += amount
	c.state.raised += amount
	testing.IssueCoins(escrowAddr(c.id), chain.NewCoins(chain.NewCoin("ugnot", amount)))
}

// The helpers' tests come first: a write's test that panics through a crossing call
// ends the package's unit tests.

func TestCheckWithdrawable(t *testing.T) {
	c := testCampaign(9401, modeEscrow, 0)
	checkWithdrawable(c)
	c.state.status, c.state.closedAt = statusClosed, now()-c.params.ExitDelay+1
	checkWithdrawable(c) // closed, a second before the exit window
	for name, k := range map[string]struct {
		mode, status string
		closedAt     int64
		err          Error
	}{
		"direct":               {modeDirect, statusOpen, 0, ErrWrongMode},
		"direct, and settled":  {modeDirect, statusSettled, 0, ErrWrongMode},
		"settled":              {modeEscrow, statusSettled, 0, ErrCampaignSettled},
		"exit window open":     {modeEscrow, statusClosed, now() - c.params.ExitDelay, ErrExitOpen},
		"long past the window": {modeEscrow, statusClosed, 1, ErrExitOpen},
	} {
		c.mode, c.state.status, c.state.closedAt = k.mode, k.status, k.closedAt
		if !panicsWith(func() { checkWithdrawable(c) }, k.err) {
			t.Errorf("%s: not %s", name, k.err)
		}
	}
}

func TestCheckRefund(t *testing.T) {
	donor, stranger := testutils.TestAddress("donor"), testutils.TestAddress("stranger")
	c := testCampaign(9402, modeEscrow, 0)
	c.contributions.Set(donor.String(), &contribution{amount: 700, refunded: 200})
	k, window, amount := checkRefund(c, donor)
	if k.amount != 700 || window != windowOpen || amount != 500 {
		t.Errorf("checkRefund = %v, %q, %d", *k, window, amount)
	}
	if !panicsWith(func() { checkRefund(c, stranger) }, ErrNothingToRefund) {
		t.Errorf("a stranger: not ErrNothingToRefund")
	}
	c.state.everWithdrawn = true
	if !panicsWith(func() { checkRefund(c, donor) }, ErrRefundWindowClosed) {
		t.Errorf("after a withdrawal: not ErrRefundWindowClosed")
	}
	k.refunded = k.amount
	if !panicsWith(func() { checkRefund(c, donor) }, ErrNothingToRefund) {
		t.Errorf("all refunded, window closed: not ErrNothingToRefund")
	}
	c.mode = modeDirect
	if !panicsWith(func() { checkRefund(c, donor) }, ErrWrongMode) {
		t.Errorf("direct, nothing left: not ErrWrongMode")
	}
}

// TestAssertBooks corrupts the books on purpose (INV-1): books above the bank stop
// every payout, before anything is written.
func TestAssertBooks(t *testing.T) {
	donor := testutils.TestAddress("donor")
	c := testCampaign(9403, modeEscrow, 0)
	fund(c, donor, 1000)
	assertBooks(c)
	c.state.raised += 1 // the books now claim a coin the escrow doesn't hold
	if !panicsWith(func() { assertBooks(c) }, ErrBooksMismatch) {
		t.Fatalf("books above the bank: not ErrBooksMismatch")
	}
	for name, f := range map[string]func(){
		"a withdrawal": func() { bookWithdrawal(c) },
		"a refund":     func() { bookRefund(c, donor) },
	} {
		if !panicsWith(f, ErrBooksMismatch) {
			t.Errorf("%s on books above the bank: not ErrBooksMismatch", name)
		}
	}
	if c.state.withdrawn != 0 || c.state.refunded != 0 || c.withdrawals.Size() != 0 || c.refunds.Size() != 0 {
		t.Errorf("a refused payout wrote the books")
	}
}

func TestBookWithdrawal(t *testing.T) {
	donor := testutils.TestAddress("donor")
	c := testCampaign(9404, modeEscrow, 0)
	if !panicsWith(func() { bookWithdrawal(c) }, ErrNothingToWithdraw) {
		t.Errorf("an empty escrow: not ErrNothingToWithdraw")
	}

	// Untracked coins alone: withdrawn as untracked, and the open window stays open.
	testing.IssueCoins(escrowAddr(c.id), chain.NewCoins(chain.NewCoin("ugnot", 300)))
	w := bookWithdrawal(c)
	checkBooks(t, c)
	if w.amount != 0 || w.untracked != 300 || w.seq != 1 || c.state.everWithdrawn || c.state.withdrawn != 0 {
		t.Errorf("untracked only: %v; everWithdrawn %t", *w, c.state.everWithdrawn)
	}
	// Tracked and untracked: Withdrawn grows by the tracked part only (INV-2). The
	// books moved no coin, so the 300 are still there.
	fund(c, donor, 1000)
	w = bookWithdrawal(c)
	checkBooks(t, c)
	if w.amount != 1000 || w.untracked != 300 || !c.state.everWithdrawn || c.state.withdrawn != 1000 || trackedBalance(c) != 0 {
		t.Errorf("tracked and untracked: %v; withdrawn %d", *w, c.state.withdrawn)
	}
	if got := c.withdrawals.Get(seqid.ID(2).Binary()).(*withdrawal); got != w || w.to != c.beneficiary || w.at != now() {
		t.Errorf("stored record %v", *got)
	}
}

func TestBookRefund(t *testing.T) {
	ada, bo := testutils.TestAddress("ada"), testutils.TestAddress("bo")
	c := testCampaign(9405, modeEscrow, 0)
	fund(c, ada, 2000)
	fund(c, bo, 1000)
	fund(c, c.organizer, 500) // a record a misdirected refund could pay from
	r := bookRefund(c, ada)
	checkBooks(t, c)
	if r.amount != 2000 || r.donor != ada || r.kind != windowOpen || r.seq != 1 {
		t.Errorf("refund %v", *r)
	}
	if k := contributionOf(c, ada); k.refunded != 2000 || c.state.refunded != 2000 || c.state.refundCount != 1 {
		t.Errorf("after a refund: contribution %v, refunded %d", *k, c.state.refunded)
	}
	// It pays only from the caller's own record: bo's is untouched (INV-13).
	if k := contributionOf(c, bo); k.refunded != 0 {
		t.Errorf("bo's record changed: %v", *k)
	}
	if !panicsWith(func() { bookRefund(c, ada) }, ErrNothingToRefund) {
		t.Errorf("a second refund: not ErrNothingToRefund")
	}
}

func TestGetContribution(t *testing.T) {
	donor := testutils.TestAddress("donor")
	c := testCampaign(9406, modeEscrow, 0)
	id, unstore := storeCampaign(c)
	defer unstore()
	if v := GetContribution(id, testutils.TestAddress("stranger")); v != (ContributionView{}) {
		t.Errorf("a stranger: %v", v)
	}
	c.contributions.Set(donor.String(), &contribution{amount: 700, refunded: 200, public: true})
	if v := GetContribution(id, donor); v != (ContributionView{Amount: 700, Refunded: 200, RefundableNow: 500, Window: windowOpen}) {
		t.Errorf("open window: %v", v)
	}
	c.state.everWithdrawn = true
	if v := GetContribution(id, donor); v.Window != "" || v.RefundableNow != 0 || v.Amount != 700 {
		t.Errorf("after a withdrawal: %v", v)
	}
	if !panicsWith(func() { GetContribution("042", donor) }, ErrNotFound) {
		t.Errorf("GetContribution(\"042\"): not ErrNotFound")
	}
}

// TestWithdraw withdraws as the beneficiary, straight from the test's body as
// AssertOriginCall requires (plan §3.3), the books held against the bank after every
// step. Its refusals are unit-tested above and in txtar (money_out.txtar).
func TestWithdraw(cur realm, t *testing.T) {
	defer func(cap int64) { escrowCap = cap }(escrowCap)
	rb := banker.NewReadonlyBanker()
	donor := testutils.TestAddress("donor")
	c := testCampaign(9407, modeEscrow, 0)
	id, unstore := storeCampaign(c)
	defer unstore()
	other := testCampaign(9408, modeEscrow, 0)
	idOther, unstoreOther := storeCampaign(other)
	defer unstoreOther()
	fund(c, donor, 3000)
	fund(other, donor, 500)
	testing.IssueCoins(escrowAddr(c.id), chain.NewCoins(chain.NewCoin("ugnot", 40))) // outside Bolo
	checkBooks(t, c)

	// Everything goes to the beneficiary: the tracked 3000 counted as Withdrawn,
	// the 40 recorded apart. The other campaign's escrow isn't touched.
	before, otherBefore := rb.GetCoin(c.beneficiary, "ugnot"), rb.GetCoin(escrowAddr(other.id), "ugnot")
	testing.SetRealm(testing.NewUserRealm(c.beneficiary))
	if got := Withdraw(cross(cur), id); got != 3040 {
		t.Errorf("Withdraw = %d, want 3040", got)
	}
	checkBooks(t, c)
	if got := rb.GetCoin(c.beneficiary, "ugnot") - before; got != 3040 || rb.GetCoin(escrowAddr(c.id), "ugnot") != 0 {
		t.Errorf("the beneficiary got %d; the escrow holds %d", got, rb.GetCoin(escrowAddr(c.id), "ugnot"))
	}
	if v := GetCampaign(id); v.Withdrawn != 3000 || v.Balance != 0 || !v.EverWithdrawn {
		t.Errorf("after the withdrawal: withdrawn %d, balance %d", v.Withdrawn, v.Balance)
	}
	if rb.GetCoin(escrowAddr(other.id), "ugnot") != otherBefore || GetCampaign(idOther).Balance != 500 {
		t.Errorf("a withdrawal touched another campaign")
	}

	// A withdrawal makes room under the cap.
	escrowCap = 3000
	checkRoom(c, 3000)

	// Closing traps nothing: closed, before the exit window, the beneficiary
	// still withdraws.
	fund(c, donor, 700)
	c.state.status, c.state.closedAt = statusClosed, now()
	if got := Withdraw(cross(cur), id); got != 700 {
		t.Errorf("Withdraw from a closed campaign = %d, want 700", got)
	}
	checkBooks(t, c)
}

// TestRefund refunds as a donor in the open window, the books held against the bank
// after every step: the caller is paid from their own record, and their receipts show
// it (INV-12, INV-13).
func TestRefund(cur realm, t *testing.T) {
	rb := banker.NewReadonlyBanker()
	ada, bo := testutils.TestAddress("ada"), testutils.TestAddress("bo")
	c := testCampaign(9409, modeEscrow, 0)
	id, unstore := storeCampaign(c)
	defer unstore()
	testing.SetRealm(testing.NewUserRealm(ada))
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin("ugnot", 2_000_000)))
	testing.IssueCoins(realmAddr(), chain.NewCoins(chain.NewCoin("ugnot", 2_000_000)))
	Donate(cross(cur), id, 0, "", false)
	defer byDonor.Remove(ada.String() + "/" + c.id.Binary())
	fund(c, bo, 1_000_000)
	checkBooks(t, c)

	before := rb.GetCoin(ada, "ugnot")
	if got := Refund(cross(cur), id); got != 2_000_000 {
		t.Errorf("Refund = %d, want 2000000", got)
	}
	checkBooks(t, c)
	if got := rb.GetCoin(ada, "ugnot") - before; got != 2_000_000 {
		t.Errorf("ada got %d back", got)
	}
	if r := GetReceipt(id, 1); r.DonorRefunded != 2_000_000 {
		t.Errorf("ada's receipt: DonorRefunded %d", r.DonorRefunded)
	}
	if v := GetCampaign(id); v.Refunded != 2_000_000 || v.RefundCount != 1 || v.Balance != 1_000_000 || v.NetRaised != 1_000_000 {
		t.Errorf("after the refund: %v", v)
	}
	if v := GetContribution(id, bo); v.RefundableNow != 1_000_000 || v.Window != windowOpen {
		t.Errorf("bo's record: %v", v)
	}

	// Given again after a refund, ada is paid what is left of her record, never all
	// of it: the escrow holds enough that paying more would go through (INV-13).
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin("ugnot", 1_000_000)))
	testing.IssueCoins(realmAddr(), chain.NewCoins(chain.NewCoin("ugnot", 1_000_000)))
	Donate(cross(cur), id, 0, "", false)
	fund(c, bo, 2_000_000)
	checkBooks(t, c)
	before = rb.GetCoin(ada, "ugnot")
	if got := Refund(cross(cur), id); got != 1_000_000 {
		t.Errorf("a second Refund = %d, want 1000000", got)
	}
	checkBooks(t, c)
	if got := rb.GetCoin(ada, "ugnot") - before; got != 1_000_000 {
		t.Errorf("ada got %d back the second time, want 1000000", got)
	}
}
