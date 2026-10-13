// Package cashflow derives a DIRECT-METHOD statement of cash flows from a
// double-entry book: how cash moved over one window, split into operating,
// investing and financing activity, with an explicit refusal where the split
// is not determinate.
//
// It is the third primary financial statement. [p/statements] derives the
// other two from a chart at an instant, and [p/periods] derives one window's
// movement; all three of those packages carry a note saying they do not do
// this one, and all three say the INDIRECT method needs a cash-vs-accrual
// classification [journal.Posting] does not carry. That is true. The direct
// method needs something different and smaller: a declaration of which chart
// codes hold cash. A declaration is something a caller can supply, which is
// what makes this package possible without changing what a posting is.
//
// # The sign convention, and why cash must be an asset
//
// A debit to a cash account is an INFLOW and a credit is an OUTFLOW. That
// follows from cash being debit-normal, so [Policy] requires every declared
// cash code to be a [journal.Asset] and refuses anything else
// ([ErrCashAccountNotAsset]). Declaring a credit-normal account as cash would
// invert every figure in the report and nothing downstream could tell. The
// cost of the rule is real and is stated rather than hidden: a bank overdraft
// carried as a liability cannot be declared as cash, and a caller holding one
// must carry it as a contra-asset or leave it out.
//
// # Attribution is per ENTRY, never per leg
//
// This is the package's central correctness decision, and the natural design
// is wrong in a way that produces numbers which balance. Take one ordinary
// part-paid purchase:
//
//	debit  Inventory          100
//	credit Cash                60
//	credit AccountsPayable     40
//
// Classifying each non-cash leg and attributing its own amount reports 100 of
// inventory-related outflow against the 60 of cash that actually moved. It
// invents a cash flow of 40 that did not happen, and the statement still adds
// up. So the unit of attribution is the entry:
//
//   - An entry with NO cash legs is skipped. It is accrual-only and moved no
//     cash. This is the direct method's whole point.
//   - An entry whose net cash movement is ZERO is named in [Report.NetZero]
//     and not classified. A transfer between two declared cash accounts is the
//     common case; there is nothing to attribute, so determinacy is not
//     demanded of it.
//   - Otherwise the entry's net cash movement is computed from its CASH legs
//     alone — so the figure is what actually moved — and that whole figure is
//     attributed to one category.
//
// # The determinacy rule, stated as a refusal
//
// An entry touching cash is determinate iff it has at least one non-cash leg
// and all of its non-cash legs classify to the SAME category, in which case
// the entry's whole net cash delta goes there. Otherwise the entry is named in
// [Report.Unresolved] with the reason, and its cash delta is carried in
// [Report.Unattributed].
//
// The "at least one" clause is not pedantry. An entry with nonzero net cash
// and no non-cash leg at all cannot come out of a balanced book, and it gets
// its own [ReasonUnbalanced] rather than being reported as a conflict with
// nothing to conflict — see that constant.
//
// Under that rule the purchase above is determinate when Inventory and
// AccountsPayable both classify operating: 60 of operating outflow, which is
// right. An entry that settles a loan and buys equipment at once — one leg
// financing, one investing — is NOT determinate, and no apportionment is
// invented for it. Splitting it proportionally would be a guess wearing a
// number's clothes.
//
// # Why classification is per CODE and not per journal.Kind
//
// A mapping from [journal.Kind] to a category would need no caller
// declaration at all, and it is the first design anyone reaches for. It is
// wrong on the most common accounts in any book: receivables and inventory are
// assets whose movement is OPERATING, not investing, and a kind-based mapping
// puts the entire working-capital cycle in the wrong section. So there is no
// kind-based default and no default bucket of any sort. A non-cash account
// with no declared category makes its entry unresolved
// ([ReasonUndeclared]) — silence is not assent.
//
// # What this package does not do
//
//   - **It never writes, and never sees a Book.** [Derive] returns figures;
//     the caller owns persistence and idempotence.
//   - **It cannot verify the policy.** Which codes hold cash and what each
//     other code's movement means are caller declarations. A chart that
//     declares a receivable as cash produces a plausible, wrong statement.
//     The declaration is the trust boundary.
//   - **It cannot verify the opening balance.** A window-filtered entry slice
//     carries period movement, not a cumulative position, so [Report.Opening]
//     is echoed back exactly as supplied and [Report.Closing] is only as good
//     as it. This is [p/periods]' limitation inherited, not a new one.
//   - **No reversal handling.** A reversing entry that touches cash moved
//     cash, and is classified like any other entry. That differs from
//     [p/periods], where an unresolved reversal is a census item, and the
//     difference is deliberate: a cash-flow statement reports movement, and a
//     reversal's movement is movement.
//   - **No paging and no merge.** [MaxEntries] is the hard bound. Merging
//     reports across pages would make the unresolved set an artifact of the
//     paging rather than of the data.
//   - **No audit.** Every figure is derived from what the caller supplied. A
//     chart from one book and entries from another produce a plausible report
//     and nothing here detects it.
//   - **Reconciling against [p/periods] proves nothing about the split.**
//     Comparing [Report.NetChange] with the cash accounts' movement in a
//     periods report is an arithmetic self-check that both packages added the
//     same columns the same way. A statement that files every flow under the
//     wrong category reconciles perfectly.
//
// [p/journal]: /p/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/journal
// [p/periods]: /p/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/periods
// [p/statements]: /p/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/statements
package cashflow

