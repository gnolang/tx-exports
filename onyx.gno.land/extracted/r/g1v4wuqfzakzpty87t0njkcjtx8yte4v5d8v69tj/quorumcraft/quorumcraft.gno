// Package quorumcraft implements QuorumCraft, an on-chain Pairwise Quadratic
// Funding & Milestone Escrow Protocol for Gno.land.
//
// Core capabilities:
//   - Permissionless Quadratic Grant Rounds funded with real escrowed ugnot
//   - Deterministic anti-collusion matching via PairwiseQF (Vitalik Buterin 2019)
//   - Milestone-structured builder proposals (2-4 tranches summing to 100%)
//   - Quorum-gated proof attestation, dispute resolution, and atomic banker payouts
//   - Multi-page on-chain Markdown + SVG Render() explorer
package quorumcraft

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"strings"

	"gno.land/p/g1v4wuqfzakzpty87t0njkcjtx8yte4v5d8v69tj/qfmath"
	"gno.land/p/nt/avl/v0"
)

var (
	rounds        []*Round
	totalEscrowed int64
	totalReleased int64
	totalRefunded int64
)

// receiveUgnot validates and returns ugnot attached to a direct EOA call.
// If allowZero is true, zero coins are permitted without requiring an EOA send.
func receiveUgnot(cur realm, allowZero bool) int64 {
	sent := unsafe.OriginSend()
	if len(sent) == 0 {
		if allowZero {
			return 0
		}
		panic("quorumcraft: must send positive ugnot amount")
	}

	if !cur.Previous().IsUserCall() {
		panic("quorumcraft: direct user call (maketx call) required for coin transfers")
	}

	for _, c := range sent {
		if c.Denom != ugnotDenom {
			panic("quorumcraft: only ugnot denomination accepted")
		}
	}

	amt := sent.AmountOf(ugnotDenom)
	if amt <= 0 {
		if allowZero {
			return 0
		}
		panic("quorumcraft: must send positive ugnot amount")
	}

	// Verify real bank balance backs our escrowed accounting ledger.
	roBank := banker.NewReadonlyBanker()
	if roBank.GetCoin(cur.Address(), ugnotDenom) < totalEscrowed+amt {
		panic("quorumcraft: insufficient realm bank balance for reported send")
	}
	return amt
}

// CreateRound launches a new Quadratic Funding grant round.
// Any ugnot sent with the transaction is escrowed as the initial matching pool.
//
// Parameters:
//   - mode: 0 = StandardQF, 1 = PairwiseQF (anti-collusion)
//   - penaltyCoeff: pairwise damping factor M in ugnot (required > 0 for PairwiseQF)
//   - quorumBps: attestation quorum in basis points (1..10000, e.g. 5000 = 50%)
//   - durationBlocks: blocks until permissionless finalization (0 = sponsor-only close)
func CreateRound(
	cur realm,
	name string,
	description string,
	mode int,
	penaltyCoeff int64,
	quorumBps int64,
	durationBlocks int64,
) int {
	name = strings.TrimSpace(name)
	description = strings.TrimSpace(description)
	if name == "" || len(name) > 120 {
		panic("quorumcraft: invalid round name")
	}
	if len(description) > 1000 {
		panic("quorumcraft: round description too long")
	}
	qfMode := QFMode(mode)
	if qfMode != ModeStandardQF && qfMode != ModePairwiseQF {
		panic("quorumcraft: invalid QF mode (use 0=StandardQF or 1=PairwiseQF)")
	}
	if qfMode == ModePairwiseQF && penaltyCoeff <= 0 {
		panic("quorumcraft: PairwiseQF requires positive penaltyCoeff")
	}
	if quorumBps <= 0 || quorumBps > bpsFull {
		panic("quorumcraft: quorumBps must be between 1 and 10000")
	}
	if durationBlocks < 0 {
		panic("quorumcraft: durationBlocks cannot be negative")
	}

	initialPool := receiveUgnot(cur, true)
	sponsor := cur.Previous().Address()
	nowHeight := runtime.ChainHeight()
	var endHeight int64
	if durationBlocks > 0 {
		endHeight = nowHeight + durationBlocks
	}

	reviewers := avl.NewTree()
	reviewers.Set(sponsor.String(), true)

	roundID := len(rounds) + 1
	r := &Round{
		ID:           roundID,
		Sponsor:      sponsor,
		Name:         name,
		Description:  description,
		Mode:         qfMode,
		PenaltyCoeff: penaltyCoeff,
		QuorumBps:    quorumBps,
		EndHeight:    endHeight,
		MatchingPool: initialPool,
		Status:       RoundOpen,
		Reviewers:    reviewers,
		Donors:       avl.NewTree(),
		Proposals:    make([]*Proposal, 0),
		CreatedAt:    nowHeight,
	}
	rounds = append(rounds, r)
	totalEscrowed += initialPool

	chain.Emit(
		"RoundCreated",
		"roundId", strconv.Itoa(roundID),
		"sponsor", sponsor.String(),
		"mode", qfMode.String(),
		"matchingPool", strconv.FormatInt(initialPool, 10),
	)
	return roundID
}

