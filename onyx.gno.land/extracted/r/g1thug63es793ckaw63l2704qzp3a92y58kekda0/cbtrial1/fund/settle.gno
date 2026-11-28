package fund

import (
	"gno.land/p/g1thug63es793ckaw63l2704qzp3a92y58kekda0/cbtrial1/fundmath"
	"gno.land/p/nt/ufmt/v0"
)

const (
	phaseSnapshot = iota
	phaseWindDownSubs
	phaseWindDownReds
	phaseSubscriptions
	phaseFee
	phaseRedemptions
	phaseCrystallise
	phaseDistribute
	phaseFinish
)

// crystDue: a performance-fee crystallisation is due: at least 6 periods
// and at least crystalliseMinDays days since the last one (or since launch);
// a suspension defers it to the next settlement.
var (
	crystDue                       bool
	lastCrystPeriod, lastCrystTime int64
)

// Settle carries out the approved period in batches of at most max items.
// Anyone may call it until the period is closed and the next one opens.
//
// Normal period: the fees are accrued and the NAV struck on the opening
// shares; then subscriptions are issued, the fees paid, redemptions paid,
// then the performance fees on those redemptions (after every redemption
// payment, so they never use cash the gate gave to a redemption; what does
// not fit is owed) and, when due, the performance fee crystallised for every
// holder, all at that NAV. The set of orders dealt is fixed at the first call.
//
// Wind-down: subscriptions are refunded (except held ones) and requests
// closed, in batches; the fees are paid, the performance fee crystallised,
// and all available cash paid out pro rata. A restricted holder's payment is
// set aside for that holder, out of NAV, until the restriction is lifted.
func Settle(cur realm, max int64) string {
	requireLaunched()
	requireState(stateSettling)
	if max < 1 || max > 100 {
		panic("max must be 1 to 100")
	}
	budget := max
	for budget > 0 {
		switch cur0.phase {
		case phaseSnapshot:
			snapshot(cur)
			cur0.cursor = ""
			if windingDown {
				cur0.phase = phaseWindDownSubs
			} else {
				cur0.phase = phaseSubscriptions
			}
			budget--
		case phaseWindDownSubs:
			if windDownSubsBatch(cur, &budget) {
				cur0.cursor = ""
				cur0.phase = phaseWindDownReds
			}
		case phaseWindDownReds:
			if windDownRedsBatch(&budget) {
				cur0.cursor = ""
				cur0.phase = phaseFee
			}
		case phaseSubscriptions:
			if issueBatch(cur, &budget) {
				cur0.phase = phaseFee
			}
		case phaseFee:
			payFees(cur)
			cur0.cursor = ""
			switch {
			case windingDown && cur0.crystallise:
				cur0.phase = phaseCrystallise
			case windingDown && cur0.distribute:
				cur0.phase = phaseDistribute
			case windingDown:
				cur0.phase = phaseFinish
			default:
				cur0.phase = phaseRedemptions
			}
			budget--
		case phaseRedemptions:
			if redeemBatch(cur, &budget) {
				cur0.cursor = ""
				payPerformanceFees(cur)
				if cur0.crystallise {
					cur0.phase = phaseCrystallise
				} else {
					cur0.phase = phaseFinish
				}
			}
		case phaseCrystallise:
			if crystalliseBatch(cur, &budget) {
				cur0.cursor = ""
				if windingDown && cur0.distribute {
					cur0.phase = phaseDistribute
				} else {
					cur0.phase = phaseFinish
				}
			}
		case phaseDistribute:
			if distributeBatch(cur, &budget) {
				cur0.phase = phaseFinish
			}
		case phaseFinish:
			finish(cur)
			return "period settled"
		}
	}
	return "more to settle: call Settle again"
}

// canDeal reports whether a holder's orders may be dealt now.
func canDeal(w, payee address, via bool) bool {
	if held(w, payee) {
		return false
	}
	if via {
		return isEligible(nomineeAddr)
	}
	return isEligible(w)
}

