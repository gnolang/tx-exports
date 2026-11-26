package tavernboard

import (
	"chain"
	"strconv"
	"strings"
	"time"

	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/p/g1uhez53ghm94hh8m4ezxs82240ql87vfppjq0mc/tavernkit"
)

// PostBounty creates a new multi-milestone bounty funded by the attached native
// ugnot (-send) and locks the coins inside a freshly minted, isolated sub-realm
// escrow vault (cur.Sub("escrow/<id>")).
//
// Parameters:
//   - title: concise quest title (1..120 bytes)
//   - summary: detailed acceptance criteria & deliverables (1..1200 bytes)
//   - tags: optional comma-separated categories (e.g. "realm,defi,gnoweb")
//   - milestoneSpec: "Full Delivery" or "Spec:3000,Core:5000,Docs:2000" (sum = 10000 bps)
//   - deadlineDays: number of days until sponsor may reclaim unsettled escrow (1..365)
//   - minReviewerStakeUgnot: minimum ugnot stake per dispute reviewer (0 uses default 50,000 ugnot)
//   - reviewerQuorum: minimum reviewers to settle a dispute (0 uses default 3; range 1..7)
func PostBounty(
	cur realm,
	title string,
	summary string,
	tags string,
	milestoneSpec string,
	deadlineDays int64,
	minReviewerStakeUgnot int64,
	reviewerQuorum int,
) uint64 {
	sponsor := requireDirectUserCall(0, cur)

	title = strings.TrimSpace(title)
	summary = strings.TrimSpace(summary)
	tags = strings.TrimSpace(tags)

	if title == "" || len(title) > MaxTitleLen {
		panic("title must be between 1 and 120 bytes")
	}
	if summary == "" || len(summary) > MaxSummaryLen {
		panic("summary must be between 1 and 1200 bytes")
	}
	if len(tags) > MaxTagsLen {
		panic("tags exceed 120 bytes")
	}
	if deadlineDays < 1 || deadlineDays > MaxDeadlineDays {
		panic("deadlineDays must be between 1 and 365")
	}

	if minReviewerStakeUgnot == 0 {
		minReviewerStakeUgnot = DefaultMinReviewerStakeUgnot
	}
	if minReviewerStakeUgnot < FloorReviewerStakeUgnot {
		panic("minReviewerStakeUgnot below floor of 10000ugnot")
	}

	if reviewerQuorum == 0 {
		reviewerQuorum = DefaultReviewerQuorum
	}
	if reviewerQuorum < 1 || reviewerQuorum > MaxReviewerQuorum {
		panic("reviewerQuorum must be between 1 and 7")
	}

	specs, err := tavernkit.ParseMilestoneSpecs(milestoneSpec)
	if err != nil {
		panic("invalid milestoneSpec: " + err.Error())
	}

	id := uint64(nextBountyID.Next())
	vaultAddr, funded := sweepOriginSendToSub(0, cur, escrowSubpath(id), MinBountyUgnot)

	weights := make([]int64, len(specs))
	for i, sp := range specs {
		weights[i] = sp.WeightBps
	}
	payouts, err := tavernkit.AllocatePayouts(funded, weights)
	if err != nil {
		panic("payout allocation failed: " + err.Error())
	}

	ms := make([]*milestone, len(specs))
	for i, sp := range specs {
		ms[i] = &milestone{
			index:       i,
			title:       sp.Title,
			weightBps:   sp.WeightBps,
			payoutUgnot: payouts[i],
			status:      tavernkit.MilestonePending,
		}
	}

	now := time.Now()
	b := &bounty{
		id:                    id,
		title:                 title,
		summary:               summary,
		tags:                  tags,
		sponsor:               sponsor,
		status:                tavernkit.StatusOpen,
		totalFundedUgnot:      funded,
		vaultAccountedUgnot:   funded,
		createdAt:             now,
		deadline:              now.Add(time.Duration(deadlineDays) * 24 * time.Hour),
		minReviewerStakeUgnot: minReviewerStakeUgnot,
		reviewerQuorum:        reviewerQuorum,
		milestones:            ms,
	}

	bounties.Set(bountyKey(id), b)
	p := getOrCreateProfile(sponsor)
	p.bountiesPosted++

	statTotalBounties++
	statOpenBounties++
	statTotalFundedUgnot += funded
	statActiveEscrowUgnot += funded

	chain.Emit(
		"BountyPosted",
		"id", strconv.FormatUint(id, 10),
		"sponsor", sponsor.String(),
		"vault", vaultAddr.String(),
		"fundedUgnot", strconv.FormatInt(funded, 10),
		"milestones", strconv.Itoa(len(ms)),
	)
	return id
}

