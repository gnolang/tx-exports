// Realm netting is a multilateral obligation clearing register in GNOT.
// A convenor opens a netting set and admits members; each member
// declares, against other members, what it owes them; closing the set
// computes every member's NET position — what it is owed minus what it
// owes — and only those net amounts move. Net debtors pay in, net
// creditors withdraw, and a graph of G gross obligations collapses to at
// most N-1 transfers.
//
// WHY THIS EXISTS (see DISCOVERY.md): across 641 live packages on
// gnoland-1 and 637 on onyx-1, thirteen chains mirrored in
// gnolang/tx-exports, and GitHub-wide `extension:gno`, no package
// records BILATERAL obligations between pairs of parties, computes net
// positions, or compresses gross obligations into net transfers. The two
// closest artifacts were read in full — mainnet
// p/moul/x/daily/pullpayment/v0 and r/moul/x/daily/splitter/v1 — and
// both fail on the same structural point: their ledgers are keyed by
// PAYEE ALONE, so there is no payer axis, no directed graph, and nothing
// to net. Both are ports of Solidity's canonical primitives, and both
// ports kept the one-dimensional ledger.
//
// THE DELTA IS STATED AT ITS REAL SIZE AND NO LARGER. Multilateral
// netting is not a new idea — it is CLS, ACH, Sardex, the Romanian
// Ministry of Economy's national setoff, and a literature of graph
// algorithms (DISCOVERY.md § out-of-language prior art). What is new
// here is a Gno implementation, with this portfolio's live-validated
// custody discipline. Nothing more is claimed.
//
// WHAT NETTING IS WORTH, HONESTLY: compression requires MUTUALITY. A
// star graph — every member owing one hub and the hub owing nobody —
// nets to itself, and the gross and net figures are identical. This
// realm therefore REPORTS the gross and net terms (Compression) and
// never asserts a saving. Read the two pairs of numbers; the ratio is
// whatever the members' obligations make it.
//
// COMPOSITION: coin movement is delegated to coinio, fee arithmetic and
// the fee pot to feeledger, the declaration window and exactly-once
// settlement authorization to duebook, ordered storage to p/nt/avl/v0,
// and free-text render output to the ecosystem sanitizer
// p/nt/markdown/sanitize/v0. This realm owns only the netting
// arithmetic, the set state machine, and the conservation bookkeeping.
//
// A NETTING SET HOLDS NO COINS WHILE IT IS OPEN. An obligation is a
// DECLARATION, not a transfer: Declare moves no value and locks none.
// Coins enter only at Settle, after the set has closed and net positions
// are frozen. This is why Cancel and Lapse need no refund path at all —
// there is nothing held to refund — and it is the sharpest difference
// between this realm and the escrow family the discovery gate found.
//
// NET POSITIONS ARE MAINTAINED INCREMENTALLY, NOT COMPUTED AT CLOSE.
// Each Declare applies -amount to the debtor and +amount to the creditor
// in the same transaction, so the vector of net positions sums to zero
// by construction at every height. Close asserts that sum is zero anyway
// (netsSumToZero) before a single coin can be asked for. The assertion
// is unreachable through the public API and is kept because it is the
// one invariant whose violation would mint or destroy value.
//
// THE SETTLEMENT IS ONE DEFERRAL. Open schedules exactly one duebook
// deferral per set — owner: the convenor, due: the declaration deadline,
// expiry: the end of the closing window — and the three transitions out
// of [open] are the three ways that deferral can be consumed:
//
//	Close  -> book.Claim   (due, not expired; ANYONE)
//	Cancel -> book.Cancel  (convenor renounces, while open)
//	Lapse  -> book.Expire  (anyone, once the closing window is over)
//
// Because duebook consumes a deferral before returning and never reuses
// an ID, a set can leave [open] AT MOST ONCE, structurally. The book's
// open-deferral cap is likewise this realm's cap on open sets.
//
// LIFECYCLE (stored states in brackets):
//
//	Open (anyone)            : opens [open]; caller is the convenor;
//	                           schedules the deferral.
//	Admit (convenor)         : adds a member, while [open]. Admission
//	                           obligates nobody: it only makes an
//	                           address a legal endpoint of a declaration.
//	Declare (member)         : "I owe this member X". Caller is ALWAYS
//	                           the debtor, so a declaration can only ever
//	                           increase the CALLER's own net debit. No
//	                           coins move.
//	Close (ANYONE)           : height in [deadline, closeEnd). Freezes
//	                           every net position. netValue == 0 (a fully
//	                           circular graph) settles on the spot with
//	                           no coins ever held -> [settled]. Otherwise
//	                           -> [settling] with a pay-in window.
//	Settle (net debtor,+send): exactly the debtor's own net debit, once,
//	                           while [settling] and before settleEnd. The
//	                           last payment that completes the set
//	                           credits every net creditor -> [settled].
//	Abandon (ANYONE)         : [settling], settleEnd reached, still
//	                           short. Every debtor who paid gets exactly
//	                           what it paid back, FEE-FREE -> [abandoned].
//	Cancel (convenor)        : while [open] -> [cancelled]. No coins are
//	                           held, so nothing is refunded.
//	Lapse (ANYONE)           : [open] and closeEnd reached -> [lapsed].
//	                           The permissionless valve: a set nobody
//	                           closes cannot hold its duebook slot
//	                           forever.
//	Withdraw (any creditor)  : the caller's whole credit balance, in
//	                           coins. Pull-only; this realm never pushes.
//	Prune (ANYONE)           : removes a terminal set holding no coins.
//	                           The freed storage deposit is refunded by
//	                           the chain to the CALLER, which is the
//	                           incentive to call it.
//	WithdrawFees (ANYONE)    : pays the accrued fee pot to the
//	                           compile-time FeeCollector.
//	SweepSurplus (ANYONE)    : out-of-band coins to the FeeCollector,
//	                           never touching tracked liabilities.
//
// ALL-OR-NOTHING, AND WHAT IT COSTS: a net creditor is credited only
// once EVERY net debtor has paid in full. One defaulting debtor
// therefore denies every creditor in that set — and the compensation is
// that no creditor is ever credited a ugnot the realm does not already
// hold, and every debtor who paid gets its money back fee-free. A
// partial-settlement design would pay some creditors from other
// debtors' money and need a rule for who; there is no such rule here
// because there is no such case.
//
// THE FEE, precisely: feeBps is snapshotted at Open from the
// compile-time SettleFeeBps, so a set's terms are fixed when it is
// created and visible in SetInfo from that moment. It is charged ONCE,
// at the moment a set becomes [settled], on each net creditor's credit,
// with feeledger's floor rounding (rounding favors the creditor). The
// ledger is constructed with the compile-time MaxFeeBps cap, so a fee
// above the cap is refused by the primitive, not by a check in this
// file. There is no fee on declaring, no fee on settling, and NO FEE ON
// ANY ABANDON REFUND.
//
// THERE IS NO ADMIN. The fee rate, the fee collector, every bound and
// every window are compile-time constants; no address can change terms,
// pause the realm, or touch a set it does not convene. The convenor's
// only powers are admitting members and cancelling its own set while it
// is open — neither of which can move a coin. The deployer has no
// privilege of any kind after deployment.
//
// MONETARY INVARIANT (conservation): let H be the ugnot held at this
// realm's address, P the sum of coins paid in for sets still [settling]
// (tracked O(1) as totalPending), L the ledger's liabilities (unclaimed
// creditor credits, unclaimed abandon refunds, and the fee pot), and
// S >= 0 the out-of-band surplus:
//
//	H == P + L + S
//
// Every transition moves value between exactly two terms inside one
// transaction: Settle raises H and P together (coinio.Receive is the
// receipt-guaranteed shape); completing a set moves netValue out of P
// and into L, split into creditor credits and the fee; Abandon moves
// paidIn out of P and into L fee-free; Withdraw and WithdrawFees debit L
// before the identical amount leaves H (checks-effects-interactions);
// any panic aborts the whole transaction; this realm never issues or
// removes coins.
//
// ONLY GNOT IS ACCEPTED: Settle rejects any envelope that is not exactly
// one positive ugnot coin (coinio.Receive). Every other entrypoint
// rejects attached coins outright rather than converting them into
// sweepable surplus.
//
// AUTHORIZATION: every identity is derived from the crossing
// entrypoint's cur.Previous().Address(). No function takes a caller
// identity as a parameter, so declaring a debt as another member,
// settling another member's net debit, or withdrawing another
// creditor's balance is impossible by construction.
//
// STORAGE: a set record is paid for by the convenor's transaction
// deposit, a member record by the convenor's Admit, and a pair record by
// the declaring debtor's own transaction. Completing or abandoning a set
// drops nothing; Prune removes the whole terminal record, and the chain
// refunds the freed deposit to the transaction that frees it.
package netting