// FundMatchingPool adds escrowed ugnot to an open round's matching pool.
func FundMatchingPool(cur realm, roundID int) {
	r := mustGetRound(roundID)
	if r.Status != RoundOpen {
		panic("quorumcraft: round is already finalized")
	}
	amt := receiveUgnot(cur, false)
	r.MatchingPool += amt
	totalEscrowed += amt

	chain.Emit(
		"MatchingPoolFunded",
		"roundId", strconv.Itoa(roundID),
		"funder", cur.Previous().Address().String(),
		"amount", strconv.FormatInt(amt, 10),
		"newPool", strconv.FormatInt(r.MatchingPool, 10),
	)
}

// AddReviewer authorizes an additional reviewer address to attest or dispute
// milestones for proposals in the specified round. Sponsor-only.
func AddReviewer(cur realm, roundID int, reviewer address) {
	r := mustGetRound(roundID)
	caller := cur.Previous().Address()
	if caller != r.Sponsor {
		panic("quorumcraft: only round sponsor can add reviewers")
	}
	if !reviewer.IsValid() {
		panic("quorumcraft: invalid reviewer address")
	}
	r.Reviewers.Set(reviewer.String(), true)

	chain.Emit(
		"ReviewerAdded",
		"roundId", strconv.Itoa(roundID),
		"reviewer", reviewer.String(),
	)
}

// parseMilestoneSpec parses "Title1:3000|Title2:4000|Title3:3000" into 2..4 milestones
// whose basis points strictly sum to 10000 (100.00%).
func parseMilestoneSpec(spec string) []*Milestone {
	spec = strings.TrimSpace(spec)
	if spec == "" {
		panic("quorumcraft: milestoneSpec required")
	}
	parts := strings.Split(spec, "|")
	if len(parts) < minMilestones || len(parts) > maxMilestones {
		panic("quorumcraft: proposal must define 2 to 4 milestones")
	}

	milestones := make([]*Milestone, len(parts))
	var sumBps int64
	for i, part := range parts {
		part = strings.TrimSpace(part)
		sep := strings.LastIndex(part, ":")
		if sep <= 0 || sep == len(part)-1 {
			panic("quorumcraft: invalid milestone format (expected Title:Bps)")
		}
		title := strings.TrimSpace(part[:sep])
		bpsStr := strings.TrimSpace(part[sep+1:])
		if title == "" || len(title) > 100 {
			panic("quorumcraft: invalid milestone title")
		}
		bps, err := strconv.ParseInt(bpsStr, 10, 64)
		if err != nil || bps <= 0 || bps > bpsFull {
			panic("quorumcraft: invalid milestone basis points")
		}
		sumBps += bps
		milestones[i] = &Milestone{
			Index:     i,
			Title:     title,
			Bps:       bps,
			Status:    MilestonePending,
			Approvals: avl.NewTree(),
		}
	}
	if sumBps != bpsFull {
		panic("quorumcraft: milestone basis points must sum to 10000")
	}
	return milestones
}