// TopUpBounty allows any direct EOA co-sponsor to add additional ugnot to an
// active bounty's isolated escrow vault. The bonus is distributed dust-free
// across all remaining unsettled milestones according to their relative weights.
func TopUpBounty(cur realm, bountyID uint64) int64 {
	funder := requireDirectUserCall(0, cur)
	b := mustGetBounty(bountyID)
	ensureTopUpAllowed(b)

	_, added := sweepOriginSendToSub(0, cur, escrowSubpath(bountyID), 1)
	creditAdditionalFunding(b, added)

	chain.Emit(
		"BountyToppedUp",
		"id", strconv.FormatUint(bountyID, 10),
		"funder", funder.String(),
		"addedUgnot", strconv.FormatInt(added, 10),
		"newTotalUgnot", strconv.FormatInt(b.totalFundedUgnot, 10),
	)
	return b.totalFundedUgnot
}

// SyncBountyVault enables composable DAO / cross-realm / direct bank co-funding:
// if any external actor transferred ugnot directly to DeriveEscrowAddress(bountyID),
// calling SyncBountyVault detects the surplus balance and allocates it across
// unsettled milestones.
func SyncBountyVault(cur realm, bountyID uint64) int64 {
	caller := requireLiveCaller(0, cur)
	b := mustGetBounty(bountyID)
	ensureTopUpAllowed(b)

	vaultAddr := DeriveEscrowAddress(bountyID)
	live := liveVaultUgnot(vaultAddr)
	delta := live - b.vaultAccountedUgnot
	if delta <= 0 {
		panic("no uncredited ugnot in escrow vault")
	}

	creditAdditionalFunding(b, delta)

	chain.Emit(
		"BountyVaultSynced",
		"id", strconv.FormatUint(bountyID, 10),
		"caller", caller.String(),
		"syncedUgnot", strconv.FormatInt(delta, 10),
		"newTotalUgnot", strconv.FormatInt(b.totalFundedUgnot, 10),
	)
	return delta
}

func ensureTopUpAllowed(b *bounty) {
	if b.status == tavernkit.StatusCompleted || b.status == tavernkit.StatusCancelled || b.status == tavernkit.StatusArchived {
		panic("cannot fund a closed bounty")
	}
	if countUnsettledMilestones(b) == 0 {
		panic("no unsettled milestones remaining")
	}
}

func creditAdditionalFunding(b *bounty, added int64) {
	var unsettled []*milestone
	var sumWeights int64
	for _, m := range b.milestones {
		if !m.status.IsTerminal() {
			unsettled = append(unsettled, m)
			sumWeights += m.weightBps
		}
	}
	// Distribute dust-free proportionally across unsettled milestones.
	var distributed int64
	for i, m := range unsettled {
		var share int64
		if i == len(unsettled)-1 {
			share = added - distributed
		} else {
			share = (added * m.weightBps) / sumWeights
			distributed += share
		}
		m.payoutUgnot += share
	}
	b.totalFundedUgnot += added
	b.vaultAccountedUgnot += added
	statTotalFundedUgnot += added
	statActiveEscrowUgnot += added
}

