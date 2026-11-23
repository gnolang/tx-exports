package agentvault

import (
	"testing"
)

func TestDayIndex(t *testing.T) {
	if DayIndex(0) != 0 {
		t.Fatal("day 0 expected for unix 0")
	}
	if DayIndex(86399) != 0 {
		t.Fatal("day 0 expected for unix 86399")
	}
	if DayIndex(86400) != 1 {
		t.Fatal("day 1 expected for unix 86400")
	}
	if DayIndex(172800) != 2 {
		t.Fatal("day 2 expected for unix 172800")
	}
}

func TestValidateCaps(t *testing.T) {
	if ValidateCaps(100, 1000) != "" {
		t.Fatal("valid caps rejected")
	}
	if ValidateCaps(0, 1000) == "" {
		t.Fatal("zero per-tx cap accepted")
	}
	if ValidateCaps(-5, 1000) == "" {
		t.Fatal("negative per-tx cap accepted")
	}
	if ValidateCaps(100, 0) == "" {
		t.Fatal("zero daily cap accepted")
	}
	if ValidateCaps(100, -1) == "" {
		t.Fatal("negative daily cap accepted")
	}
	if ValidateCaps(2000, 1000) == "" {
		t.Fatal("per-tx cap above daily cap accepted")
	}
	if ValidateCaps(1000, 1000) != "" {
		t.Fatal("per-tx cap equal to daily cap rejected")
	}
}

func TestNewBudget(t *testing.T) {
	b := NewBudget(100, 1000)
	if b.PerTxCap != 100 || b.DailyCap != 1000 {
		t.Fatal("budget caps not stored")
	}
	if b.SpentToday != 0 || b.DayIndex != 0 {
		t.Fatal("new budget must start unspent")
	}
}

func TestCheckSpend(t *testing.T) {
	b := NewBudget(100, 1000)

	// Within both caps: allowed.
	if ok, reason := CheckSpend(b, 50); !ok {
		t.Fatal("spend within caps rejected:", reason)
	}
	// Exactly at the per-tx cap: allowed.
	if ok, reason := CheckSpend(b, 100); !ok {
		t.Fatal("spend at per-tx cap rejected:", reason)
	}
	// One over the per-tx cap: rejected with the per-tx reason.
	if ok, reason := CheckSpend(b, 101); ok || reason != "exceeds per-transaction cap" {
		t.Fatal("spend over per-tx cap not rejected with per-tx reason:", ok, reason)
	}
	// Non-positive amounts: rejected.
	if ok, reason := CheckSpend(b, 0); ok || reason != "amount must be positive" {
		t.Fatal("zero spend not rejected:", ok, reason)
	}
	if ok, _ := CheckSpend(b, -10); ok {
		t.Fatal("negative spend allowed")
	}
	// Cumulative spend past the daily cap: rejected with the daily reason.
	// Spend 950 (within per-tx? no: 950 > 100). Use a budget with a
	// higher per-tx cap to isolate the daily check.
	b2 := NewBudget(1000, 1000)
	ApplySpend(&b2, 600)
	if ok, reason := CheckSpend(b2, 500); ok || reason != "exceeds daily cap" {
		t.Fatal("spend over daily cap not rejected with daily reason:", ok, reason)
	}
	// Exactly the remainder of the daily cap: allowed.
	if ok, reason := CheckSpend(b2, 400); !ok {
		t.Fatal("spend at daily remainder rejected:", reason)
	}
}

func TestRefreshDayAndRemaining(t *testing.T) {
	b := NewBudget(100, 1000)
	day0 := int64(1000)         // unix 1000 -> day 0
	day1 := int64(86400 + 1000) // unix 87400 -> day 1

	ApplySpend(&b, 400)
	b.DayIndex = DayIndex(day0)
	if RemainingToday(b, day0) != 600 {
		t.Fatal("remaining today wrong after spend:", RemainingToday(b, day0))
	}
	// Same day: refresh changes nothing.
	RefreshDay(&b, day0)
	if b.SpentToday != 400 {
		t.Fatal("refresh on same day cleared spent amount")
	}
	// Next day: refresh clears the spent amount.
	RefreshDay(&b, day1)
	if b.SpentToday != 0 {
		t.Fatal("refresh on new day did not clear spent amount")
	}
	if b.DayIndex != DayIndex(day1) {
		t.Fatal("refresh did not move day index")
	}
	if RemainingToday(b, day1) != 1000 {
		t.Fatal("remaining on new day is not the full daily cap")
	}
	// A budget that never spent: remaining is the full cap even
	// when the stored day is stale.
	stale := NewBudget(50, 500)
	if RemainingToday(stale, day1) != 500 {
		t.Fatal("stale-day budget remaining wrong")
	}
}

func TestApplySpend(t *testing.T) {
	b := NewBudget(100, 1000)
	ApplySpend(&b, 30)
	ApplySpend(&b, 20)
	if b.SpentToday != 50 {
		t.Fatal("spent today not accumulated:", b.SpentToday)
	}
}

func TestEscrowRefundable(t *testing.T) {
	e := Escrow{ID: 1, Amount: 500, DeadlineHeight: 100, Status: EscrowHeld}
	if EscrowRefundable(e, 100) {
		t.Fatal("escrow refundable at the deadline block itself")
	}
	if !EscrowRefundable(e, 101) {
		t.Fatal("escrow not refundable past the deadline")
	}
	if EscrowRefundable(e, 50) {
		t.Fatal("escrow refundable before the deadline")
	}
	e.Status = EscrowReleased
	if EscrowRefundable(e, 200) {
		t.Fatal("released escrow refundable")
	}
	e.Status = EscrowRefunded
	if EscrowRefundable(e, 200) {
		t.Fatal("refunded escrow refundable again")
	}
}

func TestEscrowStatusString(t *testing.T) {
	if EscrowStatusString(EscrowHeld) != "HELD" {
		t.Fatal("HELD string wrong")
	}
	if EscrowStatusString(EscrowReleased) != "RELEASED" {
		t.Fatal("RELEASED string wrong")
	}
	if EscrowStatusString(EscrowRefunded) != "REFUNDED" {
		t.Fatal("REFUNDED string wrong")
	}
	if EscrowStatusString(EscrowStatus(99)) != "UNKNOWN" {
		t.Fatal("unknown status string wrong")
	}
}
