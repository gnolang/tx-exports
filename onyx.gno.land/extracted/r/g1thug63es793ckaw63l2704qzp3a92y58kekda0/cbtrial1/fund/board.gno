package fund

import "gno.land/p/nt/ufmt/v0"

// Board powers (design note v3.3, B). In the fund documents these belong to
// the directors. Here the manager proposes and the independent valuation
// reviewer countersigns anything that can move money: the manager never
// moves money or assets on his signature alone (the owner's rule).
//
// A proposal is valid only in the period it is made: the two keys agree at
// the same time, and a key spent once cannot be used alone later (review 2,
// I1 and I2).

var suspensionReasons = []string{"market-closed", "valuation-unavailable", "assets-illiquid", "investor-interest"}

func checkReason(code string, allowed []string) {
	for _, a := range allowed {
		if a == code {
			return
		}
	}
	panic("reason code not allowed here")
}

// ---- suspension of dealing ----

// ProposeSuspension proposes to suspend dealing for `days` days (1 to 30)
// with one of the reason codes, or to renew a suspension. Manager only.
func ProposeSuspension(cur realm, reasonCode string, days int64) {
	onlyRole(cur, manager, "manager")
	requireNotClosed()
	checkReason(reasonCode, suspensionReasons)
	if days < 1 || days > MaxSuspensionDays {
		panic("days must be 1 to 30")
	}
	pendingSusp = &suspension{period: cur0.n, days: days, reason: reasonCode}
	addTrail("manager", ufmt.Sprintf("Suspension of dealing proposed for %d days: %s.", days, reasonCode))
}

// ProposeLiftSuspension proposes to end a suspension early. Manager only.
func ProposeLiftSuspension(cur realm) {
	onlyRole(cur, manager, "manager")
	if !isSuspended() {
		panic("dealing is not suspended")
	}
	pendingSusp = &suspension{period: cur0.n, lift: true}
	addTrail("manager", "End of the suspension proposed.")
}

// ApproveSuspension countersigns the pending suspension, renewal or lift.
// Reviewer only. A suspension runs from now and ends by itself.
func ApproveSuspension(cur realm) {
	onlyRole(cur, reviewer, "valuation reviewer")
	if pendingSusp == nil {
		panic("nothing to approve")
	}
	if pendingSusp.period != cur0.n {
		panic("the proposal was made in an earlier period; propose again")
	}
	p := pendingSusp
	pendingSusp = nil
	if p.lift {
		suspendedUntil = 0
		addTrail("reviewer", "Suspension of dealing lifted.")
		return
	}
	suspendedUntil = now() + p.days*86400
	addTrail("reviewer", ufmt.Sprintf("Dealing suspended for %d days: %s. Orders wait for the first NAV after the suspension.", p.days, p.reason))
}

// DeclineSuspension drops a pending proposal. Reviewer or manager.
func DeclineSuspension(cur realm) {
	assertMasterKey()
	requireLaunched()
	c := cur.Previous().Address()
	if c != manager && c != reviewer {
		panic("manager or valuation reviewer only")
	}
	if pendingSusp == nil {
		panic("nothing pending")
	}
	pendingSusp = nil
	addTrail(roleName(c), "Suspension proposal dropped.")
}

// ---- closing to new subscriptions (no money moves: manager alone) ----

func CloseSubscriptions(cur realm) {
	onlyRole(cur, manager, "manager")
	requireLaunched()
	if subscriptionsClosed {
		panic("already closed to new subscriptions")
	}
	subscriptionsClosed = true
	addTrail("manager", "The fund is closed to new subscriptions. Redemptions continue.")
}

func ReopenSubscriptions(cur realm) {
	onlyRole(cur, manager, "manager")
	requireLaunched()
	requireNotWindingDown()
	if !subscriptionsClosed {
		panic("the fund is open to subscriptions")
	}
	subscriptionsClosed = false
	addTrail("manager", "The fund is open to new subscriptions again.")
}

