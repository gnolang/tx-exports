// Package statements publishes classified financial statements over a chart
// of accounts this realm does not own, cannot write, and did not supply.
//
// # A PUBLISHED STATEMENT IS A CLAIM ABOUT A CLAIM
//
// Read this before trusting any figure this realm returns, and read it before
// publishing anything here.
//
// [r/books] says of itself, correctly: *"a book is a set of claims by its
// owner"*. It holds no asset, so nothing ties an account reading `Cash 5000`
// to 5000 real ugnot anywhere. A statement derived from such a book inherits
// that completely — and then **adds a layer of apparent authority**, because
// a balance sheet at a stable on-chain path, stamped with a height and a
// sequence number, looks like an audited artifact. It is a self-report of a
// self-report.
//
// This realm performs no audit, verifies no event, and holds no custody. What
// it guarantees is narrow and exact: the figures below are **derived** from
// the owner's chart at a height, by code nobody can parameterise, and frozen.
// That the chart describes anything real is not claimed here and is not
// checkable from here.
//
// # Derived, not supplied — which is the whole reason this realm exists
//
// Every figure comes from [r/books] through its own read surface. A publisher
// says *when to freeze*; they do not say what the statement says. The
// alternative design — the publisher passes the rows in — was considered in
// DISCOVERY.md § 4 and is fatal to the thesis: a statement whose inputs its
// publisher typed is an assertion about nothing, and this realm would be a
// pure function with a storage bill.
//
// The consequence is that **this is the first first-party realm-to-realm
// import in this portfolio, and it is permanent.** Bytes are immutable after
// addpkg, so these statements read the [r/books] at [BooksPath] forever. If
// that realm ever gets a v2, published statements keep reading v1 — arguably
// correct for an auditable artifact, and still a coupling nothing here has
// carried before.
//
// # What is published and what is not
//
// [Publish] freezes the three figures a balance sheet needs, the three an
// income statement needs, and the abnormality census. It does NOT freeze the
// chart: account names, codes and the postings behind them stay in [r/books],
// which keeps writing them.
//
// So [Verify] answers **"do the frozen figures still hold?"** and NOT **"is
// the chart untouched?"**. The two differ and the difference is demonstrable:
// a posting that moves 100 from one asset account to another leaves Assets,
// Claims, the net and the row count all identical, and [Verify] still reads
// true. It is a reconciliation, not a seal. The seal on the chart's own
// history is [r/books]' append-only journal, and that is where to look.
//
// # The income statement is cumulative since inception
//
// [p/journal]'s Close is a backdating seal: it refuses entries dated at or
// before a cutoff and sweeps no nominal account into equity. There is no
// retained-earnings account and no closing entry anywhere in the stack, so
// revenue and expense accumulate from the book's first posting forever.
//
// Every accessor and every rendered line therefore carries the word
// cumulative. A reader who takes them for a period figure misreads every
// statement this realm publishes. A period statement needs entry-level data;
// see DISCOVERY.md § 6.8.
//
// # The balance sheet identity is NOT offered as a check
//
// Assets and Claims are both reported. Their equality is not exposed as a
// verdict anywhere, because over a chart drawn from a [p/journal] Book it is
// algebraically identical to `totalDebits == totalCredits`, which [r/books]
// enforces on every post — a constant true, and true of a chart whose every
// account is classified backwards. [p/statements]' package doc carries the
// derivation. A `Balances()` here would be the fifth instance of the
// vacuous-true class this project keeps finding in its own work.
//
// What ships instead is the census: [AbnormalCount] and [AbnormalIn] report
// every account whose balance runs against its kind. That survives a balanced
// book. Its incompleteness is exact and is stated at [AbnormalCount].
//
// # NO CUSTODY — and refusing coins is not the same as not holding them
//
// There is no coinio import, no payable path, no fee, no withdrawal, no
// admin. So [Publish] REFUSES a transaction carrying coins: a realm with no
// withdrawal path that silently accepts ugnot strands it permanently, and
// "we hold no funds" would then be true of the design and false of the
// balance.
//
// # No admin, and no cross-owner aggregate beyond a count
//
// The deploying namespace has no privilege here: no setter, no pause, no
// ability to publish or to read anything a stranger cannot read. [Total] is a
// count of publications and nothing more. [r/books] refuses to enumerate
// books because such a total would sum every stranger's self-reported
// assertion; the same reasoning applies one level up, so there is no way to
// enumerate publishers and no cross-owner figure of any kind.
//
// # What this realm does NOT do
//
//   - It does not hold, move, or price any asset.
//   - It does not verify that an entry describes a real event.
//   - It does not detect a same-side misclassification. See [AbnormalCount].
//   - It publishes two statements and a census — no cash-flow statement, no
//     statement of changes in equity, no notes, no comparatives.
//
// [r/books]: /r/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/books
// [p/journal]: /p/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/journal
// [p/statements]: /p/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/statements
package statements

import (
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"strings"

	"gno.land/p/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/journal"
	stmt "gno.land/p/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/statements"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/r/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/books"
)

// RealmPath is this realm's own path, used to build Render links.
const RealmPath = "/r/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/statements"

// BooksPath is the ledger realm every figure here is derived from.
//
// It is taken BY VALUE from that realm's own exported constant rather than
// typed out again, so this is the compile-time pin itself and not a second
// copy of it that could drift. A reader checking which ledger a statement
// describes is reading the import, not a string in a doc comment.
const BooksPath = books.RealmPath

