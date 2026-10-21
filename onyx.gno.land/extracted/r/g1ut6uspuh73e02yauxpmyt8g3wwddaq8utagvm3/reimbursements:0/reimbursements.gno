// Realm reimbursements is a claimant-initiated, approver-gated expense
// reimbursement desk in GNOT: an owner funds a pool and appoints an
// approver with a bounded, rate-limited, revocable authority to approve
// against it; anyone may then SUBMIT a request for a specific amount with
// a memo; and the approver either approves it — which settles the money
// into the claimant's credit immediately — or rejects it.
//
// WHY THIS EXISTS (see DISCOVERY.md): request-then-approve is NOT new
// here, and an earlier draft of this comment wrongly claimed it was.
// Three realms in this portfolio already let a requester initiate and a
// second party gate before value moves — grants (applicants apply, the
// creator selects), bounties (a funder designates a winner) and
// bounty_panel (contributors submit, an M-of-N panel votes). The §7
// sweep that found them is recorded in DISCOVERY.md. The claim this
// realm actually rests on is narrower, and all three parts are
// load-bearing:
//
//   - THE REQUESTER PRICES IT. A grant or bounty amount is the funder's
//     offer, fixed before anyone asks. A reimbursement amount is a cost
//     the claimant already incurred, so the claimant names it and the
//     approver's only lever is yes or no on that figure.
//   - SETTLEMENT IS NON-EXCLUSIVE. Those three are competitive awards:
//     escrow is reserved per item and exactly one requester wins. Here an
//     unbounded number of requests settle against one SHARED,
//     UN-ESCROWED pool, which is why a pending request is not a
//     reservation (see below) — the divergence this realm is built on.
//   - THE APPROVER IS RATE-LIMITED. In all three the selecting party may
//     award whenever it likes. Here the approver is not the owner and
//     holds a bounded, windowed, revocable spendbook authority, so an
//     approver key cannot drain the pool.
//
// The four other disbursement shapes here are further away still:
// treasury_board needs the PROPOSER to be a signer, so an outside
// claimant cannot ask; budgets grants authority up front with no
// per-item gate; invoices is a receivable nobody approves; payroll and
// vesting are employer-funded accrual on a schedule.
//
// It is also, deliberately, the SECOND CONSUMER of spendbook, and the
// first with an INVERTED temporal order. budgets consumes authority at
// spend time by the spender. Here the spendbook "spender" is the
// APPROVER, and the authority is consumed at APPROVE time against a
// request a third party submitted. A primitive with one consumer is
// barely proven as a primitive; a second consumer that uses it the same
// way proves little more. This one exercises the opposite direction.
//
// COMPOSITION: approval authority is delegated entirely to spendbook
// (anchored windows, lifetime caps, expiry, one-sided amendments,
// revocation), coin movement to coinio, per-claimant credit and the fee
// pot to feeledger, ordered storage to p/nt/avl/v0, and free-text render
// output to p/nt/markdown/sanitize/v0. This realm owns the pool
// accounting, the desk and request records, the conflict-of-interest
// rule, and the solvency rule.
//
// # A desk, and what an approval IS
//
// A desk is one (owner, approver) pair with a bounded authority over the
// owner's pool. A request is one claimant's ask against one desk.
//
// The DELIBERATE DIVERGENCE from budgets is at approval:
//
//	An approved reimbursement is a SETTLED OBLIGATION, not authority.
//
// Approve moves the gross out of the owner's pool and into the claimant's
// ledger credit in the same call. The owner cannot then withdraw it out
// from under an approved claimant, and no second step can fail. budgets'
// rule — "a budget is authority, not a reservation" — is explicitly NOT
// inherited, because the two realms are answering different questions. A
// budget is an ongoing permission whose point is not pre-committing
// capital. An approved expense claim is a decision about a cost already
// incurred, and a decision that can evaporate is not a decision.
//
// The realm therefore never holds a partially-committed state: a request
// is pending (nothing has moved) or settled (everything has moved).
//
// # A PENDING REQUEST IS NOT A LIABILITY
//
// Stated plainly because the opposite is the natural assumption.
// Submitting reserves nothing, locks nothing, and is not a claim on the
// pool. Ten pending requests of 100 against a pool of 100 are all ten
// submittable; the approver can approve one of them. Liabilities() counts
// pooled funds and settled credit, and a pending request appears in
// neither. What a claimant can rely on is the moment of approval, which
// is atomic, and the Approvable view, which reports the honest figure
// before they are told yes.
//
// # THE APPROVER IS THE SPENDBOOK SPENDER
//
// The desk's allowance is consumed by the GROSS approved amount, so it
// bounds the owner's total OUTFLOW per window rather than the claimant's
// receipt — the figure an owner actually cares about capping, and the same
// treatment budgets gives its fee. An approver with a PerPeriod of 1 GNOT
// can approve 1 GNOT of the owner's money per window no matter how many
// claimants ask, and no single compromised approver key can do more than
// its window allows before the owner revokes the desk.
//
// # SELF-APPROVAL IS PROHIBITED
//
// Approve refuses when the request's claimant is the approving address.
// This is a real conflict-of-interest control and not a formality: an
// approver with a desk could otherwise reimburse themselves at will up to
// the window cap. The rule is per-APPROVAL, not per-desk, so an address
// cannot route its own claim through a second desk it also approves. An
// approver may still submit requests — to be approved by somebody else.
//
// # LIFECYCLE
//
//	Fund (owner, +send)      : adds real coins to the caller's own pool.
//	                           Anyone may fund; funding makes you an
//	                           owner. Minimum MinFunding.
//	WithdrawPool (owner)     : pulls UNSPENT pool back out, any amount,
//	                           any time. Approved credit is already out
//	                           of the pool and unreachable.
//	WithdrawPoolAll (owner)  : the whole unspent pool.
//	OpenDesk (owner)         : appoints one approver with bounded
//	                           authority and returns the desk id. The
//	                           approval fee is snapshotted here.
//	AmendDesk (owner)        : changes the desk's terms. Tighter-or-equal
//	                           applies now; looser waits for the next
//	                           window boundary. periodLength is NOT a
//	                           parameter — spendbook makes it immutable.
//	CloseDesk (owner)        : immediate; the id is never reused.
//	ReapDesk (ANYONE)        : removes an EXPIRED desk, freeing its slot.
//	Submit (ANYONE)          : files a request against a desk for a
//	                           specific amount with a memo, and returns
//	                           the request id. Expires after RequestTTL
//	                           blocks.
//	Approve (APPROVER)       : settles the request — debits the owner's
//	                           pool, credits the claimant net of the fee,
//	                           consumes the desk's authority, removes the
//	                           request.
//	Reject (APPROVER)        : closes the request with a reason. Nothing
//	                           moves. Allowed even after expiry.
//	Retract (CLAIMANT)       : the claimant withdraws their own request.
//	                           Nothing moves. Named Retract, not
//	                           Withdraw, because every Withdraw* in this
//	                           portfolio moves money and this moves none.
//	ExpireRequest (ANYONE)   : removes a request past its expiry.
//	Claim (CLAIMANT)         : pays the claimant's whole settled credit
//	                           out. The portfolio's standard pull.
//	WithdrawFees (ANYONE)    : pays the fee pot to the compile-time
//	                           FeeCollector. Fixed destination.
//	SweepSurplus (ANYONE)    : out-of-band coins to the FeeCollector,
//	                           never touching tracked liabilities.
//
// # A CLOSED DESK LEAVES ITS REQUESTS UN-APPROVABLE
//
// CloseDesk and ReapDesk remove the desk and its allowance. Requests
// filed against it remain as records and can never be approved — Approve
// panics on the missing desk. They can be Retracted by their claimant or,
// once past expiry, ExpireRequested by anyone.
//
// There is deliberately NO CASCADE DELETE. Finding a closed desk's
// requests means iterating the request tree, which is unbounded work in a
// transaction whose gas the owner pays, and an owner who cannot close a
// desk because it has too many pending requests is a worse realm than one
// where closing leaves records to be swept. The condition is documented,
// visible in RequestInfo and on the request's render page, and
// self-clearing within RequestTTL.
//
// # AVAILABILITY BOUND, stated honestly
//
// Submit is permissionless, so the request tree is fillable. The
// per-claimant and per-desk caps bound ONE address and ONE desk, and are
// defeated by many addresses — that is the correct way to read a
// per-identity cap on a permissionless chain, and budgets' own corrected
// comment (finding Y1) is this portfolio's record of getting it wrong the
// other way.
//
// What genuinely helps here, and does not help in budgets, is that a
// request has a MANDATORY expiry: RequestTTL is a compile-time constant,
// every request carries submittedAt + RequestTTL, and ExpireRequest is
// permissionless with the freed storage deposit refunded to the sweeping
// transaction. So the fill is bounded in DURATION as well as priced in
// gas and storage, and it drains itself. budgets' grants with expiresAt
// == 0 can never be reaped by anyone, which is strictly worse. The
// residual is real: for RequestTTL blocks a filled tree blocks NEW
// requests. Every desk, pool, approval, credit and claim keeps working,
// and no value is at risk.
//
// # THERE IS NO ADMIN
//
// The fee rate, the fee collector, the TTL, every bound and every cap are
// compile-time constants. No address can change terms, pause the realm,
// touch a pool it did not fund, approve at a desk it was not appointed
// to, or move a request it did not file. The deployer has no privilege of
// any kind after deployment.
//
// # MONETARY INVARIANT (conservation)
//
// Let H be the ugnot held at this realm's address, P the sum of all owner
// pools (tracked O(1) as totalPooled), L the ledger's liabilities
// (settled claimant credit plus the fee pot), and S >= 0 the out-of-band
// surplus:
//
//	H == P + L + S
//
// Every transition moves value between exactly two terms inside one
// transaction. Fund raises H and P together (coinio.Receive is the
// receipt-guaranteed shape). WithdrawPool debits P before the identical
// amount leaves H. Approve moves the gross out of P and into L, split
// into the claimant's credit and the fee — H does not move at all, which
// is why Approve has no payout to fail. Claim and WithdrawFees debit L
// before their payout. Submit, Reject, Retract and ExpireRequest move
// nothing in any term. Any panic aborts the whole transaction; this realm
// never issues or removes coins.
//
// # ONLY GNOT IS ACCEPTED
//
// Fund rejects any envelope that is not exactly one positive ugnot coin
// (coinio.Receive). Every other entrypoint rejects attached coins
// outright rather than converting them into sweepable surplus.
//
// # AUTHORIZATION
//
// Every identity is derived from the crossing entrypoint's
// cur.Previous().Address(). No function takes a caller identity as a
// parameter, so funding another owner's pool, approving at another
// address's desk, retracting another claimant's request, or claiming
// another claimant's credit is impossible by construction. This is
// spendbook consumer contract item 2, closed structurally.
//
// The clock is runtime.ChainHeight(), never an argument — spendbook
// consumer contract item 1. A caller who could choose `now` could roll
// the approval window at will, and could also expire a request out from
// under its claimant or keep an expired one alive.
//
// # STORAGE
//
// A pool entry is paid for by the owner's own funding transaction; a desk
// record and its allowance by the owner's OpenDesk; a request record by
// the claimant's Submit. CloseDesk, ReapDesk, Approve, Reject, Retract
// and ExpireRequest each remove a record, and the chain refunds the freed
// storage deposit to the transaction that frees it — which is the
// standing incentive to call ExpireRequest or ReapDesk on somebody
// else's stale record.
package reimbursements

