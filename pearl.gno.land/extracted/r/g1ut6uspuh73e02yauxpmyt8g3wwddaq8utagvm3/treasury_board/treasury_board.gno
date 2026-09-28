// Realm treasury_board is a standing GNOT pool whose outbound payments
// require M-of-N approval from a named board AND a fixed delay before
// the value moves.
//
// WHY THIS EXISTS (see DISCOVERY.md, especially §6 and §9b): across the
// full source of all 682 pearl-1 and all 536 gnoland-1 packages at the
// heights recorded there, nothing combines coin custody, M-of-N approval
// counted over a named principal set, and an enforced wait between
// authorization and effect. The two halves exist separately and were
// both read. This realm's delta over them is EXACTLY ONE THING and is
// recorded at that size rather than inflated:
//
//	the sibling `bounty_panel` has M-of-N over a named panel with real
//	custody, but the Mth vote awards ATOMICALLY — correct for a bounty,
//	where the panel judges finished work and there is nothing left to
//	reconsider. The sibling `timelock_guardian` has the delay and the
//	permissionless execute attestation, but holds no coins at all.
//
// A standing pool is the case where atomic execution is wrong: the
// interval between "the board has approved" and "the coins have moved"
// is the only window in which a compromised signer key, a mistaken
// amount, or a recipient typo can still be caught. Providing that
// window, over a pooled fund rather than per-transaction escrow, is the
// whole of what this realm adds. Everything else below — custody,
// credit-then-pull, the conservation identity, the stray-send guard —
// is conformance with patterns already live in this portfolio and is
// deliberately not claimed as novel.
//
// COMPOSITION: coin movement is delegated to coinio, all balance
// accounting to feeledger, the delay itself to duebook, ordered storage
// to p/nt/avl/v0, and free-text render output to the ecosystem sanitizer
// p/nt/markdown/sanitize/v0. This realm owns only the board, the
// proposal state machine, and the pot.
//
// THERE IS NO ADMIN, and no privileged address of any kind. This is a
// consequence, not a flourish: DISCOVERY.md §5 records that `permbook`
// resolves its ADMIN as the external principal that crossed in, so a
// board minted by a permission book would be a board one outside key can
// rewrite at will. A treasury whose approver set is minted by one key is
// a single point of failure wearing a costume. Membership here is
// changed only by the board's own process, through the same approval and
// the same delay as a payment.
//
// LIFECYCLE (one proposal type, discriminated by kind; terminal states
// are frozen):
//
//	Fund (anyone, +send)        : adds coins to the pot. A DONATION —
//	                              there is no refund path except a
//	                              payment the board approves.
//	ProposePayment   (signer)   : kind=pay      -> Pending
//	ProposeBoardChange (signer) : kind=setboard -> Pending
//	ProposeSweep     (signer)   : kind=sweep    -> Pending
//	Approve (signer)            : records a distinct approval; arms the
//	                              proposal the FIRST time live approvals
//	                              reach the threshold. Also permitted
//	                              while Armed, so a revocation can be
//	                              restored without re-arming.
//	RevokeApproval (signer)     : drops a live approval. Blocks
//	                              execution while the count is short, but
//	                              NEITHER REWINDS NOR POSTPONES the clock
//	                              (see THE CLOCK below).
//	Arm (ANYONE)                : Pending -> Armed when live approvals
//	                              already meet the threshold. Only starts
//	                              a clock, so it is safe to leave open;
//	                              it exists because lowering the
//	                              threshold can make an untouched
//	                              proposal eligible with no further
//	                              Approve to hang the arming off.
//	Execute (ANYONE)            : Armed -> Executed, once the deferral is
//	                              due and not expired AND live approvals
//	                              STILL meet the threshold.
//	Cancel (proposer only)      : Pending/Armed -> Cancelled.
//	ExpireProposal (ANYONE)     : Pending -> Expired after the approval
//	                              window; Armed -> Expired after the
//	                              execution window. The permissionless
//	                              valve against proposals that neither
//	                              resolve nor get cleaned up.
//	Absorb (ANYONE)             : folds out-of-band ugnot surplus into
//	                              the pot. Moves no coins.
//	Withdraw / WithdrawAll      : pays out the CALLER'S OWN balance.
//
// THE CLOCK, stated precisely because it is the point of the realm:
// readyAt is set ONCE, when live approvals first reach the threshold,
// and is never recalculated. Revoking and re-approving therefore cannot
// rewind it (which would be a way to execute sooner than the delay) and
// cannot postpone it indefinitely (which would be a way for one signer
// to grief the board forever). What revocation does is block execution
// while the count is short — the count is re-derived from the LIVE
// signer set at Execute, never from a cached number.
//
// WHY THE LIVE RE-COUNT IS NOT A CACHED COUNTER: an executed board
// change can remove a signer whose approval is still recorded on an
// in-flight proposal. A cached count would then be HIGHER than the
// truth, which is the dangerous direction. liveApprovals() intersects
// the proposal's approver set with the current signer set on every read
// that matters. It is O(approvers) over a set bounded by MaxBoardSize.
//
// WHY BOARD CHANGES ARE ONE ATOMIC PAYLOAD: separate add / remove / set-
// threshold proposals can each be individually valid and jointly fatal —
// two in-flight removals that were both fine when proposed can leave the
// board below its threshold when both execute, stranding the pot with no
// path out. KindSetBoard replaces the signer set AND the threshold in
// one step, so a board smaller than its own threshold is unrepresentable
// rather than merely guarded against.
//
// WHY THE DELAY HAS NO SETTER: a board that can shorten its own delay
// can shorten it to zero, which deletes the only property this realm
// has. ExecutionDelayBlocks is a compile-time constant, and the duebook
// is constructed with minDelay == maxDelay == that constant, so the
// primitive's own validation refuses any other delay. The constraint is
// structural, not a check in this file that could be edited out.
//
// WHY A STALE PENDING PROPOSAL EXPIRES: an old proposal that never
// reached the threshold is a live authorization surface. If the board
// later lowers its threshold, that proposal could become armable years
// after everyone forgot it. Arm and Approve both refuse outside the
// approval window, so the expiry is enforced at the point of use and not
// merely by hoping someone calls ExpireProposal.
//
// MONETARY INVARIANT (conservation): let H be the ugnot held at this
// realm's address, P the pot, U the ledger's claimable balances, and
// S >= 0 the out-of-band surplus:
//
//	H == P + U + S
//
// The fee pot F is identically zero: the ledger is constructed with a 0
// bps cap and every deposit passes 0 bps, so no fee can ever accrue and
// no WithdrawFees entrypoint exists. Every transition moves value
// between exactly two terms inside one transaction: Fund raises H and P
// together (coinio.Receive is the receipt-guaranteed shape); an executed
// payment moves amount from P into U; Withdraw debits the ledger BEFORE
// coinio.Payout moves the identical amount out (checks-effects-
// interactions); Absorb moves S into P and touches no coins; any panic
// aborts the whole transaction; this realm never issues or removes
// coins.
//
// WHY THERE IS NO NATIVE SWEEP: a sweep of the pot denom to an outside
// address would be a second way for value to leave, and an unapproved
// one. Native surplus is instead folded into the pot by Absorb, which
// only restores H == P + U and moves nothing. Foreign denominations have
// no pot to be folded into, so they are recovered through KindSweep —
// governed by the same threshold and the same delay as everything else,
// rather than by a privileged sweeper address this realm deliberately
// does not have.
//
// ONLY GNOT IS ACCEPTED: Fund rejects any envelope that is not exactly
// one positive ugnot coin (coinio.Receive). Every other entrypoint
// rejects attached coins outright rather than converting them into
// sweepable surplus.
//
// AUTHORIZATION: every identity is derived from the crossing entrypoint's
// cur.Previous().Address(). No function takes a caller identity as a
// parameter, so approving as another signer, cancelling another
// proposer's proposal, or withdrawing another account's balance is
// impossible by construction.
//
// LIMITATION OF THE PEARL-1 DEPLOYMENT, stated here and not only in the
// record: the initial board is three addresses from a single agent
// keybase. A 2-of-3 threshold among three keys held by one party
// demonstrates the mechanism and secures nothing. The security property
// is a claim about a board of independent operators, and this deployment
// is not evidence for it.
package treasury_board

