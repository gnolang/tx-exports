package bolo

import (
	"chain"
	"chain/banker"
	"math"
	"testing"

	"gno.land/p/nt/seqid/v0"
	"gno.land/p/nt/testutils/v0"
)

// The helpers' tests come first: a write's test that panics through a crossing
// call stops the package's run, so a test after it would never report.

func TestCheckGift(t *testing.T) {
	defer func(p bool, m int64) { paused, minDonation = p, m }(paused, minDonation)
	minDonation = 1000
	c := testCampaign(9303, modeEscrow, 0)
	if got := checkGift(c, 1500, 500); got != 1000 {
		t.Errorf("checkGift(1500, 500) = %d, want 1000", got)
	}
	for name, k := range map[string]struct {
		status     string
		paused     bool
		total, tip int64
		err        Error
	}{
		"a negative tip":           {statusOpen, false, 1500, -1, ErrBadAmount},
		"all tip":                  {statusOpen, false, 1500, 1500, ErrBadAmount},
		"a tip above the envelope": {statusOpen, false, 1500, 1501, ErrBadAmount},
		"nothing sent":             {statusOpen, false, 0, 0, ErrBadAmount},
		"under the minimum":        {statusOpen, false, 1499, 500, ErrBadAmount},
		"closed":                   {statusClosed, false, 1500, 0, ErrCampaignClosed},
		"settled":                  {statusSettled, false, 1500, 0, ErrCampaignSettled},
		"paused":                   {statusOpen, true, 1500, 0, ErrPaused},
		"closed, and paused":       {statusClosed, true, 1500, 0, ErrCampaignClosed},
		"nothing left, and closed": {statusClosed, false, 500, 500, ErrBadAmount},
		"paused, and under":        {statusOpen, true, 10, 0, ErrPaused},
	} {
		c.state.status, paused = k.status, k.paused
		if !panicsWith(func() { checkGift(c, k.total, k.tip) }, k.err) {
			t.Errorf("%s: not %s", name, k.err)
		}
	}
}

func TestCheckRoom(t *testing.T) {
	defer func(cap int64) { escrowCap = cap }(escrowCap)
	escrowCap = 1000
	c := testCampaign(9304, modeEscrow, 0)
	c.state.raised, c.state.withdrawn = 900, 300 // tracked: 600
	checkRoom(c, 400)
	if !panicsWith(func() { checkRoom(c, 401) }, ErrCapReached) {
		t.Errorf("a gift past the cap: not ErrCapReached")
	}
	// The cap reads the tracked balance, never the bank's: coins sent straight to
	// the escrow don't block a gift.
	testing.IssueCoins(escrowAddr(c.id), chain.NewCoins(chain.NewCoin("ugnot", 5000)))
	checkRoom(c, 400)
	// No cap, and direct mode, take any gift the books can hold.
	escrowCap = 0
	checkRoom(c, 1_000_000)
	escrowCap = 1000
	d := testCampaign(9305, modeDirect, 0)
	checkRoom(d, 1_000_000)
	d.state.raised = math.MaxInt64 - 5
	checkRoom(d, 5)
	if !panicsWith(func() { checkRoom(d, 6) }, ErrBadAmount) {
		t.Errorf("Raised past int64: not ErrBadAmount")
	}
}

