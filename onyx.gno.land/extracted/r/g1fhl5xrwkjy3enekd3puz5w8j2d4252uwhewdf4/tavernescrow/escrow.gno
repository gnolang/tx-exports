package tavernescrow

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"crypto/sha256"
	"encoding/hex"
	"strconv"
	"strings"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/seqid/v0"
	"gno.land/p/nt/ufmt/v0"
)

const genesisAuditDigest = "0000000000000000000000000000000000000000000000000000000000000000"

var (
	bountiesByID       *avl.Tree // key: padUint64Key(id) -> *Bounty
	auditsBySeq        *avl.Tree // key: padUint64Key(seq) -> *AuditEntry
	nextBountySeq      seqid.ID
	nextAuditSeq       seqid.ID
	latestAuditDigest  string
	totalFundedUgnot   int64
	totalLockedUgnot   int64
	totalReleasedUgnot int64
	totalRefundedUgnot int64
)

func init() {
	bountiesByID = avl.NewTree()
	auditsBySeq = avl.NewTree()
	latestAuditDigest = genesisAuditDigest
}

// CreateBounty creates and funds a milestone-based ugnot escrow bounty.
// Must be invoked directly by an EOA (MsgCall) attaching exact ugnot equal to sum(milestones).
func CreateBounty(
	cur realm,
	title string,
	summary string,
	arbiterStr string,
	workerStr string,
	milestoneTitlesCSV string,
	milestoneAmountsCSV string,
	expiryHeight int64,
) uint64 {
	// Security Guard (gno-security-guide.md §5.5): reject intermediary code realms
	// and ephemeral MsgRun scripts before inspecting unsafe.OriginSend().
	require(cur.Previous().IsUserCall(), "CreateBounty must be called directly by an EOA (maketx call)")

	sponsor := cur.Previous().Address()
	require(sponsor.IsValid(), "invalid sponsor address")

	cleanTitle := strings.TrimSpace(title)
	cleanSummary := strings.TrimSpace(summary)
	require(len(cleanTitle) >= 3 && len(cleanTitle) <= MaxTitleLen, "title must be 3..96 chars")
	require(len(cleanSummary) >= 5 && len(cleanSummary) <= MaxSummaryLen, "summary must be 5..512 chars")

	curHeight := runtime.ChainHeight()
	require(expiryHeight > curHeight, "expiryHeight must exceed current chain height")

	var arbiter address
	cleanArbiter := strings.TrimSpace(arbiterStr)
	if cleanArbiter != "" {
		arbiter = address(cleanArbiter)
		require(arbiter.IsValid(), "invalid arbiter address")
		require(arbiter != sponsor, "arbiter cannot be sponsor")
	}

	var worker address
	cleanWorker := strings.TrimSpace(workerStr)
	if cleanWorker != "" {
		worker = address(cleanWorker)
		require(worker.IsValid(), "invalid worker address")
		require(worker != sponsor, "worker cannot be sponsor")
		if arbiter != "" {
			require(worker != arbiter, "worker cannot be arbiter")
		}
	}

	rawTitles := strings.Split(milestoneTitlesCSV, ",")
	rawAmounts := strings.Split(milestoneAmountsCSV, ",")
	require(len(rawTitles) >= 1 && len(rawTitles) <= MaxMilestones, "milestones count must be 1..16")
	require(len(rawTitles) == len(rawAmounts), "milestone titles and amounts length mismatch")

	milestones := make([]Milestone, len(rawTitles))
	var totalRequired int64
	for i := 0; i < len(rawTitles); i++ {
		mTitle := strings.TrimSpace(rawTitles[i])
		require(len(mTitle) >= 2 && len(mTitle) <= MaxTitleLen, "each milestone title must be 2..96 chars")

		amt, err := strconv.ParseInt(strings.TrimSpace(rawAmounts[i]), 10, 64)
		require(err == nil && amt > 0, "each milestone amount must be a positive int64")

		totalRequired = safeAddInt64(totalRequired, amt)
		milestones[i] = Milestone{
			Index:        i,
			Title:        mTitle,
			AmountUgnot:  amt,
			Status:       MilestonePending,
			UpdatedAtBlk: curHeight,
		}
	}

	sent := unsafe.OriginSend()
	require(sent.AmountOf(DenomUgnot) == totalRequired, "sent ugnot must equal exact sum of milestones")

	bountyID := uint64(nextBountySeq.Next())
	initialStatus := StatusOpen
	if worker != "" {
		initialStatus = StatusActive
	}

	bounty := &Bounty{
		ID:           bountyID,
		Title:        cleanTitle,
		Summary:      cleanSummary,
		Sponsor:      sponsor,
		Worker:       worker,
		Arbiter:      arbiter,
		Status:       initialStatus,
		TotalFunded:  totalRequired,
		CreatedAtBlk: curHeight,
		ExpiryHeight: expiryHeight,
		DisputedIdx:  -1,
		Milestones:   milestones,
	}

	bountiesByID.Set(padUint64Key(bountyID), bounty)
	totalFundedUgnot = safeAddInt64(totalFundedUgnot, totalRequired)
	totalLockedUgnot = safeAddInt64(totalLockedUgnot, totalRequired)

	appendAudit("BOUNTY_CREATED", bountyID, -1, sponsor, totalRequired, cleanTitle)
	chain.Emit(
		"BountyCreated",
		"bounty_id", strconv.FormatUint(bountyID, 10),
		"sponsor", sponsor.String(),
		"worker", worker.String(),
		"arbiter", arbiter.String(),
		"funded_ugnot", strconv.FormatInt(totalRequired, 10),
	)
	return bountyID
}

