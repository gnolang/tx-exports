// Realm bounty_panel is a public bounty board whose resolution
// authority is separated from its funding authority.
//
// A funder escrows GNOT behind a bounty and, AT CREATION, names a panel
// of resolvers and an M-of-N threshold. Contributors submit work
// on-chain during a submission window. After that window closes the
// panel votes on the competing submissions, and the first submission to
// reach M votes wins the escrow. Neither the panel nor the threshold can
// change after creation.
//
// WHY THIS EXISTS (see DISCOVERY.md): the sibling realm `grants` already
// implements escrowed rewards, on-chain submissions, restricted award
// and a permissionless refund valve — but there the resolver IS the
// funder. On a public bounty with open submissions that is the wrong
// trust model: the deciding party has a financial interest in the
// outcome and sees every submission before deciding. This realm exists
// for exactly that delta and reuses everything else.
//
// COMPOSITION: all balance accounting is delegated to feeledger, all
// coin movement to coinio, and all free-text render output to the
// ecosystem sanitizer p/nt/markdown/sanitize/v0. This realm owns only
// the bounty state machine: bounty records, panels, submissions, votes,
// open-escrow total, deadlines, and roles.
//
// LIFECYCLE (terminal states are frozen; one transition per bounty):
//
//	CreateBounty (EOA + -send)  : escrow -> openTotal, status Open;
//	                              panel + threshold + fee bps all
//	                              SNAPSHOTTED at creation
//	Submit (also re-submit)     : while Open and height <
//	                              submitDeadline; keyed by the caller's
//	                              own address; funder and panel barred
//	Vote (panel only)           : while Open and submitDeadline <=
//	                              height < resolveDeadline; one live
//	                              vote per resolver, changeable until
//	                              the threshold is reached; the Mth vote
//	                              for a submission awards the bounty
//	                              ATOMICALLY (Open -> Awarded)
//	CancelBounty (funder only)  : Open -> Cancelled, fee-free refund —
//	                              ONLY while no submission exists
//	ExpireBounty (ANYONE)       : Open -> Expired once height >=
//	                              resolveDeadline + ExpiryGraceBlocks;
//	                              fee-free refund to the funder — the
//	                              permissionless valve against a panel
//	                              that never resolves (but see THE ONE
//	                              CAVEAT below)
//	Claim / ClaimAll (anyone)   : pays out the caller's own ledger
//	                              balance (winnings and refunds)
//	WithdrawFees (fee recipient): pays out the fee pot
//
// WHY THE WINDOWS DO NOT OVERLAP: submissions close at submitDeadline
// and voting opens at the same height. A resolver therefore votes only
// on content that can no longer change, which removes the bait-and-
// switch where a submission collects votes and is then edited. It also
// means no submission can be added in response to the votes already
// cast.
//
// THE ONE CAVEAT ON THE EXPIRY VALVE, stated rather than glossed: both
// ways out of an Open bounty — award and refund — credit the shared
// feeledger, so both fail while that ledger is saturated at the int64
// boundary, and the escrow is temporarily immovable in BOTH directions
// until some account claims down. Nothing is lost and the valve works
// again as soon as the ledger has headroom (this is exercised in
// TestSaturatedAwardCannotTrapFunds). The state requires liabilities
// within ~50 of 2^63-1 ugnot, which exceeds the real GNOT supply by
// orders of magnitude and is unreachable absent a chain-level minting
// bug, since every credit is backed by an escrowed -send. So: the
// valve makes fund-trapping impossible under any reachable condition,
// which is a weaker claim than "impossible" and is the true one.
//
// WHY CANCEL IS RESTRICTED: in `grants` the creator may cancel at any
// time while open. Here, once a single contributor has submitted work,
// the funder can no longer unilaterally reclaim the escrow — only the
// panel (by awarding) or the expiry valve (after the resolution window)
// can end the bounty. This is the concrete anti-harvest guarantee that
// a public bounty needs and a grant programme does not.
//
// AUTHORIZATION: every identity is derived from the crossing
// entrypoint's cur.Previous().Address() — no function takes a caller
// identity as a parameter. Submissions, votes and claimable balances
// are keyed by that runtime-derived address, so altering another user's
// submission, casting another resolver's vote, or claiming another
// user's winnings is impossible by construction.
//
// PANEL INTEGRITY, fixed at creation and immutable thereafter: the
// panel is non-empty, free of duplicates, every member is a valid
// bech32 address, and 1 <= threshold <= panelSize. Panel members may
// not submit work, so a resolver cannot vote for their own submission.
// The funder MAY be a panel member — barring them would be
// unenforceable theatre (a funder can always name an address they
// control), and the panel is public on-chain from creation, so a
// self-resolved bounty is visible to contributors BEFORE they spend
// effort. Disclosure beats a prohibition that cannot be enforced.
//
// FEE MODEL: fee = floor(amount * bps / 10000), rounding favors the
// winner; no minimum fee; bps snapshotted into the bounty at creation,
// so SetFeeBps affects future bounties only (closes the award-time
// admin race), and CreateBounty takes the caller's own maxFeeBps
// ceiling, rejecting creation if the live fee exceeds what the funder
// signed for (closes the creation-time race); hard compile-time cap
// MaxFeeBps (10%); refunds (cancel/expire) are always fee-free.
//
// MONETARY INVARIANT (conservation): let H be ugnot held at this
// realm's address, B = openTotal (Σ amount over Open bounties), U the
// ledger's claimable balances, F the fee pot, S >= 0 out-of-band
// surplus:
//
//	H == B + U + F + S
//
// Every transition moves value between exactly two terms inside one
// transaction: CreateBounty raises H and B together (coinio.Receive is
// the receipt-guaranteed shape); award/cancel/expire move amount from B
// into U+F with feeledger guaranteeing credited + fee == amount; claims
// and fee withdrawal debit the ledger before coinio.Payout moves the
// identical amount out (checks-effects-interactions); any panic aborts
// the whole transaction; this realm never issues or removes coins.
// Surplus is recoverable only via SweepDenom (fee recipient), which
// reserves Liabilities() = B + U + F.
//
// ONLY GNOT: CreateBounty rejects any envelope that is not exactly one
// positive ugnot coin (coinio.Receive). Every other entrypoint rejects
// attached coins outright rather than converting them to sweepable
// surplus.
package bounty_panel

