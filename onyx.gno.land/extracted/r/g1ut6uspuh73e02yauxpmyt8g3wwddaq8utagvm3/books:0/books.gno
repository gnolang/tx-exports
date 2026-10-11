// Package books is a per-owner general ledger: an address opens a chart of
// accounts and posts balanced double-entry entries against it.
//
// # The one idea
//
// Every other ledger-like realm in this portfolio is SINGLE-PURPOSE and its
// state shape IS its question. invoices tracks receivables. payroll tracks
// accrued wages. budgets tracks allocations. fee_split tracks shares. Each is
// a correct answer to one question and structurally cannot answer a second,
// because there is nowhere to put a transaction that is not already one of
// the modelled kinds.
//
// This realm has no opinion about what the accounts mean. The owner defines
// the chart; the realm enforces that every entry balances, that it cannot be
// altered after the fact, and that only the owner may write it.
//
// # NO CUSTODY — and refusing coins is not the same as not holding them
//
// This realm holds nothing. There is no coinio import, no payable path, no
// fee, no withdrawal, no admin.
//
// So every mutating entrypoint REFUSES a transaction that arrives carrying
// coins. A realm with no withdrawal path that silently accepts ugnot strands
// it permanently, and "we don't hold funds" would then be true of the design
// and false of the balance. Having no custody is not the same as being safe
// to send coins to, and the difference is one guard.
//
// # A BOOK IS A SET OF CLAIMS BY ITS OWNER
//
// Read this before trusting any number this realm returns.
//
// With no custody there is no solvency invariant tying "Cash 5000" to 5000
// real ugnot anywhere. A book can be internally perfect and describe nothing.
// IsBalanced proves arithmetic, never truth.
//
// Consequently this realm exposes NO CROSS-OWNER AGGREGATE. Summing every
// book's debits would be summing every stranger's self-reported assertion,
// and the getter's existence would invite reading it as a signal. What it
// exposes instead is owner-scoped, which is the only question a consumer can
// act on — and a consumer acting on its OWN book is trusting only itself.
//
// # The account code DETERMINES the account kind
//
// An account's code's leading digit fixes its kind, by the standard
// chart-of-accounts convention:
//
//	1xxx -> Asset       2xxx -> Liability   3xxx -> Equity
//	4xxx -> Revenue     5xxx -> Expense
//
// There is no kind parameter. This is deliberate and it is the realm's answer
// to p/journal consumer obligation 7, which exists because of that package's
// audit finding Y1: NO CHECK IN p/journal VALIDATES AN ACCOUNT'S KIND. An
// account opened Asset that should have been Liability reports a sign-flipped
// Balance() forever while IsBalanced, RederiveFromJournal and
// AccountingEquation all three stay healthy — every one of them is built on
// Debits and Credits, which the kind does not touch.
//
// Deriving the kind does not eliminate that hazard. It MOVES it: after the
// derivation the kind cannot disagree with the code, so the unauditable
// question "is this kind right?" becomes the visible question "is this code
// right?", which any reader of the chart can check against the convention
// above. That is the whole claim and it is deliberately not stated as more.
//
// The cost is a mandatory numbering convention: a code whose first character
// is not 1-5 is refused. For a realm whose purpose is auditable books, that
// is the feature.
//
// # Entries are append-only and are corrected by REVERSAL
//
// There is no edit and no delete. A wrong entry is corrected by posting its
// mirror image, which leaves both the error and the correction readable. Each
// entry may be reversed at most once; a reversal is itself an entry and is
// itself reversible once.
//
// # Periods
//
// An owner may seal everything up to a height with CloseThrough, after which
// no entry may be dated at or before it. The seal only moves forward. This is
// the owner's own discipline, not a protocol rule — nothing forces an owner to
// close anything.
//
// # The clock is the chain's
//
// Entries are dated with runtime.ChainHeight() and never with a caller-
// supplied value, satisfying p/journal obligations 2 and 3. Heights
// throughout, never seconds. A realm that let a caller choose the date would
// have no period discipline at all.
//
// # Caps, and why they are far below the engine's
//
// p/journal permits 10 000 accounts and 1 000 000 entries. Its AUDIT.md names
// the gas ceiling on RederiveFromJournal at full cap — a worst case of 64M
// posting visits in one call — as UNMEASURED and does not claim it. So this
// realm sets its own caps far below, and exposes Rederive as an explicit
// owner-callable rather than running it inside a getter where another party
// would pay for it.
//
// The caps are per-owner, never global. A global cap on books would be a
// griefing vector: one address could fill it and lock everyone else out.
// Per-owner, an owner can exhaust their own capacity and nobody else's, and
// the cost of doing so is gas plus a storage deposit per record.
//
// # Realms may keep books too, for free
//
// The owner is cur.Previous().Address(), so a realm that calls in keeps books
// under its own address with no extra authorization code. That is the
// realm-to-realm integration surface, and it arrived as a property of the
// owner-only rule rather than as a feature.
//
// # What this realm does NOT do
//
//   - It does not hold, move, or price any asset.
//   - It does not verify that an entry describes a real event.
//   - It does not validate that the right transaction went in the right
//     account. The derived kind makes the CODE auditable, not the judgement.
//   - It has no admin. The deploying namespace has no privilege here at all:
//     no setter, no pause, no ability to post, reverse, or read anything a
//     stranger cannot read.
package books