// ClaimBounty assigns an open bounty to the calling builder address.
func ClaimBounty(cur realm, bountyID uint64) {
	require(cur.Previous().IsUserCall(), "ClaimBounty must be called by an EOA")
	caller := cur.Previous().Address()
	b := mustGetBounty(bountyID)

	require(b.Status == StatusOpen, "bounty is not open for claim")
	require(b.Worker == "", "bounty already assigned to a worker")
	require(runtime.ChainHeight() < b.ExpiryHeight, "bounty already expired")
	require(caller != b.Sponsor, "sponsor cannot claim own bounty")
	require(caller != b.Arbiter, "arbiter cannot claim assigned bounty")

	b.Worker = caller
	b.Status = StatusActive

	appendAudit("BOUNTY_CLAIMED", bountyID, -1, caller, 0, "worker claimed open bounty")
	chain.Emit(
		"BountyClaimed",
		"bounty_id", strconv.FormatUint(bountyID, 10),
		"worker", caller.String(),
	)
}

// SubmitMilestone submits deliverable URI and commit digest for review.
func SubmitMilestone(cur realm, bountyID uint64, milestoneIdx int, proofURI string, commitDigest string) {
	require(cur.Previous().IsUserCall(), "SubmitMilestone must be called by an EOA")
	caller := cur.Previous().Address()
	b := mustGetBounty(bountyID)

	require(b.Status == StatusActive, "bounty must be ACTIVE to submit milestone")
	require(caller == b.Worker, "only assigned worker can submit milestone")
	require(milestoneIdx >= 0 && milestoneIdx < len(b.Milestones), "milestone index out of range")

	m := &b.Milestones[milestoneIdx]
	require(m.Status == MilestonePending || m.Status == MilestoneRejected, "milestone not awaiting submission")

	cleanURI := strings.TrimSpace(proofURI)
	cleanDigest := strings.TrimSpace(commitDigest)
	require(len(cleanURI) >= 4 && len(cleanURI) <= MaxNoteLen, "proofURI must be 4..280 chars")
	require(len(cleanDigest) >= 7 && len(cleanDigest) <= 128, "commitDigest must be 7..128 chars")

	m.Status = MilestoneSubmitted
	m.ProofURI = cleanURI
	m.CommitDigest = cleanDigest
	m.FeedbackNote = ""
	m.UpdatedAtBlk = runtime.ChainHeight()

	appendAudit("MILESTONE_SUBMITTED", bountyID, milestoneIdx, caller, m.AmountUgnot, cleanURI)
	chain.Emit(
		"MilestoneSubmitted",
		"bounty_id", strconv.FormatUint(bountyID, 10),
		"milestone_idx", strconv.Itoa(milestoneIdx),
		"worker", caller.String(),
		"proof_uri", cleanURI,
	)
}

