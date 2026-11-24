package hearthbounty

import (
	"chain"
	"chain/runtime"
	"strconv"
	"strings"

	"gno.land/p/g1x582angdzrqadgv4382j6y7ju6fj5wll6yuuq4/hearthcore/v0"
	"gno.land/p/nt/avl/v0"
	"gno.land/r/nt/grc20reg/v0"
)

type contributorRefund struct {
	addr   address
	amount int64
}

// ValidateEscrowToken verifies that a requested settlement token key matches
// the canonical 1:1 ugnot-backed wrapped GNOT key registered in grc20reg.
func ValidateEscrowToken(tokenKey string) {
	if strings.TrimSpace(tokenKey) != EscrowTokenKey {
		panic("hearthbounty: only 1:1 ugnot-backed wugnot escrow is accepted")
	}
}

func validateEscrowAmount(amount, minAmount int64) int64 {
	if amount < minAmount {
		panic("hearthbounty: escrow amount is below minimum required (100000 wugnot)")
	}
	if amount > MaxEscrowUgnot {
		panic("hearthbounty: escrow amount exceeds single-bounty safety ceiling")
	}
	return amount
}

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

// PostBounty creates a new micro-bounty funded with pre-approved 1:1 ugnot-backed
// wugnot via gno.land/r/nt/grc20reg/v0.
// Requires a direct EOA call (AssertOriginCall + cur.Previous().IsUserCall()).
func PostBounty(cur realm, title, spec, category string, rewardUgnot int64, deadlineBlocks int64) uint64 {
	runtime.AssertOriginCall()
	if !cur.Previous().IsUserCall() {
		panic("hearthbounty: direct EOA call required to fund escrow")
	}

	amount := validateEscrowAmount(rewardUgnot, hearthcore.MinRewardUgnot)
	cleanTitle := hearthcore.ValidateText("title", title, 4, hearthcore.MaxTitleLen)
	cleanSpec := hearthcore.ValidateText("spec", spec, 10, hearthcore.MaxSpecLen)
	cat, ok := hearthcore.ParseCategory(category)
	if !ok {
		panic("hearthbounty: invalid category (use realm, tool, audit, docs, or agent)")
	}
	blocks := hearthcore.ValidateDeadlineBlocks(deadlineBlocks)

	sponsor := cur.Previous().Address()
	// Pull pre-approved wugnot into realm custody before mutating bounty state.
	// Panics atomically if sponsor balance or allowance is insufficient.
	grc20reg.TransferFrom(0, cur, EscrowTokenKey, sponsor, cur.Address(), amount)

	height := runtime.ChainHeight()
	nextID := uint64(bountySeq.Next())

	rec := &bountyRecord{
		ID:                 nextID,
		Title:              cleanTitle,
		Spec:               cleanSpec,
		Category:           cat,
		Status:             hearthcore.StatusOpen,
		Sponsor:            sponsor,
		EscrowUgnot:        amount,
		InitialUgnot:       amount,
		SponsorFundedUgnot: amount,
		DonorShares:        avl.NewTree(),
		DeadlineBlocks:     blocks,
		CreatedHeight:      height,
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
		"escrow_token", EscrowTokenKey,
		"escrow_ugnot", strconv.FormatInt(amount, 10),
		"deadline_blocks", strconv.FormatInt(blocks, 10),
	)

	return nextID
}