// SubmitProposal registers a milestone-structured builder proposal in an open round.
// milestoneSpec format: "M1 Spec & Tests:3000|M2 Testnet Deploy:4000|M3 Mainnet Audit:3000"
func SubmitProposal(
	cur realm,
	roundID int,
	title string,
	repoURL string,
	summary string,
	milestoneSpec string,
) int {
	r := mustGetRound(roundID)
	if r.Status != RoundOpen {
		panic("quorumcraft: round is already finalized")
	}
	title = strings.TrimSpace(title)
	repoURL = strings.TrimSpace(repoURL)
	summary = strings.TrimSpace(summary)
	if title == "" || len(title) > 120 {
		panic("quorumcraft: invalid proposal title")
	}
	if len(repoURL) > 240 {
		panic("quorumcraft: repoURL too long")
	}
	if summary == "" || len(summary) > 1500 {
		panic("quorumcraft: invalid proposal summary")
	}

	milestones := parseMilestoneSpec(milestoneSpec)
	recipient := cur.Previous().Address()
	propID := len(r.Proposals) + 1

	p := &Proposal{
		ID:            propID,
		RoundID:       roundID,
		Recipient:     recipient,
		Title:         title,
		RepoURL:       repoURL,
		Summary:       summary,
		DonorContribs: avl.NewTree(),
		Milestones:    milestones,
		CreatedAt:     runtime.ChainHeight(),
	}
	r.Proposals = append(r.Proposals, p)

	chain.Emit(
		"ProposalSubmitted",
		"roundId", strconv.Itoa(roundID),
		"proposalId", strconv.Itoa(propID),
		"recipient", recipient.String(),
		"milestones", strconv.Itoa(len(milestones)),
	)
	return propID
}

// Contribute sends real escrowed ugnot directly to a proposal during an open round.
// Repeat contributions from the same donor aggregate into their single matrix cell,
// preventing trivial split-transaction quadratic amplification.
func Contribute(cur realm, roundID int, proposalID int) {
	r := mustGetRound(roundID)
	if r.Status != RoundOpen {
		panic("quorumcraft: round is already finalized")
	}
	p := mustGetProposal(r, proposalID)
	donor := cur.Previous().Address()
	if donor == p.Recipient {
		panic("quorumcraft: proposal recipient cannot self-contribute")
	}

	amt := receiveUgnot(cur, false)
	donorKey := donor.String()

	var prevProp int64
	if v := p.DonorContribs.Get(donorKey); v != nil {
		prevProp = v.(int64)
	}
	p.DonorContribs.Set(donorKey, prevProp+amt)
	p.DirectTotal += amt

	var prevRound int64
	if v := r.Donors.Get(donorKey); v != nil {
		prevRound = v.(int64)
	}
	r.Donors.Set(donorKey, prevRound+amt)
	r.DirectTotal += amt
	totalEscrowed += amt

	chain.Emit(
		"ContributionReceived",
		"roundId", strconv.Itoa(roundID),
		"proposalId", strconv.Itoa(proposalID),
		"donor", donorKey,
		"amount", strconv.FormatInt(amt, 10),
	)
}

// buildContributionMatrix constructs the deterministic [numProposals][numDonors]
// matrix ordered by proposal ID and lexicographically sorted donor address.
func buildContributionMatrix(r *Round) (matrix [][]int64, donorWeights []int64) {
	numProps := len(r.Proposals)
	numDonors := r.Donors.Size()
	donorKeys := make([]string, 0, numDonors)
	donorWeights = make([]int64, 0, numDonors)
	r.Donors.Iterate("", "", func(key string, val any) bool {
		donorKeys = append(donorKeys, key)
		donorWeights = append(donorWeights, val.(int64))
		return false
	})

	matrix = make([][]int64, numProps)
	for pi, p := range r.Proposals {
		row := make([]int64, numDonors)
		for di, dk := range donorKeys {
			if v := p.DonorContribs.Get(dk); v != nil {
				row[di] = v.(int64)
			}
		}
		matrix[pi] = row
	}
	return matrix, donorWeights
}

// PreviewRoundMatching returns live deterministic StandardQF and PairwiseQF
// matching allocations for a round without mutating state.
func PreviewRoundMatching(roundID int) (stdAlloc []int64, pwAlloc []int64) {
	r := mustGetRound(roundID)
	if len(r.Proposals) == 0 || r.MatchingPool == 0 {
		return make([]int64, len(r.Proposals)), make([]int64, len(r.Proposals))
	}
	matrix, _ := buildContributionMatrix(r)
	stdAlloc = qfmath.StandardQF(matrix, r.MatchingPool)
	if r.PenaltyCoeff > 0 {
		pwAlloc = qfmath.PairwiseQF(matrix, r.MatchingPool, r.PenaltyCoeff)
	} else {
		pwAlloc = stdAlloc
	}
	return stdAlloc, pwAlloc
}

