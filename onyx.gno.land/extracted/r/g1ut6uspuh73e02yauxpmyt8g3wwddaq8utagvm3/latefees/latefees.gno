// Realm latefees publishes a graduated late-fee penalty on an overdue invoice
// held in the live [r/invoices]. A creditor (an invoice issuer) declares a
// late-fee SCHEDULE once — a [p/tiers] schedule over how many blocks an
// invoice is overdue — and the realm prices the penalty as a function of that
// overdue duration, escalating by tier. The penalty can be read live
// ([PenaltyNow]) or frozen into a sequence-numbered ASSESSMENT the creditor
// can point a payer to.
//
// It is the fourth consumer of [p/tiers] and the one that exercises its
// "progressive fee" reading over TIME rather than quantity: [r/meters] prices
// usage, [r/payslips] prices withholding, and this prices lateness. It is the
// second consumer of [r/invoices] after [r/receivables], and reads the exact
// integration surface that realm's header advertises — [invoices.InvoiceInfo],
// [invoices.IsOverdue], [invoices.HasInvoice] — all non-crossing views, no
// struct slice crossing a realm boundary.
//
// # It is a PUBLISHER, not a collector
//
// [r/invoices] is live and immutable, so this realm CANNOT add a charge to an
// invoice there, and it holds no coins of its own — no banker, no deposit, no
// payout, no withdrawal path. A published penalty is a verifiable CLAIM backed
// by the invoice's own facts and the creditor's declared schedule, exactly as
// [r/receivables] publishes a loss provision and [r/cashflow] a statement. It
// compels nothing; a debtor who ignores a late fee is in the same position as
// one who ignores the invoice. A custodial variant that collects the fee is a
// separate, larger product and is deliberately out of scope.
//
// # The pricing axis, and the one it is not
//
// The base handed to [p/tiers] is the OVERDUE DURATION in blocks
// (`now - dueHeight`), and each tier's rate is a ugnot accrual per RateScale
// blocks. So the penalty ESCALATES WITH TIME: the longer an invoice is
// overdue, the higher the marginal accrual. [p/tiers]' rate cap makes
// `penalty <= overdueBlocks` an arithmetic fact — the fee can never exceed one
// ugnot per overdue block, a natural ceiling.
//
// It is NOT a percentage of the outstanding amount. [p/tiers] prices one
// amount against breakpoints — a single dimension — and a fee that is both
// time-escalating AND balance-scaled is two dimensions it cannot express in
// one call. The creditor scales the ugnot accrual to their debt magnitudes
// through the schedule; the assessment records the outstanding beside the
// penalty so a reader can compute an effective rate. Composing a balance-
// scaled fee as a single Charge call would be a plausible, wrong number.
//
// # The trust boundary, inherited twice over
//
// A penalty is a self-report of a self-report of a self-report: the issuer set
// the invoice amount in [r/invoices], the due height there, AND the late-fee
// schedule here. This realm computes faithfully from those; it does not
// validate that any of them is fair. A creditor may only assess their OWN
// invoices — [Assess] derives the issuer from `cur.Previous().Address()` and
// reads [invoices.InvoiceInfo] under that key, which returns only invoices
// that address issued.
package latefees

import (
	"chain"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"

	"gno.land/p/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/tiers"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/r/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/invoices"
)

// Denom is the asset the invoices this realm prices are denominated in, and
// the unit a penalty is expressed in. This realm never holds it.
const Denom = "ugnot"

// InvoicesPath pins the realm this one reads, by value, so a reader of a
// published assessment can see which invoices it priced.
const InvoicesPath = invoices.RealmPath

// RenderLimit bounds every rendered list — an unbounded Render was YELLOW in
// three prior audits.
const RenderLimit = 20

// MaxAssessmentsPerIssuer bounds one creditor's stored assessment records, so
// one address cannot grow this realm's state without bound. It counts STORED
// records, the invoices-realm discipline.
const MaxAssessmentsPerIssuer = 256

type assessment struct {
	seq         int64
	issuer      address // the creditor who froze it; the invoice's issuer
	invoiceID   int64
	payer       address
	amount      int64 // invoice face, snapshotted from r/invoices
	paid        int64 // snapshotted
	outstanding int64 // amount - paid at assessment time
	dueHeight   int64
	assessedAt  int64 // chain height the penalty was priced at
	overdueBy   int64 // assessedAt - dueHeight, the base priced
	penalty     int64 // Charge(overdueBy) under the snapshotted schedule
	edges       []int64
	rates       []int64
}

