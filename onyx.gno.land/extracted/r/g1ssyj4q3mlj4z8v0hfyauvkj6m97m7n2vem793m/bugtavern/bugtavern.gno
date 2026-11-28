// Package bugtavern is the BugTavern realm.
//
// Day 5 ships the money-out glue: CommitFinding / RevealFinding,
// Verdict / SponsorVerdict, DisputeFinding / ClaimPayout,
// CancelBounty / CloseBounty, MarkFixed — all money leaves the realm
// only through a tavernrules move that returns a Payout, executed
// with SendCoins AFTER the state is already final (CEI, design §7
// T2/T10). Day 4 shipped the money-in glue (CreateBounty /
// TopUpBounty); see BugTavern-DESIGN.md §10.
//
// Guard order on every mutator (design §5):
//  1. cur.Previous().IsUserCall() — direct user call only.
//  2. requireNoCoins() on every non-payment function — a stray coin
//     attached to a non-payment call panics instead of getting stuck.
//
// Payment functions (CreateBounty / TopUpBounty) check
// unsafe.OriginSend() == the exact expected amount instead.
//
// No cur.IsCurrent() guard: in a crossing function it is always true
// (README deviation 3, upstream gno AGENTS.md).
//
// Actor identity is ALWAYS cur.Previous().Address() — never a tx
// parameter. Heights ALWAYS come from runtime.ChainHeight().
package bugtavern

import (
	"strconv"

	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"

	"gno.land/p/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/tavernrules"
	"gno.land/p/nt/avl/v0"
)

// version is bumped when the realm goes live.
const version = "0.4.0-day6"

// MinDeadlineBlocks / MaxDeadlineBlocks bound the bounty lifetime
// (design §5.1: ~1 day minimum, ~90 days maximum; 1 block ≈ 3.5s,
// 24600 blocks ≈ 1 day).
const (
	MinDeadlineBlocks int64 = 24600
	MaxDeadlineBlocks int64 = 2214000
)

// State. Keys are "bounty/<20-digit id>" / "finding/<20-digit id>"
// (zero-padded so avl lexicographic order matches numeric order).
// The WHOLE tavernrules.Bounty value is stored — including the
// paidTiers bitmask; losing it would re-open paid tiers (freeze
// checklist obligation 6). Ids are unique and sequential per realm
// (obligation 4); the duplicate tie-break relies on id order.
var bounties = avl.NewTree()
var findings = avl.NewTree()
var nextBountyID uint64 = 1
var nextFindingID uint64 = 1

// Ledger: append-only money trail (design §5.5, §8.6). One entry per
// money move — CreateBounty/TopUp lock, Verdict/SponsorVerdict and
// ClaimPayout payout, Cancel/Close refund. MarkFixed moves no money
// and records nothing. Keys are "ledger/<20-digit id>" like the
// other trees, so iteration order is insertion order.
type LedgerEntry struct {
	Height    int64
	BountyID  uint64
	FindingID uint64
	Kind      string // "lock" | "payout" | "refund"
	To        address
	Amount    int64
	Note      string
}

var ledger = avl.NewTree()
var nextLedgerID uint64 = 1

func ledgerKey(id uint64) string { return "ledger/" + padID(id) }

// appendLedger records one money move. Called only after the state
// move has succeeded and (for payouts/refunds) the coins were sent,
// so the trail never describes money that did not move.
func appendLedger(height int64, bountyID, findingID uint64, kind string, to address, amount int64, note string) {
	id := nextLedgerID
	ledger.Set(ledgerKey(id), LedgerEntry{
		Height: height, BountyID: bountyID, FindingID: findingID,
		Kind: kind, To: to, Amount: amount, Note: note,
	})
	nextLedgerID++
}

// padID left-pads a decimal id to 20 digits.
func padID(id uint64) string {
	s := strconv.FormatUint(id, 10)
	for len(s) < 20 {
		s = "0" + s
	}
	return s
}

func bountyKey(id uint64) string  { return "bounty/" + padID(id) }
func findingKey(id uint64) string { return "finding/" + padID(id) }

// mustGetBounty loads a bounty by id, or panics "bounty not found"
// (freeze checklist obligation 5: unknown id is the realm's
// "not found" — the pure package has no store).
func mustGetBounty(id uint64) tavernrules.Bounty {
	b, ok := bounties.Get(bountyKey(id)).(tavernrules.Bounty)
	if !ok {
		panic("bounty not found")
	}
	return b
}

