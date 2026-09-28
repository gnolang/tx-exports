// Realm vesting escrows native GNOT for a named beneficiary and releases
// it in DISCRETE, INDIVIDUALLY DATED TRANCHES — each payable exactly once,
// at or after its own due height.
//
// # DISCRETE, NOT LINEAR — read this first
//
// Everywhere else in this ecosystem "vesting" means CONTINUOUS LINEAR
// ACCRUAL: a formula of the form amount * elapsed / duration, evaluated
// whenever someone asks. This realm does no such arithmetic. A funder
// states an explicit list of (delay, amount) pairs at funding time, and
// nothing accrues between them: a tranche is worth zero until its due
// height and its full amount from that height on.
//
// That is a deliberate choice, not a simplification:
//
//   - It is the shape real schedules actually have — cliffs, quarterly
//     tranches, milestone payments, a lump sum on a date.
//   - It has no `amount * elapsed` term, so the int64 overflow class that
//     has already shipped a NEGATIVE vested amount in two independent
//     ecosystem packages cannot occur here: that MULTIPLICATIVE class is
//     designed out rather than guarded against. The additive sums that do
//     exist are guarded, not designed out — Fund checks the tranche total
//     and the escrow total with checkedAdd, each with its own panic,
//     before any state changes. Both halves are true and neither replaces
//     the other.
//   - It maps exactly onto duebook, whose exactly-once Claim is what makes
//     a double release structurally impossible rather than merely checked.
//
// There is no default curve to be surprised by: every tranche is stated
// explicitly at creation, or the schedule does not exist.
//
// # COMPOSITION
//
// This realm owns only the schedule state machine. Everything else is
// delegated to primitives already audited and deployed:
//
//	duebook   — the entire schedule: due heights, and exactly-once release
//	coinio    — coin custody: escrow-in, payout, surplus sweep
//	feeledger — claimable balances and the fee pot
//	sanitize  — funder-supplied free text, before it reaches markdown
//
// It is duebook's FIRST PRODUCTIVE CONSUMER. duebook_demo is the
// falsification experiment and holds no coins by design; this realm is the
// first to put value behind the exactly-once claim.
//
// # LIFECYCLE
//
//	Fund (EOA + -send)      : one transaction creates the schedule, escrows
//	                          the exact total, and registers every tranche
//	                          in duebook. There is no draft state and no
//	                          half-funded schedule.
//	Release (ANYONE)        : once a tranche is due, anyone may release it.
//	                          The value is credited to the RECORDED
//	                          BENEFICIARY, never to the caller.
//	Revoke (funder only)    : returns a NOT-YET-DUE tranche to the funder,
//	                          and only if the schedule was created
//	                          revocable. A due tranche can never be revoked.
//	Withdraw / WithdrawAll  : pays out the caller's own claimable balance.
//
// # WHY NOTHING CAN BE TRAPPED, AND WHY THERE IS NO EXPIRY
//
// Tranches are scheduled with duebook's ttl == 0, so they NEVER expire.
// Vested value cannot be lost by a beneficiary who is slow, offline, or
// gone. The sibling realms in this portfolio use a permissionless expiry
// valve to guarantee escrow is never trapped; here the valve is different
// and stronger: Release is PERMISSIONLESS, so every tranche becomes
// claimable-by-anyone the moment it is due, and the schedule drains itself
// without depending on any particular actor staying alive. Combined with
// "a due tranche can never be revoked", every ugnot in escrow has exactly
// one reachable destination and a height after which nobody can block it.
//
// # VESTED MEANS IRREVOCABLE, WITH NO RACE
//
// Revoke refuses any tranche whose due height has arrived, even though
// duebook's Cancel would happily consume it. THAT CHECK IS THIS REALM'S,
// not duebook's. Without it a funder could watch for the due height and
// front-run the beneficiary's Release to claw back value already earned.
// Likewise, `revocable` is fixed at funding and has no setter: an
// irrevocable schedule cannot be made revocable later, which is the only
// thing that makes the promise worth anything.
//
// # AUTHORIZATION
//
// Every identity is derived from the crossing entrypoint's
// cur.Previous().Address(). No function takes a caller identity as a
// parameter, so acting as another account is impossible by construction.
// Release is permissionless *because* it pays the recorded beneficiary:
// the caller's identity is not used to route value, so there is nothing
// for a stranger to gain.
//
// # HOW IT WIRES DUEBOOK CORRECTLY (duebook's five-point consumer contract)
//
//  1. THE CLOCK IS runtime.ChainHeight(), never a call argument. A realm
//     that lets a caller choose `now` has no delay at all.
//  2. HEIGHTS ARE THE ONLY UNIT. No timestamp appears anywhere.
//  3. THE *Book IS NEVER EXPORTED. It is an unexported package var and is
//     never returned across a realm boundary; handing it out would hand out
//     the right to schedule, cancel and claim.
//  4. THE ACTOR IS AUTHORIZED from cur.Previous().Address(); the duebook
//     owner recorded at Schedule is the funder, and duebook checks Cancel
//     against that recorded value, never against an argument.
//  5. THE EFFECT HAPPENS AFTER A SUCCESSFUL Claim, IN THE SAME
//     TRANSACTION.
//
// The deferral PAYLOAD is a human-readable label for events and rendering.
// THIS REALM NEVER PARSES IT. Every authoritative fact about a tranche —
// its amount, its schedule, its beneficiary — comes from this realm's own
// `tranches` tree, keyed by the deferral ID that duebook guarantees is
// never reused.
//
// # MONETARY INVARIANT (conservation)
//
// Let H be ugnot held at this realm's address, E = escrowTotal (the sum of
// amounts over tranches still pending), U the ledger's claimable balances,
// F the fee pot, and S >= 0 out-of-band surplus:
//
//	H == E + U + F + S
//
// Fund raises H and E together (coinio.Receive is the receipt-guaranteed
// shape). Release moves one tranche amount from E into U+F, with feeledger
// guaranteeing credited + fee == amount. Revoke moves a tranche amount from
// E into U, fee-free. Withdrawals debit the ledger BEFORE coinio.Payout
// moves the identical amount out (checks-effects-interactions). Any panic
// aborts the whole transaction. This realm never issues or removes coins.
// Surplus is recoverable only via SweepDenom, which reserves Liabilities().
//
// # ONLY GNOT
//
// Fund rejects any envelope that is not exactly one positive ugnot coin.
// Foreign denominations sit in surplus and are sweepable.
package vesting

