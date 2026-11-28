package fund

import (
	"chain"
	"chain/runtime"
	"strings"
	"time"

	"gno.land/p/g1thug63es793ckaw63l2704qzp3a92y58kekda0/cbtrial1/fundmath"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/grc20/v0"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/nt/grc20reg/v0"

	"gno.land/r/g1thug63es793ckaw63l2704qzp3a92y58kekda0/cbtrial1/tusd"
)

const (
	escrowSub = "escrow"
	cashSub   = "cash"
)

// Period states.
const (
	stateSetup = iota
	stateOpen
	stateCutOff
	stateProposed
	stateSettling
	stateClosed
)

var stateNames = []string{"Setup", "Open", "Cut-off", "NAV proposed", "Settling", "Closed"}

var (
	token    *grc20.Token
	selfPath string
	deployer address

	// Roles, fixed at Launch.
	manager, administrator, reviewer, officer, auditor address
	agentSession                                       address // registered by the officer
	agentExpiry                                        int64   // the session's expiry, declared at registration
	launched                                           bool

	// The nominee route (design note v3, section 2).
	nomineePath     string
	nomineeAddr     address
	nomineeShares   int64 // shares held by all nominee sub-accounts
	nomineeAccounts int64 // sub-accounts holding shares

	instruments = avl.NewTree() // name -> *instrument
	instrOrder  []string
	providers   = avl.NewTree() // service provider name -> address (ADMIN, BANK, AUDIT, LEGAL, ...)
	providerOrd []string
	owed        = avl.NewTree() // payee address -> int64, fees and expenses not yet paid for lack of cash
	expenses    = avl.NewTree() // id -> *expense
	audits      = avl.NewTree() // year (padded) -> *auditRecord
	notices     = avl.NewTree() // holder address -> notice time (below the minimum holding)
	pendingMin  = avl.NewTree() // holder address -> period of the manager's proposal (compulsory redemption below the minimum)
	heldCash    = avl.NewTree() // holder address -> int64: wind-down payments set aside for a restricted holder
	subAccounts = avl.NewTree() // nominee sub-account register address -> true
	totalHeld   int64           // sum of heldCash: in the cash account, out of NAV
	closedAt    int64           // unix seconds of closure

	// crystalliseMinDays: the fewest days between two crystallisations of the
	// performance fee, fixed before Launch (182 for a real fund, 0 for a demo).
	crystalliseMinDays int64 = DefaultCrystalliseMinDays

	// The final distribution's register (review 3, I2): shares cancelled in
	// it, in total and per holder (holder.finalShares), and how many holders.
	finalShares, finalHolders int64

	// Board powers (design note v3.3, B).
	subscriptionsClosed bool
	suspendedUntil      int64 // unix seconds; dealing is suspended until then
	pendingSusp         *suspension
	windDownProposed    bool  // manager proposed
	windDownPeriod      int64 // the period of that proposal: approval only in the same period
	closureProposed     int64 // period of the manager's proposal to close (0: none)
	closureApproved     bool  // reviewer countersigned: the fund closes once nothing is left
	windDownApproved    bool  // reviewer countersigned: takes effect at the next cut-off
	windingDown         bool
	windDownReason      string
	orgLeft             int64 = OrgCostTotal // set-up costs not yet written off
	launchTime          int64

	holders     = avl.NewTree() // address -> *holder
	eligibility = avl.NewTree() // address -> *status
	subs        = avl.NewTree() // id -> *subscription, open ones only
	activeSubs  = avl.NewTree() // id -> true, money still in escrow
	reds        = avl.NewTree() // id -> *redemption, open ones only
	openReds    = avl.NewTree() // id -> true
	outflows    = avl.NewTree() // id -> *outflow
	receipts    = avl.NewTree() // id -> *receipt
	history     = avl.NewTree() // period -> *record
	trail       = avl.NewTree() // seq -> *entry
	lists       = avl.NewTree() // list code -> *listSnapshot (latest)
	listLog     = avl.NewTree() // seq -> *listSnapshot

	nextSub, nextRed, nextOut, nextRcpt, nextExp, trailSeq, listSeq int64

	// Internal ledgers. NAV is computed from these, never from token
	// balances, so tUSD sent to the fund cannot move the price.
	bookCash       int64 // investable cash in the cash account
	escrowBook     int64 // all subscriptions still in escrow
	approvedEscrow int64 // approved subscriptions waiting for settlement
	sharesInIssue  int64

	cur0           period // the current period
	lastNAV        int64  // NAV after the last settlement (cash + instrument books - fee owed)
	lastNAVps      int64  // NAV per share struck at the last approved NAV
	lastStrikeTime int64  // valuation time of the last approved NAV (unix seconds)
	totalOwed      int64  // sum of owed

	// Screening totals (per-wallet detail is not published).
	decisionsScreened, decisionsUnscreened int64
)