import (
	"chain"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"strings"

	"gno.land/p/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/coinio"
	"gno.land/p/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/feeledger"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/markdown/sanitize/v0"
)

// RealmPath is this realm's own path, used to build Render links.
const RealmPath = "/r/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/bounty_panel"

// Denom is the only asset this realm accepts.
const Denom = "ugnot"

// MaxFeeBps is the hard protocol-fee cap: 1000 bps = 10%.
const MaxFeeBps = int64(1000)

// Bounty status values.
const (
	StatusOpen      = "open"
	StatusAwarded   = "awarded"
	StatusCancelled = "cancelled"
	StatusExpired   = "expired"
)

// Input bounds.
const (
	MaxTitleLen = 80
	MaxDescLen  = 2000

	// MaxURILen bounds a submission's content reference. Submissions
	// carry a REFERENCE (a URL or content hash), not the work itself —
	// the chain cannot judge quality, and storing bulk content would
	// push an unbounded cost onto every future reader of this realm.
	MaxURILen = 500

	// MaxPanelSize bounds panel parsing, storage and Render cost.
	MaxPanelSize = int64(16)

	// MaxSubmissions bounds per-bounty state growth. Each submission
	// also costs its submitter a storage deposit, so this is a ceiling
	// on a cost that is already borne by the party creating it.
	MaxSubmissions = int64(500)

	// MinDurationBlocks / MaxDurationBlocks bound each configurable
	// window (~5s blocks: 1 block to ~580 days).
	MinDurationBlocks = int64(1)
	MaxDurationBlocks = int64(10_000_000)

	// ExpiryGraceBlocks after the resolution deadline, an Open bounty
	// becomes expirable by anyone (~8 minutes at 5s blocks — short
	// because this is a testnet deployment; a production fork would
	// raise it). The grace exists so that "the panel may still vote"
	// and "anyone may expire" are never simultaneously true.
	ExpiryGraceBlocks = int64(100)

	// MaxRenderRows bounds Render output. Render is reachable by any
	// viewer through gnoweb and vm/qrender, so its cost lands on third
	// parties rather than on whoever grew the state.
	MaxRenderRows = 20
)