// TopUpBounty allows supporters or the sponsor to add pre-approved wugnot
// (>= 0.10 GNOT) into an Open or Claimed bounty. Per-contributor custody is
// tracked in an AVL donor ledger so cancellations and dispute splits refund
// each contributor directly instead of handing external coins to the sponsor.
func TopUpBounty(cur realm, id uint64, amountUgnot int64) int64 {
	runtime.AssertOriginCall()
	if !cur.Previous().IsUserCall() {
		panic("hearthbounty: direct EOA call required to top up escrow")
	}

	amount := validateEscrowAmount(amountUgnot, MinTopUpUgnot)
	donor := cur.Previous().Address()
	b := validateTopUpTarget(donor, id, amount)

	grc20reg.TransferFrom(0, cur, EscrowTokenKey, donor, cur.Address(), amount)

	if donor == b.Sponsor {
		b.SponsorFundedUgnot += amount
	} else {
		if b.DonorShares == nil {
			b.DonorShares = avl.NewTree()
		}
		key := string(donor)
		prev := int64(0)
		if raw := b.DonorShares.Get(key); raw != nil {
			prev = raw.(int64)
		}
		b.DonorShares.Set(key, prev+amount)
		b.ExternalTopUpUgnot += amount
	}

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

func validateTopUpTarget(donor address, id uint64, amount int64) *bountyRecord {
	b, ok := getBountyRecord(id)
	if !ok {
		panic("hearthbounty: bounty not found")
	}
	if b.Status != hearthcore.StatusOpen && b.Status != hearthcore.StatusClaimed {
		panic("hearthbounty: can only top up open or claimed bounties")
	}
	if b.Claimant != "" && donor == b.Claimant {
		panic("hearthbounty: active claimant cannot top up own claimed bounty")
	}
	if b.EscrowUgnot+amount > MaxEscrowUgnot {
		panic("hearthbounty: escrow total exceeds single-bounty safety ceiling")
	}
	if donor != b.Sponsor && b.DonorShares != nil && !b.DonorShares.Has(string(donor)) && b.DonorShares.Size() >= MaxExternalDonors {
		panic("hearthbounty: external donor cap reached for this bounty")
	}
	return b
}

// ClaimBounty reserves an open bounty for a builder or autonomous AI agent.
// Sponsors and external escrow contributors cannot claim the bounty they funded.
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
	if b.DonorShares != nil && b.DonorShares.Has(string(caller)) {
		panic("hearthbounty: escrow contributor cannot claim own funded bounty")
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
// voluntarily steps down or ChainHeight() reaches DeadlineHeight.
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
	if caller != b.Claimant && height < b.DeadlineHeight {
		panic("hearthbounty: claim deadline has not expired yet")
	}

	prevClaimant := b.Claimant
	if raw := profiles.Get(string(prevClaimant)); raw != nil {
		p := raw.(*profileRecord)
		if p.ClaimedCount > 0 {
			p.ClaimedCount--
		}
	}

	transitionStatus(b, hearthcore.StatusOpen)
	b.Claimant = ""
	b.ClaimNote = ""
	b.ClaimedHeight = 0
	b.DeadlineHeight = 0
	b.SubmittedHeight = 0
	b.ReviewDeadlineHeight = 0
	b.ProofURL = ""
	b.ProofDigest = ""
	b.ProofSummary = ""
	b.RevisionFeedback = ""

	chain.Emit(
		"ClaimReleased",
		"id", strconv.FormatUint(id, 10),
		"previous_claimant", string(prevClaimant),
		"released_by", string(caller),
	)
}

// SubmitProof records an HTTPS deliverable URL, SHA-256 content digest, and
// implementation summary, opening a deterministic sponsor review window.
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

	cleanURL := ValidateProofURL(proofURL)
	cleanDigest := hearthcore.ValidateProofDigest(proofDigest)
	cleanSummary := hearthcore.ValidateText("summary", summary, 6, hearthcore.MaxNoteLen)
	height := runtime.ChainHeight()

	transitionStatus(b, hearthcore.StatusSubmitted)
	b.ProofURL = cleanURL
	b.ProofDigest = cleanDigest
	b.ProofSummary = cleanSummary
	b.SubmittedHeight = height
	b.ReviewDeadlineHeight = height + b.DeadlineBlocks
	b.SubmissionCount++
	b.RevisionFeedback = ""

	chain.Emit(
		"ProofSubmitted",
		"id", strconv.FormatUint(id, 10),
		"claimant", string(caller),
		"proof_digest", cleanDigest,
		"review_deadline_height", strconv.FormatInt(b.ReviewDeadlineHeight, 10),
		"submission_count", strconv.FormatUint(b.SubmissionCount, 10),
	)
}

// RequestRevision lets the sponsor send a submitted bounty back to Claimed with
// actionable feedback and a refreshed claim deadline window.
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
	b.ReviewDeadlineHeight = 0
	b.DeadlineHeight = runtime.ChainHeight() + b.DeadlineBlocks

	chain.Emit(
		"RevisionRequested",
		"id", strconv.FormatUint(id, 10),
		"sponsor", string(caller),
		"new_deadline_height", strconv.FormatInt(b.DeadlineHeight, 10),
	)
}

// ApproveAndSettle releases the full wugnot escrow to the claimant, records a
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
	settleFullToClaimant(cur, b, validRating, cleanNote, "BountySettled")
}

// ExpireSubmission is callable by anyone once ChainHeight() reaches
// ReviewDeadlineHeight without sponsor action. It settles 100% of the escrow
// to the claimant so sponsors cannot hold delivered work hostage forever.
func ExpireSubmission(cur realm, id uint64) {
	b, ok := getBountyRecord(id)
	if !ok {
		panic("hearthbounty: bounty not found")
	}
	if b.Status != hearthcore.StatusSubmitted {
		panic("hearthbounty: bounty has no pending submission")
	}
	if runtime.ChainHeight() < b.ReviewDeadlineHeight {
		panic("hearthbounty: submission review window has not expired yet")
	}

	settleFullToClaimant(cur, b, 0, "[Auto-Settled] Sponsor review window expired", "SubmissionExpiredSettled")
}

