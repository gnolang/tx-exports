// Package payroll is employer-funded recurring salary disbursement with
// real ugnot custody.
//
// # The one idea
//
// An allowance refills; a salary ACCRUES. That single sentence is why
// this realm exists beside budgets rather than inside it.
//
// budgets (this portfolio, live on onyx-1) grants a delegate a
// rate-limited spending authority through p/spendbook: the delegate may
// draw at most PerPeriod per window, and a window that passes unused is
// gone. Use-it-or-lose-it is exactly right for a spending authority — an
// unspent budget is not a debt.
//
// A salary is the dual. An employee who does not collect for three
// periods is owed three periods. Unclaimed pay is a LIABILITY of the
// employer, not an expired permission. No refilling primitive can model
// that, because the whole point of a refill is that the previous window
// is forgotten.
//
// So the arithmetic here is accrual arithmetic, and it is the one
// genuinely new mechanism in this realm. Everything that touches coins
// is delegated to primitives this portfolio has already audited and run
// live: p/coinio for custody and payout guards, p/feeledger for
// per-employee balances and the liabilities total.
//
// # Paid in arrears
//
// A period must COMPLETE before it is owed. At the instant a position
// starts, nothing is due; the first period becomes payable at
// StartHeight + PeriodBlocks. Paying in advance would mean the realm
// disbursing for time that has not elapsed, and there is no mechanism on
// chain to take it back if the position ends early.
//
// A consequence worth stating plainly: a position whose PeriodBlocks
// never fully elapses before it is terminated pays NOTHING. That is not
// a rounding loss hidden in the implementation, it is the arrears rule
// applied honestly, and Terminate's documentation repeats it.
//
// # Accrual is permissionless, and whole-period
//
// Gno has no autonomous execution, so "recurring" always means someone
// sends a transaction later. Accrue may therefore be called by ANYONE —
// the employee, the employer, a keeper realm, a stranger. It does only
// what the employer already committed to when the position was opened,
// it moves coins from that employer's own pool to that employee's own
// ledger balance, and the caller pays the gas. There is no third party
// who gains, so there is nothing to grief with. This is also what makes
// the realm composable with upkeep, the portfolio's keeper-incentive
// realm.
//
// Accrual settles WHOLE periods only. If the pool covers two of three
// due periods, two are credited and the third stays due — it is not
// partially paid, and no capacity is burned. The pool bounds HOW MANY
// periods clear, never WHETHER a period is paid in full.
//
// # Solvency, and the lesson taken from budgets
//
// budgets' package documentation records that a budget is authority and
// not a reservation: over-authorization is legal there, and solvency is
// enforced per-owner at draw time. The same choice is made here for the
// same reason, and the honest consequence is named rather than hidden:
//
//	OPENING A POSITION DOES NOT RESERVE ANY COINS.
//
// An employer may hire more people than the pool can ever pay. Nothing
// in this realm prevents it, because a future funding transaction is a
// perfectly ordinary way to intend to meet an obligation, and refusing
// the hire would only move the problem to the moment the pool dips. What
// the realm guarantees is narrower and checkable: a period either clears
// in full or stays due, and no employee's accrued ledger balance can be
// reduced by anyone.
//
// # The monetary invariant
//
// Two statements, because one of them is a decomposition and the other is
// a solvency claim, and collapsing them is how the wrong identity gets
// written down:
//
//	Liabilities() == TotalPooled() + AccruedTotal() + FeesAccrued()
//	Held()        == Liabilities() + Surplus()
//
// Liabilities() is every coin owed to anyone: the employers' unallocated
// pools PLUS the feeledger's own total, which is itself the accrued
// employee balances plus the fee pot. Surplus() is coins pushed at the
// realm outside every entrypoint. Both lines hold after every operation
// and are pinned by TestMonetaryInvariant. It is the same shape budgets
// carries, deliberately: a reader who has checked one can check the
// other.
//
// Only the first line can fail. The second is definitional — Surplus()
// is computed as Held()-Liabilities() — so asserting it is a tautology,
// and what the test actually checks is Held() >= Liabilities() beside the
// decomposition. A reader who takes the second line for a check has been
// reassured by arithmetic.
//
// This paragraph read `Held() == TotalPooled() + Liabilities() +
// Surplus()` until the pre-deploy audit, which double-counts the pools
// because Liabilities() already contains TotalPooled(). The code was
// never wrong and payroll_test.gno encoded the right decomposition the
// whole time; the comment was, and a comment is immutable after addpkg.
//
// # Termination is two steps, and that is a protection
//
// Terminate stops the clock. Release frees the storage. They are
// separate because collapsing them would destroy earned-but-unaccrued
// pay: an employer whose pool is short could remove a position owing
// three periods and the debt would vanish with the record.
//
// So Terminate sets the end height to now and leaves the position in
// place, with whatever is due still due and still accruable by anyone.
// Release removes it, and only once nothing is due. Release is
// permissionless and the chain refunds the freed storage deposit to the
// caller, which is the standing incentive to tidy up someone else's
// settled position — the same mechanism budgets uses for Reap.
//
// # What this realm does NOT do
//
//   - It does not value work, verify it happened, or arbitrate a dispute
//     about it. A position is a standing instruction from an employer,
//     and nothing more.
//   - It holds ugnot and only ugnot.
//   - It has no admin. The deploying namespace receives protocol fees
//     and swept surplus and has no other privilege: no setter, no pause,
//     no ability to touch a pool or a balance. Funding a pool is what
//     makes an address an employer, exactly as in budgets.
//
// # STORAGE
//
// An employer record is paid for by that employer's first Fund; a
// position record by the Hire that opens it. Release removes a position
// record and the chain refunds the freed deposit to the transaction that
// frees it.
package payroll

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
const RealmPath = "/r/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/payroll"

