package fund

import "gno.land/p/nt/ufmt/v0"

// MaxLotsPerRequest bounds a redemption request (1,000,000,000 tUSD);
// fundmath is overflow-safe anyway (review B1).
const MaxLotsPerRequest int64 = 100_000

// ---- direct registration: the investor's own wallet ----

// Subscribe places a subscription of amount tUSD (a multiple of one lot).
// First Approve this realm's address on tUSD for at least amount. The money
// goes to the escrow account until the compliance officer decides. Once
// accepted, a subscription is irrevocable.
func Subscribe(cur realm, amount int64) int64 {
	requireLaunched()
	requireState(stateOpen)
	requireTakingSubscriptions()
	w := cur.Previous().Address()
	if isFundAccount(w) {
		panic("not an investor address")
	}
	if isRole(w) {
		panic("role holders cannot invest")
	}
	if !isEligible(w) {
		panic("wallet is not eligible, or its eligibility has expired")
	}
	return placeSub(cur, w, w, false, amount, false)
}

// CancelSubscription withdraws a subscription the compliance officer has
// not yet accepted, and refunds it. Accepted subscriptions are irrevocable,
// except when the wallet is no longer eligible (the fund cannot deal it), or
// in a period stalled for 7 days in Cut-off or NAV proposed.
func CancelSubscription(cur realm, id int64) {
	requireLaunched()
	requireOpenOrStalled()
	s := getSub(id)
	if s.viaNominee || s.wallet != cur.Previous().Address() {
		panic("not your subscription")
	}
	// An accepted subscription binds the investor while the fund can deal
	// it; if the wallet is no longer eligible, the fund cannot, so the money
	// may come back.
	if s.status != subPending && !stalled() && isEligible(s.wallet) {
		panic("an accepted subscription is irrevocable")
	}
	if held(s.wallet, s.payee) {
		panic("wallet is restricted; the subscription is held")
	}
	closeSub(cur, s, true)
}

// RefundExpired refunds a direct subscription that the compliance officer
// has not decided within the timeout. Anyone may call it; the money goes
// back to the subscriber's wallet. A restricted wallet's subscription is
// held.
func RefundExpired(cur realm, id int64) {
	requireLaunched()
	requireOpenOrStalled()
	s := getSub(id)
	if s.viaNominee || s.status != subPending {
		panic("subscription is not pending")
	}
	if cur0.n-s.placedPeriod < ComplianceTimeoutPeriods {
		panic(ufmt.Sprintf("refundable from period %d", s.placedPeriod+ComplianceTimeoutPeriods))
	}
	if held(s.wallet, s.payee) {
		panic("wallet is restricted; the subscription is held")
	}
	closeSub(cur, s, true)
}

// RequestRedemption asks to redeem `lots` lots (0 = the whole holding) at
// this period's NAV. A request is irrevocable once placed. Shares stay
// invested until it is filled.
func RequestRedemption(cur realm, lots int64) int64 {
	requireLaunched()
	requireState(stateOpen)
	requireNotWindingDown()
	w := cur.Previous().Address()
	return placeRed(w, w, false, lots, false, "")
}

// ---- withdrawal at the investor's request ("save as determined by the fund") ----
//
// Orders are irrevocable: the investor cannot cancel one, but may ask the
// fund to withdraw it. The request is on-chain, so the administrator can
// withdraw only an order whose holder asked in this period (review 2, I6):
// one key cannot cancel orders nobody asked to cancel.

// AskToWithdraw asks the fund to withdraw the caller's open order (its
// subscription in escrow, or its redemption request). Investor only.
func AskToWithdraw(cur realm) {
	requireLaunched()
	requireState(stateOpen)
	assertMasterKey()
	askToWithdraw(cur.Previous().Address(), "investor")
}

// AskToWithdrawFor does the same for nominee sub-account `sub`. The nominee
// realm only.
func AskToWithdrawFor(cur realm, sub string) {
	requireNominee(cur)
	requireState(stateOpen)
	checkCommitment(sub)
	askToWithdraw(subAccountAddr(sub), "nominee")
}

func askToWithdraw(w address, role string) {
	h := getHolder(w)
	switch {
	case h != nil && h.activeSub != 0:
		s := getSub(h.activeSub)
		s.askedPeriod = cur0.n
		addTrail(role, ufmt.Sprintf("Withdrawal of subscription #%d requested.", s.id))
	case h != nil && h.openRed != 0:
		r := getRed(h.openRed)
		if r.compulsory {
			panic("a compulsory redemption cannot be withdrawn")
		}
		r.askedPeriod = cur0.n
		addTrail(role, ufmt.Sprintf("Withdrawal of redemption request #%d requested.", r.id))
	default:
		panic("no open order")
	}
}

