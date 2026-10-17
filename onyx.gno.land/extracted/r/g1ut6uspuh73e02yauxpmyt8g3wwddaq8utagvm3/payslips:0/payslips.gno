// Package payslips publishes graduated withholding statements over the wage
// facts of a live r/payroll.
//
// An employer sets a withholding schedule — a [p/tiers] bracket table — and
// publishes a payslip naming the employees it covers. For each one this realm
// reads payroll's own views, reconstructs the settled gross, prices it through
// the schedule, and records the result. Nothing is supplied by the caller
// except the schedule and the selection: every amount comes from payroll.
//
// # WHAT THIS REALM IS, AND WHAT IT CANNOT BE
//
// It is a REPORTER. It holds no coins, has no withdrawal path, and moves
// nothing. It does not deduct the withholding it computes — payroll settles
// wages and this realm states what a graduated schedule would have withheld
// from them. The separation is deliberate and it is also forced: r/payroll is
// live and immutable, so a graduated rate cannot be charged inside it, and a
// realm that charged one here would be a second custody surface over coins
// payroll already holds.
//
// The consequence is the realm's only real safety argument and it is a strong
// one: THIS REALM CANNOT WRITE A WRONG PAYMENT, BECAUSE IT CANNOT WRITE A
// PAYMENT. The failure mode it does have is a wrong or incomplete REPORT, and
// every mitigation below is aimed there.
//
// # SETTLED IS NOT EARNED
//
// The gross on a payslip is the gross payroll has SETTLED for the position
// that is open right now:
//
//	gross = PaidPeriodsOf(employer, employee) * PerPeriodOf(employer, employee)
//
// That identity is exact rather than approximate, and the reason is structural:
// payroll exports no setter for perPeriod, so a position's rate is fixed for
// its whole life by the Hire that created it, and paidPeriods only ever
// increases. The product is therefore the position's lifetime settled gross and
// not an estimate of it.
//
// It is still not the employee's lifetime earnings under this employer, and the
// gap is not small. payroll's Release removes a settled position and frees its
// storage, and Hire refuses only while a position is OPEN — so
// Terminate → Release → Hire is a legal sequence that resets paidPeriods to
// zero and makes every period before it unreadable from any view. The Released
// event carries paidPeriods, but an event is not realm-readable. So:
//
//	A PAYSLIP IS SCOPED TO THE POSITION OPEN AT ITS OWN HEIGHT, AND MUST NEVER
//	BE READ AS LIFETIME GROSS.
//
// The failure mode is silent under-reporting, which is the one error a reader
// cannot detect from the number itself. The mitigations are that every payslip
// records its height, its own scope, and a coverage line; that [Coverage] and
// [OmittedRoster] say how much of the employer's roster the payslip left out;
// and that an employee named with no open position PANICS rather than being
// dropped — a silently-dropped line is exactly the under-report this realm
// cannot detect after the fact.
//
// # PERIODS THAT ARE DUE BUT NOT ACCRUED ARE EXCLUDED, AND DISCLOSED
//
// payroll accrues on demand: anyone may call Accrue, and until someone does,
// completed periods are due and unsettled. A payslip published before an
// Accrue therefore reports a smaller gross than the employee is owed. Rather
// than guess, each line records dueGross — DuePeriods times perPeriod at the
// payslip's height — and [UnsettledGrossOf] totals it. A payslip whose
// UnsettledGrossOf is non-zero is complete about what was settled and explicit
// about what was not.
//
// # THE PLATFORM FEE IS AN INTERVAL, AND THAT IS A MEASUREMENT
//
// payroll takes an accrual fee of AccrueFeeBps from each settlement, and the
// obvious reconstruction — a flat rate on the cumulative gross — is wrong. Its
// Accrue settles every due period in ONE deposit and floors the fee on that
// aggregate, so the fee actually taken depends on how the accruals were
// BATCHED, and payroll exports no view of the batching. What it does export is
// paidPeriods and perPeriod, and those bound the fee exactly:
//
//	feeLo = paidPeriods * floor(perPeriod * bps / RateScale)   one period per call
//	feeHi = floor(gross * bps / RateScale)                     one call for all
//
// Both endpoints are achievable, so the interval is tight and not a hedge:
// floor(x) + floor(y) <= floor(x+y) gives the upper bound, and
// floor(n*x) >= n*floor(x) gives the lower. They coincide whenever
// perPeriod * bps divides RateScale evenly, which is the common case.
//
// So [PlatformFeeRange] and [NetRange] return pairs. A single platform-fee
// number here would have been plausible, derivable, and wrong for any employee
// whose accruals were batched — and nothing on the chain would have
// contradicted it.
//
// # THE SCHEDULE PRICES GROSS, AND THE TWO DEDUCTIONS ARE NEVER COMBINED
//
// The withholding schedule is applied to gross. payroll's platform fee is a
// separate deduction that payroll has already taken. They are reported side by
// side and never folded into one effective rate, because they have different
// payees, different arithmetic (graduated versus flat) and different
// certainty (exact versus an interval).
//
// A schedule in [p/tiers] carries no identity and no effective date, and a
// falling rate array is legal there — it is a volume discount — so a
// transposed table is a silent authoring error that tiers.New cannot detect.
// Two consequences this realm acts on: every payslip SNAPSHOTS the schedule
// that priced it, so a later SetSchedule cannot retroactively re-price a
// published payslip; and [OverWithheld] names the one arithmetic outcome that
// is almost certainly an authoring error — a schedule withholding more than
// the employee actually received — rather than hiding it or refusing to
// publish it.
//
// # AUTHORITY
//
// An employer publishes about their OWN roster: the employer of every payslip
// is cur.Previous().Address(), never an argument. This realm therefore cannot
// publish a payslip about a roster the caller does not hold, and a payslip's
// key is the employer that published it.
package payslips

import (
	"chain"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"strings"

	"gno.land/p/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/tiers"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/r/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/payroll"
)

// RealmPath is this realm's own path, used to build Render links.
const RealmPath = "/r/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/payslips"

// PayrollPath is the wage source every figure here is read from.
//
// It is taken BY VALUE from that realm's own exported constant rather than
// typed out again, so this is the compile-time pin itself and not a second
// copy that could drift. The convention is r/receivables' InvoicesPath.
const PayrollPath = payroll.RealmPath