import (
	"chain"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"

	"gno.land/p/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/coinio"
	"gno.land/p/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/duebook"
	"gno.land/p/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/feeledger"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/markdown/sanitize/v0"
)

// RealmPath is this realm's own path, used to build Render links.
const RealmPath = "/r/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/netting"

// Denom is the only asset this realm holds.
const Denom = "ugnot"

// MaxFeeBps is the hard ceiling on any fee this realm could ever charge,
// enforced by the feeledger the realm is constructed with — a feeBps
// above it is refused by the primitive's own validation, not by a check
// in this file. 500 bps = 5%.
const MaxFeeBps = int64(500)

// SettleFeeBps is the fee actually snapshotted into every set at Open:
// 100 bps = 1%, charged once, when the set becomes settled, on each net
// creditor's credit, floor-rounded in the creditor's favor. 1% is the
// most conservative live fee in this portfolio (fee_split precedent) and
// is what crowdfund charges.
const SettleFeeBps = int64(100)

// FeeCollector receives withdrawn fees and swept surplus. Compile-time
// constant: there is no setter and no transfer path. It is the deploying
// namespace's address — stated plainly: the operator of this realm.
const FeeCollector = address("g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3")

// MinObligation keeps dust declarations out of the graph: 0.001 GNOT.
// Declaring costs no coins, so the only thing a dust declaration wastes
// is the declarer's own storage deposit — but a graph full of 1-ugnot
// edges makes the compression figures meaningless, which is the output
// this realm exists to produce.
const MinObligation = int64(1_000)

// MaxMembers caps one set's membership. Close iterates the member tree
// twice (once to assert the nets sum to zero, once to freeze positions),
// and completing a set iterates it once more to credit creditors, so
// this is the bound that keeps every O(M) pass inside a transaction's
// gas. 32 is deliberately modest: a clearing set is a counterparty
// group, not a population.
const MaxMembers = 32

// MaxPairs caps the DISTINCT ordered (debtor, creditor) pairs one set
// may hold. Declarations themselves are unbounded in count — a repeat
// declaration between an existing pair accumulates into that pair's
// record and allocates nothing — so this bounds storage, not activity.
// MaxMembers*(MaxMembers-1) == 992 is the complete digraph; 256 is a
// deliberate fraction of it.
const MaxPairs = 256

const (
	// MinDeclareBlocks and MaxDeclareBlocks bound the declaration
	// window, in blocks, and are enforced by the duebook's own Schedule
	// validation rather than by a check in this file.
	MinDeclareBlocks = int64(1_200)
	MaxDeclareBlocks = int64(1_300_000)
)

// CloseWindowBlocks is how long after the deadline a set may still be
// closed. Past it, Close is impossible (the deferral has expired) and
// Lapse is the only way out — which strands no money, because an open
// set holds none.
const CloseWindowBlocks = int64(650_000)

// SettleWindowBlocks is how long net debtors have to pay in after a set
// closes. Past it, Abandon refunds every payer fee-free.
const SettleWindowBlocks = int64(650_000)

// MaxOpenSets caps simultaneously open sets, via the duebook's own
// open-deferral cap. The AVAILABILITY BOUND this implies is stated
// rather than hidden: when the book is full, Open fails until a set is
// closed, cancelled or lapsed. Settling and terminal sets do not occupy
// a slot — their deferral is already consumed.
const MaxOpenSets = 1024

// MaxOpenPerConvenor bounds how much of the global cap one convenor may
// occupy (permission_registry R1 precedent: an uncapped per-principal
// share of a global cap is a griefing vector, not a feature).
const MaxOpenPerConvenor = 64

const (
	// MaxLabelLen and MaxMemoLen bound the free text a set carries. Both
	// are sanitized before they reach Render.
	MaxLabelLen = 100
	MaxMemoLen  = 256
)

// MaxRenderRows bounds the list length on the render pages.
const MaxRenderRows = 50

// set states. "open" and "settling" are the two non-terminal states;
// "settling" is the only state in which this realm holds coins for a
// set.
const (
	stateOpen      = "open"
	stateSettling  = "settling"
	stateSettled   = "settled"
	stateAbandoned = "abandoned"
	stateCancelled = "cancelled"
	stateLapsed    = "lapsed"
)

