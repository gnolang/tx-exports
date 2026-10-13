// Package invoices is on-chain accounts receivable: an issuer records an
// obligation, and the named payer discharges it later, in parts.
//
// # The one idea
//
// Every payment realm in this portfolio, and every escrow and vesting
// package the discovery gate found on either live chain, is PREFUNDED.
// service_market escrows the exact price at purchase. subscriptions
// prepays a whole period. payroll, vesting, fee_split and revshare push
// money that already arrived. In all of them the coins exist before the
// claim on them does.
//
// An invoice inverts that. It is UNFUNDED AT CREATION: the obligation is
// recorded first, and the money may never arrive at all.
//
// That one inversion is the whole realm, and it is visible in the
// arithmetic rather than only in the prose. payroll's invariant carries a
// pool term because an employer funds first:
//
//	payroll:  Held() == TotalPooled() + Liabilities() + Surplus()
//	invoices: Held() ==                 Liabilities() + Surplus()
//
// There is no pool here, and no reserve, because at the moment an invoice
// is issued this realm holds nothing on its behalf and promises nothing.
// Issuing costs the issuer a storage deposit and nothing else.
//
// # What being unfunded forces
//
// Two features that would be decoration on a prefunded rail are load-
// bearing here, and they are the reason this is a realm rather than a
// field on an existing one:
//
//   - PARTIAL SETTLEMENT. When the money is already in escrow, "pay" is a
//     release of a known amount and partiality is meaningless. When it is
//     not, a payer who can send 60% today is the ordinary case. Pay
//     accepts any amount up to the outstanding balance, repeatedly.
//   - AN OVERDUE STATE. A prefunded claim cannot be late. An unfunded one
//     can, so lateness is a state other realms can read and act on. That
//     readable state is the integration surface this realm exists to
//     provide, in the same way subscriptions exists to provide Entitled.
//
// # No escrow, no acceptance, no arbitration
//
// An invoice is billed for work already done, so there is nothing for this
// realm to hold back. Money paid is credited to the issuer's ledger
// balance in the same transaction. There is no acceptance window and no
// release step — those belong to service_market, whose model is the
// opposite one.
//
// Consequently this realm DOES NOT arbitrate. A payer who disputes a bill
// simply does not pay it, and the invoice goes overdue. That is the
// mechanism off chain too, and inventing a dispute path here would make
// this a worse copy of service_market rather than a complement to it.
//
// # Payment is pull, in the direction that cannot fail
//
// Pay credits the issuer's ledger balance; the issuer later calls Claim.
// The push alternative — paying the issuer inside the payer's own
// transaction — would let the issuer's address decide whether the PAYER's
// settlement succeeds. An issuer that is a realm which panics on receipt,
// or is simply unable to accept, would make its own invoices unpayable and
// the failure would land on the payer. Pull puts every failure on the
// party who owns it.
//
// # Anyone may issue an invoice naming anyone. Read this before trusting a total.
//
// There is no permission to bill someone, because requiring one would mean
// a registry of who may invoice whom, which is a different application.
// The honest consequence is stated here rather than discovered later:
//
//	AN UNPAID INVOICE IS AN UNVERIFIED CLAIM BY ITS ISSUER.
//
// So this realm deliberately exposes NO global "what does this address
// owe" aggregate. Such a number would be the sum of every stranger's
// self-reported assertion, and reading it as a credit signal is the error
// the getter's existence would invite. What it exposes instead is
// ISSUER-SCOPED: OutstandingFrom and OverdueFrom answer "what does this
// payer owe THIS issuer", which is the question a consumer realm can
// actually act on, because a consumer gating its own service on its own
// unpaid bills is trusting only itself.
//
// Two bounds back that up mechanically. Issuing costs a storage deposit
// paid by the ISSUER, so volume is not free to the party who benefits from
// it; and MaxRecordsPerIssuer caps one issuer's STORED records, which is an
// availability bound on that issuer's own namespace and no one else's.
// Neither bound makes an unpaid claim true, and they are not presented as
// doing so.
//
// Both bounds are PER ISSUER, and the global total is not bounded. Sybil
// issuers multiply it: N funded addresses yield N*MaxRecordsPerIssuer
// records, and the per-record deposit paid by each is the only thing making
// that expensive. Two consequences follow, stated here rather than
// discovered:
//
//   - A payer named on an invoice CANNOT remove it. Void is issuer-only,
//     because forgiving a debt is the issuer's to do, and Release refuses an
//     open record; so a stranger's open invoice naming you persists until
//     that stranger voids it. What absorbs this is the design above rather
//     than a bound: no global aggregate reads such a record, and the
//     issuer-scoped getters a consumer realm actually calls stay gas-bounded
//     at MaxRecordsPerIssuer, so a victim's reads are never charged for an
//     attacker's volume. The residual harm is an off-chain reader's, and the
//     unverified-claim warning above is what it is for.
//   - An issuer record is never reclaimed. Release decrements its count but
//     does not delete the issuers entry, because `issued` and `invoiced` are
//     LIFETIME figures that IssuedOf reports, and deleting the entry would
//     reset them to zero and make that getter lie. Global state therefore
//     grows monotonically. Keeping an honest counter is worth more than
//     reclaiming one AVL node.
//
// The cap counts STORED records rather than OPEN ones, and the difference
// is load-bearing rather than a detail. OutstandingFrom, OverdueFrom and
// HasOverdueFrom — the getters a consumer realm calls, and therefore the
// ones whose gas cost is someone else's problem — iterate an issuer's whole
// prefix, settled and voided records included, because a settled record is
// not removed until Release. A cap on open invoices alone would bound the
// obligations and leave that iteration unbounded: an issuer could issue and
// void repeatedly, keeping `open` at zero while their prefix grew without
// limit, until a consumer's read ran out of gas. Capping what is stored
// bounds both, since open can never exceed stored.
//
// Finding "every invoice naming me" is therefore an off-chain indexer's
// job: on chain it would be an unbounded iteration over every issuer that
// has ever billed anyone, and the answer would be untrustworthy anyway.
//
// # STORAGE
//
// An issuer record is paid for by that issuer's first Issue; an invoice
// record by the Issue that creates it. Release removes a finished invoice
// and the chain refunds the freed deposit to the transaction that frees
// it, which is the standing incentive to tidy up a record that is no
// longer anyone's business.
//
// # What this realm does NOT do
//
//   - It does not verify that work happened, value it, or arbitrate.
//   - It holds ugnot and only ugnot.
//   - It has no admin. The deploying namespace receives protocol fees and
//     swept surplus and has no other privilege: no setter, no pause, no
//     ability to void an invoice or touch a balance.
package invoices