// mustGetFinding loads a finding by id, or panics "finding not found".
func mustGetFinding(id uint64) tavernrules.Finding {
	f, ok := findings.Get(findingKey(id)).(tavernrules.Finding)
	if !ok {
		panic("finding not found")
	}
	return f
}

// GetFinding returns a value copy of the finding with id (panics when
// unknown). A copy is returned, never a pointer to stored state.
func GetFinding(id uint64) tavernrules.Finding {
	return mustGetFinding(id)
}

// requireNoCoins panics when any coins are attached to the call
// (design §7 T14). Every non-payment mutator calls this first, so a
// coin sent to the wrong function aborts the transaction instead of
// getting stuck in the realm. Coins.IsZero covers every denom, not
// just ugnot.
func requireNoCoins() {
	if !unsafe.OriginSend().IsZero() {
		panic("this function does not accept coins")
	}
}

// requireUserCall panics unless the call is a direct user call, and
// returns the caller's address. IsUser() is NOT enough: a maketx-run
// ephemeral realm passes IsUser() while spending the origin-send
// envelope elsewhere.
func requireUserCall(cur realm) address {
	if !cur.Previous().IsUserCall() {
		panic("must be a direct user call")
	}
	return cur.Previous().Address()
}

// findingsOf returns value copies of all findings of one bounty, in
// id order (avl keys sort lexicographically; ids are zero-padded, so
// key order is id order).
func findingsOf(bountyID uint64) []tavernrules.Finding {
	var out []tavernrules.Finding
	findings.Iterate("", "", func(key string, value any) bool {
		if f, ok := value.(tavernrules.Finding); ok && f.BountyID() == bountyID {
			out = append(out, f)
		}
		return false
	})
	return out
}

// othersOf returns value copies of all findings of one bounty except
// the finding with excludeID. Verdict / claim moves take the OTHER
// findings as defence-in-depth for the tier-once rule (the paidTiers
// flag on the Bounty is authoritative; see freeze checklist
// obligation 2).
func othersOf(bountyID, excludeID uint64) []tavernrules.Finding {
	var out []tavernrules.Finding
	for _, f := range findingsOf(bountyID) {
		if f.ID() != excludeID {
			out = append(out, f)
		}
	}
	return out
}

// executePayout sends the payout's coins from this realm to its
// recipient — but ONLY when the payout is due (Kind set and Amount >
// 0). Callers invoke this only after the rules move has returned, so
// the state is already final (CEI: state first, coins second, design
// §7 T2/T10). A non-due payout moves no coins.
func executePayout(cur realm, p tavernrules.Payout) {
	if !p.Due() {
		return
	}
	banker.NewBanker(banker.BankerTypeRealmSend, cur).
		SendCoins(cur.Address(), p.To,
			chain.NewCoins(chain.NewCoin("ugnot", p.Amount)))
}

// saveBounty persists the WHOLE Bounty value — including the
// paidTiers bitmask; losing it would re-open paid tiers (freeze
// checklist obligation 6).
func saveBounty(b tavernrules.Bounty) {
	bounties.Set(bountyKey(b.ID()), b)
}

// saveFinding persists one finding value.
func saveFinding(f tavernrules.Finding) {
	findings.Set(findingKey(f.ID()), f)
}

// GetBounty returns a value copy of the bounty with id (panics when
// unknown). A copy is returned, never a pointer to stored state.
func GetBounty(id uint64) tavernrules.Bounty {
	return mustGetBounty(id)
}

// NextBountyID returns the id the next created bounty will get.
func NextBountyID() uint64 { return nextBountyID }

// NextFindingID returns the id the next committed finding will get.
func NextFindingID() uint64 { return nextFindingID }

// checkedPoolTotal sums the four tier prices, or reports overflow.
func checkedPoolTotal(priceCrit, priceHigh, priceMed, priceLow int64) (int64, bool) {
	total, ok := tavernrules.CheckedAdd(priceCrit, priceHigh)
	if !ok {
		return 0, false
	}
	total, ok = tavernrules.CheckedAdd(total, priceMed)
	if !ok {
		return 0, false
	}
	return tavernrules.CheckedAdd(total, priceLow)
}

