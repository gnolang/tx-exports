package bountysiege

import (
	"strconv"
	"strings"
	"time"

	"gno.land/p/g1fn0l3ms5puafp37r7v67mx2msjl0ztnyq3a9yv/bs_core"
	"gno.land/r/g1fn0l3ms5puafp37r7v67mx2msjl0ztnyq3a9yv/siege_rep"
)

var (
	nextQuestID uint64
	questsByID  = map[uint64]*Quest{}
	questIDs    []uint64
)

// CreateQuest creates a new Single-Claim Quest and escrows exact `reward` ugnot.
func CreateQuest(
	cur realm,
	title, description, criteria string,
	cat uint8,
	reward, stake int64,
	openDur, workDur, reviewDur int64,
) uint64 {
	requireRolesInitialized()
	requireExactUgnot(reward, cur)

	if err := bs_core.ValidateStakeBounds(reward, stake); err != nil {
		panic(err.Error())
	}
	if err := bs_core.ValidateQuestDurations(openDur, workDur, reviewDur); err != nil {
		panic(err.Error())
	}
	category := bs_core.Category(cat)
	if !category.IsValid() {
		panic("invalid skill category")
	}
	if err := bs_core.ValidateText(title, bs_core.MaxTitleBytes, true, false); err != nil {
		panic("invalid title: " + err.Error())
	}
	if err := bs_core.ValidateText(description, bs_core.MaxDescBytes, true, true); err != nil {
		panic("invalid description: " + err.Error())
	}
	if err := bs_core.ValidateText(criteria, bs_core.MaxCriteriaBytes, true, true); err != nil {
		panic("invalid acceptance criteria: " + err.Error())
	}

	sponsor := cur.Previous().Address()
	now := time.Now().Unix()

	nextQuestID++
	id := nextQuestID
	q := &Quest{
		ID:               id,
		Sponsor:          sponsor,
		Title:            strings.TrimSpace(title),
		Description:      strings.TrimSpace(description),
		Criteria:         strings.TrimSpace(criteria),
		Category:         category,
		Reward:           reward,
		Stake:            stake,
		OpenDuration:     openDur,
		WorkDuration:     workDur,
		ReviewDuration:   reviewDur,
		CreatedAt:        now,
		OpenDeadline:     now + openDur,
		Status:           bs_core.QuestOpen,
		EscrowHeld:       reward,
		ActiveAttemptIdx: -1,
	}
	q.addEvent(now, sponsor, "CREATED", "reward="+strconv.FormatInt(reward, 10)+"ugnot stake="+strconv.FormatInt(stake, 10)+"ugnot")

	questsByID[id] = q
	questIDs = append(questIDs, id)
	totalActiveEscrow += reward
	return id
}

// CancelQuest cancels an Open Quest (no active claimer) and refunds 100% reward to sponsor.
// Strictly forbidden during InProgress, RevisionRequested, or UnderReview.
func CancelQuest(cur realm, questID uint64) {
	requireNonPayableEOA(0, cur)
	q := mustGetQuest(questID)
	cancelQuestCore(q, cur)
}

func cancelQuestCore(q *Quest, rlm realm) {
	caller := rlm.Previous().Address()
	if caller != q.Sponsor {
		panic("unauthorized: only sponsor can cancel quest")
	}
	if q.Status != bs_core.QuestOpen {
		panic("cannot cancel quest unless status is Open")
	}
	refund := q.Reward
	q.Status = bs_core.QuestCancelled
	q.EscrowHeld -= refund
	totalActiveEscrow -= refund
	q.addEvent(time.Now().Unix(), caller, "CANCELLED", "refund="+strconv.FormatInt(refund, 10)+"ugnot")

	sendUgnot(q.Sponsor, refund, rlm)
}

// ExpireOpenQuest allows anyone to expire an Open Quest after openDeadline,
// refunding 100% reward to sponsor without protocol fee.
func ExpireOpenQuest(cur realm, questID uint64) {
	requireNonPayableEOA(0, cur)
	q := mustGetQuest(questID)
	expireOpenQuestCore(q, cur)
}

