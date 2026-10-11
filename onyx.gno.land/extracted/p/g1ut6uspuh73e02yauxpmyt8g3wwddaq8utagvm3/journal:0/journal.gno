// Package journal is a pure double-entry accounting primitive for realms
// that need books which provably balance. It is to *bookkeeping* what
// feeledger is to *money* and duebook is to *time*: it holds no coins,
// performs no effects, imports no chain APIs, and owns no package-level
// state. The importing realm owns a *Book, supplies the clock, and performs
// its own effects.
//
// # The one idea
//
// Every financial primitive in the searched Gno ecosystem is ONE-SIDED. A
// treasury records what moved. A pull-payment ledger records who is owed
// what. A GRC20 ledger records who holds what. Each stores a balance and
// mutates it.
//
// This package stores no balance. It stores ENTRIES, and derives balances
// from them:
//
//	book.MustOpen("1000", "Cash", Asset)
//	book.MustOpen("4000", "Revenue", Revenue)
//	book.MustPost(now, "invoice 17 paid", []Posting{
//		{Account: "1000", Side: Debit, Amount: 5000},
//		{Account: "4000", Side: Credit, Amount: 5000},
//	})
//
// An entry that does not balance is refused, and the refusal says which side
// is short. So `sum(debits) == sum(credits)` is not a property the consumer
// must remember to maintain — it is the precondition for the state changing
// at all. A Book cannot be put into an unbalanced state by any sequence of
// calls to this package.
//
// # No amend, no void
//
// Post is the only way in, and there is no Edit and no Delete. A mistake is
// corrected the way real books correct one: with a REVERSING ENTRY that
// mirrors every posting of the original, leaving both visible.
//
//	book.MustReverse(entryID, now, "wrong account")
//
// This is why history is trustworthy here and would not be if entries were
// mutable. An auditor reading the journal sees the error AND the correction,
// which is the entire point of keeping a journal rather than a balance.
// Reverse refuses a second reversal of the same entry, so a correction
// cannot be looped.
//
// # Periods
//
// Close(through) seals everything dated at or before `through`. It only ever
// moves forward, and after it Post refuses any entry dated into the sealed
// range — the backdating that makes a closed period meaningless. Reverse is
// refused there too: correcting a sealed period means opening a new entry in
// the current one, which is the consumer's call to make explicitly.
//
// # What "balanced" is actually worth
//
// Read this before quoting IsBalanced as a guarantee.
//
// IsBalanced compares TWO INDEPENDENTLY MAINTAINED ACCUMULATORS: the
// per-account debit/credit totals, summed across the chart, against the
// Book's own running totals. They are written by different code paths, so
// a drift between them is a real defect and IsBalanced finds it. What it
// does NOT do is re-read the journal, so a defect that corrupted both
// accumulators identically would survive it.
//
// RederiveFromJournal is the strong check: it replays every posting of every
// entry and compares the result against both accumulators. It costs O(all
// postings ever) and exists to be run deliberately, not on every read.
//
// AccountingEquation is WEAKER THAN IT LOOKS and is documented as such
// rather than left for a reader to assume otherwise: under this package's
// sign conventions it is implied by IsBalanced, and its boolean proves
// EXACTLY ONE of IsBalanced's three conjuncts. It is NOT an independent
// accounting fact. Three checks that are really two, presented as three,
// would be the defect this package exists to avoid.
//
// This doc said "it is a cross-check of this package's own normal-balance
// handling" until 2026-10-07, and that sentence was FALSE — the one place
// the careful disclaimer around it still overclaimed. The boolean is the
// sum of every account's RawDelta, bucketed by Kind and then added back
// together, so the bucketing cannot change it: offsets is INVARIANT under
// every possible Kind misclassification, which is the one thing
// "normal-balance handling" means. See obligation 7 below, and
// AccountingEquation's own doc for what it does prove.
//
// And the ceiling on all three: a Book can be internally perfect and
// describe nothing. See obligation 1 below.
//
// # State growth
//
// Entries are never removed, because an append-only journal whose entries
// could vanish is not a journal. Storage therefore grows with every Post and
// is bounded only by maxEntries, set at construction. A Book that reaches
// that cap refuses further entries rather than silently dropping history —
// a long-lived consumer must plan for this, and the plan is a new Book with
// opening balances carried forward, not a pruned one.
//
// # Consumer contract (the parts the package cannot enforce)
//
//  1. THE BOOKS ARE CLAIMS BY WHOEVER POSTED THEM. This package proves
//     arithmetic, never truth. With no custody there is no solvency
//     invariant tying "Cash 5000" to 5000 real ugnot anywhere. A realm that
//     presents a journal balance as a holding is asserting something this
//     package did not check. This is the single most important obligation
//     and the one most commonly got wrong.
//  2. SUPPLY A REAL CLOCK. journal cannot verify that `at` came from
//     runtime.ChainHeight() or time.Now().Unix(). A realm that lets a caller
//     choose `at` has no period discipline at all: the caller dates entries
//     wherever they are convenient. Pass the chain's clock, never a
//     transaction parameter.
//  3. USE ONE CLOCK CONSISTENTLY. Heights and seconds must not be mixed
//     within a Book; `at` and `through` are both in the caller's unit.
//  4. DO NOT EXPORT THE BOOK. A *Book is a mutable handle. Returning one
//     across a realm boundary hands out the right to open accounts, post and
//     reverse. Expose your own crossing functions instead; this package
//     returns Account and Entry VALUES, never pointers into its state.
//  5. AUTHORIZE THE POSTER. journal authenticates nobody. Who may open an
//     account, who may post, and who may close a period are the realm's
//     policy — derive the caller from cur.Previous().Address(), not from an
//     argument.
//  6. CHOOSE THE UNIT ONCE. Amounts are int64 in whatever minor unit the
//     consumer picks. journal does not know about denominations and will
//     happily balance an entry that mixes two of them.
//  7. GET THE KIND RIGHT AT OPEN TIME. NO CHECK IN THIS PACKAGE VALIDATES
//     AN ACCOUNT'S KIND. A Kind is accepted if it is one of the five and is
//     never revisited, so an account opened Asset that should have been
//     Liability reports a sign-flipped Balance() forever — and IsBalanced,
//     RederiveFromJournal and AccountingEquation all three stay healthy,
//     because every one of them is built on Debits and Credits, which the
//     Kind does not touch. This is the invariant tiers' blind spot, it is
//     structural rather than an omission to be fixed later, and a realm
//     that lets a caller choose the Kind has delegated a decision no
//     later check can audit.
//
// All failures are returned as errors and leave the Book COMPLETELY
// UNCHANGED. Must* wrappers are the only functions here that panic.
//
// The Book is address-agnostic: account codes are non-empty strings. Realms
// normally use a chart-of-accounts code, not an address.
package journal

