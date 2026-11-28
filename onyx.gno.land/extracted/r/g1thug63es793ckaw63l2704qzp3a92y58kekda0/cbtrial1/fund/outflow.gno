package fund

import (
	"gno.land/p/g1thug63es793ckaw63l2704qzp3a92y58kekda0/cbtrial1/fundmath"
	"gno.land/p/nt/ufmt/v0"
)

// ---- investment payments out ----

// ProposeOutflow proposes an investment payment to a listed instrument.
// Manager only, while the period is open.
func ProposeOutflow(cur realm, instrumentName string, amount int64) int64 {
	onlyRole(cur, manager, "manager")
	requireState(stateOpen)
	requireNotWindingDown()
	countProposal()
	getInstrument(instrumentName)
	if amount <= 0 || amount > MaxMark {
		panic("amount out of range")
	}
	nextOut++
	o := &outflow{id: nextOut, instrument: instrumentName, amount: amount, period: cur0.n}
	outflows.Set(pad(o.id), o)
	addTrail("manager", ufmt.Sprintf("Outflow #%d proposed: %s tUSD to %s.", o.id, fmtAmt(amount), instrumentName))
	return o.id
}

// ApproveOutflow countersigns and pays an outflow. Reviewer only. The limits
// are checked before payment, against the NAV after the last settlement
// (design review 1, B4): the total for the period, and the concentration
// in one instrument. Payment goes only to the instrument's listed address.
func ApproveOutflow(cur realm, id int64) {
	onlyRole(cur, reviewer, "valuation reviewer")
	requireState(stateOpen)
	o := getOutflow(id)
	if o.paid || o.cancelled {
		panic("outflow is closed")
	}
	if o.period != cur0.n {
		panic("outflow was proposed in an earlier period; propose it again")
	}
	requireNotWindingDown()
	if lastNAV <= 0 {
		panic("no settled NAV yet")
	}
	if o.amount > bookCash-totalOwed {
		panic("not enough cash")
	}
	capPeriod := fundmath.MulDivDown(lastNAV, OutflowCapBps, fundmath.BpsDenominator)
	if addChecked(cur0.outflowUsed, o.amount) > capPeriod {
		panic(ufmt.Sprintf("outflow cap: %s tUSD left this period", fmtAmt(capPeriod-cur0.outflowUsed)))
	}
	in := getInstrument(o.instrument)
	capInstr := fundmath.MulDivDown(lastNAV, ConcentrationBps, fundmath.BpsDenominator)
	if addChecked(in.book, o.amount) > capInstr {
		panic("concentration limit: " + o.instrument + " would exceed " + pct(ConcentrationBps) + " of NAV")
	}
	o.paid = true
	cur0.outflowUsed += o.amount
	bookCash -= o.amount
	in.book += o.amount
	c := cur.Sub(cashSub)
	checkErr(token.RealmTeller(0, c).Transfer(0, c, in.payTo, o.amount))
	addTrail("reviewer", ufmt.Sprintf("Outflow #%d countersigned and paid: %s tUSD to %s.", id, fmtAmt(o.amount), o.instrument))
}

// CancelOutflow withdraws (manager) or declines (reviewer) an outflow.
func CancelOutflow(cur realm, id int64) {
	assertMasterKey()
	requireLaunched()
	c := cur.Previous().Address()
	if c != manager && c != reviewer {
		panic("manager or valuation reviewer only")
	}
	o := getOutflow(id)
	if o.paid || o.cancelled {
		panic("outflow is closed")
	}
	o.cancelled = true
	addTrail(roleName(c), ufmt.Sprintf("Outflow #%d cancelled.", id))
}

func getOutflow(id int64) *outflow {
	v := outflows.Get(pad(id))
	if v == nil {
		panic("unknown outflow")
	}
	return v.(*outflow)
}

// ---- money coming back (review I4) ----

// ProposeReceipt proposes to record tUSD that has arrived in the fund's cash
// account: from an instrument (a maturity, coupon or sale), or OTHER for
// anything unexplained, such as a donation. Manager only, while open.
func ProposeReceipt(cur realm, source string, amount int64) int64 {
	onlyRole(cur, manager, "manager")
	requireState(stateOpen)
	countProposal()
	if source != "OTHER" {
		getInstrument(source)
	}
	if amount <= 0 || amount > MaxMark {
		panic("amount out of range")
	}
	nextRcpt++
	r := &receipt{id: nextRcpt, source: source, amount: amount, period: cur0.n}
	receipts.Set(pad(r.id), r)
	addTrail("manager", ufmt.Sprintf("Receipt #%d proposed: %s tUSD from %s.", r.id, fmtAmt(amount), source))
	return r.id
}