// TestDonate gives as a user, straight from the test's body as AssertOriginCall
// requires (plan §3.3), with the envelope and the realm's coins a real transaction
// would bring. Its refusals are in txtar (give.txtar) and filetests.
func TestDonate(cur realm, t *testing.T) {
	donor := testutils.TestAddress("donor")
	rb := banker.NewReadonlyBanker()
	c := testCampaign(9301, modeEscrow, 0)
	id, unstore := storeCampaign(c)
	defer unstore()
	// A tip recipient other than the admin, which it starts as: a tip must go to
	// whoever SetTipRecipient named, never to the launch admin.
	launch := tipRecipient
	tipRecipient = testutils.TestAddress("tips")
	defer func() { tipRecipient = launch }()
	escrowBefore, tipsBefore, realmBefore := rb.GetCoin(escrowAddr(c.id), "ugnot"), rb.GetCoin(tipRecipient, "ugnot"), rb.GetCoin(realmAddr(), "ugnot")

	// A public gift with a tip: the gift to the escrow, the tip to the tip
	// recipient, nothing kept by the realm (INV-3).
	testing.SetRealm(testing.NewUserRealm(donor))
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin("ugnot", 2_500_000)))
	testing.IssueCoins(realmAddr(), chain.NewCoins(chain.NewCoin("ugnot", 2_500_000)))
	if rid := Donate(cross(cur), id, 500_000, "  Courage! ", false); rid != "9301/1" {
		t.Fatalf("Donate returned %q, want 9301/1", rid)
	}
	checkBooks(t, c)
	if got := rb.GetCoin(escrowAddr(c.id), "ugnot") - escrowBefore; got != 2_000_000 {
		t.Errorf("the escrow got %d, want 2000000", got)
	}
	if got := rb.GetCoin(tipRecipient, "ugnot") - tipsBefore; got != 500_000 {
		t.Errorf("the tip recipient got %d, want 500000", got)
	}
	if got := rb.GetCoin(realmAddr(), "ugnot"); got != realmBefore {
		t.Errorf("the realm holds %d, it held %d", got, realmBefore)
	}
	s := c.state
	if s.raised != 2_000_000 || s.donationCount != 1 || s.donorCount != 1 || s.lastDonationAt != now() {
		t.Errorf("after one gift: raised %d, %d gifts, %d donors, last %d", s.raised, s.donationCount, s.donorCount, s.lastDonationAt)
	}
	k := c.contributions.Get(donor.String()).(*contribution)
	if k.amount != 2_000_000 || !k.public || !byDonor.Has(donor.String()+"/"+c.id.Binary()) {
		t.Errorf("contribution %v; by-donor entry %t", *k, byDonor.Has(donor.String()+"/"+c.id.Binary()))
	}
	defer byDonor.Remove(donor.String() + "/" + c.id.Binary())
	r := c.receipts.Get(seqid.ID(1).Binary()).(*receipt)
	want := receipt{seq: 1, donor: donor, amount: 2_000_000, tip: 500_000, message: "Courage!", at: now(), raisedAfter: 2_000_000}
	if *r != want {
		t.Errorf("receipt = %v, want %v", *r, want)
	}

	// The same donor again, anonymously and with no tip: one donor still, the
	// contribution summed, nothing sent to the tip recipient (Q2).
	tipsBefore = rb.GetCoin(tipRecipient, "ugnot")
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin("ugnot", 1_000_000)))
	testing.IssueCoins(realmAddr(), chain.NewCoins(chain.NewCoin("ugnot", 1_000_000)))
	Donate(cross(cur), id, 0, "", true)
	checkBooks(t, c)
	if s.donorCount != 1 || s.donationCount != 2 || k.amount != 3_000_000 || !k.public {
		t.Errorf("a second gift: %d donors, %d gifts, contribution %v", s.donorCount, s.donationCount, *k)
	}
	if got := rb.GetCoin(tipRecipient, "ugnot"); got != tipsBefore {
		t.Errorf("a gift with no tip sent %d to the tip recipient", got-tipsBefore)
	}
	if v := campaignView(c); v.Balance != 3_000_000 || v.Raised != 3_000_000 {
		t.Errorf("balance %d, raised %d, want 3000000 each (INV-2)", v.Balance, v.Raised)
	}

	// An anonymous first gift adds no by-donor entry.
	shy := testutils.TestAddress("shy")
	testing.SetRealm(testing.NewUserRealm(shy))
	testing.IssueCoins(realmAddr(), chain.NewCoins(chain.NewCoin("ugnot", 1_000_000)))
	Donate(cross(cur), id, 0, "", true)
	checkBooks(t, c)
	if s.donorCount != 2 || byDonor.Has(shy.String()+"/"+c.id.Binary()) || c.contributions.Get(shy.String()).(*contribution).public {
		t.Errorf("an anonymous donor: %d donors, by-donor entry %t", s.donorCount, byDonor.Has(shy.String()+"/"+c.id.Binary()))
	}

	// The same donor, publicly this time: in the by-donor index now, and still
	// counted once.
	testing.IssueCoins(realmAddr(), chain.NewCoins(chain.NewCoin("ugnot", 1_000_000)))
	Donate(cross(cur), id, 0, "", false)
	checkBooks(t, c)
	defer byDonor.Remove(shy.String() + "/" + c.id.Binary())
	if s.donorCount != 2 || !byDonor.Has(shy.String()+"/"+c.id.Binary()) || !c.contributions.Get(shy.String()).(*contribution).public {
		t.Errorf("anonymous, then public: %d donors, by-donor entry %t", s.donorCount, byDonor.Has(shy.String()+"/"+c.id.Binary()))
	}
}