func holderPPS(h *holder) int64 {
	return fundmath.PerformanceFeePerShare(cur0.navps, h.hwm, PerfFeeBps)
}

// snapshot fixes what this period deals.
func snapshot(cur realm) {
	S, nav := cur0.sharesOpen, cur0.nav
	if cur0.n-lastCrystPeriod >= CrystalliseEvery && now()-lastCrystTime >= crystalliseMinDays*86400 {
		crystDue = true
	}
	// The last investor asking for everything starts the wind-down, also
	// while the NAV is low (review 4, m3), but not during a board suspension.
	if !windingDown && !isSuspended() {
		openReds.Iterate("", "", func(k string, _ any) bool {
			r := reds.Get(k).(*redemption)
			h := getHolder(r.wallet)
			// A compulsory redemption does not count: one key (the officer)
			// cannot end the fund that way (review 2, m3).
			if r.full && !r.compulsory && !held(r.wallet, r.payee) && h.shares == S && S > 0 {
				windingDown = true
				windDownReason = "last-investor"
				addTrail("settlement", "The last investor asked to redeem everything: the fund is wound down.")
				return true
			}
			return false
		})
	}
	// A NAV per share below 1 tUSD, or a NAV of zero or less, deals nothing
	// outside a wind-down; the period still completes (review 3, I3).
	cur0.suspended = isSuspended() || (cur0.lowNAV && !windingDown)
	if windingDown {
		// Refunds and closed requests follow in batches (review 2, m1).
		cur0.distribute = !cur0.suspended
		cur0.crystallise = !cur0.suspended
		return
	}
	if cur0.suspended {
		addTrail("settlement", ufmt.Sprintf("Period %d: dealing suspended; every order waits for the first NAV after the suspension.", cur0.n))
		return
	}
	cur0.crystallise = crystDue
	var dealtCash int64
	var zero []*subscription
	activeSubs.Iterate("", "", func(k string, _ any) bool {
		s := subs.Get(k).(*subscription)
		if s.status != subApproved || !canDeal(s.wallet, s.payee, s.viaNominee) {
			return false // waits
		}
		q := fundmath.SharesForSubscription(s.amount, S, nav, Par)
		if q == 0 {
			zero = append(zero, s)
			return false
		}
		s.dealtIn, s.shares = cur0.n, q
		dealtCash += s.amount
		return false
	})
	for _, s := range zero { // an order that rounds to zero shares is refunded
		closeSub(cur, s, true)
	}
	type item struct {
		id, opening, pps int64
		req              fundmath.Request
	}
	var comp, gated []item
	openReds.Iterate("", "", func(k string, _ any) bool {
		r := reds.Get(k).(*redemption)
		if r.dealPeriod > cur0.n || held(r.wallet, r.payee) {
			return false
		}
		h := getHolder(r.wallet)
		pps := holderPPS(h)
		net := fundmath.ValueOf(h.shares, S, nav) - fundmath.MulDivDown(h.shares, pps, u)
		lots := r.lots
		if r.full || r.compulsory {
			lots = 0
		}
		req := fundmath.Classify(lots, net, Lot, MinHolding)
		req.Deferred = r.placedPeriod < cur0.n
		it := item{id: r.id, opening: h.shares, pps: pps, req: req}
		if r.compulsory {
			comp = append(comp, it)
		} else {
			gated = append(gated, it)
		}
		return false
	})
	due := totalOwed + cur0.fee
	avail := bookCash + dealtCash - due
	if avail < 0 {
		avail = 0
	}
	// Compulsory redemptions: ahead of the gate; whole when the cash allows,
	// otherwise in whole lots from the cash there is (review 2, m13).
	var compUsed int64
	for _, it := range comp {
		f := &fill{redID: it.id, compulsory: true, pps: it.pps, openingShares: it.opening, full: true}
		rem := avail - compUsed
		if it.req.Value <= rem {
			f.paid, f.done = it.req.Value, true
			compUsed += it.req.Value
		} else if rem >= Lot {
			f.lots = rem / Lot
			f.paid = f.lots * Lot
			compUsed += f.paid
		}
		cur0.fills.Set(pad(it.id), f)
	}
	left := avail - compUsed
	capacity := fundmath.MulDivDown(nav, GateBps, fundmath.BpsDenominator)
	if capacity < Lot {
		capacity = Lot // never less than one lot
	}
	if left < capacity {
		capacity = left
	}
	if len(gated) == 0 {
		capacity = 0
	}
	cur0.capacity = capacity
	reqs := make([]fundmath.Request, len(gated))
	for i, it := range gated {
		reqs[i] = it.req
	}
	fills := fundmath.AllocateGate(reqs, capacity, left, Lot, MinHolding)
	for i, f := range fills {
		it := gated[i]
		cur0.fills.Set(pad(it.id), &fill{redID: it.id, pps: it.pps, openingShares: it.opening, full: it.req.Full, lots: f.Lots, paid: f.Paid, done: f.Done})
	}
}

