package spendpolicy

import (
	"testing"

	"gno.land/p/nt/testutils/v0"
)

var (
	bar      = testutils.TestAddress("bar")
	kitchen  = testutils.TestAddress("kitchen")
	stranger = testutils.TestAddress("stranger")
)

const t0 = int64(1_764_000_000) // 2025-11-24 16:00 UTC, mid-day

func basePolicy() Policy {
	return Policy{
		PerPayment:    1_000,
		DailyCap:      2_500,
		PayeeHoldSecs: 3600,
		Payees: []Payee{
			{Name: "bar", Addr: bar, UsableAt: 0},
			{Name: "kitchen", Addr: kitchen, UsableAt: t0 + 600},
		},
	}
}

func baseState() State { return State{Balance: 10_000} }

func req(to address, amt int64) Request { return Request{To: to, Amount: amt, Now: t0} }

func expect(t *testing.T, name string, got Decision, kind Kind, reason string) {
	t.Helper()
	if got.Kind != kind || got.Reason != reason {
		t.Errorf("%s: got %s, want %s", name, got.String(), Decision{kind, reason}.String())
	}
}

func TestAllowNormal(t *testing.T) {
	expect(t, "normal", Check(basePolicy(), baseState(), req(bar, 500)), Allow, "")
}

func TestPerPaymentBoundary(t *testing.T) {
	expect(t, "== cap", Check(basePolicy(), baseState(), req(bar, 1_000)), Allow, "")
	expect(t, "cap+1", Check(basePolicy(), baseState(), req(bar, 1_001)), Hold, ReasonOverPayment)
}

func TestDailyCapBoundary(t *testing.T) {
	s := baseState()
	s.SpentToday, s.SpentDay = 1_500, DayOf(t0)
	expect(t, "fills cap exactly", Check(basePolicy(), s, req(bar, 1_000)), Allow, "")
	s.SpentToday = 1_501
	expect(t, "one over", Check(basePolicy(), s, req(bar, 1_000)), Hold, ReasonOverDaily)
}

func TestDayRollover(t *testing.T) {
	s := baseState()
	s.SpentToday, s.SpentDay = 2_500, DayOf(t0)-1 // spent yesterday
	expect(t, "new day", Check(basePolicy(), s, req(bar, 1_000)), Allow, "")
	if SpentOn(s, t0) != 0 {
		t.Errorf("SpentOn after rollover = %d", SpentOn(s, t0))
	}
	s.SpentDay = DayOf(t0)
	expect(t, "same day", Check(basePolicy(), s, req(bar, 1)), Hold, ReasonOverDaily)
}

func TestUnknownPayeeDenied(t *testing.T) {
	expect(t, "stranger", Check(basePolicy(), baseState(), req(stranger, 1)), Deny, ReasonUnknownPayee)
	p := basePolicy()
	p.Payees = nil
	expect(t, "empty list", Check(p, baseState(), req(bar, 1)), Deny, ReasonUnknownPayee)
}

func TestPayeeHold(t *testing.T) {
	expect(t, "in hold", Check(basePolicy(), baseState(), req(kitchen, 10)), Hold, ReasonPayeeHold)
	r := req(kitchen, 10)
	r.Now = t0 + 599
	expect(t, "last second of hold", Check(basePolicy(), baseState(), r), Hold, ReasonPayeeHold)
	r.Now = t0 + 600
	expect(t, "hold ends", Check(basePolicy(), baseState(), r), Allow, "")
}

func TestBadAmounts(t *testing.T) {
	expect(t, "zero", Check(basePolicy(), baseState(), req(bar, 0)), Deny, ReasonBadAmount)
	expect(t, "negative", Check(basePolicy(), baseState(), req(bar, -5)), Deny, ReasonBadAmount)
}

func TestInsufficientBalance(t *testing.T) {
	s := State{Balance: 100}
	expect(t, "over balance", Check(basePolicy(), s, req(bar, 101)), Deny, ReasonNoFunds)
	expect(t, "== balance", Check(basePolicy(), s, req(bar, 100)), Allow, "")
}

func TestFrozenBeatsEverything(t *testing.T) {
	s := baseState()
	s.Frozen = true
	expect(t, "frozen", Check(basePolicy(), s, req(bar, 1)), Deny, ReasonFrozen)
	r := req(bar, 1)
	r.OwnerApproved = true
	expect(t, "frozen + approved", Check(basePolicy(), s, r), Deny, ReasonFrozen)
}