// RateScale is the unit of a withholding rate, re-exported by value from
// [p/tiers]: a rate of 2500 is 25%. Re-exported because every rate in this
// realm's API is in these units and a caller should not have to find the other
// package to learn the denominator.
const RateScale = tiers.RateScale

// MaxTiers is the widest schedule [p/tiers] will build, by value. A schedule
// has one rate per tier and one edge between each adjacent pair, so an
// employer may name at most MaxTiers rates and MaxTiers-1 edges.
const MaxTiers = tiers.MaxTiers

// PlatformFeeBps is the accrual fee r/payroll charges, taken by value from
// that realm's own constant.
//
// Taking it by value is sound here for a reason worth stating rather than
// assuming: payroll is LIVE and a realm's bytes are immutable after addpkg, so
// that constant cannot change for the payroll this realm imports. A future
// payroll version would be a different path and a different import.
const PlatformFeeBps = payroll.AccrueFeeBps

// MaxEmployeesPerCall caps how many employees one [Publish] may name, and it
// is r/payroll's own per-employer roster cap taken by value.
//
// That is the right bound and not an arbitrary one: payroll refuses a Hire
// past MaxRoster open positions, so an employer cannot have more than
// MaxRoster employees to report on, and a cap above it would admit a call that
// must contain a duplicate or an absent position. A cap below it would make
// some rosters unreportable in one call, which is the under-report this realm
// exists to avoid.
const MaxEmployeesPerCall = payroll.MaxRoster

// PayslipsAreUncapped records a decision by its absence: there is no limit on
// how many payslips one employer may publish. Each one is a fresh record and
// the storage deposit for it is paid by the caller at publish time, so the
// chain already prices the only resource at stake. A cap here would cause the
// one failure this realm cannot tolerate — an employer unable to publish the
// statement that would have disclosed an omission.
const PayslipsAreUncapped = true

// RenderPayslipLimit is how many payslips an employer's Render page lists.
// Not a storage cap — see [PayslipsAreUncapped].
const RenderPayslipLimit = 20

// line is one employee's statement within a payslip. Every field is derived
// from r/payroll's views at the payslip's own height; none is supplied by the
// caller.
type line struct {
	employee address

	// paidPeriods and perPeriod are the two payroll facts gross is built
	// from. They are kept so a reader can re-derive the gross rather than
	// take it on trust, and so the fee interval can be re-checked.
	paidPeriods int64
	perPeriod   int64

	// gross is paidPeriods * perPeriod: the settled gross of the position
	// that was open at the payslip's height. NOT lifetime gross — see the
	// package doc.
	gross int64

	// withheld is the schedule's charge on gross, floored per slice by
	// [p/tiers].
	withheld int64

	// feeLo and feeHi bound the accrual fee r/payroll already took. The
	// interval is tight and both endpoints are reachable — see the package
	// doc.
	feeLo int64
	feeHi int64

	// dueGross is gross that has completed and NOT been accrued at the
	// payslip's height. It is excluded from gross and disclosed here.
	dueGross int64

	// ended records whether the position's clock had stopped at the
	// payslip's height. An ended position can still have dueGross: payroll
	// deliberately keeps an unsettled obligation alive past Terminate.
	ended bool
}

// payslip is one published statement. Its totals are stored rather than
// recomputed so a reader gets the numbers as published, not as re-derived
// under a later schedule.
type payslip struct {
	at int64

	// sched is the schedule that priced THIS payslip, snapshotted. A
	// schedule has no identity in [p/tiers], so a later SetSchedule would
	// otherwise silently re-price every published payslip.
	sched tiers.Schedule

	// feeBps is PlatformFeeBps as this realm understood it at publish
	// time. It cannot vary while payroll is immutable; it is recorded so a
	// reader checking the fee interval does not have to resolve a constant
	// in another package to do it.
	feeBps int64

	lines []*line

	gross    int64
	withheld int64
	feeLo    int64
	feeHi    int64
	dueGross int64

	// the coverage line. listed is what the caller named; priced is what
	// was reported; the rest describe the shape of what was priced and how
	// much of the roster was left out.
	listed    int
	priced    int
	zeroGross int
	withDue   int
	ended     int
	dupes     int
	rosterAt  int
	openAt    int
}

var (
	// payslips holds one record per published statement, keyed
	// employer|padded-seq so an employer's payslips are a contiguous prefix
	// range in sequence order.
	payslips = avl.NewTree() // "<employer>|<padded seq>" -> *payslip

	// schedules holds each employer's CURRENT withholding schedule. A
	// payslip never reads this after publication; it carries its own
	// snapshot.
	schedules = avl.NewTree() // employer string -> tiers.Schedule

	// counts is both the per-employer sequence allocator and the
	// per-employer payslip count. One tree, because they are the same
	// number.
	counts = avl.NewTree() // employer string -> int

	// slipCount is the global count, for the Render index.
	slipCount int

	// platformFee is PlatformFeeBps expressed as a one-tier [p/tiers]
	// schedule, which is how this realm computes the fee endpoints.
	//
	// Reusing the audited primitive instead of writing the arithmetic again
	// is the point. A one-tier schedule is a flat rate, tiers.Charge floors
	// it, and tiers does the multiply through bits.Mul64/Div64 so a product
	// near the int64 ceiling cannot wrap. MEASURED EQUIVALENCE: p/feeledger's
	// feeFor computes (x/10000)*bps + (x%10000)*bps/10000, which is exactly
	// floor(x*bps/10000) and so exactly this schedule's charge.
	//
	// That equivalence is the hinge the whole fee interval hangs from, so it
	// is BOTH argued and asserted, and the assertion is NAMED rather than
	// gestured at: TestPlatformFeeScheduleAgreesWithFeeledger compares the
	// two engines two-sidedly over an amount sample and the whole legal bps
	// range. An earlier draft of this comment said the equivalence "is
	// asserted in the test suite rather than argued here" while the suite did
	// not import p/feeledger at all -- it pointed a reader at evidence that
	// was not there, on the one fact it names load-bearing. A citation with no
	// referent is worse than no citation, and this text is frozen by addpkg
	// while a test is not, which is why the name is written in.
	//
	// CEILING: that test is a sample, not a proof over int64. The exhaustive
	// claim is the identity above; the test is what fires if either primitive
	// is ever redeployed with different rounding.
	platformFee = mustFlat(PlatformFeeBps)
)