import (
	"errors"

	"gno.land/p/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/journal"
	"gno.land/p/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/periods"
)

// MaxAccounts bounds the chart [Derive] will accept. It is periods' bound,
// which is statements' bound, which is journal's own account cap — one
// number, declared once, so a chart that clears one of these packages clears
// all three.
const MaxAccounts = periods.MaxAccounts

// MaxEntries bounds the entry slice [Derive] will walk. It is periods' bound
// for the same reason: a caller feeding the same window to both packages must
// not have one of them refuse what the other accepted.
const MaxEntries = periods.MaxEntries

// NumCategories is how many categories a statement of cash flows has, and so
// the length [Report.Lines] always has. It is a constant of the standard, not
// a configuration.
const NumCategories = 3

var (
	// ErrInvalidWindow is a window failing [periods.Window.Valid].
	ErrInvalidWindow = errors.New("cashflow: invalid window")

	// ErrTooManyAccounts is a chart longer than [MaxAccounts].
	ErrTooManyAccounts = errors.New("cashflow: chart length exceeds MaxAccounts")

	// ErrChartNotSorted is a chart whose codes are not strictly ascending.
	// Membership here is a binary search, so the ordering is load-bearing
	// rather than cosmetic.
	ErrChartNotSorted = errors.New("cashflow: chart codes not strictly ascending")

	// ErrInvalidKind is a chart row whose Kind is outside journal's five.
	ErrInvalidKind = errors.New("cashflow: invalid account kind")

	// ErrTooManyEntries is an entry slice longer than [MaxEntries].
	ErrTooManyEntries = errors.New("cashflow: entry count exceeds MaxEntries")

	// ErrEntriesNotSorted is an entry slice not strictly ascending by ID.
	ErrEntriesNotSorted = errors.New("cashflow: entry IDs not strictly ascending")

	// ErrTooManyPostings is an entry with more than
	// [journal.MaxPostingsPerEntry] postings. journal cannot produce one, and
	// re-checking is what makes [MaxEntries]'s cost bound a proven ceiling
	// rather than a hope.
	ErrTooManyPostings = errors.New("cashflow: entry exceeds journal.MaxPostingsPerEntry")

	// ErrInvalidPosting is an in-window posting with an invalid Side or a
	// non-positive Amount. journal carries direction in Side and amounts are
	// always positive, so a signed amount here is a posting from somewhere
	// else.
	ErrInvalidPosting = errors.New("cashflow: invalid posting")

	// ErrUnknownAccount is an in-window posting naming a code absent from the
	// chart. It is scoped to the window because no figure in the report
	// depends on an entry outside it.
	ErrUnknownAccount = errors.New("cashflow: posting names an account absent from the chart")

	// ErrNoCashAccounts is an empty [Policy.Cash]. A statement of cash flows
	// over a book with no declared cash is all zeroes and looks exactly like
	// a quiet period, so the empty declaration is refused rather than
	// reported.
	ErrNoCashAccounts = errors.New("cashflow: policy declares no cash accounts")

	// ErrCashNotSorted is a [Policy.Cash] not strictly ascending.
	ErrCashNotSorted = errors.New("cashflow: policy cash codes not strictly ascending")

	// ErrUnknownCashAccount is a declared cash code absent from the chart.
	ErrUnknownCashAccount = errors.New("cashflow: policy declares a cash account absent from the chart")

	// ErrCashAccountNotAsset is a declared cash code whose chart Kind is not
	// [journal.Asset]. See the package doc on the sign convention: this is
	// what keeps a debit to cash meaning an inflow.
	ErrCashAccountNotAsset = errors.New("cashflow: policy declares a non-asset account as cash")

	// ErrRulesNotSorted is a [Policy.Rules] not strictly ascending by Code.
	ErrRulesNotSorted = errors.New("cashflow: policy rule codes not strictly ascending")

	// ErrInvalidCategory is a category outside the declared three — in a
	// policy rule, or passed to [Report.Line].
	ErrInvalidCategory = errors.New("cashflow: unknown category")

	// ErrUnknownRuleAccount is a policy rule naming a code absent from the
	// chart.
	ErrUnknownRuleAccount = errors.New("cashflow: policy rule names an account absent from the chart")

	// ErrCashAccountClassified is a code declared both as cash and as a
	// classified account. The two roles are exclusive: a cash account is what
	// MOVES, and a classified account is what the movement is FOR. Accepting
	// both would make the same code answer two different questions in one
	// entry.
	ErrCashAccountClassified = errors.New("cashflow: code is declared as cash and also classified")

	// ErrOverflow is an int64 overflow in any accumulation, including the
	// entry-level cash total and the closing balance.
	ErrOverflow = errors.New("cashflow: int64 overflow")
)