func expireOpenQuestCore(q *Quest, rlm realm) {
	if q.Status != bs_core.QuestOpen {
		panic("quest is not Open")
	}
	now := time.Now().Unix()
	if now <= q.OpenDeadline {
		panic("openDeadline has not elapsed yet")
	}
	refund := q.Reward
	q.Status = bs_core.QuestCancelled
	q.EscrowHeld -= refund
	totalActiveEscrow -= refund
	q.addEvent(now, rlm.Previous().Address(), "EXPIRED_OPEN", "refund="+strconv.FormatInt(refund, 10)+"ugnot")

	sendUgnot(q.Sponsor, refund, rlm)
}

// ClaimQuest locks the exact anti-squatter Stake from a builder and transitions Open -> InProgress.
func ClaimQuest(cur realm, questID uint64) {
	q := mustGetQuest(questID)
	claimQuestCore(q, cur)
}

func claimQuestCore(q *Quest, rlm realm) {
	requireExactUgnot(q.Stake, rlm)
	if q.Status != bs_core.QuestOpen {
		panic("quest is not Open for claiming")
	}
	now := time.Now().Unix()
	if now > q.OpenDeadline {
		panic("quest openDeadline has passed")
	}
	builder := rlm.Previous().Address()
	if builder == q.Sponsor {
		panic("self-dealing forbidden: sponsor cannot claim own quest")
	}
	if isExcludedWorkerRole(builder) {
		panic("arbiter and treasury addresses cannot act as builders")
	}

	attempt := QuestAttempt{
		Builder:      builder,
		ClaimedAt:    now,
		WorkDeadline: now + q.WorkDuration,
		Outcome:      bs_core.AttemptActive,
	}
	q.Attempts = append(q.Attempts, attempt)
	q.ActiveAttemptIdx = len(q.Attempts) - 1
	q.Status = bs_core.QuestInProgress
	q.EscrowHeld += q.Stake
	totalActiveEscrow += q.Stake
	q.addEvent(now, builder, "CLAIMED", "stake="+strconv.FormatInt(q.Stake, 10)+"ugnot")
}

// ExpireClaim allows anyone to slash a no-show builder's stake (100% to Treasury)
// if workDeadline passes during initial InProgress (before any submission) and reopen the quest.
func ExpireClaim(cur realm, questID uint64) {
	requireNonPayableEOA(0, cur)
	q := mustGetQuest(questID)
	expireClaimCore(q, cur)
}

func expireClaimCore(q *Quest, rlm realm) {
	if q.Status != bs_core.QuestInProgress {
		panic("ExpireClaim only applies to InProgress (no-show before first submission)")
	}
	att := q.activeAttempt()
	if att == nil {
		panic("missing active attempt")
	}
	now := time.Now().Unix()
	if now <= att.WorkDeadline {
		panic("workDeadline has not elapsed yet")
	}

	builder := att.Builder
	slashed := q.Stake

	// Checks-Effects-Interactions (append-only: ActiveAttemptIdx = -1, zero deletions!)
	att.Outcome = bs_core.AttemptNoShow
	q.ActiveAttemptIdx = -1
	q.Status = bs_core.QuestOpen
	q.EscrowHeld -= slashed
	totalActiveEscrow -= slashed
	treasuryBalance += slashed
	q.addEvent(now, rlm.Previous().Address(), "EXPIRED_CLAIM", "no_show="+builder.String()+" stake_to_treasury="+strconv.FormatInt(slashed, 10))

	if repRecordingEnabled {
		siege_rep.RecordNoShow(cross(rlm), builder)
	}
}

// SubmitWork submits proof (https:// URL + note) during InProgress or RevisionRequested.
func SubmitWork(cur realm, questID uint64, proofURL, note string) {
	requireNonPayableEOA(0, cur)
	q := mustGetQuest(questID)
	submitWorkCore(q, proofURL, note, cur)
}