import (
	"chain"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"strings"

	"gno.land/p/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/coinio"
	"gno.land/p/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/duebook"
	"gno.land/p/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/feeledger"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/markdown/sanitize/v0"
)

// RealmPath is this realm's own path, used to build Render links.
const RealmPath = "/r/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/treasury_board"

// Denom is the only asset this realm pools.
const Denom = "ugnot"

// InitialSignersCSV and InitialThreshold are the board this realm is
// BORN with, baked into the source rather than set by a Setup call.
//
// Every M-of-N realm read during discovery uses a Setup-once entrypoint
// guarded against re-initialisation but NOT against who calls it first —
// the mainnet r/moul/x/daily/multisig/v0 source has no caller check in
// Setup whatsoever, so on a public chain whoever lands the first
// transaction fixes the owner set permanently. Constants eliminate that
// race and make the deployed artifact's authority auditable from the
// verified bytes alone: there is no window between deploy and Setup in
// which this realm has no board.
//
// The deployer is one of the three and has NO privilege beyond that: at
// a threshold of 2 the deploying key alone can do nothing.
const (
	InitialSignersCSV = "g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3," +
		"g184dtrgrg4euyreqn0a60azx00n9h6w57fakc9u," +
		"g1td3u7mwd06ul4rp59nszdkg4p87kcjhfar0svp"
	InitialThreshold = int64(2)
)

// ExecutionDelayBlocks is the veto window: how long after a proposal
// reaches its threshold before it may be executed.
//
// It is stated in BLOCKS because blocks are what the chain counts. The
// wall-clock figure is given as a RANGE on purpose: this portfolio's own
// realms disagree about pearl-1's block interval (vesting's arithmetic
// implies ~3.4s, bounty_panel's comment says ~5s), and neither was
// measured. 25,000 blocks is therefore between roughly 24 and 35 hours.
// A production fork would raise this considerably; it is sized here so
// the delay can actually be exercised on a testnet.
const ExecutionDelayBlocks = int64(25_000)

// ExecutionWindowBlocks is how long an armed proposal stays executable
// after it becomes due. Past it, the authorization dies and must be
// re-proposed rather than firing months later.
const ExecutionWindowBlocks = int64(150_000)

// ApprovalWindowBlocks is how long a Pending proposal may gather
// approvals. Past it, it can neither be armed nor approved, and anyone
// may expire it.
const ApprovalWindowBlocks = int64(150_000)

// MaxOpenProposals caps simultaneously ARMED proposals, via the
// duebook's own open-deferral cap.
const MaxOpenProposals = 64

// Proposal kinds.
const (
	KindPay      = "pay"
	KindSetBoard = "setboard"
	KindSweep    = "sweep"
)

