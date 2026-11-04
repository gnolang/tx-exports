package journal

import (
	"testing"
)

const (
	cash    = "1000"
	ar      = "1100"
	payable = "2000"
	capital = "3000"
	revenue = "4000"
	rent    = "5000"
)

// newBook is the default fixture: a six-line chart covering all five kinds,
// a generous entry cap.
func newBook(t *testing.T) *Book {
	t.Helper()
	b, err := New(32, 1000)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	b.MustOpen(cash, "Cash", Asset)
	b.MustOpen(ar, "Accounts receivable", Asset)
	b.MustOpen(payable, "Accounts payable", Liability)
	b.MustOpen(capital, "Owner capital", Equity)
	b.MustOpen(revenue, "Sales", Revenue)
	b.MustOpen(rent, "Rent expense", Expense)
	return b
}

// mustPanicWith asserts fn panics with exactly want. A /p/ function called
// from a /p/ test crosses no realm boundary, so the panic is LOCAL and
// recover() is the right family -- Aborts* would not see it at all.
func mustPanicWith(t *testing.T, want string, fn func()) {
	t.Helper()
	defer func() {
		r := recover()
		if r == nil {
			t.Fatalf("expected panic %q, got none", want)
		}
		err, ok := r.(error)
		if !ok || err.Error() != want {
			t.Fatalf("panic = %v, want %q", r, want)
		}
	}()
	fn()
}

// pair is the simplest balanced entry: debit one account, credit another.
func pair(dr, cr string, amount int64) []Posting {
	return []Posting{
		{Account: dr, Side: Debit, Amount: amount},
		{Account: cr, Side: Credit, Amount: amount},
	}
}

// --- construction ---------------------------------------------------------

func TestNewRejectsBadConfig(t *testing.T) {
	cases := []struct {
		name                   string
		maxAccounts, maxEntries int
	}{
		{"zero accounts", 0, 10},
		{"negative accounts", -1, 10},
		{"accounts over limit", MaxAccountsLimit + 1, 10},
		{"zero entries", 10, 0},
		{"negative entries", 10, -1},
		{"entries over limit", 10, MaxEntriesLimit + 1},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := New(tc.maxAccounts, tc.maxEntries); err != ErrInvalidConfig {
				t.Fatalf("New = %v, want ErrInvalidConfig", err)
			}
		})
	}
}

func TestNewAtLimitsIsAccepted(t *testing.T) {
	// The positive control for the bounds above: a sabotage that rejected
	// everything would pass those cases and fail this one.
	if _, err := New(1, 1); err != nil {
		t.Fatalf("New(1,1) = %v, want nil", err)
	}
	if _, err := New(MaxAccountsLimit, MaxEntriesLimit); err != nil {
		t.Fatalf("New at limits = %v, want nil", err)
	}
}

func TestNewBookIsEmptyAndBalanced(t *testing.T) {
	b := MustNew(4, 4)
	if b.AccountCount() != 0 || b.EntryCount() != 0 {
		t.Fatalf("counts = %d/%d, want 0/0", b.AccountCount(), b.EntryCount())
	}
	if b.NextID() != 1 {
		t.Fatalf("NextID = %d, want 1", b.NextID())
	}
	if !b.IsBalanced() {
		t.Fatal("an empty book must be balanced")
	}
	if _, _, agrees := b.RederiveFromJournal(); !agrees {
		t.Fatal("an empty book must rederive")
	}
	if _, closed := b.ClosedThrough(); closed {
		t.Fatal("a new book must not report a closed period")
	}
}

func TestMustNewPanics(t *testing.T) {
	mustPanicWith(t, "journal: invalid book configuration", func() { MustNew(0, 1) })
}

// --- kinds and sides ------------------------------------------------------

func TestKindNormalBalance(t *testing.T) {
	cases := []struct {
		k           Kind
		valid       bool
		debitNormal bool
		name        string
	}{
		{Asset, true, true, "asset"},
		{Expense, true, true, "expense"},
		{Liability, true, false, "liability"},
		{Equity, true, false, "equity"},
		{Revenue, true, false, "revenue"},
		{Kind(0), false, false, "invalid"},
		{Kind(6), false, false, "invalid"},
		{Kind(255), false, false, "invalid"},
	}
	for _, tc := range cases {
		if got := tc.k.Valid(); got != tc.valid {
			t.Fatalf("Kind(%d).Valid = %v, want %v", uint8(tc.k), got, tc.valid)
		}
		if got := tc.k.IsDebitNormal(); got != tc.debitNormal {
			t.Fatalf("Kind(%d).IsDebitNormal = %v, want %v", uint8(tc.k), got, tc.debitNormal)
		}
		if got := tc.k.String(); got != tc.name {
			t.Fatalf("Kind(%d).String = %q, want %q", uint8(tc.k), got, tc.name)
		}
	}
}

func TestSideValidityAndOpposite(t *testing.T) {
	if !Debit.Valid() || !Credit.Valid() {
		t.Fatal("Debit and Credit must be valid")
	}
	if Side(0).Valid() || Side(3).Valid() {
		t.Fatal("only Debit and Credit are valid sides")
	}
	if Debit.Opposite() != Credit || Credit.Opposite() != Debit {
		t.Fatal("Opposite must swap the two sides")
	}
	// An invalid side returns itself rather than a plausible default, so a
	// caller that skipped validation gets an invalid posting.
	if Side(0).Opposite() != Side(0) {
		t.Fatal("Opposite of an invalid side must stay invalid")
	}
	if Debit.String() != "debit" || Credit.String() != "credit" || Side(9).String() != "invalid" {
		t.Fatal("Side.String")
	}
}

// --- opening accounts -----------------------------------------------------

func TestOpenValidation(t *testing.T) {
	long := ""
	for i := 0; i < MaxCodeLen+1; i++ {
		long += "x"
	}
	longName := ""
	for i := 0; i < MaxNameLen+1; i++ {
		longName += "y"
	}
	cases := []struct {
		name string
		code string
		acct string
		kind Kind
		want error
	}{
		{"empty code", "", "Cash", Asset, ErrEmptyCode},
		{"code too long", long, "Cash", Asset, ErrCodeTooLong},
		{"name too long", "1", longName, Asset, ErrNameTooLong},
		{"zero kind", "1", "Cash", Kind(0), ErrInvalidKind},
		{"unknown kind", "1", "Cash", Kind(6), ErrInvalidKind},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			b := MustNew(4, 4)
			if err := b.Open(tc.code, tc.acct, tc.kind); err != tc.want {
				t.Fatalf("Open = %v, want %v", err, tc.want)
			}
			if b.AccountCount() != 0 {
				t.Fatal("a refused Open must leave the chart unchanged")
			}
		})
	}
}