// Denom is the only asset this realm holds.
const Denom = "ugnot"

// MaxFeeBps is the hard ceiling on any accrual fee this realm could ever
// charge, enforced by the feeledger the realm is constructed with — a
// feeBps above it is refused by the primitive's own validation, not by a
// check in this file. 500 bps = 5%.
const MaxFeeBps = int64(500)

// AccrueFeeBps is the fee charged on each accrual, on the gross amount,
// floor-rounded in the EMPLOYEE's favour: 100 bps = 1%. It matches the
// most conservative live fee in this portfolio (fee_split, crowdfund,
// budgets). It is a compile-time constant and there is no setter, so a
// position's economics cannot be changed under the employee after the
// position is opened.
const AccrueFeeBps = int64(100)

// FeeCollector receives withdrawn fees and swept surplus. Compile-time
// constant: there is no setter and no transfer path. It is the deploying
// namespace's address — stated plainly: the operator of this realm.
//
// NOTE FOR ANY RE-NAMESPACED PORT: this is the address-as-data hazard
// that a namespace substitution rewrites silently while every
// byte-comparison still reports the tree faithful, because the rewrite
// IS the intended transformation. Re-state it deliberately per chain;
// never let it be derived.
const FeeCollector = address("g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3")

// MinFunding keeps dust pools out: 1 GNOT per Fund call.
const MinFunding = int64(1_000_000)

// MinPerPeriod is the smallest salary a position may carry. Below the
// fee denominator a 1% fee floors to zero, so a per-period amount of a
// few ugnot would be a fee-free position by accident rather than by
// design; 1000 ugnot keeps the fee arithmetic meaningful.
const MinPerPeriod = int64(1_000)

// MinPeriodBlocks is the shortest period a position may use. A period of
// a handful of blocks is a rate rather than a salary, and it makes the
// arrears rule meaningless. Unlike budgets, a period of 0 is NOT
// accepted here: there is no "one lifetime window" reading of a salary,
// and dividing by it would panic.
const MinPeriodBlocks = int64(100)

// MaxRoster caps simultaneously-open positions per employer. Hire is
// permissionless to anyone with a funded pool, so this is an
// AVAILABILITY BOUND and it is documented rather than hidden: an
// employer can exhaust their OWN roster and no one else's, because the
// roster is per-employer. The cost of filling one is gas plus the
// storage deposit on every position record, held until Release.
const MaxRoster = 64