// windDownSubsBatch refunds the subscriptions in escrow at the start of a
// wind-down, in batches. A held (restricted) one stays in escrow; the fund
// cannot close until it is refunded after the restriction is lifted.
func windDownSubsBatch(cur realm, budget *int64) bool {
	var batch []*subscription
	visited := int64(0)
	finished := true
	activeSubs.Iterate(cur0.cursor, "", func(k string, _ any) bool {
		if k == cur0.cursor {
			return false
		}
		if visited >= *budget {
			finished = false
			return true
		}
		visited++
		s := subs.Get(k).(*subscription)
		if !held(s.wallet, s.payee) {
			batch = append(batch, s)
		}
		cur0.cursor = k
		return false
	})
	for _, s := range batch {
		closeSub(cur, s, true)
	}
	*budget -= visited
	if visited == 0 && finished {
		*budget--
	}
	return finished
}

// windDownRedsBatch closes the open redemption requests: the wind-down
// distributions replace them.
func windDownRedsBatch(budget *int64) bool {
	var batch []*redemption
	finished := true
	openReds.Iterate(cur0.cursor, "", func(k string, _ any) bool {
		if k == cur0.cursor {
			return false
		}
		if int64(len(batch)) >= *budget {
			finished = false
			return true
		}
		batch = append(batch, reds.Get(k).(*redemption))
		cur0.cursor = k
		return false
	})
	for _, r := range batch {
		closeRed(r)
		addTrail("settlement", ufmt.Sprintf("Redemption request #%d replaced by the wind-down distributions.", r.id))
	}
	*budget -= int64(len(batch))
	if len(batch) == 0 && finished {
		*budget--
	}
	return finished
}

func issueBatch(cur realm, budget *int64) bool {
	var batch []*subscription
	finished := true
	activeSubs.Iterate(cur0.cursor, "", func(k string, _ any) bool {
		if k == cur0.cursor {
			return false
		}
		if int64(len(batch)) >= *budget {
			finished = false
			return true
		}
		s := subs.Get(k).(*subscription)
		if s.status == subApproved && s.dealtIn == cur0.n {
			batch = append(batch, s)
		}
		cur0.cursor = k
		return false
	})
	for _, s := range batch {
		esc := cur.Sub(escrowSub)
		checkErr(token.RealmTeller(0, esc).Transfer(0, esc, cashAddr(), s.amount))
		escrowBook -= s.amount
		approvedEscrow -= s.amount
		bookCash += s.amount
		activeSubs.Remove(pad(s.id))
		subs.Remove(pad(s.id))
		h := getHolder(s.wallet)
		h.hwm = fundmath.BlendHWM(h.shares, h.hwm, s.shares, cur0.navps)
		addShares(h, s.shares)
		h.cost += s.amount
		addNote(h, noteSubscription, s.shares, 0, s.amount, s.amount, false)
		if fundmath.MulDivDown(h.shares, cur0.navps, u) >= MinHolding {
			notices.Remove(s.wallet.String()) // topped up: the notice lapses
			pendingMin.Remove(s.wallet.String())
		}
		h.lastIssuedPeriod = cur0.n
		h.activeSub = 0
		cur0.subsIssued++
		cur0.subsAmount += s.amount
		addTrail("settlement", ufmt.Sprintf("Subscription #%d: %s shares issued for %s tUSD.", s.id, fmtAmt(s.shares), fmtAmt(s.amount)))
	}
	*budget -= int64(len(batch))
	if len(batch) == 0 && finished {
		*budget-- // count the empty pass
	}
	return finished
}