import (
	"errors"
	"strconv"

	"gno.land/p/nt/avl/v0"
)

// MaxAccountsLimit is the largest maxAccounts a Book may be constructed
// with. It bounds the cost of IsBalanced and AccountingEquation, which scan
// the chart of accounts.
const MaxAccountsLimit = 10000

// MaxEntriesLimit is the largest maxEntries a Book may be constructed with.
const MaxEntriesLimit = 1000000

// MaxPostingsPerEntry bounds a single entry's posting count. Two is the
// minimum a balanced entry can have; the ceiling keeps one Post bounded.
const MaxPostingsPerEntry = 64

// MaxCodeLen bounds an account code.
const MaxCodeLen = 64

// MaxNameLen bounds an account's human-readable name.
const MaxNameLen = 256

// MaxMemoLen bounds an entry memo. The memo is opaque to journal — it exists
// so a realm can record why an entry was made without keeping a parallel
// table.
const MaxMemoLen = 1024

// Errors returned by Book operations.
var (
	ErrEmptyCode        = errors.New("journal: empty account code")
	ErrCodeTooLong      = errors.New("journal: account code exceeds MaxCodeLen")
	ErrNameTooLong      = errors.New("journal: account name exceeds MaxNameLen")
	ErrMemoTooLong      = errors.New("journal: memo exceeds MaxMemoLen")
	ErrInvalidKind      = errors.New("journal: unknown account kind")
	ErrInvalidSide      = errors.New("journal: posting side must be Debit or Credit")
	ErrInvalidAmount    = errors.New("journal: posting amount must be positive")
	ErrInvalidAt        = errors.New("journal: at must be non-negative")
	ErrInvalidConfig    = errors.New("journal: invalid book configuration")
	ErrAccountExists    = errors.New("journal: account code already open")
	ErrUnknownAccount   = errors.New("journal: no such account")
	ErrChartFull        = errors.New("journal: account cap reached")
	ErrBookFull         = errors.New("journal: entry cap reached")
	ErrTooFewPostings   = errors.New("journal: an entry needs at least two postings")
	ErrTooManyPostings  = errors.New("journal: entry exceeds MaxPostingsPerEntry")
	ErrNoDebit          = errors.New("journal: entry has no debit posting")
	ErrNoCredit         = errors.New("journal: entry has no credit posting")
	ErrDebitShort       = errors.New("journal: entry does not balance, debits are short")
	ErrCreditShort      = errors.New("journal: entry does not balance, credits are short")
	ErrEntryNotFound    = errors.New("journal: no such entry")
	ErrAlreadyReversed  = errors.New("journal: entry has already been reversed")
	ErrPeriodClosed     = errors.New("journal: at falls in a closed period")
	ErrCloseNotForward  = errors.New("journal: close must move forward")
	ErrOverflow         = errors.New("journal: int64 overflow")
	ErrIDExhausted      = errors.New("journal: identifier space exhausted")
)