func mustFlat(bps int64) tiers.Schedule {
	s, err := tiers.New(nil, []int64{bps})
	if err != nil {
		panic("payslips: the platform-fee schedule is invalid: " + err.Error())
	}
	return s
}

// refuseCoins aborts when a direct EOA MsgCall attaches coins to an
// entrypoint here. This realm has no custody and no withdrawal path, so a
// send would be unrecoverable by anyone — including the sender.
//
// The IsCurrent() check is not decoration. Every call site forwards a crossing
// entrypoint's own live cur, so it cannot fire today; it exists so a future
// refactor that hands this helper a stale realm value fails closed instead of
// trusting it. That shape is security.md's Class 2 and it has been found in
// this portfolio's own realms more than once.
func refuseCoins(cur realm) {
	if !cur.IsCurrent() {
		panic("payslips: realm capability is not current")
	}
	if cur.Previous().IsUserCall() && len(unsafe.OriginSend()) > 0 {
		panic("payslips: this realm holds no coins and has no withdrawal path; send none")
	}
}

// --- the schedule ---

// SetSchedule installs the caller's own withholding schedule and returns its
// tier count.
//
// edges and rates are comma-separated int64 lists in [p/tiers]'s units: rates
// are of [RateScale], edges are gross amounts in ugnot. There is one more rate
// than there are edges, because the last tier is unbounded. An EMPTY edges
// string is legal and means a one-tier schedule — a flat rate — which is the
// shape to use for a flat withholding and the shape this realm uses internally
// for the platform fee.
//
//	SetSchedule(cross(cur), "1000000,5000000", "500,1500,2500")
//
// is 5% on the first 1,000,000 ugnot of gross, 15% on the next 4,000,000, and
// 25% above 5,000,000.
//
// REPLACING A SCHEDULE DOES NOT RE-PRICE ANYTHING. Every published payslip
// carries the schedule that priced it, so this only affects payslips published
// after it. That is a design requirement rather than a convenience: a
// published statement whose numbers change under it is not a record.
//
// A FALLING RATE ARRAY IS ACCEPTED, because [p/tiers] accepts one — it is a
// volume discount, which is a real schedule. The consequence is that a
// transposed array is a silent authoring error here, and neither this realm
// nor tiers can detect it. Read back [ScheduleOf] after setting one.
func SetSchedule(cur realm, edges, rates string) int {
	refuseCoins(cur)
	employer := cur.Previous().Address()

	var e []int64
	if strings.TrimSpace(edges) != "" {
		e = parseInt64List(edges, MaxTiers-1, "edge")
	}
	r := parseInt64List(rates, MaxTiers, "rate")

	s, err := tiers.New(e, r)
	if err != nil {
		panic("payslips: " + err.Error())
	}
	schedules.Set(employer.String(), s)
	chain.Emit("ScheduleSet",
		"employer", employer.String(),
		"tiers", strconv.Itoa(s.NumTiers()),
		"edges", formatInt64List(s.Edges()),
		"rates", formatInt64List(s.Rates()))
	return s.NumTiers()
}

// --- publishing ---

// Publish prices the named employees under the caller's own roster and records
// a payslip. It returns the payslip's sequence number, which is per-employer
// and starts at 1.
//
// employees is a comma-separated list of addresses, at most
// [MaxEmployeesPerCall] of them. Order is the caller's and is preserved in the
// record, so a payslip reads in the order it was requested.
//
// THREE REFUSAL RULES, AND THE ASYMMETRY BETWEEN THEM IS THE POINT:
//
//   - An employee with NO OPEN POSITION under the caller PANICS and fails the
//     whole call. A silently-dropped line is an under-report, and under-
//     reporting is the one error this product cannot detect after the fact. A
//     caller that wants to skip an absent position must leave it out, which is
//     a decision in the transaction rather than a silence in the record.
//   - A DUPLICATE is dropped, counted in the coverage line, and does not fail
//     the call. Dropping it cannot under-report: the employee is still priced
//     once, and double-counting them would be worse.
//   - An employee with ZERO SETTLED GROSS is PRICED, not filtered. A payslip
//     for a position that has settled nothing yet is a correct payslip with a
//     gross of zero, and filtering it would turn a true statement into a
//     missing line.
//
// An empty list is refused. Nothing here filters a list down to nothing, so
// after deduplication a call always prices at least one employee.
func Publish(cur realm, employees string) int64 {
	refuseCoins(cur)
	employer := cur.Previous().Address()
	s := mustSchedule(employer)
	now := runtime.ChainHeight()

	list, dupes := parseEmployees(employees)

	lines := make([]*line, 0, len(list))
	var gross, withheld, feeLo, feeHi, dueGross int64
	var zeroGross, withDue, ended int

	for _, who := range list {
		// Existence first, and with the one payroll view that does not
		// panic on absence: every other position accessor there panics,
		// which makes them unusable as a probe. The panic below is this
		// realm's refusal, with this realm's message.
		if !payroll.HasPosition(employer, who) {
			panic("payslips: " + who.String() +
				" has no open position under " + employer.String() +
				"; a dropped line would be a silent under-report")
		}

		l := priceOne(employer, who, s, now)
		lines = append(lines, l)

		var ok bool
		if gross, ok = checkedAdd(gross, l.gross); !ok {
			panic("payslips: total gross would overflow")
		}
		if withheld, ok = checkedAdd(withheld, l.withheld); !ok {
			panic("payslips: total withholding would overflow")
		}
		if feeLo, ok = checkedAdd(feeLo, l.feeLo); !ok {
			panic("payslips: total platform-fee floor would overflow")
		}
		if feeHi, ok = checkedAdd(feeHi, l.feeHi); !ok {
			panic("payslips: total platform-fee ceiling would overflow")
		}
		if dueGross, ok = checkedAdd(dueGross, l.dueGross); !ok {
			panic("payslips: total unsettled gross would overflow")
		}

		if l.gross == 0 {
			zeroGross++
		}
		if l.dueGross > 0 {
			withDue++
		}
		if l.ended {
			ended++
		}
	}

	// Cross-foot the per-line columns against the totals. The loop above
	// already built them, so this asserts nothing about the arithmetic — it
	// asserts that the record about to be stored agrees with the lines
	// stored beside it, which is the one inconsistency a reader of a view
	// could not see.
	crossFoot(lines, gross, withheld, feeLo, feeHi, dueGross)

	// feeLo <= feeHi is an identity of the two bounds, not an assumption.
	// If it ever fails, the fee interval is not an interval and no number
	// derived from it is quotable, so this refuses rather than publishes.
	if feeLo > feeHi {
		panic("payslips: the platform-fee interval is inverted")
	}

	key := employer.String()
	seq := int64(employerCount(key)) + 1
	payslips.Set(slipKey(key, seq), &payslip{
		at:        now,
		sched:     s,
		feeBps:    PlatformFeeBps,
		lines:     lines,
		gross:     gross,
		withheld:  withheld,
		feeLo:     feeLo,
		feeHi:     feeHi,
		dueGross:  dueGross,
		listed:    len(list) + dupes,
		priced:    len(lines),
		zeroGross: zeroGross,
		withDue:   withDue,
		ended:     ended,
		dupes:     dupes,

		// The incompleteness disclosure. rosterAt is how many open
		// positions the employer held at this height, so
		// rosterAt - priced is exactly how many this payslip did not
		// cover. openAt is the chain-wide figure, which is what makes
		// an employer's share of the realm legible.
		rosterAt: payroll.RosterOf(employer),
		openAt:   payroll.OpenPositions(),
	})
	counts.Set(key, int(seq))
	slipCount++

	// Every attribute here reads the record that was just stored, and
	// `omitted` goes through [OmittedRoster] rather than recomputing
	// rosterAt - priced. Two reasons, and the second is the load-bearing one:
	//
	//   - a second payroll.RosterOf call is a second chain read, and nothing
	//     guarantees it agrees with the rosterAt now frozen in the record;
	//   - AN EMITTED ATTRIBUTE IS UNASSERTABLE FROM A GNO UNIT TEST. chain.Emit
	//     has no reader and the testing stdlib exposes none, so an event copy
	//     of a derived figure has no control over it at all. Routing it through
	//     the exported accessor the suite does pin makes the event unable to
	//     disagree with Coverage by construction, which is the only mitigation
	//     available at this layer. Measured: a sabotage replacing this figure
	//     with len(lines) was UNCAUGHT by a 33-test suite.
	chain.Emit("PayslipPublished",
		"employer", key,
		"seq", strconv.FormatInt(seq, 10),
		"at", strconv.FormatInt(now, 10),
		"lines", strconv.Itoa(len(lines)),
		"gross", strconv.FormatInt(gross, 10),
		"withheld", strconv.FormatInt(withheld, 10),
		"feeLo", strconv.FormatInt(feeLo, 10),
		"feeHi", strconv.FormatInt(feeHi, 10),
		"dueGross", strconv.FormatInt(dueGross, 10),
		"omitted", strconv.Itoa(OmittedRoster(employer, seq)))
	return seq
}