import (
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"strings"

	"gno.land/p/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/journal"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/markdown/sanitize/v0"
)

// RealmPath is this realm's own path, used to build Render links.
const RealmPath = "/r/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/books"

// MaxAccountsPerBook caps one owner's chart. Far below journal's
// MaxAccountsLimit of 10000: IsBalanced sums the whole chart, and this bound
// is what keeps that read cheap for everyone.
const MaxAccountsPerBook = 128

// MaxEntriesPerBook caps one owner's journal. Far below journal's
// MaxEntriesLimit of 1000000, because that limit's interaction with
// RederiveFromJournal is unmeasured — see the package doc.
//
// A book that fills up refuses further entries rather than dropping history.
// The remedy is a fresh book with opening balances carried forward; there is
// deliberately no Archive, because it would destroy history and needs more
// design than it has had.
const MaxEntriesPerBook = 4096

// MaxLegsPerEntry caps one entry's postings. journal permits 64; this is
// lower because an entry is parsed from a single string argument and rendered
// in full, and both of those costs are linear in the leg count.
const MaxLegsPerEntry = 16

// MaxCodeLen and MaxNameLen bound an account's identifiers. Both are at or
// below journal's own limits, so the engine's validation is a backstop here
// rather than the only check.
const (
	MaxCodeLen = 16
	MaxNameLen = 128
)

// MaxMemoLen bounds an entry's free text. Below journal's MaxMemoLen of 1024
// because every memo is a candidate for Render output.
const MaxMemoLen = 256

// RenderEntryLimit caps how many entries one Render call emits. A book may
// hold MaxEntriesPerBook of them and rendering all of them would make the
// page cost grow without bound.
const RenderEntryLimit = 25

// books maps an owner's address string to that owner's *journal.Book.
//
// The value is a POINTER and is never returned by any exported function —
// journal consumer obligation 4: a *Book is a mutable handle, and handing one
// across a realm boundary would hand out the right to post and reverse.
var books = avl.NewTree()

// openedAt records the height each book was created, for Render.
var openedAt = avl.NewTree()

// bookCount is maintained alongside the tree so the index page never has to
// iterate it.
var bookCount int

// ---------------------------------------------------------------------------
// Guards
// ---------------------------------------------------------------------------

// refuseCoins panics if a user call arrives carrying coins.
//
// This realm has no withdrawal path, so accepted coins would be stranded
// permanently. The guard is on IsUserCall rather than IsUser deliberately:
// OriginSend is only meaningful for a direct MsgCall, and the MsgRun
// ephemeral can consume the envelope before forwarding control, so IsUser
// would be the wrong predicate. See p/journal's audit note and security.md.
func refuseCoins(cur realm) {
	// A no-op at every one of today's call sites: each is a crossing entrypoint
	// forwarding its OWN first cur, which is runtime-current by construction
	// and stays current through a non-crossing call. It is here because this
	// realm is IMMUTABLE after addpkg, so a call site added later cannot be
	// made safe later — and a helper that reads Previous() off an unchecked
	// realm parameter is a designation-forgery shape (security.md Class 2)
	// whether or not it is reachable today.
	//
	// No count of the call sites is written here, per CLAUDE.md § 4a: the
	// number is the one thing about this comment that an edit elsewhere in the
	// file can falsify.
	if !cur.IsCurrent() {
		panic("books: refuseCoins called with a realm that is not current")
	}
	if cur.Previous().IsUserCall() && len(unsafe.OriginSend()) > 0 {
		panic("books: this realm holds no coins and has no withdrawal path; send none")
	}
}

// ---------------------------------------------------------------------------
// Account kinds, derived from the code
// ---------------------------------------------------------------------------

// kindFromCode maps a code's leading digit to its account kind. The second
// result is false for any code that does not begin 1-5.
//
// This is the whole of the realm's answer to journal obligation 7. See the
// package doc for what it does and does not buy.
func kindFromCode(code string) (journal.Kind, bool) {
	if code == "" {
		return 0, false
	}
	switch code[0] {
	case '1':
		return journal.Asset, true
	case '2':
		return journal.Liability, true
	case '3':
		return journal.Equity, true
	case '4':
		return journal.Revenue, true
	case '5':
		return journal.Expense, true
	}
	return 0, false
}

// KindOf reports the kind a code would be given, without opening anything.
// A consumer can call this before OpenAccount to check its own numbering.
func KindOf(code string) string {
	k, ok := kindFromCode(code)
	if !ok {
		return "invalid"
	}
	return k.String()
}

// ---------------------------------------------------------------------------
// Writes
// ---------------------------------------------------------------------------