// Kind is an account's classification, which fixes its normal balance.
// The zero value is deliberately invalid so a forgotten field is an error
// rather than an Asset.
type Kind uint8

// The five account kinds. Asset and Expense are debit-normal; Liability,
// Equity and Revenue are credit-normal.
const (
	Asset     Kind = 1
	Liability Kind = 2
	Equity    Kind = 3
	Revenue   Kind = 4
	Expense   Kind = 5
)

// Valid reports whether k is one of the five kinds.
func (k Kind) Valid() bool { return k >= Asset && k <= Expense }

// IsDebitNormal reports whether an increase in k is recorded as a debit.
// Asset and Expense are debit-normal; the other three are credit-normal.
// An invalid Kind reports false, which is why callers validate first.
func (k Kind) IsDebitNormal() bool { return k == Asset || k == Expense }

// String returns the kind's name, or "invalid" for the zero value and any
// unrecognised code.
func (k Kind) String() string {
	switch k {
	case Asset:
		return "asset"
	case Liability:
		return "liability"
	case Equity:
		return "equity"
	case Revenue:
		return "revenue"
	case Expense:
		return "expense"
	}
	return "invalid"
}

// Side is which column a posting lands in. The zero value is deliberately
// invalid: a posting with a forgotten Side must be refused, not silently
// treated as a debit.
type Side uint8

// The two posting sides.
const (
	Debit  Side = 1
	Credit Side = 2
)

// Valid reports whether s is Debit or Credit.
func (s Side) Valid() bool { return s == Debit || s == Credit }

// String returns "debit", "credit", or "invalid".
func (s Side) String() string {
	switch s {
	case Debit:
		return "debit"
	case Credit:
		return "credit"
	}
	return "invalid"
}

// Opposite returns the other side. An invalid Side returns itself, so a
// caller that skipped validation gets an invalid posting rather than a
// plausible one.
func (s Side) Opposite() Side {
	switch s {
	case Debit:
		return Credit
	case Credit:
		return Debit
	}
	return s
}

// Posting is one leg of an entry: an amount in one column of one account.
// Amount is always POSITIVE — direction is carried by Side, not by a sign.
//
// That is a deliberate choice over signed amounts. With a sign, "which side
// is short" is unanswerable without knowing each account's normal balance,
// so an unbalanced entry can only be reported as a number that does not add
// up. With an explicit Side the refusal names the short column, which is
// what a bookkeeper needs in order to fix it.
type Posting struct {
	Account string
	Side    Side
	Amount  int64
}

// Account is one line of the chart of accounts, carrying its cumulative
// debit and credit totals. It is returned BY VALUE: holders cannot reach
// into a Book through it.
type Account struct {
	Code    string
	Name    string
	Kind    Kind
	Debits  int64
	Credits int64
}

// Balance returns the account's balance in its NORMAL direction: for a
// debit-normal account Debits-Credits, for a credit-normal account
// Credits-Debits. A normal account therefore has a non-negative balance,
// and a negative result is a real signal (a contra position) rather than a
// sign convention.
func (a Account) Balance() int64 {
	if a.Kind.IsDebitNormal() {
		return a.Debits - a.Credits
	}
	return a.Credits - a.Debits
}

// RawDelta returns Debits-Credits regardless of kind. Summed over every
// account in a balanced book it is exactly zero, which is what makes it the
// useful quantity for a consistency check and the wrong one for a report.
func (a Account) RawDelta() int64 { return a.Debits - a.Credits }