// priceOne builds one line from r/payroll's views. Every arithmetic refusal
// here is a panic rather than a zero, because a view that refuses is
// recoverable and a view that lies is not — payroll's own DueAmount states the
// same rule for the same reason.
func priceOne(employer, who address, s tiers.Schedule, now int64) *line {
	pp := payroll.PaidPeriodsOf(employer, who)
	per := payroll.PerPeriodOf(employer, who)

	gross, ok := checkedMul(pp, per)
	if !ok {
		panic("payslips: settled gross for " + who.String() +
			" would overflow; read PaidPeriodsOf and PerPeriodOf directly")
	}

	withheld, err := s.Charge(gross)
	if err != nil {
		panic("payslips: " + err.Error())
	}
	// p/tiers guarantees Charge(n) <= n. Asserting it costs one comparison
	// and turns a broken dependency into a refusal instead of a payslip
	// claiming more was withheld than was earned.
	if withheld > gross {
		panic("payslips: withholding exceeds gross, which p/tiers forbids")
	}

	// The fee interval. Both endpoints go through the same audited
	// primitive; see the platformFee var for why.
	feeHi, err := platformFee.Charge(gross)
	if err != nil {
		panic("payslips: " + err.Error())
	}
	unit, err := platformFee.Charge(per)
	if err != nil {
		panic("payslips: " + err.Error())
	}
	feeLo, ok := checkedMul(pp, unit)
	if !ok {
		panic("payslips: platform-fee floor for " + who.String() + " would overflow")
	}

	dp := payroll.DuePeriods(employer, who)
	dueGross, ok := checkedMul(dp, per)
	if !ok {
		panic("payslips: unsettled gross for " + who.String() +
			" would overflow; read DuePeriods and PerPeriodOf directly")
	}

	end := payroll.EndHeightOf(employer, who)

	return &line{
		employee:    who,
		paidPeriods: pp,
		perPeriod:   per,
		gross:       gross,
		withheld:    withheld,
		feeLo:       feeLo,
		feeHi:       feeHi,
		dueGross:    dueGross,
		ended:       end != payroll.OpenEnded && end <= now,
	}
}

func crossFoot(lines []*line, gross, withheld, feeLo, feeHi, dueGross int64) {
	var g, w, lo, hi, d int64
	for _, l := range lines {
		g += l.gross
		w += l.withheld
		lo += l.feeLo
		hi += l.feeHi
		d += l.dueGross
	}
	if g != gross || w != withheld || lo != feeLo || hi != feeHi || d != dueGross {
		panic("payslips: the stored totals do not agree with the stored lines")
	}
}

// --- reading a payslip ---

// PublishedAt is the height a payslip was published at, which is the height
// every figure in it was read at.
func PublishedAt(employer address, seq int64) int64 {
	return mustPayslip(employer, seq).at
}

// GrossOf is a payslip's total SETTLED gross. Read it beside
// [UnsettledGrossOf] and [OmittedRoster]: neither is an error, and both change
// what this number means.
func GrossOf(employer address, seq int64) int64 {
	return mustPayslip(employer, seq).gross
}

// WithheldOf is the schedule's total charge on the gross.
func WithheldOf(employer address, seq int64) int64 {
	return mustPayslip(employer, seq).withheld
}

// PlatformFeeRange bounds the accrual fee r/payroll already took on this
// gross. It is an interval because the fee depends on accrual batching, which
// payroll does not expose — see the package doc. lo == hi is common and means
// the batching could not have mattered.
func PlatformFeeRange(employer address, seq int64) (lo, hi int64) {
	p := mustPayslip(employer, seq)
	return p.feeLo, p.feeHi
}