import (
	"chain"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"strings"

	"gno.land/p/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/coinio"
	"gno.land/p/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/feeledger"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/markdown/sanitize/v0"
)

// RealmPath is this realm's own path, used to build Render links.
const RealmPath = "/r/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/invoices"

// Denom is the only asset this realm holds.
const Denom = "ugnot"

// MaxFeeBps is the hard ceiling on any fee this realm could ever charge,
// enforced by the feeledger the realm is constructed with — a feeBps above
// it is refused by the primitive's own validation, not by a check in this
// file. 500 bps = 5%.
const MaxFeeBps = int64(500)

// SettlementFeeBps is charged on each payment, on the gross, floor-rounded
// in the ISSUER's favour: 100 bps = 1%. It matches the most conservative
// live fee in this portfolio (fee_split, crowdfund, budgets, payroll).
//
// The ISSUER bears it, not the payer: a payment of N reduces the
// outstanding balance by exactly N, and the issuer is credited N minus the
// fee. A payer's debt must be discharged by what the payer sent, or the
// arithmetic of "paid in full" would depend on this realm's fee schedule.
//
// It is a compile-time constant with no setter, so an invoice's economics
// cannot be changed after it is issued.
//
// The fee is floored PER PAYMENT, so splitting a payment can lower the total
// fee. Each payment boundary forfeits at most 1 ugnot, and MinPayment bounds
// how many boundaries an invoice admits. MEASURED on onyx-1, not reasoned:
// 10,990 paid at once charges 109, while ten payments of 1,099 charge 100.
// The beneficiary is the ISSUER, who is credited the difference and does not
// control the payment schedule; the payer gains nothing, because the
// outstanding balance falls by the gross either way. Gas for one extra
// payment costs more than the 1 ugnot it saves, so this is priced out rather
// than prevented, and a colluding issuer/payer pair would spend more to
// exploit it than they recovered.
//
// A final settlement below the fee denominator pays zero fee for that same
// reason and is NOT a separate case: floor(99/100) is 0 whether or not
// MinPayment's settle-exactly clause admitted it, so that clause forfeits
// nothing on its own.
const SettlementFeeBps = int64(100)

