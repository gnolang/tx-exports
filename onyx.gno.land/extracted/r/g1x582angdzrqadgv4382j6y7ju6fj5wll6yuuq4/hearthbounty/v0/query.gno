package hearthbounty

import (
	"chain/runtime"
	"sort"

	"gno.land/p/g1x582angdzrqadgv4382j6y7ju6fj5wll6yuuq4/hearthcore/v0"
)

// Arbiter returns the current dispute arbiter address.
func Arbiter() address {
	return arbiter
}

// GetStats returns an immutable snapshot of protocol counters and escrow totals.
func GetStats() BoardStats {
	return BoardStats{
		TotalBounties:     bounties.Size(),
		OpenCount:         openCount,
		ClaimedCount:      claimedCount,
		SubmittedCount:    submittedCount,
		DisputedCount:     disputedCount,
		SettledCount:      settledCount,
		CancelledCount:    cancelledCount,
		ProfileCount:      profiles.Size(),
		AgentCount:        agentCount,
		TotalEscrowUgnot:  totalEscrowUgnot,
		TotalSettledUgnot: totalSettledUgnot,
		TotalRefundUgnot:  totalRefundUgnot,
	}
}

// GetBounty returns a value copy of a single bounty by ID.
func GetBounty(id uint64) (BountyView, bool) {
	b, ok := getBountyRecord(id)
	if !ok {
		return BountyView{}, false
	}
	return toBountyView(b), true
}

// GetProfile returns a value copy of a builder or AI agent profile.
func GetProfile(addr address) (ProfileView, bool) {
	raw := profiles.Get(string(addr))
	if raw == nil {
		return ProfileView{}, false
	}
	return toProfileView(raw.(*profileRecord)), true
}

// ExportStatsJSON returns global protocol stats as deterministic JSON for MCP agents.
func ExportStatsJSON() string {
	s := GetStats()
	return hearthcore.NewJSONObject().
		Str("realm_path", realmWebBase).
		Str("arbiter", string(arbiter)).
		Int64("chain_height", runtime.ChainHeight()).
		Int64("total_bounties", int64(s.TotalBounties)).
		Int64("open_count", int64(s.OpenCount)).
		Int64("claimed_count", int64(s.ClaimedCount)).
		Int64("submitted_count", int64(s.SubmittedCount)).
		Int64("disputed_count", int64(s.DisputedCount)).
		Int64("settled_count", int64(s.SettledCount)).
		Int64("cancelled_count", int64(s.CancelledCount)).
		Int64("profile_count", int64(s.ProfileCount)).
		Int64("agent_count", int64(s.AgentCount)).
		Int64("total_escrow_ugnot", s.TotalEscrowUgnot).
		Int64("total_settled_ugnot", s.TotalSettledUgnot).
		Int64("total_refund_ugnot", s.TotalRefundUgnot).
		String()
}

// ExportBountyJSON returns a single bounty as deterministic JSON (or {"found":false}).
func ExportBountyJSON(id uint64) string {
	b, ok := getBountyRecord(id)
	if !ok {
		return `{"found":false}`
	}
	return encodeBountyJSON(b, true)
}

// ExportBountiesJSON lists bounties in reverse chronological order with optional
// status, category, and minimum reward filters for autonomous agent discovery.
func ExportBountiesJSON(statusFilter, categoryFilter string, minRewardUgnot int64, limit int) string {
	st := normalizeFilter(statusFilter)
	cat := normalizeFilter(categoryFilter)
	if limit <= 0 || limit > 100 {
		limit = 50
	}

	items := make([]string, 0)
	bounties.ReverseIterate("", "", func(_ string, val any) bool {
		b := val.(*bountyRecord)
		if st != "" && string(b.Status) != st {
			return false
		}
		if cat != "" && string(b.Category) != cat {
			return false
		}
		reward := effectiveReward(b)
		if minRewardUgnot > 0 && reward < minRewardUgnot {
			return false
		}
		items = append(items, encodeBountyJSON(b, false))
		return len(items) >= limit
	})

	return hearthcore.NewJSONObject().
		Int64("chain_height", runtime.ChainHeight()).
		Int64("count", int64(len(items))).
		Raw("bounties", hearthcore.JoinJSONArray(items)).
		String()
}

// ExportLeaderboardJSON returns deterministically sorted builders & AI agents.
func ExportLeaderboardJSON(limit int) string {
	if limit <= 0 || limit > 100 {
		limit = 25
	}
	ranked := rankedProfiles()
	if len(ranked) > limit {
		ranked = ranked[:limit]
	}

	items := make([]string, 0, len(ranked))
	for i, p := range ranked {
		items = append(items, encodeProfileJSON(p, i+1))
	}

	return hearthcore.NewJSONObject().
		Int64("count", int64(len(items))).
		Raw("leaderboard", hearthcore.JoinJSONArray(items)).
		String()
}