// Proposal states. Executed, Cancelled and Expired are terminal.
const (
	StatePending   = "pending"
	StateArmed     = "armed"
	StateExecuted  = "executed"
	StateCancelled = "cancelled"
	StateExpired   = "expired"
)

// Input bounds.
const (
	// MaxBoardSize bounds board parsing, storage, the live re-count and
	// Render cost.
	MaxBoardSize = int64(16)

	// MaxMemoLen bounds the free-text justification carried by a
	// proposal. It is sanitized before reaching markdown.
	MaxMemoLen = 256

	// MaxDenomLen bounds a sweep denomination.
	MaxDenomLen = 32

	// MaxRenderRows bounds Render output. Render is reachable by any
	// viewer through gnoweb and vm/qrender, so its cost lands on third
	// parties rather than on whoever grew the state.
	MaxRenderRows = 20
)

type proposal struct {
	id        int64
	kind      string
	proposer  address
	memo      string
	createdAt int64

	// KindPay and KindSweep: the recipient. KindPay: the amount.
	to     address
	amount int64

	// KindSweep: the denomination to recover. Never Denom.
	denom string

	// KindSetBoard: the replacement board, applied atomically.
	newSignersCSV string
	newThreshold  int64

	approvals *avl.Tree // signer address string -> struct{}{}

	deferralID uint64 // 0 until armed
	readyAt    int64  // set ONCE at arming; never recalculated
	expiresAt  int64  // armed: end of execution window

	state string
}

var (
	self address // this realm's address, captured at deploy

	signers     *avl.Tree // signer address string -> struct{}{}
	signerCount int64
	threshold   int64

	proposals = avl.NewTree() // padID(id) -> *proposal
	nextID    int64

	pot int64 // funded, not-yet-paid ugnot (the P term)

	// lifetime counters, rendered for operators
	funded int64
	paid   int64

	// Fee cap 0: a treasury board charging itself a fee is surface with
	// no purpose. The fee pot is identically zero and there is no
	// WithdrawFees entrypoint. `upkeep` sets the same precedent.
	ledger = feeledger.MustNew(0)

	// minDelay == maxDelay: the primitive itself refuses any delay other
	// than the compile-time constant.
	book = duebook.MustNew(ExecutionDelayBlocks, ExecutionDelayBlocks, MaxOpenProposals)
)

func init() {
	self = unsafe.CurrentRealm().Address()

	tree, count := parseBoard(InitialSignersCSV)
	if InitialThreshold < 1 || InitialThreshold > count {
		panic("initial threshold must be in [1, board size " + itoa(count) + "]")
	}
	signers = tree
	signerCount = count
	threshold = InitialThreshold
}

// rejectStraySend aborts when coins are attached to a non-payable call.
// This realm holds funds, so a stray send would not be lost outright —
// it would become surplus, which Absorb folds into the pot, silently
// converting a user's coins into treasury funds. Aborting reverts the
// transfer to the sender instead. Guarded on IsUserCall, not IsUser,
// because a MsgRun ephemeral can consume the OriginSend envelope before
// forwarding control.
//
// SCOPE, precisely: the guard reads the ORIGINATING transaction's
// envelope, so it only inspects direct EOA calls. For a realm-routed
// call the -send envelope is delivered to the INTERMEDIARY realm's
// address, so there is nothing at this realm to reject and the guard
// deliberately fails open. That is not a hole: an intermediary that
// separately sends coins to this realm's address is making an ordinary
// transfer, which no guard in any entrypoint could intercept. It is also
// why the guard is the composable two-clause form rather than the
// unconditional len(OriginSend()) != 0 form — the unconditional version
// makes a realm un-callable from ANY realm inside a coin-bearing
// transaction, a cost `upkeep` had to measure and work around.
func rejectStraySend(cur realm) {
	if cur.Previous().IsUserCall() && len(unsafe.OriginSend()) > 0 {
		panic("this entrypoint does not accept coins")
	}
}

// --- funding ---

// Fund adds the attached coins to the pot. Anyone may fund; funding is a
// donation to the treasury and is NOT refundable except through a
// payment the board approves.
func Fund(cur realm) {
	funder, amount := coinio.Receive(0, cur, Denom)
	newPot, ok := checkedAdd(pot, amount)
	if !ok {
		panic("pot would overflow")
	}
	newFunded, ok := checkedAdd(funded, amount)
	if !ok {
		panic("lifetime funded would overflow")
	}
	pot = newPot
	funded = newFunded
	chain.Emit("Funded", "from", funder.String(), "amount", itoa(amount),
		"pot", itoa(pot))
}

// Absorb folds out-of-band ugnot surplus into the pot, restoring
// H == P + U. It moves no coins and is permissionless: the surplus can
// only go to the board-governed pot, so there is nothing for a caller to
// gain and nothing for them to steer.
func Absorb(cur realm) int64 {
	rejectStraySend(cur)
	surplus := Held() - Liabilities()
	if surplus <= 0 {
		panic("no surplus to absorb")
	}
	newPot, ok := checkedAdd(pot, surplus)
	if !ok {
		panic("pot would overflow")
	}
	pot = newPot
	chain.Emit("Absorbed", "amount", itoa(surplus), "pot", itoa(pot))
	return surplus
}

// --- proposing ---

