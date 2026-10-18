// Realm loans is an unsecured term loan with a fixed installment schedule and
// a flat finance charge, holding real ugnot. A LENDER opens a loan to a named
// BORROWER by attaching the principal, which the realm disburses to the
// borrower in the same transaction; the borrower REPAYS over a fixed number of
// installments; each repayment credits the lender's pull-claimable balance,
// the protocol fee splitting off at the ledger. A loan whose installments go
// unpaid past a grace window is permissionlessly DEFAULT-able — a recorded
// state, not a seizure, because v1 is unsecured.
//
// It is the one financial primitive this portfolio never had: CREDIT. The
// accounting realms RECORD obligations (r/invoices, r/receivables — p/aging's
// own doc lists "invoices, loans, dues") and the disbursement realms pay a
// KNOWN TOTAL out on a schedule (r/vesting, r/payroll, r/budgets). A loan is
// the asymmetric opposite: principal OUT once, a LARGER total back over time,
// plus the finance charge and the default state a disbursement realm has no
// use for. See [onyx/r/loans/DISCOVERY.md].
//
// # Custody — the conservation invariant is the product
//
// This is the first custodial realm the factory has selected since the
// publishers (r/latefees, r/cashflow), so the monetary invariant governs it
// exactly as it does r/subscriptions and r/meters:
//
//	Held == Σ lender-claimable + fee pot   (== feeledger.Liabilities())
//
// The principal is NEVER held across a transaction: [Open] receives it and
// pays it out to the borrower in the same call, so the only coins this realm
// ever holds are repayments awaiting the lender's [Claim]. A stuck or
// abandoned loan therefore strands no principal — it was disbursed — and the
// only value at risk is the lender's expected return, which is the real nature
// of unsecured credit and is disclosed, not engineered away.
//
// # The finance charge is FLAT in v1, and that is a scope decision
//
// The total repayable is `principal + floor(principal × rateBps / 10000)` — a
// flat charge over the whole term, NOT compounding and NOT accruing per block.
// Per-installment is `ceil(total / installments)` with the rounding remainder
// on the FINAL installment, so the installments sum to exactly the total (the
// cross-foot). Compounding interest and a tiered-by-duration rate (which
// p/tiers could price) are a v2: pricing them in v1 would add an accrual
// surface whose bugs are the ones lending audits most often find.
//
// # Default is a state, not a seizure — there is no collateral in v1
//
// A borrower past the grace window who has not repaid in full is Default-able
// by anyone (like the sibling realms' valves). It freezes the loan and records
// the shortfall; no coins move, because there is nothing to seize. Secured
// lending is a v2.
//
// REALM-CALLER CAVEAT, inherited from the siblings: coinio's receipt guard
// admits only EOA payers, so the LENDER (who funds Open) and any REPAYER (who
// funds Repay) are EOAs. The BORROWER is a parameter — coinio.Payout delivers
// the principal to any valid address, including a realm — but a realm borrower
// could never Repay (Repay is payable, EOA-only), so naming one is the
// lender's own footgun (an un-repayable gift), not a realm or third-party
// hazard. assertNoSend reads the ORIGIN envelope, so every non-payable
// function refuses any transaction that attached coins anywhere.
package loans

import (
	"chain"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"

	"gno.land/p/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/coinio"
	"gno.land/p/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/feeledger"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/markdown/sanitize/v0"
)

// Denom is the only asset this realm accepts.
const Denom = "ugnot"

// MaxFeeBps is the hard protocol-fee cap: 1000 bps = 10%.
const MaxFeeBps = int64(1000)

// Loan status values. Repaid and Defaulted are terminal.
const (
	LoanActive    = "active"
	LoanRepaid    = "repaid"
	LoanDefaulted = "defaulted"
)

// Input bounds.
const (
	// MinPrincipal keeps a loan from being dust; MaxPrincipal keeps
	// principal × rateBps and the total far from int64 overflow (the
	// checked arithmetic still guards it). The lender must ATTACH the
	// principal, so the real ceiling is their balance.
	MinPrincipal = int64(1_000)
	MaxPrincipal = int64(1_000_000_000_000) // 1,000,000 GNOT

	// MaxRateBps caps the flat finance charge at 100% of principal over the
	// whole term. A 0 rate is a legitimate interest-free loan.
	MaxRateBps = int64(10_000)

	// Installment-count and period bounds. The period bounds match the
	// sibling realms: the floor keeps repayment off a per-block treadmill,
	// the ceiling keeps schedule arithmetic far from overflow.
	MinInstallments = int64(1)
	MaxInstallments = int64(60)
	MinPeriodBlocks = int64(10)
	MaxPeriodBlocks = int64(7_500_000)

	// MaxLoansPerLender bounds one lender's stored loans; terminal loans do
	// NOT free the slot, because a Repaid/Defaulted loan is a permanent
	// record a borrower and auditor may need to read.
	MaxLoansPerLender = 50

	// RenderLimit bounds every rendered list — an unbounded Render was
	// YELLOW in three prior audits.
	RenderLimit = 20
)