// TestDonateDirect: a direct gift goes to the beneficiary, and the campaign's
// balance stays 0 (INV-2). A delisted campaign takes gifts, and so does one in a
// sunset version.
func TestDonateDirect(cur realm, t *testing.T) {
	defer func(s bool) { sunset = s }(sunset)
	rb := banker.NewReadonlyBanker()
	c := testCampaign(9302, modeDirect, 0)
	c.state.listed = false
	id, unstore := storeCampaign(c)
	defer unstore()
	sunset = true
	before := rb.GetCoin(c.beneficiary, "ugnot")
	testing.SetRealm(testing.NewUserRealm(testutils.TestAddress("donor")))
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin("ugnot", 1_500_000)))
	testing.IssueCoins(realmAddr(), chain.NewCoins(chain.NewCoin("ugnot", 1_500_000)))
	Donate(cross(cur), id, 0, "", true)
	checkBooks(t, c)
	if got := rb.GetCoin(c.beneficiary, "ugnot") - before; got != 1_500_000 {
		t.Errorf("the beneficiary got %d, want 1500000", got)
	}
	if v := campaignView(c); v.Balance != 0 || v.Raised != 1_500_000 || v.NetRaised != 1_500_000 {
		t.Errorf("direct: balance %d, raised %d", v.Balance, v.Raised)
	}
}

func TestReceipts(cur realm, t *testing.T) {
	c := testCampaign(9306, modeEscrow, 0)
	id, unstore := storeCampaign(c)
	defer unstore()
	donors := []address{testutils.TestAddress("ada"), testutils.TestAddress("bo")}
	for i := 0; i < 25; i++ {
		testing.SetRealm(testing.NewUserRealm(donors[i%2]))
		testing.SetOriginSend(chain.NewCoins(chain.NewCoin("ugnot", int64(1_000_000+i))))
		testing.IssueCoins(realmAddr(), chain.NewCoins(chain.NewCoin("ugnot", int64(1_000_000+i))))
		Donate(cross(cur), id, 0, "gift", i%2 == 1)
	}
	defer byDonor.Remove(donors[0].String() + "/" + c.id.Binary())

	// The ring holds the last 20, newest first.
	recent := ListRecent(id)
	if len(recent) != recentSize || recent[0].Seq != 25 || recent[recentSize-1].Seq != 6 {
		t.Fatalf("ListRecent: %d receipts, %d first, %d last", len(recent), recent[0].Seq, recent[len(recent)-1].Seq)
	}
	for i, r := range recent {
		if want := GetReceipt(id, r.Seq); r != want || r.Seq != int64(25-i) {
			t.Errorf("recent[%d] = %v, GetReceipt says %v", i, r, want)
		}
	}

	// Anonymous gifts hide their donor; a hidden message is blanked; a refund shows.
	public, anon := GetReceipt(id, 1), GetReceipt(id, 2)
	if public.Donor != donors[0] || anon.Donor != "" || !anon.Anonymous || public.ID != id+"/1" || public.CampaignID != id {
		t.Errorf("public %v, anonymous %v", public, anon)
	}
	c.receipts.Get(seqid.ID(1).Binary()).(*receipt).messageHidden = true
	c.contributions.Get(donors[0].String()).(*contribution).refunded = 7
	if r := GetReceipt(id, 1); r.Message != "" || !r.MessageHidden || r.DonorRefunded != 7 || r.Amount != 1_000_000 {
		t.Errorf("hidden and refunded: %v", r)
	}
	for _, seq := range []int64{0, -1, 26, math.MaxInt64} {
		if !panicsWith(func() { GetReceipt(id, seq) }, ErrNotFound) {
			t.Errorf("GetReceipt(%d): not ErrNotFound", seq)
		}
	}
	if !panicsWith(func() { ListRecent("042") }, ErrNotFound) {
		t.Errorf("ListRecent(\"042\"): not ErrNotFound")
	}
	empty, unstoreEmpty := storeCampaign(testCampaign(9307, modeEscrow, 0))
	defer unstoreEmpty()
	if got := ListRecent(empty); len(got) != 0 {
		t.Errorf("a campaign without gifts lists %d", len(got))
	}
}

// TestSweepStrays: what sits at the realm goes to the tip recipient; then there is
// nothing to sweep, and nothing is sent (Q3).
func TestSweepStrays(cur realm, t *testing.T) {
	rb := banker.NewReadonlyBanker()
	SweepStrays(cross(cur)) // whatever earlier tests left
	launch := tipRecipient
	tipRecipient = testutils.TestAddress("tips")
	defer func() { tipRecipient = launch }()
	testing.IssueCoins(realmAddr(), chain.NewCoins(chain.NewCoin("ugnot", 123)))
	before := rb.GetCoin(tipRecipient, "ugnot")
	if got := SweepStrays(cross(cur)); got != 123 {
		t.Errorf("SweepStrays = %d, want 123", got)
	}
	if got := rb.GetCoin(tipRecipient, "ugnot") - before; got != 123 || rb.GetCoin(realmAddr(), "ugnot") != 0 {
		t.Errorf("the tip recipient got %d; the realm holds %d", got, rb.GetCoin(realmAddr(), "ugnot"))
	}
	if got := SweepStrays(cross(cur)); got != 0 {
		t.Errorf("SweepStrays with nothing there = %d", got)
	}
}
