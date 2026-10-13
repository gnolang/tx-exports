// Package periods turns a cumulative double-entry book into a period report:
// per-account movement over a date window, the period income statement, and
// the closing entry that sweeps nominal accounts into equity.
//
// [p/journal] is cumulative by construction and says so. Its Close is a
// backdating seal — it refuses entries dated at or before a cutoff and does
// not sweep anything — so revenue and expense accumulate from the book's first
// posting forever, and [p/statements] names its three figures
// CumulativeRevenue, CumulativeExpenses and CumulativeNet for that reason. Its
// package doc states the gap in one sentence: "A period income statement needs
// entry-level data and is out of scope." This package is that entry-level
// consumer. It reads no chain, holds no state, and writes nothing.
//
//	w := Window{From: q1Start, Until: q2Start}
//	rep, err := Derive(chart, entries, w)
//	// rep.Activity, rep.PeriodNet, rep.CrossWindowReversals
//	post, err := rep.ClosingEntry("3100")   // a PROPOSAL, not a write
//
// # Why the chart is a parameter
//
// [journal.Posting] is {Account string, Side, Amount int64}: it carries the
// account's CODE and never its Kind. So revenue cannot be told from expense
// from postings alone, and no income statement is derivable without the chart.
// That single fact fixes this package's signature. Only Code, Name and Kind
// are read; Debits and Credits are the book's CUMULATIVE columns and are
// deliberately neither read nor validated here, because period movement comes
// from the entries.
//
// # The window is closed-open
//
// [Window] is [From, Until): From is included, Until is not. Consecutive
// periods therefore TILE — [Window.Tiles] is the predicate — with no overlap
// and no gap, which is what makes a sequence of period reports add up to the
// cumulative figures. A closed-closed window double-counts exactly one
// timestamp per boundary, and that error is invisible in any single report.
//
// # Two inputs, two ordering decisions, opposite answers
//
// This package imposes an ordering precondition on one input and refuses one
// on the other, and the rule separating them is what journal GUARANTEES:
//
//   - chart must be strictly ascending by Code ([ErrChartNotOrdered]).
//     [journal.Book.IterateAccounts] is "ascending code order", so every
//     producer meets it. It buys duplicate-code detection, chart-order output
//     with no sort, and a binary-search code lookup instead of a map.
//   - entries must be strictly ascending by ID ([ErrEntriesNotOrdered]).
//     [journal.Book.IterateEntries] and [journal.Book.Entries] both guarantee
//     it. It buys duplicate-ID detection, the binary search that resolves
//     ReversalOf, and ID >= 1 for free, 0 being ReversalOf's sentinel.
//   - entries must NOT be required in ascending At order, and this package
//     must never require it. At is caller-supplied and backdating is legal
//     until Close seals it, so journal guarantees nothing about it. Such a
//     precondition would be one no producer in this portfolio can meet — a
//     gate that can never pass, in an API signature rather than in a checker.
//
// # The reversal census has three buckets, and the third is the point
//
// A reversal dated inside the window whose original is dated outside it
// changes what the period means: the window carries a correction to activity
// it never contained. The census reports three things and never two:
//
//   - [Report.Reversals] — in-window reversal, original also in-window:
//     ordinary, classified.
//   - [Report.CrossWindowReversals] — in-window reversal, original dated
//     outside: classified, and material.
//   - [Report.UnresolvedReversals] — in-window reversal whose original is
//     ABSENT from the entries slice, so the classification COULD NOT BE MADE.
//
// Collapsing the third into either of the first two would read "could not
// evaluate" as assent. It is a census, not a verdict — the same posture as
// [statements.Statement.Abnormal] — and it is a function of what the caller
// passed, not of the book: pass a window-filtered slice and every reversal
// reaching back before it is unresolved by construction.
//
// # What this package does not do
//
//   - **It never writes.** [Report.ClosingEntry] returns postings for the
//     caller to Post. It sweeps PERIOD MOVEMENT, not cumulative balance, so
//     running it twice over one window and posting both results
//     double-sweeps — and this package never sees the Book, so it cannot
//     detect that. The caller owns idempotence.
//   - **No paging, no Merge.** [MaxEntries] is the hard bound. Merging reports
//     across pages would make UnresolvedReversals an artifact of the paging
//     rather than of the data; fixing that needs a two-pass design over the
//     whole entry set and is a different package.
//   - **No cash-flow statement.** The indirect method needs a
//     cash-vs-accrual classification [journal.Posting] does not carry.
//     [Report.Activity] is the balance-sheet delta half it would need.
//   - **No audit.** Every figure is derived from what the caller supplied. A
//     chart from one book and entries from another produce a plausible report
//     and nothing here detects it.
//
// [p/journal]: /p/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/journal
// [p/statements]: /p/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/statements
package periods