// Category is which activity a cash flow belongs to. The zero value is
// deliberately invalid, so a forgotten field is an error rather than
// operating activity — which is the bucket a defaulting implementation would
// pick and the one that would hide the most.
//
// The constants carry a Category prefix for the same reason
// [statements.Section]'s do: a bare Operating would read as a field name.
type Category uint8

// The three activity categories of a statement of cash flows.
const (
	CategoryOperating Category = 1 // trading: the working-capital cycle
	CategoryInvesting Category = 2 // long-lived assets and investments
	CategoryFinancing Category = 3 // capital and borrowings
)

// Valid reports whether c is one of the three categories.
func (c Category) Valid() bool {
	return c >= CategoryOperating && c <= CategoryFinancing
}

// String returns the category's name, or "invalid" for the zero value and any
// unrecognised code.
func (c Category) String() string {
	switch c {
	case CategoryOperating:
		return "operating"
	case CategoryInvesting:
		return "investing"
	case CategoryFinancing:
		return "financing"
	}
	return "invalid"
}

// Reason is why [Derive] would not classify an entry. The zero value is
// deliberately invalid.
type Reason uint8

// The three reasons an entry is unresolved.
const (
	// ReasonConflict is an entry whose non-cash legs classify to more than
	// one category. [Unresolved.Categories] names them, and names at least
	// two.
	ReasonConflict Reason = 1

	// ReasonUndeclared is an entry with a non-cash leg whose account has no
	// policy rule. [Unresolved.Codes] names them. An undeclared account is
	// named rather than defaulted, because a default bucket turns a missing
	// declaration into a figure nobody questions.
	//
	// It takes precedence over [ReasonConflict] when an entry has both an
	// undeclared code and two declared categories, because the undeclared
	// code is the actionable half: declaring it may resolve the entry, and
	// reporting a conflict while concealing a missing declaration would send
	// the reader to re-examine a policy that is not yet complete.
	ReasonUndeclared Reason = 2

	// ReasonUnbalanced is an entry all of whose legs are declared cash
	// accounts and whose cash legs do not net to zero.
	//
	// [journal.Book] cannot produce one: a balanced entry whose every leg is
	// cash has equal debits and credits over cash and therefore nets to zero,
	// which makes it a [Report.NetZero] item instead. So this reason is
	// reachable only from a hand-built entry slice, the same class
	// [p/periods] documents for its own hand-built Report.
	//
	// It exists rather than being folded into [ReasonConflict] because a
	// conflict carrying an EMPTY [Unresolved.Categories] is indistinguishable
	// from a bug in this package, and a census item a reader cannot tell from
	// a defect is not a census item. Found by writing the test for the
	// conflict case, not by reading the code.
	ReasonUnbalanced Reason = 3
)

