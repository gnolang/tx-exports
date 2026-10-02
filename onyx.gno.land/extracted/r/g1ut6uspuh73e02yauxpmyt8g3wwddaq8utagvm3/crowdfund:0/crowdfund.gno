// Realm crowdfund is permissionless all-or-nothing crowdfunding in GNOT:
// a creator opens a campaign with a funding goal and a block deadline,
// backers pledge real coins that the realm holds, and settlement is
// conditional — if the goal is reached by the deadline the creator may
// collect the pot (minus a bounded success fee), and if it is not, every
// backer reclaims exactly what they pledged, fee-free.
//
// WHY THIS EXISTS (see DISCOVERY.md): at the heights recorded there,
// nothing on onyx-1 holds backer coins against a goal-and-deadline
// condition at all, and the one live crowdfunding realm in the wider
// ecosystem (mainnet r/moul/x/daily/crowdfund, read in full) is
// explicitly accounting-only — its own doc says "No real coin moves".
// The one real-coin implementation found anywhere ran on retired pearl-1
// under a third-party namespace and is unreachable. This realm's delta
// is stated at that size and no larger: it is the assurance-contract
// mechanic — conditional custody with a fee-free refund path — done with
// this portfolio's live-validated custody discipline, not a new idea.
//
// COMPOSITION: coin movement is delegated to coinio, fee arithmetic and
// the fee pot to feeledger, settlement timing and exactly-once
// authorization to duebook, ordered storage to p/nt/avl/v0, and
// free-text render output to the ecosystem sanitizer
// p/nt/markdown/sanitize/v0. This realm owns only the campaign state
// machine and the conservation bookkeeping.
//
// THE SETTLEMENT IS ONE DEFERRAL. Launch schedules exactly one duebook
// deferral per campaign — owner: the creator, due: the deadline, expiry:
// the end of the claim window — and every terminal transition is one of
// the ways that deferral can be consumed:
//
//	CreatorClaim  -> book.Claim   (due, goal met, creator collects)
//	SettleFailed  -> book.Claim   (due, goal UNMET, anyone; duebook
//	                               leaves claim policy to its consumer)
//	CreatorCancel -> book.Cancel  (owner renounces, any time while open)
//	Lapse         -> book.Expire  (anyone, once the claim window is over)
//
// Because duebook consumes a deferral before returning and never reuses
// an ID, a campaign can settle AT MOST ONCE, structurally — double-claim
// is not guarded against, it is unrepresentable. The book's open-
// deferral cap is likewise this realm's cap on open campaigns.
//
// LIFECYCLE (stored state in brackets; "succeeded"/"failed" are derived
// views of an open campaign after its deadline, not stored states):
//
//	Launch (anyone)          : opens [funding]; schedules the deferral.
//	Pledge (backer, +send)   : while height < deadline. Real coins.
//	Unpledge (backer)        : full own pledge back, while height <
//	                           deadline. All-or-nothing holds: nothing
//	                           is locked until the deadline passes.
//	CreatorClaim (creator)   : height in [deadline, claimDeadline),
//	                           raised >= goal -> [paid]. Pays
//	                           raised - fee to the creator, accrues the
//	                           fee. The ONLY transition that charges
//	                           anything.
//	SettleFailed (ANYONE)    : height >= deadline, raised < goal ->
//	                           [failed]. Makes the failure terminal and
//	                           frees the campaign's slots immediately;
//	                           refunds were already open on this path.
//	CreatorCancel (creator)  : while the deferral is open -> [cancelled].
//	                           Refunds open. A creator who cancels after
//	                           succeeding is renouncing the pot.
//	Lapse (ANYONE)           : height >= claimDeadline -> [lapsed].
//	                           Refunds open. The permissionless valve: a
//	                           creator who never collects cannot strand
//	                           backer money, and a dead campaign cannot
//	                           hold its duebook slot forever.
//	Refund (backer)          : own pledge back, fee-free, whenever the
//	                           campaign is [cancelled], [lapsed], or open
//	                           past its deadline with raised < goal.
//	Prune (ANYONE)           : removes a settled, fully-drained campaign
//	                           record. The freed storage deposit is
//	                           refunded by the chain to the CALLER, which
//	                           is the incentive to call it.
//	WithdrawFees (ANYONE)    : pays the accrued fee pot to the
//	                           compile-time FeeCollector. Permissionless
//	                           because the destination is fixed.
//	SweepSurplus (ANYONE)    : out-of-band coins to the FeeCollector,
//	                           never touching tracked liabilities.
//
// REFUNDS NEVER RACE THE CLAIM: while a succeeded campaign is inside its
// claim window, Refund refuses — the pot is the creator's to collect.
// The moment the window ends (Lapse) or the creator renounces (Cancel),
// and at any time after a failed deadline, Refund pays each backer
// exactly their pledge. There is no partial outcome and no fee on any
// refund path, so a backer's worst case is their money back.
//
// THE FEE, precisely: feeBps is snapshotted at Launch from the
// compile-time SuccessFeeBps, so a campaign's terms are fixed when it is
// created and visible in CampaignInfo from that moment. The fee is
// charged ONCE, at CreatorClaim, on the raised amount, with feeledger's
// floor rounding (rounding favors the creator). The ledger is
// constructed with the compile-time MaxFeeBps cap, so a fee above the
// cap is refused by the primitive, not by a check in this file. There is
// no fee on pledges, no fee on refunds, and no fee on failure.
//
// THERE IS NO ADMIN. The fee rate, the fee collector, every bound and
// every window are compile-time constants; no address can change terms,
// pause the realm, or touch a campaign it does not own. The deployer has
// no privilege of any kind after deployment.
//
// MONETARY INVARIANT (conservation): let H be the ugnot held at this
// realm's address, B the sum of raised amounts across all stored
// campaigns (tracked O(1) as totalBacked), F the accrued fee pot, and
// S >= 0 the out-of-band surplus:
//
//	H == B + F + S
//
// Every transition moves value between exactly two terms inside one
// transaction: Pledge raises H and B together (coinio.Receive is the
// receipt-guaranteed shape); Unpledge and Refund debit B before the
// identical amount leaves H (checks-effects-interactions); CreatorClaim
// moves one campaign's raised out of B, splits it into a creator payout
// (leaves H) and a fee (enters F); WithdrawFees debits F before the
// payout; any panic aborts the whole transaction; this realm never
// issues or removes coins.
//
// ONLY GNOT IS ACCEPTED: Pledge rejects any envelope that is not exactly
// one positive ugnot coin (coinio.Receive). Every other entrypoint
// rejects attached coins outright rather than converting them into
// sweepable surplus.
//
// AUTHORIZATION: every identity is derived from the crossing
// entrypoint's cur.Previous().Address(). No function takes a caller
// identity as a parameter, so pledging as another backer, claiming
// another creator's campaign, or refunding another backer's pledge is
// impossible by construction.
//
// STORAGE: a backer's pledge entry is paid for by the backer's own
// transaction deposit; a campaign record by the creator's. CreatorClaim
// drops the whole pledge table in one assignment, and Prune removes the
// settled record — both free storage, and the chain refunds freed
// deposits to the transaction that frees them.
package crowdfund

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
const RealmPath = "/r/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/crowdfund"