import (
	"errors"

	"gno.land/p/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/journal"
	"gno.land/p/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/statements"
)

// MaxAccounts bounds the chart [Derive] will accept. It is
// [statements.MaxRows] — journal's own account cap, reached through the
// package that already made this decision rather than restated — because a
// row set larger than the largest chart this ecosystem's bookkeeping
// primitive can hold did not come from a chart.
const MaxAccounts = statements.MaxRows

// MaxEntries bounds the entry slice [Derive] will walk, and it is set far
// below [journal.MaxEntriesLimit] on purpose: the journal holds a million
// entries and a million-entry loop is not a transaction.
//
// What the bound costs, stated rather than waved at. Derive makes one pass
// over the entries and, per entry, one pass over its postings, each posting
// costing a binary search over the chart. [journal.MaxPostingsPerEntry] is 64
// and is re-checked here ([ErrTooManyPostings]) so the product is a PROVEN
// ceiling and not an assumed one:
//
//	4096 entries x 64 postings = 262 144 posting visits, each a
//	log2(10 000) ~ 14-step search
//
// which is the same order as the 10 000-row walk [statements.Derive]
// documents. A realm wanting period reports caps its own journal at or below
// this; r/books allows 128 accounts and should be read the same way — this is
// the ceiling a caller may ask for, not a size worth reaching.
const MaxEntries = 4096