// Valid reports whether r is one of the three reasons.
func (r Reason) Valid() bool { return r >= ReasonConflict && r <= ReasonUnbalanced }

// String returns the reason's name, or "invalid".
func (r Reason) String() string {
	switch r {
	case ReasonConflict:
		return "conflict"
	case ReasonUndeclared:
		return "undeclared"
	case ReasonUnbalanced:
		return "unbalanced"
	}
	return "invalid"
}

// Classification is one account code's activity category, declared by the
// caller. See the package doc on why this is per code rather than per
// [journal.Kind].
type Classification struct {
	Code     string
	Category Category
}

// Policy is the caller's whole declaration: which chart codes hold cash, and
// what each other code's movement is for.
//
// Both slices must be strictly ascending by code, because membership is a
// binary search in [Derive]'s inner loop. The two sets must be disjoint
// ([ErrCashAccountClassified]). Neither is verified against anything but the
// chart — this package cannot know whether a code called "petty cash" holds
// cash, and says so in its doc rather than pretending the name is evidence.
type Policy struct {
	// Cash is the codes that hold cash, strictly ascending. Must be
	// non-empty, and every code must be a [journal.Asset] in the chart.
	Cash []string

	// Rules is the activity category for non-cash codes, strictly ascending
	// by Code. A code absent from here is NOT defaulted; an entry touching it
	// is unresolved with [ReasonUndeclared].
	Rules []Classification
}

// Line is one category's gross flows over the window.
//
// Inflows and Outflows are both non-negative AS PRODUCED BY [Derive], and
// gross rather than netted, because a category with 1,000 in and 1,000 out is
// not the same business as one with nothing happening and a net of zero is
// all a netted figure can say about either.
type Line struct {
	Category Category

	// Inflows is the gross cash received, non-negative.
	Inflows int64

	// Outflows is the gross cash paid, non-negative.
	Outflows int64

	// Entries is how many in-window entries were attributed here.
	Entries int
}

// Net returns Inflows minus Outflows.
//
// The subtraction is unchecked, and that is safe for any Line [Derive]
// produces: both columns are non-negative, so the difference is in range for
// every pair of int64 values they can hold. A hand-built Line with a negative
// column can wrap, and that is the only way it can.
//
// The wrapped value does not stay local, which is the part worth stating:
// [Report.Reconciles] sums Net() over the lines, and a wrapped Net() can make
// it agree over a report whose columns say something else entirely. So
// Reconciles refuses a negative column outright rather than summing it — see
// the guard there. Net() itself stays unchecked because it has no way to
// report a refusal and a Line is a figure, not a claim.
//
// This note previously compared the blast radius to
// [periods.Activity.Movement] and said that one was wider because a negative
// column there also inverts a sign convention. That comparative was wrong,
// and an audit of this package found it: both wrap a figure that then passes
// every downstream guard, and the real asymmetry is in where the wrapped
// value GOES, not in sign inversion. The note is kept, corrected, because the
// equivalent note in periods was also once wrong about its own blast radius
// and also had to be found by an audit — twice is a pattern, and the pattern
// is that a comparative claim about another package's hazard is the sentence
// nothing checks.
func (l Line) Net() int64 { return l.Inflows - l.Outflows }