import (
	"chain"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"strings"

	"gno.land/p/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/coinio"
	"gno.land/p/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/feeledger"
	"gno.land/p/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/spendbook"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/markdown/sanitize/v0"
)

// RealmPath is this realm's own path, used to build Render links.
const RealmPath = "/r/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/reimbursements"

// Denom is the only asset this realm holds.
const Denom = "ugnot"

// MaxFeeBps is the hard ceiling on any approval fee this realm could ever
// charge, enforced by the feeledger the realm is constructed with — a
// feeBps above it is refused by the primitive's own validation, not by a
// check in this file. 500 bps = 5%.
const MaxFeeBps = int64(500)

// ApprovalFeeBps is the fee actually snapshotted into every desk: 100 bps
// = 1%, charged once per approval on the gross amount, floor-rounded in
// the claimant's favor. The most conservative live fee in this portfolio
// (fee_split, crowdfund, budgets) is also 1%.
const ApprovalFeeBps = int64(100)

// FeeCollector receives withdrawn fees and swept surplus. Compile-time
// constant: there is no setter and no transfer path. It is the deploying
// namespace's address — stated plainly: the operator of this realm.
const FeeCollector = address("g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3")

// MinFunding keeps dust pools out: 1 GNOT per Fund call.
const MinFunding = int64(1_000_000)

// MinPerPeriod is the smallest per-window approval cap a desk may carry.
// It exists so a desk cannot be opened that no approval could ever
// satisfy, and it is paired with MinRequestAmount below rather than
// standing alone.
const MinPerPeriod = int64(1_000)

// MinPeriodBlocks is the shortest window a desk may use. A window of a
// handful of blocks is a rate, not a budget, and it makes PerPeriod
// meaningless as a bound on worst-case loss. A periodLength of 0 is still
// accepted and means ONE LIFETIME WINDOW that never refills (spendbook's
// own semantics).
const MinPeriodBlocks = int64(100)

// MinRequestAmount is the smallest request that may be filed, and it is
// deliberately EQUAL TO MinPerPeriod rather than smaller. The two
// together are what make a desk's authority expressible: a desk whose
// per-window cap is at the floor can still approve a request at the
// floor. Setting this below MinPerPeriod would admit dust requests that
// cost the approver a transaction each; setting it above would create
// desks no request could use.
const MinRequestAmount = int64(1_000)

// RequestTTL is how long a request stays approvable, IN BLOCKS. No
// wall-clock equivalent is stated because onyx-1's block time has never
// been measured by this project, and converting blocks to hours with an
// assumed rate is how a document comes to carry a number nobody checked.
// It is sized to be long enough that an approver need not be online
// continuously and short enough that the request tree drains.
const RequestTTL = int64(86_400)

// MaxLiveDesks caps simultaneously live desks, via spendbook's own
// construction bound. OpenDesk requires a funded pool, which is NOT a
// capital bound — see MaxOpenPerClaimant for why that mistake is not
// repeated here. spendbook's own MaxLiveLimit is 10000.
const MaxLiveDesks = 4096

// MaxDesksPerOwner bounds how much of the global desk cap one owner can
// occupy. spendbook's package documentation names this as the gap a
// consuming realm must close: "maxLive is a single global figure, so any
// owner permitted to Open can exhaust it and lock out the rest … a Book
// shared across mutually untrusting owners needs its own per-owner cap on
// top of this one." This is that cap.
const MaxDesksPerOwner = int64(16)

// MaxLiveRequests caps simultaneously live requests across the realm.
// Submit is permissionless, so this cap is exhaustible, and the package
// doc states that bound rather than claiming the per-identity caps below
// close it.
const MaxLiveRequests = 4096

// MaxOpenPerClaimant bounds one claimant's simultaneously-pending
// requests. It is a GRIEF-COST multiplier and not a defence: one address
// is bounded, N addresses are not, and an attacker controls N. The real
// mitigation is RequestTTL plus permissionless ExpireRequest — see the
// package doc's availability section.
const MaxOpenPerClaimant = int64(16)

// MaxOpenPerDesk bounds the pending requests at one desk, so a single
// desk's approver is not handed an unreviewable queue by one burst. It is
// per-desk, so filling it denies that desk only; other desks are
// unaffected.
const MaxOpenPerDesk = int64(64)

// MaxLabelLen bounds a desk's free-text label.
const MaxLabelLen = 64

// MaxMemoLen bounds a request's free-text memo and a rejection's reason.
// Larger than MaxLabelLen because a memo is the expense description — the
// thing an approver reads to decide — while a label only names a desk.
const MaxMemoLen = 160

// MaxRenderRows bounds the lists on the index page.
const MaxRenderRows = 20

type desk struct {
	id        int64
	owner     address
	approver  address
	allowID   uint64 // the spendbook allowance backing this desk
	feeBps    int64  // snapshotted at OpenDesk
	label     string
	createdAt int64

	approved   int64 // lifetime gross approved through this desk
	approvals  int64
	rejections int64
}

type request struct {
	id          int64
	deskID      int64
	claimant    address
	amount      int64
	feeBps      int64 // snapshotted at Submit from the desk
	memo        string
	submittedAt int64
	expiresAt   int64 // submittedAt + RequestTTL
}

