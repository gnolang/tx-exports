package bolo

import (
	"chain"
	"chain/banker"
	"strings"
	"testing"

	"gno.land/p/nt/seqid/v0"
	"gno.land/p/nt/testutils/v0"
)

// The helpers' tests come first: a write's test that panics through a crossing call
// ends the package's unit tests.

// TestBookSlash: a slash takes the bond and only the bond, once, while the campaign
// is open or within BondHold of its close, settled or not (API §3.5, INV-7).
func TestBookSlash(t *testing.T) {
	c := testCampaign(9801, modeDirect, 0)
	if !panicsWith(func() { bookSlash(c) }, ErrNoBond) {
		t.Errorf("no bond: not ErrNoBond")
	}
	testing.IssueCoins(bondAddr(c.id), chain.NewCoins(chain.NewCoin("ugnot", 1000+300))) // the deposit, the bond
	c.state.bond = 300
	if got := bookSlash(c); got != 300 || !c.state.bondSlashed {
		t.Errorf("open: slashed %d, flagged %t; want the bond, 300", got, c.state.bondSlashed)
	}
	if !panicsWith(func() { bookSlash(c) }, ErrBondSlashed) {
		t.Errorf("a second slash: not ErrBondSlashed")
	}

	for i, status := range []string{statusClosed, statusSettled} {
		d := testCampaign(seqid.ID(9802+i), modeDirect, 0)
		testing.IssueCoins(bondAddr(d.id), chain.NewCoins(chain.NewCoin("ugnot", 300)))
		d.state.bond, d.state.status, d.state.closedAt = 300, status, now()-d.params.BondHold
		if !panicsWith(func() { bookSlash(d) }, ErrHoldEnded) {
			t.Errorf("%s, the hold just ended: not ErrHoldEnded", status)
		}
		d.state.closedAt++
		if got := bookSlash(d); got != 300 {
			t.Errorf("%s, a second before the hold ends: slashed %d", status, got)
		}
	}

	e := testCampaign(9804, modeDirect, 0)
	testing.IssueCoins(bondAddr(e.id), chain.NewCoins(chain.NewCoin("ugnot", 200)))
	e.state.bond = 300
	if !panicsWith(func() { bookSlash(e) }, ErrBooksMismatch) {
		t.Errorf("a bond address holding less than the bond: not ErrBooksMismatch")
	}
	if e.state.bondSlashed {
		t.Errorf("a refused slash marked the bond slashed")
	}
}

// TestCheckNotice: "" clears, except on a delisted campaign; any other notice is
// normalized and holds 1–280 characters (API §2.3, §3.5).
func TestCheckNotice(t *testing.T) {
	c := testCampaign(9805, modeEscrow, 0)
	if got := checkNotice(c, ""); got != "" {
		t.Errorf(`"" on a listed campaign: %q`, got)
	}
	if got := checkNotice(c, "  Unverified\tclaims "); got != "Unverified claims" {
		t.Errorf("normalized: %q", got)
	}
	for name, notice := range map[string]string{
		"blank":    " \t ",
		"too long": strings.Repeat("a", noticeMax+1),
	} {
		if !panicsWith(func() { checkNotice(c, notice) }, ErrNotice) {
			t.Errorf("%s: not ErrNotice", name)
		}
	}
	c.state.listed = false
	if !panicsWith(func() { checkNotice(c, "") }, ErrNotice) {
		t.Errorf(`"" on a delisted campaign: not ErrNotice`)
	}
	if got := checkNotice(c, "Fraud reported"); got != "Fraud reported" {
		t.Errorf("a delisted campaign's new notice: %q", got)
	}
}