// Unresolved is one in-window entry [Derive] would not classify. It is a
// census item, not an error: the entry's cash movement is real and is carried
// in [Report.Unattributed], so [Report.NetChange] and [Report.Closing] stay
// true even when the split is incomplete.
//
// Whether an entry here SHOULD have been classifiable is an accounting
// judgement made outside this package. What is reported is that this policy
// could not decide it, and exactly what was missing or in conflict.
type Unresolved struct {
	// EntryID is the entry's journal ID.
	EntryID uint64

	// Reason is why it could not be classified.
	Reason Reason

	// Net is the entry's net cash movement: positive for an inflow. Reported
	// so a reader can see the size of what is unattributed rather than only
	// that something is.
	Net int64

	// Categories is the conflicting set, ascending and of length at least
	// two, when Reason is [ReasonConflict]; empty otherwise. Freshly
	// allocated and never nil.
	//
	// Ascending rather than in posting order, so that two records of the same
	// conflict compare equal whichever leg was posted first.
	Categories []Category

	// Codes is the undeclared account codes, in posting order and
	// deduplicated, when Reason is [ReasonUndeclared]; empty otherwise.
	// Freshly allocated and never nil.
	//
	// Posting order rather than ascending, because these are a worklist for
	// whoever extends the policy and the order a reader meets them in the
	// entry is the more useful one. The two slices differ on this
	// deliberately: a conflict set is compared, a code list is worked
	// through.
	Codes []string
}

// Report is one window's statement of cash flows. Every slice is freshly
// allocated by [Derive] on every call and is never nil, so the caller owns it
// and an empty result is an empty slice rather than a nil to be distinguished
// from one.
//
// The invariant that makes the report readable when the split is incomplete:
//
//	sum(Lines[i].Net()) + Unattributed == NetChange
//	Opening + NetChange             == Closing
//
// Both hold on every Report [Derive] returns, including one with unresolved
// entries. [Report.Reconciles] asserts the first.
type Report struct {
	// Window is the window the figures are for, echoed back so a stored
	// report cannot be read without it.
	Window periods.Window

	// Lines is the three categories, ascending by Category, always present
	// and always of length [NumCategories] — a category with no activity is a
	// zero line, not an absent one, because a statement of cash flows with a
	// missing section is not a statement of cash flows. Use [Report.Line] to
	// reach one by category rather than indexing by arithmetic.
	Lines []Line

	// Opening is the caller-supplied opening cash position, echoed back
	// unchanged. This package cannot verify it; see the package doc. A
	// negative value is accepted — an overdrawn position is a real one — so
	// the sign is not constrained here.
	Opening int64

	// NetChange is the window's total net cash movement, attributed and
	// unattributed together. It is the book's figure, not the statement's, so
	// it is true even when the split is not complete.
	NetChange int64

	// Unattributed is the net cash movement of the entries in Unresolved.
	// Zero exactly when every entry that moved cash was classified.
	Unattributed int64

	// Closing is Opening plus NetChange.
	Closing int64

	// Entries is how many entries fell in the window, including the ones that
	// moved no cash. Zero is a legitimate report of a quiet period, not an
	// error.
	Entries int

	// CashEntries is how many in-window entries touched a declared cash
	// account at all, including the ones in NetZero and Unresolved.
	CashEntries int

	// NetZero is the IDs of in-window entries that touched cash but moved
	// none on net — a transfer between two declared cash accounts, possibly
	// alongside non-cash legs. Classification is deliberately not attempted:
	// there is nothing to attribute, so demanding determinacy of them would
	// manufacture unresolved entries out of non-events.
	NetZero []uint64

	// Unresolved is the entries whose category was not determinate.
	Unresolved []Unresolved
}