// OpenEnded is the EndHeight value meaning "no end": the position
// accrues until it is terminated.
const OpenEnded = int64(0)

type position struct {
	employer address
	employee address

	// perPeriod is the gross salary per completed period. The employee
	// receives perPeriod minus the accrual fee.
	perPeriod int64

	// periodBlocks is the period length. Periods are ANCHORED to
	// startHeight, not sliding: period k closes at
	// startHeight + k*periodBlocks.
	periodBlocks int64

	startHeight int64

	// endHeight is OpenEnded, or the height past which no further period
	// accrues. Terminate sets it to the current height.
	endHeight int64

	// paidPeriods counts whole periods already accrued. It only ever
	// increases, and it is the single source of truth for what has been
	// settled — never a coin balance, which the employee can withdraw.
	paidPeriods int64
}

var (
	self address

	// employers holds one record per address that has ever funded a
	// pool. Key is the address string.
	employers = avl.NewTree() // address string -> *employer

	// positions holds one record per open position, keyed by
	// employer|employee so a roster scan is a prefix iteration and a
	// duplicate hire is an exact-key collision.
	positions = avl.NewTree() // "employer|employee" -> *position

	// ledger holds every employee's accrued-but-unclaimed balance and
	// the fee pot. It is GLOBAL across employers on purpose: an employee
	// paid by two employers has one balance and one Claim.
	ledger = feeledger.MustNew(MaxFeeBps)
)

type employer struct {
	pool   int64
	roster int
}

func init() {
	self = unsafe.CurrentRealm().Address()
}

// rejectStraySend aborts when a direct EOA MsgCall attaches coins to a
// non-payable entrypoint. This realm holds funds, so such a send would
// become sweepable surplus, silently converting a user's coins into
// operator funds.
//
// THE PREDICATE IS NARROWER THAN THE FIRST SENTENCE OF THIS COMMENT USED
// TO BE, and the narrowing is correct rather than a gap. OriginSend()
// reports the coins attached to the ORIGINATING TRANSACTION, not coins
// this realm received in this call — there is no per-call msg.value in
// Gno. MsgCall is the one caller shape where the two coincide: the
// envelope is delivered to the realm being called. Under MsgRun the
// envelope lands in the caller's own ephemeral /e/ realm, and under a
// realm caller it lands at the first realm in the chain; in both, coins
// that genuinely reach payroll do so through an explicit SendCoins that
// OriginSend() does not describe. So widening this guard to IsUser(), or
// dropping the conjunct entirely, would refuse calls that sent payroll
// nothing while still not seeing the sends it was widened to catch. The
// stdlib guidance is explicit that OriginSend pairs with IsUserCall.
//
// What remains uncovered is therefore not a hole in this guard: coins can
// always arrive at an address by a bare MsgSend with no call at all, which
// no entrypoint check can intercept. That is exactly what Surplus() and
// SweepSurplus exist to name and reclaim.
func rejectStraySend(cur realm) {
	if !cur.IsCurrent() {
		// Every call site forwards a crossing entrypoint's own live cur,
		// so this cannot fire today; it exists so a future refactor that
		// hands this guard a stale realm value fails closed, not open
		// (coinio names IsCurrent as the guard secondary realm
		// parameters require, and this helper follows that discipline).
		panic("payroll: realm capability is not current")
	}
	if cur.Previous().IsUserCall() && len(unsafe.OriginSend()) > 0 {
		panic("this entrypoint does not accept coins")
	}
}

// --- the pool ---

