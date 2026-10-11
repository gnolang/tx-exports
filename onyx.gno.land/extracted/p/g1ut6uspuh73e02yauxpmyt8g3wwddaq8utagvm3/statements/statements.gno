// Package statements turns a chart of accounts into classified financial
// statements, where the section, the sign and every total are functions of
// each account's kind and none of them is supplied by the caller.
//
// A realm holds the chart — [p/journal] keeps one, and a realm wrapping it
// publishes one — and asks this package what the statements say. Nothing here
// reads the chain, holds state, or decides what an account is: it takes
// [journal.Account] rows and returns figures.
//
//	rows := []journal.Account{ /* ascending by Code */ }
//	st, err := Derive(rows)
//	// st.Assets, st.Claims, st.CumulativeNet, st.Abnormal
//
// # The three-bucket partition
//
// [journal] partitions the five kinds in two, by normal balance. A statement
// partitions them in three, by where the figure is presented:
//
//	SectionAssets      : {Asset}                 balance sheet, debit side
//	SectionClaims      : {Liability, Equity}     balance sheet, credit side
//	SectionPerformance : {Revenue, Expense}      income statement
//
// [SectionOf] is the whole mapping and it is fail-closed: a Kind outside 1..5
// is [ErrInvalidKind], never a bucket. The zero Kind matters here because
// [journal.Kind.IsDebitNormal] reports it as credit-normal, so a silent
// fallthrough would not drop the row — it would file it under claims and
// produce a statement that balances and is wrong.
//
// # There is no Balances method, and the reason is the product's own arithmetic
//
// Write A, L, Q, R and X for the natural-sign totals of the five kinds, each
// the sum of [journal.Account.Balance] over its kind, and NI = R - X. For any
// single account, Balance() is RawDelta() for a debit-normal kind and its
// negation otherwise, so
//
//	sum over every account of RawDelta  =  A - L - Q - R + X
//
// and in a balanced book that sum is totalDebits - totalCredits = 0. Hence
//
//	A = L + Q + NI
//
// which is the balance sheet identity. The consequence is uncomfortable and is
// stated here rather than discovered by a reader: **over a chart drawn from a
// [journal.Book] the identity is a constant true**, algebraically identical to
// `totalDebits == totalCredits`, which the Book enforces on every Post. It is
// true of a chart whose every account is classified backwards. A `Balances()`
// returning that comparison would be a check that cannot fail, which this
// project has shipped before and does not ship again — see DISCOVERY.md § 4.
//
// The identity is NOT vacuous over this package's own input domain, because
// rows may come from anywhere and a hand-built set need not sum to zero. That
// scope is the whole content of the claim, and dropping a scope is the
// documentation defect this project has recorded most often. So:
//
//   - [Statement.Assets] and [Statement.Claims] are both reported, as figures.
//   - Their equality is asserted in the tests, in both directions: held over a
//     Book-derived chart, and shown to survive a chart miscoded on purpose,
//     which is what makes it vacuous there rather than reassuring.
//   - Nothing in the API offers that comparison as a verdict.
//
// # What ships instead: the abnormality census
//
// [journal.Account.Balance] is natural-sign and journal's own doc says a
// negative result is "a real signal (a contra position)". What did not exist
// is the roll-up: finding an abnormal account meant already knowing to look at
// it. [Statement.Abnormal] lists every row whose balance runs against its
// kind, and [Statement.AbnormalIn] counts them per section. It survives a
// balanced book, which the identity does not.
//
// It is the only partial answer in this portfolio to journal's obligation 7 —
// "a Kind set wrongly at Open time is undetectable here and undetectable
// anywhere else in this package" — and it is sound but incomplete, with the
// incompleteness exactly characterisable:
//
//   - It CATCHES a misclassification that crosses the debit/credit-normal
//     boundary and whose account has a non-zero balance. A payables account
//     coded as an asset accumulates credits and reads negative.
//   - It CANNOT CATCH a misclassification that stays on the same side:
//     Liability <-> Equity <-> Revenue, or Asset <-> Expense. Both subtotals
//     move, no balance goes negative, and nothing anywhere detects it.
//     Obligation 7 is narrowed, not closed.
//   - It has a FALSE-POSITIVE MODE that is not a defect: a genuine contra
//     account — accumulated depreciation under assets, a sales return under
//     revenue — is legitimately abnormal-signed. The census is a finding to
//     read, never a verdict.
//
// # The income statement is cumulative and can be nothing else
//
// [journal.Book.Close] is a backdating seal: it refuses entries dated at or
// before a cutoff and does not sweep nominal accounts into equity. There is no
// retained-earnings account and no closing entry, so revenue and expense
// accumulate from the book's first posting forever. The field names carry the
// word — [Statement.CumulativeRevenue], [Statement.CumulativeExpenses],
// [Statement.CumulativeNet] — because a reader who takes them for a period
// figure misreads every statement this package produces.
//
// [Statement.Claims] therefore includes CumulativeNet as an explicit
// reconciling line. A reader who checks Liabilities + Equity against Assets
// and finds it short by exactly CumulativeNet is not looking at a bug. A
// period income statement needs entry-level data and is out of scope; so is a
// cash-flow statement, which needs a cash-vs-accrual classification
// [journal.Posting] does not carry.
//
// # What this package does not claim
//
//   - **Nothing about money.** A statement is a report about a book, and a book
//     is a set of claims by its owner with no custody behind it. This package
//     never sees a coin. A realm publishing its output must say so loudly: a
//     published statement adds apparent authority to a self-report, and that
//     is the one way this product can mislead someone.
//   - **No audit.** Every figure here is derived from rows the caller supplied.
//     Deriving them faithfully is the guarantee; that they describe anything
//     real is not.
//   - **Two statements and a census**, not a statement set. No statement of
//     changes in equity, no notes, no comparatives.
//
// [p/journal]: /p/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/journal
package statements