type submission struct {
	uri    string // content reference (URL or hash)
	height int64  // block height of the latest (re)submission
	votes  int64  // live panel votes currently naming this submission
}

type bounty struct {
	id          int64
	funder      address
	title       string
	description string
	amount      int64
	feeBps      int64 // snapshotted at creation, charged at award

	panel     *avl.Tree // resolver address string -> struct{}{}
	panelSize int64
	threshold int64 // votes required to award (1 <= threshold <= panelSize)

	submitDeadline  int64 // submissions close here; voting opens here
	resolveDeadline int64 // voting closes here

	status string
	winner address // set iff status == StatusAwarded

	subs    *avl.Tree // submitter address string -> *submission
	numSubs int64
	ballots *avl.Tree // resolver address string -> submitter address string
}

var (
	admin        address // may set fee, fee recipient, successor admin
	feeRecipient address // may withdraw fees and sweep surplus
	feeBps       int64   // fee snapshotted into NEW bounties

	self      address // this realm's address, captured at deploy
	nextID    int64
	openTotal int64 // == Σ amount over bounties with status Open

	bounties = avl.NewTree() // padID(id) -> *bounty
	ledger   = feeledger.MustNew(MaxFeeBps)
)

func init() {
	admin = unsafe.OriginCaller()
	feeRecipient = admin
	self = unsafe.CurrentRealm().Address()
}

// rejectStraySend aborts when coins are attached to a non-payable call.
// This realm does hold funds, so a stray send would not be lost outright
// — it would become sweepable surplus belonging to the fee recipient,
// silently converting a user's coins into protocol revenue. Aborting
// reverts the transfer to the sender instead. Guarded on IsUserCall, not
// IsUser, because a MsgRun ephemeral can consume the OriginSend envelope
// before forwarding control.
//
// SCOPE, precisely: the guard reads the ORIGINATING transaction's
// envelope, so it only inspects direct EOA calls. For a realm-routed
// call the -send envelope is delivered to the INTERMEDIARY realm's
// address, so there is nothing at this realm to reject and the guard
// deliberately fails open. That is not a hole: an intermediary that
// separately sends coins to this realm's address is making an ordinary
// transfer, which no guard in any entrypoint could intercept, and
// which lands as surplus recoverable through SweepDenom. Coins can
// only become ESCROW through CreateBounty.
func rejectStraySend(cur realm) {
	if cur.Previous().IsUserCall() && len(unsafe.OriginSend()) > 0 {
		panic("this entrypoint does not accept coins")
	}
}

// CreateBounty escrows the attached GNOT as a new open bounty and
// returns its id. Only direct EOA calls with -send are accepted.
//
// panelCSV is a comma-separated list of resolver addresses; threshold is
// how many of them must name the same submission for it to win.
// Submissions are accepted for submitBlocks from now, after which the
// panel has resolveBlocks to decide.
//
// The current protocol fee is snapshotted into the bounty and must not
// exceed maxFeeBps, the ceiling the caller signed for; pass MaxFeeBps to
// accept any legal fee.
func CreateBounty(cur realm, title, description, panelCSV string, threshold, submitBlocks, resolveBlocks, maxFeeBps int64) int64 {
	funder, amount := coinio.Receive(0, cur, Denom)
	if feeBps > maxFeeBps {
		panic("current fee " + itoa(feeBps) + " bps exceeds the caller's maximum " + itoa(maxFeeBps))
	}
	assertValidTitle(title)
	if len(description) == 0 || len(description) > MaxDescLen {
		panic("description must be 1-" + strconv.Itoa(MaxDescLen) + " bytes")
	}
	assertDuration("submitBlocks", submitBlocks)
	assertDuration("resolveBlocks", resolveBlocks)

	panel, panelSize := parsePanel(panelCSV)
	if threshold < 1 || threshold > panelSize {
		panic("threshold must be in [1, panel size " + itoa(panelSize) + "]")
	}

	newOpenTotal, ok := checkedAdd(openTotal, amount)
	if !ok {
		panic("open escrow overflow")
	}

	now := runtime.ChainHeight()
	nextID++
	b := &bounty{
		id:              nextID,
		funder:          funder,
		title:           title,
		description:     description,
		amount:          amount,
		feeBps:          feeBps,
		panel:           panel,
		panelSize:       panelSize,
		threshold:       threshold,
		submitDeadline:  now + submitBlocks,
		resolveDeadline: now + submitBlocks + resolveBlocks,
		status:          StatusOpen,
		subs:            avl.NewTree(),
		ballots:         avl.NewTree(),
	}
	bounties.Set(padID(b.id), b)
	openTotal = newOpenTotal

	chain.Emit("BountyCreated",
		"id", itoa(b.id),
		"funder", funder.String(),
		"amount", itoa(amount),
		"feeBps", itoa(b.feeBps),
		"panelSize", itoa(panelSize),
		"threshold", itoa(threshold),
		"submitDeadline", itoa(b.submitDeadline),
		"resolveDeadline", itoa(b.resolveDeadline),
	)
	return b.id
}