// NetRange bounds what the employee kept: gross, less the schedule's
// withholding, less payroll's fee. The interval is inherited whole from
// [PlatformFeeRange] — the withholding itself is exact.
//
// IT CAN BE NEGATIVE, and that is a finding rather than a bug. A schedule may
// legally charge up to 100%, and payroll's fee is taken on top of whatever
// this realm withholds, so a schedule at or near the ceiling withholds more
// than the employee actually received. [OverWithheld] names that case.
func NetRange(employer address, seq int64) (lo, hi int64) {
	p := mustPayslip(employer, seq)
	return p.gross - p.withheld - p.feeHi, p.gross - p.withheld - p.feeLo
}

// UnsettledGrossOf is gross that had completed and not been accrued at the
// payslip's height, and is therefore EXCLUDED from [GrossOf]. Non-zero is
// normal: payroll accrues on demand.
func UnsettledGrossOf(employer address, seq int64) int64 {
	return mustPayslip(employer, seq).dueGross
}

// OverWithheld reports whether this payslip's withholding plus payroll's
// largest possible fee exceeds the gross. True is almost always a transposed
// or mis-scaled rate array, which [p/tiers] cannot detect, so this realm
// surfaces it instead of refusing to publish it — a refusal would lose the
// evidence.
func OverWithheld(employer address, seq int64) bool {
	lo, _ := NetRange(employer, seq)
	return lo < 0
}

// FeeBpsAt is the platform fee rate this payslip was priced against.
func FeeBpsAt(employer address, seq int64) int64 {
	return mustPayslip(employer, seq).feeBps
}

// ScheduleAt is the schedule that priced this payslip, as comma-separated
// lists that round-trip exactly through [SetSchedule]. The snapshot, not the
// employer's current schedule — see [ScheduleOf] for that.
func ScheduleAt(employer address, seq int64) (edges, rates string) {
	s := mustPayslip(employer, seq).sched
	return formatInt64List(s.Edges()), formatInt64List(s.Rates())
}

// Coverage is the payslip's coverage line, and it is the number to read before
// any total.
//
//	listed     employees the caller named, duplicates included
//	priced     lines in the record
//	zeroGross  priced lines whose settled gross is zero
//	withDue    priced lines with gross due and not accrued
//	ended      priced lines whose position's clock had stopped
//	dupes      duplicate names dropped
//	rosterAt   open positions the employer held at this height
//	openAt     open positions across every employer at this height
//
// listed == priced + dupes always, by construction: nothing else is dropped.
// rosterAt - priced is [OmittedRoster].
func Coverage(employer address, seq int64) (listed, priced, zeroGross, withDue, ended, dupes, rosterAt, openAt int) {
	p := mustPayslip(employer, seq)
	return p.listed, p.priced, p.zeroGross, p.withDue, p.ended, p.dupes, p.rosterAt, p.openAt
}

// OmittedRoster is how many of the employer's open positions this payslip did
// not price. It is the one number that says whether a payslip is complete, and
// a total read without it is being read wrongly.
//
// It cannot be negative: every priced line has an open position under this
// employer at the payslip's height, duplicates are dropped before pricing, so
// priced is a count of distinct open positions and rosterAt is their total.
func OmittedRoster(employer address, seq int64) int {
	p := mustPayslip(employer, seq)
	return p.rosterAt - p.priced
}

// Lines is how many employees a payslip prices.
func Lines(employer address, seq int64) int {
	return len(mustPayslip(employer, seq).lines)
}

// LineAt is one employee's statement, by index in the order the caller named
// them. gross is paidPeriods * perPeriod and can be re-derived from the two
// facts returned beside it.
func LineAt(employer address, seq int64, i int) (employee address, paidPeriods, perPeriod, gross, withheld, feeLo, feeHi, dueGross int64) {
	l := mustLine(employer, seq, i)
	return l.employee, l.paidPeriods, l.perPeriod, l.gross, l.withheld, l.feeLo, l.feeHi, l.dueGross
}

// LineEnded reports whether this line's position had been terminated or had
// passed its end height when the payslip was published. An ended position can
// still carry unsettled gross: payroll keeps the obligation alive past
// Terminate on purpose.
func LineEnded(employer address, seq int64, i int) bool {
	return mustLine(employer, seq, i).ended
}

// LineNetRange bounds what this employee kept. Same interval as [NetRange],
// one line.
func LineNetRange(employer address, seq int64, i int) (lo, hi int64) {
	l := mustLine(employer, seq, i)
	return l.gross - l.withheld - l.feeHi, l.gross - l.withheld - l.feeLo
}

// TierBreakdown is the withholding on one line split by bracket, as a
// comma-separated list in tier order — the column a payslip reader actually
// wants, because it shows which brackets the gross reached.
//
// It is recomputed from the payslip's own schedule snapshot rather than
// stored, so it is exact for the schedule that priced the line and costs no
// storage. It cross-foots the column against the stored total before returning
// it: [p/tiers] DOCUMENTS that Charge is defined as the sum of ChargeByTier,
// and a documented identity across a package boundary is worth one loop to
// assert.
func TierBreakdown(employer address, seq int64, i int) string {
	p := mustPayslip(employer, seq)
	l := mustLine(employer, seq, i)
	col, err := p.sched.ChargeByTier(l.gross)
	if err != nil {
		panic("payslips: " + err.Error())
	}
	var sum int64
	for _, c := range col {
		sum += c
	}
	if sum != l.withheld {
		panic("payslips: the per-tier column does not sum to the withholding")
	}
	return formatInt64List(col)
}

// --- reading an employer ---

// ScheduleOf is an employer's CURRENT schedule, as lists that round-trip
// through [SetSchedule]. It is not what priced any published payslip — see
// [ScheduleAt].
func ScheduleOf(employer address) (edges, rates string) {
	s := mustSchedule(employer)
	return formatInt64List(s.Edges()), formatInt64List(s.Rates())
}

// NumTiersOf is how many brackets an employer's current schedule has.
func NumTiersOf(employer address) int { return mustSchedule(employer).NumTiers() }

// HasSchedule reports whether an employer has set a schedule, without
// panicking on absence — every other schedule accessor panics, which makes
// them unusable as an existence probe.
func HasSchedule(employer address) bool {
	_, ok := schedules.Get(employer.String()).(tiers.Schedule)
	return ok
}

