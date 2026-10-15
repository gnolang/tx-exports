// Package receivables publishes a receivables aging report and the resulting
// allowance for credit losses over invoices held in [r/invoices].
//
// An issuer registers an aging schedule — age bands in BLOCKS and a loss rate
// per band — and then names the invoice ids to age. This realm reads every
// FACT from the invoice realm (amount, amount paid, due height, status) and
// prices the result with [p/aging]. The published report is frozen: the
// per-bucket unpaid totals, the per-bucket provision, the grand provision, and
// a snapshot of the schedule that priced it.
//
// # The caller supplies the selection, the chain supplies the facts
//
// This is the central design constraint and it is a measured one, not a
// preference. [r/invoices] exports no per-issuer id enumerator — its internal
// `Iterate` is unexported and nothing above it can walk an issuer's records —
// so a realm here CANNOT derive "every open invoice" on its own. It therefore
// takes the id list from the caller.
//
// The consequence is stated rather than hidden: **a report can under-report**.
// An issuer who omits an overdue invoice from the list gets a provision that
// is too small, and no check here can see the omission. What this realm does
// instead is publish a COVERAGE LINE with every report — how many ids were
// listed, how many were aged, how many were filtered and why, and how many
// open invoices and stored records the issuer held at that height — so a
// reader can compute the shortfall themselves. See [Coverage].
//
// Under-reporting is made VISIBLE here. It is not prevented, and a reader who
// treats a published provision as complete without reading the coverage line
// is reading it wrongly.
//
// # Ages are in BLOCKS
//
// [r/invoices] stores `dueHeight` as a block height, so an age is a count of
// blocks and every schedule edge is a count of blocks. A "30/60/90 day"
// schedule is a conversion the ISSUER owns and this realm never performs:
// nothing here knows the block time, and compiling a guess in would make every
// published rate wrong by whatever the guess was off by.
//
// # This realm writes no ledger entry
//
// A provision is an accounting entry — debit a credit-loss expense, credit an
// allowance — and this realm deliberately does not post it. [r/books] derives
// the owner of a book structurally from its caller, so a realm that called
// `PostMulti` would post into ITS OWN book and not the issuer's. There is no
// owner parameter to pass and no delegation path to use.
//
// So [ProposedEntry] returns the entry as a string in the form r/books'
// `PostMulti` accepts, and the issuer posts it themselves from their own
// account. The realm stays keyless with respect to every ledger, which is the
// stronger position: it cannot write a wrong entry because it cannot write.
//
// # Custody
//
// None. This realm holds no coins, has no withdrawal path, and refuses a user
// call that arrives carrying any. Nothing here moves value; a provision is a
// statement about value, which is not the same thing.
//
// # Limitations
//
//   - **The report is a self-report of a self-report.** r/invoices' amounts are
//     whatever an issuer typed; an aging of them inherits that entirely and
//     then looks like an audited artifact. No audit happens here.
//   - **It can under-report, by construction.** See above and [Coverage].
//   - **It cannot over-report an unlisted invoice**, because every fact comes
//     from the chain — but it CAN over-report a *listed* one whose amount the
//     issuer inflated in r/invoices in the first place.
//   - **No write-off.** [p/aging] prices an expected loss and never removes an
//     obligation; a receivable this report provisions at 100% is still a live
//     invoice in r/invoices. Voiding is that realm's operation, not this one's.
//   - **A frozen report does not track the invoices.** A payment landing after
//     publication leaves the published figures untouched, which is what
//     "frozen" means. There is no `Verify` here: re-deriving would need the id
//     list, which is not stored (see [Publish]).
//   - **Buckets are floored per bucket**, so the per-bucket column sums to the
//     grand provision exactly and both are at or below the unrounded figure.
//     [p/aging]'s package doc carries the counterexample.
//   - **No cross-issuer aggregate.** There is no enumerator and no total
//     provision across issuers; such a figure would sum strangers' assertions.
//
// [r/invoices]: /r/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/invoices
// [r/books]: /r/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/books
// [p/aging]: /p/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/aging
package receivables

import (
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"strings"

	"gno.land/p/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/aging"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/r/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/invoices"
)

// RealmPath is this realm's own path, used to build Render links.
const RealmPath = "/r/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/receivables"

// InvoicesPath is the receivables source every figure here is read from.
//
// It is taken BY VALUE from that realm's own exported constant rather than
// typed out again, so this is the compile-time pin itself and not a second
// copy that could drift. The convention is r/statements' BooksPath.
const InvoicesPath = invoices.RealmPath

// RateScale is the unit of a loss rate, re-exported by value from [p/aging]:
// a rate of 2500 is 25%. Re-exported because every rate in this realm's API
// is in these units and a caller should not have to find the other package to
// learn the denominator.
const RateScale = aging.RateScale

// MaxIDsPerCall caps how many invoice ids one [Publish] may name, and it is
// r/invoices' own per-issuer storage cap taken by value.
//
// That cap is the right bound and it is worth saying why, because the two
// candidate bounds differ by a factor of sixteen. [p/aging] accepts up to
// `aging.MaxObligations` (1024) obligations and offers a chunking protocol for
// more; r/invoices stores at most `MaxRecordsPerIssuer` (64) records of any
// status per issuer. An issuer therefore cannot have more than 64 ageable
// invoices in existence at one height, so **this product never chunks**, and
// p/aging's documented chunk-flooring error — where the sum of per-chunk
// provisions is not the provision of the whole — cannot arise here. The two
// caps were chosen independently and it is their inequality, not any code
// below, that makes the composition exact.
const MaxIDsPerCall = invoices.MaxRecordsPerIssuer