import (
	"chain"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"strings"

	"gno.land/p/g1qp5pt8cdq2f6kfdamn3yuxwg6quqnfpyewzz39/coinio"
	"gno.land/p/g1qp5pt8cdq2f6kfdamn3yuxwg6quqnfpyewzz39/duebook"
	"gno.land/p/g1qp5pt8cdq2f6kfdamn3yuxwg6quqnfpyewzz39/feeledger"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/markdown/sanitize/v0"
)

// Denom is the only asset this realm escrows.
const Denom = "ugnot"

// MaxFeeBps is the hard protocol-fee cap: 1000 bps = 10%.
const MaxFeeBps = int64(1000)

// Tranche status values. A tranche is created pending and reaches exactly
// one terminal state; both terminals are frozen.
const (
	StatusPending  = "pending"
	StatusReleased = "released"
	StatusRevoked  = "revoked"
)

// Bounds. All are compile-time constants: none is admin-mutable, so a
// schedule's shape cannot be changed under its funder or beneficiary.
const (
	// MinDelayBlocks is the floor on how far ahead the FIRST tranche may
	// fall. One block is enough to prove the delay is enforced while
	// keeping the realm exercisable on a live chain.
	MinDelayBlocks = int64(1)

	// MaxDelayBlocks caps the furthest tranche at roughly 10.8 years at
	// pearl-1's ~3.42s blocks. It also bounds now+delay far inside int64.
	MaxDelayBlocks = int64(100_000_000)

	// MaxTranches bounds one schedule. It bounds the Fund transaction's
	// work, the RevokeAll loop, and the schedule detail render.
	MaxTranches = 64

	// MaxOpenTranches caps pending tranches across EVERY schedule at once
	// — it is a whole-realm limit, not a per-schedule one, because it is
	// duebook's open-deferral cap. Fund fails when a new schedule would
	// cross it. Must be <= duebook.MaxOpenLimit.
	MaxOpenTranches = 5000

	// MaxOpenPerFunder bounds how many tranches ONE funder may hold
	// pending at once, so that MaxOpenTranches cannot be consumed by a
	// single account.
	//
	// Without this bound the whole-realm cap is a denial-of-service
	// surface that costs nothing to use: 79 Fund calls of 64 one-ugnot
	// tranches fill the realm, Fund then aborts for everybody, and the
	// attacker recovers 100% of the escrow fee-free with RevokeAll. Two
	// deliberate choices elsewhere remove every recovery path — ttl is
	// always 0, so duebook's permissionless Expire valve never opens, and
	// MaxOpenTranches is a compile-time constant with no admin setter. The
	// denial would therefore be total and permanent, which is out of all
	// proportion to its cost.
	//
	// 256 leaves one funder four full MaxTranches schedules open at once —
	// generous for the intended use — while exhausting the realm now takes
	// at least ceil(5000/256) = 20 separately funded accounts.
	//
	// That is a SYBIL BOUND and nothing more, so the residual is quantified
	// here rather than left to be inferred from the 20: the cap counts
	// TRANCHES, never value. parseSpec accepts amount == 1, so 256 pending
	// tranches cost 256ugnot and all 20 accounts together escrow about
	// 5000ugnot — every bit of it recoverable fee-free, since revokeOne
	// refunds at 0 bps. The real cost of the realm-wide denial is therefore
	// ~80 Fund transactions' gas and 20 funded addresses, NOT capital.
	// Anyone sizing the residual risk from the "20 accounts" figure alone
	// will size it wrong by orders of magnitude.
	//
	// Bounding the attack by VALUE instead would take a per-tranche minimum
	// amount. That is a change to what the application is — it would price
	// small legitimate tranches out — so it is a reviewer's decision, not a
	// routine fix, and it is deliberately not made here.
	MaxOpenPerFunder = 256

	// MaxTitleLen bounds a schedule title. Titles are charset-restricted
	// so they are list-safe in Render without escaping.
	MaxTitleLen = 80

	// MaxMemoLen bounds the free-text memo. It is a BYTE length, not a
	// rune count, because its job is to bound storage.
	MaxMemoLen = 1000

	// MaxSpecLen bounds the tranche specification string, so parsing cost
	// is bounded before any parsing begins.
	MaxSpecLen = 1400

	// MaxListed caps how many entries a single view or render returns.
	MaxListed = 50
)

// tranche is one dated payment. It is this realm's authoritative record;
// the matching duebook deferral carries only the due height and a label.
// Records are kept after they terminate, so history remains answerable
// once duebook has consumed the deferral.
type tranche struct {
	deferralID uint64
	scheduleID int64
	seq        int64 // 1-based position within its schedule
	amount     int64
	dueAt      int64
	status     string
	settledAt  int64 // height of release or revocation; 0 while pending
}

// schedule is one funded vesting agreement.
type schedule struct {
	id          int64
	funder      address
	beneficiary address
	title       string
	memo        string
	total       int64 // Σ tranche amounts, fixed at funding
	feeBps      int64 // snapshotted at funding, charged at each release
	revocable   bool  // fixed at funding; there is no setter
	createdAt   int64
	trancheIDs  []uint64 // in tranche order

	pending       int64 // count of tranches still pending
	releasedGross int64 // Σ amounts released (before fee)
	revokedTotal  int64 // Σ amounts returned to the funder
}