// FeeCollector receives withdrawn fees and swept surplus. Compile-time
// constant: there is no setter and no transfer path. It is the deploying
// namespace's address — stated plainly: the operator of this realm.
//
// NOTE FOR ANY RE-NAMESPACED PORT: this is the address-as-data hazard that
// a namespace substitution rewrites silently while every byte-comparison
// still reports the tree faithful, because the rewrite IS the intended
// transformation. Re-state it deliberately per chain; never let it be
// derived.
const FeeCollector = address("g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3")

// MinInvoiceAmount is the smallest invoice that may be issued. Below the
// fee denominator a 1% fee floors to zero, so a smaller invoice would be
// fee-free by accident rather than by design.
const MinInvoiceAmount = int64(1_000)

// MinPayment keeps dust settlements out. It is NOT a floor on the final
// payment: a payment is accepted when it is at least MinPayment OR when it
// settles the invoice exactly. Without that second clause an invoice with
// 300 ugnot outstanding could never be closed, and "unpayable remainder"
// is a worse failure than dust.
const MinPayment = int64(1_000)

// MaxRecordsPerIssuer caps the invoice records one issuer may have STORED
// at once — open, settled and voided alike. It is what makes the
// issuer-scoped getters gas-bounded; see the package doc for why the cap
// counts stored records and not open ones.
//
// Issue is permissionless, so this is an AVAILABILITY BOUND and it is
// documented rather than hidden: an issuer can exhaust their OWN capacity
// and no one else's, because the bound is per-issuer. The cost of filling
// it is gas plus a storage deposit on every record.
//
// Hitting it is self-service to clear: Release is permissionless and the
// chain refunds the freed deposit to whoever calls it, so an issuer at the
// cap can always release their own finished records, and a stranger has a
// standing incentive to do it for them.
const MaxRecordsPerIssuer = 64

// MaxMemoLen bounds the free-text memo, in bytes. The memo is rendered,
// so it is sanitized at the render boundary, never at the write boundary —
// storing what the issuer actually wrote keeps the record honest.
const MaxMemoLen = 256

// Invoice statuses.
const (
	StatusOpen    = "open"
	StatusSettled = "settled"
	StatusVoided  = "voided"
)

type invoice struct {
	id     int64
	issuer address
	payer  address

	// amount is the gross obligation. It never changes: forgiving part of
	// a bill is a Void of the whole remainder, not a rewrite of history.
	amount int64

	// paid is the cumulative gross the payer has sent. It only ever
	// increases, and amount-paid is the outstanding balance.
	paid int64

	// dueHeight is the height at or before which the invoice should be
	// settled. Equal to the issue height means "due on receipt".
	dueHeight int64

	issuedAt int64
	status   string
	memo     string
}

type issuerRec struct {
	// records is how many invoice records this issuer currently has
	// STORED, of any status. It is the figure MaxRecordsPerIssuer caps,
	// and therefore the one that bounds every issuer-scoped getter: it
	// rises on Issue and falls only on Release.
	records int

	// open is how many of those are still open. Informational — a
	// settled or voided record still occupies a slot until Release, so
	// this never gates anything.
	open int

	issued   int64
	invoiced int64
}

var (
	self address

	// invoices holds one record per invoice, keyed issuer|paddedID so an
	// issuer's book is a bounded prefix iteration. The public handle is
	// therefore (issuer, id), the same two-part shape payroll uses.
	invoices = avl.NewTree() // "issuer|%019d" -> *invoice

	// issuers holds one record per address that has ever issued.
	issuers = avl.NewTree() // address string -> *issuerRec

	// ledger holds every issuer's settled-but-unclaimed balance and the
	// fee pot. It is global across invoices on purpose: an issuer billing
	// twenty payers has one balance and one Claim.
	ledger = feeledger.MustNew(MaxFeeBps)

	// nextID is a monotonic counter. IDs are never reused, so a released
	// invoice's id can never be confused with a live one.
	nextID int64 = 1
)

func init() {
	self = unsafe.CurrentRealm().Address()
}

// rejectStraySend aborts when coins are attached to a non-payable call.
// This realm holds funds, so a stray send would become sweepable surplus,
// silently converting a user's coins into operator funds.
func rejectStraySend(cur realm) {
	if !cur.IsCurrent() {
		// Every call site forwards a crossing entrypoint's own live cur,
		// so this cannot fire today; it exists so a future refactor that
		// hands this guard a stale realm value fails closed, not open
		// (coinio names IsCurrent as the guard secondary realm parameters
		// require, and this helper follows that discipline).
		panic("invoices: realm capability is not current")
	}
	if cur.Previous().IsUserCall() && len(unsafe.OriginSend()) > 0 {
		panic("this entrypoint does not accept coins")
	}
}

// --- issuing ---