// ReportsAreUncapped records a decision by its absence, because every other
// realm in this portfolio caps its per-owner state and a reader will look for
// the cap here.
//
// There is none, for r/statements' reasons, which transfer unchanged: keys are
// per issuer so an issuer can fill only their own history; nothing iterates a
// history except Render, which reads the newest [RenderReportLimit] by direct
// key lookup; and there is no engine cap above this realm to mirror. Each
// publication costs its own gas and storage deposit.
//
// There is also no retraction, and that is the same decision from the other
// side. A `Retract` would split the sequence allocator from the live count —
// two numbers that can disagree — in exchange for letting an issuer delete a
// report they regret. A frozen record that can be deleted is not frozen, and
// the realm has no cap an issuer could be bricked against.
const ReportsAreUncapped = true

// RenderReportLimit caps how many of an issuer's reports one Render call
// lists, which is what keeps an issuer's page cost flat while histories are
// unbounded.
const RenderReportLimit = 20

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

// report is one frozen aging report.
//
// It stores the [aging.Schedule] that priced it, WHOLE, and that field is the
// point of this struct. p/aging's own doc warns that a Report carries no
// reference to its Schedule, so two schedules with the same bucket count will
// accept each other's reports and silently price them on the wrong rates with
// no error. Replacing a schedule is legitimate here — rates change — so the
// hazard is live rather than theoretical, and snapshotting removes the
// opportunity structurally: no bare report ever persists, and a later
// [SetSchedule] cannot retro-price anything already published.
//
// The priced columns are stored rather than re-derived on read, because
// re-deriving would mean calling into p/aging from every accessor and a view
// that recomputes is a second place for the arithmetic to live.
type report struct {
	at    int64         // chain height at publication
	sched aging.Schedule // the schedule that priced this report, snapshotted
	unpaid   []int64     // unpaid total per bucket, youngest first
	provByB  []int64     // provision per bucket, youngest first
	total    int64       // sum of unpaid
	provision int64      // sum of provByB

	// The coverage line. See [Coverage] for what each one means and why
	// they are stored rather than recomputable.
	listed   int
	aged     int
	notOpen  int
	zeroOut  int
	notDue   int
	dupes    int
	openAt   int
	recordsAt int
}

// reports maps "<issuer>|<padded seq>" to *report.
//
// The pointer never leaves this file. Every accessor copies scalars out, so no
// caller receives a handle onto stored state — the discipline r/books and
// r/statements both apply.
var reports = avl.NewTree()

// schedules maps an issuer's address string to their current
// [aging.Schedule]. One per issuer; [SetSchedule] replaces it.
var schedules = avl.NewTree()

// counts maps an issuer's address string to how many reports they have
// published. It is the sequence allocator as well as the count, and the two
// can never disagree because nothing deletes a report.
var counts = avl.NewTree()

// repCount is the global total, maintained alongside the tree so the index
// page never iterates.
var repCount int

// ---------------------------------------------------------------------------
// Guards
// ---------------------------------------------------------------------------

// refuseCoins panics if a user call arrives carrying coins. Adopted from
// r/books and r/statements, which face the identical slot: no withdrawal path,
// so accepted coins are stranded permanently.
//
// IsUserCall rather than IsUser, and the reason is not the canonical
// payment-guard one. That advice is for a realm that ACCEPTS payment, where
// IsUser is dangerously broad. This guard REFUSES, so a broader predicate
// would refuse more and "more conservative" is the wrong frame. The real
// reason is that OriginSend is a fact about the TRANSACTION and is a faithful
// receipt only on the direct MsgCall path; pairing it with IsUser adds a false
// refusal mode — a panic on a call that brought this realm nothing — and buys
// no protection.
//
// The residual is stated rather than guarded: coins can still reach this
// address through an intermediary's explicit banker send, which no predicate
// here can see. What makes that survivable is the absence of any consumption
// path — nothing in this realm can spend what arrives.
//
// The IsCurrent check is a no-op at today's call sites, where the forwarded
// cur is runtime-current by construction. It is here because this realm is
// IMMUTABLE after addpkg, so a future second caller cannot be made safe later,
// and a helper reading Previous() off an unchecked realm parameter is a
// designation-forgery shape whether or not it is reachable today.
func refuseCoins(cur realm) {
	if !cur.IsCurrent() {
		panic("receivables: refuseCoins called with a realm that is not current")
	}
	if cur.Previous().IsUserCall() && len(unsafe.OriginSend()) > 0 {
		panic("receivables: this realm holds no coins and has no withdrawal path; send none")
	}
}

// ---------------------------------------------------------------------------
// Parsing
// ---------------------------------------------------------------------------

// parseInt64List parses a comma-separated list of decimal int64s, rejecting an
// empty list, a blank element, and more than max elements.
//
// The element cap is enforced BEFORE the slice grows, so a caller cannot make
// this realm allocate a long list on the way to a refusal. The `what` word is
// only for the panic message.
func parseInt64List(s string, max int, what string) []int64 {
	parts := strings.Split(s, ",")
	if len(parts) > max {
		panic("receivables: at most " + strconv.Itoa(max) + " " + what +
			"s, got " + strconv.Itoa(len(parts)))
	}
	out := make([]int64, 0, len(parts))
	for _, p := range parts {
		t := strings.TrimSpace(p)
		if t == "" {
			panic("receivables: empty " + what + " in " + strconv.Quote(s))
		}
		v, err := strconv.ParseInt(t, 10, 64)
		if err != nil {
			panic("receivables: " + strconv.Quote(t) + " is not a valid " + what)
		}
		out = append(out, v)
	}
	return out
}

