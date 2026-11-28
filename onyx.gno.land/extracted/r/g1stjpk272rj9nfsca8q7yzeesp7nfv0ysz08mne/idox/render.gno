package idox

import (
	"strconv"
	"strings"

	"gno.land/p/nt/mux/v0"
	"gno.land/p/nt/seqid/v0"
	"gno.land/p/nt/ufmt/v0"
)

const realmBase = "/r/g1stjpk272rj9nfsca8q7yzeesp7nfv0ysz08mne/idox"

func Render(path string) string {
	router := mux.NewRouter()
	router.HandleFunc("", renderHome)
	router.HandleFunc("vault/{id}", renderVaultDetail)
	router.HandleFunc("builder/{addr}", renderBuilderProfile)
	router.HandleFunc("audits", renderAuditLog)
	router.HandleFunc("agent/pending", renderAgentPending)
	return router.Render(path)
}

func renderHome(res *mux.ResponseWriter, req *mux.Request) {
	var sb strings.Builder

	totalEscrowed := int64(0)
	totalReleased := int64(0)
	vaults.Iterate("", "", func(key string, value any) bool {
		v := value.(*ProjectVault)
		totalEscrowed += v.TotalEscrowed.Amount
		totalReleased += v.ReleasedAmount
		return false
	})

	sb.WriteString("# Idox: AI-Guarded RWA Milestone & Credential Vault\n\n")
	sb.WriteString("Deterministic escrow, on-chain trade credentials, and hard spending guardrails for autonomous AI auditors.\n\n")

	sb.WriteString(ufmt.Sprintf(
		"> **Status:** %s · **Vaults:** %d · **Verified Builders:** %d · **Total Escrowed:** %s · **Released:** %s\n\n",
		circuitStatusLabel(),
		vaults.Size(),
		profiles.Size(),
		formatGNOT(totalEscrowed),
		formatGNOT(totalReleased),
	))

	pauseActionLabel := "Emergency Pause"
	if policy.Paused {
		pauseActionLabel = "Resume Vaults"
	}
	sb.WriteString(ufmt.Sprintf(
		"**Quick Actions:** [+ Create Funded Vault](%s) · [+ Issue Badge](%s) · [Configure Guardrails](%s) · [%s](%s) · [Full Audit Log (%d)](%s:audits)\n\n---\n\n",
		helpLink("CreateVaultCSV"),
		helpLink("IssueBadge"),
		helpLink("SetGuardrailPolicy"),
		pauseActionLabel,
		pauseToggleLink(),
		len(auditLogs),
		realmBase,
	))

	sb.WriteString("## Active AI Guardrail Policy\n\n| Parameter | Enforced Value |\n| :--- | :--- |\n")
	sb.WriteString(ufmt.Sprintf("| **Circuit Breaker** | %s |\n", circuitStatusLabel()))
	sb.WriteString(ufmt.Sprintf("| **Authorized AI Agent** | `%s` |\n", policy.AgentAddr.String()))
	sb.WriteString(ufmt.Sprintf("| **Realm Admin** | `%s` |\n", adminAddr.String()))
	sb.WriteString(ufmt.Sprintf("| **Max Single Payout** | **%s** (`%d ugnot`) |\n", formatGNOT(policy.MaxSinglePayout), policy.MaxSinglePayout))
	sb.WriteString(ufmt.Sprintf("| **Rolling 24h Spend** | %s **%s** / %s |\n", progressBar(dailySpent, policy.DailySpendLimit, 10), formatGNOT(dailySpent), formatGNOT(policy.DailySpendLimit)))
	sb.WriteString(ufmt.Sprintf("| **Cooldown Window** | %d blocks |\n", policy.CooldownBlocks))
	badgePolicyLabel := "OPTIONAL"
	if policy.RequireBadgeMatch {
		badgePolicyLabel = "**REQUIRED** (enforced on release)"
	}
	sb.WriteString(ufmt.Sprintf("| **Trade Badge Verification** | %s |\n\n", badgePolicyLabel))

	sb.WriteString("## Project Escrow Vaults\n\n")
	if vaults.Size() == 0 {
		sb.WriteString("_No project vaults created yet._ Use [**+ Create Funded Vault**](" + helpLink("CreateVaultCSV") + ") to deploy one.\n\n")
	} else {
		sb.WriteString("| ID | Project Title | Contractor | Escrow Progress | Released / Total | Milestones |\n| :--- | :--- | :--- | :--- | :--- | :--- |\n")
		vaults.Iterate("", "", func(key string, value any) bool {
			v := value.(*ProjectVault)
			paidCount := countApprovedMilestones(v)
			sb.WriteString(ufmt.Sprintf(
				"| [#%d](%s:vault/%d) | [%s](%s:vault/%d) | %s | %s | %s / %s | %d/%d paid |\n",
				v.ID, realmBase, v.ID, v.Title, realmBase, v.ID,
				contractorLink(v.Contractor),
				progressBar(v.ReleasedAmount, v.TotalEscrowed.Amount, 10),
				formatGNOT(v.ReleasedAmount), formatGNOT(v.TotalEscrowed.Amount),
				paidCount, len(v.Milestones),
			))
			return false
		})
		sb.WriteString("\n")
	}

	sb.WriteString("## Verified Builder Registry\n\n")
	if profiles.Size() == 0 {
		sb.WriteString("_No builders registered yet._ Use [**+ Issue Badge**](" + helpLink("IssueBadge") + ") to register a contractor.\n\n")
	} else {
		sb.WriteString("| Handle | Address | Verified Badges | Completed | Verified Earnings | Reputation |\n| :--- | :--- | :--- | :--- | :--- | :--- |\n")
		profiles.Iterate("", "", func(key string, value any) bool {
			p := value.(*BuilderProfile)
			sb.WriteString(ufmt.Sprintf(
				"| [%s](%s:builder/%s) | `%s` | %s | %d | %s | **%d pts** |\n",
				p.Handle, realmBase, p.Addr.String(), shortAddr(p.Addr),
				badgeSummary(p), p.CompletedTasks, formatGNOT(p.TotalEarned), p.ReputationScore,
			))
			return false
		})
		sb.WriteString("\n")
	}

	sb.WriteString("## Recent AI Audit & Guardrail Log\n\n")
	if len(auditLogs) == 0 {
		sb.WriteString("_No AI audit events recorded yet._\n")
	} else {
		sb.WriteString("| Block | Vault | Milestone | Action | Note / Violation |\n| :--- | :--- | :--- | :--- | :--- |\n")
		limit := len(auditLogs) - 10
		if limit < 0 {
			limit = 0
		}
		for i := len(auditLogs) - 1; i >= limit; i-- {
			log := auditLogs[i]
			sb.WriteString(ufmt.Sprintf(
				"| %d | [#%d](%s:vault/%d) | #%d | **%s** | %s |\n",
				log.BlockHeight, log.ProjectID, realmBase, log.ProjectID, log.MilestoneID, log.Action, log.Reason,
			))
		}
		if len(auditLogs) > 10 {
			sb.WriteString(ufmt.Sprintf("\n[View all %d audit events →](%s:audits)\n", len(auditLogs), realmBase))
		}
	}

	res.Write(sb.String())
}