// CreateBounty opens a bounty and locks its pool (poolTotal =
// priceCrit+priceHigh+priceMed+priceLow) in this realm. The caller
// must attach EXACTLY poolTotal ugnot with the call; anything else
// panics and the transaction aborts. Returns the new bounty id.
// Emits a BountyCreated event.
func CreateBounty(cur realm, title, scope string, priceCrit, priceHigh, priceMed, priceLow int64, arbiter address, deadlineBlocks int64) uint64 {
	if !cur.Previous().IsUserCall() {
		panic("CreateBounty must be a direct user call")
	}
	sponsor := cur.Previous().Address()
	if deadlineBlocks < MinDeadlineBlocks || deadlineBlocks > MaxDeadlineBlocks {
		panic("deadline must be between 24600 and 2214000 blocks")
	}
	height := runtime.ChainHeight()
	deadline, ok := tavernrules.CheckedAdd(height, deadlineBlocks)
	if !ok {
		panic("deadline overflows")
	}
	poolTotal, ok := checkedPoolTotal(priceCrit, priceHigh, priceMed, priceLow)
	if !ok {
		panic("tier prices overflow")
	}
	if unsafe.OriginSend().AmountOf("ugnot") != poolTotal {
		panic("must send exactly the pool total in ugnot")
	}
	id := nextBountyID
	// NewBounty validates the rest (tier minimums, pool >= 1 GNOT,
	// title/scope lengths, non-empty arbiter, deadline >= createdAt)
	// and panics on any violation.
	bounty := tavernrules.NewBounty(id, sponsor, arbiter, title, scope,
		priceCrit, priceHigh, priceMed, priceLow, height, deadline)
	bounties.Set(bountyKey(id), bounty)
	nextBountyID++
	appendLedger(height, id, 0, "lock", sponsor, poolTotal, "bounty created")
	chain.Emit("BountyCreated",
		"bounty_id", strconv.FormatUint(id, 10),
		"sponsor", sponsor.String(),
		"pool_total", strconv.FormatInt(poolTotal, 10))
	return id
}

// TopUpBounty adds the attached ugnot to an Open bounty's pool
// (poolTotal and poolLeft grow by the same amount). Anyone may top
// up; the amount must be positive. Emits a BountyToppedUp event.
func TopUpBounty(cur realm, bountyID uint64) {
	if !cur.Previous().IsUserCall() {
		panic("TopUpBounty must be a direct user call")
	}
	topper := cur.Previous().Address()
	amount := unsafe.OriginSend().AmountOf("ugnot")
	if amount <= 0 {
		panic("top-up amount must be positive")
	}
	bounty := mustGetBounty(bountyID)
	bounty.TopUp(amount)
	bounties.Set(bountyKey(bountyID), bounty)
	appendLedger(runtime.ChainHeight(), bountyID, 0, "lock", topper, amount, "bounty topped up")
	chain.Emit("BountyToppedUp",
		"bounty_id", strconv.FormatUint(bountyID, 10),
		"amount", strconv.FormatInt(amount, 10),
		"pool_total", strconv.FormatInt(bounty.PoolTotal(), 10))
}

// ---------------------------------------------------------------------------
// Day-5 glue: money out (design §5.2–§5.4, §6).
//
// Every function below follows the same shape:
//  1. requireUserCall + requireNoCoins (no coins may be attached),
//  2. load bounty + finding, check the caller's role,
//  3. call the ONE public tavernrules move for the transition — the
//     rules validate state + actor + windows, mutate (final state
//     first), and return a Payout. The low-level Record*/Close()/
//     Cancel() primitives are NEVER called directly from the realm.
//  4. persist the WHOLE Bounty (paidTiers included) and the finding,
//  5. execute the Payout with SendCoins ONLY when Due(),
//  6. emit the event.
//
// A failed move panics inside the rules call, before any persist or
// coin movement, so a rejected transaction leaves no half-state.
// ---------------------------------------------------------------------------

// CommitFinding records a hunter's hash commitment against an Open
// bounty (design §5.2). Only while the bounty is Open and height is
// not past its deadline; the hash must be a 64-char lowercase hex
// digest and must not already be carried by another finding on the
// same bounty. Returns the new finding id. Emits FindingCommitted.
func CommitFinding(cur realm, bountyID uint64, commitHash string, severity uint8) uint64 {
	hunter := requireUserCall(cur)
	requireNoCoins()
	height := runtime.ChainHeight()
	bounty := mustGetBounty(bountyID)
	others := findingsOf(bountyID)
	id := nextFindingID
	f := tavernrules.CommitFinding(&bounty, others, id, hunter,
		tavernrules.Severity(severity), commitHash, height)
	findings.Set(findingKey(id), f)
	nextFindingID++
	chain.Emit("FindingCommitted",
		"finding_id", strconv.FormatUint(id, 10),
		"bounty_id", strconv.FormatUint(bountyID, 10),
		"hunter", hunter.String(),
		"severity", tavernrules.Severity(severity).String())
	return id
}