type instrument struct {
	name, label string
	payTo       address
	book        int64 // last approved mark, plus investments, less receipts since
}

type holder struct {
	addr             address // the register entry this holder is keyed by
	shares           int64
	hwm              int64 // high-water mark per share, for the performance fee
	lastIssuedPeriod int64
	activeSub        int64 // 0 if none
	openRed          int64 // 0 if none
	payee            address
	viaNominee       bool
	finalShares      int64 // shares cancelled in the final distribution
	cost             int64 // average-cost base of the shares held (design note v6)
}

type status struct {
	eligible   bool
	expiresAt  int64 // unix seconds
	restricted bool
	commitment string // salted commitment to the off-chain record
	decidedAt  int64  // block height
	screened   bool   // agent recommendation on file since the last decision
}

const (
	subPending = iota
	subApproved
)

var subStatusNames = []string{"pending", "approved"}

type subscription struct {
	id, amount, placedPeriod int64
	askedPeriod              int64   // the investor asked to withdraw in this period (0: never)
	wallet                   address // the holder: a wallet, or a nominee sub-account
	payee                    address // where refunds go
	viaNominee               bool
	status                   int
	shares                   int64
	dealtIn                  int64 // period whose settlement issues it
	screened                 bool
}

type redemption struct {
	id           int64
	compulsory   bool   // ordered by the officer, or by manager and reviewer
	kind         string // "compliance" (reason kept off-chain) or "below-minimum"
	reasonRef    string // compliance: salted commitment to the off-chain reason
	askedPeriod  int64  // the investor asked to withdraw in this period (0: never)
	wallet       address
	payee        address
	viaNominee   bool
	full         bool
	lots         int64 // lots still to fill (partial requests)
	placedPeriod int64
	dealPeriod   int64
	paid         int64 // total paid so far
}

type outflow struct {
	id         int64
	instrument string
	amount     int64
	period     int64
	paid       bool
	cancelled  bool
}

type receipt struct {
	id        int64
	source    string // instrument name, or OTHER
	amount    int64
	period    int64
	recorded  bool
	cancelled bool
}

type fill struct {
	redID         int64
	compulsory    bool
	pps           int64 // performance fee per share at this NAV
	openingShares int64
	full          bool
	lots, paid    int64
	done          bool
}

type period struct {
	n        int64
	state    int
	openedAt int64
	cutAt    int64
	cutBy    string
	// NAV proposal
	proposalNo int64
	valuedAt   int64
	marks      []mark
	sourceRef  string
	gross, fee int64 // fee: all scheduled fees and expenses of the period
	mgmtFee    int64
	adminFee   int64
	bankFee    int64
	orgFee     int64
	perfFees   int64 // performance fees charged this period
	perfDue    int64 // performance fees on redemptions, paid after them
	proposals  int64 // payments, receipts and expenses proposed this period
	nav, navps int64
	needsAck   bool
	sharesOpen int64
	// settlement
	phase           int
	cursor          string
	capacity        int64
	fills           *avl.Tree // padded red id -> *fill
	subsIssued      int64
	subsAmount      int64
	redsPaid        int64
	sharesCancelled int64
	outflowUsed     int64
	suspended       bool // dealing suspended at this period's settlement
	crystallise     bool
	distribute      bool // wind-down distribution
	distS, distNAV  int64
	distCash        int64
	final           bool // last distribution: every instrument at zero
	distInit        bool
	recovery        bool // money recorded after the final distribution is paid out
	insolvent       bool // nothing left for the shareholders
	lowNAV          bool // NAV per share below 1 tUSD, or NAV not positive
}

type mark struct {
	name  string
	value int64
}

type record struct {
	n, gross, fee, perfFee, nav, navps int64
	sharesOpen                         int64
	subsAmount, redsPaid, capacity     int64
	sharesAfter, cashAfter, navAfter   int64
	proposalNo                         int64
	sourceRef                          string
	height                             int64
	valuedAt                           int64
}

type expense struct {
	id        int64
	provider  string
	amount    int64
	reason    string
	period    int64
	paid      bool
	cancelled bool
}

type suspension struct {
	period int64 // approval only in the same period
	lift   bool
	days   int64
	reason string
}

