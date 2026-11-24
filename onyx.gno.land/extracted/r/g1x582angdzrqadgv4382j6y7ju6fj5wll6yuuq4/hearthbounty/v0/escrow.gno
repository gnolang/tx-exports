package hearthbounty

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"strings"

	"gno.land/p/g1x582angdzrqadgv4382j6y7ju6fj5wll6yuuq4/hearthcore/v0"
)

// SetArbiter transfers dispute-resolution authority to a new valid Gno address.
func SetArbiter(cur realm, next address) {
	caller := cur.Previous().Address()
	if caller != arbiter {
		panic("hearthbounty: only current arbiter may transfer arbiter role")
	}
	if !next.IsValid() {
		panic("hearthbounty: next arbiter address is invalid")
	}
	arbiter = next
	chain.Emit(
		"ArbiterUpdated",
		"previous", string(caller),
		"arbiter", string(next),
	)
}

// RegisterProfile creates or updates a builder or autonomous AI agent profile.
// Providing a non-empty agentEndpoint marks the profile as an MCP-capable AI agent.
func RegisterProfile(cur realm, handle, bio, skills, agentEndpoint string) {
	caller := cur.Previous().Address()
	cleanHandle := hearthcore.ValidateText("handle", handle, 2, hearthcore.MaxHandleLen)
	cleanBio := hearthcore.ValidateText("bio", bio, 0, hearthcore.MaxBioLen)
	cleanSkills := hearthcore.ValidateText("skills", skills, 0, hearthcore.MaxSkillsLen)
	cleanEndpoint := hearthcore.ValidateText("agentEndpoint", agentEndpoint, 0, hearthcore.MaxEndpointLen)

	p := getOrCreateProfile(caller, runtime.ChainHeight())
	wasAgent := p.IsAgent
	p.Handle = cleanHandle
	p.Bio = cleanBio
	p.Skills = cleanSkills
	p.AgentEndpoint = cleanEndpoint
	p.IsAgent = cleanEndpoint != ""

	if !wasAgent && p.IsAgent {
		agentCount++
	} else if wasAgent && !p.IsAgent {
		agentCount--
	}

	chain.Emit(
		"ProfileRegistered",
		"address", string(caller),
		"handle", cleanHandle,
		"is_agent", strconv.FormatBool(p.IsAgent),
	)
}

// PostBounty creates a new micro-bounty funded with attached ugnot escrow.
// Requires a direct EOA call (AssertOriginCall + cur.Previous().IsUserCall()).
func PostBounty(cur realm, title, spec, category string, deadlineBlocks int64) uint64 {
	runtime.AssertOriginCall()
	if !cur.Previous().IsUserCall() {
		panic("hearthbounty: direct EOA call required to fund escrow")
	}

	amount := requireSingleUgnotSend(hearthcore.MinRewardUgnot)
	cleanTitle := hearthcore.ValidateText("title", title, 4, hearthcore.MaxTitleLen)
	cleanSpec := hearthcore.ValidateText("spec", spec, 10, hearthcore.MaxSpecLen)
	cat, ok := hearthcore.ParseCategory(category)
	if !ok {
		panic("hearthbounty: invalid category (use realm, tool, audit, docs, or agent)")
	}
	blocks := hearthcore.ValidateDeadlineBlocks(deadlineBlocks)

	sponsor := cur.Previous().Address()
	height := runtime.ChainHeight()
	nextID := uint64(bountySeq.Next())

	rec := &bountyRecord{
		ID:             nextID,
		Title:          cleanTitle,
		Spec:           cleanSpec,
		Category:       cat,
		Status:         hearthcore.StatusOpen,
		Sponsor:        sponsor,
		EscrowUgnot:    amount,
		InitialUgnot:   amount,
		DeadlineBlocks: blocks,
		CreatedHeight:  height,
	}

	bounties.Set(bountyKey(nextID), rec)
	openCount++
	totalEscrowUgnot += amount

	sp := getOrCreateProfile(sponsor, height)
	sp.PostedCount++
	sp.SponsoredUgnot += amount

	chain.Emit(
		"BountyPosted",
		"id", strconv.FormatUint(nextID, 10),
		"sponsor", string(sponsor),
		"category", string(cat),
		"escrow_ugnot", strconv.FormatInt(amount, 10),
		"deadline_blocks", strconv.FormatInt(blocks, 10),
	)

	return nextID
}

