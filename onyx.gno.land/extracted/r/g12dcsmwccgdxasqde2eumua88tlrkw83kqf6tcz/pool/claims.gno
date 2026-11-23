package pool

import (
	mimir "gno.land/p/g12dcsmwccgdxasqde2eumua88tlrkw83kqf6tcz/mimir"
)

// owed is what `user` is owed from a resolved market: gross = stake back +
// share of the losing side. Full refund when either side is empty or on DRAW /
// UNRESOLVABLE. feeBase is the profit copy fees may be charged on: the user's
// NET profit (the share less their own stake on the losing side, so a hedger
// never pays a copy fee on their own money), counted only on the copied part
// of the winning stake. Deposits at or after the settlement cutoff are late:
// their net principal comes back and they share in nothing.
func owed(m *Market, p *Position) (gross, feeBase int64) {
	if p == nil {
		return 0, 0
	}
	raw := p.A + p.B
	if m.Outcome >= Draw {
		return raw, 0
	}
	totals := m.history.Before(m.SettlementCutoff)
	mine := p.history.Before(m.SettlementCutoff)
	if totals.A == 0 || totals.B == 0 {
		return raw, 0
	}
	late := raw - mine.A - mine.B
	win, lose, copied, opposite, winners := mine.A, mine.B, mine.CopiedA, totals.B, totals.A
	if m.Outcome == SideB {
		win, lose, copied, opposite, winners = mine.B, mine.A, mine.CopiedB, totals.A, totals.B
	}
	if win == 0 {
		return late, 0
	}
	profit := mimir.MulDiv(win, opposite, winners)
	gross = late + win + profit
	if profit > lose && copied != 0 {
		feeBase = mimir.MulDiv(profit-lose, copied, win)
	}
	return gross, feeBase
}

func winnerPayout(m *Market, p *Position) bool {
	if m.Outcome >= Draw || p == nil {
		return false
	}
	totals := m.history.Before(m.SettlementCutoff)
	if totals.A == 0 || totals.B == 0 {
		return false
	}
	mine := p.history.Before(m.SettlementCutoff)
	if m.Outcome == SideA {
		return mine.A != 0
	}
	return mine.B != 0
}

// copyFees are the copy-trade fees on the copied net profit: (to the
// referrer, to the platform). Nobody pays themselves: a referrer or fee
// recipient who is the user waives that leg.
func copyFees(user address, p *Position, feeBase int64) (toRef, toPlatform int64) {
	if feeBase == 0 || p.Referrer == "" || p.Referrer == user {
		return 0, 0
	}
	toRef = mimir.MulDiv(feeBase, ReferrerFeeBps, 10_000)
	if roles.FeeRecipient != user {
		toPlatform = mimir.MulDiv(feeBase, CopyFeeBps, 10_000)
	}
	return toRef, toPlatform
}

// Claim collects the caller's own payout.
func Claim(cur realm, id int64) {
	claimFor(cur, id, caller(cur))
}

// ClaimFor lets anyone push a user's payout to them. The money only ever goes to `user`.
func ClaimFor(cur realm, id int64, user address) {
	claimFor(cur, id, user)
}

func claimFor(cur realm, id int64, user address) {
	m := getMarket(id)
	if m.State != StResolved {
		panic("NotResolved")
	}
	p := m.position(user)
	// Paused: refunds still go out; a winner waits for the unpause.
	if roles.Paused && winnerPayout(m, p) {
		panic("IsPaused")
	}
	if p != nil && p.Claimed {
		panic("AlreadyClaimed")
	}
	gross, feeBase := owed(m, p)
	if gross == 0 {
		panic("NothingToClaim")
	}
	p.Claimed = true
	toRef, toPlatform := copyFees(user, p, feeBase)
	if toRef != 0 {
		accrue(id, p.Referrer, toRef)
	}
	if toPlatform != 0 {
		accrue(id, roles.FeeRecipient, toPlatform)
	}
	fee := toRef + toPlatform
	emit("Claimed", "id", itoa(id), "user", user.String(), "paid", itoa(gross-fee), "fee", itoa(fee))
	push(cur, user, gross-fee)
}

// ClaimFees pays the caller's accrued fees (entry fees, copy fees, forfeited bonds).
func ClaimFees(cur realm) {
	claimFeesTo(cur, caller(cur))
}

func ClaimFeesTo(cur realm, to address) {
	if !to.IsValid() {
		panic("ZeroAddress")
	}
	claimFeesTo(cur, to)
}

func claimFeesTo(cur realm, to address) {
	c := caller(cur)
	amount := feesOf(c)
	if amount == 0 {
		panic("NothingToWithdraw")
	}
	accruedFees.Set(c.String(), int64(0))
	lifetimeFeesClaimed = mimir.Add(lifetimeFeesClaimed, amount)
	emit("FeeClaimed", "recipient", c.String(), "to", to.String(), "amount", itoa(amount))
	push(cur, to, amount)
}