// ProposePayment proposes crediting `to` with `amount` from the pot.
// Signers only. The proposal is NOT self-approved: the proposer must
// call Approve, so intent to propose and intent to authorize stay
// separately recorded.
//
// The pot is NOT reserved at proposal time; sufficiency is checked at
// execution. Reserving would let a stale proposal lock funds it may
// never spend, and the delay already bounds how long a proposal lives.
func ProposePayment(cur realm, to address, amount int64, memo string) int64 {
	rejectStraySend(cur)
	proposer := assertSigner(cur.Previous().Address())
	assertValidAddress("recipient", to)
	if amount <= 0 {
		panic("amount must be positive")
	}
	assertMemo(memo)

	p := newProposal(KindPay, proposer, memo)
	p.to = to
	p.amount = amount
	store(p)
	chain.Emit("Proposed", "id", itoa(p.id), "kind", KindPay,
		"proposer", proposer.String(), "to", to.String(), "amount", itoa(amount))
	return p.id
}

// ProposeBoardChange proposes replacing the signer set AND the threshold
// atomically. Signers only.
//
// Both halves move together so that a board smaller than its own
// threshold cannot be produced by two individually-valid proposals
// landing in sequence.
func ProposeBoardChange(cur realm, signersCSV string, newThreshold int64, memo string) int64 {
	rejectStraySend(cur)
	proposer := assertSigner(cur.Previous().Address())
	assertMemo(memo)

	// Parsed and bounds-checked now so an unsatisfiable board is
	// rejected at proposal time rather than discovered at execution;
	// re-parsed at execution by the same function, so the two can never
	// disagree.
	_, count := parseBoard(signersCSV)
	if newThreshold < 1 || newThreshold > count {
		panic("threshold must be in [1, board size " + itoa(count) + "]")
	}

	p := newProposal(KindSetBoard, proposer, memo)
	p.newSignersCSV = signersCSV
	p.newThreshold = newThreshold
	store(p)
	chain.Emit("Proposed", "id", itoa(p.id), "kind", KindSetBoard,
		"proposer", proposer.String(), "boardSize", itoa(count),
		"threshold", itoa(newThreshold))
	return p.id
}

// ProposeSweep proposes recovering a NON-NATIVE denomination to `to`.
// Signers only.
//
// The native denom is rejected: native surplus belongs to the pot and is
// folded in by Absorb. Allowing a native sweep would create a second,
// differently-accounted way for pooled value to leave.
func ProposeSweep(cur realm, denom string, to address, memo string) int64 {
	rejectStraySend(cur)
	proposer := assertSigner(cur.Previous().Address())
	assertValidAddress("recipient", to)
	assertSweepDenom(denom)
	assertMemo(memo)

	p := newProposal(KindSweep, proposer, memo)
	p.denom = denom
	p.to = to
	store(p)
	chain.Emit("Proposed", "id", itoa(p.id), "kind", KindSweep,
		"proposer", proposer.String(), "denom", denom, "to", to.String())
	return p.id
}

// --- approving ---

// Approve records the caller's approval and arms the proposal the FIRST
// time live approvals reach the threshold. Signers only.
//
// Approving is also permitted while Armed. That is deliberate: if a
// signer revokes and the count falls short, another signer (or the same
// one) can restore it without the clock being touched.
func Approve(cur realm, id int64) {
	rejectStraySend(cur)
	signer := assertSigner(cur.Previous().Address())
	p := mustGetProposal(id)
	if p.state != StatePending && p.state != StateArmed {
		panic("proposal is " + p.state)
	}
	now := runtime.ChainHeight()
	if p.state == StatePending && now >= p.createdAt+ApprovalWindowBlocks {
		panic("approval window has closed")
	}
	key := signer.String()
	if p.approvals.Has(key) {
		panic("already approved")
	}
	p.approvals.Set(key, struct{}{})
	chain.Emit("Approved", "id", itoa(p.id), "signer", key,
		"approvals", itoa(liveApprovals(p)), "threshold", itoa(threshold))
	tryArm(p, now)
}

// RevokeApproval withdraws the caller's approval. Signers only.
//
// It blocks execution while the live count is short, but does NOT rewind
// or postpone an already-set clock — see THE CLOCK in the package
// comment. The proposal stays Armed; Execute re-checks the count.
func RevokeApproval(cur realm, id int64) {
	rejectStraySend(cur)
	signer := assertSigner(cur.Previous().Address())
	p := mustGetProposal(id)
	if p.state != StatePending && p.state != StateArmed {
		panic("proposal is " + p.state)
	}
	key := signer.String()
	if !p.approvals.Has(key) {
		panic("no approval to revoke")
	}
	p.approvals.Remove(key)
	chain.Emit("ApprovalRevoked", "id", itoa(p.id), "signer", key,
		"approvals", itoa(liveApprovals(p)), "threshold", itoa(threshold))
}

// Arm starts the delay on a Pending proposal whose live approvals
// already meet the threshold. Permissionless.
//
// It exists because an executed board change can LOWER the threshold,
// making an untouched proposal eligible with no further Approve call to
// hang the arming off. Permissionless is safe: arming only starts a
// clock, and every authorization check happens again at Execute.
func Arm(cur realm, id int64) {
	rejectStraySend(cur)
	p := mustGetProposal(id)
	if p.state != StatePending {
		panic("proposal is " + p.state)
	}
	if liveApprovals(p) < threshold {
		panic("approvals below threshold")
	}
	tryArm(p, runtime.ChainHeight())
}

// --- executing ---