// payFees pays the period's scheduled fees and expenses, and anything owed,
// as far as the cash goes; the rest is owed.
func payFees(cur realm) {
	orgLeft -= cur0.orgFee
	m, a, b := payCreditors(cur, cur0.mgmtFee+cur0.orgFee, cur0.adminFee, cur0.bankFee)
	if m+a+b > 0 || totalOwed > 0 {
		addTrail("settlement", ufmt.Sprintf("Fees paid: manager %s (management and set-up costs), administration %s, deposit bank %s%s.",
			fmtAmt(m), fmtAmt(a), fmtAmt(b), owedNote(totalOwed)))
	}
}

// payCreditors pays the manager, the administrator and the bank what each is
// due (this period's fee plus anything owed). If the cash does not cover all
// of it, each is paid pro rata and the rest stays owed: no payee comes first
// (review 4, I1).
func payCreditors(cur realm, mgr, adm, bnk int64) (m, a, b int64) {
	pm, pa, pb := manager, getProvider("ADMIN"), getProvider("BANK")
	dm := addChecked(owedTo(pm), mgr)
	da := addChecked(owedTo(pa), adm)
	db := addChecked(owedTo(pb), bnk)
	total := addChecked(addChecked(dm, da), db)
	if total == 0 {
		return 0, 0, 0
	}
	cash := bookCash
	if cash < 0 {
		cash = 0
	}
	if cash >= total {
		return payOrOwe(cur, pm, mgr), payOrOwe(cur, pa, adm), payOrOwe(cur, pb, bnk)
	}
	m = fundmath.MulDivDown(dm, cash, total)
	a = fundmath.MulDivDown(da, cash, total)
	b = fundmath.MulDivDown(db, cash, total)
	if r := cash - m - a - b; r > 0 && m+r <= dm {
		m += r // rounding (at most 2 micro-units), so no cash is left idle
	}
	payPart(cur, pm, dm, m)
	payPart(cur, pa, da, a)
	payPart(cur, pb, db, b)
	return m, a, b
}

// payPart pays p of a payee's due d now; the rest is owed.
func payPart(cur realm, payee address, d, p int64) {
	prev := owedTo(payee)
	if p > 0 {
		c := cur.Sub(cashSub)
		checkErr(token.RealmTeller(0, c).Transfer(0, c, payee, p))
		bookCash -= p
	}
	if d-p == 0 {
		owed.Remove(payee.String())
	} else {
		owed.Set(payee.String(), d-p)
	}
	totalOwed += d - p - prev
}

func owedNote(v int64) string {
	if v > 0 {
		return "; " + fmtAmt(v) + " owed in total"
	}
	return ""
}