// Submit records (or replaces) the caller's submission to an open bounty
// before its submission deadline. One submission per address per bounty
// — re-submitting replaces the caller's own reference only. The funder
// and every panel member are barred, so no resolver can vote for their
// own work.
func Submit(cur realm, id int64, uri string) {
	rejectStraySend(cur)
	submitter := cur.Previous().Address()
	b := mustGetBounty(id)
	if b.status != StatusOpen {
		panic("bounty is not open")
	}
	if runtime.ChainHeight() >= b.submitDeadline {
		panic("submission window has closed")
	}
	if submitter == b.funder {
		panic("the funder cannot submit to their own bounty")
	}
	if b.panel.Has(submitter.String()) {
		panic("a panel resolver cannot submit to a bounty they judge")
	}
	if len(uri) == 0 || len(uri) > MaxURILen {
		panic("uri must be 1-" + strconv.Itoa(MaxURILen) + " bytes")
	}

	key := submitter.String()
	if v := b.subs.Get(key); v != nil {
		s := v.(*submission)
		s.uri = uri
		s.height = runtime.ChainHeight()
	} else {
		if b.numSubs >= MaxSubmissions {
			panic("bounty has reached its submission cap")
		}
		b.numSubs++
		b.subs.Set(key, &submission{uri: uri, height: runtime.ChainHeight()})
	}

	chain.Emit("Submitted", "id", itoa(id), "submitter", key)
}

// Vote casts (or changes) the calling resolver's vote for one of the
// bounty's submissions. Only panel members may vote, and only after the
// submission window has closed and before the resolution deadline. A
// resolver holds exactly one live vote, changeable until the threshold
// is reached.
//
// The vote that brings a submission to the threshold awards the bounty
// in the same transaction: the escrow leaves the open pool and is
// credited to the winner's claimable balance at the fee snapshotted at
// creation. Terminal.
func Vote(cur realm, id int64, candidate address) {
	rejectStraySend(cur)
	resolver := cur.Previous().Address()
	b := mustGetBounty(id)
	if b.status != StatusOpen {
		panic("bounty is not open")
	}
	if !b.panel.Has(resolver.String()) {
		panic("only a panel resolver may vote")
	}
	now := runtime.ChainHeight()
	if now < b.submitDeadline {
		panic("voting opens when the submission window closes")
	}
	if now >= b.resolveDeadline {
		panic("resolution window has closed")
	}

	candKey := candidate.String()
	cv := b.subs.Get(candKey)
	if cv == nil {
		panic("candidate must have submitted to this bounty")
	}
	cand := cv.(*submission)

	rKey := resolver.String()
	if prev := b.ballots.Get(rKey); prev != nil {
		prevKey := prev.(string)
		if prevKey == candKey {
			panic("already voted for this submission")
		}
		// Withdraw the resolver's previous vote before recording the new
		// one, so the per-submission counts always sum to the number of
		// live ballots.
		pv := b.subs.Get(prevKey)
		pv.(*submission).votes--
	}
	b.ballots.Set(rKey, candKey)
	cand.votes++

	chain.Emit("Voted",
		"id", itoa(id),
		"resolver", rKey,
		"candidate", candKey,
		"votes", itoa(cand.votes),
		"threshold", itoa(b.threshold),
	)

	if cand.votes >= b.threshold {
		award(b, candidate, cand.votes)
	}
}