// TopUpBounty allows any supporter to crowd-fund additional ugnot into an open
// or claimed bounty's escrow pool.
func TopUpBounty(cur realm, id uint64) int64 {
	runtime.AssertOriginCall()
	if !cur.Previous().IsUserCall() {
		panic("hearthbounty: direct EOA call required to top up escrow")
	}

	amount := requireSingleUgnotSend(1)
	b, ok := getBountyRecord(id)
	if !ok {
		panic("hearthbounty: bounty not found")
	}
	if b.Status != hearthcore.StatusOpen && b.Status != hearthcore.StatusClaimed {
		panic("hearthbounty: can only top up open or claimed bounties")
	}

	donor := cur.Previous().Address()
	b.EscrowUgnot += amount
	b.TopUpCount++
	totalEscrowUgnot += amount

	dp := getOrCreateProfile(donor, runtime.ChainHeight())
	dp.SponsoredUgnot += amount

	chain.Emit(
		"BountyToppedUp",
		"id", strconv.FormatUint(id, 10),
		"donor", string(donor),
		"added_ugnot", strconv.FormatInt(amount, 10),
		"escrow_ugnot", strconv.FormatInt(b.EscrowUgnot, 10),
	)

	return b.EscrowUgnot
}

// ClaimBounty reserves an open bounty for a builder or autonomous AI agent.
// Sponsors cannot claim their own bounty to preserve reputation integrity.
func ClaimBounty(cur realm, id uint64, agentNote string) {
	b, ok := getBountyRecord(id)
	if !ok {
		panic("hearthbounty: bounty not found")
	}
	if b.Status != hearthcore.StatusOpen {
		panic("hearthbounty: bounty is not open for claiming")
	}

	caller := cur.Previous().Address()
	if caller == b.Sponsor {
		panic("hearthbounty: sponsor cannot claim own bounty")
	}
	cleanNote := hearthcore.ValidateText("agentNote", agentNote, 0, hearthcore.MaxNoteLen)

	height := runtime.ChainHeight()
	transitionStatus(b, hearthcore.StatusClaimed)
	b.Claimant = caller
	b.ClaimNote = cleanNote
	b.ClaimedHeight = height
	b.DeadlineHeight = height + b.DeadlineBlocks

	hp := getOrCreateProfile(caller, height)
	hp.ClaimedCount++

	chain.Emit(
		"BountyClaimed",
		"id", strconv.FormatUint(id, 10),
		"claimant", string(caller),
		"deadline_height", strconv.FormatInt(b.DeadlineHeight, 10),
	)
}

// ReleaseExpiredClaim returns a claimed bounty to Open when either the claimant
// voluntarily steps down or the deterministic block-height deadline has elapsed.
func ReleaseExpiredClaim(cur realm, id uint64) {
	b, ok := getBountyRecord(id)
	if !ok {
		panic("hearthbounty: bounty not found")
	}
	if b.Status != hearthcore.StatusClaimed {
		panic("hearthbounty: bounty is not currently claimed")
	}

	caller := cur.Previous().Address()
	height := runtime.ChainHeight()
	if caller != b.Claimant && height <= b.DeadlineHeight {
		panic("hearthbounty: claim deadline has not expired yet")
	}

	prevClaimant := b.Claimant
	transitionStatus(b, hearthcore.StatusOpen)
	b.Claimant = ""
	b.ClaimNote = ""
	b.ClaimedHeight = 0
	b.DeadlineHeight = 0
	b.RevisionFeedback = ""

	chain.Emit(
		"ClaimReleased",
		"id", strconv.FormatUint(id, 10),
		"previous_claimant", string(prevClaimant),
		"released_by", string(caller),
	)
}

// SubmitProof records a verifiable deliverable URL, cryptographic digest, and
// implementation summary for review by the sponsor.
func SubmitProof(cur realm, id uint64, proofURL, proofDigest, summary string) {
	b, ok := getBountyRecord(id)
	if !ok {
		panic("hearthbounty: bounty not found")
	}
	if b.Status != hearthcore.StatusClaimed {
		panic("hearthbounty: bounty must be claimed before submitting proof")
	}

	caller := cur.Previous().Address()
	if caller != b.Claimant {
		panic("hearthbounty: only the active claimant may submit proof")
	}

	cleanURL := hearthcore.ValidateProofURL(proofURL)
	cleanDigest := hearthcore.ValidateProofDigest(proofDigest)
	cleanSummary := hearthcore.ValidateText("summary", summary, 6, hearthcore.MaxNoteLen)

	transitionStatus(b, hearthcore.StatusSubmitted)
	b.ProofURL = cleanURL
	b.ProofDigest = cleanDigest
	b.ProofSummary = cleanSummary
	b.SubmittedHeight = runtime.ChainHeight()
	b.SubmissionCount++
	b.RevisionFeedback = ""

	chain.Emit(
		"ProofSubmitted",
		"id", strconv.FormatUint(id, 10),
		"claimant", string(caller),
		"proof_digest", cleanDigest,
		"submission_count", strconv.FormatUint(b.SubmissionCount, 10),
	)
}