// Issue records an obligation of `amount` owed by `payer` to the caller,
// to be settled by `dueHeight`. It moves no coins and reserves nothing.
// Returns the invoice id.
//
// dueHeight must not be in the past. A backdated due height would create
// an invoice that is overdue in the transaction that issued it, which is a
// claim about a deadline that was never offered.
func Issue(cur realm, payer address, amount, dueHeight int64, memo string) int64 {
	rejectStraySend(cur)

	// The lowercase clause is load-bearing, and it is carried from budgets'
	// Grant and payroll's Hire (measured on this toolchain, not argued):
	// address.IsValid() defers to crypto.AddressFromBech32, whose decoder
	// lowercases the input BEFORE verifying the checksum, so it returns
	// true for the all-uppercase spelling of a valid address.
	//
	// THE SEVERITY HERE IS THE MILDER OF THE TWO THIS PORTFOLIO HAS
	// MEASURED, and saying which matters. In payroll an uppercase employee
	// is a PERMANENT LOSS: Accrue credits a balance nobody can authenticate
	// as. Here it is a BRICKED RECORD, as in budgets: Pay authenticates the
	// caller against the stored payer, so a non-canonical payer makes the
	// invoice unpayable by everyone, including the person it names. No coins
	// move, nothing is lost but the issuer's own storage deposit and slot.
	// The guard is still worth its line — a record that can never be
	// satisfied and can never be distinguished from a real debt is exactly
	// the untrustworthy total the package doc warns about — but it is not
	// the fund-loss case and must not be cited as one.
	//
	// The check is complete as well as necessary: that decoder rejects
	// mixed case outright, so a valid address has exactly two spellings and
	// refusing every non-lower one leaves precisely the canonical one.
	if !payer.IsValid() || string(payer) != strings.ToLower(string(payer)) {
		panic("payer is not a valid address in canonical (lowercase) form")
	}
	if amount < MinInvoiceAmount {
		panic("amount is below MinInvoiceAmount")
	}
	if len(memo) > MaxMemoLen {
		panic("memo exceeds MaxMemoLen")
	}
	now := runtime.ChainHeight()
	if dueHeight < now {
		panic("dueHeight is in the past")
	}

	issuer := cur.Previous().Address()
	if issuer == payer {
		panic("an issuer cannot invoice themselves")
	}
	key := issuer.String()
	r := getIssuer(key)
	if r == nil {
		r = &issuerRec{}
		issuers.Set(key, r)
	}
	if r.records >= MaxRecordsPerIssuer {
		panic("issuer has too many stored invoices")
	}
	invoiced, ok := checkedAdd(r.invoiced, amount)
	if !ok {
		panic("issuer lifetime total would overflow")
	}

	id := nextID
	nextID++
	invoices.Set(invKey(issuer, id), &invoice{
		id:        id,
		issuer:    issuer,
		payer:     payer,
		amount:    amount,
		paid:      0,
		dueHeight: dueHeight,
		issuedAt:  now,
		status:    StatusOpen,
		memo:      memo,
	})
	r.records++
	r.open++
	r.issued++
	r.invoiced = invoiced

	chain.Emit("Issued", "id", itoa(id), "issuer", key,
		"payer", payer.String(), "amount", itoa(amount),
		"dueHeight", itoa(dueHeight))
	return id
}

// --- settling ---

// Pay settles part or all of an invoice with the attached coins. The named
// payer only. Direct EOA calls with -send only (the receipt-guaranteed
// shape); exactly one positive ugnot coin.
//
// The attached amount must not exceed the outstanding balance. Accepting
// an overpayment would turn a payment into a donation the payer did not
// choose to make and this realm has no path to return, so it is refused
// and the payer keeps their coins.
//
// Returns the outstanding balance remaining after this payment.
func Pay(cur realm, issuer address, id int64) int64 {
	// Receive first and once, per coinio's envelope contract.
	from, amount := coinio.Receive(0, cur, Denom)

	inv := mustInvoice(issuer, id)
	if inv.status != StatusOpen {
		panic("invoice is not open")
	}
	if from != inv.payer {
		panic("only the named payer may pay this invoice")
	}
	outstanding := inv.amount - inv.paid
	if amount > outstanding {
		panic("payment exceeds the outstanding balance")
	}
	if amount < MinPayment && amount != outstanding {
		panic("payment is below MinPayment and does not settle the invoice")
	}

	inv.paid += amount
	remaining := inv.amount - inv.paid
	if remaining == 0 {
		inv.status = StatusSettled
		mustDecOpen(issuer)
	}
	credited, fee := ledger.MustDeposit(issuer.String(), amount, SettlementFeeBps)

	chain.Emit("Paid", "id", itoa(id), "issuer", issuer.String(),
		"payer", from.String(), "amount", itoa(amount),
		"credited", itoa(credited), "fee", itoa(fee),
		"paid", itoa(inv.paid), "outstanding", itoa(remaining),
		"status", inv.status)
	return remaining
}