// Execute applies an armed proposal once its delay has elapsed and
// before its execution window closes. Permissionless.
//
// Permissionless execution is safe BECAUSE value is credited to the
// recorded recipient rather than sent to the caller: the caller's
// identity never routes value. Live approvals are re-checked here, so a
// revocation or a board change that removed an approver blocks the
// execution rather than being papered over by a stale counter.
func Execute(cur realm, id int64) {
	rejectStraySend(cur)
	p := mustGetProposal(id)
	if p.state != StateArmed {
		panic("proposal is " + p.state)
	}

	// Authorization is re-checked BEFORE the deferral is consumed. Both
	// orders are equally safe on-chain — a panic anywhere below reverts
	// the whole transaction, claim included — but this order keeps the
	// authorization failure and the consumption independent, so a
	// rejected execution leaves the deferral untouched in any environment
	// that does not revert (the test VM is one). Ordering a state change
	// after the checks that can reject it is worth doing even when the
	// runtime would have covered for the other order.
	if live := liveApprovals(p); live < threshold {
		panic("approvals fell below threshold: " + itoa(live) + " of " + itoa(threshold))
	}

	// Consume-then-act over never-reused ids: a second Execute of the
	// same proposal cannot find the deferral, so double execution is
	// structurally impossible rather than merely checked for. Any panic
	// below reverts this claim along with everything else.
	if _, err := book.Claim(p.deferralID, runtime.ChainHeight()); err != nil {
		panic(err)
	}

	switch p.kind {
	case KindPay:
		executePayment(p)
	case KindSetBoard:
		executeBoardChange(p)
	case KindSweep:
		executeSweep(cur, p)
	default:
		panic("unknown proposal kind: " + p.kind)
	}

	p.state = StateExecuted
	chain.Emit("Executed", "id", itoa(p.id), "kind", p.kind,
		"by", cur.Previous().Address().String())
}

func executePayment(p *proposal) {
	if p.amount > pot {
		panic("pot holds " + itoa(pot) + Denom + ", proposal needs " + itoa(p.amount) + Denom)
	}
	newPaid, ok := checkedAdd(paid, p.amount)
	if !ok {
		panic("lifetime paid would overflow")
	}
	credited, fee, err := ledger.Deposit(p.to.String(), p.amount, 0)
	if err != nil {
		panic(err)
	}
	// Belt and braces: the ledger is capped at 0 bps and 0 is passed
	// above, so a non-zero fee here would mean the primitive changed
	// under us. Asserting is cheaper than discovering it in the pot.
	if fee != 0 || credited != p.amount {
		panic("ledger credited " + itoa(credited) + " fee " + itoa(fee) +
			" for " + itoa(p.amount) + "; expected a fee-free credit")
	}
	pot -= p.amount
	paid = newPaid
	chain.Emit("Paid", "id", itoa(p.id), "to", p.to.String(),
		"amount", itoa(p.amount), "pot", itoa(pot))
}

func executeBoardChange(p *proposal) {
	tree, count := parseBoard(p.newSignersCSV)
	if p.newThreshold < 1 || p.newThreshold > count {
		panic("threshold must be in [1, board size " + itoa(count) + "]")
	}
	signers = tree
	signerCount = count
	threshold = p.newThreshold
	chain.Emit("BoardChanged", "id", itoa(p.id), "boardSize", itoa(count),
		"threshold", itoa(p.newThreshold))
}

func executeSweep(cur realm, p *proposal) {
	// Re-asserted at execution: the value was validated at proposal
	// time, but this is the point at which coins actually move.
	assertSweepDenom(p.denom)
	swept := coinio.Sweep(0, cur, p.to, p.denom, 0)
	chain.Emit("Swept", "id", itoa(p.id), "to", p.to.String(),
		"coins", itoa(swept)+p.denom)
}

// --- ending a proposal without executing it ---

// Cancel abandons a proposal. Proposer only, and only while it is
// Pending or Armed.
//
// Restricted to the proposer rather than to any signer: a signer who
// disagrees already has RevokeApproval, which blocks execution without
// destroying the record of who approved what.
func Cancel(cur realm, id int64) {
	rejectStraySend(cur)
	caller := cur.Previous().Address()
	p := mustGetProposal(id)
	if p.state != StatePending && p.state != StateArmed {
		panic("proposal is " + p.state)
	}
	if caller != p.proposer {
		panic("proposer only")
	}
	if p.state == StateArmed {
		if _, err := book.Cancel(p.deferralID, padID(p.id)); err != nil {
			panic(err)
		}
	}
	p.state = StateCancelled
	chain.Emit("Cancelled", "id", itoa(p.id), "by", caller.String())
}

// ExpireProposal retires a proposal that ran out of time. Permissionless.
//
// Pending: expirable once the approval window has passed. Armed:
// expirable once the execution window has passed, which also releases
// its duebook slot.
func ExpireProposal(cur realm, id int64) {
	rejectStraySend(cur)
	p := mustGetProposal(id)
	now := runtime.ChainHeight()
	switch p.state {
	case StatePending:
		if now < p.createdAt+ApprovalWindowBlocks {
			panic("approval window is still open until block " +
				itoa(p.createdAt+ApprovalWindowBlocks))
		}
	case StateArmed:
		if _, err := book.Expire(p.deferralID, now); err != nil {
			panic(err)
		}
	default:
		panic("proposal is " + p.state)
	}
	p.state = StateExpired
	chain.Emit("ProposalExpired", "id", itoa(p.id), "by", cur.Previous().Address().String())
}

// --- the pull side ---