// WithdrawSubscription withdraws and refunds a subscription whose investor
// asked for it in this period, with a reason code on the trail.
// Administrator only, while the period is open.
func WithdrawSubscription(cur realm, id int64, reasonCode string) {
	onlyRole(cur, administrator, "administrator")
	requireState(stateOpen)
	checkCode(reasonCode)
	s := getSub(id)
	if s.askedPeriod != cur0.n {
		panic("the investor has not asked to withdraw it in this period")
	}
	if held(s.wallet, s.payee) {
		panic("wallet is restricted; the subscription is held")
	}
	addTrail("administrator", ufmt.Sprintf("Subscription #%d withdrawn at the investor's request: %s.", id, reasonCode))
	closeSub(cur, s, true)
}

// WithdrawRedemption withdraws a redemption request whose investor asked for
// it in this period, with a reason code. Administrator only, while the
// period is open.
// A compulsory redemption cannot be withdrawn this way.
func WithdrawRedemption(cur realm, id int64, reasonCode string) {
	onlyRole(cur, administrator, "administrator")
	requireState(stateOpen)
	checkCode(reasonCode)
	r := getRed(id)
	if r.compulsory {
		panic("a compulsory redemption cannot be withdrawn")
	}
	if r.askedPeriod != cur0.n {
		panic("the investor has not asked to withdraw it in this period")
	}
	closeRed(r)
	addTrail("administrator", ufmt.Sprintf("Redemption request #%d withdrawn at the investor's request: %s.", id, reasonCode))
}

// ---- nominee route: orders for pseudonymous sub-accounts ----

func requireNominee(cur realm) {
	assertMasterKey()
	requireLaunched()
	if nomineePath == "" || cur.Previous().PkgPath() != nomineePath {
		panic("nominee realm only")
	}
}

// SubscribeFor places a subscription for nominee sub-account `sub` (a
// 64-hex identifier). The nominee realm only, after its batch attestation;
// the money comes from the nominee, which must Approve this realm first.
func SubscribeFor(cur realm, sub string, amount int64) int64 {
	requireNominee(cur)
	requireState(stateOpen)
	requireTakingSubscriptions()
	checkCommitment(sub)
	if !isEligible(nomineeAddr) {
		panic("the nominee is not eligible, or is restricted")
	}
	a := subAccountAddr(sub)
	if !isSubAccount(a) && getStatus(a) != nil {
		panic("this address already has a compliance status") // review 4, m2
	}
	subAccounts.Set(a.String(), true)
	return placeSub(cur, a, nomineeAddr, true, amount, true)
}

// RegisterSubAccountFor records nominee sub-account `sub` in the fund before
// its identifier is handed to the investor, so that no compliance decision
// can ever name it (review 3, m3). The nominee realm only.
func RegisterSubAccountFor(cur realm, sub string) {
	requireNominee(cur)
	checkCommitment(sub)
	a := subAccountAddr(sub)
	if getStatus(a) != nil {
		panic("this address already has a compliance status")
	}
	subAccounts.Set(a.String(), true)
}

// RequestRedemptionFor asks to redeem `lots` lots (0 = all) for nominee
// sub-account `sub`. Proceeds are paid to the nominee. Irrevocable.
func RequestRedemptionFor(cur realm, sub string, lots int64) int64 {
	requireNominee(cur)
	requireState(stateOpen)
	requireNotWindingDown()
	checkCommitment(sub)
	return placeRed(subAccountAddr(sub), nomineeAddr, true, lots, false, "")
}

// CancelFor takes a nominee sub-account's subscription back out of escrow
// in a period stalled for 7 days (orders are otherwise irrevocable).
func CancelFor(cur realm, sub string) {
	requireNominee(cur)
	checkCommitment(sub)
	if !stalled() {
		panic("orders are irrevocable; only a stalled period allows this")
	}
	h := getHolder(subAccountAddr(sub))
	if h == nil || h.activeSub == 0 {
		panic("no subscription in escrow")
	}
	s := getSub(h.activeSub)
	if held(s.wallet, s.payee) {
		panic("the nominee is restricted; the subscription is held")
	}
	closeSub(cur, s, true)
}