// PublicationsAreUncapped records a decision by its absence, because every
// other realm in this portfolio caps its per-owner state and a reader will
// look for the cap here.
//
// There is none, and the three reasons are:
//
//   - **No shared resource is consumed.** Keys are per owner, like r/books'
//     books. An owner can fill their own publication history and nobody
//     else's, and the cost of doing so is gas plus a storage deposit each
//     time. That is the same griefing argument r/books makes for its
//     per-owner caps, and here it is sufficient on its own.
//   - **Nothing iterates them.** Render reads the newest
//     [RenderPublicationLimit] by sequence number, by direct key lookup, so
//     page cost does not grow with the count. No accessor walks a publisher's
//     history.
//   - **There is no engine cap to mirror.** r/books caps because p/journal
//     caps and the interaction of its ceiling with RederiveFromJournal is
//     unmeasured. No such ceiling exists above this realm.
//
// A cap added only so a test could reach it would be worse than none.
const PublicationsAreUncapped = true

// RenderPublicationLimit caps how many of a publisher's statements one Render
// call lists. Publications are unbounded (see [PublicationsAreUncapped]), so
// this is what keeps a publisher's page cost flat.
const RenderPublicationLimit = 20

// RenderAbnormalLimit caps how many census rows one Render call emits. A
// chart may hold books.MaxAccountsPerBook accounts and in a pathological book
// every one of them is abnormal.
const RenderAbnormalLimit = 25

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

// record is one frozen statement. It stores the [stmt.Statement] whole rather
// than copying its ten fields into a parallel struct: a second field set is a
// second place for the two to disagree, and every field here is a value or a
// slice this realm allocated.
//
// There is deliberately no seq field. One was written here and read nowhere —
// found by the sabotage harness, which could not make dropping the assignment
// fail any test. A stored copy of the sequence would be a second place for the
// key and the record to disagree, and the key already carries it: every read
// path reaches a record by constructing pubKey(owner, seq) from a seq it
// already holds, so a field would only ever be checked against its own source.
type record struct {
	at int64
	st stmt.Statement
}

// published maps "<owner>|<padded seq>" to *record.
//
// The pointer never leaves this file. Every accessor copies scalars out, so no
// caller receives a handle onto stored state — the same discipline r/books
// applies to its *journal.Book.
var published = avl.NewTree()

// counts maps an owner's address string to how many statements they have
// published. It is the sequence allocator as well as the count.
var counts = avl.NewTree()

// pubCount is the global total, maintained alongside the tree so the index
// page never iterates. It is a count and nothing more; see the package doc on
// why there is no way to enumerate publishers.
var pubCount int

// ---------------------------------------------------------------------------
// Guards
// ---------------------------------------------------------------------------

// refuseCoins panics if a user call arrives carrying coins. Adopted verbatim
// from r/books, which faces the identical slot: no withdrawal path, so
// accepted coins are stranded permanently.
//
// The guard is on IsUserCall rather than IsUser deliberately, and the reason
// is NOT the one the canonical payment-guard advice gives. That advice is about
// a realm that ACCEPTS payment, where IsUser is dangerously broad because the
// MsgRun ephemeral can consume the envelope before forwarding control and the
// receipt invariant no longer holds. This guard REFUSES, so the broader
// predicate would refuse MORE, and "more conservative" is the wrong frame.
//
// The real reason is that OriginSend is a fact about the TRANSACTION, not about
// this realm. It is a faithful receipt only on the direct MsgCall path, where
// the envelope's destination is this realm. On a MsgRun path the envelope can
// be non-empty while nothing arrives here — coins sent to the ephemeral flow
// back to the user — so pairing it with IsUser buys no protection and adds a
// FALSE REFUSAL mode: a panic on a call that brought this realm nothing.
// IsUserCall is the narrowest predicate covering the only path on which a
// non-empty envelope means coins actually credited to this address.
//
// The residual is stated rather than guarded: coins can still reach this
// realm's address through an intermediary's explicit banker send, which no
// predicate here can see. What makes that survivable is not this guard but the
// absence of any consumption path — nothing in this realm can spend what
// arrives, so a stranded balance is inert rather than exploitable.
//
// An earlier version of this comment said "OriginSend is only meaningful for a
// direct MsgCall", which is false as written — it is readable on every path and
// merely stops being a receipt. An independent audit caught it. The predicate
// was right and the stated reason was not, which is the worse of the two
// failures: the predicate is re-derivable from the references and a confident
// wrong sentence is what stops a maintainer re-deriving it. Onyx's VM tightens
// IsUserCall, so this is exactly the comment that gets consulted after the
// semantics have moved underneath it.
func refuseCoins(cur realm) {
	// A no-op at today's single call site: Publish's first cur is
	// runtime-current by construction and stays current when forwarded through
	// a non-crossing call. It is here because this realm is IMMUTABLE after
	// addpkg, so a future second caller cannot be made safe later — and a
	// helper that reads Previous() off an unchecked realm parameter is a
	// designation-forgery shape whether or not it is reachable today.
	if !cur.IsCurrent() {
		panic("statements: refuseCoins called with a realm that is not current")
	}
	if cur.Previous().IsUserCall() && len(unsafe.OriginSend()) > 0 {
		panic("statements: this realm holds no coins and has no withdrawal path; send none")
	}
}

// ---------------------------------------------------------------------------
// The cross-realm reads
// ---------------------------------------------------------------------------

// parseKind turns one of [r/books]' five kind words back into a
// [journal.Kind], and PANICS on anything else.
//
// This is the ugly seam and it is named rather than hidden. r/books returns an
// account's kind as `journal.Kind.String()` — a presentation format that has
// become an API across a realm boundary — and no Kind parser exists anywhere
// in this portfolio (measured in DISCOVERY.md § 7, step 2c: zero hits for
// ParseKind, parseKind and kindFromString; r/books' own kindFromCode maps a
// code PREFIX to a kind and is unexported).
//
// It panics rather than returning a zero Kind, and the reason is specific: the
// zero Kind is reported CREDIT-NORMAL by [journal.Kind.IsDebitNormal], so a
// silently-unparsed word would not drop the row — it would file it under
// claims and produce a statement that balances and misstates. p/statements'
// Derive would catch it as ErrInvalidKind, and relying on that would make this
// realm's error message point at the wrong layer.
//
// The round trip is pinned in the suite over all five kinds rather than
// assumed, because the contract is another realm's String method.
func parseKind(s string) journal.Kind {
	switch s {
	case "asset":
		return journal.Asset
	case "liability":
		return journal.Liability
	case "equity":
		return journal.Equity
	case "revenue":
		return journal.Revenue
	case "expense":
		return journal.Expense
	}
	panic("statements: unreadable account kind " + strconv.Quote(s) +
		" from " + BooksPath)
}