// ApproveAndRelease approves a submitted milestone and transfers locked ugnot to the worker.
func ApproveAndRelease(cur realm, bountyID uint64, milestoneIdx int) {
	require(cur.Previous().IsUserCall(), "ApproveAndRelease must be called by an EOA")
	caller := cur.Previous().Address()
	b := mustGetBounty(bountyID)

	require(b.Status == StatusActive, "bounty must be ACTIVE to approve milestone")
	require(caller == b.Sponsor, "only sponsor can approve and release milestone")
	require(b.Worker != "", "bounty has no assigned worker")
	require(milestoneIdx >= 0 && milestoneIdx < len(b.Milestones), "milestone index out of range")

	m := &b.Milestones[milestoneIdx]
	require(m.Status == MilestoneSubmitted, "milestone must be SUBMITTED before release")
	amount := m.AmountUgnot
	require(amount > 0 && amount <= b.lockedRemaining(), "insufficient locked bounty balance")

	// Checks-Effects-Interactions: commit all state mutations before external coin transfer.
	m.Status = MilestoneReleased
	m.UpdatedAtBlk = runtime.ChainHeight()
	b.ReleasedAmount = safeAddInt64(b.ReleasedAmount, amount)
	totalReleasedUgnot = safeAddInt64(totalReleasedUgnot, amount)
	totalLockedUgnot = safeSubInt64(totalLockedUgnot, amount)

	if b.allMilestonesTerminal() {
		b.Status = StatusCompleted
	}

	appendAudit("MILESTONE_RELEASED", bountyID, milestoneIdx, caller, amount, m.Title)

	realmAddr := cur.Address()
	banker_ := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	require(banker_.GetCoin(realmAddr, DenomUgnot) >= amount, "realm treasury deficit")
	banker_.SendCoins(realmAddr, b.Worker, chain.NewCoins(chain.NewCoin(DenomUgnot, amount)))

	chain.Emit(
		"MilestoneReleased",
		"bounty_id", strconv.FormatUint(bountyID, 10),
		"milestone_idx", strconv.Itoa(milestoneIdx),
		"recipient", b.Worker.String(),
		"amount_ugnot", strconv.FormatInt(amount, 10),
	)
}

// RejectMilestone returns a submitted milestone back to the worker with feedback.
func RejectMilestone(cur realm, bountyID uint64, milestoneIdx int, reason string) {
	require(cur.Previous().IsUserCall(), "RejectMilestone must be called by an EOA")
	caller := cur.Previous().Address()
	b := mustGetBounty(bountyID)

	require(b.Status == StatusActive, "bounty must be ACTIVE to reject milestone")
	require(caller == b.Sponsor, "only sponsor can reject milestone")
	require(milestoneIdx >= 0 && milestoneIdx < len(b.Milestones), "milestone index out of range")

	m := &b.Milestones[milestoneIdx]
	require(m.Status == MilestoneSubmitted, "milestone must be SUBMITTED to reject")

	cleanReason := strings.TrimSpace(reason)
	require(len(cleanReason) >= 3 && len(cleanReason) <= MaxNoteLen, "reason must be 3..280 chars")

	m.Status = MilestoneRejected
	m.FeedbackNote = cleanReason
	m.UpdatedAtBlk = runtime.ChainHeight()

	appendAudit("MILESTONE_REJECTED", bountyID, milestoneIdx, caller, 0, cleanReason)
	chain.Emit(
		"MilestoneRejected",
		"bounty_id", strconv.FormatUint(bountyID, 10),
		"milestone_idx", strconv.Itoa(milestoneIdx),
		"reason", cleanReason,
	)
}

// RaiseDispute freezes the bounty into DISPUTED state for neutral arbiter resolution.
func RaiseDispute(cur realm, bountyID uint64, milestoneIdx int, evidenceNote string) {
	require(cur.Previous().IsUserCall(), "RaiseDispute must be called by an EOA")
	caller := cur.Previous().Address()
	b := mustGetBounty(bountyID)

	require(b.Arbiter != "", "bounty has no arbiter configured")
	require(b.Status == StatusActive, "bounty must be ACTIVE to raise dispute")
	require(caller == b.Sponsor || caller == b.Worker, "only sponsor or worker can raise dispute")
	require(milestoneIdx >= 0 && milestoneIdx < len(b.Milestones), "milestone index out of range")

	m := &b.Milestones[milestoneIdx]
	require(
		m.Status == MilestoneSubmitted || m.Status == MilestoneRejected,
		"dispute requires SUBMITTED or REJECTED milestone",
	)

	cleanNote := strings.TrimSpace(evidenceNote)
	require(len(cleanNote) >= 4 && len(cleanNote) <= MaxNoteLen, "evidenceNote must be 4..280 chars")

	b.Status = StatusDisputed
	b.DisputedIdx = milestoneIdx
	m.FeedbackNote = cleanNote
	m.UpdatedAtBlk = runtime.ChainHeight()

	appendAudit("DISPUTE_RAISED", bountyID, milestoneIdx, caller, m.AmountUgnot, cleanNote)
	chain.Emit(
		"DisputeRaised",
		"bounty_id", strconv.FormatUint(bountyID, 10),
		"milestone_idx", strconv.Itoa(milestoneIdx),
		"raised_by", caller.String(),
	)
}

