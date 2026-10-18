// Package cashflow publishes a direct-method statement of cash flows over a
// book this realm does not own, cannot write, and did not supply.
//
// # What it is, in one sentence
//
// An owner of a book in [r/books] declares which of their account codes hold
// cash and what every other code's movement is for; this realm then reads the
// entries in a window straight out of that ledger, hands them to [p/cashflow],
// and freezes the resulting statement at a sequence number.
//
// # A PUBLISHED STATEMENT IS A CLAIM ABOUT A CLAIM — and here, about TWO
//
// [r/statements] already says this of itself and it is true here with one
// extra layer. A book is a set of claims by its owner; nothing ties an account
// reading `Cash 5000` to 5000 real ugnot anywhere. A cash-flow statement
// derived from such a book inherits that completely, and then adds a SECOND
// caller declaration on top: which codes are cash at all.
//
// [p/cashflow] states the consequence exactly and it is repeated here rather
// than linked, because it is the single most important sentence about this
// realm: *"A realm that declares a receivable as cash produces a plausible,
// wrong statement. The declaration is the trust boundary."*
//
// So what this realm guarantees is narrow:
//
//   - the ENTRIES are read from [r/books], not supplied by the publisher;
//   - the CLASSIFICATION is the publisher's own declared policy, frozen with
//     the statement so a reader sees what it was;
//   - the ARITHMETIC is [p/cashflow]'s, which nobody here can parameterise.
//
// That the chart describes anything real, and that the codes called cash hold
// cash, are not claimed here and are not checkable from here.
//
// # Derived, not supplied — and the one figure that is supplied
//
// Every figure comes from [r/books] through its own read surface, except one.
// [p/cashflow] cannot derive an OPENING cash position from a window-filtered
// entry slice — a window carries period movement, not a cumulative position —
// so `opening` is an argument to [Publish] and is echoed into the report
// unchanged. [Closing] is `Opening + NetChange` and is therefore only as good
// as a number the publisher typed.
//
// This realm does not leave it at that. See [OpeningReconciled]: when the
// window extends past every entry the book holds, the sum of the declared cash
// accounts' balances is the cumulative cash position, and that is comparable
// to [Closing]. Where the comparison is available, [Publish] REFUSES to
// publish a statement that fails it. Where it is not available, the report
// says so and the figure stands as a declaration.
//
// # The window is REFUSED when it is too wide, never chunked
//
// [p/cashflow] is explicit that it does no paging and no merging, because
// merging reports across pages would make the unresolved set an artifact of
// the paging. Its entry cap is 4096, exactly [books.MaxEntriesPerBook], so the
// primitive can always accept a whole book and the binding constraint is not
// its cap — it is the cross-realm call budget, two reads per entry.
//
// So this realm declares [MaxWindowEntries] and refuses a window holding more,
// telling the caller to narrow it. A chunk-and-merge would be cheaper to use
// and would violate the primitive's own stated rule.
//
// # Window selection rests on a premise OWNED BY ANOTHER REALM
//
// Entries are located by binary search over entry ID, which is correct only
// because `At` is non-decreasing in ID. That is not a property of [p/journal],
// which refuses only a negative `at` and one at or before the close cutoff. It
// is a property of [r/books], which dates every entry with
// `runtime.ChainHeight()` at all three of its posting call sites and exposes
// no `at`-taking entrypoint. [r/books] declares the obligation in its own
// package doc.
//
// The failure mode if that premise ever breaks is the dangerous kind: a
// statement over FEWER entries than the window holds, which still balances and
// still reconciles. So the premise is checked rather than assumed —
// [scan] verifies `At` is non-decreasing across every entry it reads (free,
// since each `At` is already in hand) and probes the two entries immediately
// outside the located range to prove the range is maximal. A violation panics
// instead of publishing.
//
// RESIDUAL, stated with its boundary: that makes a violation at or adjacent to
// the window edges loud. A violation deep outside the scanned range is
// invisible without a full scan, which is the cost this design exists to
// avoid. [OpeningReconciled] closes it for the one window shape where the
// cumulative cross-check applies, and nowhere else.
//
// # Entry IDs are relied upon to be dense, and the argument is structural
//
// The binary search indexes entries 1..[books.EntryCount]. That is sound
// because [p/journal] allocates `id := nextID; nextID++` and writes the entry
// immediately, in one function with no error return between the two, into a
// tree that has no delete; a post that fails panics and reverts the whole
// transaction. So there are no gaps and no reuse. It is stated here because it
// is a premise, not an observation: [EntryInfo] panics on an absent ID, so a
// gap would abort the scan loudly rather than skew a figure.
//
// # A reversal lands in the period it was MADE
//
// [r/books] dates a reversing entry at the current height, not at the reversed
// entry's date, and [p/cashflow] deliberately does not special-case reversals:
// a reversing entry that touches cash moved cash. So reversing a prior-period
// entry shows as movement in the CURRENT period and the corrected period's
// published statement does not change. That is right for a cash-flow statement
// and surprising to a reader expecting otherwise, which is why it is here.
//
// # NO CUSTODY, and no re-derivation seal
//
// There is no coinio import, no payable path, no fee, no withdrawal, no admin.
// [Publish] and [DeclarePolicy] refuse a transaction carrying coins.
//
// There is deliberately NO `Verify` accessor re-deriving a stored report and
// comparing. For a window that closed before the publication height such a
// check is a CONSTANT TRUE by construction: entries are dated at the chain
// height and the journal is append-only, so no entry can later fall into a
// closed window, and the chart cannot lose an account. Shipping it would be
// the fifth instance of the vacuous-true class this project keeps finding in
// its own work. What ships instead is [Rescan], whose non-vacuity is exact and
// narrow: it re-locates the window NOW and so tests the selection premise
// above, not the ledger's contents.
//
// # No cross-owner aggregate beyond a count
//
// [r/books] scopes every read to one owner, and a cash-flow statement mixing
// owners would assert a claim no single owner can make. [Total] is a count and
// there is no way to enumerate publishers.
//
// # Limits, stated plainly
//
//   - `opening` is caller-supplied, and verified only where
//     [OpeningReconciled] says it was.
//   - The policy is caller-declared and is the trust boundary. A wrong cash
//     declaration yields a plausible, wrong statement and no on-chain check
//     here can detect it.
//   - The cost bound is reasoned against a live precedent ([r/statements]
//     performs roughly 130 cross-realm reads per report), not measured in gas.
//   - Memos and account codes and names are an owner's free text in [r/books]
//     and are unsanitized there. Every one of them goes through [cell] before
//     it reaches [Render].
//   - The chart reconstruction here is a second copy of [r/statements]'
//     unexported `chartOf`. Promoting it would modify a live realm.
//
// [r/books]: /r/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/books
// [r/statements]: /r/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/statements
// [p/cashflow]: /p/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/cashflow
// [p/journal]: /p/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/journal
// [p/periods]: /p/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/periods
package cashflow

import (
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"strings"

	cf "gno.land/p/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/cashflow"
	"gno.land/p/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/journal"
	"gno.land/p/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/periods"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/r/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/books"
)

// RealmPath is this realm's own path, used to build Render links.
const RealmPath = "/r/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/cashflow"

// BooksPath is the ledger realm every entry here is read from.
//
// Taken BY VALUE from that realm's own exported constant rather than typed out
// again, so this is the compile-time pin itself and not a second copy that
// could drift. A reader checking which ledger a statement describes is reading
// the import.
const BooksPath = books.RealmPath