// member is one party to a netting set.
//
// net is maintained incrementally by Declare and is the whole of the
// netting arithmetic: positive means the member is owed that much on
// balance, negative means it owes that much. debit and credit are
// FROZEN AT CLOSE from net, so that the settlement figures cannot move
// after coins have been asked for.
type member struct {
	addr   address
	net    int64 // + owed to them, - they owe; live while [open]
	debit  int64 // frozen at Close: -net when net < 0, else 0
	credit int64 // frozen at Close: net when net > 0, else 0
	paid   int64 // coins received from this member during [settling]

	grossOut int64 // gross declared BY them (for the compression view)
	grossIn  int64 // gross declared TOWARD them
}

type set struct {
	id        int64
	convenor  address
	label     string
	memo      string
	feeBps    int64 // snapshotted at Open
	createdAt int64
	deadline  int64 // createdAt + declareBlocks; declaring while height < deadline
	closeEnd  int64 // deadline + CloseWindowBlocks; == deferral ExpiresAt
	settleEnd int64 // set at Close; 0 while [open]
	defID     uint64
	state     string

	members   *avl.Tree // member address string -> *member
	pairs     *avl.Tree // pairKey(debtor, creditor) -> int64 (> 0)
	pairCount int

	grossCount int64 // declarations accepted
	grossValue int64 // sum of every declared amount

	// frozen at Close.
	netTransferCount int64 // members with a non-zero net position
	netValue         int64 // total net debits == total net credits
	closedAt         int64

	paidIn int64 // coins currently held for this set; 0 unless [settling]
}

var (
	self address

	sets   = avl.NewTree() // padID(id) -> *set
	nextID int64

	// openByConvenor tracks each convenor's still-open sets:
	// address string -> int64 count (> 0).
	openByConvenor = avl.NewTree()

	// totalPending is the P term of H == P + L + S: the sum of paidIn
	// across every set, maintained O(1) at every transition. Only a
	// [settling] set can have a non-zero paidIn.
	totalPending int64

	// lifetime counters, rendered for operators.
	lifetimeSets       int64 // sets that reached [settled]
	lifetimeGrossValue int64 // declared value across every closed set
	lifetimeNetValue   int64 // net value across every closed set
	lifetimeSettledIn  int64 // coins paid in by net debtors
	lifetimeCredited   int64 // credited to net creditors, net of fee
	lifetimeRefunded   int64 // returned by Abandon, fee-free
	lifetimeWithdrawn  int64 // paid out of the ledger to creditors

	// ledger carries BOTH the net-creditor credits and the abandon
	// refunds, which is what collapses two liability buckets into one
	// tracked Liabilities() term. It also owns the fee cap and the fee
	// pot.
	ledger = feeledger.MustNew(MaxFeeBps)

	// book holds one open deferral per open set. The declaration-window
	// bounds are the primitive's own validation: a window outside
	// [MinDeclareBlocks, MaxDeclareBlocks] is refused by Schedule.
	book = duebook.MustNew(MinDeclareBlocks, MaxDeclareBlocks, MaxOpenSets)
)

func init() {
	self = unsafe.CurrentRealm().Address()
}

// rejectStraySend aborts when coins are attached to a non-payable call.
// This realm holds funds, so a stray send would become sweepable
// surplus, silently converting a user's coins into operator funds.
// Aborting reverts the transfer instead. Guarded on IsUserCall, not
// IsUser, because a MsgRun ephemeral can consume the OriginSend envelope
// before forwarding control; for a realm-routed call the envelope lands
// at the intermediary, so there is nothing here to reject and the guard
// deliberately fails open (crowdfund and treasury_board document the
// same scope).
func rejectStraySend(cur realm) {
	if !cur.IsCurrent() {
		// Every call site forwards a crossing entrypoint's own live cur,
		// so this cannot fire today; it exists so a future refactor that
		// hands this guard a stale realm value fails closed, not open
		// (coinio names IsCurrent as the guard secondary realm
		// parameters require, and this helper follows that discipline).
		panic("netting: realm capability is not current")
	}
	if cur.Previous().IsUserCall() && len(unsafe.OriginSend()) > 0 {
		panic("this entrypoint does not accept coins")
	}
}

// --- set lifecycle ---

// Open convenes a netting set and returns its id. Anyone may open one;
// the caller becomes the convenor. The fee terms (SettleFeeBps at this
// moment — a compile-time constant, so always SettleFeeBps) are
// snapshotted into the set and are fixed from here on. declareBlocks is
// the length of the declaration window and must be within
// [MinDeclareBlocks, MaxDeclareBlocks] — enforced by the duebook.
//
// The convenor is NOT automatically a member. A convenor that wants to
// net its own obligations must Admit itself, which keeps "who runs the
// set" and "who is party to it" separate concepts.
func Open(cur realm, label, memo string, declareBlocks int64) int64 {
	rejectStraySend(cur)
	convenor := cur.Previous().Address()

	if label == "" {
		panic("label must not be empty")
	}
	if len(label) > MaxLabelLen {
		panic("label exceeds " + strconv.Itoa(MaxLabelLen) + " bytes")
	}
	if len(memo) > MaxMemoLen {
		panic("memo exceeds " + strconv.Itoa(MaxMemoLen) + " bytes")
	}

	key := convenor.String()
	if convenorOpen(key) >= MaxOpenPerConvenor {
		panic("convenor already has " + strconv.Itoa(MaxOpenPerConvenor) +
			" open sets")
	}

	now := runtime.ChainHeight()
	id := nextID + 1

	// The deferral is the settlement authorization: due at the
	// declaration deadline, expiring when the closing window ends.
	// Window bounds and the global open-set cap are enforced here by the
	// primitive.
	//
	// nextID advances only AFTER the deferral exists. On chain the
	// distinction is invisible — a panic reverts the whole transaction —
	// but it keeps "an id was issued" and "a set exists" from diverging
	// under any future refactor that recovers instead of aborting, and it
	// is what lets the test suite assert an exact id after a refused Open.
	defID := book.MustSchedule(key, itoa(id), now, declareBlocks, CloseWindowBlocks)
	nextID = id

	s := &set{
		id:        id,
		convenor:  convenor,
		label:     label,
		memo:      memo,
		feeBps:    SettleFeeBps,
		createdAt: now,
		deadline:  now + declareBlocks,
		closeEnd:  now + declareBlocks + CloseWindowBlocks,
		defID:     defID,
		state:     stateOpen,
		members:   avl.NewTree(),
		pairs:     avl.NewTree(),
	}
	sets.Set(padID(id), s)
	bumpConvenor(key, 1)

	chain.Emit("SetOpened", "id", itoa(id), "convenor", key,
		"deadline", itoa(s.deadline), "closeEnd", itoa(s.closeEnd))
	return id
}