func TestOpenAtExactLengthLimitsIsAccepted(t *testing.T) {
	// Positive control for the two length guards: off-by-one in the wrong
	// direction would reject these.
	code := ""
	for i := 0; i < MaxCodeLen; i++ {
		code += "x"
	}
	name := ""
	for i := 0; i < MaxNameLen; i++ {
		name += "y"
	}
	b := MustNew(4, 4)
	if err := b.Open(code, name, Asset); err != nil {
		t.Fatalf("Open at exact limits = %v, want nil", err)
	}
}

func TestOpenRejectsDuplicateAndRespectsCap(t *testing.T) {
	b := MustNew(2, 4)
	b.MustOpen("1", "One", Asset)
	if err := b.Open("1", "Different name", Revenue); err != ErrAccountExists {
		t.Fatalf("duplicate Open = %v, want ErrAccountExists", err)
	}
	// The duplicate must not have overwritten the original.
	a, _ := b.Account("1")
	if a.Name != "One" || a.Kind != Asset {
		t.Fatalf("account mutated by refused Open: %+v", a)
	}
	b.MustOpen("2", "Two", Liability)
	if err := b.Open("3", "Three", Asset); err != ErrChartFull {
		t.Fatalf("Open past cap = %v, want ErrChartFull", err)
	}
	if b.AccountCount() != 2 {
		t.Fatalf("AccountCount = %d, want 2", b.AccountCount())
	}
}

func TestMustOpenPanics(t *testing.T) {
	b := MustNew(4, 4)
	mustPanicWith(t, "journal: empty account code", func() { b.MustOpen("", "x", Asset) })
}

func TestAccountAndBalanceDistinguishMissingFromZero(t *testing.T) {
	b := newBook(t)
	if _, ok := b.Account("nope"); ok {
		t.Fatal("Account must report a missing code")
	}
	// The distinction that matters: a missing account is not a zero balance.
	if v, ok := b.Balance("nope"); ok || v != 0 {
		t.Fatalf("Balance(missing) = %d,%v want 0,false", v, ok)
	}
	if v, ok := b.Balance(cash); !ok || v != 0 {
		t.Fatalf("Balance(open, unposted) = %d,%v want 0,true", v, ok)
	}
}

// --- posting --------------------------------------------------------------

func TestPostBalancedEntryUpdatesBothSides(t *testing.T) {
	b := newBook(t)
	id, err := b.Post(100, "owner funds the business", pair(cash, capital, 5000))
	if err != nil {
		t.Fatalf("Post: %v", err)
	}
	if id != 1 || b.NextID() != 2 {
		t.Fatalf("id=%d nextID=%d, want 1 and 2", id, b.NextID())
	}
	if got, _ := b.Balance(cash); got != 5000 {
		t.Fatalf("cash balance = %d, want 5000", got)
	}
	// Equity is credit-normal, so a credit is a POSITIVE balance. A
	// debit-normal reading would report -5000 here.
	if got, _ := b.Balance(capital); got != 5000 {
		t.Fatalf("capital balance = %d, want +5000 (credit-normal)", got)
	}
	a, _ := b.Account(cash)
	if a.Debits != 5000 || a.Credits != 0 || a.RawDelta() != 5000 {
		t.Fatalf("cash account = %+v", a)
	}
	e, _ := b.Account(capital)
	if e.Debits != 0 || e.Credits != 5000 || e.RawDelta() != -5000 {
		t.Fatalf("capital account = %+v", e)
	}
	if b.TotalDebits() != 5000 || b.TotalCredits() != 5000 {
		t.Fatalf("totals = %d/%d, want 5000/5000", b.TotalDebits(), b.TotalCredits())
	}
	if !b.IsBalanced() {
		t.Fatal("book must be balanced after a balanced entry")
	}
}

func TestPostRefusesUnbalancedAndNamesTheShortSide(t *testing.T) {
	b := newBook(t)
	// Debits short: 100 debit against 150 credit.
	short := []Posting{
		{Account: cash, Side: Debit, Amount: 100},
		{Account: revenue, Side: Credit, Amount: 150},
	}
	if _, err := b.Post(1, "", short); err != ErrDebitShort {
		t.Fatalf("Post = %v, want ErrDebitShort", err)
	}
	// Credits short: the mirror case must report the OTHER error, or the
	// refusal is not actually naming the short side.
	other := []Posting{
		{Account: cash, Side: Debit, Amount: 150},
		{Account: revenue, Side: Credit, Amount: 100},
	}
	if _, err := b.Post(1, "", other); err != ErrCreditShort {
		t.Fatalf("Post = %v, want ErrCreditShort", err)
	}
	if b.EntryCount() != 0 || b.TotalDebits() != 0 {
		t.Fatal("a refused Post must leave the book completely unchanged")
	}
	if got, _ := b.Balance(cash); got != 0 {
		t.Fatalf("cash moved on a refused Post: %d", got)
	}
}

func TestPostValidation(t *testing.T) {
	long := ""
	for i := 0; i < MaxMemoLen+1; i++ {
		long += "m"
	}
	many := []Posting{}
	for i := 0; i < MaxPostingsPerEntry+1; i++ {
		side := Debit
		if i%2 == 1 {
			side = Credit
		}
		many = append(many, Posting{Account: cash, Side: side, Amount: 1})
	}
	cases := []struct {
		name     string
		at       int64
		memo     string
		postings []Posting
		want     error
	}{
		{"negative at", -1, "", pair(cash, revenue, 1), ErrInvalidAt},
		{"memo too long", 1, long, pair(cash, revenue, 1), ErrMemoTooLong},
		{"no postings", 1, "", []Posting{}, ErrTooFewPostings},
		{"one posting", 1, "", []Posting{{Account: cash, Side: Debit, Amount: 1}}, ErrTooFewPostings},
		{"too many postings", 1, "", many, ErrTooManyPostings},
		{"zero side", 1, "", []Posting{
			{Account: cash, Side: Side(0), Amount: 1},
			{Account: revenue, Side: Credit, Amount: 1},
		}, ErrInvalidSide},
		{"zero amount", 1, "", []Posting{
			{Account: cash, Side: Debit, Amount: 0},
			{Account: revenue, Side: Credit, Amount: 0},
		}, ErrInvalidAmount},
		{"negative amount", 1, "", []Posting{
			{Account: cash, Side: Debit, Amount: -5},
			{Account: revenue, Side: Credit, Amount: -5},
		}, ErrInvalidAmount},
		{"unknown account", 1, "", pair(cash, "9999", 1), ErrUnknownAccount},
		{"all debits", 1, "", []Posting{
			{Account: cash, Side: Debit, Amount: 1},
			{Account: ar, Side: Debit, Amount: 1},
		}, ErrNoCredit},
		{"all credits", 1, "", []Posting{
			{Account: revenue, Side: Credit, Amount: 1},
			{Account: payable, Side: Credit, Amount: 1},
		}, ErrNoDebit},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			b := newBook(t)
			if _, err := b.Post(tc.at, tc.memo, tc.postings); err != tc.want {
				t.Fatalf("Post = %v, want %v", err, tc.want)
			}
			if b.EntryCount() != 0 {
				t.Fatal("a refused Post must write nothing")
			}
			if !b.IsBalanced() {
				t.Fatal("a refused Post must leave the book balanced")
			}
		})
	}
}