// OpenBook creates the caller's book. It panics if the caller already has one.
//
// Separating this from OpenAccount is deliberate: creating a book is the call
// that pays the storage deposit for the owner's record, and a caller should
// see that cost on its own rather than hidden inside their first account.
func OpenBook(cur realm) {
	refuseCoins(cur)
	owner := cur.Previous().Address()
	key := owner.String()
	if books.Has(key) {
		panic("books: this address already has a book")
	}
	b := journal.MustNew(MaxAccountsPerBook, MaxEntriesPerBook)
	books.Set(key, b)
	openedAt.Set(key, runtime.ChainHeight())
	bookCount++
}

// OpenAccount adds an account to the caller's book. The KIND IS DERIVED from
// the code's leading digit; there is no kind parameter. See the package doc.
func OpenAccount(cur realm, code, name string) {
	refuseCoins(cur)
	b := mustOwnBook(cur)

	if code == "" {
		panic("books: account code must not be empty")
	}
	if len(code) > MaxCodeLen {
		panic("books: account code too long, max " + strconv.Itoa(MaxCodeLen))
	}
	if len(name) > MaxNameLen {
		panic("books: account name too long, max " + strconv.Itoa(MaxNameLen))
	}
	kind, ok := kindFromCode(code)
	if !ok {
		panic("books: account code must begin 1-5 (1 asset, 2 liability, " +
			"3 equity, 4 revenue, 5 expense); got " + code)
	}
	// journal validates length, duplication and the chart cap itself; its
	// error is returned rather than swallowed so the caller sees which bound
	// they hit.
	if err := b.Open(code, name, kind); err != nil {
		panic("books: " + err.Error())
	}
}

// PostSimple posts the two-leg entry that is the overwhelmingly common case:
// debit one account, credit another, for the same amount.
//
// It exists beside PostMulti because the two-leg form cannot be mis-encoded.
// A caller who wants one debit and one credit should never have to get a leg
// specification's syntax right.
func PostSimple(cur realm, debitCode, creditCode string, amount int64, memo string) uint64 {
	refuseCoins(cur)
	b := mustOwnBook(cur)
	checkMemo(memo)
	if amount <= 0 {
		panic("books: amount must be positive")
	}
	if debitCode == creditCode {
		// journal would accept this and fold both legs, netting to zero
		// against one account. It is always a caller mistake, so it is
		// refused here rather than recorded as a no-op entry.
		panic("books: debit and credit accounts must differ")
	}
	postings := []journal.Posting{
		{Account: debitCode, Side: journal.Debit, Amount: amount},
		{Account: creditCode, Side: journal.Credit, Amount: amount},
	}
	id, err := b.Post(runtime.ChainHeight(), memo, postings)
	if err != nil {
		panic("books: " + err.Error())
	}
	return id
}

// PostMulti posts an entry of up to MaxLegsPerEntry legs, specified as a
// comma-separated list of colon-separated triples:
//
//	"1000:D:500,4000:C:300,4100:C:200"
//
// Side is D or C, case-insensitive. Amounts are positive integers in the
// owner's chosen unit. The string form is used because a crossing function
// cannot usefully take a slice over MsgCall; treasury_board encodes a list
// the same way.
//
// Debits must equal credits, and journal names which side is short.
//
// A leg may name an account another leg already named — journal folds them,
// and "1000:D:500,1000:C:200,4000:C:300" is a legitimate net +300 to 1000.
// What is refused is an entry in which EVERY leg names the same account: it
// balances only by netting to exactly zero, so it is the PostSimple mistake
// wearing the multi-leg syntax. The narrow rule is deliberate — a blanket
// "no repeated account" would reject the legitimate fold above.
func PostMulti(cur realm, legs, memo string) uint64 {
	refuseCoins(cur)
	b := mustOwnBook(cur)
	checkMemo(memo)
	postings := parseLegs(legs)
	if allOneAccount(postings) {
		panic("books: every leg names " + postings[0].Account +
			"; such an entry can only net to zero")
	}
	id, err := b.Post(runtime.ChainHeight(), memo, postings)
	if err != nil {
		panic("books: " + err.Error())
	}
	return id
}

// Reverse posts the mirror image of an existing entry in the caller's book,
// dated now. The original is left exactly as it was: this is a correction,
// not an edit.
//
// An entry may be reversed at most once. The reversal is itself an entry and
// may itself be reversed once.
func Reverse(cur realm, id uint64, memo string) uint64 {
	refuseCoins(cur)
	b := mustOwnBook(cur)
	checkMemo(memo)
	newID, err := b.Reverse(id, runtime.ChainHeight(), memo)
	if err != nil {
		panic("books: " + err.Error())
	}
	return newID
}

// CloseThrough seals the caller's book up to and including a height: no entry
// may afterwards be dated at or before it. The seal only ever moves forward.
//
// Passing a height at or beyond the current one seals the present and makes
// the book immediately unpostable until the chain advances past it. That is
// permitted — it is the owner's own book — and it is called out because it is
// the one way to brick a book without filling it.
func CloseThrough(cur realm, through int64) {
	refuseCoins(cur)
	b := mustOwnBook(cur)
	if err := b.Close(through); err != nil {
		panic("books: " + err.Error())
	}
}

