package milestonevault

import (
	"chain/banker"
	"chain/runtime"
	"strconv"
	"strings"

	"gno.land/p/g1p8ssx7g7fz268k6jc0krpu9enuen4hjvf4599j/escrowmath"
)

// Render serves both rich gnoweb Markdown views and deterministic JSON API endpoints:
//   - ""               -> Protocol dashboard & vault directory
//   - "vault/<id>"     -> Detailed vault view with isolated sub-realm solvency audit
//   - "builder/<addr>" -> Portable on-chain builder reputation profile
//   - "api/stats"      -> Machine-readable JSON protocol stats + builder registry
//   - "api/vaults"     -> Machine-readable JSON array of all vaults
//   - "api/vault/<id>" -> Machine-readable JSON single vault
func Render(path string) string {
	path = strings.Trim(path, "/")

	switch {
	case path == "":
		return renderHome()
	case path == "api/stats":
		return renderStatsJSON()
	case path == "api/vaults":
		return renderVaultsJSON()
	case strings.HasPrefix(path, "api/vault/"):
		idStr := strings.TrimPrefix(path, "api/vault/")
		id, err := strconv.Atoi(idStr)
		if err != nil || id < 1 || id > len(vaults) {
			return `{"error":"vault not found"}`
		}
		return renderSingleVaultJSON(vaults[id-1], banker.NewReadonlyBanker())
	case strings.HasPrefix(path, "vault/"):
		idStr := strings.TrimPrefix(path, "vault/")
		id, err := strconv.Atoi(idStr)
		if err != nil || id < 1 || id > len(vaults) {
			return "# Vault Not Found\n\nInvalid vault ID: `" + idStr + "`."
		}
		return renderVaultDetail(vaults[id-1])
	case strings.HasPrefix(path, "builder/"):
		addr := address(strings.TrimPrefix(path, "builder/"))
		return renderBuilderProfile(addr)
	default:
		return "# MilestoneVault\n\nUnknown route: `" + path + "`.\n\nReturn to [Dashboard](:)."
	}
}