func TestPostAtExactPostingLimitIsAccepted(t *testing.T) {
	// Positive control for ErrTooManyPostings.
	b := newBook(t)
	ps := []Posting{}
	for i := 0; i < MaxPostingsPerEntry; i++ {
		side := Debit
		if i%2 == 1 {
			side = Credit
		}
		ps = append(ps, Posting{Account: cash, Side: side, Amount: 1})
	}
	if _, err := b.Post(1, "", ps); err != nil {
		t.Fatalf("Post at exactly MaxPostingsPerEntry = %v, want nil", err)
	}
}

func TestPostAtZeroIsAcceptedOnAnUnclosedBook(t *testing.T) {
	// at == 0 is a legitimate instant. It is only refused once a period has
	// actually been closed through it -- which is why hasClosed exists.
	b := newBook(t)
	if _, err := b.Post(0, "genesis", pair(cash, capital, 1)); err != nil {
		t.Fatalf("Post(at=0) = %v, want nil", err)
	}
}

func TestPostMultiLegEntry(t *testing.T) {
	b := newBook(t)
	// One debit split across two credits.
	id := b.MustPost(10, "part cash, part credit", []Posting{
		{Account: cash, Side: Debit, Amount: 300},
		{Account: ar, Side: Debit, Amount: 700},
		{Account: revenue, Side: Credit, Amount: 1000},
	})
	e, ok := b.Entry(id)
	if !ok {
		t.Fatal("entry missing")
	}
	if len(e.Postings) != 3 {
		t.Fatalf("postings = %d, want 3", len(e.Postings))
	}
	if e.Total() != 1000 {
		t.Fatalf("Total = %d, want 1000", e.Total())
	}
	if got, _ := b.Balance(revenue); got != 1000 {
		t.Fatalf("revenue = %d, want 1000", got)
	}
	if !b.IsBalanced() {
		t.Fatal("multi-leg entry must balance")
	}
}

func TestPostSameAccountTwiceInOneEntryAccumulatesBothLegs(t *testing.T) {
	// The staging loop folds earlier stagings of the same account. Without
	// that fold the second leg would overwrite the first and the account
	// would silently lose a posting while the book-level totals kept both --
	// which IsBalanced is built to catch, so assert both.
	b := newBook(t)
	b.MustPost(1, "net settlement through one account", []Posting{
		{Account: cash, Side: Debit, Amount: 500},
		{Account: cash, Side: Credit, Amount: 200},
		{Account: revenue, Side: Credit, Amount: 400},
		{Account: rent, Side: Debit, Amount: 100},
	})
	a, _ := b.Account(cash)
	if a.Debits != 500 || a.Credits != 200 {
		t.Fatalf("cash = %+v, want debits 500 credits 200", a)
	}
	if a.Balance() != 300 {
		t.Fatalf("cash balance = %d, want 300", a.Balance())
	}
	if !b.IsBalanced() {
		t.Fatal("per-account totals drifted from the running totals")
	}
	if _, _, agrees := b.RederiveFromJournal(); !agrees {
		t.Fatal("journal replay disagrees with the accumulators")
	}
}

func TestPostThreeLegsToOneAccountFoldsAllOfThem(t *testing.T) {
	// THREE legs, not two, and that is the entire point of the case.
	//
	// The staging fold scans every earlier staging and reassigns without
	// breaking, so the LAST match wins -- which is correct, because each
	// staging already carries the folds up to it. A `break` after the
	// first match would be the bug, and with only TWO legs the first
	// match IS the last, so the two-leg case above passes either way.
	// It takes a third leg to tell the implementation from the sabotage,
	// and neither IsBalanced nor RederiveFromJournal would notice: the
	// dropped middle leg would be absent from the account AND from the
	// stored entry the replay reads.
	b := newBook(t)
	b.MustPost(1, "three legs through one account", []Posting{
		{Account: cash, Side: Debit, Amount: 500},
		{Account: cash, Side: Credit, Amount: 200},
		{Account: cash, Side: Debit, Amount: 100},
		{Account: revenue, Side: Credit, Amount: 400},
	})
	a, _ := b.Account(cash)
	if a.Debits != 600 || a.Credits != 200 {
		t.Fatalf("cash = %+v, want debits 600 credits 200 (all three legs)", a)
	}
	if a.Balance() != 400 {
		t.Fatalf("cash balance = %d, want 400", a.Balance())
	}
	if b.TotalDebits() != 600 || b.TotalCredits() != 600 {
		t.Fatalf("book totals = %d/%d, want 600/600",
			b.TotalDebits(), b.TotalCredits())
	}
	if !b.IsBalanced() {
		t.Fatal("per-account totals drifted from the running totals")
	}
	if _, _, agrees := b.RederiveFromJournal(); !agrees {
		t.Fatal("journal replay disagrees with the accumulators")
	}
	// And the stored entry kept all four postings, not a deduplicated three.
	e, ok := b.Entry(1)
	if !ok {
		t.Fatal("entry 1 missing")
	}
	if len(e.Postings) != 4 {
		t.Fatalf("stored postings = %d, want 4", len(e.Postings))
	}
}

func TestAccountingEquationIsBlindToAKindMisclassification(t *testing.T) {
	// The sabotage that proves the NEGATIVE claim in the docs, because an
	// unenforced doc claim is the defect this package keeps being audited
	// for. Obligation 7 and AccountingEquation's own doc both say a wrong
	// Kind is undetectable by every check here. Assert it rather than
	// asking a reader to believe it.
	//
	// If this test ever fails, some check learned to validate a Kind --
	// update the docs, do not relax the test.
	b := newBook(t)
	b.MustPost(1, "", pair(cash, revenue, 100))

	dn, cn, offsets := b.AccountingEquation()
	if !offsets {
		t.Fatal("precondition: a clean book must offset")
	}
	if dn != 100 || cn != -100 {
		t.Fatalf("subtotals = %d/%d, want 100/-100", dn, cn)
	}

	// Reclassify Cash from Asset to Liability: a credit-normal bucket for
	// an account holding a debit balance. Nothing about Debits or Credits
	// changes, so nothing built on them can see it.
	a, _ := b.Account(cash)
	a.Kind = Liability
	b.accounts.Set(a.Code, a)

	dn2, cn2, offsets2 := b.AccountingEquation()
	if !offsets2 {
		t.Fatal("offsets must STAY true -- it is invariant under the partition")
	}
	// Both subtotals moved, which is how we know the misclassification
	// really took effect and the invariance is not a vacuous pass.
	if dn2 != 0 || cn2 != 0 {
		t.Fatalf("subtotals = %d/%d, want 0/0 after reclassification", dn2, cn2)
	}
	if dn2 == dn && cn2 == cn {
		t.Fatal("subtotals did not move; the sabotage did not take")
	}
	// The other two tiers are equally blind.
	if !b.IsBalanced() {
		t.Fatal("IsBalanced must stay true: Kind is not one of its inputs")
	}
	if _, _, agrees := b.RederiveFromJournal(); !agrees {
		t.Fatal("RederiveFromJournal must stay true for the same reason")
	}
	// And the visible consequence: a sign-flipped balance, reported
	// confidently by the only accessor a consumer is likely to quote.
	a2, _ := b.Account(cash)
	if a2.Balance() != -100 {
		t.Fatalf("balance = %d, want -100 (the sign flip, silently)",
			a2.Balance())
	}
	if a2.RawDelta() != 100 {
		t.Fatalf("RawDelta = %d, want 100 -- unchanged, which is the point",
			a2.RawDelta())
	}
}