// Rederive runs journal's STRONG invariant check over the caller's own book:
// it replays every posting of every entry and compares the result against
// both accumulators.
//
// It is a crossing function rather than a getter on purpose. The check is
// O(all postings ever) and the owner is the party who should pay for it —
// exposing it as a free read would let anyone make an owner's book expensive
// to query. IsBalanced is the cheap check and is a free read.
//
// Returns the replayed totals and whether they agree.
func Rederive(cur realm) (debits, credits int64, agrees bool) {
	refuseCoins(cur)
	b := mustOwnBook(cur)
	return b.RederiveFromJournal()
}

// ---------------------------------------------------------------------------
// Internals
// ---------------------------------------------------------------------------

// mustOwnBook returns the CALLER'S book, and there is no variant that returns
// anyone else's.
//
// Authorization is structural rather than a check: the owner is derived from
// cur.Previous().Address() and no mutating function takes an owner parameter,
// so there is no address for a caller to forge. journal obligation 5.
//
// "No address to forge" is true of the SIGNATURE and was never true of the
// realm VALUE, which is the second half of the same Class 2 shape refuseCoins
// carries above — and the more consequential half, because this is the
// function that decides who owns the book rather than one that only refuses
// coins. The guard is a no-op today for the same reason as refuseCoins's:
// every call site forwards a crossing entrypoint's own first cur. It is kept
// for the same reason too, and its call-site count is likewise not written
// down. See AUDIT.md § O.
func mustOwnBook(cur realm) *journal.Book {
	if !cur.IsCurrent() {
		panic("books: mustOwnBook called with a realm that is not current")
	}
	owner := cur.Previous().Address()
	b, ok := books.Get(owner.String()).(*journal.Book)
	if !ok {
		panic("books: no book for this address; call OpenBook first")
	}
	return b
}

// book returns an owner's book for READ-ONLY use by the getters below.
//
// The pointer never leaves this file: every exported getter copies scalars or
// journal's by-value Account/Entry out of it. Obligation 4.
//
// avl.Tree.Get returns ONE value, not (any, bool): it cannot distinguish a
// nil-valued key from an absent one, which is the same trap journal's
// `reversed` field comment names from the other side. The two-value TYPE
// ASSERTION is what carries the existence answer here, in one traversal —
// `ok` is false for an absent key and for a present-but-wrong-typed value
// alike, and the second is impossible because only this file ever Sets.
// Do not "fix" this into Has-then-Get: that is two traversals for the same
// answer, and a reader would then owe themselves a proof that nothing can
// change between them.
func book(owner address) (*journal.Book, bool) {
	b, ok := books.Get(owner.String()).(*journal.Book)
	if !ok {
		return nil, false
	}
	return b, true
}

func mustBook(owner address) *journal.Book {
	b, ok := book(owner)
	if !ok {
		panic("books: no book for " + owner.String())
	}
	return b
}

// allOneAccount reports whether every posting names the same account.
//
// parseLegs has already refused a list shorter than two, so this is never
// asked of a single-element slice and the loop below always compares.
func allOneAccount(postings []journal.Posting) bool {
	for _, p := range postings[1:] {
		if p.Account != postings[0].Account {
			return false
		}
	}
	return true
}

func checkMemo(memo string) {
	if len(memo) > MaxMemoLen {
		panic("books: memo too long, max " + strconv.Itoa(MaxMemoLen))
	}
}

// parseLegs decodes the "code:side:amount,..." form of PostMulti.
//
// Every failure is a panic naming the offending leg by its 1-based position,
// because a caller who mistyped one triple in a list of eight needs to know
// which one. A silently-dropped leg would produce an unbalanced entry and the
// error would surface as "debits do not equal credits", which points at the
// wrong thing.
func parseLegs(legs string) []journal.Posting {
	if strings.TrimSpace(legs) == "" {
		panic("books: no legs given; format is \"1000:D:500,4000:C:500\"")
	}
	parts := strings.Split(legs, ",")
	if len(parts) < 2 {
		panic("books: an entry needs at least two legs")
	}
	if len(parts) > MaxLegsPerEntry {
		panic("books: too many legs, max " + strconv.Itoa(MaxLegsPerEntry))
	}
	out := make([]journal.Posting, 0, len(parts))
	for i, raw := range parts {
		at := " at leg " + strconv.Itoa(i+1)
		f := strings.Split(strings.TrimSpace(raw), ":")
		if len(f) != 3 {
			panic("books: expected code:side:amount" + at)
		}
		code := strings.TrimSpace(f[0])
		if code == "" {
			panic("books: empty account code" + at)
		}
		var side journal.Side
		switch strings.ToUpper(strings.TrimSpace(f[1])) {
		case "D", "DR", "DEBIT":
			side = journal.Debit
		case "C", "CR", "CREDIT":
			side = journal.Credit
		default:
			panic("books: side must be D or C" + at)
		}
		amount, err := strconv.ParseInt(strings.TrimSpace(f[2]), 10, 64)
		if err != nil {
			panic("books: amount is not an integer" + at)
		}
		if amount <= 0 {
			panic("books: amount must be positive" + at)
		}
		out = append(out, journal.Posting{Account: code, Side: side, Amount: amount})
	}
	return out
}