// MaxWindowEntries bounds how many entries one [Publish] may read.
//
// This is the §7.4 refusal bound and the number has a derivation rather than a
// feel. Reading one entry costs TWO cross-realm reads — [books.EntryInfo] for
// the header and [books.EntryLegs] for the postings — because r/books returns
// them separately. Add the chart reconstruction, which is one [books.Accounts],
// one [books.Codes] at the chart cap and one [books.AccountInfo] per account,
// and the live precedent [r/statements] pays about 130 reads per report. Add
// the search: 2*ceil(log2(N+1)) + 4 header reads to locate and prove the range.
//
// At 256 the whole publish is about 666 plain reads, roughly five times a
// report [r/statements] performs on this chain today. At r/books' own entry cap
// of 4096 it would be about 8,350, which is the figure the discovery gate for
// r/receivables used to defer this product.
//
// It is a REFUSAL and not a truncation: a window holding more entries than this
// panics and names the count, and the caller narrows the window. Publishing a
// statement over a silently-truncated entry set is the one failure this product
// is least able to detect, because a short statement still balances.
const MaxWindowEntries = 256

// PolicyIsReplaceable records a decision a reader will look for.
//
// [DeclarePolicy] overwrites an owner's previous declaration and keeps no
// history of it. That is safe only because every [Publish] FREEZES a copy of
// the policy it used into the record: a published statement is readable with
// the classification that produced it forever, via [PolicyOf], and changing
// the live policy cannot restate a published figure.
//
// The alternative — versioned policies with reports pointing at a version — is
// the same information with an extra indirection and one more place for the
// two to disagree.
const PolicyIsReplaceable = true

// PublicationsAreUncapped mirrors [r/statements]' decision for the same three
// reasons, which hold here unchanged: keys are per owner so an owner can only
// fill their own history; no accessor and no [Render] path walks a publisher's
// whole history; and there is no engine cap above this realm to mirror.
const PublicationsAreUncapped = true

// RenderPublicationLimit caps how many of a publisher's statements one
// [Render] call lists.
const RenderPublicationLimit = 20

// RenderCensusLimit caps how many unresolved or net-zero rows one [Render]
// call emits. A window may hold [MaxWindowEntries] entries and in a book with
// no policy rules every one of them is unresolved.
const RenderCensusLimit = 25

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

// policy is one owner's frozen declaration. The slices are allocated here from
// the caller's parsed strings and never handed out: [PolicyCash] and
// [PolicyRules] re-encode them into a fresh string.
type policy struct {
	cash  []string
	rules []cf.Classification
	at    int64
}

// record is one frozen statement.
//
// It stores the [cf.Report] whole rather than copying its fields into a
// parallel struct — a second field set is a second place for the two to
// disagree — plus the three things the report cannot carry: the policy that
// produced it, the entry-ID range that was read, and the cumulative
// cross-check result.
//
// There is deliberately no seq field. Every read path reaches a record by
// constructing pubKey from a seq it already holds, so a stored copy would only
// ever be checked against its own source. [r/statements] records the same
// decision and the reason it was found: a sabotage harness could not make
// dropping the assignment fail any test.
type record struct {
	at  int64
	rep cf.Report
	pol policy

	// lo and hi are the inclusive entry-ID range read. hi < lo means the
	// window held no entries, which is a legitimate quiet period.
	lo uint64
	hi uint64

	// reconciled is whether the cumulative cross-check APPLIED. It is never
	// stored false-after-failing: a failed check panics in [Publish], so this
	// distinguishes "checked and agreed" from "not checkable", never
	// "checked and disagreed".
	reconciled bool

	// cash is the declared cash accounts' summed balance at publication, read
	// from [books.Balance]. Meaningful only when reconciled.
	cash int64
}

// policies maps an owner's address string to *policy.
var policies = avl.NewTree()

// published maps "<owner>|<padded seq>" to *record.
//
// The pointer never leaves this file. Every accessor copies scalars out, so no
// caller receives a handle onto stored state.
var published = avl.NewTree()

// counts maps an owner's address string to how many statements they have
// published. It is the sequence allocator as well as the count.
var counts = avl.NewTree()

// pubCount is the global total, maintained alongside the tree so the index
// page never iterates.
var pubCount int

// ---------------------------------------------------------------------------
// Guards
// ---------------------------------------------------------------------------

// refuseCoins panics if a direct caller attached coins.
//
// This realm has no banker, no withdrawal path and nothing that can spend what
// arrives, so a silently-accepted send would be stranded permanently and "we
// hold no funds" would be true of the design and false of the balance.
//
// The residual is stated rather than guarded: coins can still reach this
// realm's address through an intermediary's explicit banker send, which no
// predicate here can see. What makes that survivable is the absence of any
// consumption path, not this guard.
//
// The IsCurrent check is a no-op at both of today's call sites — a crossing
// function's first `cur` is runtime-current by construction and stays current
// when forwarded through a non-crossing call. It is here because this realm is
// IMMUTABLE after addpkg, so a future third caller cannot be made safe later,
// and a helper that reads Previous() off an unchecked realm parameter is a
// designation-forgery shape whether or not it is reachable today.
func refuseCoins(cur realm) {
	if !cur.IsCurrent() {
		panic("cashflow: refuseCoins called with a realm that is not current")
	}
	if cur.Previous().IsUserCall() && len(unsafe.OriginSend()) > 0 {
		panic("cashflow: this realm holds no coins and has no withdrawal path; send none")
	}
}

// ---------------------------------------------------------------------------
// The cross-realm reads
// ---------------------------------------------------------------------------

// parseKind turns one of [r/books]' five kind words back into a
// [journal.Kind] and PANICS on anything else.
//
// This is the same seam [r/statements] names in its own copy, and the reason
// it panics is the same and is specific: the zero [journal.Kind] is reported
// CREDIT-NORMAL by IsDebitNormal, so a silently-unparsed word would not drop
// the row — it would misfile it and produce a statement that balances and
// misstates. The five words are that type's own String output, and the suite
// pins the round trip over all five rather than trusting it to stay true.
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
	panic("cashflow: " + BooksPath + " reported an unknown account kind " +
		strconv.Quote(s))
}