// ClaimBounty assigns an Open bounty to the caller. Sponsors cannot claim their
// own bounty to prevent wash-farming on-chain reputation XP.
func ClaimBounty(cur realm, bountyID uint64, pitch string) {
	builder := requireLiveCaller(0, cur)
	b := mustGetBounty(bountyID)

	if b.status != tavernkit.StatusOpen {
		panic("bounty is not open for claims")
	}
	if time.Now().After(b.deadline) {
		panic("bounty deadline has passed")
	}
	if builder == b.sponsor {
		panic("sponsor cannot claim own bounty")
	}
	pitch = strings.TrimSpace(pitch)
	if len(pitch) > MaxPitchLen {
		panic("pitch exceeds 400 bytes")
	}

	b.builder = builder
	b.builderPitch = pitch
	b.status = tavernkit.StatusClaimed
	statOpenBounties--

	p := getOrCreateProfile(builder)
	p.bountiesClaimed++

	chain.Emit(
		"BountyClaimed",
		"id", strconv.FormatUint(bountyID, 10),
		"builder", builder.String(),
	)
}

// ReleaseClaim lets the active builder step down before any milestone has been
// submitted or settled, returning the bounty to Open status.
func ReleaseClaim(cur realm, bountyID uint64) {
	caller := requireLiveCaller(0, cur)
	b := mustGetBounty(bountyID)

	if caller != b.builder {
		panic("only the assigned builder can release a claim")
	}
	if b.status != tavernkit.StatusClaimed {
		panic("can only release claim while status is CLAIMED")
	}
	for _, m := range b.milestones {
		if m.status != tavernkit.MilestonePending {
			panic("cannot release claim after milestone work has been submitted or settled")
		}
	}

	b.builder = ""
	b.builderPitch = ""
	b.status = tavernkit.StatusOpen
	statOpenBounties++

	chain.Emit(
		"ClaimReleased",
		"id", strconv.FormatUint(bountyID, 10),
		"builder", caller.String(),
	)
}

// SubmitMilestone submits a verifiable proof-of-delivery URL (e.g. GitHub PR,
// commit hash, deployed onyx-1 realm link) and delivery notes for a milestone.
func SubmitMilestone(cur realm, bountyID uint64, milestoneIdx int, proofURL string, notes string) {
	caller := requireLiveCaller(0, cur)
	b := mustGetBounty(bountyID)

	if caller != b.builder {
		panic("only the assigned builder can submit milestones")
	}
	if b.status != tavernkit.StatusClaimed && b.status != tavernkit.StatusInReview {
		panic("bounty is not accepting milestone submissions")
	}
	m := mustGetMilestone(b, milestoneIdx)
	if m.status != tavernkit.MilestonePending && m.status != tavernkit.MilestoneRevisionRequested {
		panic("milestone is not pending or awaiting revision")
	}

	proofURL = strings.TrimSpace(proofURL)
	notes = strings.TrimSpace(notes)
	if proofURL == "" || len(proofURL) > MaxProofURLLen {
		panic("proofURL must be between 1 and 256 bytes")
	}
	// Reject unsafe URL schemes (javascript:, data:text/html, etc.) at write time.
	if sanitize.URL(proofURL) == "" {
		panic("proofURL rejected: must use a safe https://, http://, or relative URL")
	}
	if len(notes) > MaxNotesLen {
		panic("delivery notes exceed 800 bytes")
	}

	m.proofURL = proofURL
	m.deliveryNotes = notes
	m.status = tavernkit.MilestoneSubmitted
	m.submittedAt = time.Now()
	b.status = tavernkit.StatusInReview

	chain.Emit(
		"MilestoneSubmitted",
		"id", strconv.FormatUint(bountyID, 10),
		"milestone", strconv.Itoa(milestoneIdx),
		"builder", caller.String(),
	)
}