func renderHome() string {
	ro := banker.NewReadonlyBanker()
	var openN, activeN, completedN, disputedN int
	var liveLocked int64
	for _, v := range vaults {
		liveLocked += ro.GetCoin(v.EscrowAddr, DenomUGNOT)
		switch v.Status {
		case VaultStatusOpen:
			openN++
		case VaultStatusActive:
			activeN++
		case VaultStatusCompleted:
			completedN++
		case VaultStatusDisputed:
			disputedN++
		}
	}

	var sb strings.Builder
	sb.WriteString("# MilestoneVault — Isolated Sub-Realm Milestone Escrow\n\n")
	sb.WriteString("Trustless on-chain milestone bounties, deadman timeout protection, and arbiter-quorum arbitration on **Gno.land**.\n")
	sb.WriteString("Every vault holds its escrowed `ugnot` inside a dedicated **Gno v1.8.0 `cur.Sub(\"v<id>\")` isolated sub-realm account**, provably auditable via the bank keeper.\n\n")

	sb.WriteString("## Protocol Metrics (`" + runtime.ChainID() + "` · Block `#" + strconv.FormatInt(runtime.ChainHeight(), 10) + "`)\n\n")
	sb.WriteString("| Metric | Value |\n")
	sb.WriteString("|---|---|\n")
	sb.WriteString("| Total Vaults | **" + strconv.Itoa(len(vaults)) + "** (" + strconv.Itoa(openN) + " open · " + strconv.Itoa(activeN) + " active · " + strconv.Itoa(disputedN) + " disputed · " + strconv.Itoa(completedN) + " completed) |\n")
	sb.WriteString("| Live Sub-Realm TVL | **" + escrowmath.FormatUGNOT(liveLocked) + "** (`" + strconv.FormatInt(liveLocked, 10) + " ugnot`) |\n")
	sb.WriteString("| Total Deposited | " + escrowmath.FormatUGNOT(totalDepositedUgnot) + " |\n")
	sb.WriteString("| Total Paid to Builders | **" + escrowmath.FormatUGNOT(totalReleasedUgnot) + "** |\n")
	sb.WriteString("| JSON Endpoints | [`api/stats`](:api/stats) · [`api/vaults`](:api/vaults) |\n\n")

	sb.WriteString("## Escrow Vault Directory\n\n")
	if len(vaults) == 0 {
		sb.WriteString("_No vaults created yet. Call `CreateVault` with `--send <amount>ugnot` to deploy the first isolated escrow._\n\n")
	} else {
		sb.WriteString("| ID | Vault | Status | Deposit | Live Sub-Balance | Progress | Details |\n")
		sb.WriteString("|---|---|---|---|---|---|---|\n")
		for _, v := range vaults {
			subBal := ro.GetCoin(v.EscrowAddr, DenomUGNOT)
			bar := escrowmath.RenderProgressBar(v.ReleasedUgnot+v.RefundedUgnot, v.TotalDepositUgnot, 10)
			idStr := strconv.Itoa(v.ID)
			sb.WriteString("| #" + idStr + " | **" + v.Title + "** | `" + v.Status + "` | " +
				escrowmath.FormatUGNOT(v.TotalDepositUgnot) + " | " +
				escrowmath.FormatUGNOT(subBal) + " | `" + bar + "` | [Inspect](:vault/" + idStr + ") |\n")
		}
		sb.WriteString("\n")
	}

	if len(builderOrder) > 0 {
		sb.WriteString("## Verified On-Chain Builders\n\n")
		sb.WriteString("| Builder | Milestones Paid | Vaults Completed | Total Earned | Disputes (W/L) |\n")
		sb.WriteString("|---|---|---|---|---|\n")
		for _, addr := range builderOrder {
			st := builderStatsByAddr[addr]
			sb.WriteString("| [`" + string(addr) + "`](:builder/" + string(addr) + ") | " +
				strconv.Itoa(st.MilestonesCompleted) + " | " +
				strconv.Itoa(st.VaultsCompleted) + " | **" +
				escrowmath.FormatUGNOT(st.TotalEarnedUgnot) + "** | " +
				strconv.Itoa(st.DisputesWon) + " / " + strconv.Itoa(st.DisputesLost) + " |\n")
		}
		sb.WriteString("\n")
	}

	sb.WriteString("---\n_Pure math library: `gno.land/p/g1p8ssx7g7fz268k6jc0krpu9enuen4hjvf4599j/escrowmath` · Interactive CLI help: [`$help`]($help)_\n")
	return sb.String()
}