var (
	admin        address // may set fee, fee recipient, and propose a successor
	pendingAdmin address // must accept before the handover takes effect
	feeRecipient address // may withdraw fees and sweep surplus
	feeBps       int64   // fee snapshotted into NEW schedules

	self           address // this realm's address, captured at deploy
	nextScheduleID int64
	escrowTotal    int64 // == Σ amount over pending tranches (the E term)

	schedules = avl.NewTree() // padID(scheduleID)  -> *schedule
	tranches  = avl.NewTree() // padU(deferralID)   -> *tranche

	// openByFunder counts each funder's still-pending tranches, for the
	// MaxOpenPerFunder cap. An entry is REMOVED at zero rather than left
	// holding 0, so the tree tracks live funders and does not accumulate a
	// dead key per address that ever funded anything.
	openByFunder = avl.NewTree() // funder.String() -> int64

	ledger = feeledger.MustNew(MaxFeeBps)

	// book is unexported and never returned (duebook consumer contract 3).
	book = duebook.MustNew(MinDelayBlocks, MaxDelayBlocks, MaxOpenTranches)
)

func init() {
	admin = unsafe.OriginCaller()
	feeRecipient = admin
	self = unsafe.CurrentRealm().Address()
}

// rejectStraySend aborts if an EOA attached coins to an entrypoint that has
// no use for them. Only Fund accepts value; without this guard a mistyped
// send would be silently absorbed into surplus.
func rejectStraySend(cur realm) {
	if !cur.IsCurrent() {
		// every call site passes the entrypoint's own first cur; this
		// pins that discipline against future call-site drift, which is
		// the house pattern from fee_split/v2. Unexported and with all
		// 11 call sites forwarding a live cur, this is unreachable
		// today — it is here because the artifact is immutable and the
		// guard's answer decides whether coins are rejected or absorbed
		panic("realm capability is not current")
	}
	if cur.Previous().IsUserCall() && len(unsafe.OriginSend()) > 0 {
		panic("this entrypoint does not accept coins; only Fund does")
	}
}

// Fund creates a vesting schedule in a single transaction: it escrows the
// attached GNOT, registers every tranche with duebook, and returns the new
// schedule id. Only direct EOA calls with -send are accepted.
//
// spec lists the tranches as "delay:amount" pairs separated by commas, for
// example "100:500,200:500,300:1000". Delays are in BLOCKS FROM NOW and
// must be STRICTLY INCREASING — two payments at the same height are one
// tranche with the amounts added. Every amount must be positive, and the
// amounts must sum to EXACTLY the attached send: this realm will not
// silently absorb a surplus or create an underfunded schedule.
//
// revocable decides, permanently, whether the funder may reclaim
// not-yet-due tranches. There is no setter; an irrevocable schedule stays
// irrevocable.
//
// maxFeeBps is the ceiling the caller signs for. Funding is rejected if the
// live fee exceeds it, which closes the race where an admin sequences a fee
// raise ahead of this transaction. Pass MaxFeeBps to accept any legal fee.
func Fund(cur realm, beneficiary address, title, memo, spec string, revocable bool, maxFeeBps int64) int64 {
	// Receive first and exactly once per transaction (coinio's contract):
	// it READS the send envelope and cannot mark it spent, so crediting
	// per call would mint unbacked liabilities from a single -send.
	funder, amount := coinio.Receive(0, cur, Denom)

	if feeBps > maxFeeBps {
		panic("current fee " + itoa(feeBps) + " bps exceeds the caller's maximum " + itoa(maxFeeBps))
	}
	var zero address
	if beneficiary == zero {
		panic("empty beneficiary address")
	}
	// This realm can never call its own Withdraw, so a balance credited to
	// its own address is claimable by nobody while still counting inside
	// Liabilities() — permanently stranded AND permanently shrinking
	// SweepDenom's reach. Unlike an arbitrary typo, self is a uniquely
	// knowable address this realm publishes itself via Address(), so it is
	// the one wrong beneficiary worth spending a comparison on
	if beneficiary == self {
		panic("beneficiary must not be this realm's own address")
	}
	assertValidTitle(title)
	if len(memo) > MaxMemoLen {
		panic("memo exceeds " + itoa(MaxMemoLen) + " bytes")
	}

	delays, amounts := parseSpec(spec)
	n := int64(len(delays))

	// The declared total must match the escrow exactly, in both directions.
	declared := int64(0)
	for _, a := range amounts {
		sum, ok := checkedAdd(declared, a)
		if !ok {
			panic("tranche amounts overflow int64")
		}
		declared = sum
	}
	if declared != amount {
		panic("tranche amounts total " + itoa(declared) + Denom +
			" but " + itoa(amount) + Denom + " was sent; they must be equal")
	}

	// Whole-realm capacity check, ahead of any state change, for a clear
	// message. duebook would refuse with ErrBookFull anyway, and a panic
	// there would abort this transaction wholly — the pre-check only
	// improves the error.
	if int64(book.OpenCount())+n > int64(MaxOpenTranches) {
		panic("realm tranche capacity reached: " + itoa(int64(book.OpenCount())) +
			" pending of " + itoa(int64(MaxOpenTranches)) + ", this schedule needs " + itoa(n))
	}

	// Per-funder capacity, so one account cannot consume the whole-realm
	// cap above and lock everybody out. See MaxOpenPerFunder.
	if mine := openOf(funder); mine+n > int64(MaxOpenPerFunder) {
		panic("funder tranche capacity reached: " + itoa(mine) + " pending of " +
			itoa(int64(MaxOpenPerFunder)) + ", this schedule needs " + itoa(n))
	}

	newEscrow, ok := checkedAdd(escrowTotal, amount)
	if !ok {
		panic("escrow overflow")
	}

	now := runtime.ChainHeight() // the chain's clock (contract 1), heights only (contract 2)

	nextScheduleID++
	s := &schedule{
		id:          nextScheduleID,
		funder:      funder,
		beneficiary: beneficiary,
		title:       title,
		memo:        memo,
		total:       amount,
		feeBps:      feeBps,
		revocable:   revocable,
		createdAt:   now,
		pending:     n,
	}

	for i := 0; i < len(delays); i++ {
		seq := int64(i + 1)
		// The payload is a label for humans and events. It is NEVER parsed
		// (see the package doc): the authoritative record is the tranche
		// struct stored under the deferral ID below.
		label := "schedule " + itoa(s.id) + " tranche " + itoa(seq) + "/" + itoa(n)

		// ttl 0 means the tranche never expires: vested value cannot be
		// lost by a slow or absent beneficiary.
		did, err := book.Schedule(funder.String(), label, now, delays[i], 0)
		if err != nil {
			panic(err)
		}
		d, found := book.Get(did)
		if !found {
			panic("internal: scheduled deferral not found")
		}
		tranches.Set(padU(did), &tranche{
			deferralID: did,
			scheduleID: s.id,
			seq:        seq,
			amount:     amounts[i],
			dueAt:      d.DueAt,
			status:     StatusPending,
		})
		s.trancheIDs = append(s.trancheIDs, did)

		chain.Emit("TrancheScheduled",
			"schedule", itoa(s.id),
			"tranche", utoa(did),
			"seq", itoa(seq),
			"amount", itoa(amounts[i]),
			"dueAt", itoa(d.DueAt),
		)
	}

	schedules.Set(padID(s.id), s)
	escrowTotal = newEscrow
	addOpen(funder, n) // commits with escrowTotal: both count the same tranches

	chain.Emit("ScheduleFunded",
		"schedule", itoa(s.id),
		"funder", funder.String(),
		"beneficiary", beneficiary.String(),
		"total", itoa(amount),
		"tranches", itoa(n),
		"feeBps", itoa(s.feeBps),
		"revocable", btoa(revocable),
	)
	return s.id
}