// Void cancels the unpaid remainder of an invoice. The issuer only — this
// is an issuer forgiving a debt, and nobody else may forgive it for them.
//
// It does NOT reverse payments already made. Coins the payer sent are
// already credited to the issuer's ledger balance and may already have
// been claimed; there is no mechanism on chain to take them back, and
// pretending otherwise in the status would be worse than saying so. A
// voided invoice therefore keeps its `paid` figure, which is what makes
// the record readable afterwards.
//
// Voiding does not remove the record. Release does that.
func Void(cur realm, id int64) {
	rejectStraySend(cur)
	issuer := cur.Previous().Address()
	inv := mustInvoice(issuer, id)
	if inv.status != StatusOpen {
		panic("invoice is not open")
	}
	inv.status = StatusVoided
	mustDecOpen(issuer)
	chain.Emit("Voided", "id", itoa(id), "issuer", issuer.String(),
		"payer", inv.payer.String(), "paid", itoa(inv.paid),
		"forgiven", itoa(inv.amount-inv.paid))
}

// Release removes a finished invoice and frees its storage. Permissionless:
// the chain refunds the freed storage deposit to the caller, which is the
// standing incentive to tidy up a record that is not your own.
//
// It refuses an open invoice, which is what makes it safe to let a stranger
// call: a Release can never destroy an outstanding obligation. An issuer
// who wants a record gone must Void it first, and that leaves an event.
//
// Releasing frees the issuer's slot against MaxRecordsPerIssuer. That is
// the only way a slot is ever freed — settling and voiding do not free
// one, because the record is still stored and still walked by every
// issuer-scoped getter.
func Release(cur realm, issuer address, id int64) {
	rejectStraySend(cur)
	inv := mustInvoice(issuer, id)
	if inv.status == StatusOpen {
		panic("invoice is still open")
	}
	invoices.Remove(invKey(issuer, id))
	r := getIssuer(issuer.String())
	if r == nil || r.records == 0 {
		// Unreachable, and a panic rather than a mask on purpose. See
		// mustDecOpen for the reasoning; the stakes are higher here
		// because `records` is what the cap reads, so masking would cost
		// the issuer a slot permanently and silently.
		panic("invoices: issuer record count desynchronized from the invoice tree")
	}
	r.records--
	chain.Emit("Released", "id", itoa(id), "issuer", issuer.String(),
		"status", inv.status, "paid", itoa(inv.paid))
}

// --- claiming ---

// Claim pays the caller their whole settled balance. The issuer only —
// there is no "claim on behalf of", because that would let a third party
// choose the moment someone else's coins move.
func Claim(cur realm) int64 {
	rejectStraySend(cur)
	who := cur.Previous().Address()
	key := who.String()
	amount := ledger.BalanceOf(key)
	if amount == 0 {
		panic("no balance to claim")
	}
	// Debit first, per coinio's ordering contract: a panic inside coinio
	// aborts the transaction and reverts this debit.
	ledger.MustWithdraw(key, amount)
	coinio.Payout(0, cur, who, Denom, amount)
	chain.Emit("Claimed", "account", key, "amount", itoa(amount))
	return amount
}

// WithdrawFees moves the accrued fee pot to FeeCollector. Anyone may call
// it; the destination is a compile-time constant, so the caller cannot
// influence where the coins go.
func WithdrawFees(cur realm) int64 {
	rejectStraySend(cur)
	fees := ledger.WithdrawFees()
	if fees == 0 {
		panic("no fees accrued")
	}
	coinio.Payout(0, cur, FeeCollector, Denom, fees)
	chain.Emit("FeesWithdrawn", "to", FeeCollector.String(), "amount", itoa(fees))
	return fees
}

// SweepSurplus sends coins held beyond every obligation to FeeCollector.
// The reserve passed to coinio is the realm's full liability, so a sweep
// can never reach a coin an issuer is owed.
func SweepSurplus(cur realm) int64 {
	rejectStraySend(cur)
	swept := coinio.Sweep(0, cur, FeeCollector, Denom, Liabilities())
	chain.Emit("Swept", "denom", Denom, "to", FeeCollector.String(),
		"amount", itoa(swept))
	return swept
}