func submitWorkCore(q *Quest, proofURL, note string, rlm realm) {
	if q.Status != bs_core.QuestInProgress && q.Status != bs_core.QuestRevisionRequested {
		panic("quest is not accepting work submissions")
	}
	att := q.activeAttempt()
	if att == nil || rlm.Previous().Address() != att.Builder {
		panic("unauthorized: only active builder can submit work")
	}
	now := time.Now().Unix()
	if now > att.WorkDeadline {
		panic("workDeadline has passed")
	}
	if err := bs_core.ValidateHTTPSURL(proofURL); err != nil {
		panic("invalid proof URL: " + err.Error())
	}
	if err := bs_core.ValidateText(note, bs_core.MaxNoteBytes, true, true); err != nil {
		panic("invalid proof note: " + err.Error())
	}

	att.Proofs = append(att.Proofs, ProofEntry{
		URL:         proofURL,
		Note:        strings.TrimSpace(note),
		SubmittedAt: now,
		RevisionIdx: att.RevisionCount,
	})
	att.SubmittedAt = now
	att.ReviewDeadline = now + q.ReviewDuration
	q.Status = bs_core.QuestUnderReview
	q.addEvent(now, att.Builder, "SUBMITTED", "rev="+strconv.Itoa(att.RevisionCount))
}

// ApproveQuest approves the submission before reviewDeadline and pays out Reward (minus 2% fee) + 100% Stake.
func ApproveQuest(cur realm, questID uint64) {
	requireNonPayableEOA(0, cur)
	q := mustGetQuest(questID)
	approveQuestCore(q, false, cur)
}

func approveQuestCore(q *Quest, isRaid bool, rlm realm) {
	if q.Status != bs_core.QuestUnderReview {
		panic("quest is not UnderReview")
	}
	caller := rlm.Previous().Address()
	if caller != q.Sponsor {
		panic("unauthorized: only sponsor can approve quest")
	}
	att := q.activeAttempt()
	if att == nil {
		panic("missing active attempt")
	}
	now := time.Now().Unix()
	if now > att.ReviewDeadline {
		panic("reviewDeadline has passed; builder may trigger TimeoutClaim")
	}

	fee := bs_core.CalcProtocolFee(q.Reward)
	builderNet := q.Reward - fee
	totalToBuilder := builderNet + q.Stake
	released := q.Reward + q.Stake
	reviewSecs := now - att.SubmittedAt
	if reviewSecs < 0 {
		reviewSecs = 0
	}

	// Checks-Effects-Interactions
	att.Outcome = bs_core.AttemptApproved
	q.Status = bs_core.QuestCompleted
	q.EscrowHeld -= released
	totalActiveEscrow -= released
	treasuryBalance += fee
	totalPaidOut += q.Reward
	q.addEvent(now, caller, "APPROVED", "builder_net="+strconv.FormatInt(builderNet, 10)+" fee="+strconv.FormatInt(fee, 10))

	sendUgnot(att.Builder, totalToBuilder, rlm)
	if repRecordingEnabled {
		siege_rep.RecordQuestCompleted(cross(rlm), q.Sponsor, att.Builder, uint8(q.Category), q.Reward, reviewSecs, isRaid, false)
	}
}

// RequestRevision asks the builder to revise (max 2 times, only while now <= reviewDeadline).
// New deadline is strictly now + 24h.
func RequestRevision(cur realm, questID uint64, note string) {
	requireNonPayableEOA(0, cur)
	q := mustGetQuest(questID)
	requestRevisionCore(q, note, cur)
}

func requestRevisionCore(q *Quest, note string, rlm realm) {
	if q.Status != bs_core.QuestUnderReview {
		panic("quest is not UnderReview")
	}
	caller := rlm.Previous().Address()
	if caller != q.Sponsor {
		panic("unauthorized: only sponsor can request revision")
	}
	att := q.activeAttempt()
	if att == nil {
		panic("missing active attempt")
	}
	now := time.Now().Unix()
	if now > att.ReviewDeadline {
		panic("reviewDeadline has passed; cannot request revision")
	}
	if att.RevisionCount >= bs_core.MaxRevisions {
		panic("maximum revisions (2) reached; sponsor must Approve or Reject")
	}
	if err := bs_core.ValidateText(note, bs_core.MaxNoteBytes, true, true); err != nil {
		panic("revision note is required: " + err.Error())
	}

	att.RevisionCount++
	att.RevisionNotes = append(att.RevisionNotes, strings.TrimSpace(note))
	att.WorkDeadline = now + bs_core.RevisionDurationSec
	q.Status = bs_core.QuestRevisionRequested
	q.addEvent(now, caller, "REVISION_REQUESTED", "count="+strconv.Itoa(att.RevisionCount))
}