func renderVaultDetail(v *Vault) string {
	ro := banker.NewReadonlyBanker()
	liveBal := ro.GetCoin(v.EscrowAddr, DenomUGNOT)
	expectedBal := v.LockedAmount()
	solvency := "VERIFIED (1:1 backed)"
	if liveBal < expectedBal {
		solvency = "DEFICIT"
	}

	var sb strings.Builder
	sb.WriteString("# Vault #" + strconv.Itoa(v.ID) + ": " + v.Title + "\n\n")
	sb.WriteString("[← Back to Dashboard](:) · [Raw JSON](:api/vault/" + strconv.Itoa(v.ID) + ")\n\n")
	sb.WriteString("> " + v.Description + "\n\n")

	sb.WriteString("## Sub-Realm Escrow Audit\n\n")
	sb.WriteString("- **Status:** `" + v.Status + "`\n")
	sb.WriteString("- **Isolated Escrow Address (`cur.Sub(\"" + v.SubPath + "\")`):** `" + string(v.EscrowAddr) + "`\n")
	sb.WriteString("- **Live Bank Balance:** **" + escrowmath.FormatUGNOT(liveBal) + "** (`" + strconv.FormatInt(liveBal, 10) + " ugnot`) — **" + solvency + "**\n")
	sb.WriteString("- **Sponsor:** `" + string(v.Sponsor) + "`\n")
	if v.Builder != "" {
		sb.WriteString("- **Assigned Builder:** [`" + string(v.Builder) + "`](:builder/" + string(v.Builder) + ")\n")
	} else {
		sb.WriteString("- **Assigned Builder:** _Unassigned (open for applications)_\n")
	}
	sb.WriteString("- **Settlement Progress:** `" + escrowmath.RenderProgressBar(v.ReleasedUgnot+v.RefundedUgnot, v.TotalDepositUgnot, 16) + "`\n")
	sb.WriteString("- **Deadman Timeout:** `" + strconv.FormatInt(v.TimeoutBlocks, 10) + "` blocks after milestone submission\n")
	sb.WriteString("- **Arbiter Council (" + strconv.Itoa(len(v.Arbiters)) + ", quorum " + strconv.Itoa(escrowmath.QuorumThreshold(len(v.Arbiters))) + "):** ")
	for i, a := range v.Arbiters {
		if i > 0 {
			sb.WriteString(", ")
		}
		sb.WriteString("`" + string(a) + "`")
	}
	sb.WriteString("\n\n")

	sb.WriteString("## Milestones\n\n")
	sb.WriteString("| # | Deliverable | Allocation | Share | Status | Evidence |\n")
	sb.WriteString("|---|---|---|---|---|---|\n")
	for _, m := range v.Milestones {
		ev := "—"
		if m.EvidenceURL != "" {
			ev = "`" + m.EvidenceURL + "`"
		}
		sb.WriteString("| M" + strconv.Itoa(m.ID) + " | " + m.Title + " | " +
			escrowmath.FormatUGNOT(m.AmountUgnot) + " | " +
			strconv.FormatInt(m.Bps/100, 10) + "% | `" + m.Status + "` | " + ev + " |\n")
	}
	sb.WriteString("\n")

	if v.Dispute != nil && (v.Dispute.Active || v.Dispute.ResolvedOutcome != "") {
		sb.WriteString("## Arbitration Record\n\n")
		state := "ACTIVE"
		if !v.Dispute.Active {
			state = "RESOLVED (" + v.Dispute.ResolvedOutcome + ")"
		}
		sb.WriteString("- **State:** `" + state + "` (Milestone M" + strconv.Itoa(v.Dispute.MilestoneID) + ")\n")
		sb.WriteString("- **Reason:** " + v.Dispute.Reason + "\n")
		sb.WriteString("- **Tally:** Release `" + strconv.Itoa(v.Dispute.VotesRelease) +
			"` · Refund `" + strconv.Itoa(v.Dispute.VotesRefund) +
			"` · Split `" + strconv.Itoa(v.Dispute.VotesSplit) +
			"` (Quorum: `" + strconv.Itoa(v.Dispute.QuorumRequired) + "`)\n\n")
	}

	if len(v.Applications) > 0 {
		sb.WriteString("## Builder Applications (" + strconv.Itoa(len(v.Applications)) + ")\n\n")
		for _, app := range v.Applications {
			sb.WriteString("- `" + string(app.Builder) + "` (block #" + strconv.FormatInt(app.AppliedAtHeight, 10) + "): " + app.Pitch + "\n")
		}
		sb.WriteString("\n")
	}

	return sb.String()
}

func renderBuilderProfile(addr address) string {
	st, ok := builderStatsByAddr[addr]
	var sb strings.Builder
	sb.WriteString("# Builder Profile: `" + string(addr) + "`\n\n")
	sb.WriteString("[← Back to Dashboard](:)\n\n")
	if !ok {
		sb.WriteString("_No on-chain MilestoneVault activity recorded for this address yet._\n")
		return sb.String()
	}
	sb.WriteString("- **Milestones Paid:** **" + strconv.Itoa(st.MilestonesCompleted) + "**\n")
	sb.WriteString("- **Vaults Completed:** **" + strconv.Itoa(st.VaultsCompleted) + "**\n")
	sb.WriteString("- **Total Earned:** **" + escrowmath.FormatUGNOT(st.TotalEarnedUgnot) + "** (`" + strconv.FormatInt(st.TotalEarnedUgnot, 10) + " ugnot`)\n")
	sb.WriteString("- **Arbitration Record:** " + strconv.Itoa(st.DisputesWon) + " won / " + strconv.Itoa(st.DisputesLost) + " lost\n")
	return sb.String()
}