// --- the overdue predicate: this realm's integration surface ---

// isOverdue is a pure function of an invoice and the clock, which is what
// makes it unit-testable without a chain.
//
// Overdue means: still open, still owing, and the due height has PASSED.
// Strictly passed — at exactly dueHeight the invoice is due but not yet
// late, which is what lets dueHeight == issue height mean "due on receipt"
// without being born late.
func isOverdue(inv *invoice, now int64) bool {
	return inv.status == StatusOpen && inv.paid < inv.amount && now > inv.dueHeight
}

// IsOverdue reports whether one invoice is overdue right now.
func IsOverdue(issuer address, id int64) bool {
	return isOverdue(mustInvoice(issuer, id), runtime.ChainHeight())
}

// OutstandingFrom is the total a payer still owes THIS issuer across the
// issuer's open invoices.
//
// The iteration is bounded by MaxRecordsPerIssuer, NOT by the number of
// open invoices: it walks the issuer's whole stored prefix and skips the
// records that are not open. That is why the cap counts stored records —
// see the package doc.
//
// This is the issuer-scoped shape the package doc argues for: a consumer
// realm gating its own service on its own unpaid bills is trusting only
// itself. There is deliberately no global per-payer total — see the
// package doc, "Anyone may issue an invoice naming anyone".
func OutstandingFrom(issuer, payer address) int64 {
	var sum int64
	eachOf(issuer, func(inv *invoice) bool {
		if inv.payer == payer && inv.status == StatusOpen {
			sum += inv.amount - inv.paid
		}
		return false
	})
	return sum
}

// OverdueFrom is OutstandingFrom restricted to invoices whose due height
// has passed. A consumer realm that wants to withhold service from a late
// payer reads this.
func OverdueFrom(issuer, payer address) int64 {
	now := runtime.ChainHeight()
	var sum int64
	eachOf(issuer, func(inv *invoice) bool {
		if inv.payer == payer && isOverdue(inv, now) {
			sum += inv.amount - inv.paid
		}
		return false
	})
	return sum
}

// HasOverdueFrom is OverdueFrom as a predicate, for a consumer that only
// needs the boolean. It stops at the first hit rather than summing.
func HasOverdueFrom(issuer, payer address) bool {
	now := runtime.ChainHeight()
	found := false
	eachOf(issuer, func(inv *invoice) bool {
		if inv.payer == payer && isOverdue(inv, now) {
			found = true
			return true
		}
		return false
	})
	return found
}

// --- read-only accessors ---

// InvoiceInfo is the whole record, for a caller that wants one read.
func InvoiceInfo(issuer address, id int64) (payer address, amount, paid, dueHeight, issuedAt int64, status string) {
	inv := mustInvoice(issuer, id)
	return inv.payer, inv.amount, inv.paid, inv.dueHeight, inv.issuedAt, inv.status
}

// Outstanding is what is still owed on one invoice. Zero for a settled or
// voided one — a voided invoice owes nothing by definition, which is the
// point of voiding it.
func Outstanding(issuer address, id int64) int64 {
	inv := mustInvoice(issuer, id)
	if inv.status != StatusOpen {
		return 0
	}
	return inv.amount - inv.paid
}

// Memo is an invoice's free-text memo, exactly as the issuer wrote it. It
// is UNSANITIZED and caller-supplied: a consumer that renders it owes it
// the same treatment Render gives it here.
func Memo(issuer address, id int64) string { return mustInvoice(issuer, id).memo }

// StatusOf is an invoice's status.
func StatusOf(issuer address, id int64) string { return mustInvoice(issuer, id).status }

// HasInvoice reports whether a record exists, without panicking on
// absence — every other invoice accessor panics, which makes them unusable
// as an existence probe.
func HasInvoice(issuer address, id int64) bool {
	return invoices.Get(invKey(issuer, id)) != nil
}

// OpenOf is the number of open invoices an issuer holds.
func OpenOf(issuer address) int {
	if r := getIssuer(issuer.String()); r != nil {
		return r.open
	}
	return 0
}

// RecordsOf is the number of invoice records an issuer currently has
// stored, of any status. This — not OpenOf — is the figure capped by
// MaxRecordsPerIssuer, so it is the one an issuer near the cap needs.
func RecordsOf(issuer address) int {
	if r := getIssuer(issuer.String()); r != nil {
		return r.records
	}
	return 0
}