// chartOf reads an owner's whole chart out of [r/books] as journal.Account
// rows, ready for [stmt.Derive].
//
// # One walk, not a paging loop
//
// books.Codes takes a `from` and a `limit`, so the obvious shape is a paging
// loop — and DISCOVERY.md § 6.4 planned one, costing ceil(n/limit) full chart
// walks because that iterator has no seek and honours `from` by skipping.
// This asks for the whole chart in ONE call instead, with limit at r/books'
// own account cap, which is exactly one walk and is strictly cheaper than any
// paging of it. The cap is read from that realm's exported constant, so the
// request can never be short of what a book may hold.
//
// Dropping the loop also drops its hazard. books.Codes' `from` is INCLUSIVE —
// paging re-reads the last code received — so every paging caller owes itself
// a boundary dedup, and a missed one double-counts one account per page
// boundary. A double-counted balance is the defect this product is least able
// to detect: the statement would still balance.
//
// # The agreement check is not decoration
//
// books.Accounts and books.Codes are two reads, taken at one instant but
// through different code paths. If they disagree this refuses rather than
// publishing over a truncated chart, because a chart missing rows yields a
// statement that is wrong in a way no identity here can see.
//
// # Taint
//
// The []string books.Codes returns was allocated under that realm and reaches
// here readonly-tainted. Nothing below mutates it or stores it: the codes are
// read out by value, and the rows are allocated here.
func chartOf(owner address) []journal.Account {
	n := books.Accounts(owner) // panics if the owner has no book
	codes := books.Codes(owner, "", books.MaxAccountsPerBook)
	if len(codes) != n {
		panic("statements: " + BooksPath + " reports " + strconv.Itoa(n) +
			" accounts but enumerated " + strconv.Itoa(len(codes)) +
			"; refusing to report on a partial chart")
	}

	rows := make([]journal.Account, 0, n)
	for _, code := range codes {
		name, kind, debits, credits, balance := books.AccountInfo(owner, code)
		a := journal.Account{
			Code:    code,
			Name:    name,
			Kind:    parseKind(kind),
			Debits:  debits,
			Credits: credits,
		}
		// The balance r/books reported, against the one this row computes.
		//
		// State its reach exactly, because the flattering reading is
		// available: BOTH sides are journal.Account.Balance over the same two
		// columns, so this is a CONSTANT TRUE against any disagreement
		// between the two realms' arithmetic and must never be quoted as
		// cross-checking it. What it does catch is a transcription error in
		// the four assignments above — swapping Debits and Credits, or
		// reading a column off the wrong code — which is this realm's own
		// code and the only place in this path where that could happen.
		if a.Balance() != balance {
			panic("statements: balance mismatch for account " + code +
				"; this realm transcribed the chart wrongly")
		}
		rows = append(rows, a)
	}
	return rows
}

// deriveLive reads the owner's chart now and classifies it. Every live figure
// in this realm goes through here, so there is one path from the ledger to a
// statement and no accessor can derive differently from Publish.
//
// MustDerive, not Derive: on the mutating path an error return does not revert
// a Gno transaction and only a panic does.
func deriveLive(owner address) stmt.Statement {
	return stmt.MustDerive(chartOf(owner))
}

// ---------------------------------------------------------------------------
// Write
// ---------------------------------------------------------------------------

// Publish freezes the caller's own statement at the current height and returns
// its sequence number, which starts at 1 for each publisher.
//
// The owner is cur.Previous().Address() and there is no owner parameter, so
// authorization is structural rather than a check: there is no address for a
// caller to forge and no way to publish a statement about somebody else's
// book. A realm that calls in publishes over its own book for free, which
// arrives as a property of that rule rather than as a feature — the same way
// it does in r/books.
//
// An EMPTY CHART IS REFUSED, and this is a deliberate divergence from
// p/statements, whose doc calls zero rows "a legitimate statement of nothing".
// It is legitimate for a pure function and not worth a storage deposit here: a
// frozen row of zeros at a permanent path reads as a statement rather than as
// an absence, and the publisher has paid to say nothing.
//
// Everything that can refuse does so before this realm writes anything.
func Publish(cur realm) int64 {
	refuseCoins(cur)
	owner := cur.Previous().Address()

	rows := chartOf(owner)
	if len(rows) == 0 {
		panic("statements: this book has no accounts; there is nothing to report on")
	}
	st := stmt.MustDerive(rows)

	key := owner.String()
	seq := int64(ownerCount(key)) + 1
	published.Set(pubKey(key, seq), &record{
		at: runtime.ChainHeight(),
		st: st,
	})
	counts.Set(key, int(seq))
	pubCount++
	return seq
}

// ---------------------------------------------------------------------------
// Reads — the frozen statements
// ---------------------------------------------------------------------------

// Count is how many statements an owner has published. Zero for an address
// that has never published, which is not an error.
func Count(owner address) int { return ownerCount(owner.String()) }

// Latest is an owner's highest sequence number, and whether they have
// published at all. The second result matters: sequence numbers start at 1, so
// a zero first result means "never published" and never "statement 0".
func Latest(owner address) (int64, bool) {
	n := ownerCount(owner.String())
	if n == 0 {
		return 0, false
	}
	return int64(n), true
}

// Total is how many statements exist across every publisher. It is a count and
// nothing more; see the package doc on why there is no enumeration and no
// cross-owner figure.
func Total() int { return pubCount }