// Release pays out a due tranche. ANYONE may call it: the value is credited
// to the schedule's RECORDED BENEFICIARY, never to the caller, so a
// stranger calling this gains nothing and the beneficiary needs no liveness
// of their own. The protocol fee snapshotted at funding is charged here.
//
// Aborts if the tranche does not exist, is not due yet, or has already been
// released or revoked — the last of those is duebook's guarantee, not a
// check written here.
func Release(cur realm, trancheID int64) string {
	rejectStraySend(cur)

	did := mustID(trancheID)
	now := runtime.ChainHeight()

	// CONSUME FIRST (duebook consumer contract 5). Claim removes the
	// deferral before returning, so by the time the effect below runs no
	// second Claim of this ID can ever succeed — not in this transaction,
	// and not in any future one. This realm writes no replay guard of its
	// own because duebook's is structural.
	d, err := book.Claim(did, now)
	if err != nil {
		panic(err)
	}

	// EFFECT SECOND, same transaction.
	t := mustTranche(d.ID)
	if t.status != StatusPending {
		// Unreachable: a successful Claim proves the deferral was open, and
		// this realm terminates the tranche record in the same transaction
		// it consumes the deferral. Kept as a consistency assertion — if it
		// ever fires, the two stores have diverged and the transaction must
		// not proceed.
		panic("internal: claimed a deferral whose tranche is " + t.status)
	}
	s := mustSchedule(t.scheduleID)

	// feeledger validates before mutating, and guarantees
	// credited + fee == amount.
	credited, fee, err := ledger.Deposit(s.beneficiary.String(), t.amount, s.feeBps)
	if err != nil {
		panic(err)
	}
	escrowTotal -= t.amount // >= 0: escrowTotal == Σ pending amounts >= t.amount
	t.status = StatusReleased
	t.settledAt = now
	s.pending--
	s.releasedGross += t.amount
	addOpen(s.funder, -1) // this tranche no longer counts against the funder

	chain.Emit("TrancheReleased",
		"schedule", itoa(s.id),
		"tranche", utoa(d.ID),
		"seq", itoa(t.seq),
		"beneficiary", s.beneficiary.String(),
		"credited", itoa(credited),
		"fee", itoa(fee),
		"caller", cur.Previous().Address().String(),
		"height", itoa(now),
	)
	return "released tranche " + utoa(d.ID) + " (" + itoa(credited) + Denom + " to " +
		s.beneficiary.String() + ")"
}

// Revoke returns a NOT-YET-DUE tranche to the funder's claimable balance,
// fee-free. Only the funder may call it, and only on a schedule created
// revocable.
//
// A tranche whose due height has arrived can never be revoked, even though
// duebook's Cancel would consume it: that refusal is this realm's, and it
// is what stops a funder front-running the beneficiary's Release to claw
// back value already vested.
func Revoke(cur realm, trancheID int64) string {
	rejectStraySend(cur)

	caller := cur.Previous().Address()
	did := mustID(trancheID)
	t := mustTranche(did)
	s := mustSchedule(t.scheduleID)

	assertRevocableBy(s, caller)
	now := runtime.ChainHeight()
	if now >= t.dueAt {
		panic("tranche " + utoa(did) + " is due at height " + itoa(t.dueAt) +
			" (now " + itoa(now) + "): a vested tranche can never be revoked")
	}

	revokeOne(cur, s, t, now)
	return "revoked tranche " + utoa(did) + " (" + itoa(t.amount) + Denom + " to the funder)"
}

// RevokeAll returns every not-yet-due tranche of a schedule to the funder's
// claimable balance in one transaction, and returns how many were revoked.
// Already-due and already-settled tranches are skipped, not an error.
// Funder only, revocable schedules only. Aborts if nothing was revocable,
// so a no-op cannot be mistaken for success.
func RevokeAll(cur realm, scheduleID int64) string {
	rejectStraySend(cur)

	caller := cur.Previous().Address()
	s := mustSchedule(scheduleID)
	assertRevocableBy(s, caller)
	now := runtime.ChainHeight()

	// Bounded by MaxTranches, so the loop cost is bounded at funding time.
	count := int64(0)
	total := int64(0)
	for _, did := range s.trancheIDs {
		v := tranches.Get(padU(did))
		if v == nil {
			panic("internal: schedule references an unknown tranche")
		}
		t := v.(*tranche)
		if t.status != StatusPending || now >= t.dueAt {
			continue
		}
		amount := t.amount
		revokeOne(cur, s, t, now)
		count++
		total += amount // bounded by s.total, which was overflow-checked at funding
	}
	if count == 0 {
		panic("no revocable tranches: every tranche of this schedule is already due or settled")
	}

	chain.Emit("ScheduleRevoked",
		"schedule", itoa(s.id),
		"tranches", itoa(count),
		"amount", itoa(total),
		"height", itoa(now),
	)
	return "revoked " + itoa(count) + " tranches (" + itoa(total) + Denom + " to the funder)"
}