// Withdraw pays out `amount` of the caller's own claimable balance.
// The ledger is debited BEFORE the coins move.
func Withdraw(cur realm, amount int64) {
	rejectStraySend(cur)
	caller := cur.Previous().Address()
	if amount <= 0 {
		panic("amount must be positive")
	}
	if err := ledger.Withdraw(caller.String(), amount); err != nil {
		panic(err)
	}
	coinio.Payout(0, cur, caller, Denom, amount)
	chain.Emit("Withdrawn", "to", caller.String(), "amount", itoa(amount))
}

// WithdrawAll pays out the caller's entire claimable balance.
func WithdrawAll(cur realm) int64 {
	rejectStraySend(cur)
	caller := cur.Previous().Address()
	amount, err := ledger.WithdrawAll(caller.String())
	if err != nil {
		panic(err)
	}
	if amount == 0 {
		panic("nothing to withdraw")
	}
	coinio.Payout(0, cur, caller, Denom, amount)
	chain.Emit("Withdrawn", "to", caller.String(), "amount", itoa(amount))
	return amount
}

// --- read-only views ---

// BoardSize returns how many signers the board currently has.
func BoardSize() int64 { return signerCount }

// Threshold returns how many approvals a proposal currently needs.
func Threshold() int64 { return threshold }

// IsSigner reports whether addr is currently on the board.
func IsSigner(addr address) bool { return signers.Has(addr.String()) }

// Signers returns the board as a comma-separated list, in sorted order.
func Signers() string {
	out := ""
	signers.Iterate("", "", func(key string, _ any) bool {
		if out != "" {
			out += ","
		}
		out += key
		return false
	})
	return out
}

// ProposalInfo returns a proposal's scalar fields by value.
func ProposalInfo(id int64) (kind string, proposer address, createdAt int64, to address, amount int64, denom string, newThreshold int64, approvals int64, readyAt, expiresAt int64, state string) {
	p := mustGetProposal(id)
	return p.kind, p.proposer, p.createdAt, p.to, p.amount, p.denom,
		p.newThreshold, liveApprovals(p), p.readyAt, p.expiresAt, p.state
}

// ProposalMemo returns a proposal's raw memo text.
func ProposalMemo(id int64) string { return mustGetProposal(id).memo }

// ProposedBoard returns the replacement board of a KindSetBoard proposal.
func ProposedBoard(id int64) string { return mustGetProposal(id).newSignersCSV }

// HasApproved reports whether addr's approval is recorded on a proposal.
// It is the RAW record: an approval by an address since removed from the
// board still reads true here but does not count toward the threshold.
// Use LiveApprovals for the number that decides execution.
func HasApproved(id int64, addr address) bool {
	return mustGetProposal(id).approvals.Has(addr.String())
}

// LiveApprovals returns the approvals that currently count: recorded
// approvals intersected with the CURRENT board.
func LiveApprovals(id int64) int64 { return liveApprovals(mustGetProposal(id)) }

// RecordedApprovals returns the raw approval count, board changes
// included. It is >= LiveApprovals and decides nothing.
func RecordedApprovals(id int64) int64 {
	return int64(mustGetProposal(id).approvals.Size())
}

// IsExecutable reports whether Execute would pass its timing and
// approval checks at the current height. It does NOT check pot
// sufficiency for a payment; use Pot() and ProposalInfo() for that.
func IsExecutable(id int64) bool {
	p := mustGetProposal(id)
	if p.state != StateArmed {
		return false
	}
	d, found := book.Get(p.deferralID)
	if !found {
		return false
	}
	return d.IsClaimable(runtime.ChainHeight()) && liveApprovals(p) >= threshold
}

// NumProposals returns how many proposals have ever been created.
func NumProposals() int64 { return nextID }

// ArmedCount returns how many proposals currently hold a duebook slot.
func ArmedCount() int64 { return int64(book.OpenCount()) }

// Pot returns the funded, not-yet-paid ugnot (the P term).
func Pot() int64 { return pot }

// Funded returns the lifetime total ever funded.
func Funded() int64 { return funded }

// Paid returns the lifetime total ever paid out by executed proposals.
func Paid() int64 { return paid }

// BalanceOf returns addr's claimable balance.
func BalanceOf(addr address) int64 { return ledger.BalanceOf(addr.String()) }

// UsersTotal returns the sum of all claimable balances (the U term).
func UsersTotal() int64 { return ledger.UsersTotal() }

// Liabilities returns everything this realm owes: pot + claimable
// balances. The fee pot is identically zero.
func Liabilities() int64 { return pot + ledger.Liabilities() }

// Held returns the ugnot actually held at the realm address (H).
func Held() int64 { return coinio.HeldAt(self, Denom) }

// Surplus returns Held() - Liabilities() (the S term).
func Surplus() int64 { return Held() - Liabilities() }

// Address returns this realm's address (the funding target).
func Address() address { return self }

// Height returns the current chain height (delay arithmetic aid).
func Height() int64 { return runtime.ChainHeight() }

// DelayBlocks returns the fixed execution delay. There is no setter.
func DelayBlocks() int64 { return ExecutionDelayBlocks }