type loan struct {
	id          int64
	lender      address
	borrower    address
	principal   int64
	total       int64 // principal + finance charge, the sum repayable
	installments int64
	periodBlocks int64
	feeBps      int64 // snapshotted at Open, split off each repayment
	startHeight int64 // disbursement height; installment k due at start + k·period
	repaid      int64 // cumulative repaid toward total
	status      string
}

var (
	admin        address
	pendingAdmin address
	feeRecipient address
	feeBps       int64 // snapshotted into NEW loans

	self    address
	nextID  int64

	loans      = avl.NewTree() // padID(id)        -> *loan
	lenderNum  = avl.NewTree() // lender.String()  -> *int64, stored loans
	ledger     = feeledger.MustNew(MaxFeeBps)
)

func init() {
	admin = unsafe.OriginCaller()
	feeRecipient = admin
	self = unsafe.CurrentRealm().Address()
}

// --- lender side ---

// Open funds a loan: the caller (the lender) attaches the principal, which is
// disbursed to borrower in this same transaction, and the loan is recorded
// with a flat finance charge of rateBps of the principal, repayable over
// `installments` installments of `periodBlocks` blocks each. The current
// protocol fee is snapshotted in. Returns the loan id.
func Open(cur realm, borrower address, rateBps, installments, periodBlocks int64) int64 {
	lender, principal := coinio.Receive(0, cur, Denom)
	if !borrower.IsValid() {
		panic("invalid borrower")
	}
	if borrower == lender {
		panic("lender and borrower must differ")
	}
	if principal < MinPrincipal || principal > MaxPrincipal {
		panic("principal must be " + itoa(MinPrincipal) + ".." + itoa(MaxPrincipal) + Denom)
	}
	if rateBps < 0 || rateBps > MaxRateBps {
		panic("rateBps must be 0.." + itoa(MaxRateBps))
	}
	if installments < MinInstallments || installments > MaxInstallments {
		panic("installments must be " + itoa(MinInstallments) + ".." + itoa(MaxInstallments))
	}
	if periodBlocks < MinPeriodBlocks || periodBlocks > MaxPeriodBlocks {
		panic("periodBlocks must be " + itoa(MinPeriodBlocks) + ".." + itoa(MaxPeriodBlocks))
	}
	charge, ok := mulDivChecked(principal, rateBps, 10_000)
	if !ok {
		panic("finance charge overflow")
	}
	total, ok := addChecked(principal, charge)
	if !ok {
		panic("total overflow")
	}

	n := counter(lenderNum, lender)
	if *n >= MaxLoansPerLender {
		panic("per-lender loan limit reached")
	}

	// Disburse the principal to the borrower in this same transaction, so the
	// realm holds nothing from it. coinio.Payout panics on failure, reverting
	// the receipt above with it.
	coinio.Payout(0, cur, borrower, Denom, principal)

	id := nextID
	nextID++
	loans.Set(padID(id), &loan{
		id:           id,
		lender:       lender,
		borrower:     borrower,
		principal:    principal,
		total:        total,
		installments: installments,
		periodBlocks: periodBlocks,
		feeBps:       feeBps,
		startHeight:  runtime.ChainHeight(),
		status:       LoanActive,
	})
	*n++

	chain.Emit("LoanOpened",
		"loanId", itoa(id),
		"lender", lender.String(),
		"borrower", borrower.String(),
		"principal", itoa(principal),
		"total", itoa(total),
		"installments", itoa(installments),
		"feeBps", itoa(feeBps),
	)
	return id
}

// Claim sends amount ugnot of the caller's claimable balance (repayments
// collected on their loans, net of the protocol fee) back to the caller.
func Claim(cur realm, amount int64) {
	assertNoSend()
	caller := cur.Previous().Address()
	if err := ledger.Withdraw(caller.String(), amount); err != nil {
		panic(err)
	}
	coinio.Payout(0, cur, caller, Denom, amount)
	chain.Emit("Claim", "to", caller.String(), "amount", itoa(amount))
}