// ---------------------------------------------------------------------------
// Reads — all owner-scoped, by §4.2 of DISCOVERY.md
// ---------------------------------------------------------------------------

// HasBook reports whether an address has opened a book.
func HasBook(owner address) bool { return books.Has(owner.String()) }

// Books is the number of books that exist. It is a count and nothing more:
// there is deliberately no way to enumerate them or aggregate across them.
func Books() int { return bookCount }

// OpenedAt is the height an owner's book was created.
func OpenedAt(owner address) int64 {
	h, ok := openedAt.Get(owner.String()).(int64)
	if !ok {
		panic("books: no book for " + owner.String())
	}
	return h
}

// Balance returns an account's balance in its NORMAL direction: positive
// means a debit balance for an asset or expense, and a credit balance for a
// liability, equity or revenue account.
//
// The second result distinguishes "no such account" from "zero".
func Balance(owner address, code string) (int64, bool) {
	b, ok := book(owner)
	if !ok {
		return 0, false
	}
	return b.Balance(code)
}

// RawBalance returns an account's debits minus credits, without the normal-
// direction sign convention. Exposed because a consumer reconciling against
// an external system usually wants the raw figure.
func RawBalance(owner address, code string) (int64, bool) {
	b, ok := book(owner)
	if !ok {
		return 0, false
	}
	a, found := b.Account(code)
	if !found {
		return 0, false
	}
	return a.RawDelta(), true
}

// AccountInfo returns an account's full state. journal returns Account BY
// VALUE, so this hands out a copy and no pointer into stored state.
func AccountInfo(owner address, code string) (name, kind string, debits, credits, balance int64) {
	a, ok := mustBook(owner).Account(code)
	if !ok {
		panic("books: no account " + code + " for " + owner.String())
	}
	return a.Name, a.Kind.String(), a.Debits, a.Credits, a.Balance()
}

// HasAccount reports whether an owner's chart contains a code.
func HasAccount(owner address, code string) bool {
	b, ok := book(owner)
	if !ok {
		return false
	}
	_, found := b.Account(code)
	return found
}

// Accounts is the number of accounts in an owner's chart.
func Accounts(owner address) int { return mustBook(owner).AccountCount() }

// Codes lists an owner's account codes in ascending code order, beginning at
// from INCLUSIVE and returning at most limit of them. A limit <= 0 returns
// nothing; a limit above the chart cap is clamped to it. Page by passing the
// last code received back as from, which re-reads that one code.
//
// # Why this exists, and why a counter was not enough
//
// Accounts above returns HOW MANY accounts a chart holds, and AccountInfo
// answers for a code the caller already knows. Neither lets a caller DISCOVER
// a code. Without this, a trial balance, a balance sheet and an income
// statement are all unbuildable from outside this realm however many times
// the chart is interrogated — a consumer could only report on accounts it had
// independently been told about, which for a chart the OWNER defines is no
// guarantee at all.
//
// # Why not simply export journal's iterator
//
// journal.Book has IterateAccounts(fn func(Account) bool), and exporting a
// realm entrypoint that takes fn from the caller would be the shortest code
// here and a security defect. A caller-supplied callback is the "callback
// params" class, and journal's own doc records the sharp edge: fn runs under
// the CALLING REALM'S STORAGE AUTHORITY, because the receiver is stamped with
// this realm's PkgID and a top-level fn has no declaring realm to anchor it
// elsewhere. A hostile fn would execute holding r/books' own authority.
//
// So the iterator stays internal and this returns VALUES. The closure below
// is written by this realm, appends to a local slice, and re-enters no
// mutator — which is exactly the condition journal's doc attaches to it.
//
// Codes is a free read and NOT a crossing function, so an owner does not pay
// for a consumer's paging. The cost ceiling is the chart cap: the underlying
// iterator has no seek, so `from` is honoured by skipping, and one call walks
// the whole chart however small limit is. A caller paging a 128-account chart
// 8 codes at a time therefore does 16 full walks, not one. That is a
// deliberate trade for not touching p/journal, whose Codes-with-seek would
// have re-opened Gate A and the sabotage sweeps for all three of its
// importers.
func Codes(owner address, from string, limit int) []string {
	b := mustBook(owner)
	if limit <= 0 {
		return nil
	}
	if limit > MaxAccountsPerBook {
		limit = MaxAccountsPerBook
	}
	out := make([]string, 0, limit)
	b.IterateAccounts(func(a journal.Account) bool {
		if a.Code < from {
			return false
		}
		out = append(out, a.Code)
		return len(out) >= limit
	})
	return out
}