var (
	self address

	// desks holds one record per live desk. CloseDesk and ReapDesk remove
	// the record; ids are never reused.
	desks      = avl.NewTree() // padID(id) -> *desk
	nextDeskID int64

	// requests holds one record per PENDING request. Approve, Reject,
	// Retract and ExpireRequest each remove one; ids are never reused.
	requests  = avl.NewTree() // padID(id) -> *request
	nextReqID int64

	// pools is each owner's unspent funded balance:
	// address string -> int64 (> 0). This is the P term.
	pools = avl.NewTree()

	// desksByOwner tracks each owner's live desk count:
	// address string -> int64 (> 0).
	desksByOwner = avl.NewTree()

	// openByClaimant tracks each claimant's pending request count:
	// address string -> int64 (> 0).
	openByClaimant = avl.NewTree()

	// openByDesk tracks each desk's pending request count:
	// padID(deskID) -> int64 (> 0).
	openByDesk = avl.NewTree()

	// totalPooled is the P term of H == P + L + S, maintained O(1).
	totalPooled int64

	// lifetime counters, rendered for operators.
	lifetimeFunded    int64
	lifetimeSubmitted int64
	// lifetimeApprovals counts REQUESTS settled; lifetimeApproved sums the
	// GROSS ugnot they moved. Two different axes, and keeping only one
	// would force a Render line to imply the other. A per-desk
	// `approvals` field exists too and is NOT a substitute: closing a desk
	// removes its record and therefore its count, while these survive.
	lifetimeApprovals int64
	lifetimeApproved  int64 // gross, before the fee
	lifetimeRejected  int64
	lifetimeRetracted int64
	lifetimeExpired   int64
	lifetimeClaimed   int64 // net, paid to claimants
	lifetimeReturned  int64 // unspent pool withdrawn by owners

	// ledger holds each claimant's settled credit and the fee pot. Its
	// Liabilities() is the L term and the reserve SweepSurplus protects.
	ledger = feeledger.MustNew(MaxFeeBps)

	// book holds one live allowance per live desk. Every bound on
	// approval authority — windows, caps, expiry, amendment direction — is
	// the primitive's, not this file's.
	book = spendbook.MustNew(MaxLiveDesks)
)

func init() {
	self = unsafe.CurrentRealm().Address()
}

// rejectStraySend aborts when coins are attached to a non-payable call.
// This realm holds funds, so a stray send would become sweepable surplus,
// silently converting a user's coins into operator funds. Aborting
// reverts the transfer instead. Guarded on IsUserCall, not IsUser,
// because a MsgRun ephemeral can consume the OriginSend envelope before
// forwarding control; for a realm-routed call the envelope lands at the
// intermediary, so there is nothing here to reject and the guard
// deliberately fails open (budgets, crowdfund and treasury_board document
// the same scope).
func rejectStraySend(cur realm) {
	if !cur.IsCurrent() {
		// Every call site forwards a crossing entrypoint's own live cur,
		// so this cannot fire today; it exists so a future refactor that
		// hands this guard a stale realm value fails closed, not open
		// (coinio names IsCurrent as the guard secondary realm parameters
		// require, and this helper follows that discipline).
		panic("reimbursements: realm capability is not current")
	}
	if cur.Previous().IsUserCall() && len(unsafe.OriginSend()) > 0 {
		panic("this entrypoint does not accept coins")
	}
}

// --- the pool ---

// Fund adds the attached coins to the caller's own pool. Direct EOA calls
// with -send only (the receipt-guaranteed shape); exactly one positive
// ugnot coin, at least MinFunding. Anyone may fund; funding is what makes
// an address an owner.
func Fund(cur realm) int64 {
	owner, amount := coinio.Receive(0, cur, Denom)
	if amount < MinFunding {
		panic("fund at least " + itoa(MinFunding) + Denom)
	}
	key := owner.String()

	newPool, ok := checkedAdd(poolOf(key), amount)
	if !ok {
		panic("pool would overflow")
	}
	newTotal, ok := checkedAdd(totalPooled, amount)
	if !ok {
		panic("total pooled would overflow")
	}
	newLifetime, ok := checkedAdd(lifetimeFunded, amount)
	if !ok {
		panic("lifetime funded would overflow")
	}

	setPool(key, newPool)
	totalPooled = newTotal
	lifetimeFunded = newLifetime

	chain.Emit("Funded", "owner", key, "amount", itoa(amount),
		"pool", itoa(newPool))
	return newPool
}

// WithdrawPool returns part of the caller's UNSPENT pool and reports the
// pool REMAINING afterwards.
//
// Unlike budgets, this is not a hazard to a counterparty, and the reason
// is the divergence in the package doc: an approved reimbursement has
// already left the pool and sits in the ledger as the claimant's. What an
// owner can still do is empty the pool under a live desk, so that the
// approver's next Approve fails on solvency and pending requests cannot
// be settled. That is the owner declining to spend their own money, which
// is theirs to decline; CloseDesk is the clean way to end the
// relationship.
func WithdrawPool(cur realm, amount int64) int64 {
	rejectStraySend(cur)
	owner := cur.Previous().Address()
	if amount <= 0 {
		panic("amount must be positive")
	}
	return payOutPool(cur, owner, amount)
}

// WithdrawPoolAll returns the caller's entire unspent pool and reports
// the amount WITHDRAWN.
//
// The return values of the two withdraw entrypoints are deliberately
// asymmetric, which is worth naming rather than letting a caller
// discover: each returns the figure its caller does not already have.
// WithdrawPool was told the amount and wants to know what is left;
// WithdrawPoolAll knows what is left (nothing) and wants to know what it
// got. Returning the remainder here would hand every caller a constant 0.
func WithdrawPoolAll(cur realm) int64 {
	rejectStraySend(cur)
	owner := cur.Previous().Address()
	amount := poolOf(owner.String())
	if amount == 0 {
		panic("no pool to withdraw")
	}
	payOutPool(cur, owner, amount)
	return amount
}

// payOutPool is the shared debit-then-send path: the pool and the P term
// are reduced before the identical amount leaves the realm
// (checks-effects-interactions).
func payOutPool(cur realm, owner address, amount int64) int64 {
	key := owner.String()
	pool := poolOf(key)
	if amount > pool {
		panic("amount exceeds pool")
	}
	newReturned, ok := checkedAdd(lifetimeReturned, amount)
	if !ok {
		panic("lifetime returned would overflow")
	}

	setPool(key, pool-amount)
	totalPooled -= amount
	lifetimeReturned = newReturned

	coinio.Payout(0, cur, owner, Denom, amount)

	chain.Emit("PoolWithdrawn", "owner", key, "amount", itoa(amount),
		"pool", itoa(pool-amount))
	return pool - amount
}

// --- desks ---

// OpenDesk appoints an approver with a bounded authority over the
// caller's pool and returns the desk id. The caller becomes the desk's
// owner and must already have a funded pool — not because the desk
// reserves anything (it does not), but because a desk over an unfunded
// pool is an invitation to claimants to file requests nothing can settle,
// and this realm declines to record one.
//
// Terms, all in the chain's own units:
//
//	perPeriod    the gross the approver may approve per window, at least
//	             MinPerPeriod. Required.
//	periodLength blocks per window. 0 means ONE LIFETIME WINDOW that never
//	             refills; otherwise at least MinPeriodBlocks.
//	total        lifetime cap across every window. 0 means unlimited.
//	expiresAt    absolute block height at which the approver's authority
//	             ends. 0 means no expiry.
//
// Every bound above except the two realm minimums is validated and
// enforced by spendbook, and an invalid combination surfaces as that
// package's own sentinel error.
func OpenDesk(cur realm, approver address, label string,
	perPeriod, periodLength, total, expiresAt int64) int64 {
	rejectStraySend(cur)
	owner := cur.Previous().Address()

	// The lowercase clause is load-bearing, not decoration, and the reason
	// was measured on this toolchain rather than argued: address.IsValid()
	// defers to crypto.AddressFromBech32, whose decoder lowercases the
	// input BEFORE verifying the checksum, so it returns true for the
	// all-uppercase spelling of a valid address. Here the hazard is a
	// BRICKED DESK: Approve authenticates against cur.Previous().Address(),
	// which is always canonical, so an uppercase-spelled approver could
	// never approve anything, while the desk still occupied a
	// MaxDesksPerOwner slot and a storage deposit, and claimants could
	// still file requests at it that nobody could ever settle. The check is
	// complete as well as necessary — that decoder rejects mixed case
	// outright, so a valid address has exactly two spellings and rejecting
	// every non-lower one leaves precisely the canonical one.
	if !approver.IsValid() || string(approver) != strings.ToLower(string(approver)) {
		panic("approver is not a valid address in canonical (lowercase) form")
	}
	if len(label) > MaxLabelLen {
		panic("label exceeds " + strconv.Itoa(MaxLabelLen) + " bytes")
	}
	if perPeriod < MinPerPeriod {
		panic("perPeriod must be at least " + itoa(MinPerPeriod) + Denom)
	}
	if periodLength != 0 && periodLength < MinPeriodBlocks {
		panic("periodLength must be 0 (lifetime) or at least " +
			itoa(MinPeriodBlocks) + " blocks")
	}

	key := owner.String()
	if poolOf(key) == 0 {
		panic("fund a pool before opening a desk")
	}
	if ownerDesks(key) >= MaxDesksPerOwner {
		panic("owner already has " + itoa(MaxDesksPerOwner) + " live desks")
	}

	now := runtime.ChainHeight()
	allowID, err := book.Open(key, approver.String(), now, spendbook.Terms{
		PerPeriod:    perPeriod,
		PeriodLength: periodLength,
		Total:        total,
		ExpiresAt:    expiresAt,
	})
	if err != nil {
		panic(err)
	}

	id := nextDeskID + 1
	nextDeskID = id
	desks.Set(padID(id), &desk{
		id:        id,
		owner:     owner,
		approver:  approver,
		allowID:   allowID,
		feeBps:    ApprovalFeeBps,
		label:     label,
		createdAt: now,
	})
	setOwnerDesks(key, ownerDesks(key)+1)

	chain.Emit("DeskOpened", "id", itoa(id), "owner", key,
		"approver", approver.String(), "perPeriod", itoa(perPeriod),
		"periodLength", itoa(periodLength), "total", itoa(total),
		"expiresAt", itoa(expiresAt), "feeBps", itoa(ApprovalFeeBps))
	return id
}