type auditRecord struct {
	year   int64
	sha    string
	height int64
}

type entry struct {
	height int64
	t      int64
	role   string
	text   string
}

type listSnapshot struct {
	list, published, sha string
	height               int64
}

func init(cur realm) {
	token = grc20reg.MustGet(tusd.TokenKey())
	selfPath = cur.PkgPath()
	deployer = cur.Previous().Address()
	cur0 = period{state: stateSetup}
}

// ---- helpers ----

func fundAddr() address   { return chain.PackageAddress(selfPath) }
func escrowAddr() address { return chain.DerivePkgSubAddr(selfPath, escrowSub) }
func cashAddr() address   { return chain.DerivePkgSubAddr(selfPath, cashSub) }

// subAccountAddr is the register entry of nominee sub-account c: an address
// no one signs with.
func subAccountAddr(c string) address { return chain.DerivePkgSubAddr(nomineePath, "c/"+c) }

func now() int64       { return time.Now().Unix() }
func heightNow() int64 { return runtime.ChainHeight() }

// pad gives fixed-width tree keys so that ids sort in numeric order
// (ufmt has no zero padding).
func pad(n int64) string {
	if n < 0 {
		panic("pad: negative id")
	}
	s := ufmt.Sprintf("%d", n)
	for len(s) < 12 {
		s = "0" + s
	}
	return s
}

func addTrail(role, text string) {
	trailSeq++
	trail.Set(pad(trailSeq), &entry{height: heightNow(), t: now(), role: role, text: text})
	chain.Emit("Charterbook", "role", role, "text", text)
}

// assertMasterKey refuses any transaction signed by a session key. Every
// role function calls it (design review 1, B2).
func assertMasterKey() {
	if _, _, _, isSession := runtime.GetSessionInfo(); isSession {
		panic("master key required: session keys are refused")
	}
}

func onlyRole(cur realm, want address, name string) {
	assertMasterKey()
	if !launched {
		panic("fund not launched")
	}
	if cur.Previous().Address() != want {
		panic(name + " only")
	}
	if cur0.state == stateClosed && want != auditor {
		panic("the fund is closed") // the auditor may still record the last years
	}
}

func isRole(a address) bool {
	return a == manager || a == administrator || a == reviewer || a == officer || (auditor != "" && a == auditor) || a == deployer
}

// isFundAccount reports whether a is one of the fund's own accounts.
func isFundAccount(a address) bool {
	return a == fundAddr() || a == cashAddr() || a == escrowAddr() || (nomineeAddr != "" && a == nomineeAddr)
}

func requireState(s int) {
	if cur0.state != s {
		panic("not allowed in state " + stateNames[cur0.state])
	}
}

func requireLaunched() {
	if !launched {
		panic("fund not launched")
	}
	requireNotClosed()
}

// StallSeconds: once a period has sat in Cut-off or NAV proposed this long,
// investors may take their subscriptions back out of escrow (review I2).
const StallSeconds int64 = 7 * 24 * 60 * 60

func stalled() bool {
	return (cur0.state == stateCutOff || cur0.state == stateProposed) && now() >= cur0.cutAt+StallSeconds
}

func requireOpenOrStalled() {
	if cur0.state != stateOpen && !stalled() {
		panic("not allowed in state " + stateNames[cur0.state])
	}
}

func getHolder(a address) *holder {
	if v := holders.Get(a.String()); v != nil {
		return v.(*holder)
	}
	return nil
}

func getStatus(a address) *status {
	if v := eligibility.Get(a.String()); v != nil {
		return v.(*status)
	}
	return nil
}

func isEligible(a address) bool {
	s := getStatus(a)
	return s != nil && s.eligible && !s.restricted && now() < s.expiresAt
}

func isRestricted(a address) bool {
	s := getStatus(a)
	return s != nil && s.restricted
}

// held reports whether an order of holder w paid through payee is held by
// a restriction: of the wallet for a direct holder; of the nominee for its
// sub-accounts, which the fund never restricts one by one (review 2, I4).
func held(w, payee address) bool {
	if nomineeAddr != "" && payee == nomineeAddr {
		return isRestricted(payee)
	}
	return isRestricted(w)
}

// isSubAccount reports whether a is a nominee sub-account's register entry.
func isSubAccount(a address) bool { return subAccounts.Has(a.String()) }

func getSub(id int64) *subscription {
	v := subs.Get(pad(id))
	if v == nil {
		panic("unknown or closed subscription")
	}
	return v.(*subscription)
}