func redeemBatch(cur realm, budget *int64) bool {
	var batch []*fill
	finished := true
	cur0.fills.Iterate(cur0.cursor, "", func(k string, v any) bool {
		if k == cur0.cursor {
			return false
		}
		if int64(len(batch)) >= *budget {
			finished = false
			return true
		}
		batch = append(batch, v.(*fill))
		cur0.cursor = k
		return false
	})
	S, nav, navps := cur0.sharesOpen, cur0.nav, cur0.navps
	for _, f := range batch {
		r := getRed(f.redID)
		if held(r.wallet, r.payee) {
			continue // restricted during settlement: held, carried
		}
		if f.paid == 0 && !f.done {
			continue // nothing this period: carried
		}
		if f.paid > bookCash {
			// Cannot happen: the gate reserves the payments and the performance
			// fees are paid after them. Carried rather than overdrawn.
			addTrail("settlement", ufmt.Sprintf("Redemption request #%d carried: not enough recorded cash.", r.id))
			continue
		}
		h := getHolder(r.wallet)
		var cancel int64
		switch {
		case f.full && f.done:
			cancel = f.openingShares // the whole holding, whatever the rounding
		case f.pps == 0:
			cancel = fundmath.SharesToCancel(f.paid, S, nav)
		default:
			cancel = fundmath.MulDivUp(f.paid, u, navps-f.pps)
		}
		if cancel > h.shares {
			cancel = h.shares
		}
		perf := fundmath.MulDivDown(cancel, f.pps, u)
		costOff := takeCost(h, cancel)
		removeShares(h, cancel)
		nk := noteRedemption
		if f.compulsory {
			nk = noteCompulsory
		}
		addNote(h, nk, cancel, perf, f.paid, costOff, false)
		if f.paid > 0 {
			c := cur.Sub(cashSub)
			checkErr(token.RealmTeller(0, c).Transfer(0, c, r.payee, f.paid))
			bookCash -= f.paid
		}
		cur0.perfDue += perf // paid after every redemption payment
		cur0.perfFees += perf
		r.paid += f.paid
		cur0.redsPaid += f.paid
		cur0.sharesCancelled += cancel
		done := f.done
		if !f.full {
			r.lots -= f.lots
		}
		kind := "Redemption"
		if f.compulsory {
			kind = "Compulsory redemption"
		}
		addTrail("settlement", ufmt.Sprintf("%s #%d: %s tUSD paid, performance fee %s, %s shares cancelled%s.", kind, r.id, fmtAmt(f.paid), fmtAmt(perf), fmtAmt(cancel), carryNote(r, done)))
		if done {
			closeRed(r)
			prune(h)
		}
	}
	*budget -= int64(len(batch))
	if len(batch) == 0 && finished {
		*budget--
	}
	return finished
}

// payPerformanceFees pays the performance fees charged on this period's
// redemptions, once every redemption has been paid (review 2, B1). What the
// cash cannot cover is owed to the manager.
func payPerformanceFees(cur realm) {
	if cur0.perfDue == 0 {
		return
	}
	p := payOrOwe(cur, manager, cur0.perfDue)
	addTrail("settlement", ufmt.Sprintf("Performance fees on redemptions paid: %s tUSD%s.", fmtAmt(p), owedNote(totalOwed)))
	cur0.perfDue = 0
}

func carryNote(r *redemption, done bool) string {
	if done {
		return ""
	}
	if r.full {
		return "; the rest is deferred to the next period"
	}
	return ufmt.Sprintf("; %d lot(s) deferred to the next period", r.lots)
}

// holderBatch visits up to budget holders after the cursor.
func holderBatch(budget *int64) ([]*holder, bool) {
	var batch []*holder
	finished := true
	holders.Iterate(cur0.cursor, "", func(k string, v any) bool {
		if k == cur0.cursor {
			return false
		}
		if int64(len(batch)) >= *budget {
			finished = false
			return true
		}
		batch = append(batch, v.(*holder))
		cur0.cursor = k
		return false
	})
	*budget -= int64(len(batch))
	if len(batch) == 0 && finished {
		*budget--
	}
	return batch, finished
}