// ApproveReceipt countersigns a receipt. Reviewer only. The cash account must
// already hold the recorded cash plus the amount, so nothing is counted
// twice. A receipt from an instrument lowers its book value (never below 0).
func ApproveReceipt(cur realm, id int64) {
	onlyRole(cur, reviewer, "valuation reviewer")
	requireState(stateOpen)
	r := getReceipt(id)
	if r.recorded || r.cancelled {
		panic("receipt is closed")
	}
	if r.period != cur0.n {
		panic("receipt was proposed in an earlier period; propose it again")
	}
	// The cash account holds the recorded cash and the payments set aside for
	// restricted holders; a receipt must come on top of both (review 3, I1).
	if token.BalanceOf(cashAddr()) < addChecked(addChecked(bookCash, totalHeld), r.amount) {
		panic("the cash account does not hold this amount beyond the recorded cash")
	}
	r.recorded = true
	bookCash += r.amount
	if r.source != "OTHER" {
		in := getInstrument(r.source)
		if r.amount >= in.book {
			in.book = 0
		} else {
			in.book -= r.amount
		}
	}
	addTrail("reviewer", ufmt.Sprintf("Receipt #%d countersigned: %s tUSD from %s added to cash.", id, fmtAmt(r.amount), r.source))
}

// CancelReceipt withdraws (manager) or declines (reviewer) a receipt.
func CancelReceipt(cur realm, id int64) {
	assertMasterKey()
	requireLaunched()
	c := cur.Previous().Address()
	if c != manager && c != reviewer {
		panic("manager or valuation reviewer only")
	}
	r := getReceipt(id)
	if r.recorded || r.cancelled {
		panic("receipt is closed")
	}
	r.cancelled = true
	addTrail(roleName(c), ufmt.Sprintf("Receipt #%d cancelled.", id))
}

func getReceipt(id int64) *receipt {
	v := receipts.Get(pad(id))
	if v == nil {
		panic("unknown receipt")
	}
	return v.(*receipt)
}

// ---- expenses (administrator proposes, reviewer approves) ----

// ProposeExpense proposes to pay a listed service provider (audit, legal,
// ...) from the fund's cash. Administrator only, while open.
func ProposeExpense(cur realm, provider string, amount int64, reasonCode string) int64 {
	onlyRole(cur, administrator, "administrator")
	requireState(stateOpen)
	countProposal()
	getProvider(provider)
	checkCode(reasonCode)
	if amount <= 0 || amount > MaxMark {
		panic("amount out of range")
	}
	nextExp++
	e := &expense{id: nextExp, provider: provider, amount: amount, reason: reasonCode, period: cur0.n}
	expenses.Set(pad(e.id), e)
	addTrail("administrator", ufmt.Sprintf("Expense #%d proposed: %s tUSD to %s (%s).", e.id, fmtAmt(amount), provider, reasonCode))
	return e.id
}

// ApproveExpense countersigns and pays an expense. Reviewer only.
func ApproveExpense(cur realm, id int64) {
	onlyRole(cur, reviewer, "valuation reviewer")
	requireState(stateOpen)
	e := getExpense(id)
	if e.paid || e.cancelled {
		panic("expense is closed")
	}
	if e.period != cur0.n {
		panic("expense was proposed in an earlier period; propose it again")
	}
	if e.amount > bookCash-totalOwed {
		panic("not enough cash")
	}
	e.paid = true
	bookCash -= e.amount
	c := cur.Sub(cashSub)
	checkErr(token.RealmTeller(0, c).Transfer(0, c, getProvider(e.provider), e.amount))
	addTrail("reviewer", ufmt.Sprintf("Expense #%d countersigned and paid: %s tUSD to %s.", id, fmtAmt(e.amount), e.provider))
}

// CancelExpense withdraws (administrator) or declines (reviewer) an expense.
func CancelExpense(cur realm, id int64) {
	assertMasterKey()
	requireLaunched()
	c := cur.Previous().Address()
	if c != administrator && c != reviewer {
		panic("administrator or valuation reviewer only")
	}
	e := getExpense(id)
	if e.paid || e.cancelled {
		panic("expense is closed")
	}
	e.cancelled = true
	addTrail(roleName(c), ufmt.Sprintf("Expense #%d cancelled.", id))
}

func getExpense(id int64) *expense {
	v := expenses.Get(pad(id))
	if v == nil {
		panic("unknown expense")
	}
	return v.(*expense)
}

func roleName(a address) string {
	switch a {
	case manager:
		return "manager"
	case administrator:
		return "administrator"
	case reviewer:
		return "reviewer"
	case officer:
		return "compliance"
	case auditor:
		return "auditor"
	}
	return "investor"
}

// MaxProposalsPerPeriod bounds the payments, receipts and expenses proposed
// in one period, so the desk page stays readable (review 2, m9).
const MaxProposalsPerPeriod int64 = 30

func countProposal() {
	if cur0.proposals >= MaxProposalsPerPeriod {
		panic("too many proposals in this period")
	}
	cur0.proposals++
}