// chartOf reads the owner's whole chart of accounts in one pass.
//
// ONE call for the codes, at r/books' own account cap. That iterator has no
// seek and honours `from` by skipping, so one call walks the whole chart
// however small the limit is — paging it would cost ceil(n/limit) full walks,
// and [books.Codes]' `from` is INCLUSIVE so every paging caller also owes
// itself a boundary dedup. A missed one double-counts an account, and a
// double-counted balance is a defect this product cannot see: the statement
// would still balance.
//
// The agreement check is not decoration. [books.Accounts] and [books.Codes]
// are two reads through different code paths; if they disagree this refuses
// rather than deriving over a truncated chart, because [cf.Derive] rejects a
// posting naming an account absent from the chart and a truncated chart turns
// an ordinary entry into ErrUnknownAccount pointing at the wrong layer.
//
// TAINT: the []string [books.Codes] returns was allocated under that realm and
// arrives readonly-tainted. Nothing here mutates it or stores it — codes are
// read out by value and the rows are allocated here.
//
// This is a second copy of [r/statements]' unexported chartOf, forced: that
// realm is live and §6 forbids modifying it to promote the helper.
func chartOf(owner address) []journal.Account {
	n := books.Accounts(owner) // panics if the owner has no book
	codes := books.Codes(owner, "", books.MaxAccountsPerBook)
	if len(codes) != n {
		panic("cashflow: " + BooksPath + " reports " + strconv.Itoa(n) +
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
		// State its reach exactly, because the flattering reading is
		// available: BOTH sides are journal.Account.Balance over the same two
		// columns, so this is a CONSTANT TRUE against any disagreement between
		// the two realms' arithmetic and must never be quoted as cross-checking
		// it. What it catches is a transcription error in the four assignments
		// above — swapping Debits and Credits, or reading a column off the
		// wrong code — which is this realm's own code and the only place in
		// this path where that could happen.
		if a.Balance() != balance {
			panic("cashflow: balance mismatch for account " + code +
				"; this realm transcribed the chart wrongly")
		}
		rows = append(rows, a)
	}
	return rows
}

// lowerBound is the smallest entry ID in 1..n whose At is >= target, or n+1 if
// there is none.
//
// Correct only under the non-decreasing-At premise in the package doc. A
// violation makes this land somewhere arbitrary rather than wrong-by-one,
// which is why [scan] probes the located boundaries rather than trusting the
// result.
func lowerBound(owner address, n uint64, target int64) uint64 {
	lo, hi := uint64(1), n+1
	for lo < hi {
		mid := lo + (hi-lo)/2
		at, _, _, _, _ := books.EntryInfo(owner, mid)
		if at >= target {
			hi = mid
		} else {
			lo = mid + 1
		}
	}
	return lo
}

// scan locates and reads every entry in w, and returns them with the inclusive
// ID range and whether the window extends past every entry the book holds.
//
// The last return value is what makes the cumulative cross-check sound; see
// [OpeningReconciled]. It is true for an empty book as well, where every
// balance is necessarily zero because balances come only from postings.
//
// Every check here is a panic rather than a return, because this is reached
// from a mutating path and in Gno only a panic reverts a transaction.
func scan(owner address, w periods.Window) ([]journal.Entry, uint64, uint64, bool) {
	n := books.EntryCount(owner) // panics if the owner has no book
	if n == 0 {
		return nil, 1, 0, true
	}
	last := uint64(n)

	firstAt, _, _, _, _ := books.EntryInfo(owner, 1)
	lastAt, _, _, _, _ := books.EntryInfo(owner, last)
	if lastAt < firstAt {
		panic("cashflow: " + BooksPath + " entry 1 is dated " +
			strconv.FormatInt(firstAt, 10) + " and entry " +
			strconv.FormatUint(last, 10) + " is dated " +
			strconv.FormatInt(lastAt, 10) +
			"; entry dates are not non-decreasing and window selection is unsound")
	}
	pastEnd := w.Until > lastAt

	lo := lowerBound(owner, last, w.From)
	hi := lowerBound(owner, last, w.Until) - 1

	// THERE ARE NO MAXIMALITY PROBES HERE, DELIBERATELY. Two used to sit at
	// this point — reading the entry just below lo and the entry just above hi
	// and refusing if either fell inside the window — and they were REMOVED
	// because they are tautologies that can never fire. Both probed conditions
	// are negations of [lowerBound]'s own loop invariants:
	//
	//	hi is only ever assigned a mid at which at(mid) >= target was
	//	OBSERVED, so an exit value L <= n carries at(L) >= target, and
	//	`at(hi+1) < w.Until` is unreachable.
	//	lo is only ever assigned mid+1 at which at(mid) < target was
	//	OBSERVED, so an exit value L > 1 carries at(L-1) < target, and
	//	`at(lo-1) >= w.From` is unreachable.
	//
	// Neither derivation uses the non-decreasing-At premise, which is what
	// makes them dead rather than merely redundant: they were written to catch
	// a VIOLATION of that premise and are vacuous in exactly that case. They
	// cost two cross-realm reads per Publish and advertised a guarantee they
	// never provided. Measured, with a sabotage control, in
	// TestLowerBoundsPostconditionsHoldOverAScrambledBook.
	//
	// WHAT CATCHES A MISLOCATED RANGE INSTEAD, all three live and pinned:
	//   - the endpoint check above, when entry 1 outranks entry n;
	//   - the `at < prev` check in the read loop below;
	//   - the `!w.Contains(at)` check in the read loop below, which is the one
	//     that fires on the common dip case.
	// And when a dip makes the search return an EMPTY range — hi < lo, so the
	// loop never runs and none of the three can speak — the net is Publish's
	// cumulative cross-check against the live cash balance, which is why that
	// check is not an optional nicety. See [OpeningReconciled] for its scope,
	// and note the residual honestly: a window that does not extend past the
	// last entry has no cumulative check, so a dip that produces an empty
	// range inside a closed window is under-reported and only
	// OpeningReconciled's false reading discloses it.
	if hi < lo {
		return nil, lo, hi, pastEnd
	}
	count := hi - lo + 1
	if count > uint64(MaxWindowEntries) {
		panic("cashflow: the window holds " + strconv.FormatUint(count, 10) +
			" entries and the limit is " + strconv.Itoa(MaxWindowEntries) +
			"; narrow the window. This realm refuses rather than reading a " +
			"partial set, because a statement over fewer entries than the " +
			"window holds still balances")
	}

	out := make([]journal.Entry, 0, int(count))
	prev := int64(-1)
	for id := lo; id <= hi; id++ {
		at, memo, legs, reversalOf, total := books.EntryInfo(owner, id)
		if at < prev {
			panic("cashflow: entry " + strconv.FormatUint(id, 10) + " is dated " +
				strconv.FormatInt(at, 10) + " after entry " +
				strconv.FormatUint(id-1, 10) + " dated " +
				strconv.FormatInt(prev, 10) +
				"; entry dates are not non-decreasing and window selection is unsound")
		}
		prev = at
		if !w.Contains(at) {
			panic("cashflow: entry " + strconv.FormatUint(id, 10) + " is dated " +
				strconv.FormatInt(at, 10) + " and is outside the window; the " +
				"located range is wrong")
		}
		e := journal.Entry{
			ID:         id,
			At:         at,
			Memo:       memo,
			Postings:   parseLegs(owner, id, books.EntryLegs(owner, id)),
			ReversalOf: reversalOf,
		}
		if len(e.Postings) != legs {
			panic("cashflow: entry " + strconv.FormatUint(id, 10) + " reports " +
				strconv.Itoa(legs) + " legs and encoded " +
				strconv.Itoa(len(e.Postings)) + "; refusing a partial entry")
		}
		// Same reach as chartOf's balance check and worth the same caution:
		// both sides are journal.Entry.Total over the same postings, so this
		// catches a decoding error in parseLegs — a dropped leg, a flipped
		// side, a misparsed amount — and is NOT a cross-check of r/books'
		// arithmetic. A flipped side is the one that matters: it inverts the
		// cash direction of the leg and the statement would still reconcile.
		if e.Total() != total {
			panic("cashflow: entry " + strconv.FormatUint(id, 10) +
				" totals " + strconv.FormatInt(e.Total(), 10) +
				" as decoded and " + strconv.FormatInt(total, 10) +
				" as reported; this realm decoded the legs wrongly")
		}
		out = append(out, e)
	}
	return out, lo, hi, pastEnd
}

// parseLegs decodes the "code:side:amount,..." form [books.EntryLegs] returns.
//
// That form is [books.PostMulti]'s input format, so this is the inverse of a
// parser living in the realm the string came from. It is duplicated rather
// than shared for the same reason chartOf is: r/books is live.
//
// It is STRICTER than r/books' own parser in one direction and deliberately
// so. r/books accepts "D", "DR" and "DEBIT" for a side because a human types
// its input; [books.EntryLegs] emits only "D" or "C", so anything else here
// means the format changed underneath this realm and the right outcome is a
// refusal rather than a tolerant read. It is not stricter about leg count:
// r/books refuses fewer than two on the way IN, and re-asserting that on the
// way out would duplicate another realm's invariant in a place that cannot
// enforce it.
func parseLegs(owner address, id uint64, legs string) []journal.Posting {
	where := " in entry " + strconv.FormatUint(id, 10) + " of " + owner.String()
	if legs == "" {
		panic("cashflow: " + BooksPath + " returned no legs" + where)
	}
	parts := strings.Split(legs, ",")
	if len(parts) > journal.MaxPostingsPerEntry {
		panic("cashflow: " + strconv.Itoa(len(parts)) + " legs" + where +
			" exceeds journal.MaxPostingsPerEntry")
	}
	out := make([]journal.Posting, 0, len(parts))
	for i, raw := range parts {
		at := " at leg " + strconv.Itoa(i+1) + where
		f := strings.Split(raw, ":")
		if len(f) != 3 {
			panic("cashflow: expected code:side:amount" + at)
		}
		if f[0] == "" {
			panic("cashflow: empty account code" + at)
		}
		var side journal.Side
		switch f[1] {
		case "D":
			side = journal.Debit
		case "C":
			side = journal.Credit
		default:
			panic("cashflow: " + BooksPath + " encoded side " +
				strconv.Quote(f[1]) + at + "; want D or C")
		}
		amount, err := strconv.ParseInt(f[2], 10, 64)
		if err != nil {
			panic("cashflow: amount is not an integer" + at)
		}
		if amount <= 0 {
			panic("cashflow: amount must be positive" + at)
		}
		out = append(out, journal.Posting{Account: f[0], Side: side, Amount: amount})
	}
	return out
}

// liveCash sums the declared cash accounts' balances now.
//
// Every cash code is a [journal.Asset] — [cf.Derive] refuses a policy that
// declares a non-asset as cash — so each balance is debit-normal and the sum
// is the book's cumulative net cash movement since its first posting. That is
// the figure [OpeningReconciled] compares against.
func liveCash(owner address, cash []string) int64 {
	total := int64(0)
	for _, code := range cash {
		b, ok := books.Balance(owner, code)
		if !ok {
			panic("cashflow: declared cash account " + code +
				" is not in the owner's chart")
		}
		sum, ok2 := checkedAdd(total, b)
		if !ok2 {
			panic("cashflow: the declared cash accounts' balances overflow int64")
		}
		total = sum
	}
	return total
}

// ---------------------------------------------------------------------------
// Declaring a policy
// ---------------------------------------------------------------------------

// DeclarePolicy records the caller's own classification policy for their own
// book, replacing any previous one.
//
// `cash` is a comma-separated list of account codes that hold cash, strictly
// ascending — for example `1010,1020`. It must be non-empty and every code
// must be an asset in the caller's chart.
//
// `rules` is a comma-separated list of `code:category` pairs, strictly
// ascending by code, where category is `operating`, `investing` or
// `financing` — for example `4000:operating,1500:investing,3000:financing`.
// A code absent from `rules` is NOT defaulted to anything: an entry touching
// it is reported unresolved, by name, because a default bucket turns a missing
// declaration into a figure nobody questions. `rules` may be empty.
//
// The owner is `cur.Previous().Address()` and there is NO owner parameter.
// [r/books] derives a book's owner the same way and no mutating function there
// takes one either, so the only party who can declare a policy for a book is
// the only party who can write to it. An owner parameter would move the trust
// boundary to whoever called this.
//
// The declaration is validated against the caller's LIVE chart by deriving
// over an empty entry set: [cf.Derive] validates the window, the chart and the
// policy before it reads an entry, so a nil entry slice exercises exactly the
// declaration's validity and nothing else. A policy that is valid now stays
// valid, because [r/books] has no way to remove an account from a chart.
func DeclarePolicy(cur realm, cash, rules string) {
	refuseCoins(cur)
	owner := cur.Previous().Address()

	c := parseCash(cash)
	r := parseRules(rules)

	if _, err := cf.Derive(
		chartOf(owner), nil,
		periods.Window{From: 0, Until: 1},
		cf.Policy{Cash: c, Rules: r},
		0,
	); err != nil {
		panic("cashflow: " + err.Error())
	}

	policies.Set(owner.String(), &policy{
		cash:  c,
		rules: r,
		at:    runtime.ChainHeight(),
	})
}

// parseCash decodes the cash-code list. Order and duplication are NOT checked
// here: [cf.Derive]'s validatePolicy requires strictly ascending codes and
// says so with its own error, and a second copy of that rule here would be a
// second place for the two to disagree.
func parseCash(cash string) []string {
	if cash == "" {
		panic("cashflow: no cash accounts declared; format is \"1010,1020\"")
	}
	parts := strings.Split(cash, ",")
	if len(parts) > books.MaxAccountsPerBook {
		panic("cashflow: " + strconv.Itoa(len(parts)) +
			" cash codes exceeds books.MaxAccountsPerBook")
	}
	out := make([]string, 0, len(parts))
	for i, raw := range parts {
		code := strings.TrimSpace(raw)
		if code == "" {
			panic("cashflow: empty cash code at position " + strconv.Itoa(i+1))
		}
		out = append(out, code)
	}
	return out
}

// parseRules decodes the code:category list. An empty string is a legitimate
// empty policy — every entry touching a non-cash account is then unresolved,
// which is a true report of a book whose owner has declared nothing.
func parseRules(rules string) []cf.Classification {
	if strings.TrimSpace(rules) == "" {
		return nil
	}
	parts := strings.Split(rules, ",")
	if len(parts) > books.MaxAccountsPerBook {
		panic("cashflow: " + strconv.Itoa(len(parts)) +
			" rules exceeds books.MaxAccountsPerBook")
	}
	out := make([]cf.Classification, 0, len(parts))
	for i, raw := range parts {
		at := " at rule " + strconv.Itoa(i+1)
		f := strings.Split(strings.TrimSpace(raw), ":")
		if len(f) != 2 {
			panic("cashflow: expected code:category" + at)
		}
		code := strings.TrimSpace(f[0])
		if code == "" {
			panic("cashflow: empty account code" + at)
		}
		out = append(out, cf.Classification{
			Code:     code,
			Category: parseCategory(strings.TrimSpace(f[1])),
		})
	}
	return out
}

// parseCategory turns a category word into a [cf.Category] and panics on
// anything else. The three words are that type's own String output; the suite
// pins the round trip over all three rather than trusting another package's
// method to stay put.
//
// It panics rather than returning the zero Category because the zero value is
// deliberately invalid in [p/cashflow] and a silently-zero rule would reach
// validatePolicy as ErrInvalidCategory, pointing a reader at the wrong layer.
func parseCategory(s string) cf.Category {
	switch s {
	case "operating":
		return cf.CategoryOperating
	case "investing":
		return cf.CategoryInvesting
	case "financing":
		return cf.CategoryFinancing
	}
	panic("cashflow: unknown category " + strconv.Quote(s) +
		"; want operating, investing or financing")
}

// ---------------------------------------------------------------------------
// Publishing
// ---------------------------------------------------------------------------

// Publish freezes a statement of cash flows over [from, until) and returns its
// sequence number, which counts from 1 per publisher.
//
// The window is half-open: `from` is included and `until` is not. The unit is
// whatever [r/books] dates with, which is block height.
//
// `opening` is the caller's declared opening cash position. It cannot be
// derived from a windowed entry set and is echoed into the report unchanged;
// see [OpeningReconciled] for the one window shape where this realm can and
// does check it.
//
// The owner is `cur.Previous().Address()`. There is NO owner parameter and no
// way to publish over someone else's book, for the reason given at
// [DeclarePolicy].
//
// It PANICS, rather than returning an error, on: no book, no declared policy,
// an invalid window, a window holding more than [MaxWindowEntries] entries, a
// violation of the entry-dating premise at either window edge, a disagreement
// between the chart's two reads or an entry's two reads, any [cf.Derive] error,
// and a failed cumulative cross-check. An error return would not revert a Gno
// transaction; only a panic does.
func Publish(cur realm, from, until, opening int64) int64 {
	refuseCoins(cur)
	owner := cur.Previous().Address()

	pol := mustPolicy(owner)
	w := periods.Window{From: from, Until: until}
	if !w.Valid() {
		panic("cashflow: window [" + strconv.FormatInt(from, 10) + ", " +
			strconv.FormatInt(until, 10) + ") is not a period; want 0 <= from < until")
	}

	chart := chartOf(owner)
	entries, lo, hi, pastEnd := scan(owner, w)

	// A COPY of the stored policy goes to Derive, not the stored slices. The
	// primitive does not mutate a Policy, but handing stored state to code in
	// another package is the kind of thing that stays safe only until that
	// package changes, and this realm is immutable after addpkg.
	rep, err := cf.Derive(chart, entries, w, cf.Policy{
		Cash:  copyCodes(pol.cash),
		Rules: copyRules(pol.rules),
	}, opening)
	if err != nil {
		panic("cashflow: " + err.Error())
	}

	// Derive filters the window itself, so this asserts that the scan handed
	// it exactly the window's entries and nothing it had to discard. A
	// disagreement would mean scan's range check above is wrong, and the two
	// are independent code.
	if rep.Entries != len(entries) {
		panic("cashflow: " + strconv.Itoa(len(entries)) +
			" entries were read and the report counts " +
			strconv.Itoa(rep.Entries) + " in the window")
	}

	// THE CUMULATIVE CROSS-CHECK. Sound only when the window extends past
	// every entry the book holds: then the window's net change plus a correct
	// opening is the book's whole cash movement, which is what the declared
	// cash accounts' balances sum to. See [OpeningReconciled] for why a
	// failure is a refusal rather than a flag on the record.
	live := int64(0)
	if pastEnd {
		live = liveCash(owner, pol.cash)
		if live != rep.Closing {
			panic("cashflow: refusing to publish. The window extends past every " +
				"entry in the book, so the declared opening of " +
				strconv.FormatInt(opening, 10) + " plus the window's net change of " +
				strconv.FormatInt(rep.NetChange, 10) + " should equal the declared " +
				"cash accounts' balance of " + strconv.FormatInt(live, 10) +
				", and it is " + strconv.FormatInt(rep.Closing, 10) +
				". Either the opening is wrong or the entry scan is incomplete")
		}
	}

	seq := int64(ownerCount(owner.String()) + 1)
	published.Set(pubKey(owner.String(), seq), &record{
		at:         runtime.ChainHeight(),
		rep:        rep,
		pol:        policy{cash: copyCodes(pol.cash), rules: copyRules(pol.rules), at: pol.at},
		lo:         lo,
		hi:         hi,
		reconciled: pastEnd,
		cash:       live,
	})
	counts.Set(owner.String(), int(seq))
	pubCount++
	return seq
}

// ---------------------------------------------------------------------------
// Reading a published statement
// ---------------------------------------------------------------------------

// Count is how many statements an owner has published.
func Count(owner address) int { return ownerCount(owner.String()) }

// Latest is the newest sequence number for an owner, and false if they have
// published none.
func Latest(owner address) (int64, bool) {
	n := ownerCount(owner.String())
	if n == 0 {
		return 0, false
	}
	return int64(n), true
}

// Total is how many statements every publisher has published together. There
// is deliberately no way to enumerate the publishers; see the package doc.
func Total() int { return pubCount }

// Has reports whether a statement exists.
func Has(owner address, seq int64) bool {
	return published.Has(pubKey(owner.String(), seq))
}

// PublishedAt is the block height a statement was frozen at.
func PublishedAt(owner address, seq int64) int64 {
	return mustRecord(owner, seq).at
}

// Window is the period a statement covers, half-open: `from` is in, `until` is
// out.
func Window(owner address, seq int64) (from, until int64) {
	w := mustRecord(owner, seq).rep.Window
	return w.From, w.Until
}

// Totals is the four cumulative figures. `closing` is `opening + netChange`,
// and `opening` was supplied by the publisher — see [OpeningReconciled] for
// whether this realm was able to check it.
//
// `unattributed` is the net movement of the entries in the unresolved census
// and is part of `netChange`, not additional to it.
func Totals(owner address, seq int64) (opening, netChange, unattributed, closing int64) {
	r := mustRecord(owner, seq).rep
	return r.Opening, r.NetChange, r.Unattributed, r.Closing
}

// LineOf is one category's gross flows. `category` is `operating`, `investing`
// or `financing`; anything else panics.
//
// Inflows and outflows are GROSS and both non-negative. A category with 1,000
// in and 1,000 out is not the same business as one with nothing happening, and
// a net of zero is all a netted figure could say about either.
func LineOf(owner address, seq int64, category string) (inflows, outflows, net int64, entries int) {
	l, err := mustRecord(owner, seq).rep.Line(parseCategory(category))
	if err != nil {
		panic("cashflow: " + err.Error())
	}
	return l.Inflows, l.Outflows, l.Net(), l.Entries
}

// Scope is the statement's own coverage line, and it is the thing to read
// before quoting any figure above.
//
//   - `entries` is how many entries fell in the window, including the ones
//     that moved no cash. Zero is a quiet period, not an error.
//   - `cashEntries` is how many touched a declared cash account at all.
//   - `netZero` is how many touched cash and moved none on net — a transfer
//     between two cash accounts. Classification is not attempted for them:
//     there is nothing to attribute.
//   - `unresolved` is how many could not be classified. A statement with
//     unresolved entries is still arithmetically whole — the residual is in
//     `unattributed` — but its SPLIT is incomplete.
func Scope(owner address, seq int64) (entries, cashEntries, netZero, unresolved int) {
	r := mustRecord(owner, seq).rep
	return r.Entries, r.CashEntries, len(r.NetZero), len(r.Unresolved)
}

// EntryRange is the inclusive [r/books] entry-ID range this statement was
// derived from. `ok` is false when the window held no entries.
//
// It is stored because it is the evidence for the statement's scope: a reader
// can take the two IDs to [r/books] and read the entries themselves. A
// statement is the only artifact here, and this is what makes it checkable
// against its source.
func EntryRange(owner address, seq int64) (lo, hi uint64, ok bool) {
	r := mustRecord(owner, seq)
	if r.hi < r.lo {
		return 0, 0, false
	}
	return r.lo, r.hi, true
}

// Complete reports whether every in-window entry that moved cash was
// attributed to a category.
//
// A complete statement is not a correct one. Completeness is a property of the
// POLICY's coverage, and a policy that classifies every account wrongly is
// complete. [p/cashflow] says this of its own accessor and it is worth
// repeating at the realm boundary, where the word will be quoted.
func Complete(owner address, seq int64) bool {
	return mustRecord(owner, seq).rep.Complete()
}

// Reconciles reports whether the attributed lines plus the unattributed
// residual equal the net change.
//
// On a statement published here it is ALWAYS TRUE, because [cf.Derive]
// produces it that way and nothing between there and storage touches the
// figures. It is exposed anyway, and the reason is narrow: it is the one check
// a reader can run against a stored report without re-reading the ledger, and
// an exposed constant-true that is DOCUMENTED as one is better than a reader
// assuming the invariant holds without ever being told where it comes from.
// It must not be quoted as evidence that a statement is right.
func Reconciles(owner address, seq int64) bool {
	return mustRecord(owner, seq).rep.Reconciles()
}

// OpeningReconciled reports whether this realm was able to check the
// publisher's declared opening position against the ledger — and, because a
// failed check REFUSES to publish, it being true means the check passed.
//
// # When it applies
//
// Only when the window extended past every entry the book held at publication.
// Then the window's net change covers all movement from `from` onward, the
// declared cash accounts' summed balance covers all movement ever, and the
// difference between them is exactly the movement before `from` — which is
// what a correct opening is. An empty book qualifies too: with no postings
// every balance is zero, so the check requires an opening of zero.
//
// It does NOT apply to a window that closed before later entries were posted.
// There the balances carry post-window movement the statement rightly excludes,
// and comparing them would be comparing two different periods.
//
// # What it proves, and the second thing it proves
//
// First, that the declared opening is consistent with the ledger. Second — and
// this is why it is worth its cost — that THE ENTRY SCAN WAS COMPLETE. A scan
// that silently missed entries produces a short net change, and a short net
// change fails this comparison. That is the one mechanical control this realm
// has against the silent-under-reporting failure mode the package doc names,
// and it covers exactly the window shape where it is available.
//
// # What it does not prove
//
// Nothing about whether the codes called cash hold cash. Both sides of the
// comparison are the same owner's self-report, read through the same realm.
// It is an internal consistency check, not a custody attestation.
func OpeningReconciled(owner address, seq int64) bool {
	return mustRecord(owner, seq).reconciled
}

// ReconciledCash is the declared cash accounts' summed balance at publication,
// and false if [OpeningReconciled] does not apply to this statement. The
// figure is meaningless when ok is false and is returned as zero.
func ReconciledCash(owner address, seq int64) (int64, bool) {
	r := mustRecord(owner, seq)
	if !r.reconciled {
		return 0, false
	}
	return r.cash, true
}

// UnresolvedCount is how many entries could not be classified.
func UnresolvedCount(owner address, seq int64) int {
	return len(mustRecord(owner, seq).rep.Unresolved)
}

// UnresolvedAt is one unresolved entry, by index into the census.
//
//   - `reason` is `conflict` (the non-cash legs classify to more than one
//     category), `undeclared` (a non-cash leg's account has no policy rule) or
//     `unbalanced`.
//   - `net` is the entry's net cash movement, which is real movement the
//     statement could not attribute.
//   - `categories` is the conflicting categories, comma-separated, for a
//     conflict.
//   - `codes` is the undeclared account codes, comma-separated, for an
//     undeclared entry. Declaring them may resolve the entry, which is why
//     `undeclared` takes precedence over `conflict` when both apply.
func UnresolvedAt(owner address, seq int64, i int) (id uint64, reason string, net int64, categories, codes string) {
	rows := mustRecord(owner, seq).rep.Unresolved
	if i < 0 || i >= len(rows) {
		panic("cashflow: unresolved index " + strconv.Itoa(i) + " out of range 0.." +
			strconv.Itoa(len(rows)-1))
	}
	u := rows[i]
	cats := make([]string, 0, len(u.Categories))
	for _, c := range u.Categories {
		cats = append(cats, c.String())
	}
	return u.EntryID, u.Reason.String(), u.Net,
		strings.Join(cats, ","), strings.Join(u.Codes, ",")
}

// NetZeroCount is how many in-window entries touched cash and moved none on
// net.
func NetZeroCount(owner address, seq int64) int {
	return len(mustRecord(owner, seq).rep.NetZero)
}

// NetZeroAt is one net-zero entry's ID, by index.
func NetZeroAt(owner address, seq int64, i int) uint64 {
	ids := mustRecord(owner, seq).rep.NetZero
	if i < 0 || i >= len(ids) {
		panic("cashflow: net-zero index " + strconv.Itoa(i) + " out of range 0.." +
			strconv.Itoa(len(ids)-1))
	}
	return ids[i]
}

// PolicyOf is the classification policy that produced a published statement,
// re-encoded in [DeclarePolicy]'s own input format.
//
// It is the statement's policy, frozen with it, NOT the owner's current one.
// [PolicyIsReplaceable] explains why both exist: a reader of a published
// figure needs the declaration that produced it, and an owner needs to be able
// to correct a declaration without restating history.
func PolicyOf(owner address, seq int64) (cash, rules string) {
	p := mustRecord(owner, seq).pol
	return encodeCash(p.cash), encodeRules(p.rules)
}

// ---------------------------------------------------------------------------
// Reading the live ledger
// ---------------------------------------------------------------------------

// HasPolicy reports whether an owner has declared a policy.
func HasPolicy(owner address) bool { return policies.Has(owner.String()) }

// PolicyCash is the owner's CURRENT declared cash codes, comma-separated.
func PolicyCash(owner address) string {
	return encodeCash(mustPolicy(owner).cash)
}

// PolicyRules is the owner's CURRENT declared rules, comma-separated
// `code:category` pairs.
func PolicyRules(owner address) string {
	return encodeRules(mustPolicy(owner).rules)
}

// PolicyDeclaredAt is the height the owner's current policy was declared at.
func PolicyDeclaredAt(owner address) int64 { return mustPolicy(owner).at }

// LiveCash is the declared cash accounts' summed balance right now.
//
// This is the book's cumulative net cash movement since its first posting, and
// it is a LIVE figure — it moves with every posting. It is not a published
// statement and must not be quoted as one.
func LiveCash(owner address) int64 {
	return liveCash(owner, mustPolicy(owner).cash)
}

// Rescan re-locates a published statement's window in the ledger NOW and
// reports whether the entry count and the net change still agree with what was
// frozen.
//
// # Why this exists and the re-derivation accessor does not
//
// The package doc says there is no `Verify` here, because re-deriving a
// statement over a window that has closed is a CONSTANT TRUE: entries are
// dated at the chain height and the journal is append-only, so nothing can
// later fall into a closed window.
//
// This is the part of that comparison which is NOT constant. Window selection
// is a binary search resting on a premise owned by [r/books] — that entry
// dates are non-decreasing in entry ID — and nothing freezes that premise.
// A future change there could break it silently. Re-locating the range and
// comparing is therefore a real test of the selection, and it is the only
// check here whose answer can change for a reason that matters.
//
// # What it costs and what it does not cover
//
// It is a plain read, so the caller pays. It re-reads the window's entries,
// which is up to 2*[MaxWindowEntries] cross-realm reads plus the search.
//
// It compares the entry COUNT and the NET CHANGE, not every line. The net
// change is the figure that moves if the entry set changed, and it is derived
// from the postings rather than from the policy, so a disagreement points at
// the ledger or the selection rather than at a reclassification. A false
// return means do not trust the statement and does not say which of the two
// it is.
func Rescan(owner address, seq int64) (entries int, netChange int64, agrees bool) {
	r := mustRecord(owner, seq)
	es, _, _, _ := scan(owner, r.rep.Window)
	rep, err := cf.Derive(chartOf(owner), es, r.rep.Window, cf.Policy{
		Cash:  copyCodes(r.pol.cash),
		Rules: copyRules(r.pol.rules),
	}, r.rep.Opening)
	if err != nil {
		panic("cashflow: " + err.Error())
	}
	return rep.Entries, rep.NetChange,
		rep.Entries == r.rep.Entries && rep.NetChange == r.rep.NetChange
}

// Height is the current block height, so a reader can tell how old a
// statement is without a second query.
func Height() int64 { return runtime.ChainHeight() }

// Ledger is the realm every entry here is read from.
func Ledger() string { return BooksPath }

// ---------------------------------------------------------------------------
// Internals
// ---------------------------------------------------------------------------

// pubKey is owner|paddedSeq. The sequence is left-padded to 19 digits — the
// width of MaxInt64 — so lexicographic order over an owner's prefix is numeric
// order over their statements. An unpadded decimal would sort "10" before "9".
// The convention is r/invoices' invKey, adopted rather than re-derived.
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
		panic("cashflow: no statement " + strconv.FormatInt(seq, 10) +
			" for " + owner.String())
	}
	return r
}