// ClaimAll sends the caller's entire claimable balance back to the caller.
func ClaimAll(cur realm) {
	assertNoSend()
	caller := cur.Previous().Address()
	amount, err := ledger.WithdrawAll(caller.String())
	if err != nil {
		panic(err)
	}
	if amount == 0 {
		panic("nothing to claim")
	}
	coinio.Payout(0, cur, caller, Denom, amount)
	chain.Emit("Claim", "to", caller.String(), "amount", itoa(amount))
}

// --- borrower side ---

// Repay pays toward the caller's own loan. The caller must be the loan's
// borrower; the attached amount must be positive and must not exceed the
// outstanding balance. The payment credits the lender's claimable balance (the
// protocol fee splitting off at the ledger); when the cumulative repaid equals
// the total, the loan is Repaid. Repaying ahead of schedule is allowed.
func Repay(cur realm, loanID int64) {
	payer, amount := coinio.Receive(0, cur, Denom)
	l := mustLoan(loanID)
	if payer != l.borrower {
		panic("only the borrower may repay this loan")
	}
	if l.status != LoanActive {
		panic("loan is " + l.status)
	}
	if amount <= 0 {
		panic("attach a positive repayment")
	}
	outstanding := l.total - l.repaid
	if amount > outstanding {
		panic("repayment " + itoa(amount) + " exceeds the outstanding balance " + itoa(outstanding))
	}

	credited, fee := ledger.MustDeposit(l.lender.String(), amount, l.feeBps)
	l.repaid += amount
	if l.repaid == l.total {
		l.status = LoanRepaid
	}

	chain.Emit("Repaid",
		"loanId", itoa(loanID),
		"borrower", l.borrower.String(),
		"amount", itoa(amount),
		"repaidTotal", itoa(l.repaid),
		"credited", itoa(credited),
		"fee", itoa(fee),
		"status", l.status,
	)
}

// Default marks an active loan defaulted once it is past its grace window —
// the final installment's due height plus one more period — and not repaid in
// full. Permissionless by design: no loan's terminal state may depend on
// either party acting. No coins move; the shortfall is recorded.
func Default(cur realm, loanID int64) {
	assertNoSend()
	l := mustLoan(loanID)
	if l.status != LoanActive {
		panic("loan is " + l.status)
	}
	if runtime.ChainHeight() < defaultableAt(l) {
		panic("not defaultable until height " + itoa(defaultableAt(l)))
	}
	l.status = LoanDefaulted
	chain.Emit("Defaulted",
		"loanId", itoa(loanID),
		"lender", l.lender.String(),
		"borrower", l.borrower.String(),
		"shortfall", itoa(l.total-l.repaid),
	)
}

// --- administration (two-step transfer, the house pattern) ---

func SetFeeBps(cur realm, bps int64) {
	assertNoSend()
	if cur.Previous().Address() != admin {
		panic("admin only")
	}
	if bps < 0 || bps > MaxFeeBps {
		panic("fee must be 0.." + itoa(MaxFeeBps) + " bps")
	}
	feeBps = bps
	chain.Emit("FeeSet", "bps", itoa(bps))
}

func SetFeeRecipient(cur realm, recipient address) {
	assertNoSend()
	if cur.Previous().Address() != admin {
		panic("admin only")
	}
	if !recipient.IsValid() {
		panic("invalid recipient")
	}
	feeRecipient = recipient
	chain.Emit("FeeRecipientSet", "to", recipient.String())
}

func WithdrawFees(cur realm) {
	assertNoSend()
	if cur.Previous().Address() != feeRecipient {
		panic("fee recipient only")
	}
	amount := ledger.WithdrawFees()
	if amount == 0 {
		panic("no fees accrued")
	}
	coinio.Payout(0, cur, feeRecipient, Denom, amount)
	chain.Emit("FeesWithdrawn", "to", feeRecipient.String(), "amount", itoa(amount))
}

// SweepDenom recovers out-of-band coins to the fee recipient. For the ledger
// denom the reserve is Liabilities() — lender balances and the fee pot are
// structurally unreachable.
func SweepDenom(cur realm, denom string) {
	assertNoSend()
	if cur.Previous().Address() != feeRecipient {
		panic("fee recipient only")
	}
	reserve := int64(0)
	if denom == Denom {
		reserve = ledger.Liabilities()
	}
	swept := coinio.Sweep(0, cur, feeRecipient, denom, reserve)
	chain.Emit("SurplusSwept", "to", feeRecipient.String(), "coins", itoa(swept)+denom)
}

func TransferAdmin(cur realm, successor address) {
	assertNoSend()
	if cur.Previous().Address() != admin {
		panic("admin only")
	}
	if !successor.IsValid() {
		panic("invalid successor")
	}
	pendingAdmin = successor
	chain.Emit("AdminTransferStaged", "to", successor.String())
}

