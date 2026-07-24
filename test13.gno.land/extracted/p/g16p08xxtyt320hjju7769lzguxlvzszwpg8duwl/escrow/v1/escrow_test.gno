package escrow

import "testing"

// ---------------------------------------------------------------------------
// State transition matrix (also documented in escrow.gno package comment)
//
// Valid:
//   Open   + Fund(client, sent>=amount)     -> Funded
//   Open   + Cancel(client|worker)          -> Cancelled
//   Funded + Release(client)                -> Released
//   Funded + Refund(client)                 -> Refunded
//   Funded + Dispute(client|worker)         -> Disputed
//   Funded + TimeoutRefund(anyone, past DL) -> Refunded
//
// Invalid (each has a dedicated test expecting panic):
//   Fund not open / non-client / underfunded
//   Release not funded / non-client / double-release
//   Refund not funded / non-client / after release
//   Dispute not funded / third-party / after refund
//   Cancel not open / third-party
//   TimeoutRefund not funded / no timeout / before deadline
// ---------------------------------------------------------------------------

const (
	client = "g1client000000000000000000000000000000"
	worker = "g1worker000000000000000000000000000000"
	third  = "g1third0000000000000000000000000000000"
)

func assertPanics(t *testing.T, name string, fn func()) {
	t.Helper()
	defer func() {
		if r := recover(); r == nil {
			t.Errorf("%s: expected panic, got none", name)
		}
	}()
	fn()
}

func openDeal(timeoutSecs int64) Deal {
	return NewDeal("1", client, worker, 1_000_000, "Logo", 100, timeoutSecs)
}

func fundedDeal(timeoutSecs int64) Deal {
	d := openDeal(timeoutSecs)
	MarkFunded(&d, client, 1_000_000, 200)
	return d
}

// --- valid transitions ---

func TestHappyPathFundRelease(t *testing.T) {
	d := openDeal(0)
	MarkFunded(&d, client, 1_000_000, 101)
	if d.State != StateFunded {
		t.Fatal("expected funded")
	}
	if d.FundedAmount != 1_000_000 {
		t.Fatal("funded amount")
	}
	Release(&d, client, 102)
	if d.State != StateReleased {
		t.Fatal("expected released")
	}
}

func TestHappyPathFundRefund(t *testing.T) {
	d := fundedDeal(0)
	Refund(&d, client, 300)
	if d.State != StateRefunded {
		t.Fatal("expected refunded")
	}
}

func TestCancelByClient(t *testing.T) {
	d := openDeal(0)
	Cancel(&d, client, 150)
	if d.State != StateCancelled {
		t.Fatal("expected cancelled")
	}
}

func TestCancelByWorker(t *testing.T) {
	d := openDeal(0)
	Cancel(&d, worker, 151)
	if d.State != StateCancelled {
		t.Fatal("expected cancelled")
	}
}

func TestDisputeByWorker(t *testing.T) {
	d := fundedDeal(0)
	Dispute(&d, worker, 400)
	if d.State != StateDisputed {
		t.Fatal("expected disputed")
	}
}

func TestDisputeByClient(t *testing.T) {
	d := fundedDeal(0)
	Dispute(&d, client, 401)
	if d.State != StateDisputed {
		t.Fatal("expected disputed")
	}
}

func TestTimeoutRefundPermissionless(t *testing.T) {
	// timeout 100s, funded at 200 => deadline 300
	d := openDeal(100)
	MarkFunded(&d, client, 1_000_000, 200)
	if d.Deadline != 300 {
		t.Fatalf("deadline want 300 got %d", d.Deadline)
	}
	if !CanTimeoutRefund(&d, 300) {
		t.Fatal("should allow at deadline")
	}
	// third party may trigger
	TimeoutRefund(&d, 301)
	if d.State != StateRefunded {
		t.Fatal("expected refunded via timeout")
	}
	if d.Note != "timeout-refund" {
		t.Fatal("note")
	}
}

func TestOverpayAllowed(t *testing.T) {
	d := openDeal(0)
	MarkFunded(&d, client, 1_500_000, 101)
	if d.FundedAmount != 1_500_000 {
		t.Fatal("overpay should record funded amount")
	}
	if PayoutAmount(&d) != 1_500_000 {
		t.Fatal("payout")
	}
}

// --- invalid: fund ---