func TestPostRespectsEntryCap(t *testing.T) {
	b, err := New(8, 2)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	b.MustOpen(cash, "Cash", Asset)
	b.MustOpen(revenue, "Sales", Revenue)
	b.MustPost(1, "", pair(cash, revenue, 1))
	b.MustPost(2, "", pair(cash, revenue, 1))
	if _, err := b.Post(3, "", pair(cash, revenue, 1)); err != ErrBookFull {
		t.Fatalf("Post past cap = %v, want ErrBookFull", err)
	}
	if b.EntryCount() != 2 {
		t.Fatalf("EntryCount = %d, want 2", b.EntryCount())
	}
	// A refused Post must not consume an ID either.
	if b.NextID() != 3 {
		t.Fatalf("NextID = %d, want 3", b.NextID())
	}
}

func TestMustPostPanics(t *testing.T) {
	b := newBook(t)
	mustPanicWith(t, "journal: entry does not balance, debits are short", func() {
		b.MustPost(1, "", []Posting{
			{Account: cash, Side: Debit, Amount: 1},
			{Account: revenue, Side: Credit, Amount: 2},
		})
	})
}

// --- overflow -------------------------------------------------------------

func TestPostOverflowLeavesBookUnchanged(t *testing.T) {
	const maxInt64 = int64(9223372036854775807)
	b := newBook(t)
	b.MustPost(1, "", pair(cash, revenue, maxInt64))
	// A second entry of any positive size overflows the running totals.
	if _, err := b.Post(2, "", pair(cash, revenue, 1)); err != ErrOverflow {
		t.Fatalf("Post = %v, want ErrOverflow", err)
	}
	if b.EntryCount() != 1 || b.TotalDebits() != maxInt64 {
		t.Fatal("an overflowing Post must write nothing")
	}
	if !b.IsBalanced() {
		t.Fatal("book must remain balanced after a refused overflow")
	}
}

func TestPostOverflowWithinOneEntry(t *testing.T) {
	const maxInt64 = int64(9223372036854775807)
	b := newBook(t)
	if _, err := b.Post(1, "", []Posting{
		{Account: cash, Side: Debit, Amount: maxInt64},
		{Account: ar, Side: Debit, Amount: 1},
		{Account: revenue, Side: Credit, Amount: maxInt64},
		{Account: payable, Side: Credit, Amount: 1},
	}); err != ErrOverflow {
		t.Fatalf("Post = %v, want ErrOverflow", err)
	}
	if b.EntryCount() != 0 {
		t.Fatal("must write nothing")
	}
}

func TestPostRefusesWhenIDsAreExhausted(t *testing.T) {
	// nextID starts at 1 and only ever increases, so the wrap is 2^64
	// entries away and unreachable through the API. The guard is still
	// load-bearing -- a reused id makes one id name two entries -- so it
	// is proven by reaching past the API to the single state that fires
	// it, which is the move TestIsBalancedCatchesADriftedAccumulator makes
	// and for the same reason.
	b := newBook(t)
	b.nextID = 0
	if _, err := b.Post(1, "", pair(cash, revenue, 100)); err != ErrIDExhausted {
		t.Fatalf("Post = %v, want ErrIDExhausted", err)
	}
	if b.EntryCount() != 0 {
		t.Fatal("a refused Post must write nothing")
	}
}

func TestPostCopiesTheCallerSlice(t *testing.T) {
	// The write-side twin of TestEntryPostingsAreADefensiveCopy, which
	// mutates the slice Entry RETURNS. This one mutates the slice the
	// CALLER passed in: if post stored that slice by reference, the caller
	// keeps a writable window into a sealed journal entry, and no
	// read-side copy can take it back.
	b := newBook(t)
	legs := pair(cash, revenue, 100)
	id := b.MustPost(1, "", legs)

	legs[0].Amount = 999
	legs[0].Account = "hacked"
	legs[1].Side = Debit

	e, found := b.Entry(id)
	if !found {
		t.Fatal("the entry vanished")
	}
	if e.Postings[0].Amount != 100 || e.Postings[0].Account != cash {
		t.Fatalf("post stored the caller's slice: %+v", e.Postings[0])
	}
	if e.Postings[1].Side != Credit {
		t.Fatal("post stored the caller's slice: the side was mutated through it")
	}
	if _, _, agrees := b.RederiveFromJournal(); !agrees {
		t.Fatal("the journal must still agree with both accumulators")
	}
}

func TestPostChecksBothRunningTotalsSeparately(t *testing.T) {
	// A posted entry advances both running totals by the same amount, so
	// through the API either check alone would catch every overflow the
	// other one would -- which makes neither of them provable. Drifting
	// one accumulator first is what makes the debit check and the credit
	// check distinguishable at all.
	const maxInt64 = int64(9223372036854775807)

	b := newBook(t)
	b.totalDebits = maxInt64
	if _, err := b.Post(1, "", pair(cash, revenue, 1)); err != ErrOverflow {
		t.Fatalf("debit side: Post = %v, want ErrOverflow", err)
	}
	if b.EntryCount() != 0 {
		t.Fatal("debit side: a refused Post must write nothing")
	}

	b = newBook(t)
	b.totalCredits = maxInt64
	if _, err := b.Post(1, "", pair(cash, revenue, 1)); err != ErrOverflow {
		t.Fatalf("credit side: Post = %v, want ErrOverflow", err)
	}
	if b.EntryCount() != 0 {
		t.Fatal("credit side: a refused Post must write nothing")
	}
}