// award moves an Open bounty's escrow into the winner's claimable
// balance at the snapshotted fee and finalizes the status. The caller
// has already verified authorization, status and the threshold.
func award(b *bounty, winner address, votes int64) {
	credited, fee, err := ledger.Deposit(winner.String(), b.amount, b.feeBps)
	if err != nil {
		panic(err)
	}
	openTotal -= b.amount // >= 0: openTotal == Σ open amounts >= b.amount
	b.status = StatusAwarded
	b.winner = winner

	chain.Emit("BountyAwarded",
		"id", itoa(b.id),
		"winner", winner.String(),
		"credited", itoa(credited),
		"fee", itoa(fee),
		"votes", itoa(votes),
	)
}

// CancelBounty closes an open bounty and refunds its escrow to the
// funder, fee-free. Only the funder may cancel, and ONLY while no
// contributor has submitted: once work exists, the funder cannot
// unilaterally reclaim the escrow. Terminal.
func CancelBounty(cur realm, id int64) {
	rejectStraySend(cur)
	caller := cur.Previous().Address()
	b := mustGetBounty(id)
	if caller != b.funder {
		panic("only the bounty funder may cancel")
	}
	if b.status != StatusOpen {
		panic("bounty is not open")
	}
	if b.numSubs > 0 {
		panic("cannot cancel a bounty that has submissions; it must be resolved or expire")
	}
	refundOpen(b, StatusCancelled)
	chain.Emit("BountyCancelled", "id", itoa(id), "funder", b.funder.String(), "amount", itoa(b.amount))
}

// ExpireBounty closes an open bounty whose resolution deadline passed
// more than ExpiryGraceBlocks ago, refunding the funder fee-free. ANYONE
// may call it — this is the permissionless valve that guarantees escrow
// can never be trapped by an inactive or deadlocked panel. Terminal.
func ExpireBounty(cur realm, id int64) {
	rejectStraySend(cur)
	b := mustGetBounty(id)
	if b.status != StatusOpen {
		panic("bounty is not open")
	}
	if runtime.ChainHeight() < b.resolveDeadline+ExpiryGraceBlocks {
		panic("bounty is not expirable yet")
	}
	refundOpen(b, StatusExpired)
	chain.Emit("BountyExpired", "id", itoa(b.id), "funder", b.funder.String(), "amount", itoa(b.amount))
}

// refundOpen moves an Open bounty's escrow into the funder's claimable
// balance fee-free and finalizes the status. Callers have already
// verified authorization and status.
func refundOpen(b *bounty, terminal string) {
	if _, _, err := ledger.Deposit(b.funder.String(), b.amount, 0); err != nil {
		panic(err)
	}
	openTotal -= b.amount
	b.status = terminal
}

// Claim sends amount ugnot of the caller's claimable balance (winnings
// and refunds) back to the caller.
func Claim(cur realm, amount int64) {
	rejectStraySend(cur)
	caller := cur.Previous().Address()
	if err := ledger.Withdraw(caller.String(), amount); err != nil {
		panic(err)
	}
	coinio.Payout(0, cur, caller, Denom, amount)
	chain.Emit("Claim", "to", caller.String(), "amount", itoa(amount))
}

// ClaimAll sends the caller's entire claimable balance back to the
// caller. Fails if there is nothing to claim.
func ClaimAll(cur realm) {
	rejectStraySend(cur)
	caller := cur.Previous().Address()
	amount, err := ledger.WithdrawAll(caller.String())
	if err != nil {
		panic(err)
	}
	if amount == 0 {
		panic("nothing to claim")
	}
	coinio.Payout(0, cur, caller, Denom, amount)
	chain.Emit("Claim", "to", caller.String(), "amount", itoa(amount))
}