// revokeOne cancels one pending, not-yet-due tranche and credits the funder
// fee-free. Callers have already verified authorization, revocability and
// the due-height refusal.
func revokeOne(cur realm, s *schedule, t *tranche, now int64) {
	// CONSUME FIRST. Ownership is checked by duebook against the funder
	// address this realm recorded at Schedule, never against an argument
	// (duebook consumer contract 4).
	d, err := book.Cancel(t.deferralID, s.funder.String())
	if err != nil {
		panic(err)
	}
	_ = d

	// EFFECT SECOND, same transaction. Refunds are always fee-free.
	if _, _, err := ledger.Deposit(s.funder.String(), t.amount, 0); err != nil {
		panic(err)
	}
	escrowTotal -= t.amount
	t.status = StatusRevoked
	t.settledAt = now
	s.pending--
	s.revokedTotal += t.amount
	addOpen(s.funder, -1) // revoking frees the funder's slot too

	chain.Emit("TrancheRevoked",
		"schedule", itoa(s.id),
		"tranche", utoa(t.deferralID),
		"seq", itoa(t.seq),
		"funder", s.funder.String(),
		"amount", itoa(t.amount),
		"height", itoa(now),
	)
}

// Withdraw sends amount ugnot of the caller's claimable balance (released
// tranches for a beneficiary, revocations for a funder) to the caller.
func Withdraw(cur realm, amount int64) string {
	rejectStraySend(cur)
	caller := cur.Previous().Address()

	// Debit the ledger BEFORE the coins move (coinio's ordering contract).
	if err := ledger.Withdraw(caller.String(), amount); err != nil {
		panic(err)
	}
	coinio.Payout(0, cur, caller, Denom, amount)

	chain.Emit("Withdrawn", "to", caller.String(), "amount", itoa(amount))
	return "withdrew " + itoa(amount) + Denom
}

// WithdrawAll sends the caller's entire claimable balance to the caller.
// Aborts if there is nothing to withdraw.
func WithdrawAll(cur realm) string {
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
	return "withdrew " + itoa(amount) + Denom
}

// WithdrawFees sends the accrued fee pot to the fee recipient. Only the fee
// recipient may call it.
func WithdrawFees(cur realm) string {
	rejectStraySend(cur)
	caller := cur.Previous().Address()
	if caller != feeRecipient {
		panic("only the fee recipient may withdraw fees")
	}
	if ledger.FeesAccrued() == 0 {
		panic("no fees accrued")
	}
	amount := ledger.WithdrawFees()
	coinio.Payout(0, cur, feeRecipient, Denom, amount)

	chain.Emit("FeesWithdrawn", "to", feeRecipient.String(), "amount", itoa(amount))
	return "withdrew " + itoa(amount) + Denom + " in fees"
}

// SweepDenom sends the surplus of a single denomination to the fee
// recipient. For ugnot only the excess over Liabilities() moves — escrowed
// tranches and claimable balances are untouchable by construction. Other
// denominations move wholly. Only the fee recipient may call it.
func SweepDenom(cur realm, denom string) string {
	rejectStraySend(cur)
	caller := cur.Previous().Address()
	if caller != feeRecipient {
		panic("only the fee recipient may sweep surplus")
	}
	reserve := int64(0)
	if denom == Denom {
		reserve = Liabilities()
	}
	swept := coinio.Sweep(0, cur, feeRecipient, denom, reserve)

	chain.Emit("SurplusSwept", "to", feeRecipient.String(), "coins", itoa(swept)+denom)
	return "swept " + itoa(swept) + denom
}

// --- administration ---

// SetFeeBps sets the protocol fee snapshotted into FUTURE schedules at
// funding. Existing schedules keep the fee they were funded under, so an
// in-flight schedule's economics cannot be changed. Admin only.
func SetFeeBps(cur realm, bps int64) {
	rejectStraySend(cur)
	assertAdmin(cur.Previous().Address())
	if bps < 0 || bps > MaxFeeBps {
		panic("fee bps out of range [0, " + itoa(MaxFeeBps) + "]")
	}
	old := feeBps
	feeBps = bps
	chain.Emit("FeeBpsChanged", "old", itoa(old), "new", itoa(bps))
}

// SetFeeRecipient re-points the fee/surplus role. The pot accrued under the
// OUTGOING recipient is settled to that recipient's own claimable balance
// first, so the successor inherits the role and not the earnings. Admin
// only; the zero address is rejected.
func SetFeeRecipient(cur realm, next address) {
	rejectStraySend(cur)
	assertAdmin(cur.Previous().Address())
	var zero address
	if next == zero {
		panic("empty fee recipient")
	}
	old := feeRecipient

	// The fee pot is a single scalar — feeledger keeps no per-recipient
	// accounting — so a bare re-point would hand every basis point earned
	// under `old` to `next`, at the admin's sole discretion and with no
	// timelock. That is a privilege the rest of this realm does not grant:
	// the admin role itself is two-step, the fee is capped and snapshotted
	// per schedule, and the funder signs a maxFeeBps ceiling.
	//
	// Settling to `old`'s claimable balance moves F into U by the same
	// amount, so no coins move here and conservation is untouched; `old`
	// then withdraws on their own initiative like any other creditor.
	//
	// Refusing the call while fees are accrued would be the other available
	// fix and is worse: WithdrawFees is recipient-only, so a recipient who
	// simply declined to withdraw could hold the role hostage against the
	// admin indefinitely.
	if old != next && ledger.FeesAccrued() > 0 {
		pot := ledger.WithdrawFees()
		credited, fee, err := ledger.Deposit(old.String(), pot, 0)
		if err != nil {
			panic(err)
		}
		if credited != pot || fee != 0 {
			// Unreachable at 0 bps, where feeledger's credited+fee == amount
			// guarantee forces credited == amount. Asserted because this is
			// the one place the realm moves value between two of its own
			// liability terms, and a silent shortfall here would be a leak.
			panic("internal: fee settlement did not credit the full pot")
		}
		chain.Emit("FeesSettled", "to", old.String(), "amount", itoa(pot))
	}

	feeRecipient = next
	chain.Emit("FeeRecipientChanged", "old", old.String(), "new", next.String())
}