func TestPostRefusesAPerAccountOverflow(t *testing.T) {
	// The book-level totals are checked before the chart is touched, and
	// here they are at zero and pass -- so this reaches the per-account
	// staging check and nothing else does. Without it a chart line wraps
	// negative while the book still reads balanced at the top level.
	const maxInt64 = int64(9223372036854775807)
	b := newBook(t)
	a, _ := b.Account(cash)
	a.Debits = maxInt64
	b.accounts.Set(a.Code, a)

	if b.TotalDebits() != 0 {
		t.Fatal("precondition: the book-level check must not be the one that fires")
	}
	if _, err := b.Post(1, "", pair(cash, revenue, 1)); err != ErrOverflow {
		t.Fatalf("Post = %v, want ErrOverflow", err)
	}
	if b.EntryCount() != 0 {
		t.Fatal("a refused Post must write nothing")
	}
	again, _ := b.Account(cash)
	if again.Debits != maxInt64 {
		t.Fatalf("cash.Debits = %d, want the whole staging list discarded", again.Debits)
	}
}

func TestCheckedAddBranches(t *testing.T) {
	const maxInt64 = int64(9223372036854775807)
	const minInt64 = -maxInt64 - 1
	if v, ok := checkedAdd(2, 3); !ok || v != 5 {
		t.Fatalf("checkedAdd(2,3) = %d,%v", v, ok)
	}
	if _, ok := checkedAdd(maxInt64, 1); ok {
		t.Fatal("positive overflow not caught")
	}
	if _, ok := checkedAdd(minInt64, -1); ok {
		t.Fatal("negative overflow not caught")
	}
	if v, ok := checkedAdd(maxInt64, -1); !ok || v != maxInt64-1 {
		t.Fatalf("checkedAdd(max,-1) = %d,%v", v, ok)
	}
	if v, ok := checkedAdd(5, 0); !ok || v != 5 {
		t.Fatalf("checkedAdd(5,0) = %d,%v", v, ok)
	}
}

// --- reversal -------------------------------------------------------------

func TestReverseMirrorsEveryPostingAndNetsToZero(t *testing.T) {
	b := newBook(t)
	id := b.MustPost(10, "wrong account", []Posting{
		{Account: cash, Side: Debit, Amount: 300},
		{Account: ar, Side: Debit, Amount: 700},
		{Account: revenue, Side: Credit, Amount: 1000},
	})
	revID := b.MustReverse(id, 20, "fixing it")
	if revID != id+1 {
		t.Fatalf("reversal id = %d, want %d", revID, id+1)
	}

	rev, _ := b.Entry(revID)
	if !rev.IsReversal() || rev.ReversalOf != id {
		t.Fatalf("reversal metadata = %+v", rev)
	}
	if rev.At != 20 || rev.Memo != "fixing it" {
		t.Fatalf("reversal dating/memo = %+v", rev)
	}
	orig, _ := b.Entry(id)
	if orig.IsReversal() {
		t.Fatal("the original must not be marked a reversal")
	}
	if len(rev.Postings) != len(orig.Postings) {
		t.Fatalf("postings = %d, want %d", len(rev.Postings), len(orig.Postings))
	}
	for i, p := range rev.Postings {
		o := orig.Postings[i]
		if p.Account != o.Account || p.Amount != o.Amount || p.Side != o.Side.Opposite() {
			t.Fatalf("posting %d = %+v, want mirror of %+v", i, p, o)
		}
	}

	// The whole point: every balance is back to zero, and BOTH entries are
	// still visible.
	for _, code := range []string{cash, ar, revenue} {
		if got, _ := b.Balance(code); got != 0 {
			t.Fatalf("%s = %d, want 0 after reversal", code, got)
		}
	}
	if b.EntryCount() != 2 {
		t.Fatalf("EntryCount = %d, want 2 -- a reversal must not delete", b.EntryCount())
	}
	if !b.IsBalanced() {
		t.Fatal("book must be balanced after reversal")
	}
	if _, _, agrees := b.RederiveFromJournal(); !agrees {
		t.Fatal("journal replay must agree after reversal")
	}
}

func TestReverseIsOnceOnly(t *testing.T) {
	b := newBook(t)
	id := b.MustPost(1, "", pair(cash, revenue, 100))
	if b.IsReversed(id) {
		t.Fatal("a fresh entry must not read as reversed")
	}
	b.MustReverse(id, 2, "")
	if !b.IsReversed(id) {
		t.Fatal("IsReversed must report the reversal")
	}
	if _, err := b.Reverse(id, 3, ""); err != ErrAlreadyReversed {
		t.Fatalf("second Reverse = %v, want ErrAlreadyReversed", err)
	}
	if b.EntryCount() != 2 {
		t.Fatalf("EntryCount = %d, want 2", b.EntryCount())
	}
}

func TestReverseAReversalIsPermittedAndAlsoOnceOnly(t *testing.T) {
	// Documented behaviour: reversing a reversal re-applies the original.
	b := newBook(t)
	id := b.MustPost(1, "", pair(cash, revenue, 100))
	revID := b.MustReverse(id, 2, "")
	if got, _ := b.Balance(cash); got != 0 {
		t.Fatalf("cash = %d, want 0", got)
	}
	reRevID := b.MustReverse(revID, 3, "undo the undo")
	if got, _ := b.Balance(cash); got != 100 {
		t.Fatalf("cash = %d, want 100 -- re-reversal must re-apply", got)
	}
	if _, err := b.Reverse(revID, 4, ""); err != ErrAlreadyReversed {
		t.Fatalf("second Reverse of the reversal = %v, want ErrAlreadyReversed", err)
	}
	if reRevID != 3 || b.EntryCount() != 3 {
		t.Fatalf("ids/count = %d/%d, want 3/3", reRevID, b.EntryCount())
	}
	if !b.IsBalanced() {
		t.Fatal("must stay balanced")
	}
}

func TestReverseValidation(t *testing.T) {
	long := ""
	for i := 0; i < MaxMemoLen+1; i++ {
		long += "m"
	}
	b := newBook(t)
	id := b.MustPost(10, "", pair(cash, revenue, 100))
	cases := []struct {
		name string
		id   uint64
		at   int64
		memo string
		want error
	}{
		{"no such entry", 999, 20, "", ErrEntryNotFound},
		{"entry id zero", 0, 20, "", ErrEntryNotFound},
		{"negative at", id, -1, "", ErrInvalidAt},
		{"memo too long", id, 20, long, ErrMemoTooLong},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := b.Reverse(tc.id, tc.at, tc.memo); err != tc.want {
				t.Fatalf("Reverse = %v, want %v", err, tc.want)
			}
			if b.EntryCount() != 1 {
				t.Fatal("a refused Reverse must write nothing")
			}
			if b.IsReversed(id) {
				t.Fatal("a refused Reverse must not consume the single reversal")
			}
		})
	}
}