// parseIDs parses the invoice-id list, returning it sorted ascending with
// duplicates removed, and how many duplicates were dropped.
//
// Deduplication is THIS realm's responsibility and that is explicit in
// p/aging's contract: an Obligation "carries no identity", so the same
// obligation passed twice is counted twice and the provision is double. A
// repeated id in a hand-written list of sixty-four is an ordinary mistake, and
// the resulting over-provision is exactly the error class nothing downstream
// can detect — the report would still cross-foot.
//
// Duplicates are DROPPED and COUNTED rather than refused, because the count
// appears in the coverage line and so the caller learns about it either way,
// and a refusal would make an issuer re-type a sixty-four-element list to fix
// a repeat the realm already understood.
//
// Insertion sort over at most MaxIDsPerCall elements, which is 64: O(n²) at
// n=64 is cheaper here than importing a sort.
func parseIDs(ids string) ([]int64, int) {
	raw := parseInt64List(ids, MaxIDsPerCall, "invoice id")
	out := make([]int64, 0, len(raw))
	dupes := 0
	for _, v := range raw {
		if v <= 0 {
			panic("receivables: invoice id must be positive, got " +
				strconv.FormatInt(v, 10))
		}
		i := 0
		for i < len(out) && out[i] < v {
			i++
		}
		if i < len(out) && out[i] == v {
			dupes++
			continue
		}
		out = append(out, 0)
		copy(out[i+1:], out[i:])
		out[i] = v
	}
	return out, dupes
}

// validCode reports whether a string is usable as a ledger account code in a
// [ProposedEntry] leg.
//
// It is a WHITELIST — ASCII letters, digits, `.`, `_` and `-` — and that
// choice is the guard, not a side effect of it. The legs format r/books'
// PostMulti accepts is `code:side:amount` joined by commas, so a code
// containing `:` or `,` would inject extra legs into an entry this realm
// presents as its own arithmetic: a caller could make a one-line provision
// read as a balanced three-line entry crediting an account of their choosing.
// A blacklist of those two bytes would close today's format and not the class.
//
// What this does NOT check is whether the code exists, or is the right kind,
// in any ledger. This realm reads no ledger and has no way to; the entry is a
// PROPOSAL and the posting realm validates its own chart.
func validCode(s string) bool {
	if len(s) == 0 || len(s) > 16 {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c >= 'a' && c <= 'z':
		case c >= 'A' && c <= 'Z':
		case c >= '0' && c <= '9':
		case c == '.' || c == '_' || c == '-':
		default:
			return false
		}
	}
	return true
}

// formatInt64List renders a slice as the comma-separated form the setters
// accept, so a round trip through [ScheduleOf] and [SetSchedule] is exact.
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

// ---------------------------------------------------------------------------
// Write
// ---------------------------------------------------------------------------

// SetSchedule registers or replaces the caller's own aging schedule and
// returns its bucket count.
//
// `edges` is a comma-separated list of block ages, positive and strictly
// increasing; `rates` is one more number than there are edges, each in
// [0, RateScale] and non-decreasing. So
//
//	SetSchedule("216000,432000,648000", "0,1000,2500,5000")
//
// reads as: nothing provisioned under 216,000 blocks past due, 10% from there
// to 432,000, 25% to 648,000, 50% beyond. Every constraint is p/aging's and is
// validated by `aging.New` rather than re-checked here; a second copy of
// somebody else's validation is a second place for it to drift.
//
// The owner is `cur.Previous().Address()` and there is no owner parameter, so
// authorization is structural rather than a check: there is no address to
// forge and no way to set a schedule for somebody else.
//
// REPLACEMENT IS SAFE and that is a property of [report], not of this
// function: every published report snapshots the schedule that priced it, so a
// new schedule applies only to reports published after it. Nothing already
// frozen is re-priced.
func SetSchedule(cur realm, edges, rates string) int {
	refuseCoins(cur)
	issuer := cur.Previous().Address()

	// aging.MaxBuckets is the bucket ceiling, so at most MaxBuckets-1 edges
	// and at most MaxBuckets rates. Bounding the parse separately keeps a
	// thousand-element string from being materialised before aging.New
	// refuses it.
	e := parseInt64List(edges, aging.MaxBuckets-1, "edge")
	r := parseInt64List(rates, aging.MaxBuckets, "rate")

	s, err := aging.New(e, r)
	if err != nil {
		panic("receivables: " + err.Error())
	}
	schedules.Set(issuer.String(), s)
	return s.NumBuckets()
}