// FinalizeRound locks the round's matching distribution via qfmath.PairwiseQF
// (or qfmath.StandardQF) and credits every proposal's Milestone Escrow.
//
// Callable by the round Sponsor at any time, or permissionlessly by anyone once
// runtime.ChainHeight() >= r.EndHeight (when durationBlocks > 0).
// If no contributions were made, the matching pool is refunded to the Sponsor.
func FinalizeRound(cur realm, roundID int) {
	r := mustGetRound(roundID)
	if r.Status != RoundOpen {
		panic("quorumcraft: round is already finalized")
	}

	caller := cur.Previous().Address()
	nowHeight := runtime.ChainHeight()
	if caller != r.Sponsor {
		if r.EndHeight == 0 || nowHeight < r.EndHeight {
			panic("quorumcraft: only sponsor can finalize before round end height")
		}
	}

	r.Status = RoundFinalized
	r.FinalizedAt = nowHeight

	// Refund matching pool cleanly if no funded proposals exist.
	if len(r.Proposals) == 0 || r.DirectTotal == 0 {
		refund := r.MatchingPool
		r.MatchingPool = 0
		if refund > 0 {
			totalEscrowed -= refund
			totalRefunded += refund
			b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
			b.SendCoins(cur.Address(), r.Sponsor, chain.NewCoins(chain.NewCoin(ugnotDenom, refund)))
		}
		chain.Emit(
			"RoundFinalized",
			"roundId", strconv.Itoa(roundID),
			"mode", r.Mode.String(),
			"refundedPool", strconv.FormatInt(refund, 10),
		)
		return
	}

	matrix, _ := buildContributionMatrix(r)
	stdAlloc := qfmath.StandardQF(matrix, r.MatchingPool)
	finalAlloc := stdAlloc
	if r.Mode == ModePairwiseQF {
		finalAlloc = qfmath.PairwiseQF(matrix, r.MatchingPool, r.PenaltyCoeff)
	}

	for i, p := range r.Proposals {
		p.StandardQFMatched = stdAlloc[i]
		p.MatchedGrant = finalAlloc[i]
	}

	chain.Emit(
		"RoundFinalized",
		"roundId", strconv.Itoa(roundID),
		"mode", r.Mode.String(),
		"matchingPool", strconv.FormatInt(r.MatchingPool, 10),
		"directTotal", strconv.FormatInt(r.DirectTotal, 10),
	)
}

// SubmitMilestoneProof allows the proposal recipient to submit deliverable proof
// (URI + commit hash) for a pending milestone once the round is finalized.
func SubmitMilestoneProof(
	cur realm,
	roundID int,
	proposalID int,
	milestoneIdx int,
	proofURI string,
	commitHash string,
) {
	r := mustGetRound(roundID)
	if r.Status != RoundFinalized {
		panic("quorumcraft: round must be finalized before submitting milestone proof")
	}
	p := mustGetProposal(r, proposalID)
	caller := cur.Previous().Address()
	if caller != p.Recipient {
		panic("quorumcraft: only proposal recipient can submit milestone proof")
	}
	if p.TotalGrant() <= 0 {
		panic("quorumcraft: proposal has zero funded escrow")
	}
	m := mustGetMilestone(p, milestoneIdx)
	if m.Status != MilestonePending {
		panic("quorumcraft: milestone is not in PENDING state")
	}

	proofURI = strings.TrimSpace(proofURI)
	commitHash = strings.TrimSpace(commitHash)
	if proofURI == "" || len(proofURI) > 300 {
		panic("quorumcraft: invalid proofURI")
	}
	if commitHash == "" || len(commitHash) > 100 {
		panic("quorumcraft: invalid commitHash")
	}

	m.ProofURI = proofURI
	m.CommitHash = commitHash
	m.SubmittedAt = runtime.ChainHeight()
	m.Status = MilestoneSubmitted

	chain.Emit(
		"MilestoneProofSubmitted",
		"roundId", strconv.Itoa(roundID),
		"proposalId", strconv.Itoa(proposalID),
		"milestoneIdx", strconv.Itoa(milestoneIdx),
		"commitHash", commitHash,
	)
}

// isEligibleAttestor checks whether addr is a round reviewer, round sponsor, or
// direct contributor to proposal p (and NOT the proposal recipient).
func isEligibleAttestor(r *Round, p *Proposal, addr address) bool {
	if addr == p.Recipient {
		return false
	}
	key := addr.String()
	if r.Reviewers.Has(key) {
		return true
	}
	if p.DonorContribs.Has(key) {
		return true
	}
	return false
}

// EligibleAttestorCount counts the unique eligible attestors (reviewers U donors \ {recipient}).
func EligibleAttestorCount(r *Round, p *Proposal) int {
	recKey := p.Recipient.String()
	seen := avl.NewTree()
	r.Reviewers.Iterate("", "", func(key string, _ any) bool {
		if key != recKey {
			seen.Set(key, true)
		}
		return false
	})
	p.DonorContribs.Iterate("", "", func(key string, _ any) bool {
		if key != recKey {
			seen.Set(key, true)
		}
		return false
	})
	return seen.Size()
}