// Errors returned by this package.
var (
	// ErrInvalidWindow is a window failing [Window.Valid]: From negative, or
	// Until not strictly after From. An empty window is refused rather than
	// reported as a period with no activity, because the two are different
	// claims and only one of them is a report.
	ErrInvalidWindow = errors.New("periods: window must satisfy 0 <= From < Until")

	// ErrTooManyAccounts is a chart longer than [MaxAccounts].
	ErrTooManyAccounts = errors.New("periods: chart length exceeds MaxAccounts")

	// ErrTooManyEntries is an entry slice longer than [MaxEntries].
	ErrTooManyEntries = errors.New("periods: entry count exceeds MaxEntries")

	// ErrChartNotOrdered is a chart not in strictly ascending Code order.
	// journal's own enumerator is, so this also catches a duplicated code.
	ErrChartNotOrdered = errors.New("periods: chart must be in strictly ascending code order")

	// ErrEntriesNotOrdered is an entry slice not in strictly ascending ID
	// order, which includes an ID of zero. Both of journal's producers are
	// ordered; see the package doc on why At carries no such requirement.
	ErrEntriesNotOrdered = errors.New("periods: entries must be in strictly ascending ID order")

	// ErrInvalidKind is an account whose Kind is outside journal's five. The
	// zero Kind is the case that matters: journal reports it as
	// credit-normal, so a silent fallthrough would file it rather than refuse
	// it.
	//
	// The two producers are not symmetrical, and saying so is the point.
	// [Derive] raises it from the CHART PRE-PASS, which proves every Kind
	// [journal.Kind.Valid] before anything is summed; its later
	// [statements.SectionOf] branch is therefore UNREACHABLE, because
	// SectionOf's switch covers exactly the five kinds Valid admits. That
	// branch ships anyway, as fail-closed defence against the two definitions
	// drifting apart in a later version of either package — but it is not a
	// path this package can reach today and must not be cited as one.
	// [Report.ClosingEntry] is the reachable SectionOf case: it is handed a
	// Report rather than a chart, runs no pre-pass, and so a hand-built row
	// with an invalid Kind reaches SectionOf directly.
	ErrInvalidKind = errors.New("periods: unknown account kind")

	// ErrInvalidPosting is a posting with an invalid Side or a non-positive
	// Amount. journal cannot produce one; a hand-built entry can.
	ErrInvalidPosting = errors.New("periods: posting needs a valid side and a positive amount")

	// ErrTooManyPostings is an entry with more than
	// [journal.MaxPostingsPerEntry] postings. journal cannot produce one, and
	// re-checking is what makes [MaxEntries]'s cost bound a proven ceiling.
	ErrTooManyPostings = errors.New("periods: entry exceeds journal.MaxPostingsPerEntry")

	// ErrUnknownAccount is a posting naming a code absent from the chart.
	// Dropping it silently would UNDERSTATE the period, which is worse than
	// refusing to report it.
	ErrUnknownAccount = errors.New("periods: posting names a code absent from the chart")

	// ErrNegativeColumns is an [Activity] row whose Debits or Credits is
	// negative. [Derive] cannot produce one — it accumulates positive posting
	// amounts from zero — so this is only reachable through a hand-built
	// Report, and it is checked for the reason [statements.ErrNegativeTotals]
	// is checked over the identical hazard on the identical type.
	//
	// [Activity.Movement] delegates to [journal.Account.Balance], which
	// subtracts one column from the other with no check of its own. A row
	// carrying Credits near max and a NEGATIVE Debits therefore yields a
	// WRAPPED movement before any arithmetic here runs, and the wrap survives
	// every downstream guard: it is nonzero, so the m == 0 skip does not
	// fire, and it is not minInt64, so magnitude reports success. The result
	// was a closing posting with an INVERTED SIGN, balanced, both sides
	// present, within the posting cap, and acceptable to [journal.Book.Post]
	// — a wrong figure with no error anywhere, which is strictly worse than
	// [ErrOverflow] because nothing downstream can tell it from a real one.
	// With both columns non-negative the subtraction lands in
	// [-maxInt64, maxInt64] and cannot wrap, which is the precondition the
	// checked arithmetic in [Report.ClosingEntry] is sufficient under.
	ErrNegativeColumns = errors.New("periods: activity column totals must not be negative")

	// ErrInvalidEquityCode is an empty equity code, or one longer than
	// [journal.MaxCodeLen].
	ErrInvalidEquityCode = errors.New("periods: equity code must be non-empty and within journal.MaxCodeLen")

	// ErrEquityCodeIsNominal is an equity code naming one of the nominal
	// accounts being swept. The resulting entry would balance and mean
	// nothing. See [Report.ClosingEntry] on what this check cannot cover.
	ErrEquityCodeIsNominal = errors.New("periods: equity code names a nominal account being closed")

	// ErrNothingToClose is a window with no nominal movement at all. The
	// alternative is returning an empty posting slice that journal would
	// refuse with ErrTooFewPostings, which moves the failure one call later
	// where it is harder to read.
	ErrNothingToClose = errors.New("periods: no nominal movement in the window")

	// ErrTooManyNominalAccounts is a sweep that would exceed
	// [journal.MaxPostingsPerEntry]: at most 63 nominal accounts plus the
	// equity posting.
	ErrTooManyNominalAccounts = errors.New("periods: closing entry exceeds journal.MaxPostingsPerEntry")

	// ErrOverflow is an int64 overflow in any accumulation.
	ErrOverflow = errors.New("periods: int64 overflow")
)

// Window is a half-open date range [From, Until): From is included, Until is
// not. The unit is whatever the book's At values are — journal treats At as an
// opaque non-negative int64, so a caller holding seconds passes seconds and a
// caller holding block heights passes heights. This package imposes no
// calendar, which is why it needs none.
type Window struct {
	From  int64
	Until int64
}

// Valid reports whether w is a usable window: From non-negative and Until
// strictly after it. An empty or inverted window is not a period.
func (w Window) Valid() bool { return w.From >= 0 && w.From < w.Until }

// Contains reports whether at falls in w. Half-open: From is in, Until is out.
func (w Window) Contains(at int64) bool { return at >= w.From && at < w.Until }

// Tiles reports whether next begins exactly where w ends, so that the two
// cover [w.From, next.Until) with no overlap and no gap.
//
// It exists as API rather than as a comment because the tiling property is
// what makes a sequence of period reports sum to the cumulative figures, and a
// caller generating a sequence should be able to assert it.
func (w Window) Tiles(next Window) bool {
	return w.Valid() && next.Valid() && w.Until == next.From
}