func AcceptAdmin(cur realm) {
	assertNoSend()
	caller := cur.Previous().Address()
	if pendingAdmin == "" || caller != pendingAdmin {
		panic("no admin transfer staged for caller")
	}
	admin = pendingAdmin
	pendingAdmin = ""
	chain.Emit("AdminTransferred", "to", caller.String())
}

// --- views (non-crossing: cross-realm readable) ---

// LoanInfo returns a loan's terms and state.
func LoanInfo(loanID int64) (lender, borrower address, principal, total, repaid, installments, periodBlocks, startHeight int64, status string) {
	l := mustLoan(loanID)
	return l.lender, l.borrower, l.principal, l.total, l.repaid, l.installments, l.periodBlocks, l.startHeight, l.status
}

// InstallmentAmount is the per-installment amount: ceil(total/installments),
// with the rounding remainder carried on the FINAL installment so the
// installments sum to exactly the total.
func InstallmentAmount(loanID int64) int64 {
	l := mustLoan(loanID)
	return ceilDiv(l.total, l.installments)
}

// Outstanding is total − repaid.
func Outstanding(loanID int64) int64 {
	l := mustLoan(loanID)
	return l.total - l.repaid
}

// ScheduledDue is the cumulative amount that should have been repaid by the
// current height: the sum of every installment whose due height has passed,
// capped at the total. Installment k (1-based) is due at start + k·period.
func ScheduledDue(loanID int64) int64 {
	l := mustLoan(loanID)
	return scheduledDue(l, runtime.ChainHeight())
}

// AmountDueNow is how far behind schedule the borrower is right now:
// ScheduledDue − repaid, floored at zero (a borrower who has prepaid is not
// behind).
func AmountDueNow(loanID int64) int64 {
	l := mustLoan(loanID)
	due := scheduledDue(l, runtime.ChainHeight()) - l.repaid
	if due < 0 {
		return 0
	}
	return due
}

// DefaultableAt is the height at or after which an unpaid loan may be
// Defaulted: the final installment's due height plus one grace period.
func DefaultableAt(loanID int64) int64 { return defaultableAt(mustLoan(loanID)) }

// IsDefaultable reports whether the loan may be Defaulted right now.
func IsDefaultable(loanID int64) bool {
	l := mustLoan(loanID)
	return l.status == LoanActive && runtime.ChainHeight() >= defaultableAt(l) && l.repaid < l.total
}

func HasLoan(loanID int64) bool { return loans.Get(padID(loanID)) != nil }

func LoansOf(lender address) int64 {
	v := lenderNum.Get(lender.String())
	if v == nil {
		return 0
	}
	return *v.(*int64)
}

func Admin() address              { return admin }
func PendingAdmin() address       { return pendingAdmin }
func FeeRecipient() address       { return feeRecipient }
func FeeBps() int64               { return feeBps }
func NumLoans() int64             { return nextID }
func ClaimableOf(a address) int64 { return ledger.BalanceOf(a.String()) }
func FeesAccrued() int64          { return ledger.FeesAccrued() }
func Liabilities() int64          { return ledger.Liabilities() }
func Held() int64                 { return coinio.HeldAt(self, Denom) }
func Address() address            { return self }
func Height() int64               { return runtime.ChainHeight() }

// --- internals ---

// scheduledDue is the cumulative amount owed by `now`: k installments' worth
// where k is how many installment due-heights have passed, capped at total.
func scheduledDue(l *loan, now int64) int64 {
	if now < l.startHeight {
		return 0
	}
	elapsed := (now - l.startHeight) / l.periodBlocks // installments whose due height passed
	if elapsed >= l.installments {
		return l.total
	}
	if elapsed <= 0 {
		return 0
	}
	// k installments of ceil(total/N) each, but never more than the total.
	per := ceilDiv(l.total, l.installments)
	due, ok := mulChecked(per, elapsed)
	if !ok || due > l.total {
		return l.total
	}
	return due
}

// defaultableAt is the final installment's due height plus one grace period.
func defaultableAt(l *loan) int64 {
	return l.startHeight + (l.installments+1)*l.periodBlocks
}

func mustLoan(id int64) *loan {
	v := loans.Get(padID(id))
	if v == nil {
		panic("unknown loan " + itoa(id))
	}
	return v.(*loan)
}

func assertNoSend() {
	if !unsafe.OriginSend().IsZero() {
		panic("this function does not accept coins")
	}
}

