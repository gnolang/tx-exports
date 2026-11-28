// Package tavernrules — state-machine moves (design §5, §6).
//
// This file holds every transition of the BugTavern protocol as pure
// logic: no coins, no chain, no storage. Each move receives the acting
// address and the current block height as plain arguments; the realm
// (day 5) supplies them from cur.Previous().Address() and
// runtime.ChainHeight(), and executes the returned Payout with
// SendCoins. Rules never touch a banker.
//
// Move discipline (design §7 T2/T10/T11):
//   - validate state and actor FIRST (wrong state / wrong actor panics),
//   - then mutate (CEI: state moves to final BEFORE any payout is built),
//   - then CheckInvariant (§4.2) — a violated invariant panics instead of
//     ever returning a corrupt state.
//
// All validation panics: in Gno a panic aborts the transaction, so a
// failed move can never leave a half-mutated bounty or finding behind.
//
// Windows (design §6.3) are block heights, computed by the helpers at
// the top of this file. All deadline additions are checked math: a
// height near MaxInt64 panics instead of wrapping.
package tavernrules

// ---------------------------------------------------------------------------
// Deadline helpers (design §6.3). Each returns the last height at which
// the action is still allowed, or the first height at which the next
// actor may act — see the comment on each function.
// ---------------------------------------------------------------------------

// addWindow returns height + window, panicking on int64 overflow
// instead of wrapping silently (design §7 T11).
func addWindow(height, window int64) int64 {
	v, ok := CheckedAdd(height, window)
	if !ok {
		panic("deadline height overflow")
	}
	return v
}

// RevealDeadlineAt is the last height at which a commit may be revealed.
func RevealDeadlineAt(committedAt int64) int64 {
	return addWindow(committedAt, RevealWindow)
}

// ReviewDeadlineAt is the last height at which the arbiter may give a
// verdict on a revealed finding.
func ReviewDeadlineAt(revealedAt int64) int64 {
	return addWindow(revealedAt, ReviewWindow)
}

// SponsorDeadlineAt is the last height at which the sponsor may give a
// verdict after the arbiter's review window has expired.
func SponsorDeadlineAt(reviewDeadline int64) int64 {
	return addWindow(reviewDeadline, SponsorWindow)
}

// ClaimableAfter is the height after which the hunter may claim the
// payout: height must be strictly greater than this value (arbiter
// window + sponsor window both fully elapsed).
func ClaimableAfter(reviewDeadline int64) int64 {
	return addWindow(reviewDeadline, SponsorWindow)
}

// DisputeDeadlineAt is the last height at which the hunter may dispute
// a rejection.
func DisputeDeadlineAt(verdictAt int64) int64 {
	return addWindow(verdictAt, DisputeWindow)
}

// DisclosureDeadlineAt is the height after which an Accepted finding
// becomes Disclosed automatically even without MarkFixed.
func DisclosureDeadlineAt(verdictAt int64) int64 {
	return addWindow(verdictAt, FixWindow)
}

// DisputeReviewDeadlineAt is the last height at which the arbiter may
// re-decide a Disputed finding (design §6.3 ladder applied to
// disputes: the arbiter gets ReviewWindow from the dispute height).
func DisputeReviewDeadlineAt(disputedAt int64) int64 {
	return addWindow(disputedAt, ReviewWindow)
}

// DisputeClaimableAfter is the height after which the hunter may claim
// a Disputed finding: height must be strictly greater than this value
// (arbiter dispute-review window + sponsor window both fully elapsed).
func DisputeClaimableAfter(disputedAt int64) int64 {
	return addWindow(DisputeReviewDeadlineAt(disputedAt), SponsorWindow)
}

// ---------------------------------------------------------------------------
// Helpers shared by the moves.
// ---------------------------------------------------------------------------

// IsInFlight reports whether a finding blocks Cancel/Close: a finding
// is in flight while it is Committed, Revealed, or Disputed. A Rejected
// finding is NOT in flight by status, but it still blocks Cancel/Close
// while it is disputable — see AnyDisputable. Expired, Accepted,
// Duplicate, Rejected-past-window and Disclosed findings never block.
func IsInFlight(s FindingStatus) bool {
	switch s {
	case FindingCommitted, FindingRevealed, FindingDisputed:
		return true
	default:
		return false
	}
}