// Line returns the line for c. An invalid category is [ErrInvalidCategory];
// there is no default line.
//
// This is the accessor to use. [Report.Lines] is ordered by Category and a
// consumer could index it as Lines[c-1], but that arithmetic is a second copy
// of the ordering invariant and the kind of thing that survives a reordering
// silently.
func (r Report) Line(c Category) (Line, error) {
	if !c.Valid() {
		return Line{}, ErrInvalidCategory
	}
	for _, l := range r.Lines {
		if l.Category == c {
			return l, nil
		}
	}
	return Line{}, ErrInvalidCategory
}

// Complete reports whether every in-window entry that moved cash was
// attributed to a category.
//
// A complete report is not a correct one: completeness is a property of the
// POLICY's coverage, and a policy that classifies every account wrongly is
// complete. See the package doc.
func (r Report) Complete() bool { return len(r.Unresolved) == 0 }

// Reconciles reports whether the attributed lines plus the unattributed
// residual equal NetChange.
//
// It is offered as API rather than asserted internally because a Report can
// be built by hand, and a consumer that stores one should be able to check it
// on the way back out. On a Report from [Derive] it is always true.
//
// False means one of three things and does not distinguish them: the lines do
// not sum to NetChange, the sum overflows, or a line carries a negative
// column (which [Line.Net] would wrap). All three are "do not trust this
// report", which is the whole question a bool can answer.
func (r Report) Reconciles() bool {
	total := int64(0)
	for _, l := range r.Lines {
		// Before the sum, and the reason is that Net() cannot refuse. A
		// hand-built Line{Inflows: maxI64, Outflows: -1} nets to minI64 by
		// wrapping, and checkedAdd cannot see it: the wrap happened in the
		// subtraction, so what arrives here is an ordinary in-range negative
		// and every add is honest. Reconciles would then agree with a report
		// whose operating line advertises an inflow of maxI64 -- which is
		// worse than disagreeing, because Reconciles is the one check a
		// consumer storing a hand-built Report is told to trust.
		//
		// Derive never produces a negative column (both are accumulated from
		// zero through checkedAdd), so this costs a Derive-sourced report
		// nothing. p/periods guards the same shape at the same kind of
		// boundary, with an error rather than a bool because it has one to
		// return.
		if l.Inflows < 0 || l.Outflows < 0 {
			return false
		}
		n, ok := checkedAdd(total, l.Net())
		if !ok {
			return false
		}
		total = n
	}
	total, ok := checkedAdd(total, r.Unattributed)
	if !ok {
		return false
	}
	return total == r.NetChange
}