// ApproveMilestone allows the bounty sponsor to accept a submitted milestone
// and immediately release that milestone's exact ugnot payout from the bounty's
// isolated sub-realm escrow vault to the builder.
func ApproveMilestone(cur realm, bountyID uint64, milestoneIdx int, feedback string) {
	caller := requireLiveCaller(0, cur)
	b := mustGetBounty(bountyID)

	if caller != b.sponsor {
		panic("only the bounty sponsor can approve milestones")
	}
	m := mustGetMilestone(b, milestoneIdx)
	if m.status != tavernkit.MilestoneSubmitted {
		panic("milestone is not awaiting review")
	}
	feedback = strings.TrimSpace(feedback)
	if len(feedback) > MaxFeedbackLen {
		panic("feedback exceeds 500 bytes")
	}

	payout := m.payoutUgnot
	m.sponsorFeedback = feedback
	m.status = tavernkit.MilestoneApproved
	m.settledAt = time.Now()

	// Effects before transfer, then spend from this bounty's isolated sub-vault.
	b.totalReleasedUgnot += payout
	b.vaultAccountedUgnot -= payout
	statTotalPaidUgnot += payout
	statActiveEscrowUgnot -= payout

	sendFromSubVault(0, cur, escrowSubpath(bountyID), b.builder, payout)

	bp := getOrCreateProfile(b.builder)
	bp.approvedMilestones++
	bp.totalEarnedUgnot += payout

	refreshBountyCompletion(b, bp)

	chain.Emit(
		"MilestoneApproved",
		"id", strconv.FormatUint(bountyID, 10),
		"milestone", strconv.Itoa(milestoneIdx),
		"builder", b.builder.String(),
		"payoutUgnot", strconv.FormatInt(payout, 10),
	)
}

// RequestRevision lets the sponsor return a submitted milestone to the builder
// with actionable feedback (up to MaxRevisionRequests times).
func RequestRevision(cur realm, bountyID uint64, milestoneIdx int, feedback string) {
	caller := requireLiveCaller(0, cur)
	b := mustGetBounty(bountyID)

	if caller != b.sponsor {
		panic("only the bounty sponsor can request revisions")
	}
	m := mustGetMilestone(b, milestoneIdx)
	if m.status != tavernkit.MilestoneSubmitted {
		panic("milestone is not awaiting review")
	}
	if m.revisionCount >= MaxRevisionRequests {
		panic("maximum revision requests reached; approve or open a dispute")
	}
	feedback = strings.TrimSpace(feedback)
	if feedback == "" || len(feedback) > MaxFeedbackLen {
		panic("revision feedback must be between 1 and 500 bytes")
	}

	m.sponsorFeedback = feedback
	m.revisionCount++
	m.status = tavernkit.MilestoneRevisionRequested
	updateActiveBountyStatus(b)

	chain.Emit(
		"RevisionRequested",
		"id", strconv.FormatUint(bountyID, 10),
		"milestone", strconv.Itoa(milestoneIdx),
		"revisionCount", strconv.Itoa(m.revisionCount),
	)
}

// OpenDispute escalates a contested milestone to an on-chain stake-backed
// reviewer quorum.
//
// Eligibility:
//   - Sponsor may dispute any MilestoneSubmitted deliverable.
//   - Builder may dispute a MilestoneRevisionRequested deliverable, OR a
//     MilestoneSubmitted deliverable if the sponsor has not responded within
//     ReviewGracePeriod (48h).
func OpenDispute(cur realm, bountyID uint64, milestoneIdx int, reason string) {
	caller := requireLiveCaller(0, cur)
	b := mustGetBounty(bountyID)
	m := mustGetMilestone(b, milestoneIdx)

	if m.dispute != nil {
		panic("dispute already exists for this milestone")
	}
	reason = strings.TrimSpace(reason)
	if reason == "" || len(reason) > MaxRationaleLen {
		panic("dispute reason must be between 1 and 400 bytes")
	}

	switch caller {
	case b.sponsor:
		if m.status != tavernkit.MilestoneSubmitted {
			panic("sponsor can only dispute a submitted milestone")
		}
	case b.builder:
		if m.status == tavernkit.MilestoneRevisionRequested {
			// Allowed immediately if builder disagrees with revision request.
		} else if m.status == tavernkit.MilestoneSubmitted {
			if time.Now().Before(m.submittedAt.Add(ReviewGracePeriod)) {
				panic("sponsor still within 48h review grace period")
			}
		} else {
			panic("milestone is not eligible for builder dispute")
		}
	default:
		panic("only sponsor or assigned builder may open a dispute")
	}

	m.status = tavernkit.MilestoneDisputed
	m.dispute = &dispute{
		openedBy: caller,
		reason:   reason,
		openedAt: time.Now(),
	}
	b.status = tavernkit.StatusDisputed

	chain.Emit(
		"DisputeOpened",
		"id", strconv.FormatUint(bountyID, 10),
		"milestone", strconv.Itoa(milestoneIdx),
		"openedBy", caller.String(),
	)
}