// Denom is the only asset this realm holds.
const Denom = "ugnot"

// MaxFeeBps is the hard ceiling on any success fee this realm could ever
// charge, enforced by the feeledger the realm is constructed with — a
// feeBps above it is refused by the primitive's own validation, not by a
// check in this file. 500 bps = 5%.
const MaxFeeBps = int64(500)

// SuccessFeeBps is the fee actually snapshotted into every campaign at
// Launch: 100 bps = 1%, charged once, on CreatorClaim, on the raised
// amount, floor-rounded in the creator's favor. fee_split precedent:
// the most conservative live fee in this portfolio is also 1%.
const SuccessFeeBps = int64(100)

// FeeCollector receives withdrawn fees and swept surplus. Compile-time
// constant: there is no setter and no transfer path. It is the deploying
// namespace's address — stated plainly: the operator of this realm.
const FeeCollector = address("g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3")

// MinGoal keeps dust campaigns out: 1 GNOT.
const MinGoal = int64(1_000_000)

// MinPledge bounds pledge-table growth per GNOT of hostile capital
// (audit open question 1): at 0.01 GNOT per entry, bloating one
// campaign's table to even 10,000 entries costs 100 refundable-but-
// locked GNOT plus gas. Honest micro-backing survives: 0.01 GNOT is
// two orders of magnitude below MinGoal.
const MinPledge = int64(10_000)

// MinDurationBlocks and MaxDurationBlocks bound a campaign's funding
// period, enforced structurally: they are the duebook's minDelay and
// maxDelay, so an out-of-range duration is refused by the primitive.
// At onyx-1's roughly 3-5s blocks, ~1,200 blocks is on the order of an
// hour or two, and ~1,300,000 blocks is on the order of 45-75 days.
const (
	MinDurationBlocks = int64(1_200)
	MaxDurationBlocks = int64(1_300_000)
)