// AmendDesk changes a desk's terms. Owner only. The returned bool reports
// whether the new terms are in force NOW (a tighter-or-equal amendment)
// or queued for the next window boundary (a looser one) — spendbook's
// one-sided rule, and the distinction worth knowing.
//
// periodLength is NOT a parameter. spendbook makes it immutable because
// moving it would move every future boundary, which is an enlargement
// vector wearing a different hat; this realm reads the desk's own
// periodLength and passes it unchanged, so changing it is not merely
// refused, it is unexpressible.
//
// Amending does not touch pending requests. Their fee was snapshotted at
// Submit and their amount is fixed; what changes is whether the approver
// still has the authority to settle them, which Approvable reports.
//
// A QUEUED EXPIRY EXTENSION CAN BE LOST, AND THE DESK BECOMES REAPABLE IN
// THE MEANTIME. A widening amendment is queued rather than applied, and
// spendbook surfaces a queued term only through its internal at()
// accessor — which IsExpired does NOT use: it reads the live
// Terms.ExpiresAt directly. So between queueing and the next approval,
// IsDeskExpired and ReapDesk still read the OLD expiry. If the old expiry
// passes with no Approve and no restated AmendDesk in between, ANYONE may
// ReapDesk the desk and the queued extension dies with it. Restating the
// same amendment while the old expiry is still in the future makes it
// permanent, because spendbook writes Pending back to Terms on a spend or
// on a later amendment; restating it after the old expiry is refused with
// "allowance has expired".
//
// NO FUNDS ARE AT RISK and that is structural, not incidental: dropDesk
// moves no coins, and the claimant pools are keyed by CLAIMANT ADDRESS
// rather than by desk, so a reap strands open requests and leaves every
// accrued balance claimable. The root cause is in spendbook, which is
// already live and immutable, so the repair belongs to a future /p/
// version and not to this realm. See AUDIT.md Y1 and DEPLOY_READINESS.md.
func AmendDesk(cur realm, id int64, perPeriod, total, expiresAt int64) bool {
	rejectStraySend(cur)
	owner := cur.Previous().Address()
	d := mustDesk(id)
	if owner != d.owner {
		panic("owner only")
	}
	if perPeriod < MinPerPeriod {
		panic("perPeriod must be at least " + itoa(MinPerPeriod) + Denom)
	}

	a, err := book.Get(d.allowID)
	if err != nil {
		panic(err)
	}
	applied, err := book.Amend(d.allowID, owner.String(), runtime.ChainHeight(),
		spendbook.Terms{
			PerPeriod:    perPeriod,
			PeriodLength: a.Terms.PeriodLength, // immutable
			Total:        total,
			ExpiresAt:    expiresAt,
		})
	if err != nil {
		panic(err)
	}

	chain.Emit("DeskAmended", "id", itoa(d.id), "owner", owner.String(),
		"perPeriod", itoa(perPeriod), "total", itoa(total),
		"expiresAt", itoa(expiresAt), "applied", boolstr(applied))
	return applied
}

// CloseDesk ends an approver's authority immediately. Owner only. The id
// is never reused, so a closed desk cannot be resurrected.
//
// Closing does NOT claw back credit already approved — that is the
// claimant's and stays claimable. It does NOT remove requests filed at
// this desk either: see the package doc, "a closed desk leaves its
// requests un-approvable". The count of those is reported in the event so
// the owner learns what they just stranded.
func CloseDesk(cur realm, id int64) {
	rejectStraySend(cur)
	owner := cur.Previous().Address()
	d := mustDesk(id)
	if owner != d.owner {
		panic("owner only")
	}
	// Owner-gated twice on purpose: the check above is for the error
	// message, the primitive's is the authoritative one.
	if err := book.Revoke(d.allowID, owner.String()); err != nil {
		panic(err)
	}
	stranded := deskOpen(id)
	dropDesk(d)

	chain.Emit("DeskClosed", "id", itoa(d.id), "owner", owner.String(),
		"approver", d.approver.String(), "approved", itoa(d.approved),
		"strandedRequests", itoa(stranded))
}

// ReapDesk removes a desk whose authority has EXPIRED, freeing its slot
// and its storage. Anyone may call it, and the reasoning is spendbook's
// own: an expired allowance can never authorize another approval, so
// removing it takes nothing from the owner and grants nothing to the
// caller. The chain refunds the freed storage deposit to the reaping
// transaction, which is the standing incentive.
//
// A desk with no expiry can never be reaped; only its owner can close it.
func ReapDesk(cur realm, id int64) {
	rejectStraySend(cur)
	d := mustDesk(id)
	if err := book.Reap(d.allowID, runtime.ChainHeight()); err != nil {
		panic(err)
	}
	stranded := deskOpen(id)
	dropDesk(d)

	chain.Emit("DeskReaped", "id", itoa(d.id), "owner", d.owner.String(),
		"by", cur.Previous().Address().String(),
		"strandedRequests", itoa(stranded))
}

// --- requests ---

// Submit files a reimbursement request against a desk and returns the
// request id. ANYONE may submit: that is the point of the realm — the
// party who spent the money asks, and does not need to be a signer, a
// delegate, or known to the desk in advance.
//
// Nothing is reserved and nothing moves. The amount and the fee are fixed
// here (the fee is snapshotted from the desk, so a later AmendDesk cannot
// change the terms of a request already filed), and the request expires
// at submittedAt + RequestTTL.
//
// Submitting against a desk whose approver is the submitter is permitted
// and useless: Approve refuses self-approval, so such a request can only
// be rejected, retracted or expired. It is not refused here because an
// approver may legitimately submit at a desk they do not approve, and a
// check at Submit would have to guess which desk the claimant meant.
func Submit(cur realm, deskID int64, amount int64, memo string) int64 {
	rejectStraySend(cur)
	claimant := cur.Previous().Address()
	d := mustDesk(deskID)

	if amount < MinRequestAmount {
		panic("request at least " + itoa(MinRequestAmount) + Denom)
	}
	if len(memo) > MaxMemoLen {
		panic("memo exceeds " + strconv.Itoa(MaxMemoLen) + " bytes")
	}
	if memo == "" {
		// A reimbursement request with no description is unreviewable: the
		// approver's whole job is deciding whether THIS expense should be
		// paid, and an amount alone does not support that decision.
		panic("memo is required: describe the expense")
	}
	if requests.Size() >= MaxLiveRequests {
		panic("the request queue is full; expired requests can be cleared " +
			"by anyone with ExpireRequest")
	}

	ckey := claimant.String()
	if claimantOpen(ckey) >= MaxOpenPerClaimant {
		panic("you already have " + itoa(MaxOpenPerClaimant) +
			" pending requests")
	}
	if deskOpen(deskID) >= MaxOpenPerDesk {
		panic("this desk already has " + itoa(MaxOpenPerDesk) +
			" pending requests")
	}

	now := runtime.ChainHeight()
	expires, ok := checkedAdd(now, RequestTTL)
	if !ok {
		panic("request expiry would overflow")
	}
	newSubmitted, ok := checkedAdd(lifetimeSubmitted, 1)
	if !ok {
		panic("lifetime submitted would overflow")
	}

	id := nextReqID + 1
	nextReqID = id
	requests.Set(padID(id), &request{
		id:          id,
		deskID:      deskID,
		claimant:    claimant,
		amount:      amount,
		feeBps:      d.feeBps,
		memo:        memo,
		submittedAt: now,
		expiresAt:   expires,
	})
	setClaimantOpen(ckey, claimantOpen(ckey)+1)
	setDeskOpen(deskID, deskOpen(deskID)+1)
	lifetimeSubmitted = newSubmitted

	chain.Emit("Submitted", "id", itoa(id), "desk", itoa(deskID),
		"claimant", ckey, "amount", itoa(amount), "feeBps", itoa(d.feeBps),
		"expiresAt", itoa(expires))
	return id
}