// StakeAndVoteDispute lets an independent third-party reviewer stake native
// ugnot (attached via -send >= b.minReviewerStakeUgnot) into the bounty's
// isolated stake sub-vault (cur.Sub("stake/<id>")) and cast a binding vote.
//
// As soon as the stake-backed quorum reaches a strict majority (>= reviewerQuorum
// votes with no tie), the dispute resolves atomically in the same transaction:
//   - Escrowed milestone payout goes to builder (if approved) or refunds sponsor.
//   - Aligned reviewers reclaim 100% of their stake + an equal split of 50% of
//     dissenting reviewers' slashed stakes.
//   - Builder and reviewer on-chain reputations update immediately.
func StakeAndVoteDispute(
	cur realm,
	bountyID uint64,
	milestoneIdx int,
	approveBuilder bool,
	rationale string,
) bool {
	reviewer := requireDirectUserCall(0, cur)
	b := mustGetBounty(bountyID)
	m := mustGetMilestone(b, milestoneIdx)

	if m.status != tavernkit.MilestoneDisputed || m.dispute == nil || m.dispute.resolved {
		panic("milestone does not have an active dispute")
	}
	if reviewer == b.sponsor || reviewer == b.builder {
		panic("sponsor and builder cannot vote as reviewers on their own dispute")
	}
	for _, existing := range m.dispute.votes {
		if existing.reviewer == reviewer {
			panic("reviewer has already voted on this dispute")
		}
	}
	rationale = strings.TrimSpace(rationale)
	if rationale == "" || len(rationale) > MaxRationaleLen {
		panic("rationale must be between 1 and 400 bytes")
	}

	_, stakeAmt := sweepOriginSendToSub(0, cur, stakeSubpath(bountyID), b.minReviewerStakeUgnot)

	d := m.dispute
	d.votes = append(d.votes, &reviewVote{
		reviewer:       reviewer,
		approveBuilder: approveBuilder,
		stakeUgnot:     stakeAmt,
		rationale:      rationale,
		castAt:         time.Now(),
	})
	d.stakePoolUgnot += stakeAmt
	if approveBuilder {
		d.approveCount++
	} else {
		d.rejectCount++
	}

	chain.Emit(
		"DisputeVoteCast",
		"id", strconv.FormatUint(bountyID, 10),
		"milestone", strconv.Itoa(milestoneIdx),
		"reviewer", reviewer.String(),
		"approveBuilder", strconv.FormatBool(approveBuilder),
		"stakeUgnot", strconv.FormatInt(stakeAmt, 10),
	)

	tally := tavernkit.EvaluateQuorum(d.approveCount, d.rejectCount, b.reviewerQuorum)
	if tally.Decided {
		settleDispute(0, cur, b, m, tally.BuilderWins)
		return true
	}
	return false
}