// TestDelist delists as the admin, straight from the test's body: off the active
// indexes, with the notice; then again, which replaces the notice and slashes, moving
// the bond and only the bond to the slashed address (API §3.5, INV-7).
func TestDelist(cur realm, t *testing.T) {
	rb := banker.NewReadonlyBanker()
	c := testCampaign(9806, modeEscrow, 0)
	id, unstore := storeCampaign(c)
	defer unstore()
	testing.IssueCoins(bondAddr(c.id), chain.NewCoins(chain.NewCoin("ugnot", 1000+300)))
	c.state.bond = 300
	slashed, key := rb.GetCoin(slashedAddr(), "ugnot"), c.id.Binary()

	testing.SetRealm(testing.NewUserRealm(admin))
	Delist(cross(cur), id, " Under review ", false)
	if s := c.state; s.listed || s.notice != "Under review" || s.bondSlashed || active.Has(key) || activeByCategory.Has(c.category+"/"+key) {
		t.Errorf("delisted: listed %t, notice %q, slashed %t, active %t", s.listed, s.notice, s.bondSlashed, active.Has(key))
	}
	Delist(cross(cur), id, "Fraud reported", true)
	if s := c.state; s.notice != "Fraud reported" || !s.bondSlashed {
		t.Errorf("delisted again: notice %q, slashed %t", s.notice, s.bondSlashed)
	}
	if got := rb.GetCoin(slashedAddr(), "ugnot") - slashed; got != 300 {
		t.Errorf("the slashed address got %d, want the bond, 300", got)
	}
	if got := rb.GetCoin(bondAddr(c.id), "ugnot"); got != 1000 {
		t.Errorf("the bond address holds %d, want the deposit, 1000", got)
	}
}

// TestRelist: back on the lists, and in the active indexes only while still open; the
// notice stays (API §3.5).
func TestRelist(cur realm, t *testing.T) {
	open := testCampaign(9807, modeEscrow, 0)
	closed := testCampaign(9808, modeEscrow, 0)
	closed.state.status, closed.state.closedAt = statusClosed, now()
	testing.SetRealm(testing.NewUserRealm(admin))
	for _, c := range []*campaign{open, closed} {
		id, unstore := storeCampaign(c)
		Delist(cross(cur), id, "Under review", false)
		Relist(cross(cur), id)
		key := c.id.Binary()
		if !c.state.listed || c.state.notice != "Under review" || active.Has(key) != (c == open) || activeByCategory.Has(c.category+"/"+key) != (c == open) {
			t.Errorf("%s, relisted: listed %t, notice %q, active %t", c.state.status, c.state.listed, c.state.notice, active.Has(key))
		}
		unstore()
	}
}

// TestSetNotice: a notice without delisting, normalized, then cleared (API §3.5).
func TestSetNotice(cur realm, t *testing.T) {
	c := testCampaign(9809, modeEscrow, 0)
	id, unstore := storeCampaign(c)
	defer unstore()
	testing.SetRealm(testing.NewUserRealm(admin))
	SetNotice(cross(cur), id, " Unverified\tclaims ")
	if c.state.notice != "Unverified claims" || !c.state.listed || !active.Has(c.id.Binary()) {
		t.Errorf("noticed: %q, listed %t", c.state.notice, c.state.listed)
	}
	SetNotice(cross(cur), id, "")
	if c.state.notice != "" {
		t.Errorf("cleared: %q", c.state.notice)
	}
}

// TestHideMessage: the view blanks the message and keeps the receipt — its donor, its
// amount; the stored text stays (API §3.5).
func TestHideMessage(cur realm, t *testing.T) {
	c := testCampaign(9810, modeEscrow, 0)
	id, unstore := storeCampaign(c)
	defer unstore()
	donor := testutils.TestAddress("donor")
	c.receipts.Set(seqid.ID(1).Binary(), &receipt{seq: 1, donor: donor, amount: 500, message: "Courage"})
	testing.SetRealm(testing.NewUserRealm(admin))
	HideMessage(cross(cur), id, 1)
	if v := GetReceipt(id, 1); v.Message != "" || !v.MessageHidden || v.Amount != 500 || v.Donor != donor {
		t.Errorf("hidden: %v", v)
	}
	if r := receiptOf(c, 1); r.message != "Courage" {
		t.Errorf("the stored text: %q", r.message)
	}
}
