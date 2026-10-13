package bolo

import (
	"chain"
	"testing"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/seqid/v0"
	"gno.land/p/nt/testutils/v0"
)

// testCampaign builds a campaign in memory, stored nowhere: views and the deadline
// helper read only what they are given.
func testCampaign(id seqid.ID, mode string, deadline int64) *campaign {
	return &campaign{
		id: id, category: "water", mode: mode, deadline: deadline, createdAt: now(),
		organizer: testutils.TestAddress("organizer"), beneficiary: testutils.TestAddress("beneficiary"),
		params:        Params{1_000_000, 90 * secondsPerDay, 60 * secondsPerDay, 30 * secondsPerDay},
		text:          &campaignText{title: "Clean water"},
		state:         &campaignState{status: statusOpen, listed: true},
		contributions: avl.NewTree(), receipts: avl.NewTree(), withdrawals: avl.NewTree(),
		refunds: avl.NewTree(), updates: avl.NewTree(),
	}
}

const heightsPerDay = 17280 // five seconds a height (spike S10)

func TestRecordDeadline(cur realm, t *testing.T) {
	c := testCampaign(9001, modeEscrow, now()+secondsPerDay)
	key := c.id.Binary()
	active.Set(key, true)
	activeByCategory.Set("water/"+key, true)
	defer dropActive(c)

	recordDeadline(cur, c)
	if c.state.status != statusOpen || !active.Has(key) {
		t.Fatalf("closed before its deadline")
	}
	testing.SkipHeights(2 * heightsPerDay)
	recordDeadline(cur, c)
	s := c.state
	if s.status != statusClosed || s.closedAt != c.deadline || s.closeReason != reasonDeadline {
		t.Errorf("after the deadline: %s at %d (%s), want closed at the deadline %d", s.status, s.closedAt, s.closeReason, c.deadline)
	}
	if active.Has(key) || activeByCategory.Has("water/"+key) {
		t.Errorf("a closed campaign is still in the active indexes")
	}
	// A second call changes nothing.
	s.closeReason = reasonOrganizer
	recordDeadline(cur, c)
	if s.closeReason != reasonOrganizer {
		t.Errorf("recordDeadline rewrote a closed campaign")
	}
}

func TestCampaignView(t *testing.T) {
	// Live Params unlike every test campaign's snapshot: a view reading them would
	// show it (INV-5).
	defer func(p Params) { params = p }(params)
	params = Params{CreationDeposit: 7, DormancyPeriod: 1, ExitDelay: 2, BondHold: 3}

	// Open, no deadline: only dormancy has a time.
	c := testCampaign(9002, modeEscrow, 0)
	c.state.lastDonationAt = now() + 5
	v := campaignView(c)
	if v.Status != statusOpen || v.ClosableByAnyoneAt != now()+5+c.params.DormancyPeriod ||
		v.FinalizableAt != 0 || v.ExitOpensAt != 0 || v.BondReleasableAt != 0 || v.ExitOpen {
		t.Errorf("open, no deadline: %v", v)
	}

	// Open with a deadline: finalizable at the deadline while nothing is tracked,
	// once the exit opens when something is.
	d := testCampaign(9003, modeEscrow, now()+10*secondsPerDay)
	if v := campaignView(d); v.FinalizableAt != d.deadline {
		t.Errorf("open, nothing tracked: FinalizableAt = %d, want %d", v.FinalizableAt, d.deadline)
	}
	d.state.raised = 500
	if v := campaignView(d); v.Balance != 500 || v.NetRaised != 500 || v.FinalizableAt != d.deadline+d.params.ExitDelay {
		t.Errorf("open, 500 tracked: %v", v)
	}

	// Past the deadline: closed at it, without a write.
	testing.SkipHeights(11 * heightsPerDay)
	v = campaignView(d)
	if v.Status != statusClosed || v.CloseReason != reasonDeadline || v.ClosedAt != d.deadline {
		t.Errorf("past the deadline: %s, %s, %d", v.Status, v.CloseReason, v.ClosedAt)
	}
	if d.state.status != statusOpen {
		t.Errorf("a view wrote the close")
	}
	if v.ClosableByAnyoneAt != 0 || v.BondReleasableAt != d.deadline+d.params.BondHold ||
		v.ExitOpensAt != d.deadline+d.params.ExitDelay || v.FinalizableAt != v.ExitOpensAt || v.ExitOpen {
		t.Errorf("closed, never withdrawn: %v", v)
	}

	// The exit window opens only after a withdrawal, once its delay has passed.
	d.state.everWithdrawn = true
	if campaignView(d).ExitOpen {
		t.Errorf("exit open before its delay")
	}
	testing.SkipHeights(61 * heightsPerDay)
	if !campaignView(d).ExitOpen {
		t.Errorf("exit not open after its delay")
	}
	d.state.everWithdrawn = false
	if campaignView(d).ExitOpen {
		t.Errorf("exit open after its delay without any withdrawal")
	}
	// Nor once everything tracked was withdrawn: there is nothing to reclaim.
	d.state.everWithdrawn, d.state.withdrawn = true, d.state.raised
	if campaignView(d).ExitOpen {
		t.Errorf("exit open on an emptied escrow")
	}

	// Direct mode: nothing tracked, no exit, finalizable at the close.
	e := testCampaign(9004, modeDirect, now()+secondsPerDay)
	e.state.raised = 700
	testing.SkipHeights(2 * heightsPerDay)
	if v := campaignView(e); v.Balance != 0 || v.NetRaised != 700 || v.ExitOpensAt != 0 || v.FinalizableAt != e.deadline {
		t.Errorf("direct, closed: %v", v)
	}

	// Settled: nothing left to finalize; the bond's release time stays.
	e.state.status, e.state.closedAt, e.state.closeReason = statusSettled, e.deadline, reasonDeadline
	if v := campaignView(e); v.FinalizableAt != 0 || v.BondReleasableAt != e.deadline+e.params.BondHold {
		t.Errorf("settled: %v", v)
	}

	// Untracked: what the escrow holds beyond the books, never below 0.
	f := testCampaign(9005, modeEscrow, 0)
	f.state.raised = 300
	testing.IssueCoins(escrowAddr(f.id), chain.NewCoins(chain.NewCoin("ugnot", 1000)))
	if v := campaignView(f); v.Untracked != 700 {
		t.Errorf("Untracked = %d, want 700", v.Untracked)
	}
	f.state.raised = 5000
	if v := campaignView(f); v.Untracked != 0 {
		t.Errorf("Untracked = %d, want 0 when the books exceed the bank", v.Untracked)
	}
}