// Entry is one journal entry: a dated, memo'd, balanced set of postings.
// It is returned BY VALUE, and its Postings slice is a DEFENSIVE COPY — a
// holder can mutate the returned slice without touching the Book. Entry is
// the one type here that contains a slice, so it is the one type where
// returning the stored value directly would have handed out a writable
// window into Book state.
//
// ReversalOf is 0 unless this entry was produced by Reverse, in which case
// it is the ID of the entry it mirrors.
type Entry struct {
	ID         uint64
	At         int64
	Memo       string
	Postings   []Posting
	ReversalOf uint64
}

// IsReversal reports whether this entry was produced by Reverse.
func (e Entry) IsReversal() bool { return e.ReversalOf != 0 }

// Total returns the entry's debit total, which for any entry a Book accepted
// equals its credit total.
func (e Entry) Total() int64 {
	var t int64
	for _, p := range e.Postings {
		if p.Side == Debit {
			t += p.Amount
		}
	}
	return t
}

// Book is the chart of accounts and the journal of one consuming realm. The
// zero value is not usable; construct with New.
type Book struct {
	maxAccounts int
	maxEntries  int

	accounts *avl.Tree // code -> Account
	entries  *avl.Tree // padded id -> Entry
	// reversed stores `true`, not a struct{} sentinel, and deliberately:
	// avl.Tree.Get cannot tell a nil-valued key from an absent one, so a
	// nil sentinel invites a future reader to switch from Has to Get and
	// get a silently wrong answer. Membership is the whole value here —
	// both readers use Has and the stored value is never read.
	reversed *avl.Tree // padded id -> true, for entries already reversed

	nextID        uint64 // never decreases; entry IDs are never reused
	closedThrough int64  // entries dated at or before this are refused
	hasClosed     bool   // distinguishes "closed through 0" from "never closed"

	totalDebits  int64 // running total, maintained independently of accounts
	totalCredits int64
}

// New returns an empty Book.
//
// maxAccounts caps the chart and must be in [1, MaxAccountsLimit].
// maxEntries caps the journal and must be in [1, MaxEntriesLimit]; because
// entries are never removed, it is a lifetime cap rather than a concurrent
// one, and a Book that reaches it is finished.
func New(maxAccounts, maxEntries int) (*Book, error) {
	if maxAccounts < 1 || maxAccounts > MaxAccountsLimit {
		return nil, ErrInvalidConfig
	}
	if maxEntries < 1 || maxEntries > MaxEntriesLimit {
		return nil, ErrInvalidConfig
	}
	return &Book{
		maxAccounts: maxAccounts,
		maxEntries:  maxEntries,
		accounts:    avl.NewTree(),
		entries:     avl.NewTree(),
		reversed:    avl.NewTree(),
		nextID:      1,
	}, nil
}

// MustNew is New but panics on error.
func MustNew(maxAccounts, maxEntries int) *Book {
	b, err := New(maxAccounts, maxEntries)
	if err != nil {
		panic(err)
	}
	return b
}

// MaxAccounts returns the Book's cap on chart size.
func (b *Book) MaxAccounts() int { return b.maxAccounts }

// MaxEntries returns the Book's lifetime cap on entries.
func (b *Book) MaxEntries() int { return b.maxEntries }

// AccountCount returns how many accounts are open.
func (b *Book) AccountCount() int { return b.accounts.Size() }

// EntryCount returns how many entries the journal holds. It never decreases.
func (b *Book) EntryCount() int { return b.entries.Size() }

// NextID returns the identifier the next entry will take. It only ever
// increases, so an entry ID identifies one entry for the life of the Book.
func (b *Book) NextID() uint64 { return b.nextID }

// TotalDebits returns the Book's running debit total across every entry.
func (b *Book) TotalDebits() int64 { return b.totalDebits }

// TotalCredits returns the Book's running credit total across every entry.
func (b *Book) TotalCredits() int64 { return b.totalCredits }

// ClosedThrough returns the period seal: entries dated at or before it are
// refused. The second result is false if the Book has never been closed, in
// which case the first is meaningless — a Book closed through 0 and a Book
// never closed differ, and collapsing them would silently reject entries
// dated at 0.
func (b *Book) ClosedThrough() (int64, bool) { return b.closedThrough, b.hasClosed }