// Has reports whether a publication exists, so a reader can distinguish it
// from the panics every accessor below raises for an unknown one.
func Has(owner address, seq int64) bool {
	return published.Has(pubKey(owner.String(), seq))
}

// PublishedAt is the chain height a statement was frozen at.
func PublishedAt(owner address, seq int64) int64 {
	return mustRecord(owner, seq).at
}

// Rows is how many accounts the statement classified.
func Rows(owner address, seq int64) int {
	return mustRecord(owner, seq).st.Rows
}

// BalanceSheet returns a frozen statement's balance sheet.
//
// cumulativeNet appears here as an EXPLICIT RECONCILING LINE because nothing
// in this stack closes a nominal account into equity. claims is
// liabilities + equity + cumulativeNet, so a reader who checks assets against
// liabilities + equity alone and finds it short by exactly cumulativeNet is
// not looking at a bug.
//
// assets and claims are both returned and their equality is deliberately not
// offered as a verdict; see the package doc.
func BalanceSheet(owner address, seq int64) (assets, liabilities, equity, cumulativeNet, claims int64) {
	s := mustRecord(owner, seq).st
	return s.Assets, s.Liabilities, s.Equity, s.CumulativeNet, s.Claims
}

// IncomeStatement returns a frozen statement's income statement. Every figure
// is CUMULATIVE SINCE THE BOOK'S FIRST POSTING, not a period figure; see the
// package doc.
func IncomeStatement(owner address, seq int64) (cumulativeRevenue, cumulativeExpenses, cumulativeNet int64) {
	s := mustRecord(owner, seq).st
	return s.CumulativeRevenue, s.CumulativeExpenses, s.CumulativeNet
}

// SectionTotal returns the figure presented for one section: "assets",
// "claims" or "performance". The performance total is the income statement's
// bottom line, not the sum of its two components.
func SectionTotal(owner address, seq int64, section string) int64 {
	v, err := mustRecord(owner, seq).st.SectionTotal(parseSection(section))
	if err != nil {
		// Unreachable: parseSection panics on anything outside the three.
		panic("statements: " + err.Error())
	}
	return v
}

// AbnormalCount is how many accounts in a frozen statement carry a balance
// running against their kind.
//
// # What the census catches, and what it cannot
//
// This is the only partial answer in this portfolio to p/journal's consumer
// obligation 7 — a kind set wrongly when an account was opened is undetectable
// in that package and undetectable anywhere else in it. The answer is sound and
// incomplete, and the incompleteness is exact:
//
//   - It CATCHES a misclassification that crosses the debit/credit-normal
//     boundary and whose account has a non-zero balance. An account named
//     "Accounts payable" but coded 1200 is an asset in r/books' scheme,
//     accumulates credits, and reads negative here.
//   - It CANNOT CATCH a misclassification that stays on the same side:
//     liability to equity to revenue, or asset to expense. Both subtotals
//     move, no balance goes negative, and nothing in this portfolio detects
//     it. Obligation 7 is NARROWED, NOT CLOSED.
//   - It has a FALSE-POSITIVE MODE that is not a defect. A genuine contra
//     account — accumulated depreciation under assets, a sales return under
//     revenue — is legitimately abnormal-signed. r/books' code-prefix scheme
//     has no contra range, so such an account is indistinguishable here from a
//     miscoded one.
//
// So a non-zero count is A FINDING TO READ, never a verdict, and a zero count
// is not a clean bill of health.
func AbnormalCount(owner address, seq int64) int {
	return len(mustRecord(owner, seq).st.Abnormal)
}

// AbnormalIn counts the abnormal accounts presented in one section:
// "assets", "claims" or "performance".
func AbnormalIn(owner address, seq int64, section string) int {
	return mustRecord(owner, seq).st.AbnormalIn(parseSection(section))
}

// AbnormalAt returns one census row by its zero-based index. Rows are in
// ascending account-code order, which p/statements enforces as a precondition
// on its input rather than relying on this realm to sort.
//
// section is the row's statement section, derived from its kind through the
// same mapping the totals were built from.
func AbnormalAt(owner address, seq int64, i int) (code, name, kind, section string, balance int64) {
	rows := mustRecord(owner, seq).st.Abnormal
	if i < 0 || i >= len(rows) {
		panic("statements: no census row " + strconv.Itoa(i) +
			"; this statement has " + strconv.Itoa(len(rows)))
	}
	a := rows[i]
	sec, err := stmt.SectionOf(a.Kind)
	if err != nil {
		// Unreachable: Derive refuses a row whose kind is outside the five.
		panic("statements: " + err.Error())
	}
	return a.Code, a.Name, a.Kind.String(), sec.String(), a.Balance
}

// ---------------------------------------------------------------------------
// Reads — the live chart
// ---------------------------------------------------------------------------