// crystalliseBatch charges every holder above their high-water mark 20% of
// the gain, by cancelling shares worth the fee, and moves the mark up.
func crystalliseBatch(cur realm, budget *int64) bool {
	batch, finished := holderBatch(budget)
	navps := cur0.navps
	for _, h := range batch {
		if h.shares == 0 {
			continue
		}
		pps := holderPPS(h)
		if pps == 0 {
			continue
		}
		fee := fundmath.MulDivDown(h.shares, pps, u)
		c := fundmath.MulDivUp(fee, u, navps)
		if c > h.shares {
			c = h.shares
		}
		removeShares(h, c) // the cost base stays: the fee lowers the gain
		addNote(h, noteCrystallisation, c, fee, 0, 0, false)
		if fee > 0 {
			payOrOwe(cur, manager, fee)
			cur0.perfFees += fee
		}
		h.hwm = navps
	}
	if finished {
		crystDue = false
		lastCrystPeriod, lastCrystTime = cur0.n, now()
		addTrail("settlement", ufmt.Sprintf("Performance fee crystallised at NAV per share %s: %s tUSD in total this period.", fmtAmt(navps), fmtAmt(cur0.perfFees)))
	}
	return finished
}

// distributeBatch pays all available cash pro rata to every holder who is
// not restricted (wind-down). When every instrument is at zero, the last
// distribution pays each such holder the full value and cancels all shares.
func distributeBatch(cur realm, budget *int64) bool {
	if !cur0.distInit {
		cur0.distInit = true
		cur0.distS = sharesInIssue
		cur0.distNAV = bookCash + instrumentsTotal() - totalOwed
		cur0.distCash = bookCash - totalOwed
		if cur0.distCash < 0 {
			cur0.distCash = 0
		}
		cur0.final = instrumentsTotal() == 0
		// After the final distribution, cash recorded later (a late recovery)
		// belongs to the holders of the final distribution (review 3, I2).
		cur0.recovery = cur0.distS == 0 && finalShares > 0 && cur0.distCash > dustBound()
		// Nothing left for the shareholders: the creditors are paid first
		// (review 3, I3; the owner's decision).
		cur0.insolvent = cur0.distS > 0 && cur0.final && cur0.distNAV <= 0
	}
	switch {
	case cur0.distS == 0:
		return afterFinalBatch(cur, budget)
	case cur0.insolvent:
		return insolventBatch(budget)
	case cur0.distNAV <= 0:
		return true // nothing to pay out until the instruments are sold or written off
	}
	batch, finished := holderBatch(budget)
	for _, h := range batch {
		isHeld := held(h.addr, h.payee)
		if !isHeld {
			releaseHeld(cur, h) // a payment set aside before the restriction was lifted
		}
		if h.shares == 0 {
			if !isHeld {
				prune(h)
			}
			continue
		}
		var pay, cancel int64
		if cur0.final {
			pay = fundmath.ValueOf(h.shares, cur0.distS, cur0.distNAV)
			cancel = h.shares
			recordFinal(h, cancel)
		} else {
			pay = fundmath.MulDivDown(cur0.distCash, h.shares, cur0.distS)
			if pay == 0 {
				continue
			}
			cancel = fundmath.MulDivUp(pay, cur0.distS, cur0.distNAV)
			if cancel > h.shares {
				cancel = h.shares
			}
		}
		if pay > bookCash {
			pay = bookCash
		}
		costOff := takeCost(h, cancel)
		removeShares(h, cancel)
		addNote(h, noteDistribution, cancel, 0, pay, costOff, isHeld && pay > 0)
		if pay > 0 && isHeld {
			// Set aside for the restricted holder: out of NAV, paid when the
			// restriction is lifted (review 2, I3).
			setHeld(h.addr, heldOf(h.addr)+pay)
			totalHeld += pay
			bookCash -= pay
		} else if pay > 0 {
			c := cur.Sub(cashSub)
			checkErr(token.RealmTeller(0, c).Transfer(0, c, h.payee, pay))
			bookCash -= pay
		}
		cur0.redsPaid += pay
		cur0.sharesCancelled += cancel
		if !isHeld {
			prune(h)
		}
	}
	return finished
}