// EntryCount is the number of entries in an owner's journal.
func EntryCount(owner address) int { return mustBook(owner).EntryCount() }

// EntryInfo returns one entry's header. Postings are returned separately by
// EntryLegs, because an entry's leg count is variable and a crossing-function
// return cannot carry a slice usefully.
func EntryInfo(owner address, id uint64) (at int64, memo string, legs int, reversalOf uint64, total int64) {
	e, ok := mustBook(owner).Entry(id)
	if !ok {
		panic("books: no entry " + strconv.FormatUint(id, 10))
	}
	return e.At, e.Memo, len(e.Postings), e.ReversalOf, e.Total()
}

// EntryLegs returns one entry's postings in the "code:side:amount,..." form
// PostMulti accepts, so an entry can be read and re-posted without a
// separate encoding.
func EntryLegs(owner address, id uint64) string {
	e, ok := mustBook(owner).Entry(id)
	if !ok {
		panic("books: no entry " + strconv.FormatUint(id, 10))
	}
	var sb strings.Builder
	for i, p := range e.Postings {
		if i > 0 {
			sb.WriteString(",")
		}
		sb.WriteString(p.Account)
		if p.Side == journal.Debit {
			sb.WriteString(":D:")
		} else {
			sb.WriteString(":C:")
		}
		sb.WriteString(strconv.FormatInt(p.Amount, 10))
	}
	return sb.String()
}

// IsReversed reports whether an entry has already been reversed. An entry may
// be reversed at most once, so this is also "may this still be reversed".
func IsReversed(owner address, id uint64) bool {
	return mustBook(owner).IsReversed(id)
}

// Totals returns an owner's running debit and credit totals.
func Totals(owner address) (debits, credits int64) {
	b := mustBook(owner)
	return b.TotalDebits(), b.TotalCredits()
}

// IsBalanced is the CHEAP invariant and this realm's live-verification probe.
//
// It compares two independently-maintained accumulators: the per-account
// totals summed across the chart, against the book's own running totals.
// They are written by different code paths, so a drift between them is a real
// defect and this finds it.
//
// What it does NOT do is re-read the journal, so a defect that corrupted both
// accumulators identically would survive it. That is Rederive's job, and
// Rederive is a crossing function because the owner should pay for it.
//
// And the ceiling on both: this proves the book is self-consistent, never
// that its entries describe real events. See the package doc.
func IsBalanced(owner address) bool { return mustBook(owner).IsBalanced() }

// Equation partitions an owner's chart BY ACCOUNT KIND: the summed raw delta
// of every debit-normal account (Asset, Expense), the same for every
// credit-normal one (Liability, Equity, Revenue), and whether the two offset.
//
// The two FIGURES are why this exists. They are the balance-sheet and
// income-statement partition of the chart, and no other accessor on this
// realm exposes it — Totals sums debits and credits without regard to kind,
// and AccountInfo answers one code at a time.
//
// # `offsets` IS A VACUOUS TRUE ON THIS REALM — do not quote it as a check
//
// Read this before using the third result for anything.
//
// The kind partition is TOTAL: journal's Kind is 1..5, IsDebitNormal is
// `k == Asset || k == Expense`, so every account lands in exactly one of the
// two sums and neither can omit one. Therefore
//
//	debitNormal + creditNormal  ==  sum of RawDelta over ALL accounts
//	                            ==  totalDebits - totalCredits
//
// and this realm refuses an entry that does not balance, so that difference
// is always zero. `offsets` is consequently TRUE for every book this realm
// can produce, and it is true for a chart whose accounts are classified
// nonsensically just as readily as for a correct one.
//
// This is the `HasValidSignature` shape §7b already names: a predicate that
// is a constant under current conditions, and so is evidence of nothing. The
// suite pins the vacuity deliberately rather than asserting true and reading
// green — a test that cannot fail is the thing that makes this dangerous.
//
// What `offsets` DOES still distinguish is arithmetic overflow, where journal
// returns (0, 0, false). So the honest reading is **"the two sums are
// trustworthy"**, never "the classification is right". A consumer wanting a
// genuine classification check must compare the kinds against its own
// expectation, which is the statement consumer's job and not this realm's.
//
// Both figures are RAW deltas (debits - credits), not normalised balances, so
// a debit-normal total is normally positive and a credit-normal total normally
// negative. A credit-normal account carrying a positive raw delta is a contra
// account, which is legitimate, and is why neither figure is forced
// non-negative.
func Equation(owner address) (debitNormal, creditNormal int64, offsets bool) {
	return mustBook(owner).AccountingEquation()
}

// ClosedThrough returns the height an owner's book is sealed to, and whether
// it has ever been closed. The second result matters: a book closed through
// height 0 is not the same as a book that has never been closed.
func ClosedThrough(owner address) (int64, bool) {
	return mustBook(owner).ClosedThrough()
}

// Capacity returns an owner's remaining headroom, so a consumer can see a
// full book coming rather than discovering it on a refused entry.
func Capacity(owner address) (accountsLeft, entriesLeft int) {
	b := mustBook(owner)
	return MaxAccountsPerBook - b.AccountCount(), MaxEntriesPerBook - b.EntryCount()
}