// RequestRevision lets the sponsor send a submitted bounty back to Claimed with
// actionable feedback and a refreshed deadline window.
func RequestRevision(cur realm, id uint64, feedback string) {
	b, ok := getBountyRecord(id)
	if !ok {
		panic("hearthbounty: bounty not found")
	}
	if b.Status != hearthcore.StatusSubmitted {
		panic("hearthbounty: bounty has no pending submission")
	}

	caller := cur.Previous().Address()
	if caller != b.Sponsor {
		panic("hearthbounty: only the sponsor may request a revision")
	}

	cleanFeedback := hearthcore.ValidateText("feedback", feedback, 4, hearthcore.MaxNoteLen)
	transitionStatus(b, hearthcore.StatusClaimed)
	b.RevisionFeedback = cleanFeedback
	b.DeadlineHeight = runtime.ChainHeight() + b.DeadlineBlocks

	chain.Emit(
		"RevisionRequested",
		"id", strconv.FormatUint(id, 10),
		"sponsor", string(caller),
		"new_deadline_height", strconv.FormatInt(b.DeadlineHeight, 10),
	)
}

// ApproveAndSettle releases the full ugnot escrow to the claimant, records a
// 1-5 quality rating, and updates on-chain reputation using CEI ordering.
func ApproveAndSettle(cur realm, id uint64, rating uint8, reviewNote string) {
	b, ok := getBountyRecord(id)
	if !ok {
		panic("hearthbounty: bounty not found")
	}
	if b.Status != hearthcore.StatusSubmitted {
		panic("hearthbounty: bounty is not awaiting approval")
	}

	caller := cur.Previous().Address()
	if caller != b.Sponsor {
		panic("hearthbounty: only the sponsor may approve and settle")
	}

	validRating := hearthcore.ValidateRating(rating)
	cleanNote := hearthcore.ValidateText("reviewNote", reviewNote, 0, hearthcore.MaxNoteLen)

	payout := b.EscrowUgnot
	recipient := b.Claimant
	height := runtime.ChainHeight()

	// Effects before external bank interaction (CEI).
	b.EscrowUgnot = 0
	b.PayoutUgnot = payout
	b.Rating = validRating
	b.ReviewNote = cleanNote
	b.SettledHeight = height
	transitionStatus(b, hearthcore.StatusSettled)
	totalEscrowUgnot -= payout
	totalSettledUgnot += payout

	hp := getOrCreateProfile(recipient, height)
	hp.SettledCount++
	hp.EarnedUgnot += payout
	hp.RatingSum += uint64(validRating)
	hp.RatingCount++

	sp := getOrCreateProfile(b.Sponsor, height)
	sp.SponsoredSettled++

	// Interaction: send escrowed ugnot from realm address to claimant.
	if payout > 0 {
		bnk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
		bnk.SendCoins(cur.Address(), recipient, chain.Coins{{Denom: hearthcore.Denom, Amount: payout}})
	}

	chain.Emit(
		"BountySettled",
		"id", strconv.FormatUint(id, 10),
		"sponsor", string(b.Sponsor),
		"claimant", string(recipient),
		"payout_ugnot", strconv.FormatInt(payout, 10),
		"rating", strconv.Itoa(int(validRating)),
	)
}

// CancelBounty refunds escrowed ugnot to the sponsor. Only permitted while the
// bounty is Open so sponsors cannot withdraw funds from an active claim.
func CancelBounty(cur realm, id uint64) {
	b, ok := getBountyRecord(id)
	if !ok {
		panic("hearthbounty: bounty not found")
	}
	if b.Status != hearthcore.StatusOpen {
		panic("hearthbounty: only open bounties can be cancelled")
	}

	caller := cur.Previous().Address()
	if caller != b.Sponsor {
		panic("hearthbounty: only the sponsor may cancel")
	}

	refund := b.EscrowUgnot
	b.EscrowUgnot = 0
	b.RefundUgnot = refund
	transitionStatus(b, hearthcore.StatusCancelled)
	totalEscrowUgnot -= refund
	totalRefundUgnot += refund

	if refund > 0 {
		bnk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
		bnk.SendCoins(cur.Address(), b.Sponsor, chain.Coins{{Denom: hearthcore.Denom, Amount: refund}})
	}

	chain.Emit(
		"BountyCancelled",
		"id", strconv.FormatUint(id, 10),
		"sponsor", string(b.Sponsor),
		"refund_ugnot", strconv.FormatInt(refund, 10),
	)
}