// ExpireRevision allows anyone to close a quest if the 24h revision window passes
// without re-submission. Stake returns 100% to builder (never slashed after first
// submission), reward returns to sponsor, neutral for builder reputation.
func ExpireRevision(cur realm, questID uint64) {
	requireNonPayableEOA(0, cur)
	q := mustGetQuest(questID)
	expireRevisionCore(q, cur)
}

func expireRevisionCore(q *Quest, rlm realm) {
	if q.Status != bs_core.QuestRevisionRequested {
		panic("quest is not in RevisionRequested state")
	}
	att := q.activeAttempt()
	if att == nil {
		panic("missing active attempt")
	}
	now := time.Now().Unix()
	if now <= att.WorkDeadline {
		panic("revision deadline has not elapsed yet")
	}

	reward := q.Reward
	stake := q.Stake
	builder := att.Builder
	released := reward + stake

	att.Outcome = bs_core.AttemptRevisionExpired
	q.Status = bs_core.QuestCancelled
	q.EscrowHeld -= released
	totalActiveEscrow -= released
	q.addEvent(now, rlm.Previous().Address(), "EXPIRED_REVISION", "reward_refund="+strconv.FormatInt(reward, 10)+" stake_refund="+strconv.FormatInt(stake, 10))

	sendUgnot(builder, stake, rlm)
	sendUgnot(q.Sponsor, reward, rlm)
	if repRecordingEnabled {
		siege_rep.RecordRevisionExpired(cross(rlm), builder)
	}
}

// TimeoutClaim lets the active builder claim payout (with 2% protocol fee + 100% stake)
// if the sponsor fails to review before reviewDeadline.
func TimeoutClaim(cur realm, questID uint64) {
	requireNonPayableEOA(0, cur)
	q := mustGetQuest(questID)
	timeoutClaimCore(q, false, cur)
}

func timeoutClaimCore(q *Quest, isRaid bool, rlm realm) {
	if q.Status != bs_core.QuestUnderReview {
		panic("quest is not UnderReview")
	}
	att := q.activeAttempt()
	if att == nil || rlm.Previous().Address() != att.Builder {
		panic("unauthorized: only active builder can trigger TimeoutClaim")
	}
	now := time.Now().Unix()
	if now <= att.ReviewDeadline {
		panic("reviewDeadline has not elapsed yet")
	}

	fee := bs_core.CalcProtocolFee(q.Reward)
	builderNet := q.Reward - fee
	totalToBuilder := builderNet + q.Stake
	released := q.Reward + q.Stake

	att.Outcome = bs_core.AttemptTimeoutClaimed
	q.Status = bs_core.QuestCompleted
	q.EscrowHeld -= released
	totalActiveEscrow -= released
	treasuryBalance += fee
	totalPaidOut += q.Reward
	q.addEvent(now, att.Builder, "TIMEOUT_CLAIMED", "builder_net="+strconv.FormatInt(builderNet, 10)+" fee="+strconv.FormatInt(fee, 10))

	sendUgnot(att.Builder, totalToBuilder, rlm)
	if repRecordingEnabled {
		siege_rep.RecordQuestCompleted(cross(rlm), q.Sponsor, att.Builder, uint8(q.Category), q.Reward, 0, isRaid, true)
	}
}

// RejectSubmission rejects the builder's work before reviewDeadline.
// Per Decision B3A + B5A: Stake is IMMEDIATELY refunded 100% to builder,
// and a 48-hour dispute window opens for the builder.
func RejectSubmission(cur realm, questID uint64, reason string) {
	requireNonPayableEOA(0, cur)
	q := mustGetQuest(questID)
	rejectSubmissionCore(q, reason, cur)
}

func rejectSubmissionCore(q *Quest, reason string, rlm realm) {
	if q.Status != bs_core.QuestUnderReview {
		panic("quest is not UnderReview")
	}
	caller := rlm.Previous().Address()
	if caller != q.Sponsor {
		panic("unauthorized: only sponsor can reject submission")
	}
	att := q.activeAttempt()
	if att == nil {
		panic("missing active attempt")
	}
	now := time.Now().Unix()
	if now > att.ReviewDeadline {
		panic("reviewDeadline has passed; cannot reject")
	}
	if err := bs_core.ValidateText(reason, bs_core.MaxNoteBytes, true, true); err != nil {
		panic("rejection reason is required: " + err.Error())
	}

	stake := q.Stake
	builder := att.Builder

	att.RejectionReason = strings.TrimSpace(reason)
	att.RejectDeadline = now + bs_core.DisputeWindowSec
	q.Status = bs_core.QuestRejected
	q.EscrowHeld -= stake
	totalActiveEscrow -= stake
	q.addEvent(now, caller, "REJECTED", "stake_returned="+strconv.FormatInt(stake, 10))

	sendUgnot(builder, stake, rlm)
}