func getRed(id int64) *redemption {
	v := reds.Get(pad(id))
	if v == nil {
		panic("unknown or closed redemption request")
	}
	return v.(*redemption)
}

func getInstrument(name string) *instrument {
	v := instruments.Get(name)
	if v == nil {
		panic("unknown instrument " + name)
	}
	return v.(*instrument)
}

func instrumentsTotal() int64 {
	var t int64
	for _, n := range instrOrder {
		t = addChecked(t, getInstrument(n).book)
	}
	return t
}

func addChecked(a, b int64) int64 {
	c := a + b
	if (b > 0 && c < a) || (b < 0 && c > a) {
		panic("overflow")
	}
	return c
}

func checkCommitment(c string) {
	if len(c) != 64 {
		panic("commitment must be a 64-character hex SHA-256")
	}
	for _, r := range c {
		if !(r >= '0' && r <= '9' || r >= 'a' && r <= 'f') {
			panic("commitment must be lowercase hex")
		}
	}
}

func checkCode(c string) {
	if len(c) == 0 || len(c) > 32 {
		panic("reason code must be 1 to 32 characters")
	}
	for _, r := range c {
		if !(r >= 'a' && r <= 'z' || r >= '0' && r <= '9' || r == '-') {
			panic("reason code: a-z, 0-9 and - only")
		}
	}
}

func checkErr(err error) {
	if err != nil {
		panic(err.Error())
	}
}

func fmtAmt(v int64) string {
	neg := ""
	if v < 0 {
		neg = "-"
		v = -v
	}
	s := ufmt.Sprintf("%d", v/u)
	var b strings.Builder
	for i, r := range s {
		if i > 0 && (len(s)-i)%3 == 0 {
			b.WriteByte(',')
		}
		b.WriteRune(r)
	}
	return neg + b.String() + "." + frac6(v%u)
}

// frac6 writes 0..999999 with six digits (ufmt has no zero padding).
func frac6(f int64) string {
	s := ufmt.Sprintf("%d", f)
	for len(s) < 6 {
		s = "0" + s
	}
	return s
}

// pct writes basis points as a percentage, e.g. 150 -> "1.50%".
func pct(bps int64) string {
	f := ufmt.Sprintf("%d", bps%100)
	if len(f) < 2 {
		f = "0" + f
	}
	return ufmt.Sprintf("%d", bps/100) + "." + f + "%"
}

func valueOfShares(shares int64) int64 {
	if lastNAVps <= 0 || shares <= 0 {
		return 0
	}
	return fundmath.MulDivDown(shares, lastNAVps, u)
}

// addShares and removeShares keep the nominee totals in step.
func addShares(h *holder, q int64) {
	if h.viaNominee {
		if h.shares == 0 && q > 0 {
			nomineeAccounts++
		}
		nomineeShares += q
	}
	h.shares += q
	sharesInIssue += q
}

func removeShares(h *holder, q int64) {
	if q > h.shares {
		panic("settlement: cancellation exceeds holding")
	}
	h.shares -= q
	sharesInIssue -= q
	if h.viaNominee {
		nomineeShares -= q
		if h.shares == 0 {
			nomineeAccounts--
		}
	}
}

func owedTo(a address) int64 {
	if v := owed.Get(a.String()); v != nil {
		return v.(int64)
	}
	return 0
}

// payOrOwe pays amount (plus anything already owed) to payee from the cash
// account, as far as the recorded cash goes; the rest is owed and deducted
// from NAV until paid. It returns what was paid.
func payOrOwe(cur realm, payee address, amount int64) int64 {
	prev := owedTo(payee)
	due := addChecked(prev, amount)
	if due == 0 {
		return 0
	}
	p := due
	if p > bookCash {
		p = bookCash
	}
	if p < 0 {
		p = 0
	}
	if p > 0 {
		c := cur.Sub(cashSub)
		checkErr(token.RealmTeller(0, c).Transfer(0, c, payee, p))
		bookCash -= p
	}
	if due-p == 0 {
		owed.Remove(payee.String())
	} else {
		owed.Set(payee.String(), due-p)
	}
	totalOwed += due - p - prev
	return p
}

func getProvider(name string) address {
	v := providers.Get(name)
	if v == nil {
		panic("unknown service provider " + name)
	}
	return v.(address)
}

func isSuspended() bool { return now() < suspendedUntil }

func requireNotClosed() {
	if cur0.state == stateClosed {
		panic("the fund is closed")
	}
}