func counter(tree *avl.Tree, a address) *int64 {
	k := a.String()
	if v := tree.Get(k); v != nil {
		return v.(*int64)
	}
	n := int64(0)
	tree.Set(k, &n)
	return &n
}

// ceilDiv returns ceil(a/b) for positive b; a,b assumed non-negative and b>0
// (installments >= MinInstallments >= 1).
func ceilDiv(a, b int64) int64 {
	if a <= 0 {
		return 0
	}
	return (a + b - 1) / b
}

func addChecked(a, b int64) (int64, bool) {
	s := a + b
	if (b > 0 && s < a) || (b < 0 && s > a) {
		return 0, false
	}
	return s, true
}

func mulChecked(a, b int64) (int64, bool) {
	if a == 0 || b == 0 {
		return 0, true
	}
	p := a * b
	if p/b != a {
		return 0, false
	}
	return p, true
}

// mulDivChecked returns floor(a*b/d) without overflowing on the intermediate
// product, by dividing before multiplying where it can and checking the
// product otherwise. Here d is 10000 and a,b are bounded, so the simple
// checked product suffices; the helper names the intent and guards it.
func mulDivChecked(a, b, d int64) (int64, bool) {
	p, ok := mulChecked(a, b)
	if !ok {
		return 0, false
	}
	return p / d, true
}

func padID(id int64) string {
	s := strconv.FormatInt(id, 10)
	for len(s) < 12 {
		s = "0" + s
	}
	return s
}

func itoa(n int64) string { return strconv.FormatInt(n, 10) }

// --- Render ---

func Render(path string) string {
	switch {
	case path == "":
		return renderHome()
	case hasPrefix(path, "loan/"):
		return renderLoan(path[len("loan/"):])
	default:
		return "unknown path; try \"\" or \"loan/<id>\"\n"
	}
}

func renderHome() string {
	out := "# loans — unsecured term loans with a flat finance charge\n\n"
	out += "Loans: " + itoa(nextID) + " · claimable+fees held: " + itoa(ledger.Liabilities()) + Denom +
		" · fees accrued: " + itoa(ledger.FeesAccrued()) + Denom + "\n\n"
	out += "The realm never holds principal (it is disbursed at Open); the coins it holds are repayments awaiting Claim.\n\n"
	out += "| id | lender | borrower | principal | total | repaid | status |\n|---|---|---|---|---|---|---|\n"
	shown := int64(0)
	for id := nextID - 1; id >= 0 && shown < RenderLimit; id-- {
		v := loans.Get(padID(id))
		if v == nil {
			continue
		}
		l := v.(*loan)
		out += "| " + itoa(l.id) + " | " + sanitize.TableCell(l.lender.String()) + " | " +
			sanitize.TableCell(l.borrower.String()) + " | " + itoa(l.principal) + Denom + " | " +
			itoa(l.total) + Denom + " | " + itoa(l.repaid) + Denom + " | " + l.status + " |\n"
		shown++
	}
	if nextID > shown {
		out += "\n(" + itoa(shown) + " most recent of " + itoa(nextID) + ")\n"
	}
	return out
}

func renderLoan(idStr string) string {
	id, err := strconv.ParseInt(idStr, 10, 64)
	if err != nil {
		return "bad loan id\n"
	}
	v := loans.Get(padID(id))
	if v == nil {
		return "unknown loan " + idStr + "\n"
	}
	l := v.(*loan)
	now := runtime.ChainHeight()
	out := "# loan " + itoa(l.id) + "\n\n"
	out += "- lender: " + l.lender.String() + "\n"
	out += "- borrower: " + l.borrower.String() + "\n"
	out += "- principal " + itoa(l.principal) + Denom + ", total repayable " + itoa(l.total) + Denom +
		" (finance charge " + itoa(l.total-l.principal) + Denom + ")\n"
	out += "- " + itoa(l.installments) + " installments of ~" + itoa(ceilDiv(l.total, l.installments)) +
		Denom + " every " + itoa(l.periodBlocks) + " blocks, from height " + itoa(l.startHeight) + "\n"
	out += "- repaid " + itoa(l.repaid) + Denom + " · outstanding " + itoa(l.total-l.repaid) + Denom +
		" · status " + l.status + "\n"
	if l.status == LoanActive {
		behind := scheduledDue(l, now) - l.repaid
		if behind < 0 {
			behind = 0
		}
		out += "- scheduled-due by now " + itoa(scheduledDue(l, now)) + Denom + " · behind " + itoa(behind) +
			Denom + " · defaultable at height " + itoa(defaultableAt(l)) + "\n"
	}
	return out
}

func hasPrefix(s, p string) bool { return len(s) >= len(p) && s[:len(p)] == p }