// FinalizeRejection allows anyone to finalize a rejection after the 48h dispute window
// passes without dispute, refunding reward 100% to sponsor. Quest is permanently Cancelled.
func FinalizeRejection(cur realm, questID uint64) {
	requireNonPayableEOA(0, cur)
	q := mustGetQuest(questID)
	finalizeRejectionCore(q, cur)
}

func finalizeRejectionCore(q *Quest, rlm realm) {
	if q.Status != bs_core.QuestRejected {
		panic("quest is not in Rejected state")
	}
	att := q.activeAttempt()
	if att == nil {
		panic("missing active attempt")
	}
	now := time.Now().Unix()
	if now <= att.RejectDeadline {
		panic("48h dispute window has not elapsed yet")
	}

	reward := q.Reward
	att.Outcome = bs_core.AttemptRejectedFinal
	q.Status = bs_core.QuestCancelled
	q.EscrowHeld -= reward
	totalActiveEscrow -= reward
	q.addEvent(now, rlm.Previous().Address(), "FINALIZED_REJECTION", "refund="+strconv.FormatInt(reward, 10))

	sendUgnot(q.Sponsor, reward, rlm)
	if repRecordingEnabled {
		siege_rep.RecordRejected(cross(rlm), q.Sponsor, att.Builder)
	}
}

// OpenDispute lets the rejected builder open an arbiter dispute within 48h by locking
// a 5% dispute fee. Locks the current arbiter address for this dispute permanently.
func OpenDispute(cur realm, questID uint64, reason string) {
	q := mustGetQuest(questID)
	openDisputeCore(q, reason, cur)
}

func openDisputeCore(q *Quest, reason string, rlm realm) {
	disputeFee := bs_core.CalcDisputeFee(q.Reward)
	requireExactUgnot(disputeFee, rlm)
	if q.Status != bs_core.QuestRejected {
		panic("quest is not in Rejected state")
	}
	att := q.activeAttempt()
	if att == nil || rlm.Previous().Address() != att.Builder {
		panic("unauthorized: only rejected builder can open dispute")
	}
	now := time.Now().Unix()
	if now > att.RejectDeadline {
		panic("48h dispute window has elapsed")
	}
	if err := bs_core.ValidateText(reason, bs_core.MaxNoteBytes, true, true); err != nil {
		panic("dispute reason is required: " + err.Error())
	}

	att.DisputeFee = disputeFee
	att.DisputeReason = strings.TrimSpace(reason)
	att.LockedArbiter = arbiter
	att.DisputedAt = now
	att.DisputeDeadline = now + bs_core.ArbiterTimeoutSec
	q.Status = bs_core.QuestDisputed
	q.EscrowHeld += disputeFee
	totalActiveEscrow += disputeFee
	q.addEvent(now, att.Builder, "DISPUTE_OPENED", "fee="+strconv.FormatInt(disputeFee, 10)+" arbiter="+arbiter.String())
}

// ResolveDispute lets ONLY the dispute's lockedArbiter choose strictly one of two outcomes:
//   - releaseToBuilder == true  -> Reward - 2% fee + DisputeFee -> Builder; 2% fee -> Treasury
//   - releaseToBuilder == false -> Reward -> Sponsor; DisputeFee -> Treasury (never to arbiter!)
func ResolveDispute(cur realm, questID uint64, releaseToBuilder bool, resolutionNote string) {
	requireNonPayableEOA(0, cur)
	q := mustGetQuest(questID)
	resolveDisputeCore(q, releaseToBuilder, resolutionNote, false, cur)
}