// Has reports whether a payslip exists, so the record accessors can be
// pre-checked rather than recovered from. Every one of them panics on an
// absent record, which is deliberate — returning a zero figure for a payslip
// that was never published is the exact silent under-report this realm exists
// to refuse — but a panic is only a usable contract when the caller has a way
// not to hit it.
//
// It is here before the first deploy rather than in a successor because a
// realm's bytes are frozen by addpkg: an accessor a consumer needs cannot be
// added afterwards.
func Has(employer address, seq int64) bool {
	_, ok := payslips.Get(slipKey(employer.String(), seq)).(*payslip)
	return ok
}

// ChargeOn quotes an employer's current schedule against an arbitrary gross
// without publishing anything. The quote a caller needs before choosing a
// schedule, and the one view here that is not about a record.
func ChargeOn(employer address, gross int64) int64 {
	c, err := mustSchedule(employer).Charge(gross)
	if err != nil {
		panic("payslips: " + err.Error())
	}
	return c
}

// MarginalRateOf is the rate an employer's current schedule would charge on
// the next ugnot of gross past the given amount, of [RateScale].
func MarginalRateOf(employer address, gross int64) int64 {
	r, err := mustSchedule(employer).MarginalRate(gross)
	if err != nil {
		panic("payslips: " + err.Error())
	}
	return r
}

// Count is how many payslips an employer has published. Sequence numbers run
// 1..Count with no gaps: a payslip is never removed.
func Count(employer address) int { return employerCount(employer.String()) }

// Payslips is how many payslips exist across every employer.
func Payslips() int { return slipCount }

// Employers is how many addresses have set a schedule here. Note the tense: a
// schedule survives, so this is not a count of employers with payslips.
func Employers() int { return schedules.Size() }

// Height is the current chain height, exposed so a caller can see the clock
// this realm reads payroll against.
func Height() int64 { return runtime.ChainHeight() }

// --- internals ---

// parseEmployees splits, validates and deduplicates the selection, preserving
// the caller's order. It returns the distinct list and how many duplicates
// were dropped.
//
// The cap is checked BEFORE the slice grows, so a caller cannot make this
// realm allocate past the bound on the way to being refused.
func parseEmployees(s string) ([]address, int) {
	parts := strings.Split(s, ",")
	if len(parts) > MaxEmployeesPerCall {
		panic("payslips: at most " + strconv.Itoa(MaxEmployeesPerCall) +
			" employees, got " + strconv.Itoa(len(parts)))
	}
	out := make([]address, 0, len(parts))
	dupes := 0
	for _, raw := range parts {
		t := strings.TrimSpace(raw)
		if t == "" {
			panic("payslips: empty employee in " + strconv.Quote(s))
		}
		who := address(t)

		// The lowercase clause is carried from r/payroll's Hire, where it
		// is measured: address.IsValid() defers to a decoder that
		// lowercases before verifying the checksum, so it returns true for
		// the all-uppercase spelling of a valid address.
		//
		// HERE THE STAKE IS DIFFERENT FROM PAYROLL'S AND SMALLER, which is
		// why this is a guard and not a loss-prevention control. payroll
		// keys its ledger on this string, so an uppercase spelling there
		// stranded real coins. This realm would merely fail to find the
		// position and panic at HasPosition — already fail-closed. The
		// guard is kept because that panic would name the wrong cause: a
		// caller would read "has no open position" about an employee who
		// plainly does. A refusal that misdiagnoses itself is how a real
		// defect gets attributed to the chain.
		if !who.IsValid() || t != strings.ToLower(t) {
			panic("payslips: " + strconv.Quote(t) +
				" is not a valid address in canonical (lowercase) form")
		}

		seen := false
		for _, have := range out {
			if have == who {
				seen = true
				break
			}
		}
		if seen {
			dupes++
			continue
		}
		out = append(out, who)
	}
	if len(out) == 0 {
		panic("payslips: no employees named")
	}
	return out, dupes
}

func parseInt64List(s string, max int, what string) []int64 {
	parts := strings.Split(s, ",")
	if len(parts) > max {
		panic("payslips: at most " + strconv.Itoa(max) + " " + what +
			"s, got " + strconv.Itoa(len(parts)))
	}
	out := make([]int64, 0, len(parts))
	for _, p := range parts {
		t := strings.TrimSpace(p)
		if t == "" {
			panic("payslips: empty " + what + " in " + strconv.Quote(s))
		}
		v, err := strconv.ParseInt(t, 10, 64)
		if err != nil {
			panic("payslips: " + strconv.Quote(t) + " is not a valid " + what)
		}
		out = append(out, v)
	}
	return out
}

func formatInt64List(v []int64) string {
	var sb strings.Builder
	for i, n := range v {
		if i > 0 {
			sb.WriteString(",")
		}
		sb.WriteString(strconv.FormatInt(n, 10))
	}
	return sb.String()
}

// slipKey left-pads seq to the width of MaxInt64 so that an employer's
// payslips sort in numeric order under the tree's lexical key order.
//
// NOTHING IN THIS REALM CONSUMES THAT ORDER TODAY, and the padding is in the
// source anyway. The tree is only ever Set and Get here — renderEmployer walks
// the sequence numbers it already knows from [Count] rather than iterating —
// so unpadded keys would produce byte-identical output from every view, and no
// test can distinguish the two. It is kept because the bytes freeze at addpkg:
// an enumerator added in a successor realm, or an off-chain indexer doing a
// prefix scan over this realm's storage, would read "10" before "9" forever,
// and the fix would be unavailable. Twelve bytes of padding now against a
// defect that cannot be repaired later.
//
// Stated this way deliberately. The comment here used to claim the padding is
// "what makes a prefix iteration in Render read in sequence", which is a
// reachability argument for a prefix iteration that does not exist.
func slipKey(employer string, seq int64) string {
	s := strconv.FormatInt(seq, 10)
	for len(s) < 19 {
		s = "0" + s
	}
	return employer + "|" + s
}

func employerCount(employer string) int {
	n, ok := counts.Get(employer).(int)
	if !ok {
		return 0
	}
	return n
}

func mustSchedule(employer address) tiers.Schedule {
	s, ok := schedules.Get(employer.String()).(tiers.Schedule)
	if !ok {
		panic("payslips: " + employer.String() +
			" has no withholding schedule; call SetSchedule first")
	}
	return s
}

func mustPayslip(employer address, seq int64) *payslip {
	p, ok := payslips.Get(slipKey(employer.String(), seq)).(*payslip)
	if !ok {
		panic("payslips: no payslip " + strconv.FormatInt(seq, 10) +
			" for " + employer.String())
	}
	return p
}