// RevealFinding discloses a committed finding (design §5.2). Only the
// hunter who committed, only while Committed and before the reveal
// deadline. The commitment is recomputed inside the rules move from
// (bountyID, severity, title, pocURL, salt) and must match the stored
// hash exactly. Emits FindingRevealed.
func RevealFinding(cur realm, findingID uint64, title, pocURL, salt string) {
	hunter := requireUserCall(cur)
	requireNoCoins()
	height := runtime.ChainHeight()
	f := mustGetFinding(findingID)
	bounty := mustGetBounty(f.BountyID())
	f.Reveal(&bounty, hunter, title, pocURL, salt, height)
	saveFinding(f)
	chain.Emit("FindingRevealed",
		"finding_id", strconv.FormatUint(findingID, 10),
		"bounty_id", strconv.FormatUint(f.BountyID(), 10),
		"hunter", hunter.String())
}

// verdictOriginal loads the duplicate target for a Duplicate verdict
// (nil when duplicateOf is 0 — the rules move panics then, as a
// Duplicate verdict without an original is invalid).
func verdictOriginal(duplicateOf uint64) *tavernrules.Finding {
	if duplicateOf == 0 {
		return nil
	}
	o := mustGetFinding(duplicateOf)
	return &o
}

// doVerdict is the shared core of Verdict and SponsorVerdict: run the
// rules move, persist both sides, pay out only when due, and emit
// VerdictGiven (+ FindingPaid when money moved). arbiter=true calls
// the arbiter move, false the sponsor move. The final severity is the
// arbiter's corrected tier (design §5.3): the price follows the FINAL
// tier, not the hunter's claim. For Duplicate/Reject the value is
// ignored by the rules move, but callers still pass the claimed tier
// so the call shape is uniform.
func doVerdict(cur realm, actor address, f tavernrules.Finding, bounty tavernrules.Bounty, verdict uint8, finalSeverity uint8, reason string, duplicateOf uint64, height int64, arbiter bool) {
	others := othersOf(f.BountyID(), f.ID())
	original := verdictOriginal(duplicateOf)
	var p tavernrules.Payout
	if arbiter {
		p = f.ApplyVerdict(&bounty, actor, tavernrules.Verdict(verdict),
			tavernrules.Severity(finalSeverity), reason, duplicateOf, original, others, height)
	} else {
		p = f.SponsorVerdict(&bounty, actor, tavernrules.Verdict(verdict),
			tavernrules.Severity(finalSeverity), reason, duplicateOf, original, others, height)
	}
	saveFinding(f)
	saveBounty(bounty)
	executePayout(cur, p)
	if p.Due() {
		appendLedger(height, f.BountyID(), f.ID(), "payout", p.To, p.Amount, "verdict accepted")
	}
	chain.Emit("VerdictGiven",
		"finding_id", strconv.FormatUint(f.ID(), 10),
		"bounty_id", strconv.FormatUint(f.BountyID(), 10),
		"verdict", tavernrules.Verdict(verdict).String(),
		"by", actor.String())
	if p.Due() {
		chain.Emit("FindingPaid",
			"finding_id", strconv.FormatUint(f.ID(), 10),
			"bounty_id", strconv.FormatUint(f.BountyID(), 10),
			"to", p.To.String(),
			"amount", strconv.FormatInt(p.Amount, 10),
			"how", "accepted")
	}
}

// Verdict is the arbiter's decision on a Revealed finding, or the
// re-verdict on a Disputed finding (design §5.3). Only the bounty
// arbiter, only inside the review window (arbiter silence past the
// window hands the right to the sponsor — the move panics). Accept
// pays the FINAL tier price to the hunter in this transaction: the
// arbiter may correct the hunter's claimed severity up or down and
// the price follows the corrected tier (README deviation 20,
// resolved day 6). Duplicate and Reject pay nothing. Emits
// VerdictGiven (+ FindingPaid on Accept).
func Verdict(cur realm, findingID uint64, verdict uint8, finalSeverity uint8, reason string, duplicateOf uint64) {
	actor := requireUserCall(cur)
	requireNoCoins()
	height := runtime.ChainHeight()
	f := mustGetFinding(findingID)
	bounty := mustGetBounty(f.BountyID())
	if actor != bounty.Arbiter() {
		panic("only the bounty arbiter can give a verdict")
	}
	doVerdict(cur, actor, f, bounty, verdict, finalSeverity, reason, duplicateOf, height, true)
}

