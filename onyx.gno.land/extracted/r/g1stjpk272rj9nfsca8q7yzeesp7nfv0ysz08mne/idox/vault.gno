package idox

import (
	"chain"
	"chain/banker"
	"chain/runtime"
)

const blocksPerDay int64 = 43200

func IssueBadge(cur realm, builder address, handle string, badgeID string, badgeName string) {
	caller := cur.Previous().Address()
	if caller != adminAddr {
		panic("unauthorized: only admin can issue credentials")
	}

	profile := getOrCreateProfile(builder, handle)
	profile.Badges.Set(badgeID, &Badge{
		ID:          badgeID,
		Name:        badgeName,
		Issuer:      caller,
		IssuedBlock: runtime.ChainHeight(),
	})
}

func CreateVault(cur realm, title string, contractor address, milestoneTitles []string, requiredBadges []string, allocations []int64) uint64 {
	if len(milestoneTitles) == 0 || len(milestoneTitles) != len(requiredBadges) || len(milestoneTitles) != len(allocations) {
		panic("invalid milestone configuration")
	}

	var totalNeeded int64
	milestones := make([]*Milestone, len(milestoneTitles))
	for i := range milestoneTitles {
		if allocations[i] <= 0 {
			panic("milestone allocation must be positive")
		}
		totalNeeded += allocations[i]
		milestones[i] = &Milestone{
			ID:            i,
			Title:         milestoneTitles[i],
			RequiredBadge: requiredBadges[i],
			Allocation:    allocations[i],
			Status:        StatusPending,
		}
	}

	caller := cur.Previous().Address()
	originBanker := banker.NewBanker(banker.BankerTypeOriginSend, cur)
	originBanker.SendCoins(cur.Address(), cur.Address(), chain.Coins{chain.NewCoin("ugnot", totalNeeded)})

	id := vaultSeq.Next()
	v := &ProjectVault{
		ID:            uint64(id),
		Title:         title,
		Sponsor:       caller,
		Contractor:    contractor,
		TotalEscrowed: chain.NewCoin("ugnot", totalNeeded),
		Milestones:    milestones,
		CreatedBlock:  runtime.ChainHeight(),
	}

	vaults.Set(id.String(), v)
	return uint64(id)
}

func SubmitProof(cur realm, projectID uint64, milestoneID int, proofHash string) {
	v := getVault(projectID)
	if cur.Previous().Address() != v.Contractor {
		panic("unauthorized: only assigned contractor can submit proof")
	}
	if milestoneID < 0 || milestoneID >= len(v.Milestones) {
		panic("invalid milestone ID")
	}
	if proofHash == "" {
		panic("proof hash cannot be empty")
	}

	m := v.Milestones[milestoneID]
	if m.Status == StatusApproved {
		panic("milestone already approved")
	}

	m.ProofHash = proofHash
	m.Status = StatusSubmitted
}

func AIAuditAndRelease(cur realm, projectID uint64, milestoneID int, auditNote string) {
	caller := cur.Previous().Address()
	if caller != policy.AgentAddr {
		panic("unauthorized: caller is not registered AI agent")
	}
	if policy.Paused {
		panic("guardrail blocked: AI execution is paused")
	}

	v := getVault(projectID)
	if milestoneID < 0 || milestoneID >= len(v.Milestones) {
		panic("invalid milestone ID")
	}
	m := v.Milestones[milestoneID]
	if m.Status != StatusSubmitted {
		panic("milestone is not awaiting audit")
	}

	now := runtime.ChainHeight()

	if len(auditLogs) > 0 {
		lastLog := auditLogs[len(auditLogs)-1]
		if lastLog.Action == "APPROVED" && (now-lastLog.BlockHeight) < policy.CooldownBlocks {
			recordViolation(now, projectID, milestoneID, "CooldownBlocks violation")
			panic("guardrail blocked: cooldown period active")
		}
	}

	if m.Allocation > policy.MaxSinglePayout {
		recordViolation(now, projectID, milestoneID, "Exceeds MaxSinglePayout")
		panic("guardrail blocked: payout exceeds MaxSinglePayout")
	}

	if now-windowStartBk >= blocksPerDay {
		windowStartBk = now
		dailySpent = 0
	}
	if dailySpent+m.Allocation > policy.DailySpendLimit {
		recordViolation(now, projectID, milestoneID, "Exceeds DailySpendLimit")
		panic("guardrail blocked: payout exceeds DailySpendLimit")
	}

	rawProf := profiles.Get(v.Contractor.String())
	if rawProf == nil {
		recordViolation(now, projectID, milestoneID, "Contractor has no profile")
		panic("guardrail blocked: contractor has no verified profile")
	}
	profile := rawProf.(*BuilderProfile)
	if policy.RequireBadgeMatch && m.RequiredBadge != "" {
		if !profile.Badges.Has(m.RequiredBadge) {
			recordViolation(now, projectID, milestoneID, "Missing required badge: "+m.RequiredBadge)
			panic("guardrail blocked: contractor lacks required credential badge")
		}
	}

	m.Status = StatusApproved
	m.AuditNote = auditNote
	v.ReleasedAmount += m.Allocation
	dailySpent += m.Allocation

	profile.CompletedTasks++
	profile.TotalEarned += m.Allocation
	profile.ReputationScore += 10

	realmBanker := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	realmBanker.SendCoins(cur.Address(), v.Contractor, chain.Coins{chain.NewCoin("ugnot", m.Allocation)})

	auditLogs = append(auditLogs, &AuditLog{
		BlockHeight: now,
		ProjectID:   projectID,
		MilestoneID: milestoneID,
		Action:      "APPROVED",
		Reason:      auditNote,
	})
}

func recordViolation(height int64, projectID uint64, milestoneID int, reason string) {
	auditLogs = append(auditLogs, &AuditLog{
		BlockHeight: height,
		ProjectID:   projectID,
		MilestoneID: milestoneID,
		Action:      "BLOCKED_GUARDRAIL",
		Reason:      reason,
	})
}