func finish(cur realm) {
	lastNAV = bookCash + instrumentsTotal() - totalOwed
	history.Set(pad(cur0.n), &record{
		n: cur0.n, gross: cur0.gross, fee: cur0.fee, perfFee: cur0.perfFees, nav: cur0.nav, navps: cur0.navps, sharesOpen: cur0.sharesOpen,
		subsAmount: cur0.subsAmount, redsPaid: cur0.redsPaid, capacity: cur0.capacity, sharesAfter: sharesInIssue,
		cashAfter: bookCash, navAfter: lastNAV, proposalNo: cur0.proposalNo, sourceRef: cur0.sourceRef, height: heightNow(), valuedAt: cur0.valuedAt,
	})
	verb := "redeemed"
	if windingDown {
		verb = "paid out in the wind-down"
	}
	addTrail("settlement", ufmt.Sprintf("Period %d settled: %s tUSD subscribed, %s tUSD %s, %s shares in issue, NAV after settlement %s.",
		cur0.n, fmtAmt(cur0.subsAmount), fmtAmt(cur0.redsPaid), verb, fmtAmt(sharesInIssue), fmtAmt(lastNAV)))
	if windingDown && cur0.final && sharesInIssue == 0 {
		if closeIfDone(cur) {
			return
		}
		addTrail("settlement", "Every holder is paid, but money is still held or still to be paid out; the fund closes once it is paid.")
	}
	cur0 = period{n: cur0.n + 1, state: stateOpen, openedAt: now()}
}

// closeIfDone closes a wound-down fund once nothing is left for anyone: no
// shares, no subscription in escrow and no payment held for a restricted
// holder (review 2, B2). Rounding dust and anything owed go to the payees.
func closeIfDone(cur realm) bool {
	// The fund stays in liquidation until the manager and the reviewer approve
	// its closure, so a late recovery always has somewhere to go (review 4,
	// I2); and never while an instrument is still on the books.
	if !windingDown || !closureApproved || sharesInIssue != 0 || activeSubs.Size() != 0 || totalHeld != 0 || instrumentsTotal() != 0 {
		return false
	}
	dust := bookCash - totalOwed
	if finalShares > 0 && dust > dustBound() {
		return false // money to pay out first, at the next distribution
	}
	var payees []address
	owed.Iterate("", "", func(k string, _ any) bool {
		payees = append(payees, address(k))
		return false
	})
	if bookCash >= totalOwed {
		for _, p := range payees {
			payOrOwe(cur, p, 0)
		}
		if dust > 0 {
			payOrOwe(cur, manager, dust)
			addTrail("settlement", "Rounding dust paid to the manager: "+fmtAmt(dust)+" tUSD.")
		}
	} else {
		// Not enough for every creditor: each is paid pro rata, and the rest
		// of what is owed is written off.
		cash, total := bookCash, totalOwed
		for _, p := range payees {
			share := fundmath.MulDivDown(owedTo(p), cash, total)
			if share > 0 {
				c := cur.Sub(cashSub)
				checkErr(token.RealmTeller(0, c).Transfer(0, c, p, share))
				bookCash -= share
			}
			owed.Remove(p.String())
		}
		addTrail("settlement", "Creditors paid pro rata: "+fmtAmt(cash-bookCash)+" tUSD of "+fmtAmt(total)+" tUSD owed; the rest is written off.")
		totalOwed = 0
		if bookCash > 0 {
			payOrOwe(cur, manager, bookCash) // rounding
		}
	}
	lastNAV = 0
	closedAt = now()
	cur0 = period{n: cur0.n, state: stateClosed}
	addTrail("settlement", "The fund is closed.")
	return true
}

// ReleaseHeldPayment pays a wind-down payment that was set aside for a
// restricted holder, once the restriction is lifted. Anyone may call it; the
// money goes only to the holder's own payee. Not while a period is settling.
// If nothing else is left, the fund then closes.
func ReleaseHeldPayment(cur realm, holderAddr address) {
	requireLaunched()
	if cur0.state == stateSettling {
		panic("not allowed in state Settling")
	}
	h := getHolder(holderAddr)
	if h == nil || heldOf(holderAddr) == 0 {
		panic("nothing held for this holder")
	}
	if held(h.addr, h.payee) {
		panic("the holder is still restricted")
	}
	releaseHeld(cur, h)
	prune(h)
	if cur0.state == stateOpen {
		closeIfDone(cur)
	}
}