// AnyDisputable reports whether any finding in the slice is a Rejected
// finding whose dispute window is still open at height (not yet
// disputed, height not past verdictAt + DisputeWindow). Such a finding
// blocks Cancel/Close: cancelling first would strand the hunter's
// one dispute, since a re-verdict needs an Open bounty.
func AnyDisputable(findings []Finding, height int64) bool {
	for _, f := range findings {
		if f.Status() != FindingRejected || f.DisputedBefore() {
			continue
		}
		if height <= DisputeDeadlineAt(f.VerdictAt()) {
			return true
		}
	}
	return false
}

// AnyInFlight reports whether any finding in the slice is in flight.
func AnyInFlight(findings []Finding) bool {
	for _, f := range findings {
		if IsInFlight(f.Status()) {
			return true
		}
	}
	return false
}

// TierAlreadyPaid reports whether a severity tier has already been paid
// for this bounty (design §5.6: each tier pays at most once, first
// valid finding per tier). Callers pass the OTHER findings of the
// bounty — the finding being decided must not be in the slice.
func TierAlreadyPaid(findings []Finding, bountyID uint64, sev Severity) bool {
	for _, f := range findings {
		if f.BountyID() != bountyID {
			continue
		}
		if f.SeverityFinal() != sev {
			continue
		}
		if f.Status() == FindingAccepted || f.Status() == FindingDisclosed {
			return true
		}
	}
	return false
}

// checkBountyInvariant panics when a bounty violates §4.2.
func checkBountyInvariant(b *Bounty) {
	if msg := b.CheckInvariant(); msg != "" {
		panic("bounty invariant violated: " + msg)
	}
}

// checkFindingInvariant panics when a finding violates §4.2.
func checkFindingInvariant(f *Finding) {
	if msg := f.CheckInvariant(); msg != "" {
		panic("finding invariant violated: " + msg)
	}
}

// checkBoth panics when either side of a move violates §4.2.
func checkBoth(b *Bounty, f *Finding) {
	checkBountyInvariant(b)
	checkFindingInvariant(f)
}

// ---------------------------------------------------------------------------
// Verdict — the arbiter/sponsor decision on a revealed finding.
// ---------------------------------------------------------------------------

// Verdict is the decision an arbiter (or the sponsor, as backup) gives.
type Verdict uint8

const (
	VerdictAccept Verdict = iota + 1
	VerdictDuplicate
	VerdictReject
)

// Valid reports whether v is one of the three verdicts.
func (v Verdict) Valid() bool {
	return v >= VerdictAccept && v <= VerdictReject
}

// String returns the verdict name.
func (v Verdict) String() string {
	switch v {
	case VerdictAccept:
		return "Accept"
	case VerdictDuplicate:
		return "Duplicate"
	case VerdictReject:
		return "Reject"
	default:
		return "Unknown"
	}
}

// ---------------------------------------------------------------------------
// Bounty moves.
// ---------------------------------------------------------------------------

// TopUp adds amount to the bounty pool (poolTotal and poolLeft grow by
// the same amount). Only an Open bounty can be topped up. The realm
// must have already received exactly `amount` ugnot with the call.
func (b *Bounty) TopUp(amount int64) {
	if b.status != BountyOpen {
		panic("top-up only on an Open bounty")
	}
	if amount <= 0 {
		panic("top-up amount must be positive")
	}
	total, ok := CheckedAdd(b.poolTotal, amount)
	if !ok {
		panic("top-up overflows pool total")
	}
	left, ok := CheckedAdd(b.poolLeft, amount)
	if !ok {
		panic("top-up overflows pool left")
	}
	b.poolTotal = total
	b.poolLeft = left
	checkBountyInvariant(b)
}

// CancelBounty cancels an Open bounty and refunds the remaining pool to
// the sponsor. Only the sponsor may cancel, and only while no finding
// is in flight and no Rejected finding is still disputable at height.
// It returns the refund payout the realm must execute
// (zero Payout when nothing is left to refund).
func CancelBounty(b *Bounty, actor address, height int64, findings []Finding) Payout {
	if actor != b.sponsor {
		panic("only the sponsor can cancel a bounty")
	}
	if b.status != BountyOpen {
		panic("only an Open bounty can be cancelled")
	}
	if AnyInFlight(findings) {
		panic("cannot cancel with findings in flight")
	}
	if AnyDisputable(findings, height) {
		panic("cannot cancel while a rejected finding can still be disputed")
	}
	var p Payout
	if b.poolLeft > 0 {
		p = b.RecordRefund(b.sponsor, b.poolLeft)
	}
	b.Cancel()
	checkBountyInvariant(b)
	return p
}