func renderVaultDetail(res *mux.ResponseWriter, req *mux.Request) {
	id, err := strconv.ParseUint(req.GetVar("id"), 10, 64)
	if err != nil {
		res.Write("# Error\n\nInvalid project ID.\n\n[← Back to Dashboard](" + realmBase + ")\n")
		return
	}

	v := findVault(id)
	if v == nil {
		res.Write(ufmt.Sprintf("# Vault #%d Not Found\n\nNo project vault exists with ID `%d`.\n\n[← Back to Dashboard](%s)\n", id, id, realmBase))
		return
	}

	var sb strings.Builder
	remaining := v.TotalEscrowed.Amount - v.ReleasedAmount

	sb.WriteString(ufmt.Sprintf("[← Dashboard](%s) · [All Audits](%s:audits) · [Submit Proof](%s) · [AI Audit & Release](%s)\n\n",
		realmBase, realmBase, helpLink("SubmitProof"), helpLink("AIAuditAndRelease")))
	sb.WriteString(ufmt.Sprintf("# Project Vault #%d: %s\n\n", v.ID, v.Title))
	sb.WriteString("| Field | Details |\n| :--- | :--- |\n")
	sb.WriteString(ufmt.Sprintf("| **Sponsor** | `%s` |\n", v.Sponsor.String()))
	sb.WriteString(ufmt.Sprintf("| **Contractor** | %s (`%s`) |\n", contractorLink(v.Contractor), shortAddr(v.Contractor)))
	sb.WriteString(ufmt.Sprintf("| **Created Block** | #%d |\n", v.CreatedBlock))
	sb.WriteString(ufmt.Sprintf("| **Escrow Progress** | %s |\n", progressBar(v.ReleasedAmount, v.TotalEscrowed.Amount, 12)))
	sb.WriteString(ufmt.Sprintf("| **Released / Total** | **%s** / %s (Remaining: %s) |\n\n",
		formatGNOT(v.ReleasedAmount), formatGNOT(v.TotalEscrowed.Amount), formatGNOT(remaining)))

	sb.WriteString("## Draw Schedule & Milestones\n\n")
	sb.WriteString("| # | Milestone | Required Badge | Allocation | Status | Proof | AI Audit Note | Action |\n| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |\n")
	for _, m := range v.Milestones {
		badgeCell := "None"
		if m.RequiredBadge != "" {
			if contractorHasBadge(v.Contractor, m.RequiredBadge) {
				badgeCell = ufmt.Sprintf("`%s` ✓", m.RequiredBadge)
			} else {
				badgeCell = ufmt.Sprintf("`%s` ✗ ([Issue](%s))", m.RequiredBadge, helpLink("IssueBadge"))
			}
		}

		note := m.AuditNote
		if note == "" {
			note = "—"
		}

		actionCell := "—"
		switch m.Status {
		case StatusPending:
			actionCell = ufmt.Sprintf("[Submit Proof](%s)", helpLink("SubmitProof"))
		case StatusSubmitted:
			actionCell = ufmt.Sprintf("[Audit & Release](%s)", helpLink("AIAuditAndRelease"))
		case StatusApproved:
			actionCell = "Paid"
		case StatusRejected:
			actionCell = ufmt.Sprintf("[Resubmit](%s)", helpLink("SubmitProof"))
		}

		sb.WriteString(ufmt.Sprintf(
			"| %d | %s | %s | **%s** | %s | %s | %s | %s |\n",
			m.ID, m.Title, badgeCell, formatGNOT(m.Allocation), statusLabel(m.Status), formatProof(m.ProofHash), note, actionCell,
		))
	}

	sb.WriteString("\n## Vault Audit History\n\n")
	foundLogs := false
	for i := len(auditLogs) - 1; i >= 0; i-- {
		if auditLogs[i].ProjectID == v.ID {
			if !foundLogs {
				sb.WriteString("| Block | Milestone | Action | Note / Violation |\n| :--- | :--- | :--- | :--- |\n")
				foundLogs = true
			}
			log := auditLogs[i]
			sb.WriteString(ufmt.Sprintf("| %d | #%d | **%s** | %s |\n", log.BlockHeight, log.MilestoneID, log.Action, log.Reason))
		}
	}
	if !foundLogs {
		sb.WriteString("_No audit events recorded for this vault yet._\n")
	}

	sb.WriteString(ufmt.Sprintf("\n[← Back to Dashboard](%s)\n", realmBase))
	res.Write(sb.String())
}