// Render shows the treasury at "" and a proposal detail at "<id>".
// Memos are free text and pass through the ecosystem sanitizer before
// hitting markdown.
func Render(path string) string {
	if path != "" {
		return renderProposal(path)
	}
	held := Held()
	liab := Liabilities()
	status := "OK"
	if held < liab {
		status = "VIOLATED"
	}
	out := "# Treasury board\n\n"
	out += "A standing GNOT pool whose payments need " + itoa(threshold) + " of " +
		itoa(signerCount) + " board approvals AND a " + itoa(ExecutionDelayBlocks) +
		"-block wait before the value moves.\n\n"
	out += "## Board\n\n"
	signers.Iterate("", "", func(key string, _ any) bool {
		out += "- `" + key + "`\n"
		return false
	})
	out += "\n- threshold: " + itoa(threshold) + " of " + itoa(signerCount) + "\n"
	out += "- execution delay: " + itoa(ExecutionDelayBlocks) + " blocks (fixed at deploy; no setter)\n"
	out += "- execution window: " + itoa(ExecutionWindowBlocks) + " blocks after due\n"
	out += "- approval window: " + itoa(ApprovalWindowBlocks) + " blocks after proposal\n"
	out += "- armed proposals: " + itoa(int64(book.OpenCount())) + " of " +
		strconv.Itoa(MaxOpenProposals) + "\n"
	out += "- current height: " + itoa(runtime.ChainHeight()) + "\n\n"
	out += "## Accounting (H == P + U + S)\n\n"
	out += "- pot (P): " + itoa(pot) + Denom + "\n"
	out += "- claimable (U): " + itoa(ledger.UsersTotal()) + Denom + "\n"
	out += "- held (H): " + itoa(held) + Denom + "\n"
	out += "- surplus (S): " + itoa(held-liab) + Denom + "\n"
	out += "- conservation: " + status + "\n"
	out += "- lifetime funded / paid: " + itoa(funded) + " / " + itoa(paid) + Denom + "\n\n"
	out += "## Latest proposals\n\n"
	if nextID == 0 {
		out += "No proposals yet.\n"
		return out
	}
	shown := 0
	proposals.ReverseIterate("", "", func(_ string, v any) bool {
		p := v.(*proposal)
		out += "- [#" + itoa(p.id) + "](" + RealmPath + ":" + itoa(p.id) + ") [" +
			p.state + "] " + p.kind + " — " + itoa(liveApprovals(p)) + "/" +
			itoa(threshold) + " approvals" + summarize(p) + "\n"
		shown++
		return shown >= MaxRenderRows
	})
	if int64(shown) < nextID {
		out += "\n> [!NOTE]\n> Showing the " + strconv.Itoa(shown) + " most recent of " +
			itoa(nextID) + ". Use ProposalInfo(id) for any specific proposal.\n"
	}
	return out
}

func renderProposal(path string) string {
	id, err := strconv.ParseInt(path, 10, 64)
	if err != nil {
		return "> [!WARNING]\n> invalid proposal id\n"
	}
	v := proposals.Get(padID(id))
	if v == nil {
		return "> [!WARNING]\n> unknown proposal id\n"
	}
	p := v.(*proposal)
	now := runtime.ChainHeight()

	out := "# Proposal #" + itoa(p.id) + " (" + p.kind + ")\n\n"
	out += "- state: " + p.state + "\n"
	out += "- proposer: " + p.proposer.String() + "\n"
	out += "- created at block: " + itoa(p.createdAt) + "\n"
	out += "- live approvals: " + itoa(liveApprovals(p)) + " of " + itoa(threshold) +
		" (recorded: " + strconv.Itoa(p.approvals.Size()) + ")\n"
	switch p.kind {
	case KindPay:
		out += "- pay: " + itoa(p.amount) + Denom + " to `" + p.to.String() + "`\n"
	case KindSetBoard:
		out += "- new threshold: " + itoa(p.newThreshold) + "\n"
		out += "- new board: `" + sanitize.InlineText(p.newSignersCSV) + "`\n"
	case KindSweep:
		out += "- sweep denom `" + sanitize.InlineText(p.denom) + "` to `" +
			p.to.String() + "`\n"
	}
	if p.state == StateArmed {
		out += "- executable from block: " + itoa(p.readyAt) + "\n"
		out += "- expires at block: " + itoa(p.expiresAt) + "\n"
		if now < p.readyAt {
			out += "- **waiting**: " + itoa(p.readyAt-now) + " blocks remain\n"
		} else if now < p.expiresAt {
			out += "- **executable now**\n"
		} else {
			out += "- **expired**: call ExpireProposal\n"
		}
	} else if p.state == StatePending {
		out += "- approval window closes at block: " +
			itoa(p.createdAt+ApprovalWindowBlocks) + "\n"
	}
	out += "\n## Memo\n\n" + sanitize.InlineText(p.memo) + "\n\n"
	out += "## Approvals recorded\n\n"
	if p.approvals.Size() == 0 {
		out += "None yet.\n"
		return out
	}
	p.approvals.Iterate("", "", func(key string, _ any) bool {
		mark := " (no longer on the board)"
		if signers.Has(key) {
			mark = ""
		}
		out += "- `" + key + "`" + mark + "\n"
		return false
	})
	return out
}

// --- internals ---

// assertSigner returns the caller after proving they are on the board.
func assertSigner(caller address) address {
	if !signers.Has(caller.String()) {
		panic("signer only")
	}
	return caller
}

func mustGetProposal(id int64) *proposal {
	v := proposals.Get(padID(id))
	if v == nil {
		panic("unknown proposal id")
	}
	return v.(*proposal)
}

func newProposal(kind string, proposer address, memo string) *proposal {
	nextID++
	return &proposal{
		id:        nextID,
		kind:      kind,
		proposer:  proposer,
		memo:      memo,
		createdAt: runtime.ChainHeight(),
		approvals: avl.NewTree(),
		state:     StatePending,
	}
}

func store(p *proposal) { proposals.Set(padID(p.id), p) }