// Admit adds an address to a set's membership while the set is open.
// Convenor only.
//
// ADMISSION OBLIGATES NOBODY. Being a member only makes an address a
// legal endpoint of a declaration — it cannot be made a debtor by
// anyone but itself (see Declare). What admission does control is the
// griefing surface: without it, any address could fill a set to MaxPairs
// with declarations naming strangers, and the convenor could not form
// the group it meant to form.
func Admit(cur realm, id int64, addr address) {
	rejectStraySend(cur)
	s := mustOpen(id)
	if cur.Previous().Address() != s.convenor {
		panic("convenor only")
	}
	if addr == "" {
		panic("member address must not be empty")
	}
	key := addr.String()
	if s.members.Has(key) {
		panic("already a member")
	}
	if s.members.Size() >= MaxMembers {
		panic("set already has " + strconv.Itoa(MaxMembers) + " members")
	}
	s.members.Set(key, &member{addr: addr})

	chain.Emit("Admitted", "id", itoa(s.id), "member", key,
		"members", strconv.Itoa(s.members.Size()))
}

// Declare records that the CALLER owes a fellow member `amount` ugnot,
// while the set is open. No coins move and none are locked: an
// obligation is a declaration, and the only value this realm ever holds
// arrives at Settle.
//
// The caller is ALWAYS the debtor. That is the whole authorization
// model here and it is worth saying plainly: a declaration can only
// increase the caller's own net debit and some other member's net
// credit, so no address can be made to owe anything by anyone else.
// Declaring repeatedly toward the same creditor accumulates into one
// pair record and allocates no new storage.
func Declare(cur realm, id int64, creditor address, amount int64) {
	rejectStraySend(cur)
	debtorAddr := cur.Previous().Address()
	s := mustOpen(id)
	if runtime.ChainHeight() >= s.deadline {
		panic("declaration window is closed")
	}
	if amount < MinObligation {
		panic("declare at least " + itoa(MinObligation) + Denom)
	}
	if creditor == debtorAddr {
		panic("cannot owe yourself")
	}

	dKey := debtorAddr.String()
	cKey := creditor.String()
	d := memberOf(s, dKey)
	if d == nil {
		panic("caller is not a member of this set")
	}
	c := memberOf(s, cKey)
	if c == nil {
		panic("creditor is not a member of this set")
	}

	pk := pairKey(dKey, cKey)
	prior := pairAmount(s, pk)
	newPair, ok := checkedAdd(prior, amount)
	if !ok {
		panic("pair obligation would overflow")
	}
	if prior == 0 && s.pairCount >= MaxPairs {
		panic("set already has " + strconv.Itoa(MaxPairs) + " obligation pairs")
	}

	// -amount on the debtor, +amount on the creditor, in one transaction.
	// checkedAdd handles a negative addend, and amount is strictly
	// positive here, so -amount can never be math.MinInt64.
	newDebtorNet, ok := checkedAdd(d.net, -amount)
	if !ok {
		panic("debtor net position would overflow")
	}
	newCreditorNet, ok := checkedAdd(c.net, amount)
	if !ok {
		panic("creditor net position would overflow")
	}
	newGrossOut, ok := checkedAdd(d.grossOut, amount)
	if !ok {
		panic("gross outgoing would overflow")
	}
	newGrossIn, ok := checkedAdd(c.grossIn, amount)
	if !ok {
		panic("gross incoming would overflow")
	}
	newGrossValue, ok := checkedAdd(s.grossValue, amount)
	if !ok {
		panic("set gross value would overflow")
	}
	newGrossCount, ok := checkedAdd(s.grossCount, 1)
	if !ok {
		panic("set gross count would overflow")
	}

	if prior == 0 {
		s.pairCount++
	}
	s.pairs.Set(pk, newPair)
	d.net = newDebtorNet
	c.net = newCreditorNet
	d.grossOut = newGrossOut
	c.grossIn = newGrossIn
	s.grossValue = newGrossValue
	s.grossCount = newGrossCount

	chain.Emit("Declared", "id", itoa(s.id), "debtor", dKey,
		"creditor", cKey, "amount", itoa(amount),
		"pairTotal", itoa(newPair))
}

// Close freezes every net position in a set and opens the pay-in window.
// Anyone may call it, from the declaration deadline until the closing
// window ends; the duebook Claim consumes the set's deferral, so this
// can succeed at most once per set, ever.
//
// A set whose net value is ZERO — every member's obligations exactly
// cancelled, which is what a fully circular graph produces — settles on
// the spot. No coins are ever asked for, held, or paid, and the gross
// value is extinguished in one transaction. That case is the whole
// point of the realm, so it is the fast path rather than a special one.
func Close(cur realm, id int64) {
	rejectStraySend(cur)
	s := mustOpen(id)
	now := runtime.ChainHeight()

	// Claim enforces due-and-not-expired and consumes the deferral. The
	// height checks live in the primitive, not here.
	book.MustClaim(s.defID, now)

	// The nets sum to zero by construction (Declare applies -a and +a in
	// one transaction), so this cannot fire through the public API. It is
	// asserted anyway, BEFORE any coin is asked for, because a violation
	// would mean the realm is about to mint or destroy value — the one
	// invariant where failing closed is worth an O(M) pass.
	if sum := netsSumToZero(s); sum != 0 {
		panic("netting: net positions do not sum to zero (" + itoa(sum) + ")")
	}

	var debits, credits, transfers int64
	s.members.Iterate("", "", func(_ string, v any) bool {
		m := v.(*member)
		switch {
		case m.net < 0:
			m.debit = -m.net
			d, ok := checkedAdd(debits, m.debit)
			if !ok {
				panic("total net debits would overflow")
			}
			debits = d
			transfers++
		case m.net > 0:
			m.credit = m.net
			c, ok := checkedAdd(credits, m.credit)
			if !ok {
				panic("total net credits would overflow")
			}
			credits = c
			transfers++
		}
		return false
	})
	if debits != credits {
		panic("netting: net debits and credits disagree")
	}

	s.netValue = debits
	s.netTransferCount = transfers
	s.closedAt = now

	if gv, ok := checkedAdd(lifetimeGrossValue, s.grossValue); ok {
		lifetimeGrossValue = gv
	} else {
		panic("lifetime gross value would overflow")
	}
	if nv, ok := checkedAdd(lifetimeNetValue, s.netValue); ok {
		lifetimeNetValue = nv
	} else {
		panic("lifetime net value would overflow")
	}

	bumpConvenor(s.convenor.String(), -1)

	if debits == 0 {
		// Fully netted. Nothing to pay, nothing to credit, no window.
		s.state = stateSettled
		if n, ok := checkedAdd(lifetimeSets, 1); ok {
			lifetimeSets = n
		} else {
			panic("lifetime sets would overflow")
		}
		chain.Emit("SetClosed", "id", itoa(s.id), "state", s.state,
			"grossCount", itoa(s.grossCount), "grossValue", itoa(s.grossValue),
			"netTransfers", itoa(transfers), "netValue", "0")
		return
	}

	s.state = stateSettling
	s.settleEnd = now + SettleWindowBlocks
	chain.Emit("SetClosed", "id", itoa(s.id), "state", s.state,
		"grossCount", itoa(s.grossCount), "grossValue", itoa(s.grossValue),
		"netTransfers", itoa(transfers), "netValue", itoa(s.netValue),
		"settleEnd", itoa(s.settleEnd))
}