// HoldingOf returns a nominee sub-account's shares and their value at the
// last approved NAV per share.
func HoldingOf(sub string) (shares, value int64) {
	checkCommitment(sub)
	return Holding(subAccountAddr(sub))
}

// ---- shared ----

func requireTakingSubscriptions() {
	if subscriptionsClosed {
		panic("the fund is closed to new subscriptions")
	}
	requireNotWindingDown()
}

func requireNotWindingDown() {
	if windingDown || windDownApproved {
		panic("the fund is being wound down")
	}
}

func placeSub(cur realm, w, payee address, via bool, amount int64, approved bool) int64 {
	if amount < Lot || amount%Lot != 0 {
		panic("amount must be a multiple of one lot (10,000 tUSD)")
	}
	if activeSubs.Size() >= MaxOpenSubscriptions {
		panic("too many open subscriptions; try next period")
	}
	h := getHolder(w)
	if h == nil {
		h = &holder{addr: w, payee: payee, viaNominee: via}
		holders.Set(w.String(), h)
	}
	if h.activeSub != 0 {
		panic("this holder already has a subscription in escrow")
	}
	if h.openRed != 0 {
		panic("this holder has an open redemption request")
	}
	nextSub++
	id := nextSub
	s := &subscription{id: id, amount: amount, placedPeriod: cur0.n, wallet: w, payee: payee, viaNominee: via, status: subPending}
	if approved {
		s.status = subApproved
		approvedEscrow += amount
	}
	subs.Set(pad(id), s)
	activeSubs.Set(pad(id), true)
	h.activeSub = id
	escrowBook += amount
	checkErr(token.RealmTeller(0, cur).TransferFrom(0, cur, payee, escrowAddr(), amount))
	role := "investor"
	if via {
		role = "nominee"
	}
	addTrail(role, ufmt.Sprintf("Subscription #%d placed: %s tUSD in escrow.", id, fmtAmt(amount)))
	return id
}

// closeSub refunds a subscription still in escrow and deletes its record,
// so no closed order stays stored against a wallet (review I6). Rejection,
// cancellation and timeout share one trail wording.
func closeSub(cur realm, s *subscription, refund bool) {
	activeSubs.Remove(pad(s.id))
	subs.Remove(pad(s.id))
	escrowBook -= s.amount
	if s.status == subApproved {
		approvedEscrow -= s.amount
	}
	h := getHolder(s.wallet)
	if h != nil && h.activeSub == s.id {
		h.activeSub = 0
	}
	if refund {
		esc := cur.Sub(escrowSub)
		checkErr(token.RealmTeller(0, esc).Transfer(0, esc, s.payee, s.amount))
	}
	addTrail("settlement", ufmt.Sprintf("Subscription #%d closed; refunded.", s.id))
	prune(h)
}

func placeRed(w, payee address, via bool, lots int64, compulsory bool, reason string) int64 {
	if lots < 0 || lots > MaxLotsPerRequest {
		panic("lots must be 0 (whole holding) to 100,000")
	}
	h := getHolder(w)
	if h == nil || h.shares == 0 {
		panic("no shares to redeem")
	}
	if h.openRed != 0 {
		panic("this holder already has an open redemption request")
	}
	if h.activeSub != 0 {
		panic("this holder has a subscription in escrow")
	}
	if openReds.Size() >= MaxOpenRequests {
		panic("too many open redemption requests; try next period")
	}
	nextRed++
	id := nextRed
	r := &redemption{id: id, wallet: w, payee: payee, viaNominee: via, full: lots == 0, lots: lots, placedPeriod: cur0.n, dealPeriod: cur0.n + NoticePeriods, compulsory: compulsory}
	if compulsory {
		r.kind, r.reasonRef = compulsoryKind(reason)
	}
	reds.Set(pad(id), r)
	openReds.Set(pad(id), true)
	h.openRed = id
	what := "the whole holding"
	if lots > 0 {
		what = ufmt.Sprintf("%d lot(s)", lots)
	}
	role := "investor"
	if via {
		role = "nominee"
	}
	if compulsory {
		role = "compulsory"
	}
	addTrail(role, ufmt.Sprintf("Redemption request #%d: %s, dealt from period %d.", id, what, r.dealPeriod))
	return id
}

func closeRed(r *redemption) {
	openReds.Remove(pad(r.id))
	reds.Remove(pad(r.id))
	if h := getHolder(r.wallet); h != nil && h.openRed == r.id {
		h.openRed = 0
	}
}