// ClaimWindowBlocks is how long after the deadline a successful creator
// may collect before the campaign becomes permissionlessly lapsable and
// the pot refundable. It is every campaign's deferral ttl.
const ClaimWindowBlocks = int64(650_000)

// MaxOpenCampaigns caps simultaneously unsettled campaigns, via the
// duebook's own open-deferral cap. The AVAILABILITY BOUND this implies
// is documented rather than hidden: Launch is permissionless, so the
// cap is exhaustible in principle. What each unsettled slot costs an
// attacker is the mitigation — a failed campaign is permissionlessly
// settleable (SettleFailed) the moment its deadline passes, so holding
// a slot past its deadline requires MEETING THE GOAL, i.e. locking at
// least MinGoal of real capital per slot for the claim window. Filling
// the whole table therefore costs >= 1,024 GNOT locked for ~a month
// per cycle, against a realm whose existing campaigns keep working
// regardless. Accepted for a testnet deployment and recorded in the
// deployment record (audit finding Y1).
const MaxOpenCampaigns = 1024

// MaxOpenPerCreator bounds how much of the global cap one creator can
// occupy (permission_registry R1 precedent: an uncapped per-principal
// count lets one key monopolize a shared bound).
const MaxOpenPerCreator = int64(8)

// Input bounds. Both fields are free text and are sanitized before
// reaching markdown.
const (
	MaxTitleLen = 100
	MaxMemoLen  = 256
)

// MaxRenderRows bounds the campaign list on the index page.
const MaxRenderRows = 20

// Campaign states. statePaid, stateFailed, stateCancelled and
// stateLapsed are terminal: the campaign's deferral has been consumed
// and can never be consumed again.
const (
	stateFunding   = "funding"
	statePaid      = "paid"
	stateFailed    = "failed"
	stateCancelled = "cancelled"
	stateLapsed    = "lapsed"
)

type campaign struct {
	id        int64
	creator   address
	title     string
	memo      string
	goal      int64
	feeBps    int64 // snapshotted at Launch
	createdAt int64
	deadline  int64 // createdAt + duration; pledging while height < deadline
	claimEnd  int64 // deadline + ClaimWindowBlocks; == deferral ExpiresAt
	defID     uint64
	state     string

	raised  int64     // coins currently held for this campaign
	pledges *avl.Tree // backer address string -> int64 (> 0); nil after payout
	backers int       // final count, frozen when pledges is dropped
}