// Publish freezes an aging report over the named invoices at the current
// height and returns its sequence number, which starts at 1 for each issuer.
//
// `ids` is a comma-separated list of the caller's own invoice ids in
// [r/invoices], at most [MaxIDsPerCall] of them. The caller must have
// registered a schedule first.
//
// # What each id is checked for
//
// An id with no record for this issuer PANICS and fails the whole call. That
// is deliberate: a silently-dropped id is an under-report, and under-reporting
// is the one error this product cannot detect after the fact. The existence
// probe is a separate `HasInvoice` call rather than letting the next read
// panic, because r/invoices' own message is `"unknown invoice"` and does not
// say WHICH — unhelpful in a list of sixty-four.
//
// An id that exists but is not ageable is filtered, counted, and reported:
//
//   - not `open` — settled or voided, so nothing is owed. Counted `notOpen`.
//   - open with nothing outstanding. Counted `zeroOut`.
//   - open, owed, but `dueHeight > now`. Counted `notDue`.
//
// The third one is not an optimisation. `aging.ReportAt` requires `DueAt <=
// now` for EVERY obligation and fails the whole call on the first that is not,
// so a report over a list containing one current invoice would produce nothing
// at all. Pre-filtering here is what makes "age everything I have" a usable
// call, and the count is what stops the filter being invisible.
//
// # The outstanding cross-check
//
// `amount - paid` is computed here and compared against r/invoices'
// `Outstanding`. State its reach exactly, because the flattering reading is
// available: both sides are that realm's own two numbers, so this is a
// CONSTANT TRUE against any disagreement in ITS arithmetic and must never be
// quoted as cross-checking it. What it catches is a transcription error in
// THIS realm — reading `paid` where `amount` belongs in a six-value return, or
// subtracting the wrong way round — which is the one place in this path such
// an error could happen, and an inflated outstanding is an over-provision that
// still cross-foots.
//
// # The id list is not stored
//
// A report keeps the figures and the coverage counts, not the ids. Storing 64
// ids per report would roughly double the record for the sake of a `Verify`
// that could not mean much anyway: the invoices keep moving, so re-deriving
// would answer "do the figures still hold at today's height" and not "was this
// report right when made". r/statements documents the same distinction about
// its own Verify. The honest artifact is the frozen figure plus the coverage
// line.
func Publish(cur realm, ids string) int64 {
	refuseCoins(cur)
	issuer := cur.Previous().Address()
	s := mustSchedule(issuer)
	now := runtime.ChainHeight()

	list, dupes := parseIDs(ids)

	// An empty list is refused; a list that FILTERS DOWN to nothing is not.
	// The difference is that the second one is a statement — "I aged twenty
	// invoices and none of them is overdue, so the provision is zero" is a
	// real and useful report, and its coverage line proves the work. An empty
	// list says nothing and would cost a permanent storage deposit to say it.
	//
	// THE REFUSAL IS REAL AND THIS BRANCH IS NOT WHAT PERFORMS IT. The message
	// below is UNREACHABLE and the branch is defensive, kept for the reason
	// the zeroOut counter is kept: an invariant worth relying on is worth
	// stating where it is relied on. What a caller actually sees, measured,
	// and asserted by TestAnEmptyOrMalformedIdListIsRefused:
	//
	//   - Publish("")  panics `receivables: empty invoice id in ""`, raised in
	//     parseInt64List. strings.Split("", ",") yields ONE blank element and
	//     not zero elements, so the blank-element guard fires first.
	//   - Publish(" ") the same, via TrimSpace.
	//   - any list that parses reaches here with len(list) >= 1, because
	//     parseIDs appends the FIRST of every duplicate run and drops only the
	//     repeats — dedup cannot empty a non-empty list.
	//
	// The note this replaces documented the refusal by quoting a string the
	// realm cannot emit. A comment asserting an unreachable message is a claim
	// no test can fail on, and this realm is immutable after addpkg.
	if len(list) == 0 {
		panic("receivables: name at least one invoice id to age")
	}

	obs := make([]aging.Obligation, 0, len(list))
	var notOpen, zeroOut, notDue int
	for _, id := range list {
		if !invoices.HasInvoice(issuer, id) {
			panic("receivables: " + InvoicesPath + " holds no invoice " +
				strconv.FormatInt(id, 10) + " for " + issuer.String())
		}
		_, amount, paid, dueHeight, _, status := invoices.InvoiceInfo(issuer, id)
		if status != invoices.StatusOpen {
			notOpen++
			continue
		}
		out := amount - paid
		if out != invoices.Outstanding(issuer, id) {
			panic("receivables: outstanding mismatch on invoice " +
				strconv.FormatInt(id, 10) +
				"; this realm transcribed the record wrongly")
		}
		if out <= 0 {
			zeroOut++
			continue
		}
		if dueHeight > now {
			notDue++
			continue
		}
		obs = append(obs, aging.Obligation{Amount: out, DueAt: dueHeight})
	}

	// MustReport, not a soft error: an error return does not revert a Gno
	// transaction and only a panic does. Every refusal below is p/aging's and
	// every precondition it names has been established above, so a panic here
	// means this realm filtered wrongly.
	rep, err := s.ReportAt(obs, now)
	if err != nil {
		panic("receivables: " + err.Error())
	}
	byB, err := s.ProvisionByBucket(rep)
	if err != nil {
		panic("receivables: " + err.Error())
	}
	prov, err := s.Provision(rep)
	if err != nil {
		panic("receivables: " + err.Error())
	}

	// Cross-foot the column against the grand total. p/aging DOCUMENTS that
	// the per-bucket floor makes these agree exactly, and a documented
	// identity across a package boundary is worth one loop to assert: this
	// realm publishes both numbers side by side and a reader will subtract
	// them.
	var sum int64
	for _, b := range byB {
		sum += b
	}
	if sum != prov {
		panic("receivables: per-bucket provision does not sum to the total")
	}

	key := issuer.String()
	seq := int64(issuerCount(key)) + 1
	reports.Set(repKey(key, seq), &report{
		at:        now,
		sched:     s,
		unpaid:    rep.Buckets,
		provByB:   byB,
		total:     rep.Total,
		provision: prov,
		listed:    len(list),
		aged:      len(obs),
		notOpen:   notOpen,
		zeroOut:   zeroOut,
		notDue:    notDue,
		dupes:     dupes,
		openAt:    invoices.OpenOf(issuer),
		recordsAt: invoices.RecordsOf(issuer),
	})
	counts.Set(key, int(seq))
	repCount++
	return seq
}

// ---------------------------------------------------------------------------
// Reads — schedules
// ---------------------------------------------------------------------------

// HasSchedule reports whether an issuer has registered a schedule, so a reader
// can distinguish that from the panic [ScheduleOf] raises.
func HasSchedule(issuer address) bool {
	return schedules.Has(issuer.String())
}