// liveApprovals intersects a proposal's recorded approvers with the
// CURRENT board. Never cached — see WHY THE LIVE RE-COUNT in the package
// comment.
func liveApprovals(p *proposal) int64 {
	n := int64(0)
	p.approvals.Iterate("", "", func(key string, _ any) bool {
		if signers.Has(key) {
			n++
		}
		return false
	})
	return n
}

// tryArm schedules the delay the FIRST time a pending proposal's live
// approvals reach the threshold. readyAt is set here and nowhere else.
func tryArm(p *proposal, now int64) {
	if p.state != StatePending {
		return
	}
	if liveApprovals(p) < threshold {
		return
	}
	if now >= p.createdAt+ApprovalWindowBlocks {
		panic("approval window has closed")
	}
	did, err := book.Schedule(padID(p.id), p.kind, now,
		ExecutionDelayBlocks, ExecutionWindowBlocks)
	if err != nil {
		panic(err)
	}
	d, found := book.Get(did)
	if !found {
		panic("scheduled deferral is missing")
	}
	p.deferralID = did
	p.readyAt = d.DueAt
	p.expiresAt = d.ExpiresAt
	p.state = StateArmed
	chain.Emit("Armed", "id", itoa(p.id), "readyAt", itoa(d.DueAt),
		"expiresAt", itoa(d.ExpiresAt))
}

// parseBoard turns a comma-separated signer list into a membership tree.
// Every entry must be a valid, lowercase, non-empty, non-duplicate
// bech32 address.
//
// Validity is checked rather than trusted: a mistyped signer address
// would silently shrink the effective board and could make the threshold
// permanently unreachable, which strands the pot. The lowercase check is
// there because bech32 has a distinct all-uppercase encoding of the same
// address, and two spellings of one signer would let that signer be
// counted twice toward a threshold (the fee_split/v2 precedent).
//
// That clause is LOAD-BEARING, not belt-and-braces, and the difference was
// measured rather than argued. address.IsValid() is a native method that
// defers to crypto.AddressFromBech32 -> btcutil/bech32.DecodeNoLimit,
// which lowercases the input BEFORE verifying the checksum. It therefore
// returns true for the all-uppercase spelling of a valid address: remove
// `key != strings.ToLower(key)` and one signer can hold two board seats.
//
// The same read shows the check is COMPLETE. That decoder rejects mixed
// case outright (ErrMixedCase), so a valid address has exactly two
// encodings -- all-lower and all-upper -- and rejecting every non-lower
// spelling leaves precisely the canonical one. There is no third encoding
// for the duplicate-seat hazard to hide in.
func parseBoard(csv string) (*avl.Tree, int64) {
	parts := strings.Split(csv, ",")
	tree := avl.NewTree()
	count := int64(0)
	for _, part := range parts {
		key := strings.TrimSpace(part)
		if key == "" {
			panic("board contains an empty entry")
		}
		if !address(key).IsValid() || key != strings.ToLower(key) {
			panic("board contains an invalid address: " + key)
		}
		if tree.Has(key) {
			panic("board contains a duplicate address: " + key)
		}
		count++
		if count > MaxBoardSize {
			panic("board exceeds " + itoa(MaxBoardSize) + " signers")
		}
		tree.Set(key, struct{}{})
	}
	if count == 0 {
		panic("board must name at least one signer")
	}
	return tree, count
}

func assertValidAddress(what string, addr address) {
	if !addr.IsValid() || string(addr) != strings.ToLower(string(addr)) {
		panic("invalid " + what + " address")
	}
}

func assertMemo(memo string) {
	if len(memo) == 0 || len(memo) > MaxMemoLen {
		panic("memo must be 1-" + strconv.Itoa(MaxMemoLen) + " bytes")
	}
}

// assertSweepDenom bounds a recovery denomination and refuses the native
// one, which belongs to the pot and is folded in by Absorb.
func assertSweepDenom(denom string) {
	if denom == Denom {
		panic("native " + Denom + " is absorbed into the pot, not swept")
	}
	if len(denom) == 0 || len(denom) > MaxDenomLen {
		panic("denom must be 1-" + strconv.Itoa(MaxDenomLen) + " bytes")
	}
	for i := 0; i < len(denom); i++ {
		c := denom[i]
		switch {
		case c >= 'a' && c <= 'z':
		case c >= 'A' && c <= 'Z':
		case c >= '0' && c <= '9':
		case c == '/' || c == ':' || c == '.' || c == '_' || c == '-':
		default:
			panic("denom may only contain letters, digits and /:._-")
		}
	}
}

// summarize renders the one-line tail of a proposal in the board list.
func summarize(p *proposal) string {
	switch p.kind {
	case KindPay:
		return " — " + itoa(p.amount) + Denom + " to " + p.to.String()
	case KindSetBoard:
		return " — new threshold " + itoa(p.newThreshold)
	case KindSweep:
		return " — recover " + sanitize.InlineText(p.denom)
	}
	return ""
}

// padID renders an id as a fixed-width key so avl iteration order is
// numeric order.
func padID(id int64) string {
	s := strconv.FormatInt(id, 10)
	for len(s) < 12 {
		s = "0" + s
	}
	return s
}

func itoa(n int64) string { return strconv.FormatInt(n, 10) }

// checkedAdd reports the sum and whether it stayed inside int64.
func checkedAdd(a, b int64) (int64, bool) {
	c := a + b
	if (b > 0 && c < a) || (b < 0 && c > a) {
		return 0, false
	}
	return c, true
}