func renderStatsJSON() string {
	ro := banker.NewReadonlyBanker()
	var openN, activeN, completedN, disputedN int
	var liveLocked int64
	for _, v := range vaults {
		liveLocked += ro.GetCoin(v.EscrowAddr, DenomUGNOT)
		switch v.Status {
		case VaultStatusOpen:
			openN++
		case VaultStatusActive:
			activeN++
		case VaultStatusCompleted:
			completedN++
		case VaultStatusDisputed:
			disputedN++
		}
	}

	var sb strings.Builder
	sb.WriteString("{")
	sb.WriteString(`"chainId":"` + escrowmath.EscapeJSON(runtime.ChainID()) + `",`)
	sb.WriteString(`"blockHeight":` + strconv.FormatInt(runtime.ChainHeight(), 10) + `,`)
	sb.WriteString(`"realmPath":"` + escrowmath.EscapeJSON(realmPkgPath) + `",`)
	sb.WriteString(`"vaultCount":` + strconv.Itoa(len(vaults)) + `,`)
	sb.WriteString(`"openVaults":` + strconv.Itoa(openN) + `,`)
	sb.WriteString(`"activeVaults":` + strconv.Itoa(activeN) + `,`)
	sb.WriteString(`"completedVaults":` + strconv.Itoa(completedN) + `,`)
	sb.WriteString(`"disputedVaults":` + strconv.Itoa(disputedN) + `,`)
	sb.WriteString(`"totalDepositedUgnot":` + strconv.FormatInt(totalDepositedUgnot, 10) + `,`)
	sb.WriteString(`"totalReleasedUgnot":` + strconv.FormatInt(totalReleasedUgnot, 10) + `,`)
	sb.WriteString(`"totalLockedUgnot":` + strconv.FormatInt(liveLocked, 10) + `,`)
	sb.WriteString(`"builders":[`)
	for i, addr := range builderOrder {
		if i > 0 {
			sb.WriteString(",")
		}
		st := builderStatsByAddr[addr]
		sb.WriteString(`{"address":"` + escrowmath.EscapeJSON(string(st.Address)) + `",` +
			`"milestonesCompleted":` + strconv.Itoa(st.MilestonesCompleted) + `,` +
			`"vaultsCompleted":` + strconv.Itoa(st.VaultsCompleted) + `,` +
			`"totalEarnedUgnot":` + strconv.FormatInt(st.TotalEarnedUgnot, 10) + `,` +
			`"disputesWon":` + strconv.Itoa(st.DisputesWon) + `,` +
			`"disputesLost":` + strconv.Itoa(st.DisputesLost) + `}`)
	}
	sb.WriteString("]}")
	return sb.String()
}

func renderVaultsJSON() string {
	ro := banker.NewReadonlyBanker()
	var sb strings.Builder
	sb.WriteString("[")
	for i, v := range vaults {
		if i > 0 {
			sb.WriteString(",")
		}
		sb.WriteString(renderSingleVaultJSON(v, ro))
	}
	sb.WriteString("]")
	return sb.String()
}

