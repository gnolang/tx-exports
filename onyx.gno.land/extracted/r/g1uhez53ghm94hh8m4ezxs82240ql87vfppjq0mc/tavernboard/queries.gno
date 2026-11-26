package tavernboard

import (
	"strconv"
	"strings"

	"gno.land/p/g1uhez53ghm94hh8m4ezxs82240ql87vfppjq0mc/tavernkit"
)

// -----------------------------------------------------------------------------
// Composable Cross-Realm & Off-Chain Read APIs
// Every getter returns pure value copies (never pointers to internal state).
// -----------------------------------------------------------------------------

// GetStats returns aggregate realm-wide escrow and reputation metrics.
func GetStats() BoardStats {
	return BoardStats{
		TotalBounties:     statTotalBounties,
		OpenBounties:      statOpenBounties,
		CompletedBounties: statCompletedBounties,
		DisputesResolved:  statDisputesResolved,
		TotalFundedUgnot:  statTotalFundedUgnot,
		TotalPaidUgnot:    statTotalPaidUgnot,
		ActiveEscrowUgnot: statActiveEscrowUgnot,
		RankedBuilders:    profiles.Size(),
		ArchivedBounties:  statArchivedBounties,
	}
}

// GetReputation returns the deterministic ReputationScore for any address.
// Designed for other Gno.land realms and DAOs to gate proposals, grant tiers,
// or reviewer privileges based on verified TavernBoard delivery history.
func GetReputation(addr address) tavernkit.ReputationScore {
	return tavernkit.ComputeReputation(profileToReputationInput(getProfileReadOnly(addr)))
}

// HasCraftTier reports whether addr has earned at least minTier on TavernBoard.
// Example composable check from another DAO realm:
//
//	if !tavernboard.HasCraftTier(caller, tavernkit.TierArtisan) { panic("artisan rank required") }
func HasCraftTier(addr address, minTier tavernkit.CraftTier) bool {
	return GetReputation(addr).Tier >= minTier
}

// GetProfile returns an immutable snapshot of a participant's complete stats.
func GetProfile(addr address) ProfileSnapshot {
	p := getProfileReadOnly(addr)
	score := tavernkit.ComputeReputation(profileToReputationInput(p))
	if p == nil {
		return ProfileSnapshot{
			Address: addr,
			Score:   score,
		}
	}
	return ProfileSnapshot{
		Address:            p.addr,
		Score:              score,
		CompletedBounties:  p.completedBounties,
		ApprovedMilestones: p.approvedMilestones,
		TotalEarnedUgnot:   p.totalEarnedUgnot,
		ReviewsAligned:     p.reviewsAligned,
		ReviewsSlashed:     p.reviewsSlashed,
		DisputesWon:        p.disputesWon,
		DisputesLost:       p.disputesLost,
		BountiesPosted:     p.bountiesPosted,
		BountiesClaimed:    p.bountiesClaimed,
	}
}

// GetBounty returns an immutable snapshot of a bounty and its live sub-realm
// vault balances. Returns (zero, false) if bountyID does not exist.
func GetBounty(bountyID uint64) (BountySnapshot, bool) {
	b := getBounty(bountyID)
	if b == nil {
		return BountySnapshot{}, false
	}
	escrowAddr := DeriveEscrowAddress(b.id)
	stakeAddr := DeriveStakeAddress(b.id)
	settled := 0
	for _, m := range b.milestones {
		if m.status.IsTerminal() {
			settled++
		}
	}
	return BountySnapshot{
		ID:                    b.id,
		Title:                 b.title,
		Summary:               b.summary,
		Tags:                  b.tags,
		Sponsor:               b.sponsor,
		Builder:               b.builder,
		Status:                b.status,
		TotalFundedUgnot:      b.totalFundedUgnot,
		TotalReleasedUgnot:    b.totalReleasedUgnot,
		TotalRefundedUgnot:    b.totalRefundedUgnot,
		EscrowVaultAddr:       escrowAddr,
		StakeVaultAddr:        stakeAddr,
		EscrowVaultLiveUgnot:  liveVaultUgnot(escrowAddr),
		StakeVaultLiveUgnot:   liveVaultUgnot(stakeAddr),
		CreatedAtUnix:         b.createdAt.Unix(),
		DeadlineUnix:          b.deadline.Unix(),
		MinReviewerStakeUgnot: b.minReviewerStakeUgnot,
		ReviewerQuorum:        b.reviewerQuorum,
		MilestoneCount:        len(b.milestones),
		SettledMilestones:     settled,
		Archived:              b.archived,
	}, true
}