// Open adds an account to the chart. Codes are unique and immutable: there
// is no Rename and no Close, because an account's cumulative totals are part
// of the derivation of every balance that cites it, and removing one would
// make the journal unreplayable.
//
// Fails with ErrEmptyCode, ErrCodeTooLong, ErrNameTooLong, ErrInvalidKind,
// ErrAccountExists, or ErrChartFull. On error nothing is modified.
func (b *Book) Open(code, name string, kind Kind) error {
	if code == "" {
		return ErrEmptyCode
	}
	if len(code) > MaxCodeLen {
		return ErrCodeTooLong
	}
	if len(name) > MaxNameLen {
		return ErrNameTooLong
	}
	if !kind.Valid() {
		return ErrInvalidKind
	}
	if b.accounts.Has(code) {
		return ErrAccountExists
	}
	if b.accounts.Size() >= b.maxAccounts {
		return ErrChartFull
	}
	b.accounts.Set(code, Account{Code: code, Name: name, Kind: kind})
	return nil
}

// MustOpen is Open but panics on error.
func (b *Book) MustOpen(code, name string, kind Kind) {
	if err := b.Open(code, name, kind); err != nil {
		panic(err)
	}
}

// Account returns an account by code. The second result is false if no such
// account is open.
func (b *Book) Account(code string) (Account, bool) { return b.account(code) }

// Balance returns an account's balance in its normal direction, and whether
// the account exists. A missing account returns (0, false) rather than a
// zero balance, because "no such account" and "balance zero" are different
// answers and a consumer branching on the number alone would conflate them.
func (b *Book) Balance(code string) (int64, bool) {
	a, ok := b.account(code)
	if !ok {
		return 0, false
	}
	return a.Balance(), true
}

// Post appends a balanced entry and returns its ID.
//
// The postings must number at least two and at most MaxPostingsPerEntry,
// each naming an open account, a valid Side, and a positive Amount. The
// entry must contain at least one debit and at least one credit, and the two
// column totals must be equal — an inequality is reported as ErrDebitShort
// or ErrCreditShort, naming the column that needs more.
//
// Fails with ErrInvalidAt, ErrMemoTooLong, ErrPeriodClosed, ErrBookFull,
// ErrIDExhausted, ErrTooFewPostings, ErrTooManyPostings, ErrInvalidSide,
// ErrInvalidAmount, ErrUnknownAccount, ErrNoDebit, ErrNoCredit,
// ErrDebitShort, ErrCreditShort, or ErrOverflow. On error nothing is
// modified — every posting is validated and every total computed before the
// first write.
func (b *Book) Post(at int64, memo string, postings []Posting) (uint64, error) {
	if at < 0 {
		return 0, ErrInvalidAt
	}
	if len(memo) > MaxMemoLen {
		return 0, ErrMemoTooLong
	}
	if b.hasClosed && at <= b.closedThrough {
		return 0, ErrPeriodClosed
	}
	return b.post(at, memo, 0, postings)
}

// MustPost is Post but panics on error.
func (b *Book) MustPost(at int64, memo string, postings []Posting) uint64 {
	id, err := b.Post(at, memo, postings)
	if err != nil {
		panic(err)
	}
	return id
}

// Reverse appends the mirror of an existing entry — every posting repeated
// on the opposite side, for the same amount — and returns the new entry's
// ID. The original is left exactly as it was.
//
// An entry may be reversed at most once. Reversing a reversal IS permitted
// (it re-applies the original's effect) and is itself subject to the same
// once-only rule, so a correction cannot be looped.
//
// `at` dates the correction and must be in the open period: a sealed period
// cannot be corrected in place, by construction. Correcting one means
// posting into the current period, which is the consumer's decision to make
// explicitly rather than this package's to make silently.
//
// Fails with ErrInvalidAt, ErrMemoTooLong, ErrPeriodClosed,
// ErrEntryNotFound, ErrAlreadyReversed, ErrBookFull, ErrIDExhausted, or
// ErrOverflow. On error nothing is modified.
func (b *Book) Reverse(id uint64, at int64, memo string) (uint64, error) {
	if at < 0 {
		return 0, ErrInvalidAt
	}
	if len(memo) > MaxMemoLen {
		return 0, ErrMemoTooLong
	}
	if b.hasClosed && at <= b.closedThrough {
		return 0, ErrPeriodClosed
	}
	orig, ok := b.entry(id)
	if !ok {
		return 0, ErrEntryNotFound
	}
	if b.reversed.Has(idKey(id)) {
		return 0, ErrAlreadyReversed
	}

	mirror := make([]Posting, len(orig.Postings))
	for i, p := range orig.Postings {
		mirror[i] = Posting{Account: p.Account, Side: p.Side.Opposite(), Amount: p.Amount}
	}

	newID, err := b.post(at, memo, id, mirror)
	if err != nil {
		return 0, err
	}
	// Marked only after post succeeded, so a refused reversal does not
	// consume the original's single reversal.
	b.reversed.Set(idKey(id), true)
	return newID, nil
}

