package memba_weighted_host

import "strconv"

func (h *Host) escrowConfigJSON() string {
	if h.escrowPolicy == nil {
		return ""
	}
	return `,"escrowPolicy":{"target":` + quoteJSON(EscrowPath) + `,"successor":` + quoteJSON(string(h.escrowPolicy.Successor())) + `,"resolutionCategory":"financial","unpauseCategory":"financial","feeRecipientCategory":"financial","emergencyPause":true,"returnStagesOnly":true,"invalidatesOtherProposals":true}`
}
func escrowNumber(n int64) string { return quoteJSON(strconv.FormatInt(n, 10)) }

// Only dispute actions name a milestone; for the others it is null, so it
// cannot be mistaken for milestone 0.
func escrowMilestoneJSON(a EscrowAction) string {
	if a.Kind() != EscrowRefundClient && a.Kind() != EscrowPayFreelancer {
		return "null"
	}
	return escrowNumber(int64(a.Milestone()))
}
func escrowStateJSON(s EscrowState) string {
	c := s.Contract
	milestones := "["
	for i := 0; i < c.Count; i++ {
		if i > 0 {
			milestones += ","
		}
		m := c.Milestones[i]
		milestones += `{"id":` + escrowNumber(int64(m.ID)) + `,"amount":` + escrowNumber(m.Amount) + `,"status":` + quoteJSON(m.Status) + `,"fundedAt":` + escrowNumber(m.FundedAt) + `,"completedAt":` + escrowNumber(m.CompletedAt) + `,"disputedAt":` + escrowNumber(m.DisputedAt) + `,"preDisputeStatus":` + quoteJSON(m.PreDisputeStatus) + `}`
	}
	milestones += "]"
	return `{"owner":` + quoteJSON(string(s.Owner)) + `,"pendingOwner":` + quoteJSON(string(s.PendingOwner)) + `,"feeRecipient":` + quoteJSON(string(s.FeeRecipient)) + `,"pendingFeeRecipient":` + quoteJSON(string(s.PendingFeeRecipient)) + `,"paused":` + strconv.FormatBool(s.Paused) + `,"pausedAt":` + escrowNumber(s.PausedAt) + `,"exitsReopenAt":` + escrowNumber(s.ExitsReopenAt) + `,"cooldownUntil":` + escrowNumber(s.CooldownUntil) + `,"contract":{"exists":` + strconv.FormatBool(c.Exists) + `,"id":` + quoteJSON(c.ID) + `,"contentHash":` + quoteJSON(c.ContentHash) + `,"status":` + quoteJSON(c.Status) + `,"client":` + quoteJSON(string(c.Client)) + `,"freelancer":` + quoteJSON(string(c.Freelancer)) + `,"count":` + escrowNumber(int64(c.Count)) + `,"milestones":` + milestones + `},"fees":{"rawBPS":` + escrowNumber(s.Fees.RawBPS) + `,"effectiveBPS":` + escrowNumber(s.Fees.EffectiveBPS) + `,"rawTreasury":` + quoteJSON(string(s.Fees.RawTreasury)) + `,"fallbackTreasury":` + quoteJSON(string(s.Fees.FallbackTreasury)) + `,"effectiveTreasury":` + quoteJSON(string(s.Fees.EffectiveTreasury)) + `}}`
}
func escrowActionJSON(a EscrowAction, s EscrowState) string {
	return `{"type":"escrow","target":` + quoteJSON(EscrowPath) + `,"operation":` + quoteJSON(string(a.Kind())) + `,"recipient":` + quoteJSON(string(a.Recipient())) + `,"contractId":` + quoteJSON(a.ContractID()) + `,"milestoneIndex":` + escrowMilestoneJSON(a) + `,"before":` + escrowStateJSON(s) + `}`
}