func settleFullToClaimant(cur realm, b *bountyRecord, rating uint8, reviewNote, eventName string) {
	payout := b.EscrowUgnot
	recipient := b.Claimant
	height := runtime.ChainHeight()

	// Effects before external token transfer (CEI).
	b.EscrowUgnot = 0
	b.SponsorFundedUgnot = 0
	b.ExternalTopUpUgnot = 0
	b.DonorShares = avl.NewTree()
	b.PayoutUgnot = payout
	b.Rating = rating
	b.ReviewNote = reviewNote
	b.SettledHeight = height
	transitionStatus(b, hearthcore.StatusSettled)
	totalEscrowUgnot -= payout
	totalSettledUgnot += payout

	hp := getOrCreateProfile(recipient, height)
	hp.SettledCount++
	hp.EarnedUgnot += payout
	if rating > 0 {
		hp.RatingSum += uint64(rating)
		hp.RatingCount++
	}

	sp := getOrCreateProfile(b.Sponsor, height)
	sp.SponsoredSettled++

	if payout > 0 {
		grc20reg.Transfer(0, cur, EscrowTokenKey, recipient, payout)
	}

	chain.Emit(
		eventName,
		"id", strconv.FormatUint(b.ID, 10),
		"sponsor", string(b.Sponsor),
		"claimant", string(recipient),
		"payout_ugnot", strconv.FormatInt(payout, 10),
		"rating", strconv.Itoa(int(rating)),
	)
}

// CancelBounty cancels an Open bounty and refunds each contributor directly.
// Third-party top-up coins are returned strictly to their original donors,
// never to the sponsor, and refunded sponsorship credits are reversed.
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

	totalRefund := b.EscrowUgnot
	sponsorRefund := b.SponsorFundedUgnot
	externalRefundTotal := int64(0)
	donorRefunds := make([]contributorRefund, 0)
	if b.DonorShares != nil {
		b.DonorShares.Iterate("", "", func(key string, val any) bool {
			amt := val.(int64)
			if amt > 0 {
				donorRefunds = append(donorRefunds, contributorRefund{
					addr:   address(key),
					amount: amt,
				})
				externalRefundTotal += amt
			}
			return false
		})
	}
	if sponsorRefund+externalRefundTotal != totalRefund {
		panic("hearthbounty: internal escrow custody invariant mismatch")
	}

	// Effects before interactions (CEI).
	b.EscrowUgnot = 0
	b.SponsorFundedUgnot = 0
	b.ExternalTopUpUgnot = 0
	b.DonorShares = avl.NewTree()
	b.RefundUgnot = totalRefund
	transitionStatus(b, hearthcore.StatusCancelled)
	totalEscrowUgnot -= totalRefund
	totalRefundUgnot += totalRefund

	decrementSponsoredCredit(b.Sponsor, sponsorRefund)
	for _, dr := range donorRefunds {
		decrementSponsoredCredit(dr.addr, dr.amount)
	}

	if sponsorRefund > 0 {
		grc20reg.Transfer(0, cur, EscrowTokenKey, b.Sponsor, sponsorRefund)
	}
	for _, dr := range donorRefunds {
		grc20reg.Transfer(0, cur, EscrowTokenKey, dr.addr, dr.amount)
	}

	chain.Emit(
		"BountyCancelled",
		"id", strconv.FormatUint(id, 10),
		"sponsor", string(b.Sponsor),
		"sponsor_refund_ugnot", strconv.FormatInt(sponsorRefund, 10),
		"external_refund_ugnot", strconv.FormatInt(externalRefundTotal, 10),
		"refund_ugnot", strconv.FormatInt(totalRefund, 10),
	)
}

// OpenDispute escalates a submitted bounty to arbiter review and sets a
// deterministic dispute resolution timeout.
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
	height := runtime.ChainHeight()
	transitionStatus(b, hearthcore.StatusDisputed)
	b.DisputeReason = cleanReason
	b.DisputeOpenedBy = caller
	b.DisputedHeight = height
	b.DisputeDeadlineHeight = height + b.DeadlineBlocks

	chain.Emit(
		"DisputeOpened",
		"id", strconv.FormatUint(id, 10),
		"opened_by", string(caller),
		"dispute_deadline_height", strconv.FormatInt(b.DisputeDeadlineHeight, 10),
		"reason", cleanReason,
	)
}