// WithdrawFees sends the accrued fee pot to the fee recipient. Only the
// fee recipient may call it.
func WithdrawFees(cur realm) {
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
}

// SweepDenom sends the surplus of a single denomination to the fee
// recipient. For ugnot only the excess over Liabilities() moves; other
// denoms move wholly. Only the fee recipient may call it.
func SweepDenom(cur realm, denom string) {
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
}

// SetFeeBps sets the protocol fee snapshotted into FUTURE bounties at
// creation. Existing bounties keep the fee they were created under.
// Admin only; bounded by [0, MaxFeeBps].
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

// SetFeeRecipient re-points the fee/surplus role, including the pot
// accrued so far. Admin only; zero address rejected.
func SetFeeRecipient(cur realm, next address) {
	rejectStraySend(cur)
	assertAdmin(cur.Previous().Address())
	var zero address
	if next == zero {
		panic("empty fee recipient")
	}
	old := feeRecipient
	feeRecipient = next
	chain.Emit("FeeRecipientChanged", "old", old.String(), "new", next.String())
}

// TransferAdmin hands the admin role to next. Admin only; zero address
// rejected. One-step (documented trade-off, matching the siblings).
func TransferAdmin(cur realm, next address) {
	rejectStraySend(cur)
	assertAdmin(cur.Previous().Address())
	var zero address
	if next == zero {
		panic("empty admin address")
	}
	admin = next
	chain.Emit("AdminTransferred", "newAdmin", next.String())
}

// --- read-only views ---

// BountyInfo returns a bounty's scalar fields by value.
func BountyInfo(id int64) (funder address, title string, amount, feeBps, submitDeadline, resolveDeadline int64, status string, winner address, numSubmissions, panelSize, threshold int64) {
	b := mustGetBounty(id)
	return b.funder, b.title, b.amount, b.feeBps, b.submitDeadline, b.resolveDeadline, b.status, b.winner, b.numSubs, b.panelSize, b.threshold
}

// Description returns a bounty's raw description text.
func Description(id int64) string { return mustGetBounty(id).description }

// SubmissionOf returns addr's content reference, submission height and
// current vote count for a bounty, with ok reporting whether a
// submission exists.
func SubmissionOf(id int64, addr address) (uri string, height, votes int64, ok bool) {
	b := mustGetBounty(id)
	v := b.subs.Get(addr.String())
	if v == nil {
		return "", 0, 0, false
	}
	s := v.(*submission)
	return s.uri, s.height, s.votes, true
}

// IsPanelMember reports whether addr may vote on a bounty.
func IsPanelMember(id int64, addr address) bool {
	return mustGetBounty(id).panel.Has(addr.String())
}

// Panel returns a bounty's resolver addresses as a comma-separated
// list, in sorted order.
func Panel(id int64) string {
	b := mustGetBounty(id)
	out := ""
	b.panel.Iterate("", "", func(key string, _ any) bool {
		if out != "" {
			out += ","
		}
		out += key
		return false
	})
	return out
}

// VoteOf returns the submission a resolver currently votes for, with ok
// reporting whether that resolver has voted at all.
func VoteOf(id int64, resolver address) (candidate string, ok bool) {
	b := mustGetBounty(id)
	v := b.ballots.Get(resolver.String())
	if v == nil {
		return "", false
	}
	return v.(string), true
}

// VotesCast returns how many resolvers currently hold a live vote.
func VotesCast(id int64) int64 { return int64(mustGetBounty(id).ballots.Size()) }

// Admin returns the current admin.
func Admin() address { return admin }

// FeeRecipient returns who may withdraw fees and sweep surplus.
func FeeRecipient() address { return feeRecipient }

// FeeBps returns the fee that will be snapshotted into newly created
// bounties (existing bounties keep their own snapshot).
func FeeBps() int64 { return feeBps }

// FeeOn previews the fee and net payout for a bounty of amount at the
// CURRENT FeeBps.
func FeeOn(amount int64) (fee, credited int64) {
	f, err := feeledger.FeeFor(amount, feeBps)
	if err != nil {
		panic(err)
	}
	return f, amount - f
}