var (
	self      address // this realm's address, captured at deploy
	nextSeq   int64
	schedules = avl.NewTree() // issuer.String()      -> tiers.Schedule (by value)
	bySeq     = avl.NewTree() // padID(seq)            -> *assessment
	issuerNum = avl.NewTree() // issuer.String()       -> *int64, stored assessments
)

func init() {
	self = unsafe.CurrentRealm().Address()
}

// --- creditor side ---

// SetSchedule declares or replaces the caller's late-fee schedule: a graduated
// accrual over OVERDUE BLOCKS, built from comma-separated int64 lists where
// len(rates) == len(edges)+1 and each rate is a ugnot accrual per RateScale
// blocks (0..10000). Edges are block counts — e.g. "216000,648000" is roughly
// ten and thirty days at ~4s blocks. A single rate with no edges is a flat
// accrual. Replacing a schedule does not touch already-frozen assessments,
// which snapshot the schedule that priced them.
func SetSchedule(cur realm, edges, rates string) int {
	assertNoSend()
	issuer := cur.Previous().Address()
	s, err := tiers.New(
		parseInt64List(edges, tiers.MaxTiers-1, "edge"),
		parseInt64List(rates, tiers.MaxTiers, "rate"),
	)
	if err != nil {
		panic("schedule: " + err.Error())
	}
	schedules.Set(issuer.String(), s)
	chain.Emit("ScheduleSet", "issuer", issuer.String(), "tiers", itoa(int64(s.NumTiers())))
	return s.NumTiers()
}

// Assess freezes a late-fee penalty on one of the caller's own overdue
// invoices and returns its sequence number. The caller must be the invoice's
// issuer (the creditor), must have declared a schedule, and the invoice must
// be overdue right now. The invoice's facts and the current schedule are
// snapshotted, so the assessment is a stable claim even as the invoice keeps
// accruing or is later paid.
func Assess(cur realm, invoiceID int64) int64 {
	assertNoSend()
	issuer := cur.Previous().Address()
	if !invoices.HasInvoice(issuer, invoiceID) {
		panic("no invoice " + itoa(invoiceID) + " issued by the caller")
	}
	sv := schedules.Get(issuer.String())
	if sv == nil {
		panic("declare a late-fee schedule first with SetSchedule")
	}
	if !invoices.IsOverdue(issuer, invoiceID) {
		panic("invoice " + itoa(invoiceID) + " is not overdue")
	}
	n := counter(issuerNum, issuer)
	if *n >= MaxAssessmentsPerIssuer {
		panic("per-issuer assessment limit reached")
	}

	payer, amount, paid, dueHeight, _, _ := invoices.InvoiceInfo(issuer, invoiceID)
	now := runtime.ChainHeight()
	overdueBy := now - dueHeight // > 0: IsOverdue required now > dueHeight
	sched := sv.(tiers.Schedule)
	penalty := charge(sched, overdueBy)

	seq := nextSeq
	nextSeq++
	bySeq.Set(padID(seq), &assessment{
		seq:         seq,
		issuer:      issuer,
		invoiceID:   invoiceID,
		payer:       payer,
		amount:      amount,
		paid:        paid,
		outstanding: amount - paid,
		dueHeight:   dueHeight,
		assessedAt:  now,
		overdueBy:   overdueBy,
		penalty:     penalty,
		edges:       sched.Edges(),
		rates:       sched.Rates(),
	})
	*n++

	chain.Emit("Assessed",
		"seq", itoa(seq),
		"issuer", issuer.String(),
		"invoiceId", itoa(invoiceID),
		"payer", payer.String(),
		"overdueBy", itoa(overdueBy),
		"outstanding", itoa(amount-paid),
		"penalty", itoa(penalty),
	)
	return seq
}

// --- views (non-crossing: cross-realm readable) ---

// PenaltyNow is the penalty an issuer's invoice has accrued as of the current
// height, under the issuer's CURRENT schedule. It is 0 when the invoice is not
// overdue — including once it is paid or voided, because [r/invoices] does not
// expose when a payment landed, so accrual is only computable while the
// invoice is still open and late. A frozen [Assess] is how a claim survives
// the invoice being paid. Panics only if the issuer has no schedule or the
// invoice does not exist.
func PenaltyNow(issuer address, invoiceID int64) int64 {
	if !invoices.HasInvoice(issuer, invoiceID) {
		panic("no invoice " + itoa(invoiceID) + " issued by " + issuer.String())
	}
	sv := schedules.Get(issuer.String())
	if sv == nil {
		panic("issuer has no late-fee schedule")
	}
	if !invoices.IsOverdue(issuer, invoiceID) {
		return 0
	}
	_, _, _, dueHeight, _, _ := invoices.InvoiceInfo(issuer, invoiceID)
	return charge(sv.(tiers.Schedule), runtime.ChainHeight()-dueHeight)
}