// CloseBounty closes an Open bounty after its deadline and refunds the
// remaining pool to the sponsor. Only the sponsor may close, only when
// height is strictly past the deadline, and only while no finding is
// in flight and no Rejected finding is still disputable at height.
// It returns the refund payout the realm must execute
// (zero Payout when nothing is left to refund).
func CloseBounty(b *Bounty, actor address, height int64, findings []Finding) Payout {
	if actor != b.sponsor {
		panic("only the sponsor can close a bounty")
	}
	if b.status != BountyOpen {
		panic("only an Open bounty can be closed")
	}
	if height <= b.deadline {
		panic("cannot close before the bounty deadline")
	}
	if AnyInFlight(findings) {
		panic("cannot close with findings in flight")
	}
	if AnyDisputable(findings, height) {
		panic("cannot close while a rejected finding can still be disputed")
	}
	var p Payout
	if b.poolLeft > 0 {
		p = b.RecordRefund(b.sponsor, b.poolLeft)
	}
	b.Close()
	checkBountyInvariant(b)
	return p
}

// MarkFixedBounty marks the audited realm fixed: every Accepted finding
// of this bounty becomes Disclosed and appears on the public
// disclosure page. Only the sponsor, only while the bounty is Open.
// It returns how many findings were disclosed.
func MarkFixedBounty(b *Bounty, actor address, height int64, findings []*Finding) int {
	if actor != b.sponsor {
		panic("only the sponsor can mark a bounty fixed")
	}
	if b.status != BountyOpen {
		panic("only an Open bounty can be marked fixed")
	}
	n := 0
	for _, f := range findings {
		if f == nil {
			panic("nil finding in list")
		}
		if f.BountyID() != b.id {
			panic("finding belongs to another bounty")
		}
		if f.Status() == FindingAccepted {
			f.MarkDisclosed(height)
			n++
		}
	}
	checkBountyInvariant(b)
	return n
}

// ---------------------------------------------------------------------------
// Finding moves.
// ---------------------------------------------------------------------------

// CommitFinding records a hunter's hash commitment against an Open
// bounty. It panics unless the bounty is Open, height is not past the
// bounty deadline, the hash is a valid 64-hex digest, and no OTHER
// finding on the same bounty already carries this exact hash —
// EXCEPT an Expired one (design §7 T3: copying another hunter's
// visible commit hash must not squat the finding — the copycat cannot
// reveal without the salt, and the hash check rejects the squat
// outright). The block covers decided findings too: once a finding
// is Revealed its salt is public, so a copycat could otherwise
// re-commit the identical hash and, if the arbiter corrected the
// tier, be paid for the same bug a second time at another tier.
// An Expired finding does not block a fresh commit of the same hash:
// the hunter re-commits with a new salt. The reveal deadline is
// height + RevealWindow.
func CommitFinding(b *Bounty, others []Finding, id uint64, hunter address, severity Severity, commitHash string, height int64) Finding {
	if b.status != BountyOpen {
		panic("cannot commit to a bounty that is not Open")
	}
	if height > b.deadline {
		panic("cannot commit after the bounty deadline")
	}
	for _, o := range others {
		if o.BountyID() != b.id || o.CommitHash() != commitHash {
			continue
		}
		if o.Status() != FindingExpired {
			panic("commit hash already in use by another finding on this bounty")
		}
	}
	f := NewFinding(id, b.id, hunter, severity, commitHash, height, RevealDeadlineAt(height))
	checkFindingInvariant(&f)
	return f
}