// Approve settles a request. APPROVER ONLY: the approver is the calling
// address, never an argument. The claimant is credited net of the fee and
// claims separately, which is this portfolio's standard pull shape.
//
// The checks fail in this order, and the order matters:
//
//  1. the desk must still exist (a closed or reaped desk strands its
//     requests, by design);
//  2. the caller must be that desk's approver;
//  3. the caller must not be the request's own claimant (no
//     self-approval);
//  4. the request must not have expired;
//  5. the owner's pool must cover the GROSS amount;
//  6. the desk's spendbook authority must permit the gross amount.
//
// Solvency (5) is checked BEFORE the allowance is consumed (6), so an
// approval refused for insolvency leaves the desk's window untouched
// rather than burning capacity on an approval that did not happen. This
// is budgets' ordering, kept for the same reason.
func Approve(cur realm, reqID int64) int64 {
	rejectStraySend(cur)
	approver := cur.Previous().Address()
	r := mustRequest(reqID)
	d := mustDesk(r.deskID)

	if approver != d.approver {
		panic("approver only")
	}
	if r.claimant == approver {
		// Conflict of interest, enforced per-approval so it cannot be
		// routed around via a second desk the same address approves.
		panic("an approver cannot approve their own request")
	}
	now := runtime.ChainHeight()
	if now >= r.expiresAt {
		panic("request has expired; anyone may ExpireRequest it")
	}

	ownerKey := d.owner.String()
	pool := poolOf(ownerKey)
	if r.amount > pool {
		// A pending request is not a reservation (package doc). The honest
		// failure is here, at approval time, rather than a credit the
		// claimant could not claim.
		panic("owner's pool cannot cover this request")
	}

	// Authority. spendbook checks every bound and CONSUMES the allowance
	// in this one call, before returning; on any error nothing is
	// consumed. Its sentinel errors name the reason. The allowance is
	// consumed by the GROSS, so the desk bounds the owner's outflow.
	if err := book.Spend(d.allowID, approver.String(), now, r.amount); err != nil {
		panic(err)
	}

	newApproved, ok := checkedAdd(d.approved, r.amount)
	if !ok {
		panic("desk approved total would overflow")
	}
	newLifetime, ok := checkedAdd(lifetimeApproved, r.amount)
	if !ok {
		panic("lifetime approved would overflow")
	}
	newApprovals, ok := checkedAdd(lifetimeApprovals, 1)
	if !ok {
		panic("lifetime approvals would overflow")
	}
	// The desk counter is guarded for the same reason as every other
	// accumulation here, and not because the overflow is reachable: it
	// costs one transaction per increment, so it is not. The audit (G1)
	// flagged `d.approvals++` and `d.rejections++` as the only two bare
	// accumulations in the realm -- nineteen lines from a checkedAdd of
	// the same shape -- and read the asymmetry as mild evidence that two
	// lines had been skipped rather than reasoned about. That is the
	// cheap reading to close BEFORE addpkg, after which it is closed
	// forever: a reader who has to re-derive the reachability argument
	// at every bare `++` eventually stops deriving it.
	newDeskApprovals, ok := checkedAdd(d.approvals, 1)
	if !ok {
		panic("desk approvals would overflow")
	}

	// Move the gross out of P and into L. H does not move, which is why
	// this transition has no payout to fail.
	setPool(ownerKey, pool-r.amount)
	totalPooled -= r.amount
	credited, fee := ledger.MustDeposit(r.claimant.String(), r.amount, r.feeBps)
	d.approved = newApproved
	d.approvals = newDeskApprovals
	lifetimeApproved = newLifetime
	lifetimeApprovals = newApprovals
	dropRequest(r)

	chain.Emit("Approved", "id", itoa(r.id), "desk", itoa(d.id),
		"approver", approver.String(), "claimant", r.claimant.String(),
		"gross", itoa(r.amount), "credited", itoa(credited),
		"fee", itoa(fee), "pool", itoa(pool-r.amount))
	return credited
}

// Reject closes a request without settling it. APPROVER ONLY. Nothing
// moves in any term of the invariant, and no authority is consumed — a
// rejection costs the desk's window nothing, which is deliberate: an
// approver must be able to say no as often as necessary.
//
// Rejecting an EXPIRED request is allowed. The alternative would force an
// approver who wants the record to carry a reason to race the expiry, and
// the reason is the useful artifact: ExpireRequest emits no explanation.
func Reject(cur realm, reqID int64, reason string) {
	rejectStraySend(cur)
	approver := cur.Previous().Address()
	r := mustRequest(reqID)
	d := mustDesk(r.deskID)

	if approver != d.approver {
		panic("approver only")
	}
	if len(reason) > MaxMemoLen {
		panic("reason exceeds " + strconv.Itoa(MaxMemoLen) + " bytes")
	}
	newRejected, ok := checkedAdd(lifetimeRejected, 1)
	if !ok {
		panic("lifetime rejected would overflow")
	}
	// Guarded for the reason given at the desk-approvals counter above.
	newDeskRejections, ok := checkedAdd(d.rejections, 1)
	if !ok {
		panic("desk rejections would overflow")
	}

	d.rejections = newDeskRejections
	lifetimeRejected = newRejected
	dropRequest(r)

	chain.Emit("Rejected", "id", itoa(r.id), "desk", itoa(d.id),
		"approver", approver.String(), "claimant", r.claimant.String(),
		"amount", itoa(r.amount), "reason", reason)
}

// Retract removes the caller's own pending request. CLAIMANT ONLY.
// Nothing moves.
//
// Named Retract rather than Withdraw on purpose: every Withdraw* in this
// portfolio moves money, and this moves none. A claimant reading a
// function list should not have to open the source to learn which.
func Retract(cur realm, reqID int64) {
	rejectStraySend(cur)
	claimant := cur.Previous().Address()
	r := mustRequest(reqID)
	if claimant != r.claimant {
		panic("claimant only")
	}
	newRetracted, ok := checkedAdd(lifetimeRetracted, 1)
	if !ok {
		panic("lifetime retracted would overflow")
	}
	lifetimeRetracted = newRetracted
	dropRequest(r)

	chain.Emit("Retracted", "id", itoa(r.id), "desk", itoa(r.deskID),
		"claimant", claimant.String(), "amount", itoa(r.amount))
}

// ExpireRequest removes a request past its expiry, freeing its slot and
// its storage. ANYONE may call it, and the reasoning matches ReapDesk's:
// an expired request can never be approved, so removing it takes nothing
// from the claimant and grants nothing to the caller. The chain refunds
// the freed storage deposit to the expiring transaction, which is the
// standing incentive and the mechanism that drains the queue.
func ExpireRequest(cur realm, reqID int64) {
	rejectStraySend(cur)
	r := mustRequest(reqID)
	now := runtime.ChainHeight()
	if now < r.expiresAt {
		panic("request has not expired yet")
	}
	newExpired, ok := checkedAdd(lifetimeExpired, 1)
	if !ok {
		panic("lifetime expired would overflow")
	}
	lifetimeExpired = newExpired
	dropRequest(r)

	chain.Emit("RequestExpired", "id", itoa(r.id), "desk", itoa(r.deskID),
		"claimant", r.claimant.String(), "amount", itoa(r.amount),
		"by", cur.Previous().Address().String())
}

// --- the pull ---

// Claim pays the caller's entire settled credit out. CLAIMANT ONLY: the
// account is the calling address. Credit from a desk that has since been
// closed, expired or reaped is still claimable — it was settled under a
// live authority and this realm does not revisit that.
func Claim(cur realm) int64 {
	rejectStraySend(cur)
	account := cur.Previous().Address()
	key := account.String()

	amount, err := ledger.WithdrawAll(key)
	if err != nil {
		panic(err)
	}
	if amount == 0 {
		panic("no credit to claim")
	}
	newClaimed, ok := checkedAdd(lifetimeClaimed, amount)
	if !ok {
		panic("lifetime claimed would overflow")
	}
	lifetimeClaimed = newClaimed

	coinio.Payout(0, cur, account, Denom, amount)

	chain.Emit("Claimed", "account", key, "amount", itoa(amount))
	return amount
}

// --- fees and surplus ---

// WithdrawFees pays the entire accrued fee pot to the compile-time
// FeeCollector. Anyone may call it: the destination is fixed, so there is
// nothing for a caller to steer.
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

// SweepSurplus sends out-of-band coins to the FeeCollector: for the pool
// denom, everything above tracked liabilities; for any foreign denom, the
// full balance. Owner pools, claimant credit and the fee pot are
// untouchable by construction (coinio.Sweep refuses to dip below the
// reserve). Anyone may call it.
//
// With nothing out of band this ABORTS ("coinio: no surplus to sweep for
// <denom>") rather than returning 0. That is the primitive's choice and
// the right one: a sweep is a transfer, and a transfer of nothing that
// reports success is how a caller comes to believe a balance was moved.
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

// --- desk views ---

// DeskInfo returns a desk's parties and the terms currently recorded for
// it. perPeriod reflects a tightening amendment immediately; a queued
// loosening shows in PendingTerms until its boundary arrives.
func DeskInfo(id int64) (owner, approver address, perPeriod, periodLength,
	total, expiresAt, anchor, createdAt, feeBps int64) {
	d := mustDesk(id)
	a := mustAllowance(d)
	return d.owner, d.approver, a.Terms.PerPeriod, a.Terms.PeriodLength,
		a.Terms.Total, a.Terms.ExpiresAt, a.Anchor, d.createdAt, d.feeBps
}