// IssuedOf is how many invoices an address has ever issued, and their
// total face value. Note the tense: both are lifetime figures and neither
// falls when an invoice is settled, voided or released.
func IssuedOf(issuer address) (count, invoiced int64) {
	if r := getIssuer(issuer.String()); r != nil {
		return r.issued, r.invoiced
	}
	return 0, 0
}

// BalanceOf is an issuer's settled, unclaimed balance.
func BalanceOf(issuer address) int64 { return ledger.BalanceOf(issuer.String()) }

// Records is the number of invoice records currently stored, open or not.
// It falls on Release, so it is a storage figure rather than a count of
// invoices that have existed.
func Records() int { return invoices.Size() }

// Issuers is the number of addresses that have ever issued an invoice.
func Issuers() int { return issuers.Size() }

// NextID is the id the next Issue will allocate. Exposed so a caller can
// tell a never-issued id from a released one.
func NextID() int64 { return nextID }

// SettledTotal is the sum of every issuer's unclaimed balance.
func SettledTotal() int64 { return ledger.UsersTotal() }

// FeesAccrued is the fee pot awaiting WithdrawFees.
func FeesAccrued() int64 { return ledger.FeesAccrued() }

// Liabilities is every coin this realm owes to anyone: the ledger's own
// total, which is issuer balances plus the fee pot.
//
// There is no pool term, and its ABSENCE is the unfunded property this
// realm exists to model — see the package doc. Do not "fix" this to match
// payroll's shape.
func Liabilities() int64 { return ledger.Liabilities() }

// Held is the realm's actual ugnot balance, read from the chain.
func Held() int64 { return coinio.HeldAt(self, Denom) }

// Surplus is coins held beyond every obligation — what SweepSurplus would
// move. It is zero when every coin arrived through an entrypoint.
func Surplus() int64 {
	h, l := Held(), Liabilities()
	if h <= l {
		return 0
	}
	return h - l
}

// Address is this realm's own address.
func Address() address { return self }

// Height is the current chain height, exposed so a caller can compute due
// heights against the same clock this realm uses.
func Height() int64 { return runtime.ChainHeight() }

// --- internals ---

// invKey is issuer|paddedID. The id is left-padded to 19 digits — the
// width of MaxInt64 — so that lexicographic order over an issuer's prefix
// is numeric order over their invoice ids. An unpadded decimal would sort
// "10" before "9" and make a prefix scan return them out of order.
func invKey(issuer address, id int64) string {
	return issuer.String() + "|" + padID(id)
}

func padID(id int64) string {
	s := strconv.FormatInt(id, 10)
	for len(s) < 19 {
		s = "0" + s
	}
	return s
}

// eachOf iterates one issuer's invoice records in id order. The callback
// returns true to stop, matching avl's own convention.
func eachOf(issuer address, fn func(*invoice) bool) {
	prefix := issuer.String() + "|"
	invoices.Iterate(prefix, prefix+"\xff", func(_ string, v any) bool {
		return fn(v.(*invoice))
	})
}

func getIssuer(key string) *issuerRec {
	v := issuers.Get(key)
	if v == nil {
		return nil
	}
	return v.(*issuerRec)
}

func mustInvoice(issuer address, id int64) *invoice {
	v := invoices.Get(invKey(issuer, id))
	if v == nil {
		panic("unknown invoice")
	}
	return v.(*invoice)
}

// mustDecOpen decrements an issuer's open count by one and REFUSES rather
// than masking if it cannot.
//
// Both call sites — settlement in Pay and forgiveness in Void — have already
// proved the invoice exists and was StatusOpen, so neither branch below can
// fire. The decrement is reachable only through a status transition out of
// StatusOpen, each invoice makes that transition at most once (both guards
// require StatusOpen and both set a terminal status), and Issue increments
// `open` for every record it stores. So an open invoice contributed exactly
// one to this counter and has not yet taken it back.
//
// The earlier spelling was `if r := getIssuer(...); r != nil && r.open > 0`,
// which reads as prudence and is the opposite. Those clauses cannot prevent
// the inconsistency — the status has already been written by the time we get
// here — they can only decline to notice it, and then COMMIT it. A panic
// aborts the whole transaction and reverts the status write too, which
// leaves the realm consistent; masking leaves it inconsistent and silent,
// and the counter it corrupts is the one MaxRecordsPerIssuer reads.
//
// So the guard exists for a future edit, not for today: a path that retires
// an invoice without coming through here fails loudly on the next one
// instead of quietly leaking a slot. A check that can never fire and a
// check that always passes are the same artifact from a reader's seat; the
// difference is what each does when it is wrong.
func mustDecOpen(issuer address) {
	r := getIssuer(issuer.String())
	if r == nil || r.open == 0 {
		panic("invoices: issuer open count desynchronized from the invoice tree")
	}
	r.open--
}