func TestRefusedReverseDoesNotConsumeTheReversal(t *testing.T) {
	// The ordering that matters: `reversed` is marked only AFTER post
	// succeeds. A book at its entry cap refuses the reversal; the original
	// must still be reversible once there is room.
	b, err := New(8, 1)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	b.MustOpen(cash, "Cash", Asset)
	b.MustOpen(revenue, "Sales", Revenue)
	id := b.MustPost(1, "", pair(cash, revenue, 100))
	if _, err := b.Reverse(id, 2, ""); err != ErrBookFull {
		t.Fatalf("Reverse = %v, want ErrBookFull", err)
	}
	if b.IsReversed(id) {
		t.Fatal("a reversal refused at the cap must not mark the entry reversed")
	}

	// Same book, with room: the reversal now succeeds.
	b2, _ := New(8, 2)
	b2.MustOpen(cash, "Cash", Asset)
	b2.MustOpen(revenue, "Sales", Revenue)
	id2 := b2.MustPost(1, "", pair(cash, revenue, 100))
	if _, err := b2.Reverse(id2, 2, ""); err != nil {
		t.Fatalf("Reverse with room = %v, want nil", err)
	}
}

func TestMustReversePanics(t *testing.T) {
	b := newBook(t)
	mustPanicWith(t, "journal: no such entry", func() { b.MustReverse(42, 1, "") })
}

// --- period close ---------------------------------------------------------

func TestCloseSealsBackdatingForBothPostAndReverse(t *testing.T) {
	b := newBook(t)
	id := b.MustPost(10, "", pair(cash, revenue, 100))
	if err := b.Close(100); err != nil {
		t.Fatalf("Close: %v", err)
	}
	through, closed := b.ClosedThrough()
	if !closed || through != 100 {
		t.Fatalf("ClosedThrough = %d,%v want 100,true", through, closed)
	}
	// At the boundary and below are sealed; the instant after is open.
	if _, err := b.Post(100, "", pair(cash, revenue, 1)); err != ErrPeriodClosed {
		t.Fatalf("Post at the seal = %v, want ErrPeriodClosed", err)
	}
	if _, err := b.Post(50, "", pair(cash, revenue, 1)); err != ErrPeriodClosed {
		t.Fatalf("Post before the seal = %v, want ErrPeriodClosed", err)
	}
	if _, err := b.Post(101, "", pair(cash, revenue, 1)); err != nil {
		t.Fatalf("Post after the seal = %v, want nil", err)
	}
	// Reverse is sealed by the same rule: a closed period cannot be
	// corrected in place.
	if _, err := b.Reverse(id, 100, ""); err != ErrPeriodClosed {
		t.Fatalf("Reverse into the seal = %v, want ErrPeriodClosed", err)
	}
	if b.IsReversed(id) {
		t.Fatal("a period-refused Reverse must not consume the reversal")
	}
	if _, err := b.Reverse(id, 200, "corrected in the open period"); err != nil {
		t.Fatalf("Reverse in the open period = %v, want nil", err)
	}
}

func TestCloseOnlyMovesForward(t *testing.T) {
	b := newBook(t)
	if err := b.Close(100); err != nil {
		t.Fatalf("Close: %v", err)
	}
	if err := b.Close(100); err != ErrCloseNotForward {
		t.Fatalf("re-close at the same instant = %v, want ErrCloseNotForward", err)
	}
	if err := b.Close(99); err != ErrCloseNotForward {
		t.Fatalf("close backwards = %v, want ErrCloseNotForward", err)
	}
	if err := b.Close(-1); err != ErrInvalidAt {
		t.Fatalf("Close(-1) = %v, want ErrInvalidAt", err)
	}
	// The seal must be exactly where it was after three refusals.
	through, _ := b.ClosedThrough()
	if through != 100 {
		t.Fatalf("ClosedThrough = %d, want 100", through)
	}
	if err := b.Close(101); err != nil {
		t.Fatalf("Close forward = %v, want nil", err)
	}
}

func TestCloseThroughZeroIsDistinctFromNeverClosed(t *testing.T) {
	// hasClosed exists for exactly this: without it, "closed through 0" is
	// indistinguishable from a new book, and a new book would silently
	// reject every entry dated at 0.
	b := newBook(t)
	if _, err := b.Post(0, "accepted before any close", pair(cash, capital, 1)); err != nil {
		t.Fatalf("Post(0) on a new book = %v, want nil", err)
	}
	if err := b.Close(0); err != nil {
		t.Fatalf("Close(0) = %v, want nil", err)
	}
	through, closed := b.ClosedThrough()
	if !closed || through != 0 {
		t.Fatalf("ClosedThrough = %d,%v want 0,true", through, closed)
	}
	if _, err := b.Post(0, "", pair(cash, capital, 1)); err != ErrPeriodClosed {
		t.Fatalf("Post(0) after Close(0) = %v, want ErrPeriodClosed", err)
	}
}

func TestMustClosePanics(t *testing.T) {
	b := newBook(t)
	b.MustClose(5)
	mustPanicWith(t, "journal: close must move forward", func() { b.MustClose(5) })
}

// --- invariants -----------------------------------------------------------

func TestInvariantsHoldAcrossALongSequence(t *testing.T) {
	b := newBook(t)
	b.MustPost(1, "capital", pair(cash, capital, 10000))
	b.MustPost(2, "sale on credit", pair(ar, revenue, 2500))
	b.MustPost(3, "collect", pair(cash, ar, 2500))
	b.MustPost(4, "rent accrued", pair(rent, payable, 800))
	b.MustPost(5, "rent paid", pair(payable, cash, 800))
	bad := b.MustPost(6, "mistake", pair(rent, cash, 999))
	b.MustReverse(bad, 7, "mistake reversed")

	if !b.IsBalanced() {
		t.Fatal("IsBalanced")
	}
	d, c, agrees := b.RederiveFromJournal()
	if !agrees {
		t.Fatal("RederiveFromJournal must agree")
	}
	if d != c || d != b.TotalDebits() {
		t.Fatalf("rederived %d/%d vs totals %d/%d", d, c, b.TotalDebits(), b.TotalCredits())
	}
	if _, _, offsets := b.AccountingEquation(); !offsets {
		t.Fatal("AccountingEquation must offset")
	}

	// Spot-check the economics, so this is a test of the ledger and not only
	// of its self-checks: 10000 in, 2500 collected, 800 rent paid, and the
	// 999 mistake reversed back out.
	if got, _ := b.Balance(cash); got != 10000+2500-800 {
		t.Fatalf("cash = %d, want 11700", got)
	}
	if got, _ := b.Balance(ar); got != 0 {
		t.Fatalf("AR = %d, want 0 after collection", got)
	}
	if got, _ := b.Balance(payable); got != 0 {
		t.Fatalf("payable = %d, want 0 after payment", got)
	}
	if got, _ := b.Balance(revenue); got != 2500 {
		t.Fatalf("revenue = %d, want 2500", got)
	}
	if got, _ := b.Balance(rent); got != 800 {
		t.Fatalf("rent = %d, want 800 -- the 999 error must be reversed out", got)
	}
}