// QuotePenalty prices a hypothetical overdue duration against an issuer's
// current schedule, without reading any invoice — the preview a creditor uses
// to tune a schedule. Panics if the issuer has no schedule or overdueBlocks is
// negative.
func QuotePenalty(issuer address, overdueBlocks int64) int64 {
	sv := schedules.Get(issuer.String())
	if sv == nil {
		panic("issuer has no late-fee schedule")
	}
	if overdueBlocks < 0 {
		panic("overdueBlocks must be non-negative")
	}
	return charge(sv.(tiers.Schedule), overdueBlocks)
}

// HasSchedule reports whether an issuer has declared a late-fee schedule.
func HasSchedule(issuer address) bool { return schedules.Get(issuer.String()) != nil }

// ScheduleOf returns an issuer's current schedule as its edge and rate slices,
// or two empty slices if none is declared.
func ScheduleOf(issuer address) (edges, rates []int64) {
	sv := schedules.Get(issuer.String())
	if sv == nil {
		return nil, nil
	}
	s := sv.(tiers.Schedule)
	return s.Edges(), s.Rates()
}

// AssessmentInfo returns a frozen assessment's fields. Panics on an unknown
// sequence.
func AssessmentInfo(seq int64) (issuer, payer address, invoiceID, outstanding, overdueBy, penalty, assessedAt int64) {
	a := mustAssessment(seq)
	// invoiceID/outstanding/overdueBy/penalty/assessedAt are int64; issuer and
	// payer are addresses, returned first.
	return a.issuer, a.payer, a.invoiceID, a.outstanding, a.overdueBy, a.penalty, a.assessedAt
}

// AssessmentSchedule returns the schedule snapshot an assessment was priced
// under — the edges and rates frozen with it, which may differ from the
// issuer's current schedule.
func AssessmentSchedule(seq int64) (edges, rates []int64) {
	a := mustAssessment(seq)
	return a.edges, a.rates
}

// HasAssessment reports whether a sequence number names a frozen assessment.
func HasAssessment(seq int64) bool { return bySeq.Get(padID(seq)) != nil }

// AssessmentsOf is the number of assessments an issuer has frozen.
func AssessmentsOf(issuer address) int64 {
	v := issuerNum.Get(issuer.String())
	if v == nil {
		return 0
	}
	return *v.(*int64)
}

func NumAssessments() int64 { return nextSeq }
func Invoices() string      { return InvoicesPath }
func Address() address      { return self }
func Height() int64         { return runtime.ChainHeight() }

// --- internals ---

// charge prices an overdue duration against a schedule, surfacing tiers' own
// error as a panic rather than a silent zero. A zero or negative base prices
// to zero (tiers refuses a negative amount, so it is guarded here).
func charge(s tiers.Schedule, overdueBy int64) int64 {
	if overdueBy <= 0 {
		return 0
	}
	c, err := s.Charge(overdueBy)
	if err != nil {
		panic("charge: " + err.Error())
	}
	return c
}

func mustAssessment(seq int64) *assessment {
	v := bySeq.Get(padID(seq))
	if v == nil {
		panic("unknown assessment " + itoa(seq))
	}
	return v.(*assessment)
}

// assertNoSend refuses coins on every crossing entrypoint. This realm holds
// nothing, so every one of its writes is non-payable. Reads the ORIGIN
// envelope, so a transaction attaching coins anywhere is refused.
func assertNoSend() {
	if !unsafe.OriginSend().IsZero() {
		panic("this function does not accept coins")
	}
}

func counter(tree *avl.Tree, a address) *int64 {
	k := a.String()
	if v := tree.Get(k); v != nil {
		return v.(*int64)
	}
	n := int64(0)
	tree.Set(k, &n)
	return &n
}

// parseInt64List parses a comma-separated int64 list, bounding the element
// count BEFORE materialising values so a long string dies on count, not
// memory (the r/receivables bounding argument). "" is the empty list.
func parseInt64List(s string, max int, what string) []int64 {
	if s == "" {
		return nil
	}
	var out []int64
	start := 0
	for i := 0; i <= len(s); i++ {
		if i < len(s) && s[i] != ',' {
			continue
		}
		if len(out) >= max {
			panic("too many " + what + "s: at most " + strconv.Itoa(max))
		}
		field := s[start:i]
		start = i + 1
		n, err := strconv.ParseInt(trimSpaces(field), 10, 64)
		if err != nil {
			panic("bad " + what + " " + field + ": " + err.Error())
		}
		out = append(out, n)
	}
	return out
}

func trimSpaces(s string) string {
	i, j := 0, len(s)
	for i < j && s[i] == ' ' {
		i++
	}
	for j > i && s[j-1] == ' ' {
		j--
	}
	return s[i:j]
}