func checkedAdd(a, b int64) (int64, bool) {
	c := a + b
	if (b > 0 && c < a) || (b < 0 && c > a) {
		return 0, false
	}
	return c, true
}

func itoa(n int64) string { return strconv.FormatInt(n, 10) }

// --- render ---

func Render(path string) string {
	var b strings.Builder
	b.WriteString("# invoices\n\n")
	b.WriteString("On-chain accounts receivable. An invoice is unfunded at ")
	b.WriteString("creation: the obligation is recorded first, and the ")
	b.WriteString("money may never arrive.\n\n")

	if path == "" {
		b.WriteString("## Totals\n\n")
		b.WriteString("| field | value |\n|---|---|\n")
		b.WriteString("| issuers | " + itoa(int64(Issuers())) + " |\n")
		b.WriteString("| stored records | " + itoa(int64(Records())) + " |\n")
		b.WriteString("| settled, unclaimed | " + itoa(SettledTotal()) + " " + Denom + " |\n")
		b.WriteString("| fees accrued | " + itoa(FeesAccrued()) + " " + Denom + " |\n")
		b.WriteString("| held | " + itoa(Held()) + " " + Denom + " |\n")
		b.WriteString("| surplus | " + itoa(Surplus()) + " " + Denom + " |\n\n")
		b.WriteString("> Anyone may issue an invoice naming anyone, so an ")
		b.WriteString("unpaid invoice is an unverified claim by its issuer. ")
		b.WriteString("There is deliberately no global \"what does this ")
		b.WriteString("address owe\" total; read OutstandingFrom, which is ")
		b.WriteString("issuer-scoped.\n\n")
		b.WriteString("Append an issuer address to this path to see their book.\n")
		return b.String()
	}

	who := sanitize.InlineText(path)
	b.WriteString("## Book of " + who + "\n\n")
	r := getIssuer(path)
	if r == nil {
		b.WriteString("No issuer record at that address.\n")
		return b.String()
	}
	b.WriteString("Open: " + itoa(int64(r.open)) + ", ")
	b.WriteString("stored: " + itoa(int64(r.records)) + "/" +
		itoa(int64(MaxRecordsPerIssuer)) + ", ")
	b.WriteString("issued all time: " + itoa(r.issued) + ", ")
	b.WriteString("face value all time: " + itoa(r.invoiced) + " " + Denom + "\n\n")

	now := runtime.ChainHeight()
	b.WriteString("| id | payer | amount | paid | due | status | memo |\n")
	b.WriteString("|---|---|---|---|---|---|---|\n")
	prefix := path + "|"
	invoices.Iterate(prefix, prefix+"\xff", func(_ string, v any) bool {
		inv := v.(*invoice)
		state := inv.status
		if isOverdue(inv, now) {
			state = "OVERDUE"
		}
		b.WriteString("| " + itoa(inv.id))
		b.WriteString(" | " + sanitize.TableCell(inv.payer.String()))
		b.WriteString(" | " + itoa(inv.amount))
		b.WriteString(" | " + itoa(inv.paid))
		b.WriteString(" | " + itoa(inv.dueHeight))
		b.WriteString(" | " + state)
		b.WriteString(" | " + cell(inv.memo) + " |\n")
		return false
	})
	return b.String()
}

// cell prepares caller-supplied text for a GFM table cell, truncating it
// for display first.
//
// TableCell rather than InlineText, and the slot is the reason: these
// bytes land between two `|` delimiters, and an unescaped `|` in a memo
// would open a new column and shift every column to its right. InlineText
// does not escape the pipe. The payer cell above uses the same helper for
// the same slot even though a bech32 address cannot contain one — matching
// the helper to the slot is the rule that survives a later edit, whereas
// "this particular value happens to be safe" is a fact about today's
// charset.
//
// TRUNCATE BEFORE ESCAPING, and on a RUNE boundary. Escaping first and
// cutting afterwards can slice a `\|` in half and leave the cell ending in
// a bare backslash; cutting on a byte boundary can split a multi-byte rune
// and emit invalid UTF-8. Neither is something the sanitizer is asked to
// repair, because by the time it sees the string the damage is upstream.
func cell(s string) string {
	const maxRunes = 48
	if r := []rune(s); len(r) > maxRunes {
		s = string(r[:maxRunes]) + "…"
	}
	return sanitize.TableCell(s)
}