// Derive builds the statement for one window.
//
// Preconditions, all refused rather than assumed: w must be valid; chart must
// be strictly ascending by Code, no longer than [MaxAccounts], with every
// Kind one of journal's five; entries must be strictly ascending by ID and no
// longer than [MaxEntries], with at most [journal.MaxPostingsPerEntry]
// postings each; and p must satisfy the rules on [Policy].
//
// Entries outside w are skipped, not refused — a caller passing the whole
// book is the expected case — and their postings are therefore not
// content-checked, because no figure in the report depends on them.
// [ErrInvalidPosting] and [ErrUnknownAccount] are scoped to the window for
// that reason; the postings-per-entry cap is not, since it is what makes
// [MaxEntries]'s cost ceiling a bound rather than a hope.
func Derive(chart []journal.Account, entries []journal.Entry, w periods.Window, p Policy, opening int64) (Report, error) {
	if !w.Valid() {
		return Report{}, ErrInvalidWindow
	}
	if len(chart) > MaxAccounts {
		return Report{}, ErrTooManyAccounts
	}
	if len(entries) > MaxEntries {
		return Report{}, ErrTooManyEntries
	}
	for i, a := range chart {
		if !a.Kind.Valid() {
			return Report{}, ErrInvalidKind
		}
		if i > 0 && chart[i-1].Code >= a.Code {
			return Report{}, ErrChartNotSorted
		}
	}
	for i, e := range entries {
		if len(e.Postings) > journal.MaxPostingsPerEntry {
			return Report{}, ErrTooManyPostings
		}
		if i > 0 && entries[i-1].ID >= e.ID {
			return Report{}, ErrEntriesNotSorted
		}
	}
	if err := validatePolicy(chart, p); err != nil {
		return Report{}, err
	}

	rep := Report{
		Window:     w,
		Lines:      make([]Line, 0, NumCategories),
		Opening:    opening,
		NetZero:    make([]uint64, 0),
		Unresolved: make([]Unresolved, 0),
	}
	for c := CategoryOperating; c <= CategoryFinancing; c++ {
		rep.Lines = append(rep.Lines, Line{Category: c})
	}

	for _, e := range entries {
		if !w.Contains(e.At) {
			continue
		}
		rep.Entries++

		net := int64(0)
		cashLegs := 0
		cats := make([]Category, 0, NumCategories)
		codes := make([]string, 0)

		for _, pg := range e.Postings {
			if !pg.Side.Valid() || pg.Amount <= 0 {
				return Report{}, ErrInvalidPosting
			}
			if !inChart(chart, pg.Account) {
				return Report{}, ErrUnknownAccount
			}
			if isCash(p.Cash, pg.Account) {
				cashLegs++
				signed := pg.Amount
				if pg.Side == journal.Credit {
					signed = -pg.Amount
				}
				sum, ok := checkedAdd(net, signed)
				if !ok {
					return Report{}, ErrOverflow
				}
				net = sum
				continue
			}
			c, found := ruleFor(p.Rules, pg.Account)
			if !found {
				if !hasCode(codes, pg.Account) {
					codes = append(codes, pg.Account)
				}
				continue
			}
			if !hasCategory(cats, c) {
				cats = append(cats, c)
			}
		}

		if cashLegs == 0 {
			continue
		}
		rep.CashEntries++

		if net == 0 {
			rep.NetZero = append(rep.NetZero, e.ID)
			continue
		}

		total, ok := checkedAdd(rep.NetChange, net)
		if !ok {
			return Report{}, ErrOverflow
		}
		rep.NetChange = total

		if len(codes) > 0 || len(cats) != 1 {
			// The three cases are selected explicitly rather than by falling
			// through to a default, so that each Unresolved record carries the
			// set that explains it: Codes for a missing declaration,
			// Categories for a conflict, and NEITHER for an unbalanced
			// cash-only entry -- which is why that case has its own reason
			// rather than appearing as a conflict with an empty set.
			var reason Reason
			reported := make([]Category, 0, len(cats))
			reportedCodes := make([]string, 0, len(codes))
			switch {
			case len(codes) > 0:
				reason = ReasonUndeclared
				reportedCodes = append(reportedCodes, codes...)
			case len(cats) == 0:
				reason = ReasonUnbalanced
			default:
				reason = ReasonConflict
				reported = append(reported, sortedCategories(cats)...)
			}
			unattributed, ok := checkedAdd(rep.Unattributed, net)
			if !ok {
				return Report{}, ErrOverflow
			}
			rep.Unattributed = unattributed
			rep.Unresolved = append(rep.Unresolved, Unresolved{
				EntryID:    e.ID,
				Reason:     reason,
				Net:        net,
				Categories: reported,
				Codes:      reportedCodes,
			})
			continue
		}

		idx := int(cats[0]) - 1
		if net > 0 {
			in, ok := checkedAdd(rep.Lines[idx].Inflows, net)
			if !ok {
				return Report{}, ErrOverflow
			}
			rep.Lines[idx].Inflows = in
		} else {
			out, ok := checkedAdd(rep.Lines[idx].Outflows, -net)
			if !ok {
				return Report{}, ErrOverflow
			}
			rep.Lines[idx].Outflows = out
		}
		rep.Lines[idx].Entries++
	}

	closing, ok := checkedAdd(rep.Opening, rep.NetChange)
	if !ok {
		return Report{}, ErrOverflow
	}
	rep.Closing = closing

	return rep, nil
}