// Reveal discloses a committed finding: the hunter supplies the title,
// PoC URL and salt, the commitment is recomputed with MakeCommitment
// and must match the stored hash exactly, or the call panics. Only
// the committing hunter, only while Committed, only up to the reveal
// deadline, and only on an Open bounty. On success the finding is
// Revealed and the review deadline is height + ReviewWindow.
func (f *Finding) Reveal(b *Bounty, actor address, title, pocURL, salt string, height int64) {
	if b.id != f.bountyID {
		panic("finding does not belong to this bounty")
	}
	if b.status != BountyOpen {
		panic("cannot reveal on a bounty that is not Open")
	}
	if actor != f.hunter {
		panic("only the hunter who committed can reveal")
	}
	if f.status != FindingCommitted {
		panic("only a Committed finding can be revealed")
	}
	if height > f.revealDeadline {
		panic("reveal deadline has passed")
	}
	if msg := ValidateReveal(title, pocURL, salt); msg != "" {
		panic(msg)
	}
	if MakeCommitment(f.bountyID, f.severity, title, pocURL, salt) != f.commitHash {
		panic("commitment mismatch: revealed contents do not match the commit hash")
	}
	f.title = title
	f.pocURL = pocURL
	f.revealedAt = height
	f.reviewDeadline = ReviewDeadlineAt(height)
	f.status = FindingRevealed
	checkFindingInvariant(f)
}

// ExpireCommit lapses a commit that was never revealed: only a
// Committed finding, only once height is strictly past its reveal
// deadline. The finding becomes Expired (final) and can never be
// revealed; it no longer blocks Cancel/Close. Expiry is also enforced
// implicitly — Reveal panics past the deadline — this move just makes
// the lapse explicit and final.
func (f *Finding) ExpireCommit(height int64) {
	if f.status != FindingCommitted {
		panic("only a Committed finding can expire")
	}
	if height <= f.revealDeadline {
		panic("reveal deadline has not passed yet")
	}
	f.status = FindingExpired
	checkFindingInvariant(f)
}

// ApplyVerdict is the arbiter's verdict on a Revealed finding, or the
// re-verdict on a Disputed finding. From Revealed the arbiter must
// decide by the review deadline — after that the right passes to the
// sponsor (see SponsorVerdict) and the arbiter panics. From Disputed
// the arbiter must re-decide by disputedAt + ReviewWindow — after
// that the right passes to the sponsor the same way. Accept pays the
// final tier price from the pool (CEI: the finding moves to Accepted
// first); Duplicate and Reject pay nothing.
func (f *Finding) ApplyVerdict(b *Bounty, by address, v Verdict, finalSeverity Severity, reason string, duplicateOf uint64, original *Finding, others []Finding, height int64) Payout {
	return f.doVerdict(b, by, v, finalSeverity, reason, duplicateOf, original, others, height, true)
}

// SponsorVerdict is the sponsor's backup verdict: only the sponsor,
// only on a Revealed finding (after the arbiter's review window and
// up to reviewDeadline + SponsorWindow), or on a Disputed finding
// (after the arbiter's dispute-review window and up to
// disputedAt + ReviewWindow + SponsorWindow). After those windows
// the hunter may claim the payout directly (see ClaimPayout).
func (f *Finding) SponsorVerdict(b *Bounty, by address, v Verdict, finalSeverity Severity, reason string, duplicateOf uint64, original *Finding, others []Finding, height int64) Payout {
	return f.doVerdict(b, by, v, finalSeverity, reason, duplicateOf, original, others, height, false)
}

// doVerdict is the shared verdict core. arbiter=true enforces the
// arbiter's actor + review window; arbiter=false enforces the
// sponsor's actor + sponsor window.
func (f *Finding) doVerdict(b *Bounty, by address, v Verdict, finalSeverity Severity, reason string, duplicateOf uint64, original *Finding, others []Finding, height int64, arbiter bool) Payout {
	if b.id != f.bountyID {
		panic("finding does not belong to this bounty")
	}
	if b.status != BountyOpen {
		panic("cannot give a verdict on a bounty that is not Open")
	}
	if !v.Valid() {
		panic("invalid verdict")
	}
	if len(reason) > MaxReasonLen {
		panic("verdict reason must be at most 300 characters")
	}
	if arbiter {
		if by != b.arbiter {
			panic("only the bounty arbiter can give a verdict")
		}
		if f.status == FindingRevealed {
			if height > f.reviewDeadline {
				panic("arbiter review window has expired; the sponsor decides now")
			}
		} else if f.status == FindingDisputed {
			if height > DisputeReviewDeadlineAt(f.disputedAt) {
				panic("arbiter dispute-review window has expired; the sponsor decides now")
			}
		} else {
			panic("verdict requires a Revealed or Disputed finding")
		}
	} else {
		if by != b.sponsor {
			panic("only the sponsor can give a sponsor verdict")
		}
		if f.status == FindingRevealed {
			if height <= f.reviewDeadline {
				panic("sponsor verdict only after the arbiter review window")
			}
			if height > SponsorDeadlineAt(f.reviewDeadline) {
				panic("sponsor verdict window has expired; the hunter may claim")
			}
		} else if f.status == FindingDisputed {
			if height <= DisputeReviewDeadlineAt(f.disputedAt) {
				panic("sponsor verdict only after the arbiter dispute-review window")
			}
			if height > DisputeClaimableAfter(f.disputedAt) {
				panic("sponsor verdict window has expired; the hunter may claim")
			}
		} else {
			panic("sponsor verdict requires a Revealed or Disputed finding")
		}
	}
	switch v {
	case VerdictAccept:
		return f.doAccept(b, by, finalSeverity, reason, others, height)
	case VerdictDuplicate:
		f.doDuplicate(b, by, reason, duplicateOf, original, height)
		return Payout{}
	case VerdictReject:
		f.doReject(b, by, reason, height)
		return Payout{}
	default:
		panic("invalid verdict")
	}
}