// ProposeAdmin nominates a successor admin. The handover takes effect only
// when that account calls AcceptAdmin, so a typo cannot strand the role.
// Admin only; the zero address clears a pending proposal.
func ProposeAdmin(cur realm, next address) {
	rejectStraySend(cur)
	assertAdmin(cur.Previous().Address())
	pendingAdmin = next
	chain.Emit("AdminProposed", "pending", next.String())
}

// AcceptAdmin completes a handover. Only the proposed account may call it.
func AcceptAdmin(cur realm) {
	rejectStraySend(cur)
	caller := cur.Previous().Address()
	var zero address
	if pendingAdmin == zero || caller != pendingAdmin {
		panic("only the proposed admin may accept")
	}
	old := admin
	admin = caller
	pendingAdmin = zero
	chain.Emit("AdminTransferred", "old", old.String(), "new", admin.String())
}

// --- read-only views ---

// ScheduleInfo returns a schedule's fields by value.
func ScheduleInfo(id int64) (funder, beneficiary address, title string, total, feeBps int64,
	revocable bool, createdAt, numTranches, pending, releasedGross, revokedTotal int64) {
	s := mustSchedule(id)
	return s.funder, s.beneficiary, s.title, s.total, s.feeBps, s.revocable,
		s.createdAt, int64(len(s.trancheIDs)), s.pending, s.releasedGross, s.revokedTotal
}

// Memo returns a schedule's raw memo text.
func Memo(id int64) string { return mustSchedule(id).memo }

// TrancheInfo returns one tranche's fields by value. It answers for settled
// tranches too, after duebook has consumed the deferral.
func TrancheInfo(trancheID int64) (scheduleID, seq, amount, dueAt int64, status string, settledAt int64) {
	t := mustTranche(mustID(trancheID))
	return t.scheduleID, t.seq, t.amount, t.dueAt, t.status, t.settledAt
}

// TranchesOf lists a schedule's tranches, newline-separated, one per line
// as "id seq amount dueAt status".
func TranchesOf(id int64) string {
	s := mustSchedule(id)
	out := ""
	for _, did := range s.trancheIDs {
		t := tranches.Get(padU(did)).(*tranche)
		out += utoa(did) + " " + itoa(t.seq) + " " + itoa(t.amount) + " " +
			itoa(t.dueAt) + " " + t.status + "\n"
	}
	return out
}

// VestedOf returns, for a schedule, the amount whose due height has arrived
// and which is therefore no longer revocable — whether or not it has been
// released yet — alongside the amount still revocable by the funder.
func VestedOf(id int64) (vested, unvested int64) {
	s := mustSchedule(id)
	now := runtime.ChainHeight()
	for _, did := range s.trancheIDs {
		t := tranches.Get(padU(did)).(*tranche)
		if t.status == StatusRevoked {
			continue
		}
		if now >= t.dueAt {
			vested += t.amount
		} else {
			unvested += t.amount
		}
	}
	return vested, unvested
}

// ReleasableNow lists tranche ids that are due and still pending, up to
// MaxListed, newline-separated. Anyone may Release each of them.
func ReleasableNow() string {
	now := runtime.ChainHeight()
	due := book.Due(now, MaxListed)
	out := ""
	for _, d := range due {
		out += utoa(d.ID) + "\n"
	}
	return out
}

// Admin returns the current admin.
func Admin() address { return admin }

// PendingAdmin returns the proposed successor admin, or the zero address.
func PendingAdmin() address { return pendingAdmin }

// FeeRecipient returns who may withdraw fees and sweep surplus.
func FeeRecipient() address { return feeRecipient }

// FeeBps returns the fee that will be snapshotted into newly funded
// schedules. Existing schedules keep their own snapshot.
func FeeBps() int64 { return feeBps }

// FeeOn previews the fee and net credit for a tranche of amount at the
// CURRENT FeeBps.
func FeeOn(amount int64) (fee, credited int64) {
	f, err := feeledger.FeeFor(amount, feeBps)
	if err != nil {
		panic(err)
	}
	return f, amount - f
}

// NumSchedules returns how many schedules have ever been funded.
func NumSchedules() int64 { return nextScheduleID }

// OpenTrancheCount returns how many tranches are pending across the whole
// realm, against the MaxOpenTranches cap.
func OpenTrancheCount() int { return book.OpenCount() }

// OpenTranchesOfFunder returns how many tranches funder currently holds
// pending, against the MaxOpenPerFunder cap. A funder can read this before
// funding to see the headroom they have left.
func OpenTranchesOfFunder(funder address) int64 { return openOf(funder) }

// FundersWithOpenTranches returns how many distinct funders hold at least
// one pending tranche. It is the width of the per-funder cap: exhausting
// MaxOpenTranches requires this to reach ceil(MaxOpenTranches/MaxOpenPerFunder).
func FundersWithOpenTranches() int { return openByFunder.Size() }

// EscrowTotal returns the escrow held by pending tranches (the E term).
func EscrowTotal() int64 { return escrowTotal }

// BalanceOf returns addr's claimable balance (released tranches for a
// beneficiary, revocations for a funder).
func BalanceOf(addr address) int64 { return ledger.BalanceOf(addr.String()) }

// UsersTotal returns the sum of all claimable balances (the U term).
func UsersTotal() int64 { return ledger.UsersTotal() }

// FeesAccrued returns the fee pot (the F term).
func FeesAccrued() int64 { return ledger.FeesAccrued() }