func renderBuilderProfile(res *mux.ResponseWriter, req *mux.Request) {
	addrStr := req.GetVar("addr")
	raw := profiles.Get(addrStr)
	if raw == nil {
		res.Write(ufmt.Sprintf("# Builder Not Found\n\nNo profile exists for `%s`.\n\n[+ Issue First Badge](%s) · [← Back to Dashboard](%s)\n",
			addrStr, helpLink("IssueBadge"), realmBase))
		return
	}

	p := raw.(*BuilderProfile)
	var sb strings.Builder

	sb.WriteString(ufmt.Sprintf("[← Dashboard](%s) · [+ Assign New Vault](%s) · [+ Issue Badge](%s)\n\n",
		realmBase, helpLink("CreateVaultCSV", "contractor", p.Addr.String()), helpLink("IssueBadge")))
	sb.WriteString(ufmt.Sprintf("# Builder Profile: %s\n\n", p.Handle))
	sb.WriteString("| Metric | Value |\n| :--- | :--- |\n")
	sb.WriteString(ufmt.Sprintf("| **Address** | `%s` |\n", p.Addr.String()))
	sb.WriteString(ufmt.Sprintf("| **Completed Milestones** | %d |\n", p.CompletedTasks))
	sb.WriteString(ufmt.Sprintf("| **Total Verified Earnings** | **%s** (`%d ugnot`) |\n", formatGNOT(p.TotalEarned), p.TotalEarned))
	sb.WriteString(ufmt.Sprintf("| **Reputation Score** | **%d pts** |\n\n", p.ReputationScore))

	sb.WriteString("## Verified Trade Credentials\n\n")
	if p.Badges.Size() == 0 {
		sb.WriteString("_No badges issued yet._\n\n")
	} else {
		sb.WriteString("| Badge ID | Credential Name | Issuer | Issued Block |\n| :--- | :--- | :--- | :--- |\n")
		p.Badges.Iterate("", "", func(key string, value any) bool {
			b := value.(*Badge)
			sb.WriteString(ufmt.Sprintf("| `%s` | **%s** | `%s` | #%d |\n", b.ID, b.Name, shortAddr(b.Issuer), b.IssuedBlock))
			return false
		})
		sb.WriteString("\n")
	}

	sb.WriteString("## Assigned Project Vaults\n\n")
	hasVaults := false
	vaults.Iterate("", "", func(key string, value any) bool {
		v := value.(*ProjectVault)
		if v.Contractor == p.Addr {
			if !hasVaults {
				sb.WriteString("| ID | Project Title | Escrow Progress | Released / Total |\n| :--- | :--- | :--- | :--- |\n")
				hasVaults = true
			}
			sb.WriteString(ufmt.Sprintf("| [#%d](%s:vault/%d) | [%s](%s:vault/%d) | %s | %s / %s |\n",
				v.ID, realmBase, v.ID, v.Title, realmBase, v.ID,
				progressBar(v.ReleasedAmount, v.TotalEscrowed.Amount, 10),
				formatGNOT(v.ReleasedAmount), formatGNOT(v.TotalEscrowed.Amount)))
		}
		return false
	})
	if !hasVaults {
		sb.WriteString("_No vaults assigned to this builder yet._\n")
	}

	sb.WriteString(ufmt.Sprintf("\n[← Back to Dashboard](%s)\n", realmBase))
	res.Write(sb.String())
}