// Activity is one account's movement WITHIN the window. Debits and Credits are
// period sums, not the book's cumulative columns, and both are non-negative AS
// PRODUCED BY [Derive] — postings carry positive amounts and Derive refuses
// anything else.
//
// A Report assembled by hand is under no such constraint, so
// [Report.ClosingEntry] checks it: a negative column there is
// [ErrNegativeColumns]. The check is not tidiness. [Movement] delegates to
// [journal.Account.Balance], an unchecked subtraction, so a negative column
// wraps the movement BEFORE any guard here runs and the wrap passes all of
// them — the earlier version of this comment claimed a hand-built Report's
// only consequence was [ErrOverflow], and an audit disproved it by producing a
// sign-inverted closing entry that [journal.Book.Post] accepts with no error
// at all. See [ErrNegativeColumns] for the mechanism.
//
// [Derive] emits a row only for a code the window actually touched: an account
// with no movement is ABSENT, not a zero row. Over a chart of 10 000 with
// three active accounts that is three rows, and the alternative is paying
// statements' full MaxRows cost to report nothing.
type Activity struct {
	Code    string
	Name    string
	Kind    journal.Kind
	Debits  int64
	Credits int64
}

// Movement returns the period movement in the account's NORMAL direction, so
// a revenue account that earned reads positive and a contra movement reads
// negative.
//
// It is journal's own definition, reached by handing journal the two columns
// rather than re-deriving the normal-balance rule here. One definition of
// which kinds are debit-normal, in the package that owns it.
//
// Inheriting that definition means inheriting its arithmetic: Balance
// subtracts without a check, so on a row with a NEGATIVE column — which only a
// hand-built Report can hold — this wraps and returns a plausible wrong
// number. It is left unchecked rather than given an error return, because a
// two-value Movement would have to be handled at four call sites to defend one
// input class that [Report.ClosingEntry] refuses outright. The guard is at the
// boundary; see [ErrNegativeColumns].
func (a Activity) Movement() int64 {
	return journal.Account{Kind: a.Kind, Debits: a.Debits, Credits: a.Credits}.Balance()
}

// RawDelta returns Debits-Credits regardless of kind. Summed over every row of
// a report derived from balanced entries it is exactly zero, which is what
// makes it useful for a consistency check and wrong for a report.
func (a Activity) RawDelta() int64 { return a.Debits - a.Credits }

// CrossReversal is an in-window reversal whose original entry is dated outside
// the window: the period carries a correction to activity it never contained.
//
// Total is the reversal's debit total ([journal.Entry.Total]), which is its
// magnitude on both sides because journal only accepts balanced entries.
type CrossReversal struct {
	ID         uint64
	ReversalOf uint64
	Total      int64
}

// Report is one window's activity. Every slice is freshly allocated by
// [Derive] on every call and is never nil, so the caller owns it and an empty
// result is an empty slice rather than a nil to be distinguished from one.
type Report struct {
	// Window is the window the figures are for, echoed back so a stored
	// report cannot be read without it.
	Window Window

	// Activity is per-account period movement, in CHART order — which the
	// chart precondition makes ascending by Code — for codes the window
	// touched.
	Activity []Activity

	// Entries is how many entries fell in the window. Zero is a legitimate
	// report of a quiet period, not an error.
	Entries int

	// FirstID and LastID are the lowest and highest IDs IN THE WINDOW, or
	// both zero when Entries is zero. They are min and max over the
	// in-window SUBSET and not the ends of the supplied slice: over entries
	// 1, 2, 3 with only 2 in the window, both read 2.
	FirstID uint64
	LastID  uint64

	// PeriodRevenue and PeriodExpenses are the natural-sign period totals of
	// the two nominal kinds. The names carry the word PERIOD for the same
	// reason statements' carry CUMULATIVE: a reader who takes one for the
	// other misreads every figure.
	PeriodRevenue  int64
	PeriodExpenses int64

	// PeriodNet is PeriodRevenue - PeriodExpenses: the period income
	// statement's bottom line, which no cumulative report can produce.
	PeriodNet int64

	// Reversals counts in-window reversals whose original is also in-window.
	Reversals int

	// CrossWindowReversals lists in-window reversals whose original is dated
	// outside the window, in the order the entries were walked.
	CrossWindowReversals []CrossReversal

	// UnresolvedReversals lists the IDs of in-window reversals whose original
	// is absent from the supplied entries, so they could be classified
	// neither way. See the package doc: this is the bucket that must not be
	// collapsed.
	UnresolvedReversals []uint64
}