// Settle pays in the caller's own net debit, in full, once. The attached
// envelope must be exactly the caller's frozen net debit — not more, not
// less, and not in instalments. Partial payment is refused rather than
// accommodated: it would leave the set holding money that belongs to
// neither the payer nor any creditor, and a rule for who gets it first.
//
// The payment that completes the set credits every net creditor in the
// same transaction and the set becomes settled.
func Settle(cur realm, id int64) {
	payer, amount := coinio.Receive(0, cur, Denom)
	s := mustGet(id)
	if s.state != stateSettling {
		panic("set is not settling")
	}
	if runtime.ChainHeight() >= s.settleEnd {
		panic("settlement window is closed")
	}

	key := payer.String()
	m := memberOf(s, key)
	if m == nil {
		panic("caller is not a member of this set")
	}
	if m.debit == 0 {
		panic("caller is not a net debtor")
	}
	if m.paid != 0 {
		panic("caller has already settled")
	}
	if amount != m.debit {
		panic("send exactly " + itoa(m.debit) + Denom)
	}

	newPaidIn, ok := checkedAdd(s.paidIn, amount)
	if !ok {
		panic("set pay-in would overflow")
	}
	newPending, ok := checkedAdd(totalPending, amount)
	if !ok {
		panic("total pending would overflow")
	}
	newLifetime, ok := checkedAdd(lifetimeSettledIn, amount)
	if !ok {
		panic("lifetime settled-in would overflow")
	}

	m.paid = amount
	s.paidIn = newPaidIn
	totalPending = newPending
	lifetimeSettledIn = newLifetime

	chain.Emit("Settled", "id", itoa(s.id), "debtor", key,
		"amount", itoa(amount), "paidIn", itoa(s.paidIn),
		"netValue", itoa(s.netValue))

	if s.paidIn == s.netValue {
		completeSet(s)
	}
}

// completeSet converts a fully-funded set's pay-ins into creditor
// credits and marks it settled. It is reached only from Settle, only
// when paidIn == netValue, and it is where the fee is charged.
//
// The ORDER is the conservation argument: paidIn and totalPending are
// debited by exactly netValue, and the identical netValue is deposited
// into the ledger as credits plus fee. feeledger.Deposit credits
// amount-fee and accrues fee, so the two sides agree to the ugnot.
func completeSet(s *set) {
	moved := s.netValue
	s.paidIn = 0
	totalPending -= moved
	s.state = stateSettled

	var credited int64
	s.members.Iterate("", "", func(_ string, v any) bool {
		m := v.(*member)
		if m.credit == 0 {
			return false
		}
		got, _ := ledger.MustDeposit(m.addr.String(), m.credit, s.feeBps)
		c, ok := checkedAdd(credited, got)
		if !ok {
			panic("credited total would overflow")
		}
		credited = c
		return false
	})

	if n, ok := checkedAdd(lifetimeCredited, credited); ok {
		lifetimeCredited = n
	} else {
		panic("lifetime credited would overflow")
	}
	if n, ok := checkedAdd(lifetimeSets, 1); ok {
		lifetimeSets = n
	} else {
		panic("lifetime sets would overflow")
	}

	chain.Emit("SetSettled", "id", itoa(s.id), "netValue", itoa(moved),
		"credited", itoa(credited), "feeBps", itoa(s.feeBps))
}

// Abandon ends a set that reached its settlement deadline still short,
// and credits every debtor who paid exactly what it paid, FEE-FREE.
// Anyone may call it: the outcome is fully determined by the set's own
// state, so there is nothing for a caller to steer.
//
// Net creditors receive nothing on this path, and that is the
// all-or-nothing guarantee working rather than failing: they were never
// credited, so there is no clawback, and no creditor was ever paid from
// another debtor's money.
func Abandon(cur realm, id int64) {
	rejectStraySend(cur)
	s := mustGet(id)
	if s.state != stateSettling {
		panic("set is not settling")
	}
	if runtime.ChainHeight() < s.settleEnd {
		panic("settlement window is still open")
	}
	if s.paidIn == s.netValue {
		// Unreachable: Settle completes the set in the same transaction
		// that makes paidIn equal netValue, so a fully-funded set is
		// never [settling]. Kept so that a future change which defers
		// completion fails closed instead of refunding a settled set.
		panic("set is fully funded")
	}

	returned := s.paidIn
	s.paidIn = 0
	totalPending -= returned
	s.state = stateAbandoned

	var refunded int64
	s.members.Iterate("", "", func(_ string, v any) bool {
		m := v.(*member)
		if m.paid == 0 {
			return false
		}
		// Fee-free, deliberately: the refund path never charges.
		got, _ := ledger.MustDeposit(m.addr.String(), m.paid, 0)
		r, ok := checkedAdd(refunded, got)
		if !ok {
			panic("refunded total would overflow")
		}
		refunded = r
		return false
	})
	if refunded != returned {
		panic("netting: abandon refunds disagree with coins held")
	}
	if n, ok := checkedAdd(lifetimeRefunded, refunded); ok {
		lifetimeRefunded = n
	} else {
		panic("lifetime refunded would overflow")
	}

	chain.Emit("SetAbandoned", "id", itoa(s.id), "shortfall",
		itoa(s.netValue-returned), "refunded", itoa(refunded))
}

// Cancel ends an open set. Convenor only, any time while the set is
// open. No refund path is needed and none exists: an open set holds no
// coins, because a declaration is not a transfer. What members lose is
// the storage deposit and gas they spent declaring, which is stated
// plainly rather than hidden — a convenor can waste a member's gas but
// can never touch a member's money.
func Cancel(cur realm, id int64) {
	rejectStraySend(cur)
	s := mustOpen(id)
	if cur.Previous().Address() != s.convenor {
		panic("convenor only")
	}
	book.MustCancel(s.defID, s.convenor.String())
	s.state = stateCancelled
	bumpConvenor(s.convenor.String(), -1)

	chain.Emit("SetCancelled", "id", itoa(s.id),
		"grossCount", itoa(s.grossCount), "grossValue", itoa(s.grossValue))
}