// Fund adds the attached coins to the caller's own pool. Direct EOA
// calls with -send only (the receipt-guaranteed shape); exactly one
// positive ugnot coin, at least MinFunding. Anyone may fund; funding is
// what makes an address an employer.
func Fund(cur realm) int64 {
	owner, amount := coinio.Receive(0, cur, Denom)
	if amount < MinFunding {
		panic("funding is below MinFunding")
	}
	key := owner.String()
	e := getEmployer(key)
	if e == nil {
		e = &employer{}
		employers.Set(key, e)
	}
	total, ok := checkedAdd(e.pool, amount)
	if !ok {
		panic("pool would overflow")
	}
	e.pool = total
	chain.Emit("Funded", "employer", key, "amount", itoa(amount),
		"pool", itoa(e.pool))
	return e.pool
}

// WithdrawPool returns unallocated pool coins to the employer. There is
// no lock and no notice period, and that is a DOCUMENTED asymmetry
// rather than an oversight: see the package doc on solvency. An employer
// may withdraw a pool while positions are open, which leaves those
// positions accruing against an empty pool — due but unsettleable until
// the pool is refunded. What an employer can never do is reduce a
// balance already accrued to an employee's ledger account.
func WithdrawPool(cur realm, amount int64) int64 {
	rejectStraySend(cur)
	if amount <= 0 {
		panic("amount must be positive")
	}
	owner := cur.Previous().Address()
	key := owner.String()
	e := mustEmployer(key)
	if amount > e.pool {
		panic("amount exceeds pool")
	}
	// Debit before the payout, per coinio's ordering contract: a panic
	// inside coinio aborts the transaction and reverts this debit.
	e.pool -= amount
	coinio.Payout(0, cur, owner, Denom, amount)
	chain.Emit("PoolWithdrawn", "employer", key, "amount", itoa(amount),
		"pool", itoa(e.pool))
	return e.pool
}

// WithdrawPoolAll is WithdrawPool for the whole pool. It panics on an
// empty pool rather than succeeding with a zero transfer, so a caller
// cannot read success as evidence that coins moved.
func WithdrawPoolAll(cur realm) int64 {
	rejectStraySend(cur)
	owner := cur.Previous().Address()
	e := mustEmployer(owner.String())
	if e.pool == 0 {
		panic("no pool to withdraw")
	}
	return WithdrawPool(cur, e.pool)
}

// --- positions ---