func TestPanicFundNotOpen(t *testing.T) {
	d := fundedDeal(0)
	assertPanics(t, "fund already funded", func() {
		MarkFunded(&d, client, 1_000_000, 500)
	})
}

func TestPanicFundNonClient(t *testing.T) {
	d := openDeal(0)
	assertPanics(t, "fund by worker", func() {
		MarkFunded(&d, worker, 1_000_000, 101)
	})
}

func TestPanicFundThirdParty(t *testing.T) {
	d := openDeal(0)
	assertPanics(t, "fund by third", func() {
		MarkFunded(&d, third, 1_000_000, 101)
	})
}

func TestPanicUnderfunded(t *testing.T) {
	d := openDeal(0)
	assertPanics(t, "underfunded", func() {
		MarkFunded(&d, client, 999_999, 101)
	})
}

// --- invalid: release ---

func TestPanicReleaseBeforeFunded(t *testing.T) {
	d := openDeal(0)
	assertPanics(t, "release before fund", func() {
		Release(&d, client, 102)
	})
}

func TestPanicReleaseNonClient(t *testing.T) {
	d := fundedDeal(0)
	assertPanics(t, "release by worker", func() {
		Release(&d, worker, 102)
	})
}

func TestPanicReleaseThirdParty(t *testing.T) {
	d := fundedDeal(0)
	assertPanics(t, "release by third", func() {
		Release(&d, third, 102)
	})
}

func TestPanicDoubleRelease(t *testing.T) {
	d := fundedDeal(0)
	Release(&d, client, 102)
	assertPanics(t, "double release", func() {
		Release(&d, client, 103)
	})
}

// --- invalid: refund ---

func TestPanicRefundBeforeFunded(t *testing.T) {
	d := openDeal(0)
	assertPanics(t, "refund before fund", func() {
		Refund(&d, client, 102)
	})
}

func TestPanicRefundNonClient(t *testing.T) {
	d := fundedDeal(0)
	assertPanics(t, "refund by worker", func() {
		Refund(&d, worker, 102)
	})
}

func TestPanicRefundThirdParty(t *testing.T) {
	d := fundedDeal(0)
	assertPanics(t, "refund by third", func() {
		Refund(&d, third, 102)
	})
}

func TestPanicRefundAfterRelease(t *testing.T) {
	d := fundedDeal(0)
	Release(&d, client, 102)
	assertPanics(t, "refund after release", func() {
		Refund(&d, client, 103)
	})
}

// --- invalid: dispute ---

func TestPanicDisputeBeforeFunded(t *testing.T) {
	d := openDeal(0)
	assertPanics(t, "dispute before fund", func() {
		Dispute(&d, client, 102)
	})
}

func TestPanicDisputeThirdParty(t *testing.T) {
	d := fundedDeal(0)
	assertPanics(t, "dispute by third", func() {
		Dispute(&d, third, 102)
	})
}

func TestPanicDisputeAfterRefund(t *testing.T) {
	d := fundedDeal(0)
	Refund(&d, client, 102)
	assertPanics(t, "dispute after refund", func() {
		Dispute(&d, worker, 103)
	})
}

// --- invalid: cancel ---

func TestPanicCancelWhenFunded(t *testing.T) {
	d := fundedDeal(0)
	assertPanics(t, "cancel funded", func() {
		Cancel(&d, client, 300)
	})
}

func TestPanicCancelThirdParty(t *testing.T) {
	d := openDeal(0)
	assertPanics(t, "cancel by third", func() {
		Cancel(&d, third, 150)
	})
}

// --- invalid: timeout ---

func TestPanicTimeoutBeforeDeadline(t *testing.T) {
	d := openDeal(100)
	MarkFunded(&d, client, 1_000_000, 200) // deadline 300
	assertPanics(t, "timeout early", func() {
		TimeoutRefund(&d, 299)
	})
}

func TestPanicTimeoutNoConfig(t *testing.T) {
	d := fundedDeal(0)
	assertPanics(t, "no timeout", func() {
		TimeoutRefund(&d, 999999)
	})
}

func TestPanicTimeoutNotFunded(t *testing.T) {
	d := openDeal(100)
	assertPanics(t, "timeout open", func() {
		TimeoutRefund(&d, 999)
	})
}

func TestNewDealRejectsBadAmount(t *testing.T) {
	assertPanics(t, "zero amount", func() {
		NewDeal("x", client, worker, 0, "t", 1, 0)
	})
}