// Lapse ends an open set whose closing window has passed. Anyone may
// call it. This is the permissionless valve: a set nobody closes cannot
// hold its duebook slot forever, and because an open set holds no coins
// there is nothing stranded by the outcome.
func Lapse(cur realm, id int64) {
	rejectStraySend(cur)
	s := mustOpen(id)
	book.MustExpire(s.defID, runtime.ChainHeight())
	s.state = stateLapsed
	bumpConvenor(s.convenor.String(), -1)

	chain.Emit("SetLapsed", "id", itoa(s.id),
		"grossCount", itoa(s.grossCount), "grossValue", itoa(s.grossValue))
}

// --- creditor withdrawal ---

// Withdraw pays the caller its entire credit balance in coins and
// returns the amount. Pull-only: this realm never pushes a payout, so a
// creditor that cannot receive coins can never block a settlement.
// Credits arrive from a settled set (net of that set's fee) and from an
// abandoned set's refund (fee-free); both land in the same balance.
func Withdraw(cur realm) int64 {
	rejectStraySend(cur)
	caller := cur.Previous().Address()
	key := caller.String()

	amount, err := ledger.WithdrawAll(key)
	if err != nil {
		panic(err)
	}
	if amount == 0 {
		panic("no credit to withdraw")
	}
	if n, ok := checkedAdd(lifetimeWithdrawn, amount); ok {
		lifetimeWithdrawn = n
	} else {
		panic("lifetime withdrawn would overflow")
	}

	coinio.Payout(0, cur, caller, Denom, amount)
	chain.Emit("Withdrawn", "to", key, "amount", itoa(amount))
	return amount
}

// Prune removes a terminal set that holds no coins, reclaiming its
// storage. Anyone may call it: the chain refunds the freed storage
// deposit to the pruning transaction, which is the incentive. Credits
// already in the ledger are unaffected — they are a per-address balance,
// not part of the set record.
func Prune(cur realm, id int64) {
	rejectStraySend(cur)
	s := mustGet(id)
	if s.state == stateOpen || s.state == stateSettling {
		panic("set is not terminal")
	}
	if s.paidIn != 0 {
		panic("set still holds coins")
	}
	sets.Remove(padID(s.id))
	chain.Emit("Pruned", "id", itoa(s.id), "by",
		cur.Previous().Address().String())
}

// --- fees and surplus ---

// WithdrawFees pays the entire accrued fee pot to the compile-time
// FeeCollector. Anyone may call it: the destination is fixed, so there
// is nothing for a caller to steer.
func WithdrawFees(cur realm) int64 {
	rejectStraySend(cur)
	fees := ledger.WithdrawFees()
	if fees == 0 {
		panic("no fees accrued")
	}
	coinio.Payout(0, cur, FeeCollector, Denom, fees)
	chain.Emit("FeesWithdrawn", "to", FeeCollector.String(), "amount", itoa(fees))
	return fees
}

// SweepSurplus sends out-of-band coins to the FeeCollector: for the pot
// denom, everything above tracked liabilities; for any foreign denom,
// the full balance. Pending pay-ins, creditor credits and the fee pot
// are untouchable by construction (coinio.Sweep refuses to dip below the
// reserve). Anyone may call it.
func SweepSurplus(cur realm, denom string) int64 {
	rejectStraySend(cur)
	reserve := int64(0)
	if denom == Denom {
		reserve = Liabilities()
	}
	swept := coinio.Sweep(0, cur, FeeCollector, denom, reserve)
	chain.Emit("Swept", "denom", denom, "to", FeeCollector.String(),
		"amount", itoa(swept))
	return swept
}

// --- views ---

// SetInfo returns a set's fixed terms and live tallies.
func SetInfo(id int64) (convenor address, feeBps, createdAt, deadline,
	closeEnd, settleEnd int64, state string, members int, pairs int,
	paidIn int64) {
	s := mustGet(id)
	return s.convenor, s.feeBps, s.createdAt, s.deadline, s.closeEnd,
		s.settleEnd, s.state, s.members.Size(), s.pairCount, s.paidIn
}

// Compression returns the four numbers the product exists to produce:
// how many obligations were declared and for how much, against how many
// transfers the netting leaves and for how much. The RATIO IS NOT
// RETURNED and is not asserted anywhere — divide them if you want it,
// and note that netValue can legitimately be zero (a fully circular
// graph, the best possible case), which is exactly why no ratio is
// computed here.
//
// While a set is still open the net figures are zero because they are
// frozen at Close, not derived on read.
func Compression(id int64) (grossCount, netTransferCount, grossValue, netValue int64) {
	s := mustGet(id)
	return s.grossCount, s.netTransferCount, s.grossValue, s.netValue
}

// SetLabel returns a set's label, verbatim and unsanitized. Render
// sanitizes; a caller reading the raw value gets the raw value.
func SetLabel(id int64) string { return mustGet(id).label }

// SetMemo returns a set's memo, verbatim and unsanitized.
func SetMemo(id int64) string { return mustGet(id).memo }

// Status returns a set's stored state.
func Status(id int64) string { return mustGet(id).state }

// IsMember reports whether an address is party to a set.
func IsMember(id int64, addr address) bool {
	return memberOf(mustGet(id), addr.String()) != nil
}

// NetOf returns a member's live net position: positive when it is owed
// that much on balance, negative when it owes that much. It is live
// while the set is open and frozen thereafter. A non-member reads 0,
// which is also a member's value when its obligations cancel exactly —
// use IsMember to tell the two apart.
func NetOf(id int64, addr address) int64 {
	if m := memberOf(mustGet(id), addr.String()); m != nil {
		return m.net
	}
	return 0
}

// PositionOf returns a member's frozen settlement figures: what it must
// pay in, what it is owed, and what it has actually paid. All three are
// zero until the set is closed.
func PositionOf(id int64, addr address) (debit, credit, paid int64) {
	if m := memberOf(mustGet(id), addr.String()); m != nil {
		return m.debit, m.credit, m.paid
	}
	return 0, 0, 0
}

// GrossOf returns a member's gross declared flows: what it has declared
// it owes, and what others have declared they owe it. These are the
// uncompressed figures, kept so a reader can see what netting removed.
func GrossOf(id int64, addr address) (out, in int64) {
	if m := memberOf(mustGet(id), addr.String()); m != nil {
		return m.grossOut, m.grossIn
	}
	return 0, 0
}