// ScheduleOf returns an issuer's CURRENT schedule in the comma-separated form
// [SetSchedule] accepts, so the round trip is exact.
//
// This is the schedule that would price the issuer's NEXT report, not
// necessarily the one that priced their last. [ScheduleUsed] answers that.
func ScheduleOf(issuer address) (edges, rates string) {
	s := mustSchedule(issuer)
	return formatInt64List(s.Edges()), formatInt64List(s.Rates())
}

// Buckets is how many age bands an issuer's current schedule has.
func Buckets(issuer address) int { return mustSchedule(issuer).NumBuckets() }

// ---------------------------------------------------------------------------
// Reads — frozen reports
// ---------------------------------------------------------------------------

// Count is how many reports an issuer has published. Zero for an address that
// never has, which is not an error.
func Count(issuer address) int { return issuerCount(issuer.String()) }

// Latest is an issuer's highest sequence number, and whether they have
// published at all. The second result matters: sequence numbers start at 1, so
// a zero first result means "never published" and never "report 0".
func Latest(issuer address) (int64, bool) {
	n := issuerCount(issuer.String())
	if n == 0 {
		return 0, false
	}
	return int64(n), true
}

// Total is how many reports exist across every issuer. It is a count and
// nothing more; see the package doc on why there is no cross-issuer provision.
func Total() int { return repCount }

// Has reports whether a report exists, so a reader can distinguish it from the
// panics the accessors below raise for an unknown one.
func Has(issuer address, seq int64) bool {
	return reports.Has(repKey(issuer.String(), seq))
}

// PublishedAt is the chain height a report was frozen at. It is also the `now`
// every age in it was measured against.
func PublishedAt(issuer address, seq int64) int64 {
	return mustReport(issuer, seq).at
}

// Provision is the allowance for credit losses a report concluded: the sum of
// the per-bucket column, each bucket floored.
func Provision(issuer address, seq int64) int64 {
	return mustReport(issuer, seq).provision
}

// Unpaid is the total outstanding the report aged. It is the denominator the
// provision is a fraction of, and it covers ONLY the aged invoices — not the
// issuer's whole receivable book. See [Coverage].
func Unpaid(issuer address, seq int64) int64 {
	return mustReport(issuer, seq).total
}

// Totals returns a report's headline figures together, which is the shape a
// reader wants and the shape that cannot be assembled from two reads at
// different heights.
func Totals(issuer address, seq int64) (unpaid, provision int64, aged int) {
	r := mustReport(issuer, seq)
	return r.total, r.provision, r.aged
}

// BucketCount is how many age bands a frozen report has, which is the bucket
// count of the schedule that priced it and may differ from the issuer's
// current schedule.
func BucketCount(issuer address, seq int64) int {
	return len(mustReport(issuer, seq).unpaid)
}

// BucketAt returns one line item of a frozen report, youngest band first.
//
// `lo` and `hi` are the band's age range in BLOCKS, half-open [lo, hi); when
// `unbounded` is true the band has no upper edge and `hi` is meaningless. An
// age equal to an edge belongs to the OLDER band. `rate` is in [RateScale]
// units, `unpaid` is the outstanding total that landed in the band, and
// `provision` is `floor(unpaid × rate / RateScale)`.
func BucketAt(issuer address, seq int64, i int) (lo, hi int64, unbounded bool, rate, unpaid, provision int64) {
	r := mustReport(issuer, seq)
	if i < 0 || i >= len(r.unpaid) {
		panic("receivables: bucket " + strconv.Itoa(i) + " is out of range for a report with " +
			strconv.Itoa(len(r.unpaid)) + " buckets")
	}
	lo, hi, unbounded, err := r.sched.BucketRange(i)
	if err != nil {
		panic("receivables: " + err.Error())
	}
	return lo, hi, unbounded, r.sched.Rates()[i], r.unpaid[i], r.provByB[i]
}

// ScheduleUsed returns the schedule that PRICED a frozen report, in the
// comma-separated form [SetSchedule] accepts.
//
// This exists because p/aging warns that a report carries no reference to its
// schedule and two schedules of the same bucket count will silently accept
// each other's reports. Here the reference is stored, so a reader can see the
// rates that produced the figure rather than inferring them from whatever the
// issuer has registered today.
func ScheduleUsed(issuer address, seq int64) (edges, rates string) {
	r := mustReport(issuer, seq)
	return formatInt64List(r.sched.Edges()), formatInt64List(r.sched.Rates())
}

// Coverage is the part of a report a reader must not skip.
//
// This realm cannot enumerate an issuer's invoices (see the package doc), so a
// report covers exactly the ids the issuer named. These eight numbers are what
// let a reader judge whether that was everything:
//
//   - `listed` — distinct ids in the call, after deduplication.
//   - `aged` — ids that became obligations in the report. The provision covers
//     these and nothing else.
//   - `notOpen` — settled or voided, so nothing owed.
//   - `zeroOut` — open with nothing outstanding.
//   - `notDue` — open and owed, but not yet due at `PublishedAt`.
//   - `dupes` — repeated ids dropped before aging.
//   - `openAt` — `invoices.OpenOf(issuer)` at publication: how many open
//     invoices the issuer actually held.
//   - `recordsAt` — `invoices.RecordsOf(issuer)` at publication: records of
//     any status, which is the figure r/invoices' per-issuer cap applies to.
//
// The arithmetic to do: `aged + zeroOut + notDue` is how many OPEN invoices
// the report accounted for, so `openAt` minus that is **how many open invoices
// were left out**. A non-zero remainder means the provision is understated by
// an unknown amount, and no part of this realm can say by how much.
//
// `listed = aged + notOpen + zeroOut + notDue` always holds; `dupes` is
// outside it, having been dropped before the filter.
//
// # ACCOUNTED FOR IS NOT THE SAME AS AT RISK
//
// `notDue` counts toward "accounted for" and carries NO provision. That is
// right on its own terms — the invoice was examined, and p/aging deliberately
// refuses to bucket something that is not yet due — but it makes one reading
// wrong in a way the arithmetic above will not catch. A reader who takes
// `aged` (or the provision) as "the receivables at risk" while `notDue` is
// non-zero has measured a STRICT SUBSET of the open book: the omitted part is
// not omitted by mistake, it is merely not due yet, and it becomes due later
// with no further call to this realm.
//
// So `OmittedOpen == 0` means "every open invoice was examined", never "every
// open invoice is provisioned". The second question is answered by reading
// `notDue` beside the provision, and the render pages print both for exactly
// this reason.
func Coverage(issuer address, seq int64) (listed, aged, notOpen, zeroOut, notDue, dupes, openAt, recordsAt int) {
	r := mustReport(issuer, seq)
	return r.listed, r.aged, r.notOpen, r.zeroOut, r.notDue, r.dupes, r.openAt, r.recordsAt
}