import (
	"errors"

	"gno.land/p/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/journal"
)

// MaxRows bounds the chart [Derive] will classify, and so bounds its only
// loop. It is journal's own account cap, because that is the largest chart
// this ecosystem's bookkeeping primitive can produce, and a row set larger
// than that did not come from a chart.
//
// What the bound costs, stated rather than waved at: Derive is one pass with
// a checked add and a comparison per row, so a chart at the limit is 10,000
// iterations in one call. A realm that classifies several charts in one
// transaction, or renders them, multiplies that. The realm wrapping this
// package will have a much smaller cap of its own — r/books allows 128 — and
// should: this bound is the ceiling a caller may ask for, not a size worth
// reaching.
const MaxRows = journal.MaxAccountsLimit

// Errors returned by this package.
var (
	// ErrInvalidKind is returned for a row whose Kind is outside journal's
	// five. It is fail-closed by choice: the alternative is a row filed
	// under claims by [journal.Kind.IsDebitNormal]'s treatment of the zero
	// value, which yields a statement that balances and misstates.
	ErrInvalidKind = errors.New("statements: unknown account kind")

	// ErrRowsNotOrdered is returned when rows are not in strictly ascending
	// Code order. The precondition does three jobs at once and that is why
	// it is a precondition rather than an internal sort: it rules out a
	// duplicate code silently double-counting a balance, it keeps
	// [Statement.Abnormal] in a deterministic order a Render can rely on,
	// and it costs one string comparison per row instead of an allocation
	// and a sort.
	//
	// A row with an empty Code fails this check, since no string sorts
	// before "". journal refuses an empty code at Open, so a Book-derived
	// chart cannot contain one.
	//
	// Every producer in this portfolio already satisfies it:
	// [journal.Book.IterateAccounts] walks an avl tree keyed by code, and
	// r/books' Codes pages that same order.
	ErrRowsNotOrdered = errors.New("statements: rows must be in strictly ascending code order")

	// ErrTooManyRows is returned when len(rows) exceeds MaxRows.
	ErrTooManyRows = errors.New("statements: row count exceeds MaxRows")

	// ErrNegativeTotals is returned for a row whose Debits or Credits column
	// is negative. Such a row cannot have come from a [journal.Book]:
	// postings carry positive amounts only and an account's two columns are
	// monotone non-decreasing.
	//
	// It is checked for a reason beyond tidiness, and the reason is what
	// makes this package's overflow story complete.
	// [journal.Account.Balance] subtracts one column from the other with no
	// check of its own, so a row carrying Debits near max and a NEGATIVE
	// Credits yields a WRAPPED balance before any arithmetic here runs — and
	// no amount of checked adding downstream can recover a figure that was
	// already wrong on arrival. With both columns non-negative that
	// subtraction lands in [-maxInt64, maxInt64] and cannot wrap, which is
	// the precondition the checked adds in [Derive] are sufficient under.
	ErrNegativeTotals = errors.New("statements: account column totals must not be negative")

	// ErrOverflow is returned when a section total, the cumulative net, or
	// the claims subtotal would wrap int64. Nothing is reported partially:
	// an overflowing statement is an error, not a wrapped number, because a
	// wrapped total is a figure a reader cannot tell from a real one.
	ErrOverflow = errors.New("statements: int64 overflow")

	// ErrInvalidSection is returned by [Statement.SectionTotal] for a
	// section outside the declared three.
	ErrInvalidSection = errors.New("statements: unknown section")
)