// SponsorVerdict is the sponsor's backup verdict (design §5.4). Only
// the bounty sponsor, only on a Revealed finding after the arbiter's
// review window and up to reviewDeadline + SponsorWindow (or the
// mirrored Disputed ladder). Same effects as Verdict, including the
// final-severity correction on Accept. Emits
// VerdictGiven (+ FindingPaid on Accept).
func SponsorVerdict(cur realm, findingID uint64, verdict uint8, finalSeverity uint8, reason string, duplicateOf uint64) {
	actor := requireUserCall(cur)
	requireNoCoins()
	height := runtime.ChainHeight()
	f := mustGetFinding(findingID)
	bounty := mustGetBounty(f.BountyID())
	if actor != bounty.Sponsor() {
		panic("only the sponsor can give a sponsor verdict")
	}
	doVerdict(cur, actor, f, bounty, verdict, finalSeverity, reason, duplicateOf, height, false)
}

// DisputeFinding protests a rejection (design §5.2). Only the hunter,
// only on a Rejected finding, only once, inside the dispute window.
// The finding becomes Disputed and awaits a re-verdict. Emits
// FindingDisputed.
func DisputeFinding(cur realm, findingID uint64, reason string) {
	hunter := requireUserCall(cur)
	requireNoCoins()
	height := runtime.ChainHeight()
	f := mustGetFinding(findingID)
	if hunter != f.Hunter() {
		panic("only the hunter can dispute")
	}
	f.Dispute(hunter, reason, height)
	saveFinding(f)
	chain.Emit("FindingDisputed",
		"finding_id", strconv.FormatUint(findingID, 10),
		"bounty_id", strconv.FormatUint(f.BountyID(), 10),
		"hunter", hunter.String())
}

// ClaimPayout is the hunter's last-resort claim (design §5.2, §6.3).
// Only the hunter, only on a Revealed finding once height is strictly
// past reviewDeadline + SponsorWindow (arbiter silent, then sponsor
// silent), or on a Disputed finding past the mirrored ladder. It pays
// the claimed tier price from the pool. Emits FindingPaid
// (how="timeout").
func ClaimPayout(cur realm, findingID uint64) {
	hunter := requireUserCall(cur)
	requireNoCoins()
	height := runtime.ChainHeight()
	f := mustGetFinding(findingID)
	bounty := mustGetBounty(f.BountyID())
	if hunter != f.Hunter() {
		panic("only the hunter can claim the payout")
	}
	others := othersOf(f.BountyID(), f.ID())
	p := f.ClaimPayout(&bounty, hunter, others, height)
	saveFinding(f)
	saveBounty(bounty)
	executePayout(cur, p)
	if p.Due() {
		appendLedger(height, f.BountyID(), f.ID(), "payout", p.To, p.Amount, "timeout claim")
	}
	if p.Due() {
		chain.Emit("FindingPaid",
			"finding_id", strconv.FormatUint(findingID, 10),
			"bounty_id", strconv.FormatUint(f.BountyID(), 10),
			"to", p.To.String(),
			"amount", strconv.FormatInt(p.Amount, 10),
			"how", "timeout")
	}
}

// CancelBounty cancels an Open bounty and refunds the remaining pool
// to the sponsor (design §5.1). Only the sponsor, only while no
// finding is in flight and no Rejected finding is still disputable.
// Emits BountyCancelled.
func CancelBounty(cur realm, bountyID uint64) {
	actor := requireUserCall(cur)
	requireNoCoins()
	height := runtime.ChainHeight()
	bounty := mustGetBounty(bountyID)
	if actor != bounty.Sponsor() {
		panic("only the sponsor can cancel a bounty")
	}
	p := tavernrules.CancelBounty(&bounty, actor, height, findingsOf(bountyID))
	saveBounty(bounty)
	executePayout(cur, p)
	if p.Due() {
		appendLedger(height, bountyID, 0, "refund", p.To, p.Amount, "bounty cancelled")
	}
	chain.Emit("BountyCancelled",
		"bounty_id", strconv.FormatUint(bountyID, 10),
		"refund", strconv.FormatInt(p.Amount, 10))
}