func mustPolicy(owner address) *policy {
	p, ok := policies.Get(owner.String()).(*policy)
	if !ok {
		panic("cashflow: " + owner.String() + " has declared no policy; call " +
			"DeclarePolicy first. Which codes hold cash cannot be guessed and " +
			"a guess would be a figure nobody questions")
	}
	return p
}

func copyCodes(in []string) []string {
	out := make([]string, len(in))
	copy(out, in)
	return out
}

func copyRules(in []cf.Classification) []cf.Classification {
	out := make([]cf.Classification, len(in))
	copy(out, in)
	return out
}

func encodeCash(cash []string) string { return strings.Join(cash, ",") }

func encodeRules(rules []cf.Classification) string {
	parts := make([]string, 0, len(rules))
	for _, r := range rules {
		parts = append(parts, r.Code+":"+r.Category.String())
	}
	return strings.Join(parts, ",")
}

// checkedAdd is int64 addition that reports overflow instead of wrapping.
// Local because a /p/ import for one function would be a dependency this
// realm's closure does not need, and the same four lines appear in p/journal,
// p/periods and p/cashflow.
func checkedAdd(a, b int64) (int64, bool) {
	s := a + b
	if (a > 0 && b > 0 && s < 0) || (a < 0 && b < 0 && s >= 0) {
		return 0, false
	}
	return s, true
}