// doAccept pays the final tier price to the hunter. The arbiter may
// correct the hunter's claimed severity up or down; the price follows
// the FINAL tier. It panics when the decider is the hunter
// themselves (an arbiter or sponsor must never pay themselves from
// the sponsor's pool), when the tier was already paid for this
// bounty (§5.6), or the pool cannot cover the tier price.
func (f *Finding) doAccept(b *Bounty, by address, finalSeverity Severity, reason string, others []Finding, height int64) Payout {
	if by == f.hunter {
		panic("the decider cannot accept their own finding")
	}
	if !finalSeverity.Valid() {
		panic("final severity must be a valid tier")
	}
	if b.TierPaid(finalSeverity) {
		panic("this severity tier has already been paid for this bounty")
	}
	if TierAlreadyPaid(others, f.bountyID, finalSeverity) {
		panic("this severity tier has already been paid for this bounty")
	}
	price := b.PriceFor(finalSeverity)
	if price <= 0 {
		panic("final severity has no configured price")
	}
	if price > b.poolLeft {
		panic("pool left is below the tier price")
	}
	// CEI: finding to its final state first, then the bounty payout.
	f.severityFinal = finalSeverity
	f.verdictBy = by
	f.verdictAt = height
	f.verdictReason = reason
	f.paidAmount = price
	f.status = FindingAccepted
	p := b.RecordPayout(f.hunter, finalSeverity, price)
	checkBoth(b, f)
	return p
}

// doDuplicate marks the finding a duplicate of an earlier finding. The
// original must be a different finding on the same bounty, committed
// strictly earlier — or in the same block with a lower id (finding
// ids are assigned in commit order, so a lower id is the earlier
// commit inside one block) — and currently Revealed, Accepted or
// Disclosed. No money moves.
func (f *Finding) doDuplicate(b *Bounty, by address, reason string, duplicateOf uint64, original *Finding, height int64) {
	if duplicateOf == 0 {
		panic("duplicate verdict requires the original finding id")
	}
	if original == nil {
		panic("duplicate verdict requires the original finding")
	}
	if original.ID() != duplicateOf {
		panic("duplicateOf does not match the original finding")
	}
	if original.BountyID() != f.bountyID {
		panic("original finding belongs to another bounty")
	}
	if original.ID() == f.id {
		panic("a finding cannot duplicate itself")
	}
	if original.CommittedAt() > f.committedAt {
		panic("original finding must have been committed earlier")
	}
	if original.CommittedAt() == f.committedAt && original.ID() > f.id {
		panic("original finding must have the lower id when committed in the same block")
	}
	switch original.Status() {
	case FindingRevealed, FindingAccepted, FindingDisclosed:
	default:
		panic("original finding must be Revealed, Accepted or Disclosed")
	}
	f.verdictBy = by
	f.verdictAt = height
	f.verdictReason = reason
	f.duplicateOf = duplicateOf
	f.status = FindingDuplicate
	b.RecordDuplicate()
	checkBoth(b, f)
}

// doReject rejects the finding. A reason is mandatory (<= 300 chars)
// and stays public. The hunter may dispute once, inside the dispute
// window (see Dispute).
func (f *Finding) doReject(b *Bounty, by address, reason string, height int64) {
	if len(reason) == 0 {
		panic("reject verdict requires a reason")
	}
	f.verdictBy = by
	f.verdictAt = height
	f.verdictReason = reason
	f.status = FindingRejected
	b.RecordRejected()
	checkBoth(b, f)
}