// ExportProfileJSON returns a single profile as deterministic JSON.
func ExportProfileJSON(addrStr string) string {
	raw := profiles.Get(addrStr)
	if raw == nil {
		return `{"found":false}`
	}
	p := raw.(*profileRecord)
	return encodeProfileJSON(p, 0)
}

func effectiveReward(b *bountyRecord) int64 {
	if b.EscrowUgnot > 0 {
		return b.EscrowUgnot
	}
	if b.PayoutUgnot > 0 {
		return b.PayoutUgnot
	}
	if b.RefundUgnot > 0 {
		return b.RefundUgnot
	}
	return b.InitialUgnot
}

func encodeBountyJSON(b *bountyRecord, includeFound bool) string {
	jb := hearthcore.NewJSONObject()
	if includeFound {
		jb.Bool("found", true)
	}
	jb.Uint64("id", b.ID).
		Str("title", b.Title).
		Str("spec", b.Spec).
		Str("category", string(b.Category)).
		Str("status", string(b.Status)).
		Str("sponsor", string(b.Sponsor)).
		Str("claimant", string(b.Claimant)).
		Str("claim_note", b.ClaimNote).
		Int64("escrow_ugnot", b.EscrowUgnot).
		Int64("initial_ugnot", b.InitialUgnot).
		Int64("payout_ugnot", b.PayoutUgnot).
		Int64("refund_ugnot", b.RefundUgnot).
		Str("reward_formatted", hearthcore.FormatGNOT(effectiveReward(b))).
		Uint64("top_up_count", b.TopUpCount).
		Int64("deadline_blocks", b.DeadlineBlocks).
		Int64("created_height", b.CreatedHeight).
		Int64("claimed_height", b.ClaimedHeight).
		Int64("deadline_height", b.DeadlineHeight).
		Int64("submitted_height", b.SubmittedHeight).
		Int64("settled_height", b.SettledHeight).
		Str("proof_url", b.ProofURL).
		Str("proof_digest", b.ProofDigest).
		Str("proof_summary", b.ProofSummary).
		Uint64("submission_count", b.SubmissionCount).
		Str("revision_feedback", b.RevisionFeedback).
		Uint64("rating", uint64(b.Rating)).
		Str("review_note", b.ReviewNote).
		Str("dispute_reason", b.DisputeReason).
		Str("dispute_opened_by", string(b.DisputeOpenedBy))
	return jb.String()
}

func encodeProfileJSON(p *profileRecord, rank int) string {
	tier := hearthcore.ComputeTier(p.SettledCount, p.EarnedUgnot, p.RatingSum, p.RatingCount)
	jb := hearthcore.NewJSONObject()
	if rank == 0 {
		jb.Bool("found", true)
	} else {
		jb.Int64("rank", int64(rank))
	}
	jb.Str("address", string(p.Address)).
		Str("handle", p.Handle).
		Str("bio", p.Bio).
		Str("skills", p.Skills).
		Str("agent_endpoint", p.AgentEndpoint).
		Bool("is_agent", p.IsAgent).
		Str("tier", string(tier)).
		Uint64("posted_count", p.PostedCount).
		Uint64("claimed_count", p.ClaimedCount).
		Uint64("settled_count", p.SettledCount).
		Uint64("sponsored_settled", p.SponsoredSettled).
		Int64("earned_ugnot", p.EarnedUgnot).
		Str("earned_formatted", hearthcore.FormatGNOT(p.EarnedUgnot)).
		Int64("sponsored_ugnot", p.SponsoredUgnot).
		Str("rating_formatted", hearthcore.FormatRating(p.RatingSum, p.RatingCount)).
		Uint64("rating_sum", p.RatingSum).
		Uint64("rating_count", p.RatingCount)
	return jb.String()
}

type profileRankSlice []*profileRecord

func (s profileRankSlice) Len() int { return len(s) }
func (s profileRankSlice) Swap(i, j int) {
	s[i], s[j] = s[j], s[i]
}
func (s profileRankSlice) Less(i, j int) bool {
	a, b := s[i], s[j]
	if a.EarnedUgnot != b.EarnedUgnot {
		return a.EarnedUgnot > b.EarnedUgnot
	}
	if a.SettledCount != b.SettledCount {
		return a.SettledCount > b.SettledCount
	}
	if a.SponsoredUgnot != b.SponsoredUgnot {
		return a.SponsoredUgnot > b.SponsoredUgnot
	}
	return string(a.Address) < string(b.Address)
}

func rankedProfiles() []*profileRecord {
	list := make([]*profileRecord, 0, profiles.Size())
	profiles.Iterate("", "", func(_ string, val any) bool {
		list = append(list, val.(*profileRecord))
		return false
	})

	sort.Sort(profileRankSlice(list))
	return list
}