// ActivityIn counts the rows presented in sec.
//
// The section is recomputed from each row's Kind through
// [statements.SectionOf] rather than stored, so there is one definition of the
// three-bucket partition and no second field that could disagree with it. A
// Report built by hand can hold a row with an invalid Kind; such a row is
// counted in no section, and [Derive] cannot produce one.
//
// It deliberately does NOT check [ErrNegativeColumns], unlike
// [Report.ClosingEntry], and has no error return to do it with. The reason is
// that it reads no column: the count depends on Kind alone, so a negative
// column cannot make this answer wrong. A guard added here for symmetry would
// be a check that can never change an outcome — the vacuous-true shape this
// portfolio refuses elsewhere — and the honest version is this sentence.
func (r Report) ActivityIn(sec statements.Section) int {
	n := 0
	for _, a := range r.Activity {
		got, err := statements.SectionOf(a.Kind)
		if err != nil {
			continue
		}
		if got == sec {
			n++
		}
	}
	return n
}

// Derive computes the period report.
//
// It is a pure function of its three arguments: the same inputs always give
// the same Report, and nothing about the caller, the chain or the time enters
// it. On any error the returned Report is the zero value, so a caller that
// ignores the error reads zeros rather than a half-summed period.
//
// Preconditions, each for a reason given in the package doc: w must be valid;
// chart must be strictly ascending by Code and no longer than [MaxAccounts],
// with every Kind one of journal's five; entries must be strictly ascending by
// ID and no longer than [MaxEntries], with at most
// [journal.MaxPostingsPerEntry] postings each.
//
// Entries outside w are skipped, not refused — a caller passing the whole book
// is the expected case — and their postings are therefore NOT content-checked,
// because no figure in the report depends on them. [ErrInvalidPosting] and
// [ErrUnknownAccount] are scoped to the window for that reason; the
// postings-per-entry cap is not, since it is what makes [MaxEntries]' cost
// ceiling a bound rather than a hope.
func Derive(chart []journal.Account, entries []journal.Entry, w Window) (Report, error) {
	if !w.Valid() {
		return Report{}, ErrInvalidWindow
	}
	if len(chart) > MaxAccounts {
		return Report{}, ErrTooManyAccounts
	}
	if len(entries) > MaxEntries {
		return Report{}, ErrTooManyEntries
	}

	// Both preconditions are established in full BEFORE any figure is
	// computed, because the lookups below are binary searches and a search
	// over a half-validated slice is only sound by argument. An empty first
	// code fails the ascending test on its own, prev starting at "".
	prevCode := ""
	for _, a := range chart {
		if a.Code <= prevCode {
			return Report{}, ErrChartNotOrdered
		}
		prevCode = a.Code
		if !a.Kind.Valid() {
			return Report{}, ErrInvalidKind
		}
	}

	var prevID uint64
	for _, e := range entries {
		if e.ID <= prevID {
			return Report{}, ErrEntriesNotOrdered
		}
		prevID = e.ID
		// Checked for every entry, in or out of window, because this is the
		// bound MaxEntries' cost ceiling is stated against. The posting
		// CONTENT checks below are scoped to the window instead, since they
		// are about the figures rather than about the cost.
		if len(e.Postings) > journal.MaxPostingsPerEntry {
			return Report{}, ErrTooManyPostings
		}
	}

	// Period columns, parallel to chart by index. A map would be the obvious
	// structure and no /p/ in this portfolio uses one; the chart precondition
	// makes a binary search enough.
	debits := make([]int64, len(chart))
	credits := make([]int64, len(chart))

	rep := Report{
		Window:               w,
		Activity:             []Activity{},
		CrossWindowReversals: []CrossReversal{},
		UnresolvedReversals:  []uint64{},
	}

	for _, e := range entries {
		if !w.Contains(e.At) {
			continue
		}

		for _, p := range e.Postings {
			if !p.Side.Valid() || p.Amount <= 0 {
				return Report{}, ErrInvalidPosting
			}
			at := indexOfCode(chart, p.Account)
			if at < 0 {
				return Report{}, ErrUnknownAccount
			}
			var ok bool
			if p.Side == journal.Debit {
				debits[at], ok = checkedAdd(debits[at], p.Amount)
			} else {
				credits[at], ok = checkedAdd(credits[at], p.Amount)
			}
			if !ok {
				return Report{}, ErrOverflow
			}
		}

		if rep.Entries == 0 || e.ID < rep.FirstID {
			rep.FirstID = e.ID
		}
		if e.ID > rep.LastID {
			rep.LastID = e.ID
		}
		rep.Entries++

		if !e.IsReversal() {
			continue
		}
		orig := indexOfID(entries, e.ReversalOf)
		switch {
		case orig < 0:
			rep.UnresolvedReversals = append(rep.UnresolvedReversals, e.ID)
		case w.Contains(entries[orig].At):
			rep.Reversals++
		default:
			rep.CrossWindowReversals = append(rep.CrossWindowReversals, CrossReversal{
				ID:         e.ID,
				ReversalOf: e.ReversalOf,
				Total:      e.Total(),
			})
		}
	}

	for i, a := range chart {
		if debits[i] == 0 && credits[i] == 0 {
			continue
		}
		row := Activity{
			Code:    a.Code,
			Name:    a.Name,
			Kind:    a.Kind,
			Debits:  debits[i],
			Credits: credits[i],
		}
		rep.Activity = append(rep.Activity, row)

		sec, err := statements.SectionOf(a.Kind)
		if err != nil {
			return Report{}, ErrInvalidKind
		}
		if sec != statements.SectionPerformance {
			continue
		}
		var ok bool
		if a.Kind == journal.Revenue {
			rep.PeriodRevenue, ok = checkedAdd(rep.PeriodRevenue, row.Movement())
		} else {
			rep.PeriodExpenses, ok = checkedAdd(rep.PeriodExpenses, row.Movement())
		}
		if !ok {
			return Report{}, ErrOverflow
		}
	}

	net, ok := checkedSub(rep.PeriodRevenue, rep.PeriodExpenses)
	if !ok {
		return Report{}, ErrOverflow
	}
	rep.PeriodNet = net

	return rep, nil
}