func TestAccountingEquationHalvesAreReported(t *testing.T) {
	b := newBook(t)
	b.MustPost(1, "", pair(cash, capital, 10000))
	b.MustPost(2, "", pair(rent, payable, 400))
	// debit-normal raw delta: cash +10000, rent +400 = 10400
	// credit-normal raw delta: capital -10000, payable -400 = -10400
	dn, cn, offsets := b.AccountingEquation()
	if dn != 10400 || cn != -10400 || !offsets {
		t.Fatalf("AccountingEquation = %d,%d,%v want 10400,-10400,true", dn, cn, offsets)
	}
}

func TestIsBalancedCatchesADriftedAccumulator(t *testing.T) {
	// The sabotage that proves IsBalanced can fail. Reaching past the API
	// into the running total is exactly the drift it exists to detect; if
	// this book still read balanced, the check would be decorative.
	b := newBook(t)
	b.MustPost(1, "", pair(cash, revenue, 100))
	if !b.IsBalanced() {
		t.Fatal("precondition")
	}
	b.totalDebits += 1
	if b.IsBalanced() {
		t.Fatal("IsBalanced must fail when the running total drifts")
	}
	if _, _, agrees := b.RederiveFromJournal(); agrees {
		t.Fatal("RederiveFromJournal must fail on the same drift")
	}
	b.totalDebits -= 1

	// And the other representation: drift a per-account accumulator.
	a, _ := b.Account(cash)
	a.Debits += 7
	b.accounts.Set(a.Code, a)
	if b.IsBalanced() {
		t.Fatal("IsBalanced must fail when an account total drifts")
	}
	if _, _, offsets := b.AccountingEquation(); offsets {
		t.Fatal("AccountingEquation must fail on an account drift")
	}
}

func TestRederiveFromJournalCatchesACorruptedEntry(t *testing.T) {
	// The drift the cheap check cannot see: corrupt the JOURNAL while both
	// accumulators stay consistent with each other. IsBalanced passes --
	// which is the documented ceiling -- and only the replay catches it.
	b := newBook(t)
	id := b.MustPost(1, "", pair(cash, revenue, 100))
	e, _ := b.entry(id)
	e.Postings = []Posting{
		{Account: cash, Side: Debit, Amount: 999},
		{Account: revenue, Side: Credit, Amount: 999},
	}
	b.entries.Set(idKey(id), e)

	if !b.IsBalanced() {
		t.Fatal("IsBalanced is documented as blind to this; if it now catches it, update the doc")
	}
	d, c, agrees := b.RederiveFromJournal()
	if agrees {
		t.Fatal("RederiveFromJournal must catch a journal that disagrees with the accumulators")
	}
	if d != 999 || c != 999 {
		t.Fatalf("rederived = %d/%d, want 999/999 from the journal itself", d, c)
	}
}

func TestIsBalancedComparesTheTwoColumnsToEachOther(t *testing.T) {
	// d == b.totalDebits and c == b.totalCredits together do NOT imply
	// d == c: a book whose two representations agree with each other can
	// still have a debit column that does not equal its credit column.
	// Drifting an account and its matching running total by the SAME
	// amount leaves the d == c conjunct as the only one that can notice,
	// which is what makes that conjunct provable rather than redundant.
	b := newBook(t)
	b.MustPost(1, "", pair(cash, revenue, 100))
	if !b.IsBalanced() {
		t.Fatal("precondition")
	}
	a, _ := b.Account(cash)
	a.Debits += 7
	b.accounts.Set(a.Code, a)
	b.totalDebits += 7

	d, c, ok := b.sumAccounts()
	if !ok {
		t.Fatal("precondition: the chart must still sum")
	}
	if d != b.totalDebits || c != b.totalCredits {
		t.Fatalf("precondition: both representations must agree: chart %d/%d, totals %d/%d",
			d, c, b.totalDebits, b.totalCredits)
	}
	if d == c {
		t.Fatal("precondition: the two columns must differ")
	}
	if b.IsBalanced() {
		t.Fatal("IsBalanced must fail when the debit column does not equal the credit column")
	}
}

func TestIsBalancedRefusesAnOverflowedChartSum(t *testing.T) {
	// sumAccounts documents that callers must not read its (0, 0) on
	// overflow as an empty chart, and this is the reason: a fresh Book's
	// running totals are also 0/0, so discarding the ok makes an
	// overflowed chart read exactly like a book with nothing posted.
	const maxInt64 = int64(9223372036854775807)
	b := newBook(t)
	for _, code := range []string{cash, ar} {
		a, _ := b.Account(code)
		a.Debits = maxInt64
		b.accounts.Set(a.Code, a)
	}

	if _, _, ok := b.sumAccounts(); ok {
		t.Fatal("precondition: the chart sum must overflow")
	}
	if b.TotalDebits() != 0 || b.TotalCredits() != 0 {
		t.Fatal("precondition: the running totals must still be zero, or the test proves something else")
	}
	if b.IsBalanced() {
		t.Fatal("IsBalanced must refuse a chart sum it could not compute")
	}
	if _, _, agrees := b.RederiveFromJournal(); agrees {
		t.Fatal("RederiveFromJournal must refuse the same chart")
	}
}

func TestRederiveFromJournalComparesTheReplayToTheChart(t *testing.T) {
	// The chart is the third representation and the one the running totals
	// cannot stand in for. Drift one account only: the replay still agrees
	// with both running totals, so the d == sd && c == sc conjunct is the
	// only thing left that can catch it.
	b := newBook(t)
	b.MustPost(1, "", pair(cash, revenue, 100))
	a, _ := b.Account(cash)
	a.Debits += 7
	b.accounts.Set(a.Code, a)

	d, c, agrees := b.RederiveFromJournal()
	if d != 100 || c != 100 {
		t.Fatalf("replay = %d/%d, want 100/100 read back from the journal", d, c)
	}
	if d != b.totalDebits || c != b.totalCredits {
		t.Fatalf("precondition: the replay must still agree with both running totals (%d/%d)",
			b.totalDebits, b.totalCredits)
	}
	sd, sc, okSum := b.sumAccounts()
	if !okSum {
		t.Fatal("precondition: the chart must still sum")
	}
	if sd == d {
		t.Fatalf("precondition: the chart must disagree with the replay: chart %d/%d", sd, sc)
	}
	if agrees {
		t.Fatal("RederiveFromJournal must fail when the chart disagrees with the journal")
	}
}

// --- reads and encapsulation ----------------------------------------------