// THE COST DECISION FOR EVERY ACCESSOR BELOW, RECORDED BECAUSE IT WAS NOT.
//
// Each of these takes an `owner address` the CALLER names, and each one walks
// that stranger's whole chart: one books.Codes call plus up to
// books.MaxAccountsPerBook separate cross-realm books.AccountInfo calls. None
// of them is a crossing function, so anyone can trigger that against any
// address for free. An audit raised it; this block is the answer, and the
// realm's other cost decisions are documented so this one has to be too.
//
// WHAT IS AND IS NOT AT STAKE. The querying caller pays the gas. Nothing is
// charged to the owner, nothing accumulates in chain state, and no figure here
// can be moved by the query. The residual is that a vm/qrender or vm/qeval
// against a chart at the account cap is that many cross-realm calls of
// NODE-SIDE work — a node-operator consideration, not a hazard to this realm
// or to the owner. [Verify] being reached from [Render] is the one part that is
// involuntary for a viewer and repeatable by anyone: a public page pays it per
// view.
//
// THE DECISION IS TO KEEP THE INLINE CALL. The cheap alternative is for
// renderStatement to print the frozen figures and link to [Verify] instead of
// calling it. That is refused because a page showing frozen figures with no
// live comparison is the exact artifact this realm exists to improve on — the
// whole reason [Verify] and these accessors exist is that a stale statement be
// visibly stale, and deferring that to a second click makes the common reading
// the uninformed one. The bound is the realm's own account cap, it is
// double-clamped by books.Codes, and the cost is flat per view rather than
// growing.
//
// THE AXIS THAT DOES NOT PRICE THIS. Entries, not accounts, are what a book
// accumulates without bound, so the question that decides the ceiling is
// whether this walk is priced by entries as well as by accounts. It is not,
// and the reason is STRUCTURAL rather than measured: books.AccountInfo returns
// the account's STORED Debits and Credits and a Balance() over them, so it
// READS NO ENTRIES AT ALL and performs no journal replay. chartOf does one
// books.Codes walk plus one AccountInfo per account, bounded by the account
// cap. So the ceiling is the MAX of the account and entry axes and never their
// product.
//
// Say it as "O(1) in entries EXAMINED", never as "O(1) in gas" -- the second is
// the overclaim available here and the measurement below refutes it. A bigger
// book is a bigger store and every lookup into it traverses a deeper avl tree,
// so cost does grow with entries: sub-linearly, in the store's depth rather
// than in the entry count. The ceiling argument needs only that the entry term
// is absent from the PRODUCT, which this gives it.
//
// A gas measurement checks that and does not establish it, which is the right
// way round and was not how this comment first read. Measured on the pinned
// onyx toolchain, two accounts held constant, as (101 reads minus 1 read) / 100
// so the setup cancels: about 476k gas per read against a 3-entry book and
// about 563k against one at books.MaxEntriesPerBook -- +18% across the whole
// entry range, or roughly twenty gas per entry, IN THAT FIXTURE. Read the next
// paragraph before quoting either figure; the qualifier is not a hedge and the
// percentage is not a property of this realm. What the figures do establish is
// the shape: entry count adds a realm-size overhead and not a replay, which is
// what the structural argument predicts.
//
// THOSE TWO FIGURES ARE EXACTLY REPRODUCIBLE AND ARE STILL NOT A PRICE, and
// the distinction is the whole point of this paragraph. Two separate
// invocations of the same four-case fixture returned 476,470 and 562,874 gas
// per read, identical to the unit -- so this is not run-to-run noise and the
// toolchain is deterministic. Add NINE UNRELATED test cases ahead of the same
// four and the cap figure becomes 828,602, up 47%, while the 3-entry figure
// moves 3%. What the number is sensitive to is therefore the total avl state
// resident when the read happens, not the entry count under test. A figure
// measured in a fixture is a figure about that fixture; on chain the resident
// state is the whole realm's history and nothing here bounds it.
//
// That also explains the two designs that failed, which are kept because the
// failure is the evidence. Differencing setup-only against setup-plus-one-read
// at the cap puts a ~5e5 signal against a ~3.5e9 setup. Differencing by TEN
// reads returned a NEGATIVE marginal: each case carries its own setup, and the
// later case's setup runs against more accumulated state than the earlier
// one's, so the order effect exceeded a 10-read signal and reversed its sign.
// A hundred reads clears that; ten does not. The confound was found by the sign
// rather than argued.
//
// An earlier version of this comment quoted 1,060,407 and 1,085,495 gas,
// "+2.4%", "about six gas per entry". Those came from one of the confounded
// designs and did not reproduce. They are replaced rather than defended. The
// structural claim above is the one that survives, and it is checkable from
// source forever while a gas figure is not.
//
// WHAT THIS IS NOT. It is NOT the cost decision books.Rederive makes by being
// a crossing function. That realm's doc says a free read there "would let
// anyone make an owner's book expensive to query", and the first reading of
// this finding was that this realm undoes that decision. It does not, and the
// analogy was withdrawn on evidence: Rederive replays the APPEND-ONLY JOURNAL,
// bounded by entry count and growing without bound, while chartOf is bounded
// by ACCOUNTS at a fixed cap. The two differ by orders of magnitude, which is
// why one is gated and these are not.

// CurrentBalanceSheet derives the owner's balance sheet from their chart NOW,
// publishing nothing. It exists so that a false [Verify] is diagnosable: a
// reader can see which figure moved instead of only that one did.
//
// Each of the three Current accessors re-reads the chart, so asking for all of
// them is three walks. [Verify] is the single-call form.
func CurrentBalanceSheet(owner address) (assets, liabilities, equity, cumulativeNet, claims int64) {
	s := deriveLive(owner)
	return s.Assets, s.Liabilities, s.Equity, s.CumulativeNet, s.Claims
}

// CurrentIncomeStatement derives the owner's income statement from their chart
// now. Cumulative since inception; see the package doc.
func CurrentIncomeStatement(owner address) (cumulativeRevenue, cumulativeExpenses, cumulativeNet int64) {
	s := deriveLive(owner)
	return s.CumulativeRevenue, s.CumulativeExpenses, s.CumulativeNet
}

// CurrentAbnormalCount runs the census over the owner's chart now. Its reach
// is exactly [AbnormalCount]'s.
func CurrentAbnormalCount(owner address) int {
	return len(deriveLive(owner).Abnormal)
}

// CurrentRows is how many accounts the owner's chart holds right now, as this
// realm reads it. It agrees with books.Accounts by construction — chartOf
// refuses when they disagree — and is exposed so a reader comparing a frozen
// statement's Rows against the live chart does not have to call two realms.
func CurrentRows(owner address) int { return len(chartOf(owner)) }