// Hire opens a position. The caller is the employer and must already
// have a funded pool, which is this realm's only barrier to opening
// records at someone else's expense.
//
// startHeight must not be in the past. A backdated start would make a
// large number of periods due in the same transaction that opened the
// position, draining the pool to one employee in one call — the hire
// would look like a schedule and behave like a withdrawal. Refusing it
// is cheaper to reason about than bounding it.
//
// # perPeriod is bounded below and NOT above, and the slot cost is permanent
//
// MinPerPeriod is a floor; there is no ceiling. A position opened with a
// perPeriod larger than any pool that can be funded is unsettleable,
// because Accrue's solvency check is integer division — e.pool/perPeriod
// is 0 for every reachable pool, so Accrue panics on "cannot cover one
// period" forever. Once that position's first period completes, duePeriods
// is permanently non-zero, so Release refuses forever too, and the record
// consumes one of the employer's MaxRoster slots for good.
//
// This is a DECLARED LIMITATION rather than a defect, and the reason is
// that it is strictly self-harm: owner comes from cur.Previous().Address()
// below and is never a parameter, so no caller can open an unpayable
// position on anyone else's roster, and the pool itself stays fully
// withdrawable through WithdrawPool. The mitigation is available and
// narrow: Terminate then Release BEFORE the first period completes, while
// duePeriods is still zero. After that the slot does not come back.
func Hire(cur realm, employee address, perPeriod, periodBlocks, startHeight, endHeight int64) {
	rejectStraySend(cur)

	// The lowercase clause is load-bearing, and it is carried from budgets'
	// Grant (measured on this toolchain, not argued): address.IsValid()
	// defers to crypto.AddressFromBech32, whose decoder lowercases the
	// input BEFORE verifying the checksum, so it returns true for the
	// all-uppercase spelling of a valid address.
	//
	// HERE THE CONSEQUENCE IS WORSE THAN IN BUDGETS, which is why this is
	// not boilerplate. In budgets an uppercase delegate yields a BRICKED
	// GRANT: no coins move, the owner's pool is untouched, only a slot is
	// wasted. In payroll, Accrue would debit the employer's pool and credit
	// ledger["G1UPPER..."], while Claim authenticates against
	// cur.Previous().Address(), which is always canonical. The balance would
	// be real, owed, and unreachable by every caller — a PERMANENT LOSS of
	// the employer's coins rather than a wasted record.
	//
	// One guard of this kind is all the realm needs, and the reason is
	// structural: employee is the only caller-supplied value that ever
	// becomes a storage key here. Every other key derives from
	// cur.Previous().Address() or coinio.Receive's sender, both canonical by
	// construction, and every other entrypoint LOOKS UP a position rather
	// than creating one, so a non-canonical argument there fails closed at
	// mustPosition. The check is complete as well as necessary: that decoder
	// rejects mixed case outright, so a valid address has exactly two
	// spellings and refusing every non-lower one leaves precisely the
	// canonical one.
	if !employee.IsValid() || string(employee) != strings.ToLower(string(employee)) {
		panic("employee is not a valid address in canonical (lowercase) form")
	}
	if perPeriod < MinPerPeriod {
		panic("perPeriod is below MinPerPeriod")
	}
	if periodBlocks < MinPeriodBlocks {
		panic("periodBlocks is below MinPeriodBlocks")
	}
	now := runtime.ChainHeight()
	if startHeight < now {
		panic("startHeight is in the past")
	}
	if endHeight != OpenEnded {
		if endHeight <= startHeight {
			panic("endHeight must be after startHeight, or OpenEnded")
		}
		if endHeight-startHeight < periodBlocks {
			panic("position ends before its first period completes")
		}
	}

	owner := cur.Previous().Address()
	ownerKey := owner.String()
	e := mustEmployer(ownerKey)
	if e.pool == 0 {
		panic("fund a pool before hiring")
	}
	if e.roster >= MaxRoster {
		panic("employer roster is full")
	}
	k := posKey(owner, employee)
	if positions.Get(k) != nil {
		panic("this employee already has an open position with this employer")
	}

	positions.Set(k, &position{
		employer:     owner,
		employee:     employee,
		perPeriod:    perPeriod,
		periodBlocks: periodBlocks,
		startHeight:  startHeight,
		endHeight:    endHeight,
		paidPeriods:  0,
	})
	e.roster++
	chain.Emit("Hired", "employer", ownerKey, "employee", employee.String(),
		"perPeriod", itoa(perPeriod), "periodBlocks", itoa(periodBlocks),
		"startHeight", itoa(startHeight), "endHeight", itoa(endHeight))
}

// Accrue settles every whole period that has completed and not yet been
// paid, as far as the employer's pool reaches, and credits the gross
// minus the accrual fee to the employee's ledger balance.
//
// ANYONE may call this — see the package doc. It returns the gross
// amount settled.
func Accrue(cur realm, employer, employee address) int64 {
	rejectStraySend(cur)
	p := mustPosition(employer, employee)
	e := mustEmployer(employer.String())

	now := runtime.ChainHeight()
	due := duePeriods(p, now)
	if due == 0 {
		panic("no periods are due")
	}

	// Whole periods the pool can cover. This is the solvency check and
	// it runs BEFORE any state moves, so a pool that cannot cover even
	// one period leaves paidPeriods untouched and nothing is lost.
	affordable := e.pool / p.perPeriod
	n := due
	if affordable < n {
		n = affordable
	}
	if n == 0 {
		panic("employer's pool cannot cover one period")
	}

	gross := n * p.perPeriod // bounded by e.pool, so it cannot overflow
	e.pool -= gross
	p.paidPeriods += n
	credited, fee := ledger.MustDeposit(employee.String(), gross, AccrueFeeBps)

	chain.Emit("Accrued", "employer", employer.String(),
		"employee", employee.String(), "periods", itoa(n),
		"gross", itoa(gross), "credited", itoa(credited), "fee", itoa(fee),
		"paidPeriods", itoa(p.paidPeriods), "pool", itoa(e.pool))
	return gross
}