func mustLine(employer address, seq int64, i int) *line {
	p := mustPayslip(employer, seq)
	if i < 0 || i >= len(p.lines) {
		panic("payslips: line " + strconv.Itoa(i) + " is out of range for payslip " +
			strconv.FormatInt(seq, 10) + ", which has " +
			strconv.Itoa(len(p.lines)) + " lines")
	}
	return p.lines[i]
}

func checkedAdd(a, b int64) (int64, bool) {
	s := a + b
	if (b > 0 && s < a) || (b < 0 && s > a) {
		return 0, false
	}
	return s, true
}

// checkedMul is written for the non-negative operands this realm has — every
// multiplicand is a period count or a per-period amount, both of which
// r/payroll refuses to make negative. The division test is exact for those.
func checkedMul(a, b int64) (int64, bool) {
	if a < 0 || b < 0 {
		return 0, false
	}
	if a == 0 || b == 0 {
		return 0, true
	}
	p := a * b
	if p/b != a {
		return 0, false
	}
	return p, true
}

// ---------------------------------------------------------------------------

// Render serves the index at "", an employer's page at "<address>", and one
// payslip at "<address>/<seq>".
//
// Every caller-supplied string reaching the output goes through the sanitizer.
// This realm stores no free text, so the untrusted bytes are the path itself
// and the addresses in a record — and that is still the one injection-shaped
// surface a realm with no custody has.
func Render(path string) string {
	p := strings.TrimSpace(strings.Trim(path, "/"))
	if p == "" {
		return renderIndex()
	}
	if i := strings.Index(p, "/"); i >= 0 {
		employer := address(strings.TrimSpace(p[:i]))
		rest := strings.TrimSpace(strings.Trim(p[i+1:], "/"))
		seq, err := strconv.ParseInt(rest, 10, 64)
		if err != nil {
			return "# payslips\n\n`" + sanitize.InlineText(rest) +
				"` is not a payslip number.\n"
		}
		return renderPayslip(employer, seq)
	}
	return renderEmployer(address(p))
}

func renderIndex() string {
	var sb strings.Builder
	sb.WriteString("# payslips — graduated withholding over a live payroll\n\n")
	sb.WriteString("Withholding statements priced from wage facts in [`" +
		PayrollPath + "`](" + PayrollPath + ") — never from amounts supplied ")
	sb.WriteString("here. This realm holds no coins, moves nothing, and ")
	sb.WriteString("deducts nothing: it states what a bracket schedule would ")
	sb.WriteString("have withheld from gross that payroll has already ")
	sb.WriteString("settled.\n\n")

	sb.WriteString("> **A payslip covers the position that was open at its ")
	sb.WriteString("own height, and nothing else.** `" + PayrollPath + "`'s ")
	sb.WriteString("Release removes a settled position, so a re-hire resets ")
	sb.WriteString("the period count and earlier periods become unreadable ")
	sb.WriteString("from any view. A gross here is therefore never lifetime ")
	sb.WriteString("gross. Every payslip publishes a coverage line, and ")
	sb.WriteString("`OmittedRoster` is the one number that says whether it ")
	sb.WriteString("is complete.\n\n")

	sb.WriteString("> **The platform fee is an interval.** payroll floors its ")
	sb.WriteString("accrual fee on each settlement and settles every due ")
	sb.WriteString("period in one deposit, so the fee it took depends on how ")
	sb.WriteString("the accruals were batched — which no view exposes. ")
	sb.WriteString("`PlatformFeeRange` bounds it tightly from the two facts ")
	sb.WriteString("that are exposed. A single number would have been ")
	sb.WriteString("plausible and wrong.\n\n")

	sb.WriteString("| | |\n|---|---|\n")
	sb.WriteString("| payslips published | " + strconv.Itoa(slipCount) + " |\n")
	sb.WriteString("| employers with a schedule | " + strconv.Itoa(schedules.Size()) + " |\n")
	sb.WriteString("| platform fee | " + strconv.FormatInt(PlatformFeeBps, 10) +
		" of " + strconv.FormatInt(RateScale, 10) + " |\n")
	sb.WriteString("| widest schedule | " + strconv.Itoa(MaxTiers) + " tiers |\n")
	sb.WriteString("| employees per payslip | at most " +
		strconv.Itoa(MaxEmployeesPerCall) + " |\n\n")

	sb.WriteString("Browse an employer at `" + RealmPath + ":<address>`.\n")
	return sb.String()
}

func renderEmployer(employer address) string {
	var sb strings.Builder
	name := sanitize.InlineText(employer.String())
	sb.WriteString("# payslips — " + name + "\n\n")

	if HasSchedule(employer) {
		e, r := ScheduleOf(employer)
		sb.WriteString("Current schedule: edges `" + sanitize.InlineText(e) +
			"` (gross, ugnot), rates `" + sanitize.InlineText(r) + "` (of " +
			strconv.FormatInt(RateScale, 10) + ").\n\n")
		sb.WriteString("A replacement does not re-price a published payslip — ")
		sb.WriteString("each one carries the schedule that priced it.\n\n")
	} else {
		sb.WriteString("No withholding schedule set. `SetSchedule` first; ")
		sb.WriteString("`Publish` refuses without one.\n\n")
	}

	n := employerCount(employer.String())
	sb.WriteString("Open positions now: " +
		strconv.Itoa(payroll.RosterOf(employer)) + ". Payslips published: " +
		strconv.Itoa(n) + ".\n\n")
	if n == 0 {
		return sb.String()
	}

	sb.WriteString("| # | height | lines | gross | withheld | fee (lo–hi) | omitted |\n")
	sb.WriteString("|---|---|---|---|---|---|---|\n")
	first := int64(1)
	if int64(n) > int64(RenderPayslipLimit) {
		first = int64(n) - int64(RenderPayslipLimit) + 1
	}
	for seq := int64(n); seq >= first; seq-- {
		p := mustPayslip(employer, seq)
		s := strconv.FormatInt(seq, 10)
		sb.WriteString("| [" + s + "](" + RealmPath + ":" + name + "/" + s + ") | " +
			strconv.FormatInt(p.at, 10) + " | " +
			strconv.Itoa(len(p.lines)) + " | " +
			strconv.FormatInt(p.gross, 10) + " | " +
			strconv.FormatInt(p.withheld, 10) + " | " +
			strconv.FormatInt(p.feeLo, 10) + "–" +
			strconv.FormatInt(p.feeHi, 10) + " | " +
			strconv.Itoa(p.rosterAt-p.priced) + " |\n")
	}
	if int64(n) > int64(RenderPayslipLimit) {
		sb.WriteString("\nShowing the most recent " +
			strconv.Itoa(RenderPayslipLimit) + " of " + strconv.Itoa(n) +
			". Older ones are still readable by number — nothing is removed.\n")
	}
	return sb.String()
}