// Verify re-derives the owner's chart now and reports whether every figure in
// a frozen statement still holds, including the census rows.
//
// # Read the ceiling before quoting this
//
// A true result means THE FROZEN FIGURES STILL HOLD. It does NOT mean the
// chart is untouched, and the gap is demonstrable rather than theoretical: a
// posting that moves an amount between two asset accounts leaves Assets,
// Claims, the net, the row count and the census all identical, and this still
// reads true. The suite pins that case.
//
// A false result is a real difference and nothing more: the owner has posted
// since, which is the normal life of a book. It is not evidence of
// misconduct, and this realm offers no mechanism that treats it as such.
//
// What proves the chart's own history is r/books' append-only journal, where
// a wrong entry is corrected by a visible reversal rather than an edit.
func Verify(owner address, seq int64) bool {
	want := mustRecord(owner, seq).st
	got := deriveLive(owner)

	if want.Rows != got.Rows ||
		want.Assets != got.Assets ||
		want.Liabilities != got.Liabilities ||
		want.Equity != got.Equity ||
		want.CumulativeRevenue != got.CumulativeRevenue ||
		want.CumulativeExpenses != got.CumulativeExpenses ||
		want.CumulativeNet != got.CumulativeNet ||
		want.Claims != got.Claims {
		return false
	}
	if len(want.Abnormal) != len(got.Abnormal) {
		return false
	}
	for i, a := range want.Abnormal {
		b := got.Abnormal[i]
		if a.Code != b.Code || a.Kind != b.Kind || a.Balance != b.Balance {
			return false
		}
		// Name is deliberately NOT compared. r/books has no rename path, so
		// it cannot change; comparing it would assert a property of that
		// realm's API surface from here, where a reader would mistake it for
		// a check on the chart.
	}
	return true
}

// Height is the chain height this realm stamps publications with. Exposed so a
// caller can predict what Publish will record.
func Height() int64 { return runtime.ChainHeight() }

// Ledger is the path of the realm every figure here is derived from. The
// constant is [BooksPath]; this is the accessor for a caller that cannot read
// a constant off a package.
func Ledger() string { return BooksPath }

// ---------------------------------------------------------------------------
// Internals
// ---------------------------------------------------------------------------

// pubKey is owner|paddedSeq. The sequence is left-padded to 19 digits — the
// width of MaxInt64 — so that lexicographic order over an owner's prefix is
// numeric order over their statements. An unpadded decimal would sort "10"
// before "9". The convention is r/invoices' invKey, adopted rather than
// re-derived.
func pubKey(owner string, seq int64) string {
	s := strconv.FormatInt(seq, 10)
	for len(s) < 19 {
		s = "0" + s
	}
	return owner + "|" + s
}

// ownerCount reads a publisher's count, treating an absent key as zero.
//
// avl.Tree.Get returns ONE value and cannot distinguish an absent key from a
// nil-valued one, so the two-value type assertion carries the existence answer
// in one traversal. Only this file ever Sets, and it only ever Sets an int.
func ownerCount(owner string) int {
	n, ok := counts.Get(owner).(int)
	if !ok {
		return 0
	}
	return n
}

func mustRecord(owner address, seq int64) *record {
	r, ok := published.Get(pubKey(owner.String(), seq)).(*record)
	if !ok {
		panic("statements: no statement " + strconv.FormatInt(seq, 10) +
			" for " + owner.String())
	}
	return r
}

// parseSection turns a section word into a [stmt.Section] and panics on
// anything else. The three words are that type's own String output, so the
// round trip is exact; the suite pins it rather than trusting this to stay
// true of another package's method.
func parseSection(section string) stmt.Section {
	switch strings.ToLower(strings.TrimSpace(section)) {
	case "assets":
		return stmt.SectionAssets
	case "claims":
		return stmt.SectionClaims
	case "performance":
		return stmt.SectionPerformance
	}
	panic("statements: unknown section " + strconv.Quote(section) +
		"; want assets, claims or performance")
}

// ---------------------------------------------------------------------------
// Render
// ---------------------------------------------------------------------------

// Render serves the index at "", a publisher's page at "<address>", and one
// statement at "<address>/<seq>".
//
// Every caller-supplied string — an account's code and name, both of them an
// owner's free text in r/books — goes through [cell]. Free text reaching
// Render unescaped is the one injection-shaped surface a realm with no custody
// still has, and here the bytes come from a THIRD realm's state, which does
// not make them safer.
func Render(path string) string {
	p := strings.TrimSpace(strings.Trim(path, "/"))
	if p == "" {
		return renderIndex()
	}
	if i := strings.Index(p, "/"); i >= 0 {
		owner := address(strings.TrimSpace(p[:i]))
		rest := strings.TrimSpace(strings.Trim(p[i+1:], "/"))
		seq, err := strconv.ParseInt(rest, 10, 64)
		if err != nil {
			return "# statements\n\n`" + sanitize.InlineText(rest) +
				"` is not a statement number.\n"
		}
		return renderStatement(owner, seq)
	}
	return renderPublisher(address(p))
}