// Terminate stops the clock on a position. The employer only.
//
// It does NOT remove the record and does not settle anything: whatever
// was due stays due, and anyone may still Accrue it. That separation is
// the employee's protection — see the package doc. Use Release to remove
// a settled position.
//
// If the position has not yet reached its first complete period, this
// pays nothing, by the arrears rule.
func Terminate(cur realm, employee address) {
	rejectStraySend(cur)
	owner := cur.Previous().Address()
	p := mustPosition(owner, employee)
	now := runtime.ChainHeight()
	if p.endHeight != OpenEnded && p.endHeight <= now {
		panic("position has already ended")
	}
	p.endHeight = now
	chain.Emit("Terminated", "employer", owner.String(),
		"employee", employee.String(), "endHeight", itoa(now),
		"paidPeriods", itoa(p.paidPeriods), "due", itoa(duePeriods(p, now)))
}

// Release removes an ended, fully-settled position and frees its
// storage. Permissionless: the chain refunds the freed storage deposit
// to the caller, which is the standing incentive to tidy up a settled
// position that is not your own.
//
// It refuses while anything is due, which is what makes it safe to let a
// stranger call: a Release cannot destroy an unpaid obligation.
func Release(cur realm, employer, employee address) {
	rejectStraySend(cur)
	p := mustPosition(employer, employee)
	now := runtime.ChainHeight()
	if p.endHeight == OpenEnded || p.endHeight > now {
		panic("position has not ended")
	}
	if duePeriods(p, now) != 0 {
		panic("position has unsettled periods")
	}
	positions.Remove(posKey(employer, employee))
	if e := getEmployer(employer.String()); e != nil && e.roster > 0 {
		e.roster--
	}
	chain.Emit("Released", "employer", employer.String(),
		"employee", employee.String(), "paidPeriods", itoa(p.paidPeriods))
}

// --- claiming ---

// Claim pays the caller their whole accrued balance. The employee only —
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
	// Debit first, per coinio's ordering contract.
	ledger.MustWithdraw(key, amount)
	coinio.Payout(0, cur, who, Denom, amount)
	chain.Emit("Claimed", "account", key, "amount", itoa(amount))
	return amount
}

// WithdrawFees moves the accrued fee pot to FeeCollector. Anyone may
// call it; the destination is a compile-time constant, so the caller
// cannot influence where the coins go.
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
// The reserve passed to coinio is the realm's full liability — pooled
// coins plus ledger liabilities — so a sweep can never reach a coin that
// an employer or an employee is owed.
func SweepSurplus(cur realm) int64 {
	rejectStraySend(cur)
	swept := coinio.Sweep(0, cur, FeeCollector, Denom, Liabilities())
	chain.Emit("Swept", "denom", Denom, "to", FeeCollector.String(),
		"amount", itoa(swept))
	return swept
}

// --- accrual arithmetic, the one new mechanism ---

// duePeriods is the number of whole periods that have completed and not
// been paid. It is a pure function of the position and the clock, which
// is what makes it unit-testable without a chain.
//
// Periods are ANCHORED to startHeight: period k closes at
// startHeight + k*periodBlocks. Nothing is due at startHeight itself —
// salary is paid in arrears.
func duePeriods(p *position, now int64) int64 {
	horizon := now
	if p.endHeight != OpenEnded && p.endHeight < horizon {
		horizon = p.endHeight
	}
	if horizon <= p.startHeight {
		return 0
	}
	completed := (horizon - p.startHeight) / p.periodBlocks
	if completed <= p.paidPeriods {
		return 0
	}
	return completed - p.paidPeriods
}

// --- read-only accessors ---

// DuePeriods is duePeriods for a live position, at the current height.
func DuePeriods(employer, employee address) int64 {
	return duePeriods(mustPosition(employer, employee), runtime.ChainHeight())
}