func renderAuditLog(res *mux.ResponseWriter, req *mux.Request) {
	var sb strings.Builder
	sb.WriteString(ufmt.Sprintf("[← Back to Dashboard](%s)\n\n# Idox AI Audit & Guardrail Log\n\n", realmBase))
	sb.WriteString(ufmt.Sprintf("Total recorded events: **%d**\n\n", len(auditLogs)))

	if len(auditLogs) == 0 {
		sb.WriteString("_No AI audit events recorded yet._\n")
	} else {
		sb.WriteString("| Block | Vault | Milestone | Action | Note / Violation |\n| :--- | :--- | :--- | :--- | :--- |\n")
		for i := len(auditLogs) - 1; i >= 0; i-- {
			log := auditLogs[i]
			sb.WriteString(ufmt.Sprintf("| %d | [#%d](%s:vault/%d) | #%d | **%s** | %s |\n",
				log.BlockHeight, log.ProjectID, realmBase, log.ProjectID, log.MilestoneID, log.Action, log.Reason))
		}
	}
	res.Write(sb.String())
}

func findVault(projectID uint64) *ProjectVault {
	raw := vaults.Get(seqid.ID(projectID).String())
	if raw == nil {
		return nil
	}
	return raw.(*ProjectVault)
}

func countApprovedMilestones(v *ProjectVault) int {
	n := 0
	for _, m := range v.Milestones {
		if m.Status == StatusApproved {
			n++
		}
	}
	return n
}

func contractorHasBadge(contractor address, badgeID string) bool {
	if badgeID == "" {
		return true
	}
	raw := profiles.Get(contractor.String())
	if raw == nil {
		return false
	}
	return raw.(*BuilderProfile).Badges.Get(badgeID) != nil
}