func heldOf(a address) int64 {
	if v := heldCash.Get(a.String()); v != nil {
		return v.(int64)
	}
	return 0
}

func setHeld(a address, v int64) {
	if v == 0 {
		heldCash.Remove(a.String())
	} else {
		heldCash.Set(a.String(), v)
	}
}

func releaseHeld(cur realm, h *holder) {
	v := heldOf(h.addr)
	if v == 0 {
		return
	}
	setHeld(h.addr, 0)
	totalHeld -= v
	c := cur.Sub(cashSub)
	checkErr(token.RealmTeller(0, c).Transfer(0, c, h.payee, v))
	addTrail("settlement", "A held wind-down payment was released: "+fmtAmt(v)+" tUSD.")
}

// recordFinal keeps the final distribution's register: the shares each
// holder had cancelled, for any money recorded afterwards.
func recordFinal(h *holder, cancelled int64) {
	if cancelled <= 0 {
		return
	}
	if h.finalShares == 0 {
		finalHolders++
	}
	h.finalShares += cancelled
	finalShares += cancelled
}

// dustBound is the rounding the final distribution can leave: at most one
// micro-unit per holder paid, plus one.
func dustBound() int64 { return finalHolders + 1 }

// afterFinalBatch runs once no shares are left: it pays, in batches, a late
// recovery pro rata to the holders of the final distribution (a restricted
// holder's part is set aside), and the set-aside payments of holders whose
// restriction has been lifted.
func afterFinalBatch(cur realm, budget *int64) bool {
	batch, finished := holderBatch(budget)
	for _, h := range batch {
		isHeld := held(h.addr, h.payee)
		if cur0.recovery && h.finalShares > 0 {
			pay := fundmath.MulDivDown(cur0.distCash, h.finalShares, finalShares)
			if pay > bookCash {
				pay = bookCash
			}
			if pay > 0 {
				addNote(h, noteRecovery, 0, 0, pay, 0, isHeld)
			}
			if pay > 0 && isHeld {
				setHeld(h.addr, heldOf(h.addr)+pay)
				totalHeld += pay
				bookCash -= pay
			} else if pay > 0 {
				c := cur.Sub(cashSub)
				checkErr(token.RealmTeller(0, c).Transfer(0, c, h.payee, pay))
				bookCash -= pay
			}
			cur0.redsPaid += pay
		}
		if !isHeld {
			releaseHeld(cur, h)
		}
	}
	if finished && cur0.recovery {
		addTrail("settlement", "Money recorded after the final distribution was paid pro rata to its holders: "+fmtAmt(cur0.redsPaid)+" tUSD.")
	}
	return finished
}

// insolventBatch cancels every share without payment when nothing is left
// for the shareholders; the cash left goes to the creditors at closure.
func insolventBatch(budget *int64) bool {
	batch, finished := holderBatch(budget)
	for _, h := range batch {
		if h.shares == 0 {
			continue
		}
		c := h.shares
		costOff := takeCost(h, c)
		removeShares(h, c)
		addNote(h, noteInsolvency, c, 0, 0, costOff, false)
		recordFinal(h, c)
		cur0.sharesCancelled += c
	}
	if finished {
		addTrail("settlement", "Nothing is left for the shareholders: every share is cancelled, and the cash left is paid to the creditors.")
	}
	return finished
}

// prune removes a register entry with nothing left: no shares, no order and
// nothing held (review 2, m1). Notices go with it.
func prune(h *holder) {
	if h == nil || h.shares != 0 || h.activeSub != 0 || h.openRed != 0 || heldOf(h.addr) != 0 || h.finalShares != 0 {
		return
	}
	holders.Remove(h.addr.String())
	notices.Remove(h.addr.String())
	pendingMin.Remove(h.addr.String())
}