// RequiredQuorum computes ceil(eligibleCount * QuorumBps / 10000), minimum 1.
func RequiredQuorum(r *Round, p *Proposal) int {
	eligible := EligibleAttestorCount(r, p)
	if eligible <= 0 {
		return 1
	}
	req := int((int64(eligible)*r.QuorumBps + bpsFull - 1) / bpsFull)
	if req < 1 {
		req = 1
	}
	return req
}

// AttestMilestone records an approval vote from an eligible reviewer/sponsor/donor
// for a submitted milestone proof.
func AttestMilestone(cur realm, roundID int, proposalID int, milestoneIdx int) {
	r := mustGetRound(roundID)
	if r.Status != RoundFinalized {
		panic("quorumcraft: round is not finalized")
	}
	p := mustGetProposal(r, proposalID)
	m := mustGetMilestone(p, milestoneIdx)
	if m.Status != MilestoneSubmitted {
		panic("quorumcraft: milestone is not awaiting attestation")
	}

	caller := cur.Previous().Address()
	if !isEligibleAttestor(r, p, caller) {
		panic("quorumcraft: caller is not an eligible attestor for this proposal")
	}
	key := caller.String()
	if m.Approvals.Has(key) {
		panic("quorumcraft: caller has already attested this milestone")
	}

	m.Approvals.Set(key, true)
	m.ApprovalCount++

	chain.Emit(
		"MilestoneAttested",
		"roundId", strconv.Itoa(roundID),
		"proposalId", strconv.Itoa(proposalID),
		"milestoneIdx", strconv.Itoa(milestoneIdx),
		"attestor", key,
		"approvals", strconv.Itoa(m.ApprovalCount),
		"required", strconv.Itoa(RequiredQuorum(r, p)),
	)
}

// DisputeMilestone flags a submitted milestone proof as disputed, halting escrow
// release until the round sponsor resolves the dispute.
func DisputeMilestone(cur realm, roundID int, proposalID int, milestoneIdx int, reason string) {
	r := mustGetRound(roundID)
	if r.Status != RoundFinalized {
		panic("quorumcraft: round is not finalized")
	}
	p := mustGetProposal(r, proposalID)
	m := mustGetMilestone(p, milestoneIdx)
	if m.Status != MilestoneSubmitted {
		panic("quorumcraft: only SUBMITTED milestones can be disputed")
	}

	caller := cur.Previous().Address()
	if !isEligibleAttestor(r, p, caller) {
		panic("quorumcraft: caller is not eligible to dispute this milestone")
	}
	reason = strings.TrimSpace(reason)
	if reason == "" || len(reason) > 500 {
		panic("quorumcraft: invalid dispute reason")
	}

	m.Status = MilestoneDisputed
	m.DisputeReason = reason
	m.DisputedBy = caller

	chain.Emit(
		"MilestoneDisputed",
		"roundId", strconv.Itoa(roundID),
		"proposalId", strconv.Itoa(proposalID),
		"milestoneIdx", strconv.Itoa(milestoneIdx),
		"disputedBy", caller.String(),
	)
}

// ProposalTrancheAmount returns the exact ugnot payout for milestone idx,
// assigning any integer division dust to the final milestone so all tranches
// sum strictly to proposal.TotalGrant().
func ProposalTrancheAmount(p *Proposal, idx int) int64 {
	total := p.TotalGrant()
	if total <= 0 || idx < 0 || idx >= len(p.Milestones) {
		return 0
	}
	var allocated int64
	lastIdx := len(p.Milestones) - 1
	for i := 0; i <= lastIdx; i++ {
		if i == lastIdx {
			if idx == i {
				return total - allocated
			}
			break
		}
		tranche := (total * p.Milestones[i].Bps) / bpsFull
		if idx == i {
			return tranche
		}
		allocated += tranche
	}
	return 0
}