func renderPayslip(employer address, seq int64) string {
	name := sanitize.InlineText(employer.String())

	// A URL is caller-supplied, so an absent record is a wrong guess and not a
	// broken invariant. The accessors panic on purpose; a page does not, and
	// gnoweb serves a panic as an error rather than as markdown. This is the
	// receivables precedent (receivables.gno renderReport), followed here
	// deliberately rather than diverged from.
	if !Has(employer, seq) {
		return "# payslips\n\nNo payslip " + strconv.FormatInt(seq, 10) +
			" for `" + name + "`.\n"
	}
	p := mustPayslip(employer, seq)

	var sb strings.Builder
	sb.WriteString("# payslip " + strconv.FormatInt(seq, 10) + " — " + name + "\n\n")
	sb.WriteString("Published at height " + strconv.FormatInt(p.at, 10) +
		", priced from [`" + PayrollPath + "`](" + PayrollPath + ").\n\n")

	netLo := p.gross - p.withheld - p.feeHi
	netHi := p.gross - p.withheld - p.feeLo

	sb.WriteString("| | |\n|---|---|\n")
	sb.WriteString("| settled gross | " + strconv.FormatInt(p.gross, 10) + " |\n")
	sb.WriteString("| withheld by schedule | " + strconv.FormatInt(p.withheld, 10) + " |\n")
	sb.WriteString("| payroll accrual fee | " + strconv.FormatInt(p.feeLo, 10) +
		" – " + strconv.FormatInt(p.feeHi, 10) + " |\n")
	sb.WriteString("| net to employees | " + strconv.FormatInt(netLo, 10) +
		" – " + strconv.FormatInt(netHi, 10) + " |\n")
	sb.WriteString("| gross due, not accrued | " +
		strconv.FormatInt(p.dueGross, 10) + " |\n\n")

	if netLo < 0 {
		sb.WriteString("> **Over-withheld.** The schedule charges more than ")
		sb.WriteString("the employee received after payroll's fee. That is a ")
		sb.WriteString("legal schedule and almost certainly a transposed or ")
		sb.WriteString("mis-scaled rate array — `p/tiers` cannot detect one. ")
		sb.WriteString("The payslip is published rather than refused so the ")
		sb.WriteString("evidence survives.\n\n")
	}
	if p.dueGross > 0 {
		sb.WriteString("> **" + strconv.Itoa(p.withDue) + " of " +
			strconv.Itoa(p.priced) + " lines carry gross that had completed ")
		sb.WriteString("and not been accrued.** It is excluded from the gross ")
		sb.WriteString("above, by design: this realm reports what payroll ")
		sb.WriteString("settled, and payroll accrues on demand.\n\n")
	}

	sb.WriteString("## Coverage\n\n")
	sb.WriteString("| | |\n|---|---|\n")
	sb.WriteString("| named | " + strconv.Itoa(p.listed) + " |\n")
	sb.WriteString("| priced | " + strconv.Itoa(p.priced) + " |\n")
	sb.WriteString("| duplicates dropped | " + strconv.Itoa(p.dupes) + " |\n")
	sb.WriteString("| zero settled gross | " + strconv.Itoa(p.zeroGross) + " |\n")
	sb.WriteString("| positions ended | " + strconv.Itoa(p.ended) + " |\n")
	sb.WriteString("| employer's open positions then | " +
		strconv.Itoa(p.rosterAt) + " |\n")
	sb.WriteString("| **omitted from this payslip** | **" +
		strconv.Itoa(p.rosterAt-p.priced) + "** |\n")
	sb.WriteString("| open positions chain-wide then | " +
		strconv.Itoa(p.openAt) + " |\n\n")
	if p.rosterAt-p.priced > 0 {
		sb.WriteString("> The employer held " + strconv.Itoa(p.rosterAt) +
			" open positions and this payslip prices " + strconv.Itoa(p.priced) +
			". `" + PayrollPath + "` exports no per-employer enumerator, so ")
		sb.WriteString("this realm cannot find the omitted ones — it can only ")
		sb.WriteString("count them. A total read without this line is being ")
		sb.WriteString("read wrongly.\n\n")
	}

	sb.WriteString("## Schedule that priced this payslip\n\n")
	sb.WriteString("Edges `" + sanitize.InlineText(formatInt64List(p.sched.Edges())) +
		"`, rates `" + sanitize.InlineText(formatInt64List(p.sched.Rates())) +
		"` (of " + strconv.FormatInt(RateScale, 10) + "), " +
		strconv.Itoa(p.sched.NumTiers()) + " tiers. Platform fee " +
		strconv.FormatInt(p.feeBps, 10) + " of " +
		strconv.FormatInt(RateScale, 10) + ".\n\n")

	sb.WriteString("## Lines\n\n")
	sb.WriteString("| employee | periods | per period | gross | withheld | fee (lo–hi) | due, unaccrued |\n")
	sb.WriteString("|---|---|---|---|---|---|---|\n")
	for _, l := range p.lines {
		mark := ""
		if l.ended {
			mark = " (ended)"
		}
		sb.WriteString("| `" + sanitize.InlineText(l.employee.String()) + "`" +
			mark + " | " + strconv.FormatInt(l.paidPeriods, 10) + " | " +
			strconv.FormatInt(l.perPeriod, 10) + " | " +
			strconv.FormatInt(l.gross, 10) + " | " +
			strconv.FormatInt(l.withheld, 10) + " | " +
			strconv.FormatInt(l.feeLo, 10) + "–" +
			strconv.FormatInt(l.feeHi, 10) + " | " +
			strconv.FormatInt(l.dueGross, 10) + " |\n")
	}
	sb.WriteString("\nGross is `periods × per period`, so every line can be ")
	sb.WriteString("re-derived from the two facts beside it. `TierBreakdown` ")
	sb.WriteString("splits a line's withholding by bracket.\n")
	return sb.String()
}