// OmittedOpen is the coverage arithmetic as one number: how many of the
// issuer's open invoices the report did not account for, at the height it was
// published.
//
// Zero is the answer a complete report gives. A positive answer means the
// provision is understated. A NEGATIVE answer is possible and is not a bug
// here: `openAt` is read after the loop, so an invoice settled or voided by a
// transaction between — impossible within one transaction, but the figure is a
// snapshot either way — would make the accounted set larger than the open
// count. It is returned signed rather than clamped, because a clamp would turn
// an inconsistency into a clean zero.
func OmittedOpen(issuer address, seq int64) int {
	r := mustReport(issuer, seq)
	return r.openAt - (r.aged + r.zeroOut + r.notDue)
}

// ProposedEntry returns the double entry that records a report's provision, in
// the `code:side:amount` form r/books' PostMulti accepts — and this realm does
// NOT post it.
//
// It cannot. r/books derives a book's owner structurally from its caller, so a
// posting made from here would land in this realm's own book rather than the
// issuer's, and there is no owner parameter and no delegation path. The issuer
// posts this string themselves, from their own account, into their own book.
// That keeps this realm keyless with respect to every ledger: it cannot write
// a wrong entry because it cannot write.
//
// The entry debits `expenseCode` and credits `allowanceCode` for the whole
// provision:
//
//	ProposedEntry(issuer, seq, "E-BADDEBT", "A-ALLOW")
//	  → "E-BADDEBT:D:1250,A-ALLOW:C:1250"
//
// Both codes go through [validCode], an ASCII whitelist, and the reason is the
// format itself: a code containing `:` or `,` would inject extra legs into a
// string this realm presents as its own arithmetic. Whether a code EXISTS, or
// is the right kind, in any ledger is not checked and cannot be — this realm
// reads no ledger.
//
// A zero provision is refused rather than returned as a balanced pair of
// zeros, which would be a storage deposit spent to post nothing.
//
// It is a PROPOSAL in the full sense: nothing here records that it was posted,
// posting it twice double-counts, and the allowance it credits is a contra
// asset whose previous balance this realm cannot see. An issuer provisioning
// monthly posts the DELTA, not this figure, and working that out is theirs.
func ProposedEntry(issuer address, seq int64, expenseCode, allowanceCode string) string {
	r := mustReport(issuer, seq)
	if r.provision == 0 {
		panic("receivables: the provision is zero; there is no entry to post")
	}
	if !validCode(expenseCode) {
		panic("receivables: " + strconv.Quote(expenseCode) +
			" is not a usable account code; want 1-16 of [A-Za-z0-9._-]")
	}
	if !validCode(allowanceCode) {
		panic("receivables: " + strconv.Quote(allowanceCode) +
			" is not a usable account code; want 1-16 of [A-Za-z0-9._-]")
	}
	if expenseCode == allowanceCode {
		panic("receivables: the expense and allowance accounts must differ")
	}
	n := strconv.FormatInt(r.provision, 10)
	return expenseCode + ":D:" + n + "," + allowanceCode + ":C:" + n
}

// Source is the realm every figure here is read from, by value from its own
// exported constant.
func Source() string { return InvoicesPath }

// Height is the current chain height, which is the `now` a report published in
// this transaction would be aged against.
func Height() int64 { return runtime.ChainHeight() }

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

// repKey is issuer|paddedSeq. The sequence is left-padded to 19 digits — the
// width of MaxInt64 — so lexicographic order over an issuer's prefix is
// numeric order over their reports. An unpadded decimal would sort "10" before
// "9". The convention is r/invoices' invKey, adopted rather than re-derived.
func repKey(issuer string, seq int64) string {
	s := strconv.FormatInt(seq, 10)
	for len(s) < 19 {
		s = "0" + s
	}
	return issuer + "|" + s
}

// issuerCount reads an issuer's report count, treating an absent key as zero.
//
// avl.Tree.Get returns ONE value and cannot distinguish an absent key from a
// nil-valued one, so the two-value type assertion carries the existence answer
// in one traversal. Only this file ever Sets, and it only ever Sets an int.
func issuerCount(issuer string) int {
	n, ok := counts.Get(issuer).(int)
	if !ok {
		return 0
	}
	return n
}

func mustSchedule(issuer address) aging.Schedule {
	s, ok := schedules.Get(issuer.String()).(aging.Schedule)
	if !ok {
		panic("receivables: " + issuer.String() +
			" has no aging schedule; call SetSchedule first")
	}
	return s
}

func mustReport(issuer address, seq int64) *report {
	r, ok := reports.Get(repKey(issuer.String(), seq)).(*report)
	if !ok {
		panic("receivables: no report " + strconv.FormatInt(seq, 10) +
			" for " + issuer.String())
	}
	return r
}