// ---------------------------------------------------------------------------
// Render
// ---------------------------------------------------------------------------

// Render serves the index at "", a publisher's page at "<address>", and one
// statement at "<address>/<seq>".
//
// Every caller-supplied string reaching this page — an account code, an entry
// memo — is an owner's free text in [r/books] and arrives unsanitized, because
// that realm does not sanitize what it stores. Free text reaching a page
// unescaped is the one injection-shaped surface a realm with no custody still
// has, and the bytes coming from a THIRD realm's state does not make them
// safer. Everything goes through [cell].
func Render(path string) string {
	p := strings.TrimSpace(strings.Trim(path, "/"))
	if p == "" {
		return renderIndex()
	}
	if i := strings.Index(p, "/"); i >= 0 {
		owner := address(p[:i])
		seq, err := strconv.ParseInt(p[i+1:], 10, 64)
		if err != nil {
			return "# Not found\n\nExpected `<address>/<sequence>`.\n"
		}
		return renderStatement(owner, seq)
	}
	return renderPublisher(address(p))
}

func renderIndex() string {
	var sb strings.Builder
	sb.WriteString("# Statements of cash flows\n\n")
	sb.WriteString("Direct-method cash-flow statements derived from books in `")
	sb.WriteString(BooksPath)
	sb.WriteString("`.\n\n")
	sb.WriteString("A statement here is **a claim about a claim**. The entries are read ")
	sb.WriteString("from the ledger rather than supplied, and the arithmetic is ")
	sb.WriteString("`p/cashflow`'s — but which accounts hold *cash* is declared by the ")
	sb.WriteString("book's own owner, and nothing on chain can check that declaration. ")
	sb.WriteString("The opening position is declared too; a statement says whether this ")
	sb.WriteString("realm was able to reconcile it.\n\n")
	sb.WriteString("- Statements published: **")
	sb.WriteString(strconv.Itoa(pubCount))
	sb.WriteString("**\n- Window entry limit: **")
	sb.WriteString(strconv.Itoa(MaxWindowEntries))
	sb.WriteString("** entries — a wider window is refused, never truncated\n- Height: **")
	sb.WriteString(strconv.FormatInt(runtime.ChainHeight(), 10))
	sb.WriteString("**\n\n")
	sb.WriteString("There is no way to enumerate publishers here: a cash-flow statement ")
	sb.WriteString("is one owner's, and an index of them would be a list this realm has ")
	sb.WriteString("no standing to publish. View one at `")
	sb.WriteString(RealmPath)
	sb.WriteString(":<address>`.\n")
	return sb.String()
}