// DeskUsage returns a desk's consumption AT THE CURRENT HEIGHT: what the
// window the chain is in right now has approved, the lifetime gross, that
// window's index, how many approvals there have been, how many
// rejections, and how many requests are pending at the desk.
//
// The two window figures are computed rather than read straight off the
// record, and that is the whole point of windowAt below: a window that
// has rolled with no approval since leaves Allowance.WindowIndex naming a
// window the chain has already left, and Allowance.SpentWindow holding
// the previous window's spend.
func DeskUsage(id int64) (approvedWindow, approvedTotal, windowIndex,
	approvals, rejections, pending int64) {
	d := mustDesk(id)
	a := mustAllowance(d)
	now := runtime.ChainHeight()
	return spentInWindow(a, now), a.SpentTotal, windowAt(a, now),
		d.approvals, d.rejections, deskOpen(id)
}

// DeskLabel returns a desk's raw label (unsanitized: callers rendering it
// into markdown must sanitize, as this realm's Render does).
func DeskLabel(id int64) string { return mustDesk(id).label }

// Remaining is the AUTHORITY figure for a desk: what its terms permit the
// approver to approve right now, ignoring whether the owner's pool can
// cover it.
func Remaining(id int64) int64 {
	d := mustDesk(id)
	return book.Remaining(d.allowID, runtime.ChainHeight())
}

// Approvable is the HONEST figure for a desk, and the one both an
// approver and a prospective claimant should read: the lesser of what the
// desk authorizes and what the owner's pool holds. This distinction is
// the realm's own — spendbook bounds permission and says so, never
// solvency.
func Approvable(id int64) int64 {
	d := mustDesk(id)
	authorized := book.Remaining(d.allowID, runtime.ChainHeight())
	pool := poolOf(d.owner.String())
	if pool < authorized {
		return pool
	}
	return authorized
}

// PendingTerms returns a queued loosening amendment on a desk and whether
// there is one. An amendment is queued only when it would widen the live
// window, and it takes effect at the next window boundary.
func PendingTerms(id int64) (perPeriod, total, expiresAt int64, pending bool) {
	a := mustAllowance(mustDesk(id))
	if !a.HasPending {
		return 0, 0, 0, false
	}
	return a.Pending.PerPeriod, a.Pending.Total, a.Pending.ExpiresAt, true
}

// IsDeskExpired reports whether a desk's authority has lapsed, which is
// also the condition under which anyone may ReapDesk it.
//
// It reads the LIVE expiry only. A queued expiry extension reported by
// PendingTerms is NOT considered here, so this can read true while an
// amendment widening the window is still queued — see AmendDesk for the
// full disclosure and why no funds are at risk.
func IsDeskExpired(id int64) bool {
	return mustAllowance(mustDesk(id)).IsExpired(runtime.ChainHeight())
}

// --- request views ---

// RequestInfo returns a request's desk, claimant, amount, snapshotted
// fee, and the two heights that bound it.
func RequestInfo(id int64) (deskID int64, claimant address,
	amount, feeBps, submittedAt, expiresAt int64) {
	r := mustRequest(id)
	return r.deskID, r.claimant, r.amount, r.feeBps, r.submittedAt, r.expiresAt
}

// RequestMemo returns a request's raw memo (unsanitized: callers
// rendering it into markdown must sanitize, as this realm's Render does).
func RequestMemo(id int64) string { return mustRequest(id).memo }

// IsRequestExpired reports whether a request is past its expiry, which is
// both the condition under which Approve refuses and the condition under
// which anyone may ExpireRequest it.
func IsRequestExpired(id int64) bool {
	return runtime.ChainHeight() >= mustRequest(id).expiresAt
}

// ApprovalBlocker returns the empty string when the request could be
// approved right now by its desk's approver, and otherwise the single
// reason it could not. It is the view a UI wants before showing an
// approve button, and an approver wants before paying gas for a call that
// will abort.
//
// The reasons are reported in the same order Approve checks them, so this
// view and that entrypoint can never disagree about WHICH reason applies.
// It deliberately does NOT report "you are not the approver": the caller
// of a view is not the caller of the approval, so this answers about the
// request and the desk, not about whoever is asking.
func ApprovalBlocker(id int64) string {
	r := mustRequest(id)
	v := desks.Get(padID(r.deskID))
	if v == nil {
		return "the desk has been closed or reaped; this request can only " +
			"be retracted by its claimant or expired by anyone"
	}
	d := v.(*desk)
	if r.claimant == d.approver {
		return "the desk's approver is the claimant; self-approval is refused"
	}
	if runtime.ChainHeight() >= r.expiresAt {
		return "the request has expired"
	}
	if r.amount > poolOf(d.owner.String()) {
		return "the owner's pool cannot cover this request"
	}
	if r.amount > book.Remaining(d.allowID, runtime.ChainHeight()) {
		return "the desk's authority does not cover this request at this " +
			"height (window cap spent, lifetime cap reached, or expired)"
	}
	return ""
}

// --- aggregate views ---

// PoolOf returns an owner's unspent pool.
func PoolOf(addr address) int64 { return poolOf(addr.String()) }

// CreditOf returns a claimant's settled-but-unclaimed credit.
func CreditOf(addr address) int64 { return ledger.BalanceOf(addr.String()) }

// DesksOf returns how many live desks an owner currently holds.
func DesksOf(addr address) int64 { return ownerDesks(addr.String()) }

// OpenRequestsOf returns how many pending requests a claimant has.
func OpenRequestsOf(addr address) int64 { return claimantOpen(addr.String()) }

// OpenRequestsAt returns how many pending requests a desk has.
func OpenRequestsAt(deskID int64) int64 { return deskOpen(deskID) }

// NumDesks returns how many desks have ever been opened. Ids are never
// reused, so this only grows.
func NumDesks() int64 { return nextDeskID }

// LiveDesks returns how many desks are currently live, from the
// primitive's own count.
func LiveDesks() int64 { return int64(book.Count()) }

// NumRequests returns how many requests have ever been filed. Ids are
// never reused, so this only grows.
func NumRequests() int64 { return nextReqID }

// LiveRequests returns how many requests are currently pending. A pending
// request may still be unapprovable — see ApprovalBlocker.
func LiveRequests() int64 { return int64(requests.Size()) }

// TotalPooled returns the P term: unspent owner funds. Pending requests
// are NOT included; they are not liabilities.
func TotalPooled() int64 { return totalPooled }

// UnclaimedCredit returns the claimants' share of the L term: approved
// and not yet claimed.
func UnclaimedCredit() int64 { return ledger.UsersTotal() }

// FeesAccrued returns the fee pot: charged, not yet withdrawn.
func FeesAccrued() int64 { return ledger.FeesAccrued() }

// Liabilities returns P + L — everything this realm owes. A pending
// request is not part of it.
func Liabilities() int64 { return totalPooled + ledger.Liabilities() }

// Held returns H: the ugnot actually at this realm's address.
func Held() int64 { return coinio.HeldAt(self, Denom) }

// Surplus returns H - (P + L) — out-of-band coins, sweepable.
func Surplus() int64 { return Held() - Liabilities() }

// Address returns this realm's own address.
func Address() address { return self }

// Height returns the current chain height: the clock every window,
// expiry and TTL is measured against, and the one no caller can choose.
func Height() int64 { return runtime.ChainHeight() }

// --- render ---

// Render shows the realm at "", a desk page at "desk/<id>" and a request
// page at "request/<id>". Labels and memos are free text and pass through
// the ecosystem sanitizer before hitting markdown.
func Render(path string) string {
	switch {
	case path == "":
		return renderIndex()
	case strings.HasPrefix(path, "desk/"):
		return renderDesk(path[len("desk/"):])
	case strings.HasPrefix(path, "request/"):
		return renderRequest(path[len("request/"):])
	}
	return "> [!WARNING]\n> unknown path. Try `desk/<id>` or `request/<id>`.\n"
}