// DueAmount is the gross that DuePeriods would settle if the pool were
// unbounded. Read it beside AccruableAmount: the difference between them
// is exactly the employer's shortfall.
//
// It is the one arithmetic here with NO pool bound behind it, so it is the
// one place an int64 can wrap: perPeriod has no ceiling and due grows with
// the chain. Accrue cannot wrap, because its product is bounded by the
// pool it is about to debit (see the comment there). An unpayable position
// is a legal state in this realm, so the overflow is reachable in
// principle, and this panics rather than returning a negative salary —
// a view that refuses is recoverable, a view that lies is not.
func DueAmount(employer, employee address) int64 {
	p := mustPosition(employer, employee)
	gross, ok := checkedMul(duePeriods(p, runtime.ChainHeight()), p.perPeriod)
	if !ok {
		panic("due amount would overflow; read DuePeriods and PerPeriodOf instead")
	}
	return gross
}

// AccruableAmount is the gross an Accrue would settle right now, pool
// bound included. It is the honest number, and it can be less than
// DueAmount without anything being wrong — see the package doc on
// solvency.
func AccruableAmount(employer, employee address) int64 {
	p := mustPosition(employer, employee)
	e := mustEmployer(employer.String())
	due := duePeriods(p, runtime.ChainHeight())
	affordable := e.pool / p.perPeriod
	if affordable < due {
		due = affordable
	}
	return due * p.perPeriod
}

// PoolOf is an employer's unallocated pool. Zero for an address that has
// never funded one.
func PoolOf(employer address) int64 {
	if e := getEmployer(employer.String()); e != nil {
		return e.pool
	}
	return 0
}

// RosterOf is the number of open positions an employer holds.
func RosterOf(employer address) int {
	if e := getEmployer(employer.String()); e != nil {
		return e.roster
	}
	return 0
}

// BalanceOf is an employee's accrued, unclaimed balance.
func BalanceOf(employee address) int64 { return ledger.BalanceOf(employee.String()) }

// PerPeriodOf is a position's gross salary per period.
func PerPeriodOf(employer, employee address) int64 {
	return mustPosition(employer, employee).perPeriod
}

// PaidPeriodsOf is how many whole periods a position has settled.
func PaidPeriodsOf(employer, employee address) int64 {
	return mustPosition(employer, employee).paidPeriods
}

// EndHeightOf is a position's end height, or OpenEnded.
func EndHeightOf(employer, employee address) int64 {
	return mustPosition(employer, employee).endHeight
}

// HasPosition reports whether a position is open, without panicking on
// absence — every other position accessor panics, which makes them
// unusable as an existence probe.
func HasPosition(employer, employee address) bool {
	return positions.Get(posKey(employer, employee)) != nil
}

// OpenPositions is the number of open positions across every employer.
func OpenPositions() int { return positions.Size() }

// Employers is the number of addresses that have ever funded a pool.
// Note the tense: an employer record survives a pool going to zero, so
// this is not a count of currently-funded employers.
func Employers() int { return employers.Size() }

// TotalPooled is the sum of every employer's unallocated pool.
func TotalPooled() int64 {
	var sum int64
	employers.Iterate("", "", func(_ string, v any) bool {
		sum += v.(*employer).pool
		return false
	})
	return sum
}

// AccruedTotal is the sum of every employee's unclaimed balance.
func AccruedTotal() int64 { return ledger.UsersTotal() }

// FeesAccrued is the fee pot awaiting WithdrawFees.
func FeesAccrued() int64 { return ledger.FeesAccrued() }

// Liabilities is every coin this realm owes to anyone: pooled coins plus
// the ledger's own total (employee balances plus the fee pot).
func Liabilities() int64 {
	total, ok := checkedAdd(TotalPooled(), ledger.Liabilities())
	if !ok {
		panic("liabilities would overflow")
	}
	return total
}

// Held is the realm's actual ugnot balance, read from the chain.
func Held() int64 { return coinio.HeldAt(self, Denom) }

// Surplus is coins held beyond every obligation — what SweepSurplus
// would move. It is zero when every coin arrived through an entrypoint.
func Surplus() int64 {
	h, l := Held(), Liabilities()
	if h <= l {
		return 0
	}
	return h - l
}