func renderIndex() string {
	var sb strings.Builder
	sb.WriteString("# statements — classified financial statements\n\n")
	sb.WriteString("A balance sheet, a cumulative income statement and an ")
	sb.WriteString("abnormality census, **derived** from a chart of accounts ")
	sb.WriteString("in [`" + BooksPath + "`](" + BooksPath + ") — never ")
	sb.WriteString("supplied by the publisher.\n\n")

	sb.WriteString("> **A published statement is a claim about a claim.** ")
	sb.WriteString("The ledger it reads holds no asset, so nothing ties an ")
	sb.WriteString("account reading `Cash 5000` to 5000 real ugnot anywhere. ")
	sb.WriteString("A statement derived from it inherits that entirely and ")
	sb.WriteString("then adds a layer of apparent authority: it looks like an ")
	sb.WriteString("audited artifact and is a self-report of a self-report. ")
	sb.WriteString("No audit is performed here and no custody exists.\n\n")

	sb.WriteString("## State\n\n")
	sb.WriteString("- statements published: **" + strconv.Itoa(pubCount) + "**\n")
	sb.WriteString("- ledger: `" + BooksPath + "`\n")
	sb.WriteString("- chain height: **" + strconv.FormatInt(runtime.ChainHeight(), 10) + "**\n\n")
	sb.WriteString("There is deliberately no way to enumerate publishers or ")
	sb.WriteString("to aggregate across them: such a total would sum every ")
	sb.WriteString("stranger's self-reported assertion.\n\n")

	sb.WriteString("## What is frozen, and what is not\n\n")
	sb.WriteString("`Publish` freezes the **figures**. It does not freeze the ")
	sb.WriteString("chart — account codes, names and the postings behind them ")
	sb.WriteString("stay in the ledger, which keeps writing them. So ")
	sb.WriteString("`Verify` answers *\"do the frozen figures still hold?\"* ")
	sb.WriteString("and **not** *\"is the chart untouched?\"*: a posting that ")
	sb.WriteString("moves an amount between two asset accounts leaves every ")
	sb.WriteString("figure identical and `Verify` still reads true.\n\n")

	sb.WriteString("## The three sections\n\n")
	sb.WriteString("| section | account kinds | presented as |\n|---|---|---|\n")
	sb.WriteString("| `assets` | asset | balance sheet, debit side |\n")
	sb.WriteString("| `claims` | liability, equity | balance sheet, credit side |\n")
	sb.WriteString("| `performance` | revenue, expense | income statement |\n\n")
	sb.WriteString("Revenue and expenses are **cumulative since the book's ")
	sb.WriteString("first posting**, not period figures: nothing in this ")
	sb.WriteString("stack closes a nominal account into equity, so the net ")
	sb.WriteString("appears on the balance sheet as an explicit reconciling ")
	sb.WriteString("line.\n\n")

	sb.WriteString("## Usage\n\n")
	sb.WriteString("```\nseq := Publish()            // over the caller's own book\n")
	sb.WriteString("BalanceSheet(owner, seq)\nIncomeStatement(owner, seq)\n")
	sb.WriteString("AbnormalCount(owner, seq)   // a finding to read, not a verdict\n")
	sb.WriteString("Verify(owner, seq)          // do the figures still hold?\n```\n\n")
	sb.WriteString("A publisher's statements are at `" + RealmPath +
		":<address>`, and one statement at `" + RealmPath +
		":<address>/<seq>`.\n")
	return sb.String()
}

// cell prepares caller-supplied text for a GFM table cell, truncating it for
// display first.
//
// It is r/books' helper of the same name, adopted verbatim, because the slot is
// identical and the text is literally the same bytes one realm further on.
// TableCell rather than InlineText: these bytes land between two `|`
// delimiters and InlineText does not escape the pipe — deliberately, per the
// sanitizer's own doc, so that TableCell can escape it without
// double-escaping. r/books shipped InlineText in this slot first and an
// adversarial audit found it.
//
// The account CODE needs this as much as the name does. A GFM row is split
// before inline parsing runs, so a `|` inside a backtick span is not protected
// by the backticks, and r/books' kindFromCode constrains only the code's first
// character.
//
// TRUNCATE BEFORE ESCAPING, and on a RUNE boundary. Escaping first and cutting
// afterwards can slice a `\|` in half and leave a cell ending in a bare
// backslash; cutting on a byte boundary can split a multi-byte rune and emit
// invalid UTF-8. By the time the sanitizer sees the string the damage is
// upstream of it.
func cell(s string) string {
	const maxRunes = 48
	if r := []rune(s); len(r) > maxRunes {
		s = string(r[:maxRunes]) + "…"
	}
	return sanitize.TableCell(s)
}

func renderPublisher(owner address) string {
	n := ownerCount(owner.String())
	if n == 0 {
		return "# statements\n\nNo statement published by `" +
			sanitize.InlineText(owner.String()) + "`.\n"
	}

	var sb strings.Builder
	sb.WriteString("# Statements published by " +
		sanitize.InlineText(owner.String()) + "\n\n")
	sb.WriteString("Derived from that address's book in [`" + BooksPath +
		"`](" + BooksPath + ":" + owner.String() + "). ")
	sb.WriteString("**A statement is a claim about a claim** — see the ")
	sb.WriteString("[index](" + RealmPath + ").\n\n")

	shown := n
	if shown > RenderPublicationLimit {
		shown = RenderPublicationLimit
	}
	sb.WriteString("| seq | height | rows | assets | claims | cumulative net | census |\n")
	sb.WriteString("|---|---|---|---|---|---|---|\n")
	for seq := int64(n); seq > int64(n-shown); seq-- {
		r, ok := published.Get(pubKey(owner.String(), seq)).(*record)
		if !ok {
			// Unreachable: counts and published are written together.
			continue
		}
		sb.WriteString("| [" + strconv.FormatInt(seq, 10) + "](" + RealmPath +
			":" + owner.String() + "/" + strconv.FormatInt(seq, 10) + ") | " +
			strconv.FormatInt(r.at, 10) + " | " +
			strconv.Itoa(r.st.Rows) + " | " +
			strconv.FormatInt(r.st.Assets, 10) + " | " +
			strconv.FormatInt(r.st.Claims, 10) + " | " +
			strconv.FormatInt(r.st.CumulativeNet, 10) + " | " +
			strconv.Itoa(len(r.st.Abnormal)) + " |\n")
	}
	if n > shown {
		sb.WriteString("\n_Showing the " + strconv.Itoa(shown) +
			" most recent of " + strconv.Itoa(n) + " statements._\n")
	}
	return sb.String()
}