// Height is the chain height this realm dates entries with. Exposed so a
// caller can predict what CloseThrough will seal.
func Height() int64 { return runtime.ChainHeight() }

// ---------------------------------------------------------------------------
// Render
// ---------------------------------------------------------------------------

// Render serves the index at "" and one owner's book at "<address>".
//
// Every caller-supplied string — account names and entry memos — goes through
// the ecosystem sanitizer. Free text reaching Render unescaped is the one
// injection-shaped surface a realm with no custody still has.
func Render(path string) string {
	p := strings.TrimSpace(strings.Trim(path, "/"))
	if p == "" {
		return renderIndex()
	}
	return renderBook(address(p))
}

func renderIndex() string {
	var sb strings.Builder
	sb.WriteString("# books — a per-owner general ledger\n\n")
	sb.WriteString("Double-entry books. Append-only, corrected by reversal, ")
	sb.WriteString("and **no custody of any asset**.\n\n")

	sb.WriteString("> A book is a set of claims by its owner. With no custody ")
	sb.WriteString("there is no solvency invariant tying a balance to a real ")
	sb.WriteString("holding — a book can be internally perfect and describe ")
	sb.WriteString("nothing. The invariants here prove arithmetic, not truth.\n\n")

	sb.WriteString("## State\n\n")
	sb.WriteString("- books opened: **" + strconv.Itoa(bookCount) + "**\n")
	sb.WriteString("- chain height: **" + strconv.FormatInt(runtime.ChainHeight(), 10) + "**\n\n")
	sb.WriteString("There is deliberately no way to enumerate books or to ")
	sb.WriteString("aggregate across them: such a total would be the sum of ")
	sb.WriteString("every stranger's self-reported assertion.\n\n")

	sb.WriteString("## The chart-of-accounts convention\n\n")
	sb.WriteString("An account's **code determines its kind** — there is no kind ")
	sb.WriteString("parameter:\n\n")
	sb.WriteString("| code | kind | normal balance |\n")
	sb.WriteString("|---|---|---|\n")
	sb.WriteString("| `1xxx` | asset | debit |\n")
	sb.WriteString("| `2xxx` | liability | credit |\n")
	sb.WriteString("| `3xxx` | equity | credit |\n")
	sb.WriteString("| `4xxx` | revenue | credit |\n")
	sb.WriteString("| `5xxx` | expense | debit |\n\n")

	sb.WriteString("## Caps, per owner\n\n")
	sb.WriteString("| bound | value |\n|---|---|\n")
	sb.WriteString("| accounts per book | " + strconv.Itoa(MaxAccountsPerBook) + " |\n")
	sb.WriteString("| entries per book | " + strconv.Itoa(MaxEntriesPerBook) + " |\n")
	sb.WriteString("| legs per entry | " + strconv.Itoa(MaxLegsPerEntry) + " |\n\n")

	sb.WriteString("## Usage\n\n")
	sb.WriteString("```\nOpenBook()\nOpenAccount(\"1000\", \"Cash\")\n")
	sb.WriteString("OpenAccount(\"4000\", \"Sales\")\n")
	sb.WriteString("PostSimple(\"1000\", \"4000\", 5000, \"invoice 17 settled\")\n")
	sb.WriteString("PostMulti(\"1000:D:500,4000:C:300,4100:C:200\", \"split sale\")\n```\n\n")
	sb.WriteString("View a book at `" + RealmPath + ":<address>`.\n")
	return sb.String()
}

// cell prepares caller-supplied text for a GFM table cell, truncating it for
// display first. It is the `invoices` helper of the same name, adopted verbatim
// rather than re-derived, because the two realms face the identical slot.
//
// TableCell rather than InlineText, and the SLOT is the reason: these bytes
// land between two `|` delimiters, and an unescaped `|` opens a new column and
// shifts every column to its right. InlineText does not escape the pipe —
// deliberately, per the sanitizer's own doc, so that TableCell can escape it
// without double-escaping. Measured on onyx-1 with chain_id_bound: true:
//
//	InlineText("Cash | **forged** | x") -> `Cash | \*\*forged\*\* | x`   pipes LIVE
//	TableCell ("Cash | **forged** | x") -> `Cash \| \*\*forged\*\* \| x`  escaped
//
// This realm shipped InlineText here first and an adversarial audit found it.
// An owner could forge columns in their own book's chart or journal — and the
// victim is a THIRD PARTY reading that book, which attacks the one thing this
// realm exists to provide. The account CODE needs this as much as the name
// does: a GFM row is split before inline parsing runs, so a `|` inside the
// backtick span at the code column is not protected by the backticks, and
// kindFromCode constrains only code[0].
//
// Applied to caller-supplied text only. `Kind.String()` and the `note` column
// are realm-constructed from an enum and a uint64, so sanitizing them would be
// noise rather than slot-matching — unlike `invoices`, which passes a bech32
// address through this helper precisely because that value IS caller-derived.
//
// TRUNCATE BEFORE ESCAPING, and on a RUNE boundary. Escaping first and cutting
// afterwards can slice a `\|` in half and leave the cell ending in a bare
// backslash; cutting on a byte boundary can split a multi-byte rune and emit
// invalid UTF-8. By the time the sanitizer sees the string the damage is
// upstream of it, so neither is something it is asked to repair.
func cell(s string) string {
	const maxRunes = 48
	if r := []rune(s); len(r) > maxRunes {
		s = string(r[:maxRunes]) + "…"
	}
	return sanitize.TableCell(s)
}