// ResolveDispute settles a disputed bounty using deterministic basis-point math
// (hunterBps in 0..10000). The arbiter cannot resolve a bounty they are a party
// to, and any refunded portion is returned pro-rata to sponsor and external donors.
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
	if caller == b.Sponsor || caller == b.Claimant {
		panic("hearthbounty: arbiter cannot resolve a bounty they are party to")
	}

	cleanResolution := hearthcore.ValidateText("resolution", resolution, 4, hearthcore.MaxNoteLen)
	settleDisputeSplit(cur, b, hunterBps, "[Arbiter Resolution] "+cleanResolution, caller, "DisputeResolved")
}

// ExpireDispute is callable by anyone once ChainHeight() reaches
// DisputeDeadlineHeight without arbiter action. It splits escrow 50/50
// (5000 bps to claimant, 5000 bps pro-rata back to contributors) so lost or
// conflicted arbiter keys can never trap escrowed wugnot forever.
func ExpireDispute(cur realm, id uint64) {
	b, ok := getBountyRecord(id)
	if !ok {
		panic("hearthbounty: bounty not found")
	}
	if b.Status != hearthcore.StatusDisputed {
		panic("hearthbounty: bounty is not disputed")
	}
	if runtime.ChainHeight() < b.DisputeDeadlineHeight {
		panic("hearthbounty: dispute resolution window has not expired yet")
	}

	caller := cur.Previous().Address()
	settleDisputeSplit(cur, b, 5000, "[Timeout Split 50/50] Arbiter resolution window expired", caller, "DisputeExpiredSplit")
}

func settleDisputeSplit(cur realm, b *bountyRecord, hunterBps uint64, reviewNote string, resolver address, eventName string) {
	escrow := b.EscrowUgnot
	_, sponsorRefund := hearthcore.ComputeSplit(b.SponsorFundedUgnot, hunterBps)

	donorRefunds := make([]contributorRefund, 0)
	totalRefunds := sponsorRefund
	if b.DonorShares != nil {
		b.DonorShares.Iterate("", "", func(key string, val any) bool {
			amt := val.(int64)
			if amt > 0 {
				_, dRefund := hearthcore.ComputeSplit(amt, hunterBps)
				if dRefund > 0 {
					donorRefunds = append(donorRefunds, contributorRefund{
						addr:   address(key),
						amount: dRefund,
					})
					totalRefunds += dRefund
				}
			}
			return false
		})
	}
	hunterShare := escrow - totalRefunds
	height := runtime.ChainHeight()

	// Effects before interactions (CEI).
	b.EscrowUgnot = 0
	b.SponsorFundedUgnot = 0
	b.ExternalTopUpUgnot = 0
	b.DonorShares = avl.NewTree()
	b.PayoutUgnot = hunterShare
	b.RefundUgnot = totalRefunds
	b.ReviewNote = reviewNote
	b.SettledHeight = height
	transitionStatus(b, hearthcore.StatusSettled)
	totalEscrowUgnot -= escrow
	totalSettledUgnot += hunterShare
	totalRefundUgnot += totalRefunds

	if hunterShare > 0 {
		hp := getOrCreateProfile(b.Claimant, height)
		hp.SettledCount++
		hp.EarnedUgnot += hunterShare
	}
	decrementSponsoredCredit(b.Sponsor, sponsorRefund)
	for _, dr := range donorRefunds {
		decrementSponsoredCredit(dr.addr, dr.amount)
	}

	if hunterShare > 0 {
		grc20reg.Transfer(0, cur, EscrowTokenKey, b.Claimant, hunterShare)
	}
	if sponsorRefund > 0 {
		grc20reg.Transfer(0, cur, EscrowTokenKey, b.Sponsor, sponsorRefund)
	}
	for _, dr := range donorRefunds {
		grc20reg.Transfer(0, cur, EscrowTokenKey, dr.addr, dr.amount)
	}

	chain.Emit(
		eventName,
		"id", strconv.FormatUint(b.ID, 10),
		"resolver", string(resolver),
		"hunter_bps", strconv.FormatUint(hunterBps, 10),
		"hunter_ugnot", strconv.FormatInt(hunterShare, 10),
		"sponsor_refund_ugnot", strconv.FormatInt(sponsorRefund, 10),
		"total_refund_ugnot", strconv.FormatInt(totalRefunds, 10),
	)
}

func normalizeFilter(raw string) string {
	return strings.ToLower(strings.TrimSpace(raw))
}