// Address is this realm's own address.
func Address() address { return self }

// Height is the current chain height, exposed so a caller can compute
// period boundaries against the same clock this realm uses.
func Height() int64 { return runtime.ChainHeight() }

// --- internals ---

func posKey(employer, employee address) string {
	return employer.String() + "|" + employee.String()
}

func getEmployer(key string) *employer {
	v := employers.Get(key)
	if v == nil {
		return nil
	}
	return v.(*employer)
}

func mustEmployer(key string) *employer {
	e := getEmployer(key)
	if e == nil {
		panic("unknown employer")
	}
	return e
}

func mustPosition(employer, employee address) *position {
	v := positions.Get(posKey(employer, employee))
	if v == nil {
		panic("unknown position")
	}
	return v.(*position)
}

func checkedAdd(a, b int64) (int64, bool) {
	c := a + b
	if (b > 0 && c < a) || (b < 0 && c > a) {
		return 0, false
	}
	return c, true
}

// checkedMul reports a*b and whether it is exact. Both operands here are
// non-negative (duePeriods never returns a negative, perPeriod is validated
// at or above MinPerPeriod), so the division test is sufficient and the
// sign cases a general version would need are deliberately absent.
func checkedMul(a, b int64) (int64, bool) {
	if a == 0 || b == 0 {
		return 0, true
	}
	c := a * b
	if c/b != a {
		return 0, false
	}
	return c, true
}

func itoa(n int64) string { return strconv.FormatInt(n, 10) }

// --- render ---

func Render(path string) string {
	var b strings.Builder
	b.WriteString("# payroll\n\n")
	b.WriteString("Employer-funded recurring salary disbursement. ")
	b.WriteString("An allowance refills; a salary accrues.\n\n")

	if path == "" {
		b.WriteString("## Totals\n\n")
		b.WriteString("| field | value |\n|---|---|\n")
		b.WriteString("| employers | " + itoa(int64(Employers())) + " |\n")
		b.WriteString("| open positions | " + itoa(int64(OpenPositions())) + " |\n")
		b.WriteString("| pooled | " + itoa(TotalPooled()) + " " + Denom + " |\n")
		b.WriteString("| accrued to employees | " + itoa(AccruedTotal()) + " " + Denom + " |\n")
		b.WriteString("| fees accrued | " + itoa(FeesAccrued()) + " " + Denom + " |\n")
		b.WriteString("| held | " + itoa(Held()) + " " + Denom + " |\n")
		b.WriteString("| surplus | " + itoa(Surplus()) + " " + Denom + " |\n\n")
		b.WriteString("Salary is paid in arrears: a period must complete ")
		b.WriteString("before it is owed. Accrue is permissionless.\n\n")
		b.WriteString("Append an employer address to this path to see ")
		b.WriteString("their roster.\n")
		return b.String()
	}

	who := sanitize.InlineText(path)
	b.WriteString("## Roster of " + who + "\n\n")
	e := getEmployer(path)
	if e == nil {
		b.WriteString("No employer record at that address.\n")
		return b.String()
	}
	b.WriteString("Pool: " + itoa(e.pool) + " " + Denom + ", ")
	b.WriteString("open positions: " + itoa(int64(e.roster)) + "\n\n")

	now := runtime.ChainHeight()
	b.WriteString("| employee | per period | period | paid | due |\n")
	b.WriteString("|---|---|---|---|---|\n")
	prefix := path + "|"
	positions.Iterate(prefix, prefix+"\xff", func(_ string, v any) bool {
		p := v.(*position)
		b.WriteString("| " + sanitize.InlineText(p.employee.String()))
		b.WriteString(" | " + itoa(p.perPeriod))
		b.WriteString(" | " + itoa(p.periodBlocks))
		b.WriteString(" | " + itoa(p.paidPeriods))
		b.WriteString(" | " + itoa(duePeriods(p, now)) + " |\n")
		return false
	})
	return b.String()
}