// ReleaseMilestone atomically disburses a milestone's escrowed ugnot tranche to
// the proposal recipient once quorum approvals are met and no dispute is active.
func ReleaseMilestone(cur realm, roundID int, proposalID int, milestoneIdx int) int64 {
	r := mustGetRound(roundID)
	if r.Status != RoundFinalized {
		panic("quorumcraft: round is not finalized")
	}
	p := mustGetProposal(r, proposalID)
	m := mustGetMilestone(p, milestoneIdx)
	if m.Status != MilestoneSubmitted {
		panic("quorumcraft: milestone is not eligible for release")
	}

	req := RequiredQuorum(r, p)
	if m.ApprovalCount < req {
		panic("quorumcraft: milestone has not reached attestation quorum")
	}

	payout := ProposalTrancheAmount(p, milestoneIdx)
	if payout <= 0 {
		panic("quorumcraft: zero tranche payout")
	}

	// Checks-Effects-Interactions: update ledger before sending coins.
	m.Status = MilestoneReleased
	m.ReleasedAmount = payout
	p.EscrowReleased += payout
	totalEscrowed -= payout
	totalReleased += payout

	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	b.SendCoins(cur.Address(), p.Recipient, chain.NewCoins(chain.NewCoin(ugnotDenom, payout)))

	chain.Emit(
		"MilestoneReleased",
		"roundId", strconv.Itoa(roundID),
		"proposalId", strconv.Itoa(proposalID),
		"milestoneIdx", strconv.Itoa(milestoneIdx),
		"recipient", p.Recipient.String(),
		"amount", strconv.FormatInt(payout, 10),
	)
	return payout
}

// ResolveDispute allows the round sponsor to resolve a DISPUTED milestone by
// either releasing the tranche to the recipient (releaseToRecipient=true) or
// slashing/refunding that tranche back to the round sponsor (releaseToRecipient=false).
func ResolveDispute(
	cur realm,
	roundID int,
	proposalID int,
	milestoneIdx int,
	releaseToRecipient bool,
) int64 {
	r := mustGetRound(roundID)
	caller := cur.Previous().Address()
	if caller != r.Sponsor {
		panic("quorumcraft: only round sponsor can resolve disputes")
	}
	p := mustGetProposal(r, proposalID)
	m := mustGetMilestone(p, milestoneIdx)
	if m.Status != MilestoneDisputed {
		panic("quorumcraft: milestone is not disputed")
	}

	tranche := ProposalTrancheAmount(p, milestoneIdx)
	if tranche <= 0 {
		panic("quorumcraft: zero tranche amount")
	}

	var dest address
	var outcome string
	if releaseToRecipient {
		m.Status = MilestoneReleased
		m.ReleasedAmount = tranche
		p.EscrowReleased += tranche
		totalEscrowed -= tranche
		totalReleased += tranche
		dest = p.Recipient
		outcome = "RELEASED"
	} else {
		m.Status = MilestoneRefunded
		p.EscrowRefunded += tranche
		totalEscrowed -= tranche
		totalRefunded += tranche
		dest = r.Sponsor
		outcome = "REFUNDED"
	}

	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	b.SendCoins(cur.Address(), dest, chain.NewCoins(chain.NewCoin(ugnotDenom, tranche)))

	chain.Emit(
		"DisputeResolved",
		"roundId", strconv.Itoa(roundID),
		"proposalId", strconv.Itoa(proposalID),
		"milestoneIdx", strconv.Itoa(milestoneIdx),
		"outcome", outcome,
		"destination", dest.String(),
		"amount", strconv.FormatInt(tranche, 10),
	)
	return tranche
}

// GetProtocolStats returns aggregate escrow & round metrics.
func GetProtocolStats() ProtocolStats {
	stats := ProtocolStats{
		RoundCount:    len(rounds),
		TotalEscrowed: totalEscrowed,
		TotalReleased: totalReleased,
		TotalRefunded: totalRefunded,
	}
	for _, r := range rounds {
		if r.Status == RoundOpen {
			stats.OpenRounds++
		}
		stats.ProposalCount += len(r.Proposals)
	}
	return stats
}

// GetRound returns the round struct for read-only inspection.
func GetRound(roundID int) *Round {
	return mustGetRound(roundID)
}

func mustGetRound(roundID int) *Round {
	if roundID < 1 || roundID > len(rounds) {
		panic("quorumcraft: round not found")
	}
	return rounds[roundID-1]
}

func mustGetProposal(r *Round, proposalID int) *Proposal {
	if proposalID < 1 || proposalID > len(r.Proposals) {
		panic("quorumcraft: proposal not found")
	}
	return r.Proposals[proposalID-1]
}

func mustGetMilestone(p *Proposal, milestoneIdx int) *Milestone {
	if milestoneIdx < 0 || milestoneIdx >= len(p.Milestones) {
		panic("quorumcraft: milestone index out of range")
	}
	return p.Milestones[milestoneIdx]
}