func renderIndex() string {
	now := runtime.ChainHeight()
	held := Held()
	liab := Liabilities()
	conservation := "OK"
	if held < liab {
		conservation = "VIOLATED"
	}

	out := "# Reimbursements\n\n"
	out += "Claimant-initiated expense reimbursement in GNOT. An owner " +
		"funds a pool and appoints an approver with a bounded, " +
		"rate-limited, revocable authority over it. **Anyone** may submit " +
		"a request with an amount and a description; the approver either " +
		"approves it — which settles the money into the claimant's credit " +
		"in the same transaction — or rejects it.\n\n"
	out += "> [!IMPORTANT]\n> A pending request is **not** a reservation " +
		"and not a liability. Nothing moves until an approval, and an " +
		"approval is atomic. Read `Approvable(deskID)` for what a desk can " +
		"actually settle right now, and `ApprovalBlocker(reqID)` for why a " +
		"specific request cannot be.\n\n"
	out += "## Terms (fixed at deploy; no admin, no setters)\n\n"
	out += "- approval fee: " + bps(ApprovalFeeBps) +
		" of the gross approved amount, paid from the owner's pool (hard cap " +
		bps(MaxFeeBps) + ")\n"
	out += "- no fee on funding, on withdrawing an unspent pool, or on claiming\n"
	out += "- self-approval is refused: an approver cannot approve their own request\n"
	out += "- minimum funding: " + itoa(MinFunding) + Denom + " per call\n"
	out += "- minimum request: " + itoa(MinRequestAmount) + Denom + "\n"
	out += "- minimum per-window approval cap: " + itoa(MinPerPeriod) + Denom + "\n"
	out += "- window length: 0 (one lifetime window) or at least " +
		itoa(MinPeriodBlocks) + " blocks\n"
	out += "- request expiry: " + itoa(RequestTTL) +
		" blocks after submission, then anyone may ExpireRequest it\n"
	out += "- live desks: " + itoa(LiveDesks()) + " of " +
		strconv.Itoa(MaxLiveDesks) + " (per owner: " + itoa(MaxDesksPerOwner) + ")\n"
	out += "- pending requests: " + itoa(LiveRequests()) + " of " +
		strconv.Itoa(MaxLiveRequests) + " (per claimant: " +
		itoa(MaxOpenPerClaimant) + ", per desk: " + itoa(MaxOpenPerDesk) + ")\n"
	out += "- current height: " + itoa(now) + "\n\n"
	out += "## Accounting (H == P + L + S)\n\n"
	out += "- pooled (P): " + itoa(totalPooled) + Denom + "\n"
	out += "- unclaimed claimant credit: " + itoa(ledger.UsersTotal()) + Denom + "\n"
	out += "- fee pot: " + itoa(ledger.FeesAccrued()) + Denom + "\n"
	out += "- held (H): " + itoa(held) + Denom + "\n"
	out += "- surplus (S): " + itoa(held-liab) + Denom + "\n"
	out += "- conservation: " + conservation + "\n"
	out += "- lifetime funded / approved / claimed / returned: " +
		itoa(lifetimeFunded) + " / " + itoa(lifetimeApproved) + " / " +
		itoa(lifetimeClaimed) + " / " + itoa(lifetimeReturned) + Denom + "\n"
	out += "- requests submitted / approved / rejected / retracted / expired: " +
		itoa(lifetimeSubmitted) + " / " + itoa(lifetimeApprovals) + " / " +
		itoa(lifetimeRejected) + " / " + itoa(lifetimeRetracted) + " / " +
		itoa(lifetimeExpired) + "\n\n"

	out += renderDeskList(now)
	out += renderRequestList(now)
	return out
}

func renderDeskList(now int64) string {
	out := "## Live desks\n\n"
	if desks.Size() == 0 {
		return out + "None yet. Fund a pool, then OpenDesk an approver.\n\n"
	}
	shown := 0
	expired := 0
	desks.ReverseIterate("", "", func(_ string, v any) bool {
		d := v.(*desk)
		a, aerr := book.Get(d.allowID)
		state := "live"
		if aerr != nil {
			state = "missing"
		} else if a.IsExpired(now) {
			state = "expired (reapable)"
			expired++
		}
		out += "- [desk #" + itoa(d.id) + "](" + RealmPath + ":desk/" +
			itoa(d.id) + ") [" + state + "] " +
			sanitize.InlineText(labelOr(d)) + " — approvable " +
			itoa(Approvable(d.id)) + Denom + ", " + itoa(deskOpen(d.id)) +
			" pending\n"
		shown++
		return shown >= MaxRenderRows
	})
	if shown < desks.Size() {
		out += "\n> [!NOTE]\n> Showing the " + strconv.Itoa(shown) +
			" most recent of " + strconv.Itoa(desks.Size()) +
			" live desks (" + itoa(nextDeskID) +
			" ever opened; closed and reaped records are removed). " +
			"Use DeskInfo(id) for any specific desk.\n"
	}
	if expired > 0 {
		out += "\n> [!TIP]\n> Anyone may ReapDesk(id) an expired desk to " +
			"free its slot and reclaim its storage deposit: " +
			strconv.Itoa(expired) + " of the desks above are reapable.\n"
	}
	return out + "\n"
}

func renderRequestList(now int64) string {
	out := "## Pending requests\n\n"
	if requests.Size() == 0 {
		return out + "None pending.\n"
	}
	shown := 0
	stale := 0
	requests.ReverseIterate("", "", func(_ string, v any) bool {
		r := v.(*request)
		state := "awaiting approval"
		if now >= r.expiresAt {
			state = "expired (clearable)"
			stale++
		} else if blocker := ApprovalBlocker(r.id); blocker != "" {
			state = "blocked"
		}
		out += "- [request #" + itoa(r.id) + "](" + RealmPath + ":request/" +
			itoa(r.id) + ") [" + state + "] " + itoa(r.amount) + Denom +
			" at desk #" + itoa(r.deskID) + " — " +
			sanitize.InlineText(r.memo) + "\n"
		shown++
		return shown >= MaxRenderRows
	})
	if shown < requests.Size() {
		out += "\n> [!NOTE]\n> Showing the " + strconv.Itoa(shown) +
			" most recent of " + strconv.Itoa(requests.Size()) +
			" pending requests (" + itoa(nextReqID) +
			" ever filed; settled and cleared records are removed). " +
			"Use RequestInfo(id) for any specific request.\n"
	}
	if stale > 0 {
		out += "\n> [!TIP]\n> Anyone may ExpireRequest(id) a request past " +
			"its expiry to free its slot and reclaim its storage deposit: " +
			strconv.Itoa(stale) + " of the requests above are clearable.\n"
	}
	return out
}

func renderDesk(idStr string) string {
	id, err := strconv.ParseInt(idStr, 10, 64)
	if err != nil {
		return "> [!WARNING]\n> invalid desk id\n"
	}
	v := desks.Get(padID(id))
	if v == nil {
		return "> [!WARNING]\n> unknown desk id (never opened, or closed/reaped)\n"
	}
	d := v.(*desk)
	a, gerr := book.Get(d.allowID)
	if gerr != nil {
		// Unreachable: dropDesk removes the record and the allowance
		// together, in one call. Rendered rather than panicked so a
		// corrupted pair is visible instead of breaking the page.
		return "> [!CAUTION]\n> desk #" + itoa(d.id) +
			" has no backing allowance; this is a bug. Reason: " +
			sanitize.InlineText(gerr.Error()) + "\n"
	}
	now := runtime.ChainHeight()

	out := "# Desk #" + itoa(d.id)
	if d.label != "" {
		out += ": " + sanitize.InlineText(d.label)
	}
	out += "\n\n"
	out += "- owner (funds the pool): `" + d.owner.String() + "`\n"
	out += "- approver (decides): `" + d.approver.String() + "`\n"
	out += "- per-window approval cap: " + itoa(a.Terms.PerPeriod) + Denom + "\n"
	if a.Terms.PeriodLength == 0 {
		out += "- window: one lifetime window; the cap never refills\n"
	} else {
		out += "- window: " + itoa(a.Terms.PeriodLength) +
			" blocks, anchored at " + itoa(a.Anchor) +
			" (now in window " + itoa(windowAt(a, now)) + ")\n"
	}
	if a.Terms.Total == 0 {
		out += "- lifetime cap: none\n"
	} else {
		out += "- lifetime cap: " + itoa(a.Terms.Total) + Denom +
			" (" + itoa(a.SpentTotal) + " used)\n"
	}
	if a.Terms.ExpiresAt == 0 {
		out += "- expiry: none (only the owner can close it)\n"
	} else {
		out += "- expiry: block " + itoa(a.Terms.ExpiresAt) + "\n"
	}
	out += "- approval fee: " + bps(d.feeBps) + " (snapshotted at desk open)\n"
	out += "- approved this window: " + itoa(spentInWindow(a, now)) + Denom + "\n"
	out += "- approved in total: " + itoa(d.approved) + Denom + " over " +
		itoa(d.approvals) + " approvals (" + itoa(d.rejections) + " rejected)\n"
	out += "- pending requests here: " + itoa(deskOpen(d.id)) + " of " +
		itoa(MaxOpenPerDesk) + "\n"
	out += "- opened at block: " + itoa(d.createdAt) + "\n"
	out += "- current height: " + itoa(now) + "\n\n"

	authorized := a.Remaining(now)
	pool := poolOf(d.owner.String())
	out += "## What can be approved right now\n\n"
	out += "- authorized by the terms: " + itoa(authorized) + Denom + "\n"
	out += "- owner's unspent pool: " + itoa(pool) + Denom + "\n"
	approvable := authorized
	if pool < approvable {
		approvable = pool
	}
	out += "- **approvable: " + itoa(approvable) + Denom +
		"** (the lesser of the two)\n\n"

	switch {
	case a.IsExpired(now):
		out += "This desk has **expired**. Anyone may ReapDesk(" + itoa(d.id) +
			") to free its slot and reclaim its storage deposit. Requests " +
			"filed here can no longer be approved.\n"
	case approvable == 0 && authorized == 0:
		out += "Nothing authorized at this height — the window cap is spent, " +
			"the lifetime cap is reached, or the desk has not started.\n"
	case approvable == 0:
		out += "Authorized but **not funded**: the owner's pool cannot cover " +
			"an approval. A pending request is not a reservation.\n"
	default:
		out += "A claimant may Submit(" + itoa(d.id) +
			", amount, memo) here, and the approver may Approve(reqID) up " +
			"to the approvable figure. The claimant then Claim()s.\n"
	}
	if a.HasPending {
		out += "\n> [!NOTE]\n> A **looser** amendment is queued and takes " +
			"effect at the next window boundary: per-window cap " +
			itoa(a.Pending.PerPeriod) + Denom + ", lifetime cap " +
			itoa(a.Pending.Total) + ", expiry " + itoa(a.Pending.ExpiresAt) +
			" (0 means none). Until then the terms above are what govern.\n"
	}
	return out
}