// Section is where an account's figure is presented. The zero value is
// deliberately invalid, so a forgotten field is an error rather than assets.
//
// The constants carry a Section prefix on purpose: [Statement] has fields
// named Assets and Claims, and bare constants of the same words would read as
// the same thing in two namespaces.
type Section uint8

// The three statement sections.
const (
	SectionAssets      Section = 1 // balance sheet, debit side
	SectionClaims      Section = 2 // balance sheet, credit side
	SectionPerformance Section = 3 // income statement
)

// Valid reports whether s is one of the three sections.
func (s Section) Valid() bool { return s >= SectionAssets && s <= SectionPerformance }

// String returns the section's name, or "invalid" for the zero value and any
// unrecognised code.
func (s Section) String() string {
	switch s {
	case SectionAssets:
		return "assets"
	case SectionClaims:
		return "claims"
	case SectionPerformance:
		return "performance"
	}
	return "invalid"
}

// SectionOf maps an account kind to the section it presents in. An invalid
// kind is [ErrInvalidKind]; there is no default bucket.
//
// This is the only place in the package that knows the partition, and it is
// exported so a consumer grouping rows for presentation uses the same mapping
// the totals were built from rather than a second copy of it.
func SectionOf(k journal.Kind) (Section, error) {
	switch k {
	case journal.Asset:
		return SectionAssets, nil
	case journal.Liability, journal.Equity:
		return SectionClaims, nil
	case journal.Revenue, journal.Expense:
		return SectionPerformance, nil
	}
	return 0, ErrInvalidKind
}

// Abnormal is one account whose balance runs against its kind's normal
// direction. Balance is in the account's normal direction and is therefore
// always negative here.
//
// [Derive] is its only producer in this package.
type Abnormal struct {
	Code    string
	Name    string
	Kind    journal.Kind
	Balance int64
}

// Statement is the classified figures for one chart at one instant.
//
// Every int64 field is a natural-sign total: a normal chart has them all
// non-negative. They are values, not pointers, so a holder cannot reach back
// into anything — except through Abnormal, which is a slice and is freshly
// allocated by [Derive] on every call, so the caller owns it.
//
// Assets and Claims are both reported and their equality is deliberately not
// offered as a method; see the package doc on why that comparison cannot fail
// over a Book-derived chart.
type Statement struct {
	// Rows is how many accounts were classified. Zero is a legitimate
	// statement of nothing, not an error.
	Rows int

	// Assets is the balance-sheet debit side.
	Assets int64

	// Liabilities and Equity are the two credit-side components, reported
	// separately because a reader needs them apart and Claims does not
	// recover them.
	Liabilities int64
	Equity      int64

	// CumulativeRevenue and CumulativeExpenses accumulate from the book's
	// first posting, not over a period. See the package doc.
	CumulativeRevenue  int64
	CumulativeExpenses int64

	// CumulativeNet is CumulativeRevenue - CumulativeExpenses. It appears on
	// the balance sheet as a reconciling line because journal closes no
	// nominal account into equity.
	CumulativeNet int64

	// Claims is Liabilities + Equity + CumulativeNet: the credit side of the
	// balance sheet as presented.
	Claims int64

	// Abnormal lists every row whose balance runs against its kind, in the
	// row order Derive received, which ErrRowsNotOrdered forces to be
	// ascending by code. It is never nil for a Statement from Derive.
	Abnormal []Abnormal
}

// AbnormalIn counts the abnormal rows presented in sec.
//
// It recomputes each row's section from its Kind through [SectionOf] rather
// than storing one, so there is one definition of the partition and no
// second field that could disagree with it. A Statement built by hand can
// hold a row with an invalid Kind, and such a row is counted in no section;
// Derive cannot produce one.
func (s Statement) AbnormalIn(sec Section) int {
	n := 0
	for _, a := range s.Abnormal {
		got, err := SectionOf(a.Kind)
		if err != nil {
			continue
		}
		if got == sec {
			n++
		}
	}
	return n
}