// Liabilities returns everything this realm owes:
// EscrowTotal + UsersTotal + FeesAccrued.
func Liabilities() int64 { return escrowTotal + ledger.Liabilities() }

// Held returns the ugnot actually held at this realm's address (H).
func Held() int64 { return coinio.HeldAt(self, Denom) }

// Surplus returns Held() - Liabilities() (the S term).
func Surplus() int64 { return Held() - Liabilities() }

// Address returns this realm's address (the escrow target).
func Address() address { return self }

// Height returns the current chain height. Delays in Fund's spec are
// relative to the height at which Fund executes, so this is an aid for
// composing a spec, not an input to one.
func Height() int64 { return runtime.ChainHeight() }

// --- render ---

// Render shows the realm at "" and a schedule detail at "<id>". Free text
// (titles are charset-restricted; memos are not) passes through the
// ecosystem sanitizer before it reaches markdown.
func Render(path string) string {
	if path != "" {
		return renderSchedule(path)
	}
	held := Held()
	liab := Liabilities()
	status := "OK"
	if held < liab {
		status = "VIOLATED"
	}
	now := runtime.ChainHeight()

	out := "# Vesting — dated tranche disbursement\n\n"
	out += "Escrowed GNOT released in **discrete, individually dated tranches** — not by "
	out += "linear accrual. A tranche is worth nothing before its due height and its full "
	out += "amount from that height on.\n\n"
	out += "Schedule and exactly-once release via `duebook`; coin custody via `coinio`; "
	out += "accounting via `feeledger`.\n\n"
	out += "## Configuration\n\n"
	out += "- fee for new schedules: " + itoa(feeBps) + " bps (cap " + itoa(MaxFeeBps) +
		" bps; each schedule keeps the fee snapshotted at funding)\n"
	out += "- tranches per schedule: up to " + itoa(MaxTranches) + "\n"
	out += "- pending tranches realm-wide: " + itoa(int64(book.OpenCount())) + " of " +
		itoa(int64(MaxOpenTranches)) + "\n"
	out += "- pending tranches per funder: up to " + itoa(int64(MaxOpenPerFunder)) +
		" (" + itoa(int64(openByFunder.Size())) + " funder(s) hold at least one)\n"
	out += "- delay range: " + itoa(MinDelayBlocks) + " to " + itoa(MaxDelayBlocks) + " blocks\n"
	out += "- fee recipient: " + feeRecipient.String() + "\n"
	out += "- admin: " + admin.String() + "\n"
	out += "- current height: " + itoa(now) + "\n\n"
	out += "## Accounting (H == E + U + F + S)\n\n"
	out += "- escrowed in pending tranches (E): " + itoa(escrowTotal) + Denom + "\n"
	out += "- claimable (U): " + itoa(ledger.UsersTotal()) + Denom + "\n"
	out += "- fees accrued (F): " + itoa(ledger.FeesAccrued()) + Denom + "\n"
	out += "- held (H): " + itoa(held) + Denom + "\n"
	out += "- conservation: " + status + "\n\n"
	out += "## Latest schedules\n\n"
	if nextScheduleID == 0 {
		out += "No schedules yet.\n"
		return out
	}
	shown := 0
	schedules.ReverseIterate("", "", func(_ string, v any) bool {
		s := v.(*schedule)
		kind := "irrevocable"
		if s.revocable {
			kind = "revocable"
		}
		out += "- [#" + itoa(s.id) + "](/r/g1qp5pt8cdq2f6kfdamn3yuxwg6quqnfpyewzz39/vesting:" +
			itoa(s.id) + ") " + s.title + " — " + itoa(s.total) + Denom + " in " +
			itoa(int64(len(s.trancheIDs))) + " tranches (" + itoa(s.pending) + " pending, " +
			kind + ")\n"
		shown++
		return shown >= 20
	})
	return out
}

func renderSchedule(path string) string {
	id, err := strconv.ParseInt(path, 10, 64)
	if err != nil {
		return "> [!WARNING]\n> invalid schedule id\n"
	}
	v := schedules.Get(padID(id))
	if v == nil {
		return "> [!WARNING]\n> unknown schedule id\n"
	}
	s := v.(*schedule)
	now := runtime.ChainHeight()
	vested, unvested := VestedOf(s.id)

	out := "# Schedule #" + itoa(s.id) + ": " + s.title + "\n\n"
	out += "- funder: " + s.funder.String() + "\n"
	out += "- beneficiary: " + s.beneficiary.String() + "\n"
	out += "- total: " + itoa(s.total) + Denom + " in " + itoa(int64(len(s.trancheIDs))) + " tranches\n"
	out += "- fee (snapshot): " + itoa(s.feeBps) + " bps\n"
	if s.revocable {
		out += "- revocable by the funder — but only for tranches that are NOT yet due\n"
	} else {
		out += "- **irrevocable**: the funder cannot reclaim any tranche\n"
	}
	out += "- funded at height: " + itoa(s.createdAt) + " (now " + itoa(now) + ")\n"
	out += "- vested (no longer revocable): " + itoa(vested) + Denom + "\n"
	out += "- unvested (still revocable if revocable): " + itoa(unvested) + Denom + "\n"
	out += "- released so far: " + itoa(s.releasedGross) + Denom +
		"; revoked: " + itoa(s.revokedTotal) + Denom + "\n\n"

	out += "## Tranches\n\n"
	out += "| # | id | amount | due at | status |\n|---|---|---|---|---|\n"
	shown := 0
	for _, did := range s.trancheIDs {
		if shown >= MaxListed {
			out += "| … | | | | (" + itoa(int64(len(s.trancheIDs))-int64(shown)) + " more) |\n"
			break
		}
		t := tranches.Get(padU(did)).(*tranche)
		note := t.status
		if t.status == StatusPending && now >= t.dueAt {
			note = "**releasable now**"
		}
		out += "| " + itoa(t.seq) + " | " + utoa(did) + " | " + itoa(t.amount) + Denom +
			" | " + itoa(t.dueAt) + " | " + note + " |\n"
		shown++
	}
	if s.memo != "" {
		out += "\n## Memo\n\n" + sanitize.InlineText(s.memo) + "\n"
	}
	return out
}