// MustReverse is Reverse but panics on error.
func (b *Book) MustReverse(id uint64, at int64, memo string) uint64 {
	newID, err := b.Reverse(id, at, memo)
	if err != nil {
		panic(err)
	}
	return newID
}

// IsReversed reports whether an entry has already been reversed. It returns
// false for an entry that does not exist, so pair it with Entry when the
// distinction matters.
func (b *Book) IsReversed(id uint64) bool { return b.reversed.Has(idKey(id)) }

// Close seals the period ending at `through`, after which Post and Reverse
// refuse any entry dated at or before it.
//
// It only moves forward. A first close may name any non-negative instant; a
// later one must name a strictly greater instant, so a seal can never be
// loosened and backdating can never be re-enabled.
//
// Fails with ErrInvalidAt (through < 0) or ErrCloseNotForward. On error
// nothing is modified.
func (b *Book) Close(through int64) error {
	if through < 0 {
		return ErrInvalidAt
	}
	if b.hasClosed && through <= b.closedThrough {
		return ErrCloseNotForward
	}
	b.closedThrough = through
	b.hasClosed = true
	return nil
}

// MustClose is Close but panics on error.
func (b *Book) MustClose(through int64) {
	if err := b.Close(through); err != nil {
		panic(err)
	}
}

// Entry returns an entry by ID, with a defensive copy of its postings. The
// second result is false if no such entry exists — which, because entries
// are never removed, means it was never created.
func (b *Book) Entry(id uint64) (Entry, bool) {
	e, ok := b.entry(id)
	if !ok {
		return Entry{}, false
	}
	return e.withCopiedPostings(), true
}

// IsBalanced reports whether the Book's two independently-maintained
// accumulators agree with each other and with themselves.
//
// It scans the chart, sums every account's debit and credit totals, and
// requires that the two sums are equal AND that each matches the Book's own
// running total. Those totals are written by different code in Post, so a
// disagreement is a defect in this package and IsBalanced is how a consumer
// detects one.
//
// What it does not do is re-read the journal. Read the package doc's
// "What balanced is actually worth" before quoting it, and use
// RederiveFromJournal for the strong claim.
//
// An empty Book is balanced.
func (b *Book) IsBalanced() bool {
	d, c, ok := b.sumAccounts()
	if !ok {
		return false
	}
	return d == c && d == b.totalDebits && c == b.totalCredits
}

// RederiveFromJournal replays every posting of every entry and reports the
// debit and credit totals it finds, together with whether they agree with
// both the per-account accumulators and the Book's running totals.
//
// This is the strong check and the expensive one: its cost is proportional
// to every posting ever made, so it is meant to be called deliberately — by
// an auditor, or by a consumer's own invariant view — and not from a hot
// path. `agrees` false on a Book this package built is a defect in this
// package.
func (b *Book) RederiveFromJournal() (debits, credits int64, agrees bool) {
	var d, c int64
	okMath := true
	b.entries.Iterate("", "", func(_ string, value any) bool {
		e := value.(Entry)
		for _, p := range e.Postings {
			var ok bool
			if p.Side == Debit {
				d, ok = checkedAdd(d, p.Amount)
			} else {
				c, ok = checkedAdd(c, p.Amount)
			}
			if !ok {
				okMath = false
				return true
			}
		}
		return false
	})
	if !okMath {
		return 0, 0, false
	}
	sd, sc, okSum := b.sumAccounts()
	agrees = okSum &&
		d == c &&
		d == b.totalDebits && c == b.totalCredits &&
		d == sd && c == sc
	return d, c, agrees
}