// ---- compulsory redemption ----

// CompelRedemption orders the full redemption of a direct holder at the
// next NAV, ahead of the gate, for a compliance reason (not eligible, breach
// of law, information not provided). The reason stays off-chain: only a
// salted commitment to the officer's record is kept (review 2, I4). An open
// request of the holder becomes compulsory. Compliance officer only.
// Nominee sub-accounts are handled by the nominee, off-chain.
func CompelRedemption(cur realm, holderAddr address, reasonCommitment string) int64 {
	onlyRole(cur, officer, "compliance officer")
	requireState(stateOpen)
	requireNotWindingDown()
	checkCommitment(reasonCommitment)
	if isSubAccount(holderAddr) {
		panic("nominee sub-accounts are handled by the nominee, off-chain")
	}
	return compel(cur, holderAddr, reasonCommitment)
}

func compulsoryKind(reason string) (kind, ref string) {
	if reason == "below-minimum" {
		return "below-minimum", ""
	}
	return "compliance", reason
}

// NoticeBelowMinimum records notice to a holder worth less than the minimum
// holding at the last NAV: after 30 days without a top-up, the manager may
// propose a compulsory redemption. Manager only (no money moves).
func NoticeBelowMinimum(cur realm, holderAddr address) {
	onlyRole(cur, manager, "manager")
	requireLaunched()
	h := getHolder(holderAddr)
	if h == nil || h.shares == 0 {
		panic("not a holder")
	}
	if valueOfShares(h.shares) >= MinHolding {
		panic("the holding is not below the minimum")
	}
	notices.Set(holderAddr.String(), now())
	addTrail("manager", "Notice given to a holding below the minimum: 30 days to top up.")
}

// ProposeMinimumRedemption proposes the compulsory redemption of a holding
// still below the minimum 30 days after notice. Manager only; the reviewer
// must countersign with ApproveMinimumRedemption.
func ProposeMinimumRedemption(cur realm, holderAddr address) {
	onlyRole(cur, manager, "manager")
	requireState(stateOpen)
	v := notices.Get(holderAddr.String())
	if v == nil {
		panic("no notice given")
	}
	if now() < v.(int64)+MinHoldingNoticeDays*86400 {
		panic("the 30-day notice has not run out")
	}
	h := getHolder(holderAddr)
	if h == nil || h.shares == 0 || valueOfShares(h.shares) >= MinHolding {
		panic("the holding is not below the minimum")
	}
	pendingMin.Set(holderAddr.String(), cur0.n)
	addTrail("manager", "Compulsory redemption of a holding below the minimum proposed.")
}

// WithdrawMinimumRedemption drops the manager's proposal. Manager only.
func WithdrawMinimumRedemption(cur realm, holderAddr address) {
	onlyRole(cur, manager, "manager")
	if !pendingMin.Has(holderAddr.String()) {
		panic("nothing proposed for this holder")
	}
	pendingMin.Remove(holderAddr.String())
	addTrail("manager", "Proposal of a compulsory redemption below the minimum withdrawn.")
}

// ApproveMinimumRedemption countersigns it, in the period it was proposed,
// if the holding is still below the minimum. Reviewer only.
func ApproveMinimumRedemption(cur realm, holderAddr address) int64 {
	onlyRole(cur, reviewer, "valuation reviewer")
	requireState(stateOpen)
	v := pendingMin.Get(holderAddr.String())
	if v == nil {
		panic("nothing proposed for this holder")
	}
	if v.(int64) != cur0.n {
		panic("the proposal was made in an earlier period; propose again")
	}
	h := getHolder(holderAddr)
	if h == nil || h.shares == 0 || valueOfShares(h.shares) >= MinHolding {
		panic("the holding is not below the minimum")
	}
	pendingMin.Remove(holderAddr.String())
	notices.Remove(holderAddr.String())
	return compel(cur, holderAddr, "below-minimum")
}