var (
	self address

	campaigns = avl.NewTree() // padID(id) -> *campaign
	nextID    int64

	// openByCreator tracks each creator's unsettled campaigns:
	// address string -> int64 count (> 0).
	openByCreator = avl.NewTree()

	// totalBacked is the B term of H == B + F + S: the sum of raised
	// across all stored campaigns, maintained O(1) at every transition.
	totalBacked int64

	// lifetime counters, rendered for operators.
	lifetimePledged  int64
	lifetimePaidOut  int64 // creator payouts, net of fee
	lifetimeReturned int64 // unpledges + refunds

	// ledger provides the fee arithmetic, the fee cap, and the fee pot.
	// Its user-balance side is used only transiently inside
	// CreatorClaim, so UsersTotal() is 0 between transactions.
	ledger = feeledger.MustNew(MaxFeeBps)

	// book holds one open deferral per unsettled campaign. The bounds
	// are the primitive's own validation: a duration outside
	// [MinDurationBlocks, MaxDurationBlocks] is refused by Schedule.
	book = duebook.MustNew(MinDurationBlocks, MaxDurationBlocks, MaxOpenCampaigns)
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
// deliberately fails open (treasury_board documents the same scope).
func rejectStraySend(cur realm) {
	if !cur.IsCurrent() {
		// Every call site forwards a crossing entrypoint's own live cur,
		// so this cannot fire today; it exists so a future refactor that
		// hands this guard a stale realm value fails closed, not open
		// (coinio names IsCurrent as the guard secondary realm
		// parameters require, and this helper follows that discipline).
		panic("crowdfund: realm capability is not current")
	}
	if cur.Previous().IsUserCall() && len(unsafe.OriginSend()) > 0 {
		panic("this entrypoint does not accept coins")
	}
}

// --- campaign lifecycle ---

// Launch opens a campaign and returns its id. Anyone may launch; the
// caller becomes the creator. The fee terms (SuccessFeeBps at this
// moment — a compile-time constant, so always SuccessFeeBps) are
// snapshotted into the campaign and are fixed from here on. The funding
// duration is given in blocks and must be within
// [MinDurationBlocks, MaxDurationBlocks] — enforced by the duebook.
func Launch(cur realm, title, memo string, goal, durationBlocks int64) int64 {
	rejectStraySend(cur)
	creator := cur.Previous().Address()

	if title == "" {
		panic("title must not be empty")
	}
	if len(title) > MaxTitleLen {
		panic("title exceeds " + strconv.Itoa(MaxTitleLen) + " bytes")
	}
	if len(memo) > MaxMemoLen {
		panic("memo exceeds " + strconv.Itoa(MaxMemoLen) + " bytes")
	}
	if goal < MinGoal {
		panic("goal must be at least " + itoa(MinGoal) + Denom)
	}
	key := creator.String()
	if creatorOpen(key) >= MaxOpenPerCreator {
		panic("creator already has " + itoa(MaxOpenPerCreator) + " unsettled campaigns")
	}

	now := runtime.ChainHeight()
	id := nextID + 1

	// The deferral is the settlement authorization: due at the deadline,
	// expiring when the claim window closes. Duration bounds and the
	// global open-campaign cap are enforced here by the primitive.
	defID := book.MustSchedule(key, itoa(id), now, durationBlocks, ClaimWindowBlocks)

	c := &campaign{
		id:        id,
		creator:   creator,
		title:     title,
		memo:      memo,
		goal:      goal,
		feeBps:    SuccessFeeBps,
		createdAt: now,
		deadline:  now + durationBlocks,
		claimEnd:  now + durationBlocks + ClaimWindowBlocks,
		defID:     defID,
		state:     stateFunding,
		pledges:   avl.NewTree(),
	}
	nextID = id
	campaigns.Set(padID(id), c)
	setCreatorOpen(key, creatorOpen(key)+1)

	chain.Emit("Launched", "id", itoa(id), "creator", key,
		"goal", itoa(goal), "deadline", itoa(c.deadline),
		"feeBps", itoa(c.feeBps))
	return id
}

// Pledge backs a campaign with the attached coins. Direct EOA calls
// with -send only (the receipt-guaranteed shape); exactly one positive
// ugnot coin. Open while height < deadline.
func Pledge(cur realm, id int64) {
	backer, amount := coinio.Receive(0, cur, Denom)
	c := mustGet(id)
	if c.state != stateFunding {
		panic("campaign is settled")
	}
	if runtime.ChainHeight() >= c.deadline {
		panic("funding is closed")
	}
	if amount < MinPledge {
		panic("pledge at least " + itoa(MinPledge) + Denom)
	}

	key := backer.String()
	newPledge, ok := checkedAdd(pledgeOf(c, key), amount)
	if !ok {
		panic("pledge would overflow")
	}
	newRaised, ok := checkedAdd(c.raised, amount)
	if !ok {
		panic("raised would overflow")
	}
	newBacked, ok := checkedAdd(totalBacked, amount)
	if !ok {
		panic("total backed would overflow")
	}
	newLifetime, ok := checkedAdd(lifetimePledged, amount)
	if !ok {
		panic("lifetime pledged would overflow")
	}

	c.pledges.Set(key, newPledge)
	c.raised = newRaised
	totalBacked = newBacked
	lifetimePledged = newLifetime

	chain.Emit("Pledged", "id", itoa(c.id), "backer", key,
		"amount", itoa(amount), "raised", itoa(c.raised))
}

// Unpledge returns the caller's entire pledge while funding is still
// open. All-or-nothing means nothing is committed before the deadline,
// so backing out is always whole and always free.
func Unpledge(cur realm, id int64) {
	rejectStraySend(cur)
	caller := cur.Previous().Address()
	c := mustGet(id)
	if c.state != stateFunding {
		panic("campaign is settled")
	}
	if runtime.ChainHeight() >= c.deadline {
		panic("funding is closed; use Refund if the campaign failed")
	}
	payBack(cur, c, caller, "Unpledged")
}

// CreatorClaim collects a successful campaign: creator only, from the
// deadline until the claim window closes, and only with the goal
// reached. Pays raised minus the snapshotted fee to the creator and
// accrues the fee. The duebook Claim consumes the campaign's deferral,
// so this can succeed at most once per campaign, ever.
func CreatorClaim(cur realm, id int64) {
	rejectStraySend(cur)
	caller := cur.Previous().Address()
	c := mustGet(id)
	if caller != c.creator {
		panic("creator only")
	}
	if c.state != stateFunding {
		panic("campaign is settled")
	}
	if c.raised < c.goal {
		panic("goal not reached")
	}

	// Timing (not due / expired) is the primitive's verdict; its error
	// names the reason. A success consumes the deferral before returning.
	d := book.MustClaim(c.defID, runtime.ChainHeight())
	if d.Owner != c.creator.String() {
		// Unreachable by construction (the deferral was scheduled with
		// this campaign's creator as owner); checked because the payout
		// below is irreversible.
		panic("settlement owner mismatch")
	}

	amount := c.raised
	credited, fee := ledger.MustDeposit(c.creator.String(), amount, c.feeBps)
	ledger.MustWithdraw(c.creator.String(), credited)

	// Debit the campaign before the coins move.
	c.raised = 0
	totalBacked -= amount
	c.backers = c.pledges.Size()
	c.pledges = nil // drop the whole table; entitlements are settled
	c.state = statePaid
	decCreatorOpen(c.creator.String())
	newPaid, ok := checkedAdd(lifetimePaidOut, credited)
	if !ok {
		panic("lifetime paid would overflow")
	}
	lifetimePaidOut = newPaid

	coinio.Payout(0, cur, c.creator, Denom, credited)

	chain.Emit("Claimed", "id", itoa(c.id), "creator", c.creator.String(),
		"amount", itoa(credited), "fee", itoa(fee))
}

// CreatorCancel settles the caller's own campaign as cancelled and opens
// refunds. Permitted at any time while the settlement deferral is open —
// during funding, and equally after a successful deadline (renouncing
// the pot). The duebook Cancel is owner-gated and consumes the deferral.
func CreatorCancel(cur realm, id int64) {
	rejectStraySend(cur)
	caller := cur.Previous().Address()
	c := mustGet(id)
	if caller != c.creator {
		panic("creator only")
	}
	if c.state != stateFunding {
		panic("campaign is settled")
	}

	book.MustCancel(c.defID, caller.String())
	c.state = stateCancelled
	decCreatorOpen(c.creator.String())

	chain.Emit("Cancelled", "id", itoa(c.id), "creator", c.creator.String(),
		"raised", itoa(c.raised))
}

// SettleFailed settles a campaign that reached its deadline with the
// goal unmet. Anyone may call it — there is nothing to steer: refunds
// were already open on this path, so the only effects are making the
// failure terminal and freeing the campaign's duebook slot (and its
// creator's cap slot) immediately instead of at the end of the claim
// window. This is what makes slot-squatting with unfunded campaigns
// pointless: holding a slot past the deadline requires meeting the
// goal, i.e. real locked capital.
//
// The deferral is consumed with the duebook's Claim under this realm's
// policy (goal unmet), which the primitive explicitly leaves to its
// consumer; the timing verdict (not due before the deadline) is the
// primitive's own.
func SettleFailed(cur realm, id int64) {
	rejectStraySend(cur)
	c := mustGet(id)
	if c.state != stateFunding {
		panic("campaign is settled")
	}
	if c.raised >= c.goal {
		panic("goal reached; the claim window is the creator's")
	}

	book.MustClaim(c.defID, runtime.ChainHeight())
	c.state = stateFailed
	decCreatorOpen(c.creator.String())

	chain.Emit("Failed", "id", itoa(c.id), "by",
		cur.Previous().Address().String(), "raised", itoa(c.raised))
}

// Lapse settles a campaign whose claim window has closed. Anyone may
// call it — a lapsed campaign's pot belongs to its backers, and the
// caller is doing them (and the duebook's open-slot budget) a service.
// The duebook Expire refuses while the window is still open.
func Lapse(cur realm, id int64) {
	rejectStraySend(cur)
	c := mustGet(id)
	if c.state != stateFunding {
		panic("campaign is settled")
	}

	book.MustExpire(c.defID, runtime.ChainHeight())
	c.state = stateLapsed
	decCreatorOpen(c.creator.String())

	chain.Emit("Lapsed", "id", itoa(c.id), "by",
		cur.Previous().Address().String(), "raised", itoa(c.raised))
}

// Refund returns the caller's entire pledge from a campaign that will
// never pay its creator: cancelled, lapsed, or past its deadline with
// the goal unmet. Always whole, always fee-free. While a succeeded
// campaign is inside its claim window the pot is the creator's to
// collect, so Refund refuses — if the creator never collects, Lapse
// reopens this path.
func Refund(cur realm, id int64) {
	rejectStraySend(cur)
	caller := cur.Previous().Address()
	c := mustGet(id)
	if !refundable(c, runtime.ChainHeight()) {
		panic("campaign is not refundable")
	}
	payBack(cur, c, caller, "Refunded")
}

// Prune removes a settled campaign record that holds no coins,
// reclaiming its storage. Anyone may call it: the chain refunds the
// freed storage deposit to the pruning transaction, which is the
// incentive. A record with raised > 0 still carries backer entitlements
// and is not prunable.
func Prune(cur realm, id int64) {
	rejectStraySend(cur)
	c := mustGet(id)
	if c.state == stateFunding {
		panic("campaign is not settled")
	}
	if c.raised != 0 {
		panic("campaign still holds backer funds")
	}
	campaigns.Remove(padID(c.id))
	chain.Emit("Pruned", "id", itoa(c.id), "by",
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
// the full balance. Tracked backer money and the fee pot are
// untouchable by construction (coinio.Sweep refuses to dip below the
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

// CampaignInfo returns a campaign's fixed terms and live tallies.
func CampaignInfo(id int64) (creator address, goal, raised, feeBps,
	createdAt, deadline, claimEnd int64, backers int, state string) {
	c := mustGet(id)
	return c.creator, c.goal, c.raised, c.feeBps,
		c.createdAt, c.deadline, c.claimEnd, backerCount(c), c.state
}

// CampaignTitle returns a campaign's raw title (unsanitized: callers
// rendering it into markdown must sanitize, as this realm's Render does).
func CampaignTitle(id int64) string { return mustGet(id).title }

// CampaignMemo returns a campaign's raw memo (same caveat as the title).
func CampaignMemo(id int64) string { return mustGet(id).memo }

// Status returns the human verdict for a campaign right now: "funding",
// "succeeded (awaiting creator claim)", "failed (refunds open)",
// "paid", "cancelled", or "lapsed".
func Status(id int64) string { return status(mustGet(id), runtime.ChainHeight()) }

// PledgeOf returns addr's live pledge in a campaign (0 if none, and 0
// for settled campaigns whose pledge table has been dropped).
func PledgeOf(id int64, addr address) int64 {
	c := mustGet(id)
	if c.pledges == nil {
		return 0
	}
	return pledgeOf(c, addr.String())
}

// IsRefundable reports whether Refund would currently accept this
// campaign (for any backer with a live pledge).
func IsRefundable(id int64) bool {
	return refundable(mustGet(id), runtime.ChainHeight())
}

// NumCampaigns returns how many campaigns have ever been launched.
// Prune removes records but never reuses ids.
func NumCampaigns() int64 { return nextID }

// OpenCampaigns returns how many campaigns are currently unsettled.
func OpenCampaigns() int64 { return int64(book.OpenCount()) }

// OpenOf returns how many unsettled campaigns addr currently has.
func OpenOf(addr address) int64 { return creatorOpen(addr.String()) }

// TotalBacked returns the B term: coins held for campaigns.
func TotalBacked() int64 { return totalBacked }

// FeesAccrued returns the F term: charged, not yet withdrawn.
func FeesAccrued() int64 { return ledger.FeesAccrued() }

// Liabilities returns B + F — everything this realm owes.
func Liabilities() int64 { return totalBacked + ledger.Liabilities() }

// Held returns H: the ugnot actually at this realm's address.
func Held() int64 { return coinio.HeldAt(self, Denom) }

// Surplus returns H - (B + F) — out-of-band coins, sweepable.
func Surplus() int64 { return Held() - Liabilities() }

// Address returns this realm's own address.
func Address() address { return self }

// Height returns the current chain height, the clock every deadline is
// measured against.
func Height() int64 { return runtime.ChainHeight() }

// --- render ---

// Render shows the realm at "" and a campaign page at "<id>". Titles
// and memos are free text and pass through the ecosystem sanitizer
// before hitting markdown.
func Render(path string) string {
	if path != "" {
		return renderCampaign(path)
	}
	now := runtime.ChainHeight()
	held := Held()
	liab := Liabilities()
	conservation := "OK"
	if held < liab {
		conservation = "VIOLATED"
	}
	out := "# Crowdfund\n\n"
	out += "All-or-nothing crowdfunding in GNOT: hit the goal by the deadline " +
		"and the creator collects (minus a " + bps(SuccessFeeBps) +
		" success fee); miss it and every backer reclaims exactly what they " +
		"pledged, fee-free.\n\n"
	out += "## Terms (fixed at deploy; no admin, no setters)\n\n"
	out += "- success fee: " + bps(SuccessFeeBps) + " of raised, charged only on a successful claim (hard cap " + bps(MaxFeeBps) + ")\n"
	out += "- refunds and unpledges: always whole, always fee-free\n"
	out += "- goal: at least " + itoa(MinGoal) + Denom + "\n"
	out += "- funding duration: " + itoa(MinDurationBlocks) + " to " + itoa(MaxDurationBlocks) + " blocks\n"
	out += "- claim window after deadline: " + itoa(ClaimWindowBlocks) + " blocks, then anyone may Lapse\n"
	out += "- open campaigns: " + itoa(OpenCampaigns()) + " of " + strconv.Itoa(MaxOpenCampaigns) +
		" (per creator: " + itoa(MaxOpenPerCreator) + ")\n"
	out += "- current height: " + itoa(now) + "\n\n"
	out += "## Accounting (H == B + F + S)\n\n"
	out += "- backed (B): " + itoa(totalBacked) + Denom + "\n"
	out += "- fee pot (F): " + itoa(ledger.FeesAccrued()) + Denom + "\n"
	out += "- held (H): " + itoa(held) + Denom + "\n"
	out += "- surplus (S): " + itoa(held-liab) + Denom + "\n"
	out += "- conservation: " + conservation + "\n"
	out += "- lifetime pledged / paid out / returned: " + itoa(lifetimePledged) +
		" / " + itoa(lifetimePaidOut) + " / " + itoa(lifetimeReturned) + Denom + "\n\n"
	out += "## Latest campaigns\n\n"
	if campaigns.Size() == 0 {
		out += "None yet. Launch one.\n"
	} else {
		shown := 0
		campaigns.ReverseIterate("", "", func(_ string, v any) bool {
			c := v.(*campaign)
			out += "- [#" + itoa(c.id) + "](" + RealmPath + ":" + itoa(c.id) + ") [" +
				status(c, now) + "] " + sanitize.InlineText(c.title) + " — " +
				itoa(c.raised) + " / " + itoa(c.goal) + Denom + "\n"
			shown++
			return shown >= MaxRenderRows
		})
		if int64(shown) < nextID {
			out += "\n> [!NOTE]\n> Showing the " + strconv.Itoa(shown) +
				" most recent of " + itoa(nextID) +
				" ever launched (settled records may have been pruned). " +
				"Use CampaignInfo(id) for any specific campaign.\n"
		}
	}
	due := book.Due(now, 5)
	lapsable := book.Expirable(now, 5)
	if len(due) > 0 || len(lapsable) > 0 {
		out += "\n## Keeper work\n\n"
	}
	if len(due) > 0 {
		out += "Settlements due — the creator may CreatorClaim(id) if the " +
			"goal is met; anyone may SettleFailed(id) if it is not:\n\n"
		for _, d := range due {
			out += "- campaign #" + sanitize.InlineText(d.Payload) + "\n"
		}
	}
	if len(lapsable) > 0 {
		out += "Settlements past their claim window — anyone may call Lapse(id) " +
			"to open refunds:\n\n"
		for _, d := range lapsable {
			out += "- campaign #" + sanitize.InlineText(d.Payload) + "\n"
		}
	}
	return out
}

func renderCampaign(path string) string {
	id, err := strconv.ParseInt(path, 10, 64)
	if err != nil {
		return "> [!WARNING]\n> invalid campaign id\n"
	}
	v := campaigns.Get(padID(id))
	if v == nil {
		return "> [!WARNING]\n> unknown campaign id (never launched, or settled and pruned)\n"
	}
	c := v.(*campaign)
	now := runtime.ChainHeight()

	out := "# #" + itoa(c.id) + ": " + sanitize.InlineText(c.title) + "\n\n"
	out += "- status: **" + status(c, now) + "**\n"
	out += "- creator: `" + c.creator.String() + "`\n"
	out += "- raised: " + itoa(c.raised) + " / " + itoa(c.goal) + Denom +
		" (" + percent(c.raised, c.goal) + ")\n"
	out += "- backers: " + strconv.Itoa(backerCount(c)) + "\n"
	out += "- success fee: " + bps(c.feeBps) + " (snapshotted at launch)\n"
	out += "- created at block: " + itoa(c.createdAt) + "\n"
	out += "- deadline: block " + itoa(c.deadline) + "\n"
	out += "- claim window closes: block " + itoa(c.claimEnd) + "\n"
	out += "- current height: " + itoa(now) + "\n\n"
	switch {
	case c.state == stateFunding && now < c.deadline:
		out += "Pledge(" + itoa(c.id) + ") with -send to back it; " +
			"Unpledge(" + itoa(c.id) + ") to back out. " +
			itoa(c.deadline-now) + " blocks remain.\n"
	case c.state == stateFunding && c.raised >= c.goal && now < c.claimEnd:
		out += "**Goal reached.** The creator may CreatorClaim(" + itoa(c.id) +
			") until block " + itoa(c.claimEnd) + ".\n"
	case c.state == stateFunding && c.raised >= c.goal:
		out += "**Claim window over.** Anyone may Lapse(" + itoa(c.id) +
			") to open refunds.\n"
	case c.state == stateFunding && now < c.claimEnd:
		out += "**Goal not reached.** Backers may Refund(" + itoa(c.id) +
			"); anyone may SettleFailed(" + itoa(c.id) +
			") to close it out.\n"
	case c.state == stateFunding:
		// Past the claim window the deferral is expired, so the failed
		// path closes via Lapse, not SettleFailed (audit G1).
		out += "**Goal not reached.** Backers may Refund(" + itoa(c.id) +
			"); anyone may Lapse(" + itoa(c.id) + ") to close it out.\n"
	case c.raised > 0:
		out += "Backers may Refund(" + itoa(c.id) + ").\n"
	default:
		out += "Fully settled. Anyone may Prune(" + itoa(c.id) +
			") to reclaim the record's storage.\n"
	}
	if c.memo != "" {
		out += "\n## About\n\n" + sanitize.InlineText(c.memo) + "\n"
	}
	return out
}

// --- internals ---

func mustGet(id int64) *campaign {
	v := campaigns.Get(padID(id))
	if v == nil {
		panic("unknown campaign id")
	}
	return v.(*campaign)
}

// payBack is the shared whole-pledge return path for Unpledge and
// Refund: debit the backer's entry and the campaign before the
// identical amount leaves the realm.
func payBack(cur realm, c *campaign, backer address, event string) {
	key := backer.String()
	amount := pledgeOf(c, key)
	if amount == 0 {
		panic("no pledge to return")
	}
	c.pledges.Remove(key)
	c.raised -= amount
	totalBacked -= amount
	newReturned, ok := checkedAdd(lifetimeReturned, amount)
	if !ok {
		panic("lifetime returned would overflow")
	}
	lifetimeReturned = newReturned

	coinio.Payout(0, cur, backer, Denom, amount)

	chain.Emit(event, "id", itoa(c.id), "backer", key,
		"amount", itoa(amount), "raised", itoa(c.raised))
}

// refundable: failed, cancelled and lapsed campaigns always; an
// unsettled campaign once its deadline has passed with the goal unmet.
// A succeeded campaign inside its claim window is NOT refundable — the
// pot is the creator's to collect until Cancel or Lapse says otherwise.
func refundable(c *campaign, now int64) bool {
	switch c.state {
	case stateFailed, stateCancelled, stateLapsed:
		return true
	case stateFunding:
		return now >= c.deadline && c.raised < c.goal
	default:
		return false
	}
}

func status(c *campaign, now int64) string {
	if c.state != stateFunding {
		return c.state
	}
	switch {
	case now < c.deadline:
		return stateFunding
	case c.raised >= c.goal:
		return "succeeded (awaiting creator claim)"
	default:
		return "failed (refunds open)"
	}
}

func pledgeOf(c *campaign, key string) int64 {
	v := c.pledges.Get(key)
	if v == nil {
		return 0
	}
	return v.(int64)
}

func backerCount(c *campaign) int {
	if c.pledges == nil {
		return c.backers
	}
	return c.pledges.Size()
}

func creatorOpen(key string) int64 {
	v := openByCreator.Get(key)
	if v == nil {
		return 0
	}
	return v.(int64)
}

func setCreatorOpen(key string, n int64) {
	if n <= 0 {
		openByCreator.Remove(key)
		return
	}
	openByCreator.Set(key, n)
}

func decCreatorOpen(key string) { setCreatorOpen(key, creatorOpen(key)-1) }

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

// percent renders raised/goal as an integer percentage (floor).
// goal >= MinGoal > 0 by construction, so no divide guard is needed.
func percent(raised, goal int64) string {
	q := raised / goal
	r := raised % goal
	var p int64
	if r <= (int64(1)<<62)/100 {
		p = q*100 + r*100/goal
	} else {
		// goal (> r) is so large that r*100 would overflow; the scaled
		// form loses at most a rounding step, which is cosmetic here.
		p = q*100 + r/(goal/100)
	}
	return itoa(p) + "%"
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