// ResolveDispute lets the designated arbiter release or refund the disputed milestone.
func ResolveDispute(cur realm, bountyID uint64, milestoneIdx int, releaseToWorker bool, resolutionNote string) {
	require(cur.Previous().IsUserCall(), "ResolveDispute must be called by an EOA")
	caller := cur.Previous().Address()
	b := mustGetBounty(bountyID)

	require(b.Status == StatusDisputed, "bounty is not in DISPUTED state")
	require(caller == b.Arbiter, "only configured arbiter can resolve dispute")
	require(milestoneIdx == b.DisputedIdx, "milestoneIdx does not match active disputed milestone")
	require(milestoneIdx >= 0 && milestoneIdx < len(b.Milestones), "milestone index out of range")

	cleanNote := strings.TrimSpace(resolutionNote)
	require(len(cleanNote) >= 4 && len(cleanNote) <= MaxNoteLen, "resolutionNote must be 4..280 chars")

	m := &b.Milestones[milestoneIdx]
	require(m.Status == MilestoneSubmitted || m.Status == MilestoneRejected, "disputed milestone already settled")
	amount := m.AmountUgnot
	require(amount > 0 && amount <= b.lockedRemaining(), "insufficient locked balance for resolution")

	var recipient address
	var action string
	if releaseToWorker {
		require(b.Worker != "", "cannot release without worker")
		m.Status = MilestoneReleased
		b.ReleasedAmount = safeAddInt64(b.ReleasedAmount, amount)
		totalReleasedUgnot = safeAddInt64(totalReleasedUgnot, amount)
		recipient = b.Worker
		action = "DISPUTE_RELEASED_WORKER"
	} else {
		m.Status = MilestoneRefunded
		b.RefundedAmount = safeAddInt64(b.RefundedAmount, amount)
		totalRefundedUgnot = safeAddInt64(totalRefundedUgnot, amount)
		recipient = b.Sponsor
		action = "DISPUTE_REFUNDED_SPONSOR"
	}

	m.FeedbackNote = cleanNote
	m.UpdatedAtBlk = runtime.ChainHeight()
	totalLockedUgnot = safeSubInt64(totalLockedUgnot, amount)
	b.DisputedIdx = -1

	if b.allMilestonesTerminal() {
		b.Status = StatusCompleted
	} else {
		b.Status = StatusActive
	}

	appendAudit(action, bountyID, milestoneIdx, caller, amount, cleanNote)

	realmAddr := cur.Address()
	banker_ := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	require(banker_.GetCoin(realmAddr, DenomUgnot) >= amount, "realm treasury deficit")
	banker_.SendCoins(realmAddr, recipient, chain.NewCoins(chain.NewCoin(DenomUgnot, amount)))

	chain.Emit(
		"DisputeResolved",
		"bounty_id", strconv.FormatUint(bountyID, 10),
		"milestone_idx", strconv.Itoa(milestoneIdx),
		"recipient", recipient.String(),
		"amount_ugnot", strconv.FormatInt(amount, 10),
	)
}