func resolveDisputeCore(q *Quest, releaseToBuilder bool, resolutionNote string, isRaid bool, rlm realm) {
	if q.Status != bs_core.QuestDisputed {
		panic("quest is not Disputed")
	}
	att := q.activeAttempt()
	if att == nil {
		panic("missing active attempt")
	}
	caller := rlm.Previous().Address()
	if caller != att.LockedArbiter {
		panic("unauthorized: only the locked arbiter for this dispute can resolve it")
	}
	now := time.Now().Unix()
	if now > att.DisputeDeadline {
		panic("arbiter 7-day deadline has passed; anyone may trigger ExpireDispute")
	}
	if err := bs_core.ValidateText(resolutionNote, bs_core.MaxNoteBytes, true, true); err != nil {
		panic("resolution note is required: " + err.Error())
	}

	reward := q.Reward
	disputeFee := att.DisputeFee
	released := reward + disputeFee
	att.ResolutionNote = strings.TrimSpace(resolutionNote)
	q.EscrowHeld -= released
	totalActiveEscrow -= released

	if releaseToBuilder {
		fee := bs_core.CalcProtocolFee(reward)
		builderNet := reward - fee
		att.Outcome = bs_core.AttemptDisputeWon
		q.Status = bs_core.QuestCompleted
		treasuryBalance += fee
		totalPaidOut += reward
		q.addEvent(now, caller, "DISPUTE_RELEASE_BUILDER", "builder_net="+strconv.FormatInt(builderNet, 10)+" fee="+strconv.FormatInt(fee, 10))

		sendUgnot(att.Builder, builderNet+disputeFee, rlm)
		if repRecordingEnabled {
			siege_rep.RecordQuestCompleted(cross(rlm), q.Sponsor, att.Builder, uint8(q.Category), reward, 0, isRaid, false)
			siege_rep.RecordDisputeOutcome(cross(rlm), q.Sponsor, att.Builder, true)
		}
	} else {
		att.Outcome = bs_core.AttemptDisputeLost
		q.Status = bs_core.QuestCancelled
		treasuryBalance += disputeFee
		q.addEvent(now, caller, "DISPUTE_REFUND_SPONSOR", "refund="+strconv.FormatInt(reward, 10)+" dispute_fee_to_treasury="+strconv.FormatInt(disputeFee, 10))

		sendUgnot(q.Sponsor, reward, rlm)
		if repRecordingEnabled {
			siege_rep.RecordDisputeOutcome(cross(rlm), q.Sponsor, att.Builder, false)
		}
	}
}

// ExpireDispute allows anyone to resolve a dispute if the locked arbiter times out (> 7 days).
// Global rounding rule: Sponsor = R/2, Builder = R/2 - 2% fee + DisputeFee, Treasury = 2% fee + (R % 2).
func ExpireDispute(cur realm, questID uint64) {
	requireNonPayableEOA(0, cur)
	q := mustGetQuest(questID)
	expireDisputeCore(q, cur)
}

func expireDisputeCore(q *Quest, rlm realm) {
	if q.Status != bs_core.QuestDisputed {
		panic("quest is not Disputed")
	}
	att := q.activeAttempt()
	if att == nil {
		panic("missing active attempt")
	}
	now := time.Now().Unix()
	if now <= att.DisputeDeadline {
		panic("arbiter 7-day deadline has not elapsed yet")
	}

	reward := q.Reward
	disputeFee := att.DisputeFee
	released := reward + disputeFee
	sponsorAmt, builderNet, treasuryAmt := bs_core.CalcArbiterTimeoutSplit(reward)

	att.Outcome = bs_core.AttemptDisputeTimeout
	q.Status = bs_core.QuestResolvedTimeout
	q.EscrowHeld -= released
	totalActiveEscrow -= released
	treasuryBalance += treasuryAmt
	totalPaidOut += (reward / 2)
	q.addEvent(now, rlm.Previous().Address(), "DISPUTE_ARBITER_TIMEOUT", "sponsor="+strconv.FormatInt(sponsorAmt, 10)+" builder_net="+strconv.FormatInt(builderNet, 10)+" treasury="+strconv.FormatInt(treasuryAmt, 10))

	sendUgnot(q.Sponsor, sponsorAmt, rlm)
	sendUgnot(att.Builder, builderNet+disputeFee, rlm)
}

func mustGetQuest(id uint64) *Quest {
	q, ok := questsByID[id]
	if !ok {
		panic("quest not found: " + strconv.FormatUint(id, 10))
	}
	return q
}

func QuestCount() int {
	return len(questIDs)
}