// --- internals ---

func assertAdmin(caller address) {
	if caller != admin {
		panic("admin only")
	}
}

// assertRevocableBy checks both halves of the revocation authority: the
// schedule must have been funded revocable, and the caller must be its
// funder.
func assertRevocableBy(s *schedule, caller address) {
	if !s.revocable {
		panic("schedule " + itoa(s.id) + " is irrevocable")
	}
	if caller != s.funder {
		panic("only the funder may revoke")
	}
}

func mustSchedule(id int64) *schedule {
	v := schedules.Get(padID(id))
	if v == nil {
		panic("unknown schedule id")
	}
	return v.(*schedule)
}

func mustTranche(did uint64) *tranche {
	v := tranches.Get(padU(did))
	if v == nil {
		panic("unknown tranche id")
	}
	return v.(*tranche)
}

// openOf reports how many tranches funder currently holds pending. A
// missing key means zero, which is the same thing: addOpen removes the
// entry when the count reaches zero.
func openOf(funder address) int64 {
	v := openByFunder.Get(funder.String())
	if v == nil {
		return 0
	}
	return v.(int64)
}

// addOpen adjusts funder's pending-tranche count by delta, which may be
// negative. Every increment happens in Fund and every decrement is paired
// with a pending -> terminal transition, so the count tracks exactly the
// tranches openOf claims.
func addOpen(funder address, delta int64) {
	next := openOf(funder) + delta
	if next < 0 {
		// Unreachable: a tranche can only leave StatusPending once, and it
		// was counted when it was created. Kept as a consistency assertion
		// — if it fires, this counter has diverged from the tranche records
		// and the transaction must not proceed.
		panic("internal: funder open-tranche count went negative")
	}
	if next == 0 {
		openByFunder.Remove(funder.String())
		return
	}
	openByFunder.Set(funder.String(), next)
}

// mustID converts an entrypoint's int64 tranche id to duebook's uint64,
// rejecting the non-positive values duebook never issues.
func mustID(id int64) uint64 {
	if id <= 0 {
		panic("tranche id must be positive")
	}
	return uint64(id)
}

// parseSpec parses "delay:amount,delay:amount,…" into parallel slices,
// enforcing every bound before any state is touched. Delays must be
// strictly increasing; amounts must be positive. Nothing here consults or
// mutates realm state, so a malformed spec is rejected with the escrow
// still untouched (the whole transaction aborts regardless).
func parseSpec(spec string) (delays, amounts []int64) {
	if spec == "" {
		panic("spec must list at least one tranche as \"delay:amount\"")
	}
	if len(spec) > MaxSpecLen {
		panic("spec exceeds " + itoa(MaxSpecLen) + " bytes")
	}
	parts := strings.Split(spec, ",")
	if len(parts) > MaxTranches {
		panic("a schedule may have at most " + itoa(MaxTranches) + " tranches, got " +
			itoa(int64(len(parts))))
	}

	prev := int64(-1)
	for i, part := range parts {
		at := strings.Index(part, ":")
		if at < 0 {
			panic("tranche " + itoa(int64(i+1)) + ": expected \"delay:amount\", got \"" + part + "\"")
		}
		delay, err := strconv.ParseInt(part[:at], 10, 64)
		if err != nil {
			panic("tranche " + itoa(int64(i+1)) + ": delay is not an integer")
		}
		amount, err := strconv.ParseInt(part[at+1:], 10, 64)
		if err != nil {
			panic("tranche " + itoa(int64(i+1)) + ": amount is not an integer")
		}
		if delay < MinDelayBlocks || delay > MaxDelayBlocks {
			panic("tranche " + itoa(int64(i+1)) + ": delay " + itoa(delay) +
				" outside [" + itoa(MinDelayBlocks) + ", " + itoa(MaxDelayBlocks) + "]")
		}
		if delay <= prev {
			panic("tranche " + itoa(int64(i+1)) + ": delays must be strictly increasing (" +
				itoa(delay) + " follows " + itoa(prev) + "); combine same-height payments")
		}
		if amount <= 0 {
			panic("tranche " + itoa(int64(i+1)) + ": amount must be positive")
		}
		prev = delay
		delays = append(delays, delay)
		amounts = append(amounts, amount)
	}
	return delays, amounts
}

// assertValidTitle bounds length and restricts the charset so titles are
// list-safe in Render without escaping.
func assertValidTitle(title string) {
	if len(title) == 0 || len(title) > MaxTitleLen {
		panic("title must be 1-" + itoa(MaxTitleLen) + " characters")
	}
	for i := 0; i < len(title); i++ {
		c := title[i]
		switch {
		case c >= 'a' && c <= 'z':
		case c >= 'A' && c <= 'Z':
		case c >= '0' && c <= '9':
		case c == ' ' || c == '_' || c == '-':
		default:
			panic("title may only contain letters, digits, space, _ and -")
		}
	}
}

// padID renders a schedule id as a fixed-width key so avl iteration order
// is numeric order.
func padID(id int64) string {
	s := strconv.FormatInt(id, 10)
	for len(s) < 12 {
		s = "0" + s
	}
	return s
}

// padU renders a deferral id as a fixed-width key. 20 digits covers the
// whole uint64 range, so tranche iteration is numeric order too.
func padU(id uint64) string {
	s := strconv.FormatUint(id, 10)
	for len(s) < 20 {
		s = "0" + s
	}
	return s
}

func itoa(n int64) string { return strconv.FormatInt(n, 10) }

func utoa(n uint64) string { return strconv.FormatUint(n, 10) }

func btoa(b bool) string {
	if b {
		return "true"
	}
	return "false"
}

func checkedAdd(a, b int64) (int64, bool) {
	sum := a + b
	if (b > 0 && sum < a) || (b < 0 && sum > a) {
		return 0, false
	}
	return sum, true
}