func renderPublisher(owner address) string {
	n := ownerCount(owner.String())
	if n == 0 {
		return "# No statements\n\n`" + cell(owner.String()) +
			"` has published none.\n"
	}
	var sb strings.Builder
	sb.WriteString("# Statements of cash flows\n\n**Publisher:** `")
	sb.WriteString(cell(owner.String()))
	sb.WriteString("`\n\n**Published:** ")
	sb.WriteString(strconv.Itoa(n))
	sb.WriteString("\n\n")

	shown := n
	if shown > RenderPublicationLimit {
		shown = RenderPublicationLimit
	}
	sb.WriteString("| seq | window | net change | closing | entries | unresolved | opening reconciled |\n")
	sb.WriteString("|---|---|---|---|---|---|---|\n")
	for seq := int64(n); seq > int64(n-shown); seq-- {
		r := mustRecord(owner, seq)
		sb.WriteString("| [")
		sb.WriteString(strconv.FormatInt(seq, 10))
		sb.WriteString("](")
		sb.WriteString(RealmPath)
		sb.WriteString(":")
		sb.WriteString(owner.String())
		sb.WriteString("/")
		sb.WriteString(strconv.FormatInt(seq, 10))
		sb.WriteString(") | [")
		sb.WriteString(strconv.FormatInt(r.rep.Window.From, 10))
		sb.WriteString(", ")
		sb.WriteString(strconv.FormatInt(r.rep.Window.Until, 10))
		sb.WriteString(") | ")
		sb.WriteString(strconv.FormatInt(r.rep.NetChange, 10))
		sb.WriteString(" | ")
		sb.WriteString(strconv.FormatInt(r.rep.Closing, 10))
		sb.WriteString(" | ")
		sb.WriteString(strconv.Itoa(r.rep.Entries))
		sb.WriteString(" | ")
		sb.WriteString(strconv.Itoa(len(r.rep.Unresolved)))
		sb.WriteString(" | ")
		sb.WriteString(yesNo(r.reconciled))
		sb.WriteString(" |\n")
	}
	if n > shown {
		sb.WriteString("\n_Showing the newest ")
		sb.WriteString(strconv.Itoa(shown))
		sb.WriteString(" of ")
		sb.WriteString(strconv.Itoa(n))
		sb.WriteString("._\n")
	}
	return sb.String()
}