func compel(cur realm, holderAddr address, reason string) int64 {
	h := getHolder(holderAddr)
	if h == nil || h.shares == 0 {
		panic("not a holder")
	}
	if h.openRed != 0 {
		r := getRed(h.openRed)
		r.compulsory, r.full, r.lots = true, true, 0
		r.kind, r.reasonRef = compulsoryKind(reason)
		addTrail("compulsory", ufmt.Sprintf("Redemption request #%d made compulsory.", r.id))
		return r.id
	}
	if h.activeSub != 0 {
		// A top-up the fund can no longer deal (the wallet is not eligible)
		// is refunded first (review 2, m4).
		s := getSub(h.activeSub)
		if held(s.wallet, s.payee) || isEligible(s.wallet) {
			panic("the holder has a subscription in escrow; decide it first")
		}
		closeSub(cur, s, true)
	}
	return placeRed(holderAddr, h.payee, h.viaNominee, 0, true, reason)
}

// ---- wind-down (design note v3.1): two keys ----

var windDownReasons = []string{"last-investor", "manager-decision", "too-small", "investor-interest"}

// ProposeWindDown proposes to close the fund. Manager only.
func ProposeWindDown(cur realm, reasonCode string) {
	onlyRole(cur, manager, "manager")
	requireState(stateOpen)
	requireNotWindingDown()
	checkReason(reasonCode, windDownReasons)
	windDownProposed, windDownReason, windDownPeriod = true, reasonCode, cur0.n
	addTrail("manager", "Wind-down of the fund proposed: "+reasonCode+".")
}

// WithdrawWindDown (manager) or DeclineWindDown (reviewer) drops the proposal.
func WithdrawWindDown(cur realm) {
	onlyRole(cur, manager, "manager")
	dropWindDown("manager", "withdrawn")
}

func DeclineWindDown(cur realm) {
	onlyRole(cur, reviewer, "valuation reviewer")
	dropWindDown("reviewer", "declined")
}

func dropWindDown(role, verb string) {
	if !windDownProposed || windDownApproved {
		panic("no wind-down proposal pending")
	}
	windDownProposed, windDownReason = false, ""
	addTrail(role, "Wind-down proposal "+verb+".")
}

// ApproveWindDown countersigns it, in the period it was proposed; the
// wind-down starts at this period's cut-off. Reviewer only. It cannot be
// reversed in this version.
func ApproveWindDown(cur realm) {
	onlyRole(cur, reviewer, "valuation reviewer")
	requireState(stateOpen)
	if !windDownProposed {
		panic("no wind-down proposed")
	}
	if windDownPeriod != cur0.n {
		panic("the proposal was made in an earlier period; propose again")
	}
	windDownApproved = true
	addTrail("reviewer", "Wind-down approved. It starts at this period's cut-off: no new subscriptions or investments; each period all available cash is paid out pro rata until the fund closes.")
}

// ---- closure (review 4, I2): two keys, after the wind-down ----

// ProposeClosure proposes to close the wound-down fund once nothing is left
// (no shares, no escrow, nothing set aside, no instrument on the books, no
// money to pay out). Until then late recoveries keep reaching the former
// holders. Manager only.
func ProposeClosure(cur realm) {
	onlyRole(cur, manager, "manager")
	requireState(stateOpen)
	if !windingDown {
		panic("the fund is not being wound down")
	}
	closureProposed = cur0.n
	addTrail("manager", "Closure of the fund proposed.")
}

// ApproveClosure countersigns it, in the same period. Reviewer only. The fund
// closes now if nothing is left, otherwise at the first settlement after.
func ApproveClosure(cur realm) {
	onlyRole(cur, reviewer, "valuation reviewer")
	requireState(stateOpen)
	if closureProposed == 0 || closureProposed != cur0.n {
		panic("no closure proposed in this period")
	}
	closureApproved = true
	addTrail("reviewer", "Closure approved: the fund closes once nothing is left to pay out.")
	closeIfDone(cur)
}