func settleDispute(_ int, rlm realm, b *bounty, m *milestone, builderWins bool) {
	d := m.dispute
	d.resolved = true
	d.builderWon = builderWins
	d.resolvedAt = time.Now()
	m.settledAt = d.resolvedAt
	statDisputesResolved++

	// 1. Settle escrowed milestone funds from escrow/<id> sub-vault.
	payout := m.payoutUgnot
	b.vaultAccountedUgnot -= payout
	statActiveEscrowUgnot -= payout

	bp := getOrCreateProfile(b.builder)
	if builderWins {
		m.status = tavernkit.MilestoneResolvedBuilder
		b.totalReleasedUgnot += payout
		statTotalPaidUgnot += payout
		bp.approvedMilestones++
		bp.totalEarnedUgnot += payout
		bp.disputesWon++
		sendFromSubVault(0, rlm, escrowSubpath(b.id), b.builder, payout)
	} else {
		m.status = tavernkit.MilestoneResolvedSponsor
		b.totalRefundedUgnot += payout
		bp.disputesLost++
		sendFromSubVault(0, rlm, escrowSubpath(b.id), b.sponsor, payout)
	}

	// 2. Settle reviewer stakes from stake/<id> sub-vault:
	//    - Dissenting reviewers forfeit DissentSlashBps (50%) of their stake
	//      and receive back the remaining 50%.
	//    - Aligned reviewers receive 100% of their stake + an equal share of
	//      the slashed bonus pool (dust goes to first aligned reviewer so zero
	//      ugnot is stranded in the stake sub-vault).
	var winners []*reviewVote
	var losers []*reviewVote
	var slashedPool int64

	for _, v := range d.votes {
		if v.approveBuilder == builderWins {
			winners = append(winners, v)
		} else {
			losers = append(losers, v)
			slash := (v.stakeUgnot * DissentSlashBps) / tavernkit.BasisPointsTotal
			slashedPool += slash
		}
	}

	stakePath := stakeSubpath(b.id)
	for _, lv := range losers {
		slash := (lv.stakeUgnot * DissentSlashBps) / tavernkit.BasisPointsTotal
		returnAmt := lv.stakeUgnot - slash
		if returnAmt > 0 {
			sendFromSubVault(0, rlm, stakePath, lv.reviewer, returnAmt)
		}
		lp := getOrCreateProfile(lv.reviewer)
		lp.reviewsSlashed++
	}

	winnerCount := int64(len(winners))
	var bonusEach, bonusRem int64
	if winnerCount > 0 && slashedPool > 0 {
		bonusEach = slashedPool / winnerCount
		bonusRem = slashedPool % winnerCount
	}
	for i, wv := range winners {
		reward := wv.stakeUgnot + bonusEach
		if i == 0 {
			reward += bonusRem
		}
		sendFromSubVault(0, rlm, stakePath, wv.reviewer, reward)
		wp := getOrCreateProfile(wv.reviewer)
		wp.reviewsAligned++
		if reward > wv.stakeUgnot {
			wp.totalEarnedUgnot += (reward - wv.stakeUgnot)
		}
	}
	d.stakePoolUgnot = 0

	refreshBountyCompletion(b, bp)

	chain.Emit(
		"DisputeResolved",
		"id", strconv.FormatUint(b.id, 10),
		"milestone", strconv.Itoa(m.index),
		"builderWins", strconv.FormatBool(builderWins),
		"slashedPoolUgnot", strconv.FormatInt(slashedPool, 10),
	)
}

// CancelOrReclaimExpired lets the sponsor cancel an unclaimed Open bounty
// immediately, OR reclaim remaining unsettled escrow funds after the bounty's
// deadline has expired (as long as no milestone is currently under active
// quorum dispute).
func CancelOrReclaimExpired(cur realm, bountyID uint64) int64 {
	caller := requireLiveCaller(0, cur)
	b := mustGetBounty(bountyID)

	if caller != b.sponsor {
		panic("only the bounty sponsor can cancel or reclaim")
	}
	if b.status == tavernkit.StatusCompleted || b.status == tavernkit.StatusCancelled || b.status == tavernkit.StatusArchived {
		panic("bounty is already closed")
	}
	if b.status != tavernkit.StatusOpen && !time.Now().After(b.deadline) {
		panic("claimed bounty cannot be cancelled before deadline")
	}
	for _, m := range b.milestones {
		if m.status == tavernkit.MilestoneDisputed {
			panic("cannot reclaim while a milestone dispute is active")
		}
	}

	var refund int64
	for _, m := range b.milestones {
		if !m.status.IsTerminal() {
			refund += m.payoutUgnot
			m.status = tavernkit.MilestoneResolvedSponsor
			m.settledAt = time.Now()
		}
	}

	if b.status == tavernkit.StatusOpen {
		statOpenBounties--
	}
	b.status = tavernkit.StatusCancelled
	b.totalRefundedUgnot += refund
	b.vaultAccountedUgnot -= refund
	statActiveEscrowUgnot -= refund

	if refund > 0 {
		sendFromSubVault(0, cur, escrowSubpath(bountyID), b.sponsor, refund)
	}

	chain.Emit(
		"BountyCancelled",
		"id", strconv.FormatUint(bountyID, 10),
		"sponsor", b.sponsor.String(),
		"refundedUgnot", strconv.FormatInt(refund, 10),
	)
	return refund
}