func renderRequest(idStr string) string {
	id, err := strconv.ParseInt(idStr, 10, 64)
	if err != nil {
		return "> [!WARNING]\n> invalid request id\n"
	}
	v := requests.Get(padID(id))
	if v == nil {
		return "> [!WARNING]\n> unknown request id (never filed, or already " +
			"approved/rejected/retracted/expired)\n"
	}
	r := v.(*request)
	now := runtime.ChainHeight()

	out := "# Request #" + itoa(r.id) + "\n\n"
	out += "- claimant: `" + r.claimant.String() + "`\n"
	out += "- desk: [#" + itoa(r.deskID) + "](" + RealmPath + ":desk/" +
		itoa(r.deskID) + ")\n"
	out += "- amount requested (gross): " + itoa(r.amount) + Denom + "\n"
	out += "- approval fee if settled: " + bps(r.feeBps) +
		" (snapshotted at submission)\n"
	out += "- submitted at block: " + itoa(r.submittedAt) + "\n"
	out += "- expires at block: " + itoa(r.expiresAt) + "\n"
	out += "- current height: " + itoa(now) + "\n\n"
	out += "## Expense\n\n> " + sanitize.InlineText(r.memo) + "\n\n"
	out += "## Status\n\n"
	if blocker := ApprovalBlocker(r.id); blocker != "" {
		out += "> [!WARNING]\n> **Not approvable:** " + blocker + "\n"
	} else {
		out += "> [!NOTE]\n> **Approvable now.** The desk's approver may " +
			"Approve(" + itoa(r.id) + "), which credits the claimant in the " +
			"same transaction; the claimant then Claim()s.\n"
	}
	out += "\nThe claimant may Retract(" + itoa(r.id) +
		") at any time while it is pending. Nothing has moved yet: a " +
		"pending request is not a reservation.\n"
	return out
}

// --- internals ---

func mustDesk(id int64) *desk {
	v := desks.Get(padID(id))
	if v == nil {
		panic("unknown desk id")
	}
	return v.(*desk)
}

func mustRequest(id int64) *request {
	v := requests.Get(padID(id))
	if v == nil {
		panic("unknown request id")
	}
	return v.(*request)
}

// mustAllowance fetches the spendbook allowance behind a desk. The pair
// is created and removed together, so a missing allowance is a bug in
// this realm rather than a user error, and it panics rather than
// reporting a zero value that a reader would take for "no authority".
func mustAllowance(d *desk) spendbook.Allowance {
	a, err := book.Get(d.allowID)
	if err != nil {
		panic(err)
	}
	return a
}

// windowAt returns the anchored window index containing now, and
// spentInWindow what that window has approved.
//
// These duplicate a line of spendbook, and the duplication is deliberate,
// bounded, and worth justifying because the primitive's own at() comment
// warns against exactly this. What is NOT reimplemented is the part that
// warning is about: which terms are in force after a boundary, and
// therefore every authority figure this realm reports — Remaining and
// Approvable both call through to the primitive, and nothing here
// second-guesses them.
//
// What is copied is pure index arithmetic over three EXPORTED fields plus
// the already-documented fact that the in-window spend RESETS rather than
// carries. The alternative is worse than the duplication: Allowance's
// WindowIndex and SpentWindow are the last-WRITTEN pair, so between a
// boundary and the next approval they describe a window the chain has
// left, and a Render publishing them would print "approved this window:
// 100000" immediately above "authorized by the terms: 100000".
//
// The two are pinned to the primitive by
// TestWindowRefillsAtAnchoredBoundary rather than by inspection: it
// approves after crossing a boundary and asserts approvedWindow equals
// that approval, which can only hold if windowAt agreed with spendbook's
// own index at the moment of the write.
func windowAt(a spendbook.Allowance, now int64) int64 {
	if a.Terms.PeriodLength == 0 || now < a.Anchor {
		return 0
	}
	return (now - a.Anchor) / a.Terms.PeriodLength
}

func spentInWindow(a spendbook.Allowance, now int64) int64 {
	if windowAt(a, now) != a.WindowIndex {
		return 0
	}
	return a.SpentWindow
}

// dropDesk removes a desk record and decrements its owner's live count.
// The allowance itself is removed by the spendbook call that precedes
// every caller of this helper.
//
// It deliberately does NOT remove the desk's pending requests — see the
// package doc, "a closed desk leaves its requests un-approvable". Its
// openByDesk counter IS removed, because the counter exists to bound new
// submissions at a live desk and a dead desk accepts none; the stranded
// requests remain findable by id and are still counted against their
// claimants' openByClaimant, which is what bounds them.
func dropDesk(d *desk) {
	desks.Remove(padID(d.id))
	openByDesk.Remove(padID(d.id))
	decOwnerDesks(d.owner.String())
}

// dropRequest removes a request record and decrements both of its
// counters. Every caller has already decided the request's outcome;
// this is only the bookkeeping.
func dropRequest(r *request) {
	requests.Remove(padID(r.id))
	decClaimantOpen(r.claimant.String())
	// A request at a desk closed since submission has no openByDesk entry
	// to decrement (dropDesk removed it); setDeskOpen floors at zero and
	// removes rather than storing a negative, so this is safe rather than
	// merely harmless.
	setDeskOpen(r.deskID, deskOpen(r.deskID)-1)
}

func labelOr(d *desk) string {
	if d.label == "" {
		return "(no label)"
	}
	return d.label
}

func poolOf(key string) int64 {
	v := pools.Get(key)
	if v == nil {
		return 0
	}
	return v.(int64)
}

func setPool(key string, n int64) {
	if n <= 0 {
		pools.Remove(key)
		return
	}
	pools.Set(key, n)
}

func ownerDesks(key string) int64 {
	v := desksByOwner.Get(key)
	if v == nil {
		return 0
	}
	return v.(int64)
}

func setOwnerDesks(key string, n int64) {
	if n <= 0 {
		desksByOwner.Remove(key)
		return
	}
	desksByOwner.Set(key, n)
}

func decOwnerDesks(key string) { setOwnerDesks(key, ownerDesks(key)-1) }

func claimantOpen(key string) int64 {
	v := openByClaimant.Get(key)
	if v == nil {
		return 0
	}
	return v.(int64)
}

func setClaimantOpen(key string, n int64) {
	if n <= 0 {
		openByClaimant.Remove(key)
		return
	}
	openByClaimant.Set(key, n)
}

func decClaimantOpen(key string) { setClaimantOpen(key, claimantOpen(key)-1) }

func deskOpen(deskID int64) int64 {
	v := openByDesk.Get(padID(deskID))
	if v == nil {
		return 0
	}
	return v.(int64)
}

func setDeskOpen(deskID int64, n int64) {
	if n <= 0 {
		openByDesk.Remove(padID(deskID))
		return
	}
	openByDesk.Set(padID(deskID), n)
}

func itoa(n int64) string { return strconv.FormatInt(n, 10) }

func boolstr(b bool) string {
	if b {
		return "true"
	}
	return "false"
}

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

// padID encodes an id so avl's lexical order matches numeric order.
func padID(id int64) string {
	s := strconv.FormatInt(id, 10)
	const width = 20
	if len(s) >= width {
		return s
	}
	return zeros[:width-len(s)] + s
}

const zeros = "00000000000000000000"

// checkedAdd returns a+b and reports whether the addition did not
// overflow int64.
func checkedAdd(a, b int64) (int64, bool) {
	sum := a + b
	if (b > 0 && sum < a) || (b < 0 && sum > a) {
		return 0, false
	}
	return sum, true
}