// ---------------------------------------------------------------------------
// Render
// ---------------------------------------------------------------------------

// Render serves the index at "", an issuer's page at "<address>", and one
// report at "<address>/<seq>".
//
// Every caller-supplied string reaching the output goes through the sanitizer.
// The surface is narrower here than in the sibling realms — this realm stores
// no free text, so the only untrusted bytes are the path itself — and it is
// still the one injection-shaped surface a realm with no custody has.
func Render(path string) string {
	p := strings.TrimSpace(strings.Trim(path, "/"))
	if p == "" {
		return renderIndex()
	}
	if i := strings.Index(p, "/"); i >= 0 {
		issuer := address(strings.TrimSpace(p[:i]))
		rest := strings.TrimSpace(strings.Trim(p[i+1:], "/"))
		seq, err := strconv.ParseInt(rest, 10, 64)
		if err != nil {
			return "# receivables\n\n`" + sanitize.InlineText(rest) +
				"` is not a report number.\n"
		}
		return renderReport(issuer, seq)
	}
	return renderIssuer(address(p))
}

func renderIndex() string {
	var sb strings.Builder
	sb.WriteString("# receivables — aging and the allowance for credit losses\n\n")
	sb.WriteString("A receivables aging report and the resulting provision, ")
	sb.WriteString("priced from invoices in [`" + InvoicesPath + "`](" +
		InvoicesPath + ") — never from amounts supplied here.\n\n")

	sb.WriteString("> **A report covers the invoices the issuer named, and ")
	sb.WriteString("nothing else.** `" + InvoicesPath + "` exports no ")
	sb.WriteString("per-issuer enumerator, so this realm cannot find an ")
	sb.WriteString("invoice that was left out. Every report therefore ")
	sb.WriteString("publishes a coverage line, and `OmittedOpen` is the one ")
	sb.WriteString("number that says whether the provision is complete. A ")
	sb.WriteString("provision read without it is being read wrongly.\n\n")

	sb.WriteString("## State\n\n")
	sb.WriteString("- reports published: **" + strconv.Itoa(repCount) + "**\n")
	sb.WriteString("- source: `" + InvoicesPath + "`\n")
	sb.WriteString("- chain height: **" +
		strconv.FormatInt(runtime.ChainHeight(), 10) + "**\n\n")
	sb.WriteString("There is deliberately no way to enumerate issuers or to ")
	sb.WriteString("aggregate a provision across them: such a total would sum ")
	sb.WriteString("every stranger's self-reported receivable.\n\n")

	sb.WriteString("## Ages are in BLOCKS\n\n")
	sb.WriteString("An invoice's `dueHeight` is a block height, so an age is ")
	sb.WriteString("a count of blocks and every schedule edge is a count of ")
	sb.WriteString("blocks. A \"30/60/90 day\" schedule is a conversion the ")
	sb.WriteString("issuer owns; nothing here knows the block time, and ")
	sb.WriteString("compiling a guess in would make every published rate ")
	sb.WriteString("wrong by whatever the guess was off by.\n\n")

	sb.WriteString("## This realm posts no entry\n\n")
	sb.WriteString("A provision is a double entry, and `ProposedEntry` ")
	sb.WriteString("returns it as a string the ledger's `PostMulti` accepts — ")
	sb.WriteString("for the **issuer** to post from their own account. ")
	sb.WriteString("A ledger derives a book's owner from its caller, so a ")
	sb.WriteString("posting made from here would land in this realm's book ")
	sb.WriteString("and not the issuer's. The realm stays keyless with ")
	sb.WriteString("respect to every ledger: it cannot write a wrong entry ")
	sb.WriteString("because it cannot write.\n\n")

	sb.WriteString("## Usage\n\n")
	sb.WriteString("```\n")
	sb.WriteString("SetSchedule(\"216000,432000,648000\", \"0,1000,2500,5000\")\n")
	sb.WriteString("seq := Publish(\"1,2,3,7\")   // the caller's own invoice ids\n")
	sb.WriteString("Totals(issuer, seq)           // unpaid, provision, aged\n")
	sb.WriteString("Coverage(issuer, seq)         // read this one\n")
	sb.WriteString("OmittedOpen(issuer, seq)      // 0 means complete\n")
	sb.WriteString("ProposedEntry(issuer, seq, \"E-BADDEBT\", \"A-ALLOW\")\n")
	sb.WriteString("```\n\n")
	sb.WriteString("At most **" + strconv.Itoa(MaxIDsPerCall) + "** ids per ")
	sb.WriteString("call, which is the source realm's own per-issuer record ")
	sb.WriteString("cap, so an aging never has to be chunked.\n\n")
	sb.WriteString("An issuer's reports are at `" + RealmPath +
		":<address>`, and one report at `" + RealmPath +
		":<address>/<seq>`.\n")
	return sb.String()
}