func contractorLink(addr address) string {
	label := shortAddr(addr)
	if raw := profiles.Get(addr.String()); raw != nil {
		p := raw.(*BuilderProfile)
		if p.Handle != "" {
			label = p.Handle
		}
	}
	return ufmt.Sprintf("[%s](%s:builder/%s)", label, realmBase, addr.String())
}

func badgeSummary(p *BuilderProfile) string {
	if p.Badges.Size() == 0 {
		return "None"
	}
	var ids []string
	p.Badges.Iterate("", "", func(key string, value any) bool {
		b := value.(*Badge)
		ids = append(ids, "`"+b.ID+"`")
		return false
	})
	return strings.Join(ids, ", ")
}

func circuitStatusLabel() string {
	if policy.Paused {
		return "🔴 **PAUSED**"
	}
	return "🟢 **ACTIVE**"
}

func statusLabel(s MilestoneStatus) string {
	switch s {
	case StatusPending:
		return "⏳ PENDING"
	case StatusSubmitted:
		return "📤 SUBMITTED"
	case StatusApproved:
		return "✅ APPROVED"
	case StatusRejected:
		return "❌ REJECTED"
	default:
		return "UNKNOWN"
	}
}

func formatGNOT(ugnot int64) string {
	neg := ""
	if ugnot < 0 {
		neg = "-"
		ugnot = -ugnot
	}
	whole := ugnot / 1_000_000
	frac := (ugnot % 1_000_000) / 10_000
	fracStr := strconv.FormatInt(frac, 10)
	if frac < 10 {
		fracStr = "0" + fracStr
	}
	return neg + strconv.FormatInt(whole, 10) + "." + fracStr + " GNOT"
}

func progressBar(current, total int64, width int) string {
	if total <= 0 || width <= 0 {
		return "`[" + strings.Repeat("░", width) + "] 0%`"
	}
	pct := (current * 100) / total
	if pct < 0 {
		pct = 0
	}
	if pct > 100 {
		pct = 100
	}
	filled := int((current * int64(width)) / total)
	if filled < 0 {
		filled = 0
	}
	if filled > width {
		filled = width
	}
	return "`[" + strings.Repeat("█", filled) + strings.Repeat("░", width-filled) + "] " + strconv.FormatInt(pct, 10) + "%`"
}

func formatProof(proof string) string {
	if proof == "" {
		return "—"
	}
	if strings.HasPrefix(proof, "ipfs://") {
		cid := strings.TrimPrefix(proof, "ipfs://")
		shortCID := cid
		if len(shortCID) > 14 {
			shortCID = shortCID[:8] + "..." + shortCID[len(shortCID)-4:]
		}
		return ufmt.Sprintf("[ipfs://%s](https://ipfs.io/ipfs/%s)", shortCID, cid)
	}
	return "`" + proof + "`"
}

func helpLink(fn string, kv ...string) string {
	var sb strings.Builder
	sb.WriteString(realmBase)
	sb.WriteString("$help&func=")
	sb.WriteString(fn)
	for i := 0; i+1 < len(kv); i += 2 {
		sb.WriteString("&")
		sb.WriteString(kv[i])
		sb.WriteString("=")
		sb.WriteString(kv[i+1])
	}
	return sb.String()
}

func pauseToggleLink() string {
	nextPaused := "true"
	if policy.Paused {
		nextPaused = "false"
	}
	reqBadge := "false"
	if policy.RequireBadgeMatch {
		reqBadge = "true"
	}
	return helpLink(
		"SetGuardrailPolicy",
		"agent", policy.AgentAddr.String(),
		"maxSingle", strconv.FormatInt(policy.MaxSinglePayout, 10),
		"dailyLimit", strconv.FormatInt(policy.DailySpendLimit, 10),
		"cooldown", strconv.FormatInt(policy.CooldownBlocks, 10),
		"requireBadge", reqBadge,
		"paused", nextPaused,
	)
}

func shortAddr(a address) string {
	s := a.String()
	if len(s) <= 12 {
		return s
	}
	return s[:6] + "..." + s[len(s)-4:]
}