// NumBounties returns how many bounties have ever been created.
func NumBounties() int64 { return nextID }

// OpenTotal returns the escrow held by open bounties (the B term).
func OpenTotal() int64 { return openTotal }

// BalanceOf returns addr's claimable balance (winnings + refunds).
func BalanceOf(addr address) int64 { return ledger.BalanceOf(addr.String()) }

// UsersTotal returns the sum of all claimable balances (the U term).
func UsersTotal() int64 { return ledger.UsersTotal() }

// FeesAccrued returns the fee pot (the F term).
func FeesAccrued() int64 { return ledger.FeesAccrued() }

// Liabilities returns everything this realm owes:
// openTotal + UsersTotal + FeesAccrued.
func Liabilities() int64 { return openTotal + ledger.Liabilities() }

// Held returns the ugnot actually held at the realm address (H).
func Held() int64 { return coinio.HeldAt(self, Denom) }

// Surplus returns Held() - Liabilities() (the S term).
func Surplus() int64 { return Held() - Liabilities() }

// Address returns this realm's address (the escrow target).
func Address() address { return self }

// Height returns the current chain height (deadline arithmetic aid).
func Height() int64 { return runtime.ChainHeight() }

// Render shows the board at "" and a bounty detail at "<id>". Free text
// (titles are charset-restricted; descriptions and URIs are not) passes
// through the ecosystem sanitizer before hitting markdown.
func Render(path string) string {
	if path != "" {
		return renderBounty(path)
	}
	held := Held()
	liab := Liabilities()
	status := "OK"
	if held < liab {
		status = "VIOLATED"
	}
	out := "# Bounty panel\n\n"
	out += "Escrowed GNOT bounties resolved by a panel named at creation, not by the funder.\n\n"
	out += "## Configuration\n\n"
	out += "- fee for new bounties: " + itoa(feeBps) + " bps (cap " + itoa(MaxFeeBps) +
		" bps; each bounty keeps the fee snapshotted at its creation)\n"
	out += "- fee recipient: " + feeRecipient.String() + "\n"
	out += "- admin: " + admin.String() + "\n\n"
	out += "## Accounting (H == B + U + F + S)\n\n"
	out += "- open escrow (B): " + itoa(openTotal) + Denom + "\n"
	out += "- claimable (U): " + itoa(ledger.UsersTotal()) + Denom + "\n"
	out += "- fees accrued (F): " + itoa(ledger.FeesAccrued()) + Denom + "\n"
	out += "- held (H): " + itoa(held) + Denom + "\n"
	out += "- conservation: " + status + "\n\n"
	out += "## Latest bounties\n\n"
	if nextID == 0 {
		out += "No bounties yet.\n"
		return out
	}
	shown := 0
	bounties.ReverseIterate("", "", func(_ string, v any) bool {
		b := v.(*bounty)
		out += "- [#" + itoa(b.id) + "](" + RealmPath + ":" + itoa(b.id) + ") [" +
			b.status + "] " + b.title + " — " + itoa(b.amount) + Denom +
			" (" + itoa(b.numSubs) + " submissions, " + itoa(b.threshold) + "-of-" + itoa(b.panelSize) + ")\n"
		shown++
		return shown >= MaxRenderRows
	})
	if int64(shown) < nextID {
		out += "\n> [!NOTE]\n> Showing the " + strconv.Itoa(shown) + " most recent of " +
			itoa(nextID) + ". Use BountyInfo(id) for any specific bounty.\n"
	}
	return out
}