func renderBook(owner address) string {
	b, ok := book(owner)
	if !ok {
		return "# books\n\nNo book for `" +
			sanitize.InlineText(owner.String()) + "`.\n"
	}

	var sb strings.Builder
	sb.WriteString("# Book of " + sanitize.InlineText(owner.String()) + "\n\n")

	// Invariant first, with its ceiling stated beside it rather than below.
	if b.IsBalanced() {
		sb.WriteString("**IsBalanced: true** — the per-account totals agree ")
		sb.WriteString("with the running totals. This is arithmetic ")
		sb.WriteString("self-consistency and says nothing about whether the ")
		sb.WriteString("entries describe real events.\n\n")
	} else {
		sb.WriteString("**IsBalanced: FALSE** — the accumulators have drifted. ")
		sb.WriteString("This is a defect; do not rely on any figure below.\n\n")
	}

	d, c := b.TotalDebits(), b.TotalCredits()
	sb.WriteString("| | |\n|---|---|\n")
	sb.WriteString("| total debits | " + strconv.FormatInt(d, 10) + " |\n")
	sb.WriteString("| total credits | " + strconv.FormatInt(c, 10) + " |\n")
	sb.WriteString("| accounts | " + strconv.Itoa(b.AccountCount()) + " / " +
		strconv.Itoa(MaxAccountsPerBook) + " |\n")
	sb.WriteString("| entries | " + strconv.Itoa(b.EntryCount()) + " / " +
		strconv.Itoa(MaxEntriesPerBook) + " |\n")
	if through, has := b.ClosedThrough(); has {
		sb.WriteString("| closed through | height " +
			strconv.FormatInt(through, 10) + " |\n")
	} else {
		sb.WriteString("| closed through | never closed |\n")
	}
	sb.WriteString("\n")

	// Chart of accounts, in ascending code order — avl, so deterministic.
	sb.WriteString("## Chart of accounts\n\n")
	if b.AccountCount() == 0 {
		sb.WriteString("_No accounts yet._\n\n")
	} else {
		sb.WriteString("| code | name | kind | debits | credits | balance |\n")
		sb.WriteString("|---|---|---|---|---|---|\n")
		b.IterateAccounts(func(a journal.Account) bool {
			sb.WriteString("| `" + cell(a.Code) + "` | " +
				cell(a.Name) + " | " + a.Kind.String() + " | " +
				strconv.FormatInt(a.Debits, 10) + " | " +
				strconv.FormatInt(a.Credits, 10) + " | " +
				strconv.FormatInt(a.Balance(), 10) + " |\n")
			return false
		})
		sb.WriteString("\nBalances are in each account's **normal direction**.\n\n")
	}

	// The most recent entries, newest first, bounded.
	sb.WriteString("## Journal\n\n")
	total := b.EntryCount()
	if total == 0 {
		sb.WriteString("_No entries yet._\n")
		return sb.String()
	}
	shown := total
	if shown > RenderEntryLimit {
		shown = RenderEntryLimit
	}
	// Entries are ids 1..nextID-1 and none are ever removed, so the newest
	// `shown` of them start at total-shown+1.
	from := uint64(total-shown) + 1
	recent := b.Entries(from, shown)

	sb.WriteString("| id | height | memo | legs | total | note |\n")
	sb.WriteString("|---|---|---|---|---|---|\n")
	for i := len(recent) - 1; i >= 0; i-- {
		e := recent[i]
		note := ""
		if e.IsReversal() {
			note = "reverses #" + strconv.FormatUint(e.ReversalOf, 10)
		} else if b.IsReversed(e.ID) {
			note = "reversed"
		}
		memo := cell(e.Memo)
		if memo == "" {
			memo = "_none_"
		}
		sb.WriteString("| " + strconv.FormatUint(e.ID, 10) + " | " +
			strconv.FormatInt(e.At, 10) + " | " + memo + " | " +
			strconv.Itoa(len(e.Postings)) + " | " +
			strconv.FormatInt(e.Total(), 10) + " | " + note + " |\n")
	}
	if total > shown {
		sb.WriteString("\n_Showing the " + strconv.Itoa(shown) + " most recent of " +
			strconv.Itoa(total) + " entries._\n")
	}
	sb.WriteString("\nEntries are append-only. A wrong entry is corrected by ")
	sb.WriteString("posting its reversal, which leaves both readable.\n")
	return sb.String()
}