// ArchiveClosedBounty is a permissionless Gno.land storage-deposit hygiene
// endpoint: once a bounty is Completed or Cancelled and its vaults hold zero
// accounted ugnot, ANY user can prune heavy prose fields (summary, pitch,
// delivery notes, feedback, dispute rationales) into a compact tombstone.
// Per Gno's storage-deposit model, freeing those bytes refunds storage deposit
// to the transaction sender while preserving financial & reputation history.
func ArchiveClosedBounty(cur realm, bountyID uint64) {
	caller := requireLiveCaller(0, cur)
	b := mustGetBounty(bountyID)

	if b.archived {
		panic("bounty is already archived")
	}
	if b.status != tavernkit.StatusCompleted && b.status != tavernkit.StatusCancelled {
		panic("only completed or cancelled bounties can be archived")
	}
	if b.vaultAccountedUgnot != 0 {
		panic("cannot archive while vault balance is non-zero")
	}

	b.summary = ""
	b.builderPitch = ""
	for _, m := range b.milestones {
		m.deliveryNotes = ""
		m.sponsorFeedback = ""
		if m.dispute != nil {
			m.dispute.reason = ""
			for _, v := range m.dispute.votes {
				v.rationale = ""
			}
		}
	}
	b.archived = true
	b.status = tavernkit.StatusArchived
	statArchivedBounties++

	chain.Emit(
		"BountyArchived",
		"id", strconv.FormatUint(bountyID, 10),
		"archiver", caller.String(),
	)
}

func mustGetMilestone(b *bounty, idx int) *milestone {
	if idx < 0 || idx >= len(b.milestones) {
		panic("milestone index out of range")
	}
	return b.milestones[idx]
}

func countUnsettledMilestones(b *bounty) int {
	n := 0
	for _, m := range b.milestones {
		if !m.status.IsTerminal() {
			n++
		}
	}
	return n
}

func countApprovedMilestones(b *bounty) int {
	n := 0
	for _, m := range b.milestones {
		if m.status == tavernkit.MilestoneApproved || m.status == tavernkit.MilestoneResolvedBuilder {
			n++
		}
	}
	return n
}

func refreshBountyCompletion(b *bounty, bp *builderProfile) {
	if countUnsettledMilestones(b) == 0 {
		b.status = tavernkit.StatusCompleted
		statCompletedBounties++
		// Credit completedBounties only if builder successfully won/delivered at
		// least one milestone on the quest.
		if countApprovedMilestones(b) > 0 && bp != nil {
			bp.completedBounties++
		}
		return
	}
	updateActiveBountyStatus(b)
}

func updateActiveBountyStatus(b *bounty) {
	hasDispute := false
	hasSubmitted := false
	for _, m := range b.milestones {
		switch m.status {
		case tavernkit.MilestoneDisputed:
			hasDispute = true
		case tavernkit.MilestoneSubmitted:
			hasSubmitted = true
		}
	}
	switch {
	case hasDispute:
		b.status = tavernkit.StatusDisputed
	case hasSubmitted:
		b.status = tavernkit.StatusInReview
	default:
		b.status = tavernkit.StatusClaimed
	}
}