// Dispute protests a rejection. Only the hunter, only once per finding,
// only inside DisputeWindow blocks after the verdict. The finding
// becomes Disputed and awaits a re-verdict from the arbiter.
func (f *Finding) Dispute(actor address, reason string, height int64) {
	if actor != f.hunter {
		panic("only the hunter can dispute")
	}
	if f.status != FindingRejected {
		panic("only a Rejected finding can be disputed")
	}
	if f.disputed {
		panic("a finding can be disputed only once")
	}
	if height < f.verdictAt {
		panic("dispute height is before the verdict")
	}
	if height > DisputeDeadlineAt(f.verdictAt) {
		panic("dispute window has expired")
	}
	if len(reason) == 0 || len(reason) > MaxReasonLen {
		panic("dispute reason must be 1-300 characters")
	}
	f.disputed = true
	f.disputeReason = reason
	f.disputedAt = height
	f.status = FindingDisputed
	checkFindingInvariant(f)
}

// ClaimPayout is the hunter's last-resort claim: only the hunter, only
// on a Revealed finding (once height is strictly past
// reviewDeadline + SponsorWindow — arbiter silent, then sponsor
// silent) or on a Disputed finding (once height is strictly past
// disputedAt + ReviewWindow + SponsorWindow — arbiter silent on the
// re-verdict, then sponsor silent). It pays the CLAIMED tier price
// from the pool — the hunter's own severity claim, since nobody
// corrected it — and moves the finding to Accepted. It panics when
// the tier was already paid or the pool cannot cover the tier price.
func (f *Finding) ClaimPayout(b *Bounty, actor address, others []Finding, height int64) Payout {
	if b.id != f.bountyID {
		panic("finding does not belong to this bounty")
	}
	if b.status != BountyOpen {
		panic("cannot claim a payout on a bounty that is not Open")
	}
	if actor != f.hunter {
		panic("only the hunter can claim the payout")
	}
	if f.status != FindingRevealed && f.status != FindingDisputed {
		panic("only a Revealed or Disputed finding can be claimed")
	}
	if f.status == FindingRevealed {
		if height <= ClaimableAfter(f.reviewDeadline) {
			panic("claim window has not opened: arbiter and sponsor may still decide")
		}
	} else {
		if height <= DisputeClaimableAfter(f.disputedAt) {
			panic("claim window has not opened: arbiter and sponsor may still decide the dispute")
		}
	}
	if b.TierPaid(f.severity) {
		panic("this severity tier has already been paid for this bounty")
	}
	if TierAlreadyPaid(others, f.bountyID, f.severity) {
		panic("this severity tier has already been paid for this bounty")
	}
	price := b.PriceFor(f.severity)
	if price <= 0 {
		panic("claimed severity has no configured price")
	}
	if price > b.poolLeft {
		panic("pool left is below the tier price")
	}
	// CEI: finding to its final state first, then the bounty payout.
	f.severityFinal = f.severity
	f.verdictBy = actor
	f.verdictAt = height
	f.verdictReason = "timeout: arbiter and sponsor silent"
	f.paidAmount = price
	f.status = FindingAccepted
	p := b.RecordPayout(f.hunter, f.severity, price)
	checkBoth(b, f)
	return p
}

// MarkDisclosed moves an Accepted finding to Disclosed (public
// disclosure page). Called by MarkFixedBounty, or by the realm for a
// single finding.
func (f *Finding) MarkDisclosed(height int64) {
	if f.status != FindingAccepted {
		panic("only an Accepted finding can be disclosed")
	}
	f.status = FindingDisclosed
	f.disclosedAt = height
	checkFindingInvariant(f)
}

// AutoDisclose moves an Accepted finding to Disclosed once the fix
// window has elapsed (height strictly past verdictAt + FixWindow),
// even when the sponsor never called MarkFixed.
func (f *Finding) AutoDisclose(height int64) {
	if f.status != FindingAccepted {
		panic("only an Accepted finding can be auto-disclosed")
	}
	if height <= DisclosureDeadlineAt(f.verdictAt) {
		panic("fix window has not expired")
	}
	f.status = FindingDisclosed
	f.disclosedAt = height
	checkFindingInvariant(f)
}