func TestExpiry(t *testing.T) {
	p := basePolicy()
	p.ExpiresAt = t0
	expect(t, "at expiry", Check(p, baseState(), req(bar, 1)), Deny, ReasonExpired)
	p.ExpiresAt = t0 + 1
	expect(t, "before expiry", Check(p, baseState(), req(bar, 1)), Allow, "")
}

func TestSessionExpiry(t *testing.T) {
	r := req(bar, 1)
	r.SessionExpiresAt = t0
	expect(t, "session expired", Check(basePolicy(), baseState(), r), Deny, ReasonSessionExpired)
	r.SessionExpiresAt = t0 + 60
	expect(t, "session live", Check(basePolicy(), baseState(), r), Allow, "")
}

func TestOverflowDenied(t *testing.T) {
	s := State{Balance: 9_223_372_036_854_775_807, SpentToday: 9_223_372_036_854_775_800, SpentDay: DayOf(t0)}
	p := basePolicy()
	p.PerPayment, p.DailyCap = 9_223_372_036_854_775_807, 9_223_372_036_854_775_807
	expect(t, "overflow", Check(p, s, req(bar, 100)), Deny, ReasonOverflow)
}

func TestApprovalLiftsHoldsOnly(t *testing.T) {
	r := req(bar, 5_000)
	r.OwnerApproved = true
	expect(t, "approved over caps", Check(basePolicy(), baseState(), r), Allow, "")
	r = req(kitchen, 10)
	r.OwnerApproved = true
	expect(t, "approved payee hold", Check(basePolicy(), baseState(), r), Allow, "")
	r = req(stranger, 10)
	r.OwnerApproved = true
	expect(t, "approved unknown payee", Check(basePolicy(), baseState(), r), Deny, ReasonUnknownPayee)
	r = req(bar, 20_000)
	r.OwnerApproved = true
	expect(t, "approved over balance", Check(basePolicy(), baseState(), r), Deny, ReasonNoFunds)
}

func TestDenyBeforeHold(t *testing.T) {
	// over the per-payment cap AND over the balance: the hard limit must win
	s := State{Balance: 1_500}
	expect(t, "deny wins", Check(basePolicy(), s, req(bar, 2_000)), Deny, ReasonNoFunds)
}

func TestRecord(t *testing.T) {
	s := Record(baseState(), 700, t0)
	if s.Balance != 9_300 || s.SpentToday != 700 || s.SpentDay != DayOf(t0) {
		t.Errorf("record: %+v", s)
	}
	s = Record(s, 300, t0+Day) // next day resets the counter
	if s.SpentToday != 300 || s.Balance != 9_000 {
		t.Errorf("record next day: %+v", s)
	}
}

func TestRecordPanicsOnMisuse(t *testing.T) {
	for _, amt := range []int64{0, -1, 10_001} {
		func() {
			defer func() {
				if recover() == nil {
					t.Errorf("Record(%d) did not panic", amt)
				}
			}()
			Record(baseState(), amt, t0)
		}()
	}
}

func TestValidate(t *testing.T) {
	if e := Validate(basePolicy()); e != "" {
		t.Errorf("base policy invalid: %s", e)
	}
	cases := map[string]func(p *Policy){
		"negative":    func(p *Policy) { p.DailyCap = -1 },
		"per > daily": func(p *Policy) { p.PerPayment = 3_000 },
		"dup name":    func(p *Policy) { p.Payees[1].Name = "bar" },
		"dup address": func(p *Policy) { p.Payees[1].Addr = bar },
		"bad name":    func(p *Policy) { p.Payees[0].Name = "Bar Tab!" },
		"empty name":  func(p *Policy) { p.Payees[0].Name = "" },
		"bad address": func(p *Policy) { p.Payees[0].Addr = address("g1notanaddress") },
		"too many": func(p *Policy) {
			for i := 0; i < MaxPayees; i++ {
				p.Payees = append(p.Payees, p.Payees[0])
			}
		},
	}
	for name, mut := range cases {
		p := basePolicy()
		mut(&p)
		if Validate(p) == "" {
			t.Errorf("Validate accepted %s", name)
		}
	}
}

func TestDayOf(t *testing.T) {
	if DayOf(0) != 0 || DayOf(Day-1) != 0 || DayOf(Day) != 1 || DayOf(-1) != -1 {
		t.Errorf("DayOf wrong: %d %d %d %d", DayOf(0), DayOf(Day-1), DayOf(Day), DayOf(-1))
	}
}