func renderStatement(owner address, seq int64) string {
	r, ok := published.Get(pubKey(owner.String(), seq)).(*record)
	if !ok {
		return "# statements\n\nNo statement " +
			strconv.FormatInt(seq, 10) + " for `" +
			sanitize.InlineText(owner.String()) + "`.\n"
	}
	s := r.st

	var sb strings.Builder
	sb.WriteString("# Statement " + strconv.FormatInt(seq, 10) + " of " +
		sanitize.InlineText(owner.String()) + "\n\n")
	sb.WriteString("Frozen at height **" + strconv.FormatInt(r.at, 10) +
		"** over **" + strconv.Itoa(s.Rows) + "** accounts, derived from [`" +
		BooksPath + "`](" + BooksPath + ":" + owner.String() + ").\n\n")

	sb.WriteString("> **This is a claim about a claim.** The ledger holds no ")
	sb.WriteString("asset and no audit was performed. Every figure below is ")
	sb.WriteString("derived faithfully from what this address wrote about ")
	sb.WriteString("itself.\n\n")

	sb.WriteString("## Balance sheet\n\n")
	sb.WriteString("| | |\n|---|---|\n")
	sb.WriteString("| assets | " + strconv.FormatInt(s.Assets, 10) + " |\n")
	sb.WriteString("| liabilities | " + strconv.FormatInt(s.Liabilities, 10) + " |\n")
	sb.WriteString("| equity | " + strconv.FormatInt(s.Equity, 10) + " |\n")
	sb.WriteString("| cumulative net | " + strconv.FormatInt(s.CumulativeNet, 10) + " |\n")
	sb.WriteString("| **claims** | **" + strconv.FormatInt(s.Claims, 10) + "** |\n\n")
	sb.WriteString("`claims` is liabilities + equity + cumulative net. The ")
	sb.WriteString("net is an **explicit reconciling line**, because nothing ")
	sb.WriteString("in this stack closes a nominal account into equity — a ")
	sb.WriteString("reader who checks assets against liabilities + equity ")
	sb.WriteString("alone and finds it short by exactly the net is not ")
	sb.WriteString("looking at a bug.\n\n")
	sb.WriteString("That `assets` and `claims` agree is **not offered as a ")
	sb.WriteString("check**: over any chart the ledger can produce that ")
	sb.WriteString("equality is algebraically identical to *debits equal ")
	sb.WriteString("credits*, which it enforces on every post. It is true of ")
	sb.WriteString("a chart whose every account is classified backwards.\n\n")

	sb.WriteString("## Income statement — cumulative since inception\n\n")
	sb.WriteString("| | |\n|---|---|\n")
	sb.WriteString("| cumulative revenue | " + strconv.FormatInt(s.CumulativeRevenue, 10) + " |\n")
	sb.WriteString("| cumulative expenses | " + strconv.FormatInt(s.CumulativeExpenses, 10) + " |\n")
	sb.WriteString("| **cumulative net** | **" + strconv.FormatInt(s.CumulativeNet, 10) + "** |\n\n")
	sb.WriteString("**Not a period figure.** Revenue and expenses accumulate ")
	sb.WriteString("from the book's first posting forever: the ledger's close ")
	sb.WriteString("is a backdating seal and sweeps no nominal account into ")
	sb.WriteString("equity.\n\n")

	sb.WriteString("## Abnormality census\n\n")
	if len(s.Abnormal) == 0 {
		sb.WriteString("_No account carried a balance against its kind._\n\n")
	} else {
		sb.WriteString("**" + strconv.Itoa(len(s.Abnormal)) + "** account(s) ")
		sb.WriteString("carried a balance running against their kind.\n\n")
		sb.WriteString("| code | name | kind | section | balance |\n")
		sb.WriteString("|---|---|---|---|---|\n")
		for i, a := range s.Abnormal {
			if i >= RenderAbnormalLimit {
				break
			}
			secName := "invalid"
			if sec, err := stmt.SectionOf(a.Kind); err == nil {
				secName = sec.String()
			}
			sb.WriteString("| `" + cell(a.Code) + "` | " + cell(a.Name) +
				" | " + a.Kind.String() + " | " + secName + " | " +
				strconv.FormatInt(a.Balance, 10) + " |\n")
		}
		if len(s.Abnormal) > RenderAbnormalLimit {
			sb.WriteString("\n_Showing " + strconv.Itoa(RenderAbnormalLimit) +
				" of " + strconv.Itoa(len(s.Abnormal)) + " rows._\n")
		}
		sb.WriteString("\n")
	}
	sb.WriteString("A census row is **a finding to read, never a verdict**. ")
	sb.WriteString("It catches a misclassification that crosses the ")
	sb.WriteString("debit/credit-normal boundary; it **cannot** catch one ")
	sb.WriteString("that stays on the same side (liability↔equity↔revenue, ")
	sb.WriteString("asset↔expense), and a genuine contra account — ")
	sb.WriteString("accumulated depreciation, a sales return — is ")
	sb.WriteString("legitimately abnormal-signed. An empty census is not a ")
	sb.WriteString("clean bill of health.\n\n")

	sb.WriteString("## Does it still hold?\n\n")
	if !books.HasBook(owner) {
		sb.WriteString("_The ledger reports no book for this address._\n")
		return sb.String()
	}
	if Verify(owner, seq) {
		sb.WriteString("**Verify: true** — re-deriving the chart now ")
		sb.WriteString("reproduces every figure above. This means the ")
		sb.WriteString("**figures** still hold; it does **not** mean the ")
		sb.WriteString("chart is untouched. A posting that moves an amount ")
		sb.WriteString("between two asset accounts leaves every figure here ")
		sb.WriteString("identical.\n")
	} else {
		sb.WriteString("**Verify: false** — the chart has moved since this ")
		sb.WriteString("statement was frozen. That is the normal life of a ")
		sb.WriteString("book and is not evidence of anything else. The ")
		sb.WriteString("current figures are derivable with ")
		sb.WriteString("`CurrentBalanceSheet`.\n")
	}
	return sb.String()
}