// ReclaimExpired lets the sponsor reclaim remaining unspent locked ugnot after expiryHeight.
// Blocked while an active dispute is pending arbiter resolution.
func ReclaimExpired(cur realm, bountyID uint64) int64 {
	require(cur.Previous().IsUserCall(), "ReclaimExpired must be called by an EOA")
	caller := cur.Previous().Address()
	b := mustGetBounty(bountyID)

	require(caller == b.Sponsor, "only sponsor can reclaim expired bounty")
	require(runtime.ChainHeight() >= b.ExpiryHeight, "bounty has not reached expiryHeight")
	require(b.Status == StatusOpen || b.Status == StatusActive, "cannot reclaim disputed, completed, or cancelled bounty")

	reclaimAmt := b.lockedRemaining()
	require(reclaimAmt > 0, "no locked ugnot remaining to reclaim")

	curHeight := runtime.ChainHeight()
	for i := range b.Milestones {
		if b.Milestones[i].Status != MilestoneReleased && b.Milestones[i].Status != MilestoneRefunded {
			b.Milestones[i].Status = MilestoneRefunded
			b.Milestones[i].UpdatedAtBlk = curHeight
		}
	}

	b.RefundedAmount = safeAddInt64(b.RefundedAmount, reclaimAmt)
	b.Status = StatusCancelled
	totalRefundedUgnot = safeAddInt64(totalRefundedUgnot, reclaimAmt)
	totalLockedUgnot = safeSubInt64(totalLockedUgnot, reclaimAmt)

	appendAudit("BOUNTY_EXPIRED_RECLAIMED", bountyID, -1, caller, reclaimAmt, "sponsor reclaimed expired locked funds")

	realmAddr := cur.Address()
	banker_ := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	require(banker_.GetCoin(realmAddr, DenomUgnot) >= reclaimAmt, "realm treasury deficit")
	banker_.SendCoins(realmAddr, b.Sponsor, chain.NewCoins(chain.NewCoin(DenomUgnot, reclaimAmt)))

	chain.Emit(
		"BountyReclaimed",
		"bounty_id", strconv.FormatUint(bountyID, 10),
		"sponsor", b.Sponsor.String(),
		"amount_ugnot", strconv.FormatInt(reclaimAmt, 10),
	)
	return reclaimAmt
}

// GetRealmStats returns a value-copied summary of realm accounting.
func GetRealmStats() RealmStats {
	return RealmStats{
		ChainID:            runtime.ChainID(),
		BlockHeight:        runtime.ChainHeight(),
		BountyCount:        bountiesByID.Size(),
		AuditCount:         auditsBySeq.Size(),
		TotalFundedUgnot:   totalFundedUgnot,
		TotalLockedUgnot:   totalLockedUgnot,
		TotalReleasedUgnot: totalReleasedUgnot,
		TotalRefundedUgnot: totalRefundedUgnot,
		LatestAuditDigest:  latestAuditDigest,
	}
}

// GetBountyView returns a defensive value copy of a bounty (never a mutable pointer).
func GetBountyView(bountyID uint64) BountyView {
	return mustGetBounty(bountyID).toView()
}

// GetBountySummary returns a deterministic single-line summary string for CLI queries.
func GetBountySummary(bountyID uint64) string {
	b := mustGetBounty(bountyID)
	return ufmt.Sprintf(
		"Bounty #%d | %s | status=%s | funded=%dugnot | released=%dugnot | refunded=%dugnot | locked=%dugnot | expiry=%d",
		b.ID,
		b.Title,
		string(b.Status),
		b.TotalFunded,
		b.ReleasedAmount,
		b.RefundedAmount,
		b.lockedRemaining(),
		b.ExpiryHeight,
	)
}

func mustGetBounty(bountyID uint64) *Bounty {
	b, ok := bountiesByID.Get(padUint64Key(bountyID)).(*Bounty)
	require(ok && b != nil, "bounty not found")
	return b
}

func appendAudit(action string, bountyID uint64, milestoneIdx int, actor address, amountUgnot int64, note string) {
	seq := uint64(nextAuditSeq.Next())
	height := runtime.ChainHeight()
	prev := latestAuditDigest

	payload := ufmt.Sprintf(
		"%s|%d|%d|%s|%d|%d|%s|%d|%s",
		prev,
		seq,
		height,
		action,
		bountyID,
		milestoneIdx,
		actor.String(),
		amountUgnot,
		note,
	)
	sum := sha256.Sum256([]byte(payload))
	digest := hex.EncodeToString(sum[:])

	entry := &AuditEntry{
		Seq:          seq,
		Height:       height,
		Action:       action,
		BountyID:     bountyID,
		MilestoneIdx: milestoneIdx,
		Actor:        actor,
		AmountUgnot:  amountUgnot,
		Note:         note,
		PrevDigest:   prev,
		Digest:       digest,
	}
	auditsBySeq.Set(padUint64Key(seq), entry)
	latestAuditDigest = digest
}