// AccountingEquation returns the two halves of assets+expenses versus
// liabilities+equity+revenue, in RAW debit-minus-credit terms, and whether
// they offset.
//
// IT IS WEAKER THAN IT LOOKS, and weaker than this doc used to claim.
//
// What offsets ACTUALLY proves: sum(RawDelta) == 0 over the whole chart,
// which is the same fact as IsBalanced's first conjunct (d == c) and
// nothing more. IsBalanced requires three. So this is implied by
// IsBalanced, is NOT an independent accounting fact, and citing it as a
// second guarantee alongside IsBalanced is counting one check twice.
//
// What offsets DOES NOT prove, despite the Kind partition sitting right
// there in the code: anything whatsoever about normal-balance handling.
// dn and cn are a partition of the same addends, so dn+cn is the total
// regardless of which bucket each account landed in. Reclassify every
// account in the chart and BOTH subtotals change while offsets stays
// true. A Kind set wrongly at Open time is undetectable here and
// undetectable anywhere else in this package — obligation 7.
//
// It is exported because the two SUBTOTALS are correct and a consumer
// presenting a balance sheet wants them anyway. They are the product;
// offsets is a duplicate of a check you already have.
func (b *Book) AccountingEquation() (debitNormal, creditNormal int64, offsets bool) {
	var dn, cn int64
	okMath := true
	b.accounts.Iterate("", "", func(_ string, value any) bool {
		a := value.(Account)
		var ok bool
		if a.Kind.IsDebitNormal() {
			dn, ok = checkedAdd(dn, a.RawDelta())
		} else {
			cn, ok = checkedAdd(cn, a.RawDelta())
		}
		if !ok {
			okMath = false
			return true
		}
		return false
	})
	if !okMath {
		return 0, 0, false
	}
	sum, ok := checkedAdd(dn, cn)
	return dn, cn, ok && sum == 0
}

// IterateAccounts calls fn for every account in ascending code order.
// Iteration stops early when fn returns true.
//
// fn receives a COPY: Account is passed by value and holds only scalars and
// strings, so fn gets no pointer into the Book.
//
// Two rules for fn, and the second is the one that is easy to miss.
//
//   - Do not Open, Post, Reverse or Close from inside fn: mutating a tree
//     while iterating it is undefined. Collect what you need first, then act
//     after IterateAccounts returns.
//
//   - fn runs under the CALLING REALM'S STORAGE AUTHORITY. This method's
//     receiver is stamped with the importing realm's PkgID, so the borrow
//     rules leave the realm context set to that realm for the whole
//     callback, and a top-level fn has no receiver and no declaring realm to
//     anchor it elsewhere. A callback that re-enters the calling realm's own
//     mutators therefore does so with that realm's authority. Never pass a
//     caller-supplied function here from inside a permission-gated path;
//     pass only a closure this package's consumer wrote itself.
func (b *Book) IterateAccounts(fn func(Account) bool) {
	b.accounts.Iterate("", "", func(_ string, value any) bool {
		return fn(value.(Account))
	})
}

// IterateEntries calls fn for every entry in ascending ID order, which for
// an append-only journal is also chronological by insertion. Iteration stops
// early when fn returns true.
//
// fn receives an Entry whose Postings slice is a DEFENSIVE COPY, so a
// callback cannot write through it into Book state. The two rules on
// IterateAccounts's fn apply here unchanged, including the storage-authority
// one.
func (b *Book) IterateEntries(fn func(Entry) bool) {
	b.entries.Iterate("", "", func(_ string, value any) bool {
		return fn(value.(Entry).withCopiedPostings())
	})
}

// Entries returns up to limit entries with ID >= from, in ascending ID
// order, each with a defensive copy of its postings. A limit <= 0 returns
// nothing. It is the paging read for a consumer that cannot hold the whole
// journal in one call.
func (b *Book) Entries(from uint64, limit int) []Entry {
	out := []Entry{}
	if limit <= 0 {
		return out
	}
	b.entries.Iterate(idKey(from), "", func(_ string, value any) bool {
		out = append(out, value.(Entry).withCopiedPostings())
		return len(out) >= limit
	})
	return out
}