// SectionTotal returns the figure presented for sec: Assets, Claims, or
// CumulativeNet. A section outside the three is [ErrInvalidSection].
//
// Note what the performance total is: the income statement's bottom line, not
// the sum of its two components. Revenue and expenses are read from their own
// fields.
func (s Statement) SectionTotal(sec Section) (int64, error) {
	switch sec {
	case SectionAssets:
		return s.Assets, nil
	case SectionClaims:
		return s.Claims, nil
	case SectionPerformance:
		return s.CumulativeNet, nil
	}
	return 0, ErrInvalidSection
}

// Derive classifies rows and returns the statement figures.
//
// rows must be in strictly ascending Code order ([ErrRowsNotOrdered]) and no
// longer than [MaxRows]. Every Kind must be one of journal's five
// ([ErrInvalidKind]) and neither column may be negative
// ([ErrNegativeTotals], which is what makes the checked adds here
// sufficient). Every accumulation is checked ([ErrOverflow]).
//
// It is a pure function of rows: the same rows always give the same Statement,
// and nothing about the caller, the chain or the time enters it. On any error
// the returned Statement is the zero value, so a caller that ignores the error
// reads zeros rather than a half-summed chart.
func Derive(rows []journal.Account) (Statement, error) {
	if len(rows) > MaxRows {
		return Statement{}, ErrTooManyRows
	}

	st := Statement{Abnormal: []Abnormal{}}
	prev := ""
	for _, a := range rows {
		if a.Code <= prev {
			return Statement{}, ErrRowsNotOrdered
		}
		prev = a.Code

		if !a.Kind.Valid() {
			return Statement{}, ErrInvalidKind
		}
		if a.Debits < 0 || a.Credits < 0 {
			return Statement{}, ErrNegativeTotals
		}

		bal := a.Balance()
		ok := true
		switch a.Kind {
		case journal.Asset:
			st.Assets, ok = checkedAdd(st.Assets, bal)
		case journal.Liability:
			st.Liabilities, ok = checkedAdd(st.Liabilities, bal)
		case journal.Equity:
			st.Equity, ok = checkedAdd(st.Equity, bal)
		case journal.Revenue:
			st.CumulativeRevenue, ok = checkedAdd(st.CumulativeRevenue, bal)
		case journal.Expense:
			st.CumulativeExpenses, ok = checkedAdd(st.CumulativeExpenses, bal)
		}
		if !ok {
			return Statement{}, ErrOverflow
		}

		if bal < 0 {
			st.Abnormal = append(st.Abnormal, Abnormal{
				Code:    a.Code,
				Name:    a.Name,
				Kind:    a.Kind,
				Balance: bal,
			})
		}
		st.Rows++
	}

	net, ok := checkedSub(st.CumulativeRevenue, st.CumulativeExpenses)
	if !ok {
		return Statement{}, ErrOverflow
	}
	st.CumulativeNet = net

	claims, ok := checkedAdd(st.Liabilities, st.Equity)
	if !ok {
		return Statement{}, ErrOverflow
	}
	claims, ok = checkedAdd(claims, net)
	if !ok {
		return Statement{}, ErrOverflow
	}
	st.Claims = claims

	return st, nil
}

// MustDerive is [Derive] and panics instead of returning an error. It is for
// a realm's mutating path, where an error return does not revert the
// transaction and only a panic does.
func MustDerive(rows []journal.Account) Statement {
	st, err := Derive(rows)
	if err != nil {
		panic(err)
	}
	return st
}

// checkedAdd returns a+b and reports whether the addition did not overflow
// int64. journal's copy is unexported, so this is a deliberate three-line
// duplicate of a trivial helper — a different thing from the second Kind enum
// DISCOVERY.md § 3 refused, which would have duplicated a domain decision.
func checkedAdd(a, b int64) (int64, bool) {
	sum := a + b
	if (b > 0 && sum < a) || (b < 0 && sum > a) {
		return 0, false
	}
	return sum, true
}

// checkedSub returns a-b and reports whether the subtraction did not overflow
// int64. It is not checkedAdd(a, -b): negating math.MinInt64 overflows on its
// own, so that form would wrap before the check ran.
func checkedSub(a, b int64) (int64, bool) {
	diff := a - b
	if (b < 0 && diff < a) || (b > 0 && diff > a) {
		return 0, false
	}
	return diff, true
}