// OpenDispute escalates a submitted bounty to arbiter review. Either the
// sponsor or the active claimant may open a dispute.
func OpenDispute(cur realm, id uint64, reason string) {
	b, ok := getBountyRecord(id)
	if !ok {
		panic("hearthbounty: bounty not found")
	}
	if b.Status != hearthcore.StatusSubmitted {
		panic("hearthbounty: disputes can only be opened on submitted bounties")
	}

	caller := cur.Previous().Address()
	if caller != b.Sponsor && caller != b.Claimant {
		panic("hearthbounty: only sponsor or claimant may open a dispute")
	}

	cleanReason := hearthcore.ValidateText("reason", reason, 6, hearthcore.MaxNoteLen)
	transitionStatus(b, hearthcore.StatusDisputed)
	b.DisputeReason = cleanReason
	b.DisputeOpenedBy = caller

	chain.Emit(
		"DisputeOpened",
		"id", strconv.FormatUint(id, 10),
		"opened_by", string(caller),
		"reason", cleanReason,
	)
}

// ResolveDispute settles a disputed bounty using deterministic basis-point math
// (hunterBps in 0..10000). The remainder is refunded atomically to the sponsor.
func ResolveDispute(cur realm, id uint64, hunterBps uint64, resolution string) {
	caller := cur.Previous().Address()
	if caller != arbiter {
		panic("hearthbounty: only the arbiter may resolve disputes")
	}

	b, ok := getBountyRecord(id)
	if !ok {
		panic("hearthbounty: bounty not found")
	}
	if b.Status != hearthcore.StatusDisputed {
		panic("hearthbounty: bounty is not disputed")
	}

	cleanResolution := hearthcore.ValidateText("resolution", resolution, 4, hearthcore.MaxNoteLen)
	escrow := b.EscrowUgnot
	hunterShare, sponsorShare := hearthcore.ComputeSplit(escrow, hunterBps)
	height := runtime.ChainHeight()

	// Effects before interactions (CEI).
	b.EscrowUgnot = 0
	b.PayoutUgnot = hunterShare
	b.RefundUgnot = sponsorShare
	b.ReviewNote = "[Arbiter Resolution] " + cleanResolution
	b.SettledHeight = height
	transitionStatus(b, hearthcore.StatusSettled)
	totalEscrowUgnot -= escrow
	totalSettledUgnot += hunterShare
	totalRefundUgnot += sponsorShare

	if hunterShare > 0 {
		hp := getOrCreateProfile(b.Claimant, height)
		hp.SettledCount++
		hp.EarnedUgnot += hunterShare
	}

	bnk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	if hunterShare > 0 {
		bnk.SendCoins(cur.Address(), b.Claimant, chain.Coins{{Denom: hearthcore.Denom, Amount: hunterShare}})
	}
	if sponsorShare > 0 {
		bnk.SendCoins(cur.Address(), b.Sponsor, chain.Coins{{Denom: hearthcore.Denom, Amount: sponsorShare}})
	}

	chain.Emit(
		"DisputeResolved",
		"id", strconv.FormatUint(id, 10),
		"arbiter", string(caller),
		"hunter_bps", strconv.FormatUint(hunterBps, 10),
		"hunter_ugnot", strconv.FormatInt(hunterShare, 10),
		"sponsor_refund_ugnot", strconv.FormatInt(sponsorShare, 10),
	)
}

// requireSingleUgnotSend validates that the caller attached exclusively ugnot
// at or above minAmount so unsupported denominations cannot get trapped.
func requireSingleUgnotSend(minAmount int64) int64 {
	sent := unsafe.OriginSend()
	if len(sent) == 0 {
		panic("hearthbounty: must attach ugnot escrow coins")
	}
	if len(sent) != 1 || sent[0].Denom != hearthcore.Denom {
		panic("hearthbounty: only ugnot coins are accepted")
	}
	if sent[0].Amount < minAmount {
		panic("hearthbounty: attached ugnot is below minimum required amount")
	}
	return sent[0].Amount
}

func normalizeFilter(raw string) string {
	return strings.ToLower(strings.TrimSpace(raw))
}
