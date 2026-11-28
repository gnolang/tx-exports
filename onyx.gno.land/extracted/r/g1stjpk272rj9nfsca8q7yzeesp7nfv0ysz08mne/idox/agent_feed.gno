package idox

import (
	"strings"

	"gno.land/p/nt/mux/v0"
	"gno.land/p/nt/ufmt/v0"
)

func renderAgentPending(res *mux.ResponseWriter, req *mux.Request) {
	var sb strings.Builder

	lastApproved := int64(0)
	for i := len(auditLogs) - 1; i >= 0; i-- {
		if auditLogs[i].Action == "APPROVED" {
			lastApproved = auditLogs[i].BlockHeight
			break
		}
	}

	sb.WriteString(ufmt.Sprintf(
		"POLICY|%t|%s|%d|%d|%d|%d|%t|%d\n",
		policy.Paused,
		policy.AgentAddr.String(),
		policy.MaxSinglePayout,
		policy.DailySpendLimit,
		dailySpent,
		policy.CooldownBlocks,
		policy.RequireBadgeMatch,
		lastApproved,
	))

	vaults.Iterate("", "", func(key string, value any) bool {
		v := value.(*ProjectVault)
		for _, m := range v.Milestones {
			if m.Status != StatusSubmitted {
				continue
			}
			hasBadge := contractorHasBadge(v.Contractor, m.RequiredBadge)
			sb.WriteString(ufmt.Sprintf(
				"ITEM|%d|%d|%s|%s|%t|%d|%s|%s\n",
				v.ID,
				m.ID,
				v.Contractor.String(),
				sanitizeFeedField(m.RequiredBadge),
				hasBadge,
				m.Allocation,
				sanitizeFeedField(m.ProofHash),
				sanitizeFeedField(m.Title),
			))
		}
		return false
	})

	res.Write(sb.String())
}

func sanitizeFeedField(s string) string {
	s = strings.ReplaceAll(s, "|", "/")
	s = strings.ReplaceAll(s, "\n", " ")
	return strings.TrimSpace(s)
}