// MustDerive is [Derive] and panics instead of returning an error. It is for a
// realm's mutating path, where an error return does not revert the transaction
// and only a panic does.
func MustDerive(chart []journal.Account, entries []journal.Entry, w Window) Report {
	rep, err := Derive(chart, entries, w)
	if err != nil {
		panic(err)
	}
	return rep
}

// ClosingEntry returns the postings that zero every nominal account's PERIOD
// MOVEMENT and carry the net to equityCode — the entry [journal.Book.Close]
// deliberately does not make, Close being a backdating seal and nothing else.
//
// Nominal means [statements.SectionPerformance]: the partition is read through
// [statements.SectionOf] rather than restated as a second list of kinds.
//
// The result is a PROPOSAL. This package holds no Book and posts nothing, and
// three consequences follow that a caller must own:
//
//   - It sweeps period movement, not cumulative balance. Posting it twice for
//     one window double-sweeps the period, and nothing here can detect that.
//   - A window the book has already sealed is still reportable — Close refuses
//     writes, not reads — so these postings may come back
//     [journal.ErrPeriodClosed]. That is journal's call; this package cannot
//     see the seal and does not pre-empt it.
//   - equityCode is checked for being empty, over-long, or one of the nominal
//     codes being swept ([ErrEquityCodeIsNominal]). It CANNOT be checked for
//     naming an Equity-kind account, because Report does not retain the chart:
//     a code naming a known liability yields an entry journal will accept and
//     that files net income in the wrong place. journal rejects an unknown
//     code on its own; the wrong-kind case is the caller's.
//
// The postings always balance and always carry both a debit and a credit when
// there are any at all, which is why a non-error return is always postable on
// those grounds. Net income is credited to equity and a net loss is debited,
// equity being credit-normal. A window with no nominal movement is
// [ErrNothingToClose] rather than an empty slice.
//
// That postability claim rests on a precondition [Derive] supplies for free
// and a hand-built Report does not, so this function establishes it itself:
// every row's columns must be non-negative, or [ErrNegativeColumns]. Without
// the check the claim is false in the worst available way — not an error, but
// a balanced, postable, SIGN-INVERTED entry. See [ErrNegativeColumns].
func (r Report) ClosingEntry(equityCode string) ([]journal.Posting, error) {
	if equityCode == "" || len(equityCode) > journal.MaxCodeLen {
		return nil, ErrInvalidEquityCode
	}

	out := []journal.Posting{}
	var net int64
	for _, a := range r.Activity {
		// Before the partition, not after it. A negative column on a
		// non-nominal row cannot affect this result, so checking only the
		// nominal rows would be sufficient for the arithmetic and useless as a
		// claim: the guarantee worth having is "ClosingEntry refuses any
		// Report carrying a negative column", which a reader can state and a
		// test can prove, rather than "refuses one in the rows it happened to
		// reach".
		if a.Debits < 0 || a.Credits < 0 {
			return nil, ErrNegativeColumns
		}

		sec, err := statements.SectionOf(a.Kind)
		if err != nil {
			return nil, ErrInvalidKind
		}
		if sec != statements.SectionPerformance {
			continue
		}
		if a.Code == equityCode {
			return nil, ErrEquityCodeIsNominal
		}

		m := a.Movement()
		if m == 0 {
			continue
		}
		// This branch is UNREACHABLE as the function now stands, and shipping
		// it is deliberate rather than an oversight. magnitude only refuses
		// minInt64, and with both columns proven non-negative above no single
		// row can produce it: Credits-Debits = minInt64 would need a Debits of
		// 2^63, which no int64 holds. It was reachable before
		// ErrNegativeColumns existed. It stays because it is the fail-closed
		// backstop if that guard is ever weakened, and because deleting it
		// would make this the only magnitude call site without one. The
		// REACHABLE overflow is the net accumulator below, which can reach
		// minInt64 by accumulation; the test names which door it uses.
		amt, ok := magnitude(m)
		if !ok {
			return nil, ErrOverflow
		}

		// Close the account by posting against its movement: the opposite of
		// its normal side when it moved normally, its normal side when it
		// moved contra.
		side := journal.Debit
		if a.Kind.IsDebitNormal() == (m > 0) {
			side = journal.Credit
		}
		out = append(out, journal.Posting{Account: a.Code, Side: side, Amount: amt})

		if a.Kind == journal.Revenue {
			net, ok = checkedAdd(net, m)
		} else {
			net, ok = checkedSub(net, m)
		}
		if !ok {
			return nil, ErrOverflow
		}
	}

	if net != 0 {
		amt, ok := magnitude(net)
		if !ok {
			return nil, ErrOverflow
		}
		side := journal.Credit
		if net < 0 {
			side = journal.Debit
		}
		out = append(out, journal.Posting{Account: equityCode, Side: side, Amount: amt})
	}

	if len(out) == 0 {
		return nil, ErrNothingToClose
	}
	if len(out) > journal.MaxPostingsPerEntry {
		return nil, ErrTooManyNominalAccounts
	}
	return out, nil
}