func renderBounty(path string) string {
	id, err := strconv.ParseInt(path, 10, 64)
	if err != nil {
		return "> [!WARNING]\n> invalid bounty id\n"
	}
	v := bounties.Get(padID(id))
	if v == nil {
		return "> [!WARNING]\n> unknown bounty id\n"
	}
	b := v.(*bounty)
	now := runtime.ChainHeight()

	out := "# Bounty #" + itoa(b.id) + ": " + b.title + "\n\n"
	out += "- status: " + b.status + "\n"
	out += "- funder: " + b.funder.String() + "\n"
	out += "- amount: " + itoa(b.amount) + Denom + "\n"
	out += "- fee (snapshot): " + itoa(b.feeBps) + " bps\n"
	out += "- resolution: " + itoa(b.threshold) + " of " + itoa(b.panelSize) + " panel votes\n"
	out += "- submissions close: block " + itoa(b.submitDeadline) + "\n"
	out += "- resolution closes: block " + itoa(b.resolveDeadline) + " (now " + itoa(now) + ")\n"
	out += "- submissions: " + itoa(b.numSubs) + "\n"
	if b.status == StatusAwarded {
		out += "- winner: " + b.winner.String() + "\n"
	}

	out += "\n## Description\n\n" + sanitize.InlineText(b.description) + "\n"

	out += "\n## Panel\n\n"
	b.panel.Iterate("", "", func(key string, _ any) bool {
		out += "- " + key + "\n"
		return false
	})

	out += "\n## Submissions\n\n"
	if b.numSubs == 0 {
		out += "No submissions yet.\n"
		return out
	}
	shown := 0
	b.subs.Iterate("", "", func(key string, sv any) bool {
		s := sv.(*submission)
		out += "- " + key + " — " + itoa(s.votes) + " vote(s), block " + itoa(s.height) +
			"\n  - " + sanitize.InlineText(s.uri) + "\n"
		shown++
		return shown >= MaxRenderRows
	})
	if int64(shown) < b.numSubs {
		out += "\n> [!NOTE]\n> Showing " + strconv.Itoa(shown) + " of " + itoa(b.numSubs) +
			" submissions. Use SubmissionOf(id, addr) for any specific one.\n"
	}
	return out
}

// --- internals ---

func assertAdmin(caller address) {
	if caller != admin {
		panic("admin only")
	}
}

func mustGetBounty(id int64) *bounty {
	v := bounties.Get(padID(id))
	if v == nil {
		panic("unknown bounty id")
	}
	return v.(*bounty)
}

func assertDuration(name string, blocks int64) {
	if blocks < MinDurationBlocks || blocks > MaxDurationBlocks {
		panic(name + " out of range [" + itoa(MinDurationBlocks) + ", " + itoa(MaxDurationBlocks) + "]")
	}
}

// parsePanel turns a comma-separated resolver list into a membership
// tree. Every entry must be a valid, non-empty, non-duplicate bech32
// address. Validity is checked here rather than trusted: a mistyped
// resolver address would silently shrink the effective panel and could
// make the threshold permanently unreachable, which is a fund-trapping
// shape even with the expiry valve in place.
func parsePanel(csv string) (*avl.Tree, int64) {
	parts := strings.Split(csv, ",")
	panel := avl.NewTree()
	count := int64(0)
	for _, p := range parts {
		key := strings.TrimSpace(p)
		if key == "" {
			panic("panel contains an empty entry")
		}
		if !address(key).IsValid() {
			panic("panel contains an invalid address: " + key)
		}
		if panel.Has(key) {
			panic("panel contains a duplicate address: " + key)
		}
		count++
		if count > MaxPanelSize {
			panic("panel exceeds " + itoa(MaxPanelSize) + " resolvers")
		}
		panel.Set(key, struct{}{})
	}
	if count == 0 {
		panic("panel must name at least one resolver")
	}
	return panel, count
}

// assertValidTitle bounds length and restricts the charset so titles are
// list-safe in Render without escaping.
func assertValidTitle(title string) {
	if len(title) == 0 || len(title) > MaxTitleLen {
		panic("title must be 1-" + strconv.Itoa(MaxTitleLen) + " characters")
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

// padID renders an id as a fixed-width key so avl iteration order is
// numeric order.
func padID(id int64) string {
	s := strconv.FormatInt(id, 10)
	for len(s) < 12 {
		s = "0" + s
	}
	return s
}

func itoa(n int64) string {
	return strconv.FormatInt(n, 10)
}

func checkedAdd(a, b int64) (int64, bool) {
	sum := a + b
	if (b > 0 && sum < a) || (b < 0 && sum > a) {
		return 0, false
	}
	return sum, true
}