func renderIssuer(issuer address) string {
	var sb strings.Builder
	sb.WriteString("# receivables — " + sanitize.InlineText(issuer.String()) + "\n\n")

	n := issuerCount(issuer.String())
	if HasSchedule(issuer) {
		e, r := ScheduleOf(issuer)
		sb.WriteString("Current schedule: edges `" + sanitize.InlineText(e) +
			"` (blocks), rates `" + sanitize.InlineText(r) + "` (of " +
			strconv.FormatInt(RateScale, 10) + ").\n\n")
	} else {
		sb.WriteString("No aging schedule registered.\n\n")
	}
	if n == 0 {
		sb.WriteString("No reports published.\n")
		return sb.String()
	}

	sb.WriteString("Reports published: **" + strconv.Itoa(n) + "**")
	first := int64(1)
	if int64(n) > RenderReportLimit {
		first = int64(n) - RenderReportLimit + 1
		sb.WriteString(", showing the newest " +
			strconv.Itoa(RenderReportLimit))
	}
	sb.WriteString(".\n\n")

	sb.WriteString("| seq | height | unpaid | provision | aged | omitted open |\n")
	sb.WriteString("|---|---|---|---|---|---|\n")
	for seq := int64(n); seq >= first; seq-- {
		rep := mustReport(issuer, seq)
		s := strconv.FormatInt(seq, 10)
		// The issuer is sanitized here even though it is UNREACHABLE as
		// attacker bytes, and the reason is the point. This loop runs only
		// when n != 0, and n comes from issuerCount(issuer.String()), which
		// is keyed exclusively by cur.Previous().Address().String() — the
		// only three .Set calls in this file are so keyed — so a path
		// an attacker chose has count 0 and returns above. The value here is
		// always a genuine bech32 address, whose charset holds no markdown
		// metacharacter.
		//
		// That is a four-step reachability argument, and the header thirty
		// lines up sanitizes the same value. An audit raised the
		// inconsistency and resolved it by re-deriving the argument; the
		// sanitizer costs nothing and means the next reader does not have to.
		// A guard that depends on an argument holding elsewhere in the file
		// is one refactor from being wrong, and this realm is immutable
		// after addpkg.
		sb.WriteString("| [" + s + "](" + RealmPath + ":" +
			sanitize.InlineText(issuer.String()) + "/" + s + ") | " +
			strconv.FormatInt(rep.at, 10) + " | " +
			strconv.FormatInt(rep.total, 10) + " | " +
			strconv.FormatInt(rep.provision, 10) + " | " +
			strconv.Itoa(rep.aged) + " | " +
			strconv.Itoa(rep.openAt-(rep.aged+rep.zeroOut+rep.notDue)) + " |\n")
	}
	return sb.String()
}

func renderReport(issuer address, seq int64) string {
	if !Has(issuer, seq) {
		return "# receivables\n\nNo report " +
			strconv.FormatInt(seq, 10) + " for `" +
			sanitize.InlineText(issuer.String()) + "`.\n"
	}
	r := mustReport(issuer, seq)

	var sb strings.Builder
	sb.WriteString("# receivables — report " + strconv.FormatInt(seq, 10) + "\n\n")
	sb.WriteString("Issuer `" + sanitize.InlineText(issuer.String()) +
		"`, frozen at height **" + strconv.FormatInt(r.at, 10) +
		"**, from `" + InvoicesPath + "`.\n\n")

	sb.WriteString("- unpaid aged: **" + strconv.FormatInt(r.total, 10) + "**\n")
	sb.WriteString("- provision: **" + strconv.FormatInt(r.provision, 10) + "**\n")
	sb.WriteString("- schedule used: edges `" +
		sanitize.InlineText(formatInt64List(r.sched.Edges())) +
		"`, rates `" + sanitize.InlineText(formatInt64List(r.sched.Rates())) +
		"`\n\n")

	sb.WriteString("## Buckets\n\n")
	sb.WriteString("Ages in **blocks**, youngest band first. A band is ")
	sb.WriteString("half-open `[lo, hi)`, so an age equal to an edge belongs ")
	sb.WriteString("to the older band.\n\n")
	sb.WriteString("| band | from | to | rate | unpaid | provision |\n")
	sb.WriteString("|---|---|---|---|---|---|\n")
	rates := r.sched.Rates()
	for i := range r.unpaid {
		lo, hi, unbounded, err := r.sched.BucketRange(i)
		if err != nil {
			panic("receivables: " + err.Error())
		}
		to := strconv.FormatInt(hi, 10)
		if unbounded {
			to = "—"
		}
		sb.WriteString("| " + strconv.Itoa(i) + " | " +
			strconv.FormatInt(lo, 10) + " | " + to + " | " +
			strconv.FormatInt(rates[i], 10) + " | " +
			strconv.FormatInt(r.unpaid[i], 10) + " | " +
			strconv.FormatInt(r.provByB[i], 10) + " |\n")
	}
	sb.WriteString("\nThe provision column is floored **per band**, so it ")
	sb.WriteString("sums to the total exactly and both are at or below the ")
	sb.WriteString("unrounded figure.\n\n")

	sb.WriteString("## Coverage\n\n")
	omitted := r.openAt - (r.aged + r.zeroOut + r.notDue)
	sb.WriteString("| listed | aged | not open | nothing owed | not yet due | dupes dropped | open then | records then |\n")
	sb.WriteString("|---|---|---|---|---|---|---|---|\n| " +
		strconv.Itoa(r.listed) + " | " + strconv.Itoa(r.aged) + " | " +
		strconv.Itoa(r.notOpen) + " | " + strconv.Itoa(r.zeroOut) + " | " +
		strconv.Itoa(r.notDue) + " | " + strconv.Itoa(r.dupes) + " | " +
		strconv.Itoa(r.openAt) + " | " + strconv.Itoa(r.recordsAt) + " |\n\n")

	if omitted > 0 {
		sb.WriteString("> **This report is incomplete.** " +
			strconv.Itoa(omitted) + " of the issuer's open invoices were ")
		sb.WriteString("not named in the call, so the provision is ")
		sb.WriteString("understated by an amount nothing here can determine.\n")
	} else if omitted == 0 {
		sb.WriteString("Every open invoice the issuer held at that height was ")
		sb.WriteString("accounted for.\n")
	} else {
		sb.WriteString("> The accounted set is larger than the open count by " +
			strconv.Itoa(-omitted) + ", which is reported rather than ")
		sb.WriteString("clamped. See `OmittedOpen`.\n")
	}
	return sb.String()
}