// Obligation returns the cumulative amount debtor has declared it owes
// creditor in a set. Direction matters: Obligation(id, a, b) and
// Obligation(id, b, a) are different edges and both may be non-zero —
// the graph is directed, and netting them is Close's job, not storage's.
func Obligation(id int64, debtor, creditor address) int64 {
	s := mustGet(id)
	return pairAmount(s, pairKey(debtor.String(), creditor.String()))
}

// MemberCount returns how many addresses are party to a set.
func MemberCount(id int64) int { return mustGet(id).members.Size() }

// NumSets returns how many sets have ever been opened. It is the id
// high-water mark, so it does not decrease when a set is pruned.
func NumSets() int64 { return nextID }

// OpenSets returns how many sets are currently open, via the duebook's
// own open-deferral count.
func OpenSets() int64 { return int64(book.OpenCount()) }

// OpenOf returns how many open sets an address convenes.
func OpenOf(addr address) int64 { return convenorOpen(addr.String()) }

// BalanceOf returns an address's withdrawable credit.
func BalanceOf(addr address) int64 { return ledger.BalanceOf(addr.String()) }

// TotalPending is the P term of the conservation invariant: coins paid
// in for sets that have not yet settled or been abandoned.
func TotalPending() int64 { return totalPending }

// FeesAccrued is the fee pot, withdrawable only to the FeeCollector.
func FeesAccrued() int64 { return ledger.FeesAccrued() }

// Liabilities is everything this realm owes anyone: pending pay-ins plus
// unclaimed credits plus the fee pot.
func Liabilities() int64 { return totalPending + ledger.Liabilities() }

// Held is the realm's actual ugnot balance.
func Held() int64 { return coinio.HeldAt(self, Denom) }

// Surplus is Held minus Liabilities: out-of-band coins, sweepable to the
// FeeCollector. It is never negative in correct operation.
func Surplus() int64 { return Held() - Liabilities() }

// Lifetime returns the realm's cumulative counters: sets settled, gross
// and net value across every closed set, coins paid in, credited to
// creditors, refunded by Abandon, and withdrawn.
func Lifetime() (sets, grossValue, netValue, settledIn, credited,
	refunded, withdrawn int64) {
	return lifetimeSets, lifetimeGrossValue, lifetimeNetValue,
		lifetimeSettledIn, lifetimeCredited, lifetimeRefunded,
		lifetimeWithdrawn
}

// Address returns this realm's own address, which is where coins paid in
// are held.
func Address() address { return self }

// Height returns the chain height this realm sees, so a caller can
// compare it against a deadline without a second query.
func Height() int64 { return runtime.ChainHeight() }

// --- internals ---

// mustGet resolves a set id or aborts.
//
// avl/v0's Get returns ONE value — the stored value, or nil when the key
// is absent — so absence is detected by the type assertion rather than
// by a second boolean return. That is sound here, and sound only because
// this realm never stores a nil under any key in any of its trees: the
// package's own doc warns that a key holding nil is indistinguishable
// from a missing key, which would turn the assertion's ok from "the key
// is present" into "the key is present AND well-typed". Every Set call
// in this file stores a non-nil *set, *member or int64.
func mustGet(id int64) *set {
	s, ok := sets.Get(padID(id)).(*set)
	if !ok {
		panic("no such set")
	}
	return s
}

func mustOpen(id int64) *set {
	s := mustGet(id)
	if s.state != stateOpen {
		panic("set is not open")
	}
	return s
}

func memberOf(s *set, key string) *member {
	if m, ok := s.members.Get(key).(*member); ok {
		return m
	}
	return nil
}

func pairAmount(s *set, pk string) int64 {
	if n, ok := s.pairs.Get(pk).(int64); ok {
		return n
	}
	return 0
}

// pairKey builds the storage key for a directed edge. The separator is a
// newline, which no bech32 address can contain, so two different
// (debtor, creditor) pairs can never collide into one key.
func pairKey(debtor, creditor string) string { return debtor + "\n" + creditor }

// netsSumToZero returns the sum of every member's net position, which
// must be zero. It is a separate O(M) pass rather than folded into
// Close's freezing loop on purpose: the assertion has to hold over the
// WHOLE membership before any position is frozen, and a single loop
// would freeze the early members before it could know about the late
// ones.
func netsSumToZero(s *set) int64 {
	var sum int64
	s.members.Iterate("", "", func(_ string, v any) bool {
		n, ok := checkedAdd(sum, v.(*member).net)
		if !ok {
			panic("net position sum would overflow")
		}
		sum = n
		return false
	})
	return sum
}

func convenorOpen(key string) int64 {
	if n, ok := openByConvenor.Get(key).(int64); ok {
		return n
	}
	return 0
}

func bumpConvenor(key string, delta int64) {
	n := convenorOpen(key) + delta
	switch {
	case n < 0:
		panic("netting: convenor open count went negative")
	case n == 0:
		openByConvenor.Remove(key)
	default:
		openByConvenor.Set(key, n)
	}
}

// checkedAdd adds two int64s and reports whether the result is exact.
//
// STATED LIMIT, because it is the kind that survives a copy-paste into a
// context where it is wrong: the sign test cannot see the one overflow
// where the sum does not move past the addend. checkedAdd(0, MinInt64)
// returns (MinInt64, true) — correct, since 0+MinInt64 is exactly
// MinInt64 — but so does checkedAdd(a, MinInt64) for any a >= 0, where
// the true sum is representable only when a == 0. Nothing here can reach
// it: every addend this realm passes is either positive or the negation
// of a value at or above MinObligation, so MinInt64 is never an operand
// and no accumulator starts at one. The audit raised it as an open
// question and the answer is "unreachable, and worth a comment if this
// helper is ever reused" — so this is the comment, and a caller that can
// supply MinInt64 needs a different helper rather than this one.
func checkedAdd(a, b int64) (int64, bool) {
	sum := a + b
	if (b > 0 && sum < a) || (b < 0 && sum > a) {
		return 0, false
	}
	return sum, true
}

func itoa(n int64) string { return strconv.FormatInt(n, 10) }

// bps renders a basis-point figure as a human percentage, exactly.
func bps(n int64) string {
	whole := n / 100
	frac := n % 100
	if frac == 0 {
		return itoa(whole) + "%"
	}
	if frac%10 == 0 {
		return itoa(whole) + "." + itoa(frac/10) + "%"
	}
	pad := ""
	if frac < 10 {
		pad = "0"
	}
	return itoa(whole) + "." + pad + itoa(frac) + "%"
}

const zeros = "00000000000000000000"

func padID(id int64) string {
	s := strconv.FormatInt(id, 10)
	const width = 20
	if len(s) >= width {
		return s
	}
	return zeros[:width-len(s)] + s
}

func shortAddr(a string) string {
	if len(a) <= 14 {
		return a
	}
	return a[:8] + "…" + a[len(a)-4:]
}