func padID(id int64) string {
	s := strconv.FormatInt(id, 10)
	for len(s) < 12 {
		s = "0" + s
	}
	return s
}

func itoa(n int64) string { return strconv.FormatInt(n, 10) }

// --- Render ---

// Render shows the catalog at "", an assessment at "seq/<n>", and an issuer's
// schedule at "issuer/<addr>". Every user-supplied value rendered between
// table pipes is escaped with sanitize.TableCell; addresses carry no markdown
// metacharacter but are passed through InlineText for the same reason the
// sibling realms do.
func Render(path string) string {
	switch {
	case path == "":
		return renderHome()
	case hasPrefix(path, "seq/"):
		return renderAssessment(path[len("seq/"):])
	case hasPrefix(path, "issuer/"):
		return renderIssuer(path[len("issuer/"):])
	default:
		return "unknown path; try \"\", \"seq/<n>\" or \"issuer/<address>\"\n"
	}
}

func renderHome() string {
	out := "# latefees — graduated late-fee penalties over " + sanitize.InlineText(InvoicesPath) + "\n\n"
	out += "Assessments: " + itoa(nextSeq) + ". A penalty is a published CLAIM, not a collected charge; this realm holds no coins.\n\n"
	out += "| seq | issuer | invoice | overdue (blocks) | outstanding | penalty |\n|---|---|---|---|---|---|\n"
	shown := int64(0)
	// Newest-first: the most recent assessments are the ones a reader wants,
	// and oldest-first under a cap lets early seqs own the page forever
	// (r/meters audit finding Y2).
	for seq := nextSeq - 1; seq >= 0 && shown < RenderLimit; seq-- {
		v := bySeq.Get(padID(seq))
		if v == nil {
			continue
		}
		a := v.(*assessment)
		out += "| " + itoa(a.seq) + " | " + sanitize.TableCell(a.issuer.String()) + " | " +
			itoa(a.invoiceID) + " | " + itoa(a.overdueBy) + " | " + itoa(a.outstanding) + Denom +
			" | " + itoa(a.penalty) + Denom + " |\n"
		shown++
	}
	if nextSeq > shown {
		out += "\n(" + itoa(shown) + " most recent of " + itoa(nextSeq) + ")\n"
	}
	return out
}

func renderAssessment(seqStr string) string {
	seq, err := strconv.ParseInt(seqStr, 10, 64)
	if err != nil {
		return "bad sequence\n"
	}
	v := bySeq.Get(padID(seq))
	if v == nil {
		return "unknown assessment " + seqStr + "\n"
	}
	a := v.(*assessment)
	out := "# assessment " + itoa(a.seq) + "\n\n"
	out += "- issuer (creditor): " + a.issuer.String() + "\n"
	out += "- payer (debtor): " + a.payer.String() + "\n"
	out += "- invoice " + itoa(a.invoiceID) + " in " + sanitize.InlineText(InvoicesPath) + "\n"
	out += "- face " + itoa(a.amount) + Denom + ", paid " + itoa(a.paid) + Denom +
		", outstanding " + itoa(a.outstanding) + Denom + "\n"
	out += "- due at height " + itoa(a.dueHeight) + ", assessed at " + itoa(a.assessedAt) +
		" (" + itoa(a.overdueBy) + " blocks overdue)\n"
	out += "- **penalty: " + itoa(a.penalty) + Denom + "**, priced on the overdue duration\n\n"
	out += renderSchedule(a.edges, a.rates)
	return out
}

func renderIssuer(addr string) string {
	issuer := address(addr)
	sv := schedules.Get(addr)
	if sv == nil {
		return "issuer " + sanitize.InlineText(addr) + " has no late-fee schedule\n"
	}
	s := sv.(tiers.Schedule)
	out := "# late-fee schedule for " + sanitize.InlineText(addr) + "\n\n"
	out += "Frozen assessments by this issuer: " + itoa(AssessmentsOf(issuer)) + "\n\n"
	out += renderSchedule(s.Edges(), s.Rates())
	return out
}

func renderSchedule(edges, rates []int64) string {
	out := "Schedule over overdue blocks (ugnot accrued per 10000 blocks, by tier):\n\n"
	out += "| from (blocks overdue) | rate (/10000) |\n|---|---|\n"
	lo := int64(0)
	for i, r := range rates {
		out += "| " + itoa(lo) + " | " + itoa(r) + " |\n"
		if i < len(edges) {
			lo = edges[i]
		}
	}
	return out
}

func hasPrefix(s, p string) bool { return len(s) >= len(p) && s[:len(p)] == p }