func renderStatement(owner address, seq int64) string {
	if !published.Has(pubKey(owner.String(), seq)) {
		return "# Not found\n\nNo statement " + strconv.FormatInt(seq, 10) +
			" for `" + cell(owner.String()) + "`.\n"
	}
	r := mustRecord(owner, seq)
	var sb strings.Builder

	sb.WriteString("# Statement of cash flows #")
	sb.WriteString(strconv.FormatInt(seq, 10))
	sb.WriteString("\n\n**Publisher:** `")
	sb.WriteString(cell(owner.String()))
	sb.WriteString("`\n\n**Window:** [")
	sb.WriteString(strconv.FormatInt(r.rep.Window.From, 10))
	sb.WriteString(", ")
	sb.WriteString(strconv.FormatInt(r.rep.Window.Until, 10))
	sb.WriteString(") — half-open, by block height\n\n**Frozen at height:** ")
	sb.WriteString(strconv.FormatInt(r.at, 10))
	sb.WriteString("\n\n**Ledger:** `")
	sb.WriteString(BooksPath)
	sb.WriteString("`\n\n")

	sb.WriteString("## Activities\n\n| category | inflows | outflows | net | entries |\n")
	sb.WriteString("|---|---|---|---|---|\n")
	for _, l := range r.rep.Lines {
		sb.WriteString("| ")
		sb.WriteString(l.Category.String())
		sb.WriteString(" | ")
		sb.WriteString(strconv.FormatInt(l.Inflows, 10))
		sb.WriteString(" | ")
		sb.WriteString(strconv.FormatInt(l.Outflows, 10))
		sb.WriteString(" | ")
		sb.WriteString(strconv.FormatInt(l.Net(), 10))
		sb.WriteString(" | ")
		sb.WriteString(strconv.Itoa(l.Entries))
		sb.WriteString(" |\n")
	}

	sb.WriteString("\n## Reconciliation\n\n| | |\n|---|---|\n| opening (declared) | ")
	sb.WriteString(strconv.FormatInt(r.rep.Opening, 10))
	sb.WriteString(" |\n| net change | ")
	sb.WriteString(strconv.FormatInt(r.rep.NetChange, 10))
	sb.WriteString(" |\n| of which unattributed | ")
	sb.WriteString(strconv.FormatInt(r.rep.Unattributed, 10))
	sb.WriteString(" |\n| closing | ")
	sb.WriteString(strconv.FormatInt(r.rep.Closing, 10))
	sb.WriteString(" |\n\n")

	if r.reconciled {
		sb.WriteString("> **Opening reconciled.** The window extended past every entry ")
		sb.WriteString("in the book, so the declared cash accounts' balance of **")
		sb.WriteString(strconv.FormatInt(r.cash, 10))
		sb.WriteString("** is the whole book's cash movement, and it equals the closing ")
		sb.WriteString("figure above. That also means the entry scan was complete. It ")
		sb.WriteString("says nothing about whether those accounts hold cash.\n\n")
	} else {
		sb.WriteString("> **Opening NOT reconciled.** The window closed before later ")
		sb.WriteString("entries were posted, so the cash accounts' current balances ")
		sb.WriteString("carry movement this statement rightly excludes and cannot be ")
		sb.WriteString("compared to it. The opening position above is the publisher's ")
		sb.WriteString("declaration and this realm did not check it.\n\n")
	}

	sb.WriteString("## Scope\n\n")
	if r.hi < r.lo {
		sb.WriteString("- Entries read: **none** — the window holds no entries\n")
	} else {
		sb.WriteString("- Entries read: **")
		sb.WriteString(strconv.FormatUint(r.hi-r.lo+1, 10))
		sb.WriteString("**, ledger IDs ")
		sb.WriteString(strconv.FormatUint(r.lo, 10))
		sb.WriteString("–")
		sb.WriteString(strconv.FormatUint(r.hi, 10))
		sb.WriteString(" (read them in `")
		sb.WriteString(BooksPath)
		sb.WriteString("` to check this statement against its source)\n")
	}
	sb.WriteString("- In-window entries: **")
	sb.WriteString(strconv.Itoa(r.rep.Entries))
	sb.WriteString("**, of which **")
	sb.WriteString(strconv.Itoa(r.rep.CashEntries))
	sb.WriteString("** touched a declared cash account\n- Window entry limit: **")
	sb.WriteString(strconv.Itoa(MaxWindowEntries))
	sb.WriteString("**\n- Split complete: **")
	sb.WriteString(yesNo(r.rep.Complete()))
	sb.WriteString("**\n\n")

	sb.WriteString("## Policy as published\n\n- Cash accounts: `")
	sb.WriteString(cell(encodeCash(r.pol.cash)))
	sb.WriteString("`\n- Rules: `")
	rules := encodeRules(r.pol.rules)
	if rules == "" {
		rules = "(none declared)"
	}
	sb.WriteString(cell(rules))
	sb.WriteString("`\n- Declared at height: ")
	sb.WriteString(strconv.FormatInt(r.pol.at, 10))
	sb.WriteString("\n\nThis is the policy that produced the figures above, frozen with ")
	sb.WriteString("them. The owner's current policy may differ. A code absent from the ")
	sb.WriteString("rules is not defaulted — an entry touching it is listed below.\n\n")

	sb.WriteString(renderCensus(r))
	return sb.String()
}