// CloseBounty closes an Open bounty after its deadline and refunds
// the remaining pool to the sponsor (design §5.1). Only the sponsor,
// only when height is strictly past the deadline, only while no
// finding is in flight and no Rejected finding is still disputable.
// Emits BountyClosed.
func CloseBounty(cur realm, bountyID uint64) {
	actor := requireUserCall(cur)
	requireNoCoins()
	height := runtime.ChainHeight()
	bounty := mustGetBounty(bountyID)
	if actor != bounty.Sponsor() {
		panic("only the sponsor can close a bounty")
	}
	p := tavernrules.CloseBounty(&bounty, actor, height, findingsOf(bountyID))
	saveBounty(bounty)
	executePayout(cur, p)
	if p.Due() {
		appendLedger(height, bountyID, 0, "refund", p.To, p.Amount, "bounty closed")
	}
	chain.Emit("BountyClosed",
		"bounty_id", strconv.FormatUint(bountyID, 10),
		"refund", strconv.FormatInt(p.Amount, 10))
}

// MarkFixed marks the audited realm fixed (design §5.1). Only the
// sponsor, only while the bounty is Open. Every Accepted finding of
// the bounty becomes Disclosed and appears on the public disclosure
// page. Emits BountyFixed.
func MarkFixed(cur realm, bountyID uint64) {
	actor := requireUserCall(cur)
	requireNoCoins()
	height := runtime.ChainHeight()
	bounty := mustGetBounty(bountyID)
	if actor != bounty.Sponsor() {
		panic("only the sponsor can mark a bounty fixed")
	}
	// Pointers to local copies: MarkFixedBounty mutates through them,
	// then each copy is persisted back to the tree.
	copies := findingsOf(bountyID)
	ptrs := make([]*tavernrules.Finding, len(copies))
	for i := range copies {
		ptrs[i] = &copies[i]
	}
	n := tavernrules.MarkFixedBounty(&bounty, actor, height, ptrs)
	for i := range copies {
		saveFinding(copies[i])
	}
	chain.Emit("BountyFixed",
		"bounty_id", strconv.FormatUint(bountyID, 10),
		"disclosed", strconv.Itoa(n))
}

// Totals is the realm-wide money summary. Locked is the sum of
// PoolLeft over all bounties — the internal truth of funds (design
// §3.1), NOT the realm's bank balance: stray coins sent via bank
// transfer are untracked by design.
type Totals struct {
	Bounties int
	Findings int
	Locked   int64
	PaidOut  int64
	Refunded int64
}

// GetTotals returns the realm-wide money summary.
func GetTotals() Totals {
	t := Totals{Bounties: bounties.Size(), Findings: findings.Size()}
	bounties.Iterate("", "", func(key string, value any) bool {
		if b, ok := value.(tavernrules.Bounty); ok {
			t.Locked += b.PoolLeft()
			t.PaidOut += b.PaidOut()
			t.Refunded += b.Refunded()
		}
		return false
	})
	return t
}

// ---------------------------------------------------------------------------
// Day-6 read getters (design §5.5). All are non-crossing (free via
// qeval), return value COPIES (never pointers into stored state),
// list newest-first, and paginate (offset/limit, limit clamped to
// 1..50, default 20). Render uses these; nothing here moves money.
// ---------------------------------------------------------------------------

// clampPage normalizes pagination arguments: limit defaults to 20
// and is capped at 50, a negative offset becomes 0.
func clampPage(offset, limit int) (int, int) {
	if limit <= 0 {
		limit = 20
	}
	if limit > 50 {
		limit = 50
	}
	if offset < 0 {
		offset = 0
	}
	return offset, limit
}

// ListBounties returns bounties newest-first (highest id first).
func ListBounties(offset, limit int) []tavernrules.Bounty {
	all := allBountiesDesc()
	offset, limit = clampPage(offset, limit)
	if offset >= len(all) {
		return nil
	}
	end := offset + limit
	if end > len(all) {
		end = len(all)
	}
	return all[offset:end]
}

// FindingsByBounty returns one bounty's findings newest-first.
func FindingsByBounty(bountyID uint64, offset, limit int) []tavernrules.Finding {
	var all []tavernrules.Finding
	for _, f := range allFindingsDesc() {
		if f.BountyID() == bountyID {
			all = append(all, f)
		}
	}
	offset, limit = clampPage(offset, limit)
	if offset >= len(all) {
		return nil
	}
	end := offset + limit
	if end > len(all) {
		end = len(all)
	}
	return all[offset:end]
}