// GetMilestones returns an immutable slice of milestone snapshots for bountyID.
func GetMilestones(bountyID uint64) []MilestoneSnapshot {
	b := getBounty(bountyID)
	if b == nil {
		return nil
	}
	out := make([]MilestoneSnapshot, len(b.milestones))
	for i, m := range b.milestones {
		snap := MilestoneSnapshot{
			Index:           m.index,
			Title:           m.title,
			WeightBps:       m.weightBps,
			PayoutUgnot:     m.payoutUgnot,
			Status:          m.status,
			ProofURL:        m.proofURL,
			DeliveryNotes:   m.deliveryNotes,
			SponsorFeedback: m.sponsorFeedback,
			RevisionCount:   m.revisionCount,
		}
		if m.dispute != nil {
			snap.HasDispute = true
			snap.ApproveVotes = m.dispute.approveCount
			snap.RejectVotes = m.dispute.rejectCount
			snap.DisputeResolved = m.dispute.resolved
			snap.BuilderWon = m.dispute.builderWon
		}
		out[i] = snap
	}
	return out
}

// GetBoardJSON returns a clean, compact JSON snapshot of the board stats and
// most recent bounties (up to limit, max 25) for zero-friction querying via
// `vm/qeval` or `vm/qeval_json` from web explorers, indexers, and AI agents.
func GetBoardJSON(limit int) string {
	if limit <= 0 || limit > 25 {
		limit = 20
	}
	st := GetStats()
	var sb strings.Builder
	sb.WriteString(`{"stats":{`)
	sb.WriteString(`"totalBounties":` + strconv.FormatInt(st.TotalBounties, 10))
	sb.WriteString(`,"openBounties":` + strconv.FormatInt(st.OpenBounties, 10))
	sb.WriteString(`,"completedBounties":` + strconv.FormatInt(st.CompletedBounties, 10))
	sb.WriteString(`,"disputesResolved":` + strconv.FormatInt(st.DisputesResolved, 10))
	sb.WriteString(`,"totalFundedUgnot":` + strconv.FormatInt(st.TotalFundedUgnot, 10))
	sb.WriteString(`,"totalPaidUgnot":` + strconv.FormatInt(st.TotalPaidUgnot, 10))
	sb.WriteString(`,"activeEscrowUgnot":` + strconv.FormatInt(st.ActiveEscrowUgnot, 10))
	sb.WriteString(`,"rankedBuilders":` + strconv.Itoa(st.RankedBuilders))
	sb.WriteString(`,"archivedBounties":` + strconv.FormatInt(st.ArchivedBounties, 10))
	sb.WriteString(`},"bounties":[`)

	count := 0
	bounties.ReverseIterate("", "", func(_ string, val any) bool {
		if count >= limit {
			return true
		}
		b := val.(*bounty)
		if count > 0 {
			sb.WriteString(",")
		}
		writeBountyJSON(&sb, b)
		count++
		return false
	})

	sb.WriteString(`]}`)
	return sb.String()
}

func writeBountyJSON(sb *strings.Builder, b *bounty) {
	escrowAddr := DeriveEscrowAddress(b.id)
	settled := 0
	for _, m := range b.milestones {
		if m.status.IsTerminal() {
			settled++
		}
	}
	sb.WriteString(`{"id":` + strconv.FormatUint(b.id, 10))
	sb.WriteString(`,"title":` + jsonQuote(b.title))
	sb.WriteString(`,"tags":` + jsonQuote(b.tags))
	sb.WriteString(`,"sponsor":` + jsonQuote(b.sponsor.String()))
	sb.WriteString(`,"builder":` + jsonQuote(b.builder.String()))
	sb.WriteString(`,"status":` + jsonQuote(b.status.String()))
	sb.WriteString(`,"fundedUgnot":` + strconv.FormatInt(b.totalFundedUgnot, 10))
	sb.WriteString(`,"releasedUgnot":` + strconv.FormatInt(b.totalReleasedUgnot, 10))
	sb.WriteString(`,"escrowVault":` + jsonQuote(escrowAddr.String()))
	sb.WriteString(`,"escrowLiveUgnot":` + strconv.FormatInt(liveVaultUgnot(escrowAddr), 10))
	sb.WriteString(`,"milestones":` + strconv.Itoa(len(b.milestones)))
	sb.WriteString(`,"settledMilestones":` + strconv.Itoa(settled))
	sb.WriteString(`,"deadlineUnix":` + strconv.FormatInt(b.deadline.Unix(), 10))
	sb.WriteString(`,"archived":` + strconv.FormatBool(b.archived))
	sb.WriteString(`}`)
}

func jsonQuote(s string) string {
	var sb strings.Builder
	sb.WriteByte('"')
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch c {
		case '"':
			sb.WriteString(`\"`)
		case '\\':
			sb.WriteString(`\\`)
		case '\n':
			sb.WriteString(`\n`)
		case '\r':
			sb.WriteString(`\r`)
		case '\t':
			sb.WriteString(`\t`)
		default:
			if c < 0x20 {
				sb.WriteString(" ")
			} else {
				sb.WriteByte(c)
			}
		}
	}
	sb.WriteByte('"')
	return sb.String()
}