func renderSingleVaultJSON(v *Vault, ro banker.Banker) string {
	liveBal := ro.GetCoin(v.EscrowAddr, DenomUGNOT)
	var sb strings.Builder
	sb.WriteString("{")
	sb.WriteString(`"id":` + strconv.Itoa(v.ID) + `,`)
	sb.WriteString(`"title":"` + escrowmath.EscapeJSON(v.Title) + `",`)
	sb.WriteString(`"description":"` + escrowmath.EscapeJSON(v.Description) + `",`)
	sb.WriteString(`"sponsor":"` + escrowmath.EscapeJSON(string(v.Sponsor)) + `",`)
	sb.WriteString(`"builder":"` + escrowmath.EscapeJSON(string(v.Builder)) + `",`)
	sb.WriteString(`"escrowAddress":"` + escrowmath.EscapeJSON(string(v.EscrowAddr)) + `",`)
	sb.WriteString(`"status":"` + escrowmath.EscapeJSON(v.Status) + `",`)
	sb.WriteString(`"totalDepositUgnot":` + strconv.FormatInt(v.TotalDepositUgnot, 10) + `,`)
	sb.WriteString(`"releasedUgnot":` + strconv.FormatInt(v.ReleasedUgnot, 10) + `,`)
	sb.WriteString(`"refundedUgnot":` + strconv.FormatInt(v.RefundedUgnot, 10) + `,`)
	sb.WriteString(`"lockedUgnot":` + strconv.FormatInt(v.LockedAmount(), 10) + `,`)
	sb.WriteString(`"liveSubBalanceUgnot":` + strconv.FormatInt(liveBal, 10) + `,`)
	sb.WriteString(`"timeoutBlocks":` + strconv.FormatInt(v.TimeoutBlocks, 10) + `,`)
	sb.WriteString(`"createdAtHeight":` + strconv.FormatInt(v.CreatedAtHeight, 10) + `,`)

	sb.WriteString(`"arbiters":[`)
	for i, a := range v.Arbiters {
		if i > 0 {
			sb.WriteString(",")
		}
		sb.WriteString(`"` + escrowmath.EscapeJSON(string(a)) + `"`)
	}
	sb.WriteString(`],"milestones":[`)
	for i, m := range v.Milestones {
		if i > 0 {
			sb.WriteString(",")
		}
		sb.WriteString(`{"id":` + strconv.Itoa(m.ID) + `,` +
			`"title":"` + escrowmath.EscapeJSON(m.Title) + `",` +
			`"amountUgnot":` + strconv.FormatInt(m.AmountUgnot, 10) + `,` +
			`"bps":` + strconv.FormatInt(m.Bps, 10) + `,` +
			`"status":"` + escrowmath.EscapeJSON(m.Status) + `",` +
			`"evidenceUrl":"` + escrowmath.EscapeJSON(m.EvidenceURL) + `",` +
			`"submittedAtHeight":` + strconv.FormatInt(m.SubmittedAtHeight, 10) + `,` +
			`"approvedAtHeight":` + strconv.FormatInt(m.ApprovedAtHeight, 10) + `}`)
	}
	sb.WriteString(`],"applications":[`)
	for i, app := range v.Applications {
		if i > 0 {
			sb.WriteString(",")
		}
		sb.WriteString(`{"builder":"` + escrowmath.EscapeJSON(string(app.Builder)) + `",` +
			`"pitch":"` + escrowmath.EscapeJSON(app.Pitch) + `",` +
			`"appliedAtHeight":` + strconv.FormatInt(app.AppliedAtHeight, 10) + `}`)
	}
	sb.WriteString(`],"dispute":`)
	if v.Dispute == nil {
		sb.WriteString(`{"active":false,"milestoneId":0,"openedBy":"","reason":"","openedAtHeight":0,"votesRelease":0,"votesRefund":0,"votesSplit":0,"quorumRequired":1,"resolvedOutcome":""}`)
	} else {
		activeStr := "false"
		if v.Dispute.Active {
			activeStr = "true"
		}
		sb.WriteString(`{"active":` + activeStr + `,` +
			`"milestoneId":` + strconv.Itoa(v.Dispute.MilestoneID) + `,` +
			`"openedBy":"` + escrowmath.EscapeJSON(string(v.Dispute.OpenedBy)) + `",` +
			`"reason":"` + escrowmath.EscapeJSON(v.Dispute.Reason) + `",` +
			`"openedAtHeight":` + strconv.FormatInt(v.Dispute.OpenedAtHeight, 10) + `,` +
			`"votesRelease":` + strconv.Itoa(v.Dispute.VotesRelease) + `,` +
			`"votesRefund":` + strconv.Itoa(v.Dispute.VotesRefund) + `,` +
			`"votesSplit":` + strconv.Itoa(v.Dispute.VotesSplit) + `,` +
			`"quorumRequired":` + strconv.Itoa(v.Dispute.QuorumRequired) + `,` +
			`"resolvedOutcome":"` + escrowmath.EscapeJSON(v.Dispute.ResolvedOutcome) + `"}`)
	}
	sb.WriteString("}")
	return sb.String()
}