// FindingsByHunter returns one hunter's findings newest-first.
func FindingsByHunter(addr address, offset, limit int) []tavernrules.Finding {
	var all []tavernrules.Finding
	for _, f := range allFindingsDesc() {
		if f.Hunter() == addr {
			all = append(all, f)
		}
	}
	offset, limit = clampPage(offset, limit)
	if offset >= len(all) {
		return nil
	}
	end := offset + limit
	if end > len(all) {
		end = len(all)
	}
	return all[offset:end]
}

// allBountiesDesc returns value copies of all bounties, newest-first.
func allBountiesDesc() []tavernrules.Bounty {
	var asc []tavernrules.Bounty
	bounties.Iterate("", "", func(key string, value any) bool {
		if b, ok := value.(tavernrules.Bounty); ok {
			asc = append(asc, b)
		}
		return false
	})
	for i, j := 0, len(asc)-1; i < j; i, j = i+1, j-1 {
		asc[i], asc[j] = asc[j], asc[i]
	}
	return asc
}

// allFindingsDesc returns value copies of all findings, newest-first.
func allFindingsDesc() []tavernrules.Finding {
	var asc []tavernrules.Finding
	findings.Iterate("", "", func(key string, value any) bool {
		if f, ok := value.(tavernrules.Finding); ok {
			asc = append(asc, f)
		}
		return false
	})
	for i, j := 0, len(asc)-1; i < j; i, j = i+1, j-1 {
		asc[i], asc[j] = asc[j], asc[i]
	}
	return asc
}

// allLedgerDesc returns value copies of all ledger entries,
// newest-first.
func allLedgerDesc() []LedgerEntry {
	var asc []LedgerEntry
	ledger.Iterate("", "", func(key string, value any) bool {
		if e, ok := value.(LedgerEntry); ok {
			asc = append(asc, e)
		}
		return false
	})
	for i, j := 0, len(asc)-1; i < j; i, j = i+1, j-1 {
		asc[i], asc[j] = asc[j], asc[i]
	}
	return asc
}

// tryGetBounty loads a bounty without panicking when the id is
// unknown (read getters must never panic on dangling references).
func tryGetBounty(id uint64) (tavernrules.Bounty, bool) {
	b, ok := bounties.Get(bountyKey(id)).(tavernrules.Bounty)
	return b, ok
}

// HunterStats returns one hunter's public reputation record
// (submitted/accepted/duplicates/rejected/earned), computed from
// the findings tree. Accepted counts Accepted + Disclosed findings;
// a Rejected finding still under dispute counts as rejected.
func HunterStats(addr address) tavernrules.HunterStats {
	if addr == "" {
		return tavernrules.HunterStats{}
	}
	s := tavernrules.NewHunterStats(addr)
	for _, f := range allFindingsDesc() {
		if f.Hunter() != addr {
			continue
		}
		s.RecordSubmitted()
		switch f.Status() {
		case tavernrules.FindingAccepted, tavernrules.FindingDisclosed:
			s.RecordAccepted(f.PaidAmount())
		case tavernrules.FindingDuplicate:
			s.RecordDuplicate()
		case tavernrules.FindingRejected, tavernrules.FindingDisputed:
			s.RecordRejected()
		}
	}
	return s
}

// hunterRankLess orders hunters for the leaderboard (design §4):
// accepted desc, earned desc, address asc (deterministic).
func hunterRankLess(a, b tavernrules.HunterStats) bool {
	if a.Accepted() != b.Accepted() {
		return a.Accepted() > b.Accepted()
	}
	if a.Earned() != b.Earned() {
		return a.Earned() > b.Earned()
	}
	return a.Addr().String() < b.Addr().String()
}

// TopHunters returns the top n hunters by rank (n <= 0 means 25,
// n is capped at 50). Hunters with no findings never appear.
func TopHunters(n int) []tavernrules.HunterStats {
	if n <= 0 {
		n = 25
	}
	if n > 50 {
		n = 50
	}
	seen := map[string]bool{}
	var addrs []address
	for _, f := range allFindingsDesc() {
		k := f.Hunter().String()
		if !seen[k] {
			seen[k] = true
			addrs = append(addrs, f.Hunter())
		}
	}
	stats := make([]tavernrules.HunterStats, 0, len(addrs))
	for _, a := range addrs {
		stats = append(stats, HunterStats(a))
	}
	for i := 0; i < len(stats); i++ {
		for j := i + 1; j < len(stats); j++ {
			if hunterRankLess(stats[j], stats[i]) {
				stats[i], stats[j] = stats[j], stats[i]
			}
		}
	}
	if len(stats) > n {
		stats = stats[:n]
	}
	return stats
}