// --- render ---

// Render serves the index at "" and a set page at "<id>".
func Render(path string) string {
	if path == "" {
		return renderIndex()
	}
	id, err := strconv.ParseInt(path, 10, 64)
	if err != nil {
		return "# netting\n\nNot a set id: `" + sanitize.InlineText(path) + "`\n"
	}
	s, ok := sets.Get(padID(id)).(*set)
	if !ok {
		return "# netting\n\nNo set `" + itoa(id) + "`.\n"
	}
	return renderSet(s)
}

func renderIndex() string {
	out := "# netting\n\nMultilateral obligation clearing. Members declare what they owe each other; closing a set nets those obligations and only the net amounts move.\n\n"
	out += "| | |\n|---|---|\n"
	out += "| sets opened | " + itoa(nextID) + " |\n"
	out += "| open now | " + itoa(OpenSets()) + " |\n"
	out += "| settle fee | " + bps(SettleFeeBps) + " |\n"
	out += "| pending pay-ins | " + itoa(totalPending) + " " + Denom + " |\n"
	out += "| unclaimed credit | " + itoa(ledger.Liabilities()-ledger.FeesAccrued()) + " " + Denom + " |\n"
	out += "| fee pot | " + itoa(ledger.FeesAccrued()) + " " + Denom + " |\n"
	out += "| held | " + itoa(Held()) + " " + Denom + " |\n\n"

	gross := lifetimeGrossValue
	net := lifetimeNetValue
	out += "## Lifetime compression\n\n"
	out += "Across every closed set: **" + itoa(gross) + " " + Denom +
		"** of declared obligations required **" + itoa(net) + " " + Denom +
		"** of transfers.\n\n"
	out += "> Netting compresses only where obligations are mutual. A star graph — everyone owing one hub — nets to itself, and these two numbers are equal. Both figures are reported; no saving is claimed and no ratio is computed.\n\n"

	out += "## Sets\n\n"
	if sets.Size() == 0 {
		return out + "_none yet._\n"
	}
	out += "| id | label | state | members | gross | net |\n|---|---|---|---|---|---|\n"
	rows := 0
	sets.ReverseIterate("", "", func(_ string, v any) bool {
		if rows >= MaxRenderRows {
			return true
		}
		s := v.(*set)
		out += "| [" + itoa(s.id) + "](" + RealmPath + ":" + itoa(s.id) + ") | " +
			sanitize.InlineText(s.label) + " | " + s.state + " | " +
			strconv.Itoa(s.members.Size()) + " | " + itoa(s.grossValue) + " | " +
			itoa(s.netValue) + " |\n"
		rows++
		return false
	})
	if sets.Size() > rows {
		out += "\n_showing " + strconv.Itoa(rows) + " of " +
			strconv.Itoa(sets.Size()) + " stored sets._\n"
	}
	return out
}

func renderSet(s *set) string {
	out := "# netting set " + itoa(s.id) + "\n\n## " +
		sanitize.InlineText(s.label) + "\n\n"
	if s.memo != "" {
		out += sanitize.InlineText(s.memo) + "\n\n"
	}
	out += "| | |\n|---|---|\n"
	out += "| state | **" + s.state + "** |\n"
	out += "| convenor | `" + shortAddr(s.convenor.String()) + "` |\n"
	out += "| fee | " + bps(s.feeBps) + " |\n"
	out += "| declare until | height " + itoa(s.deadline) + " |\n"
	out += "| close until | height " + itoa(s.closeEnd) + " |\n"
	if s.settleEnd != 0 {
		out += "| settle until | height " + itoa(s.settleEnd) + " |\n"
	}
	out += "| now | height " + itoa(runtime.ChainHeight()) + " |\n"
	if s.state == stateSettling {
		out += "| paid in | " + itoa(s.paidIn) + " of " + itoa(s.netValue) +
			" " + Denom + " |\n"
	}
	out += "\n## Compression\n\n"
	out += "| | count | value |\n|---|---|---|\n"
	out += "| gross obligations | " + itoa(s.grossCount) + " | " +
		itoa(s.grossValue) + " " + Denom + " |\n"
	out += "| net transfers | " + itoa(s.netTransferCount) + " | " +
		itoa(s.netValue) + " " + Denom + " |\n\n"
	if s.state == stateOpen {
		out += "_Net figures are frozen at Close and read zero until then._\n\n"
	} else if s.netValue == 0 && s.grossValue > 0 {
		out += "**Fully netted: " + itoa(s.grossValue) + " " + Denom +
			" of obligations cleared with no transfer at all.**\n\n"
	}

	out += "## Members\n\n"
	if s.members.Size() == 0 {
		out += "_none admitted._\n\n"
	} else {
		out += "| member | owes (gross) | owed (gross) | net | pay in | receive | paid |\n"
		out += "|---|---|---|---|---|---|---|\n"
		rows := 0
		s.members.Iterate("", "", func(k string, v any) bool {
			if rows >= MaxRenderRows {
				return true
			}
			m := v.(*member)
			out += "| `" + shortAddr(k) + "` | " + itoa(m.grossOut) + " | " +
				itoa(m.grossIn) + " | " + itoa(m.net) + " | " +
				itoa(m.debit) + " | " + itoa(m.credit) + " | " +
				itoa(m.paid) + " |\n"
			rows++
			return false
		})
		if s.members.Size() > rows {
			out += "\n_showing " + strconv.Itoa(rows) + " of " +
				strconv.Itoa(s.members.Size()) + " members._\n"
		}
		out += "\n"
	}

	out += "## Obligations\n\n"
	if s.pairs.Size() == 0 {
		return out + "_none declared._\n"
	}
	out += "| debtor | creditor | amount |\n|---|---|---|\n"
	rows := 0
	s.pairs.Iterate("", "", func(k string, v any) bool {
		if rows >= MaxRenderRows {
			return true
		}
		debtor, creditor := splitPairKey(k)
		out += "| `" + shortAddr(debtor) + "` | `" + shortAddr(creditor) +
			"` | " + itoa(v.(int64)) + " |\n"
		rows++
		return false
	})
	if s.pairs.Size() > rows {
		out += "\n_showing " + strconv.Itoa(rows) + " of " +
			strconv.Itoa(s.pairs.Size()) + " obligation pairs._\n"
	}
	return out
}

// splitPairKey reverses pairKey for render. The separator cannot appear
// inside an address, so the first occurrence is the only one.
func splitPairKey(pk string) (debtor, creditor string) {
	for i := 0; i < len(pk); i++ {
		if pk[i] == '\n' {
			return pk[:i], pk[i+1:]
		}
	}
	return pk, ""
}