// validatePolicy checks p against the chart. Every failure is a distinct
// error, because each one has a distinct fix and "invalid policy" tells a
// caller nothing about which of six things to look at.
func validatePolicy(chart []journal.Account, p Policy) error {
	if len(p.Cash) == 0 {
		return ErrNoCashAccounts
	}
	if len(p.Cash) > MaxAccounts || len(p.Rules) > MaxAccounts {
		return ErrTooManyAccounts
	}
	for i, code := range p.Cash {
		if i > 0 && p.Cash[i-1] >= code {
			return ErrCashNotSorted
		}
		k, found := kindOf(chart, code)
		if !found {
			return ErrUnknownCashAccount
		}
		if k != journal.Asset {
			return ErrCashAccountNotAsset
		}
	}
	for i, r := range p.Rules {
		if i > 0 && p.Rules[i-1].Code >= r.Code {
			return ErrRulesNotSorted
		}
		if !r.Category.Valid() {
			return ErrInvalidCategory
		}
		if _, found := kindOf(chart, r.Code); !found {
			return ErrUnknownRuleAccount
		}
		if isCash(p.Cash, r.Code) {
			return ErrCashAccountClassified
		}
	}
	return nil
}

// kindOf returns the chart Kind for code. The chart is strictly ascending, so
// this is a binary search.
func kindOf(chart []journal.Account, code string) (journal.Kind, bool) {
	lo, hi := 0, len(chart)-1
	for lo <= hi {
		mid := lo + (hi-lo)/2
		switch {
		case chart[mid].Code == code:
			return chart[mid].Kind, true
		case chart[mid].Code < code:
			lo = mid + 1
		default:
			hi = mid - 1
		}
	}
	return 0, false
}

// inChart reports whether code is in the chart.
func inChart(chart []journal.Account, code string) bool {
	_, found := kindOf(chart, code)
	return found
}

// isCash reports whether code is a declared cash account. cash is strictly
// ascending, so this is a binary search.
func isCash(cash []string, code string) bool {
	lo, hi := 0, len(cash)-1
	for lo <= hi {
		mid := lo + (hi-lo)/2
		switch {
		case cash[mid] == code:
			return true
		case cash[mid] < code:
			lo = mid + 1
		default:
			hi = mid - 1
		}
	}
	return false
}

// ruleFor returns the declared category for code. rules is strictly ascending
// by Code, so this is a binary search.
func ruleFor(rules []Classification, code string) (Category, bool) {
	lo, hi := 0, len(rules)-1
	for lo <= hi {
		mid := lo + (hi-lo)/2
		switch {
		case rules[mid].Code == code:
			return rules[mid].Category, true
		case rules[mid].Code < code:
			lo = mid + 1
		default:
			hi = mid - 1
		}
	}
	return 0, false
}

// hasCategory reports whether c is already in cats. The slice is at most
// NumCategories long, so a linear scan is the whole cost.
func hasCategory(cats []Category, c Category) bool {
	for _, x := range cats {
		if x == c {
			return true
		}
	}
	return false
}

// hasCode reports whether code is already in codes. The slice is at most
// journal.MaxPostingsPerEntry long.
func hasCode(codes []string, code string) bool {
	for _, x := range codes {
		if x == code {
			return true
		}
	}
	return false
}

// sortedCategories returns cats in ascending order, freshly allocated. The
// input is at most NumCategories long, so this is a selection over three
// values and the ordering exists so a reader comparing two Unresolved records
// is comparing sets rather than posting orders.
func sortedCategories(cats []Category) []Category {
	out := make([]Category, 0, len(cats))
	for c := CategoryOperating; c <= CategoryFinancing; c++ {
		if hasCategory(cats, c) {
			out = append(out, c)
		}
	}
	return out
}

// checkedAdd returns a+b and whether it is representable. Both operands are
// int64 and the sign test is the standard one: an overflow is exactly the
// case where two same-signed operands produce a differently-signed sum.
func checkedAdd(a, b int64) (int64, bool) {
	s := a + b
	if (a > 0 && b > 0 && s < 0) || (a < 0 && b < 0 && s >= 0) {
		return 0, false
	}
	return s, true
}