// ArbiterStats returns one arbiter's public track record. Verdicts
// are counted from findings they decided (Accepted/Disclosed,
// Duplicate, Rejected/Disputed); a timeout is counted when a bounty
// they arbitrate was decided by someone else (sponsor verdict or
// hunter timeout claim) — i.e. their review right expired.
func ArbiterStats(addr address) tavernrules.ArbiterStats {
	if addr == "" {
		return tavernrules.ArbiterStats{}
	}
	s := tavernrules.NewArbiterStats(addr)
	for _, f := range allFindingsDesc() {
		if f.VerdictBy() == addr {
			accepted := f.Status() == tavernrules.FindingAccepted ||
				f.Status() == tavernrules.FindingDisclosed
			rejected := f.Status() == tavernrules.FindingRejected ||
				f.Status() == tavernrules.FindingDisputed
			duplicate := f.Status() == tavernrules.FindingDuplicate
			s.RecordVerdict(accepted, rejected, duplicate)
			continue
		}
		if f.VerdictBy() == "" {
			continue
		}
		b, ok := tryGetBounty(f.BountyID())
		if !ok || b.Arbiter() != addr {
			continue
		}
		switch f.Status() {
		case tavernrules.FindingAccepted, tavernrules.FindingDuplicate,
			tavernrules.FindingRejected, tavernrules.FindingDisclosed:
			s.RecordTimeout()
		}
	}
	return s
}

// arbiterRankLess orders arbiters for the leaderboard: verdicts
// desc, address asc (deterministic).
func arbiterRankLess(a, b tavernrules.ArbiterStats) bool {
	if a.Verdicts() != b.Verdicts() {
		return a.Verdicts() > b.Verdicts()
	}
	return a.Addr().String() < b.Addr().String()
}

// TopArbiters returns the top n arbiters by verdicts (n <= 0 means
// 25, n is capped at 25). Arbiters appear once they have decided a
// verdict or timed out on one.
func TopArbiters(n int) []tavernrules.ArbiterStats {
	if n <= 0 {
		n = 25
	}
	if n > 25 {
		n = 25
	}
	seen := map[string]bool{}
	var addrs []address
	for _, f := range allFindingsDesc() {
		if f.VerdictBy() != "" {
			k := f.VerdictBy().String()
			if !seen[k] {
				seen[k] = true
				addrs = append(addrs, f.VerdictBy())
			}
		}
		if b, ok := tryGetBounty(f.BountyID()); ok {
			k := b.Arbiter().String()
			if !seen[k] {
				seen[k] = true
				addrs = append(addrs, b.Arbiter())
			}
		}
	}
	stats := make([]tavernrules.ArbiterStats, 0, len(addrs))
	for _, a := range addrs {
		stats = append(stats, ArbiterStats(a))
	}
	for i := 0; i < len(stats); i++ {
		for j := i + 1; j < len(stats); j++ {
			if arbiterRankLess(stats[j], stats[i]) {
				stats[i], stats[j] = stats[j], stats[i]
			}
		}
	}
	if len(stats) > n {
		stats = stats[:n]
	}
	return stats
}

// GetLedger returns the money trail newest-first, paginated
// (design §8.6). Kind is "lock", "payout" or "refund".
func GetLedger(offset, limit int) []LedgerEntry {
	all := allLedgerDesc()
	offset, limit = clampPage(offset, limit)
	if offset >= len(all) {
		return nil
	}
	end := offset + limit
	if end > len(all) {
		end = len(all)
	}
	return all[offset:end]
}

// LedgerCount returns how many ledger entries exist.
func LedgerCount() int { return ledger.Size() }

// ExampleCommitment returns the commitment for the demo finding in
// design §6.4, proving the realm can use tavernrules.MakeCommitment
// (sha256.Sum256 + hex, gate-verified day 1).
func ExampleCommitment() string {
	return tavernrules.MakeCommitment(1, tavernrules.SevCritical,
		"Missing access control on Withdraw",
		"https://example.com/poc", "saltsaltsaltsalt")
}

// Render lives in render.gno (day 6, design §8): board, bounty and
// finding detail, hunter profile, leaderboard, ledger and help,
// with pagination and centralized sanitization (escape.gno).