func renderCensus(r *record) string {
	var sb strings.Builder

	sb.WriteString("## Unresolved\n\n")
	if len(r.rep.Unresolved) == 0 {
		sb.WriteString("None. Every in-window entry that moved cash was attributed.\n\n")
	} else {
		sb.WriteString("These entries moved cash that the policy could not attribute. ")
		sb.WriteString("Their net movement is in **unattributed** above, so the ")
		sb.WriteString("arithmetic is whole and the *split* is not.\n\n")
		sb.WriteString("| entry | reason | net | detail |\n|---|---|---|---|\n")
		shown := len(r.rep.Unresolved)
		if shown > RenderCensusLimit {
			shown = RenderCensusLimit
		}
		for i := 0; i < shown; i++ {
			u := r.rep.Unresolved[i]
			sb.WriteString("| ")
			sb.WriteString(strconv.FormatUint(u.EntryID, 10))
			sb.WriteString(" | ")
			sb.WriteString(u.Reason.String())
			sb.WriteString(" | ")
			sb.WriteString(strconv.FormatInt(u.Net, 10))
			sb.WriteString(" | ")
			sb.WriteString(cell(censusDetail(u)))
			sb.WriteString(" |\n")
		}
		if len(r.rep.Unresolved) > shown {
			sb.WriteString("\n_Showing ")
			sb.WriteString(strconv.Itoa(shown))
			sb.WriteString(" of ")
			sb.WriteString(strconv.Itoa(len(r.rep.Unresolved)))
			sb.WriteString("._\n")
		}
		sb.WriteString("\n")
	}

	sb.WriteString("## Net-zero cash entries\n\n")
	if len(r.rep.NetZero) == 0 {
		sb.WriteString("None.\n")
		return sb.String()
	}
	sb.WriteString("These touched a declared cash account and moved none on net — a ")
	sb.WriteString("transfer between cash accounts. They are not classified because ")
	sb.WriteString("there is nothing to attribute.\n\n")
	shown := len(r.rep.NetZero)
	if shown > RenderCensusLimit {
		shown = RenderCensusLimit
	}
	ids := make([]string, 0, shown)
	for i := 0; i < shown; i++ {
		ids = append(ids, strconv.FormatUint(r.rep.NetZero[i], 10))
	}
	sb.WriteString("Entries: ")
	sb.WriteString(strings.Join(ids, ", "))
	if len(r.rep.NetZero) > shown {
		sb.WriteString(" _(")
		sb.WriteString(strconv.Itoa(shown))
		sb.WriteString(" of ")
		sb.WriteString(strconv.Itoa(len(r.rep.NetZero)))
		sb.WriteString(")_")
	}
	sb.WriteString("\n")
	return sb.String()
}

// censusDetail is the actionable half of an unresolved row: the undeclared
// codes for an undeclared entry, the conflicting categories for a conflict.
func censusDetail(u cf.Unresolved) string {
	if len(u.Codes) > 0 {
		return "undeclared: " + strings.Join(u.Codes, ", ")
	}
	if len(u.Categories) > 0 {
		cats := make([]string, 0, len(u.Categories))
		for _, c := range u.Categories {
			cats = append(cats, c.String())
		}
		return "categories: " + strings.Join(cats, ", ")
	}
	return "—"
}

// cell truncates and escapes a string for a markdown table cell.
//
// The truncation is first and is not cosmetic: an account name may be
// books.MaxNameLen bytes and a memo books.MaxMemoLen, and a table row carrying
// either whole is unreadable. The escape is sanitize.TableCell, which is what
// keeps an owner's free text from breaking out of the cell.
func cell(s string) string {
	const maxRunes = 48
	if r := []rune(s); len(r) > maxRunes {
		s = string(r[:maxRunes]) + "…"
	}
	return sanitize.TableCell(s)
}

func yesNo(b bool) string {
	if b {
		return "yes"
	}
	return "no"
}