func TestEntryPostingsAreADefensiveCopy(t *testing.T) {
	b := newBook(t)
	id := b.MustPost(1, "", pair(cash, revenue, 100))

	e, _ := b.Entry(id)
	e.Postings[0].Amount = 1
	e.Postings[0].Account = "hacked"
	e.Postings[1].Side = Debit

	again, _ := b.Entry(id)
	if again.Postings[0].Amount != 100 || again.Postings[0].Account != cash {
		t.Fatalf("Entry returned a window into Book state: %+v", again.Postings[0])
	}
	if again.Postings[1].Side != Credit {
		t.Fatal("Entry's postings were mutated through the returned slice")
	}
	if !b.IsBalanced() {
		t.Fatal("book must be unaffected")
	}
}

func TestIterateEntriesAlsoCopies(t *testing.T) {
	b := newBook(t)
	b.MustPost(1, "", pair(cash, revenue, 100))
	b.IterateEntries(func(e Entry) bool {
		e.Postings[0].Amount = 42
		return false
	})
	again := b.Entries(1, 1)
	if len(again) != 1 || again[0].Postings[0].Amount != 100 {
		t.Fatal("IterateEntries handed out a writable window")
	}
}

func TestEntryMissingIsReportedNotZeroed(t *testing.T) {
	b := newBook(t)
	if _, ok := b.Entry(1); ok {
		t.Fatal("Entry on an empty journal must report false")
	}
	if _, ok := b.Entry(0); ok {
		t.Fatal("id 0 is never allocated")
	}
	if b.IsReversed(1) {
		t.Fatal("IsReversed on a missing entry must be false")
	}
}

func TestIterationIsInAscendingIDOrderPastTenEntries(t *testing.T) {
	// The padded-key test: with unpadded decimal keys, "10" sorts before
	// "2" and this fails at the tenth entry.
	b := newBook(t)
	for i := 0; i < 12; i++ {
		b.MustPost(int64(i+1), "", pair(cash, revenue, int64(i+1)))
	}
	var seen []uint64
	b.IterateEntries(func(e Entry) bool {
		seen = append(seen, e.ID)
		return false
	})
	if len(seen) != 12 {
		t.Fatalf("iterated %d, want 12", len(seen))
	}
	for i, id := range seen {
		if id != uint64(i+1) {
			t.Fatalf("order = %v, want 1..12 ascending", seen)
		}
	}
}

func TestIterationStopsEarly(t *testing.T) {
	b := newBook(t)
	for i := 0; i < 5; i++ {
		b.MustPost(int64(i+1), "", pair(cash, revenue, 1))
	}
	n := 0
	b.IterateEntries(func(Entry) bool {
		n++
		return n >= 2
	})
	if n != 2 {
		t.Fatalf("IterateEntries visited %d, want 2", n)
	}

	m := 0
	b.IterateAccounts(func(Account) bool {
		m++
		return m >= 3
	})
	if m != 3 {
		t.Fatalf("IterateAccounts visited %d, want 3", m)
	}
}

func TestIterateAccountsCoversTheChartInCodeOrder(t *testing.T) {
	b := newBook(t)
	var codes []string
	b.IterateAccounts(func(a Account) bool {
		codes = append(codes, a.Code)
		return false
	})
	want := []string{cash, ar, payable, capital, revenue, rent}
	if len(codes) != len(want) {
		t.Fatalf("iterated %d accounts, want %d", len(codes), len(want))
	}
	for i := range want {
		if codes[i] != want[i] {
			t.Fatalf("order = %v, want %v", codes, want)
		}
	}
}

func TestEntriesPagesFromAnID(t *testing.T) {
	b := newBook(t)
	for i := 0; i < 6; i++ {
		b.MustPost(int64(i+1), "", pair(cash, revenue, 1))
	}
	if got := b.Entries(0, 0); len(got) != 0 {
		t.Fatalf("limit 0 returned %d", len(got))
	}
	if got := b.Entries(0, -1); len(got) != 0 {
		t.Fatalf("negative limit returned %d", len(got))
	}
	page := b.Entries(3, 2)
	if len(page) != 2 || page[0].ID != 3 || page[1].ID != 4 {
		t.Fatalf("Entries(3,2) = %v", page)
	}
	tail := b.Entries(5, 10)
	if len(tail) != 2 || tail[0].ID != 5 {
		t.Fatalf("Entries(5,10) returned %d entries", len(tail))
	}
	if got := b.Entries(99, 5); len(got) != 0 {
		t.Fatalf("Entries past the end returned %d", len(got))
	}
}

func TestIDKeyPadsAndOrders(t *testing.T) {
	if got := idKey(1); got != "00000000000000000001" {
		t.Fatalf("idKey(1) = %q", got)
	}
	if len(idKey(1)) != len(idKey(1234567)) {
		t.Fatal("keys must be fixed width")
	}
	if !(idKey(2) < idKey(10)) {
		t.Fatal("lexical order must match numeric order")
	}
	// The 20-digit claim: math.MaxUint64 is exactly 20 digits, so it is the
	// one input that uses the full width with no padding.
	max := idKey(18446744073709551615)
	if len(max) != 20 || max != "18446744073709551615" {
		t.Fatalf("idKey(maxUint64) = %q", max)
	}
}

func TestEntryTotalCountsDebitsOnly(t *testing.T) {
	e := Entry{Postings: []Posting{
		{Account: cash, Side: Debit, Amount: 30},
		{Account: ar, Side: Debit, Amount: 70},
		{Account: revenue, Side: Credit, Amount: 100},
	}}
	if e.Total() != 100 {
		t.Fatalf("Total = %d, want 100", e.Total())
	}
	if (Entry{}).Total() != 0 {
		t.Fatal("empty entry Total must be 0")
	}
}

func TestAccountBalanceSignByKind(t *testing.T) {
	// A contra position is a real signal, not a sign convention: an asset
	// with more credits than debits reports NEGATIVE.
	a := Account{Kind: Asset, Debits: 10, Credits: 40}
	if a.Balance() != -30 || a.RawDelta() != -30 {
		t.Fatalf("contra asset = %d/%d, want -30/-30", a.Balance(), a.RawDelta())
	}
	l := Account{Kind: Liability, Debits: 10, Credits: 40}
	if l.Balance() != 30 || l.RawDelta() != -30 {
		t.Fatalf("liability = %d/%d, want 30/-30", l.Balance(), l.RawDelta())
	}
	// An invalid kind reports false from IsDebitNormal, so Balance reads it
	// as credit-normal. Asserted rather than left implicit, because a book
	// can never hold one -- Open refuses it.
	bad := Account{Kind: Kind(0), Debits: 10, Credits: 40}
	if bad.Balance() != 30 {
		t.Fatalf("invalid kind Balance = %d, want 30 (credit-normal fallback)", bad.Balance())
	}
}