// post is the shared body of Post and Reverse. Callers have already
// validated `at`, the memo, and the period seal; reversalOf is 0 for an
// original entry. It validates every posting and computes both totals before
// writing anything.
func (b *Book) post(at int64, memo string, reversalOf uint64, postings []Posting) (uint64, error) {
	if len(postings) < 2 {
		return 0, ErrTooFewPostings
	}
	if len(postings) > MaxPostingsPerEntry {
		return 0, ErrTooManyPostings
	}
	if b.entries.Size() >= b.maxEntries {
		return 0, ErrBookFull
	}
	if b.nextID == 0 {
		return 0, ErrIDExhausted
	}

	var debits, credits int64
	sawDebit, sawCredit := false, false
	for _, p := range postings {
		if !p.Side.Valid() {
			return 0, ErrInvalidSide
		}
		if p.Amount <= 0 {
			return 0, ErrInvalidAmount
		}
		if !b.accounts.Has(p.Account) {
			return 0, ErrUnknownAccount
		}
		var ok bool
		if p.Side == Debit {
			sawDebit = true
			debits, ok = checkedAdd(debits, p.Amount)
		} else {
			sawCredit = true
			credits, ok = checkedAdd(credits, p.Amount)
		}
		if !ok {
			return 0, ErrOverflow
		}
	}
	if !sawDebit {
		return 0, ErrNoDebit
	}
	if !sawCredit {
		return 0, ErrNoCredit
	}
	if debits < credits {
		return 0, ErrDebitShort
	}
	if credits < debits {
		return 0, ErrCreditShort
	}

	// Book-level running totals, checked before any account is touched.
	newTotalDebits, ok := checkedAdd(b.totalDebits, debits)
	if !ok {
		return 0, ErrOverflow
	}
	newTotalCredits, ok := checkedAdd(b.totalCredits, credits)
	if !ok {
		return 0, ErrOverflow
	}

	// Per-account accumulators, all computed into a staging list before the
	// first Set, so an overflow on the last posting leaves nothing written.
	staged := make([]Account, len(postings))
	for i, p := range postings {
		a, found := b.account(p.Account)
		if !found {
			// Unreachable: Has() succeeded above and nothing has been
			// written since. Refused rather than ignored, because a silent
			// zero Account here would corrupt the chart.
			return 0, ErrUnknownAccount
		}
		// Fold earlier stagings of the same account, so an entry that posts
		// to one account twice accumulates both legs instead of the second
		// staging overwriting the first.
		for j := 0; j < i; j++ {
			if staged[j].Code == p.Account {
				a = staged[j]
			}
		}
		var okAcc bool
		if p.Side == Debit {
			a.Debits, okAcc = checkedAdd(a.Debits, p.Amount)
		} else {
			a.Credits, okAcc = checkedAdd(a.Credits, p.Amount)
		}
		if !okAcc {
			return 0, ErrOverflow
		}
		staged[i] = a
	}

	// Past here nothing can fail.
	id := b.nextID
	b.nextID++
	stored := make([]Posting, len(postings))
	copy(stored, postings)
	b.entries.Set(idKey(id), Entry{
		ID:         id,
		At:         at,
		Memo:       memo,
		Postings:   stored,
		ReversalOf: reversalOf,
	})
	for _, a := range staged {
		b.accounts.Set(a.Code, a)
	}
	b.totalDebits = newTotalDebits
	b.totalCredits = newTotalCredits
	return id, nil
}

// sumAccounts totals every account's debit and credit columns. The bool is
// false on overflow, which is why callers must not treat (0, 0) as an empty
// chart.
func (b *Book) sumAccounts() (debits, credits int64, ok bool) {
	var d, c int64
	okMath := true
	b.accounts.Iterate("", "", func(_ string, value any) bool {
		a := value.(Account)
		var okAdd bool
		if d, okAdd = checkedAdd(d, a.Debits); !okAdd {
			okMath = false
			return true
		}
		if c, okAdd = checkedAdd(c, a.Credits); !okAdd {
			okMath = false
			return true
		}
		return false
	})
	if !okMath {
		return 0, 0, false
	}
	return d, c, true
}

// account looks up one chart line.
func (b *Book) account(code string) (Account, bool) {
	v := b.accounts.Get(code)
	if v == nil {
		return Account{}, false
	}
	return v.(Account), true
}

// entry looks up one journal entry, WITHOUT copying its postings. Internal
// callers must not retain or mutate the returned slice; every exported path
// goes through withCopiedPostings.
func (b *Book) entry(id uint64) (Entry, bool) {
	v := b.entries.Get(idKey(id))
	if v == nil {
		return Entry{}, false
	}
	return v.(Entry), true
}

// withCopiedPostings returns e with a fresh Postings slice, so a value
// handed to a caller shares no backing array with the Book.
func (e Entry) withCopiedPostings() Entry {
	out := make([]Posting, len(e.Postings))
	copy(out, e.Postings)
	e.Postings = out
	return e
}

// idKey encodes an ID so that avl's lexical key order matches numeric ID
// order. math.MaxUint64 is 20 digits, so a fixed 20-wide zero-padded
// decimal is both sufficient and unambiguous.
func idKey(id uint64) string {
	s := strconv.FormatUint(id, 10)
	const width = 20
	if len(s) >= width {
		return s
	}
	return zeros[:width-len(s)] + s
}

const zeros = "00000000000000000000"

// checkedAdd returns a+b and reports whether the addition did not overflow
// int64.
func checkedAdd(a, b int64) (int64, bool) {
	sum := a + b
	if (b > 0 && sum < a) || (b < 0 && sum > a) {
		return 0, false
	}
	return sum, true
}