// indexOfCode returns the index of code in chart, or -1. chart is strictly
// ascending by Code, which Derive has already established, so this is a binary
// search.
func indexOfCode(chart []journal.Account, code string) int {
	lo, hi := 0, len(chart)-1
	for lo <= hi {
		mid := lo + (hi-lo)/2
		switch {
		case chart[mid].Code == code:
			return mid
		case chart[mid].Code < code:
			lo = mid + 1
		default:
			hi = mid - 1
		}
	}
	return -1
}

// indexOfID returns the index of the entry with the given ID, or -1. entries
// is strictly ascending by ID, which Derive establishes over the WHOLE slice
// before computing anything, so the search is sound by precondition rather
// than by an argument about which IDs a reversal can name.
func indexOfID(entries []journal.Entry, id uint64) int {
	lo, hi := 0, len(entries)-1
	for lo <= hi {
		mid := lo + (hi-lo)/2
		switch {
		case entries[mid].ID == id:
			return mid
		case entries[mid].ID < id:
			lo = mid + 1
		default:
			hi = mid - 1
		}
	}
	return -1
}

// minInt64 is the one int64 whose negation is not an int64.
const minInt64 int64 = -1 << 63

// magnitude returns the absolute value of v and reports whether it fit. It is
// not -v: negating [minInt64] overflows on its own, so the check has to come
// first.
func magnitude(v int64) (int64, bool) {
	if v >= 0 {
		return v, true
	}
	if v == minInt64 {
		return 0, false
	}
	return -v, true
}

// checkedAdd returns a+b and reports whether the addition did not overflow
// int64. journal's and statements' copies are both unexported, so this is a
// deliberate three-line duplicate of a trivial helper — a different thing from
// a second copy of the nominal-account partition, which is why
// [statements.SectionOf] is imported instead of restated.
func checkedAdd(a, b int64) (int64, bool) {
	sum := a + b
	if (b > 0 && sum < a) || (b < 0 && sum > a) {
		return 0, false
	}
	return sum, true
}

// checkedSub returns a-b and reports whether the subtraction did not overflow
// int64. It is not checkedAdd(a, -b), for magnitude's reason.
func checkedSub(a, b int64) (int64, bool) {
	diff := a - b
	if (b < 0 && diff < a) || (b > 0 && diff > a) {
		return 0, false
	}
	return diff, true
}
