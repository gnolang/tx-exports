package milestone_escrow

import (
	"strconv"
	"strings"
)

func formatGnot(ugnot int64) string {
	whole := ugnot / 1_000_000
	frac := ugnot % 1_000_000
	if frac < 0 {
		frac = -frac
	}
	if frac == 0 {
		return strconv.FormatInt(whole, 10) + " GNOT"
	}
	fracStr := strconv.FormatInt(frac, 10)
	for len(fracStr) < 6 {
		fracStr = "0" + fracStr
	}
	fracStr = strings.TrimRight(fracStr, "0")
	return strconv.FormatInt(whole, 10) + "." + fracStr + " GNOT"
}

func shortAddr(a address) string {
	s := a.String()
	if len(s) <= 16 {
		return s
	}
	return s[:10] + "..." + s[len(s)-6:]
}

func Render(path string) string {
	trimmed := strings.Trim(path, "/")
	switch {
	case trimmed == "":
		return renderHome()
	case trimmed == "stats":
		return renderStats()
	case trimmed == "guide":
		return renderGuide()
	case strings.HasPrefix(trimmed, "contract/"):
		idStr := strings.TrimPrefix(trimmed, "contract/")
		id, err := strconv.ParseUint(idStr, 10, 64)
		if err != nil {
			return "# Invalid Contract ID\n\nExpected `/contract/<numeric-id>`."
		}
		return renderContract(id)
	default:
		return "# 404 — Route Not Found\n\nAvailable routes: [Home](?) | [Stats](?:stats) | [CLI Guide](?:guide)"
	}
}

func renderHome() string {
	var b strings.Builder
	b.WriteString("# MilestoneEscrow — On-Chain Milestone Bounty & Split-Payout Realm\n\n")
	b.WriteString("Trust-minimized multi-milestone `ugnot` escrow for freelancers, open-source bounties, and autonomous AI agents.\n\n")
	b.WriteString("[Overview](?) | [Accounting & Stats](?:stats) | [Quick-Start CLI Guide](?:guide)\n\n")

	active := 0
	completed := 0
	cancelled := 0
	for _, c := range contracts {
		switch c.Status {
		case ContractActive:
			active++
		case ContractCompleted:
			completed++
		case ContractCancelled:
			cancelled++
		}
	}

	b.WriteString("## Live Protocol Snapshot\n\n")
	b.WriteString("| Metric | Value |\n")
	b.WriteString("|---|---|\n")
	b.WriteString("| Total Contracts | " + strconv.Itoa(len(contracts)) + " (" + strconv.Itoa(active) + " active, " + strconv.Itoa(completed) + " completed, " + strconv.Itoa(cancelled) + " cancelled) |\n")
	b.WriteString("| Currently Locked Escrow | **" + formatGnot(LockedBalanceUgnot()) + "** (`" + strconv.FormatInt(LockedBalanceUgnot(), 10) + "ugnot`) |\n")
	b.WriteString("| Cumulative Settled to Contractors | " + formatGnot(totalReleased) + " |\n")
	b.WriteString("| Cumulative Refunded to Clients | " + formatGnot(totalRefunded) + " |\n")
	b.WriteString("| Disputes Escalated | " + strconv.Itoa(totalDisputesCount) + " |\n\n")

	b.WriteString("## Escrow Contracts\n\n")
	if len(contracts) == 0 {
		b.WriteString("_No escrow contracts created yet. Call `CreateContract` with an exact `ugnot` deposit to open the first milestone contract._\n")
		return b.String()
	}

	b.WriteString("| ID | Title | Client | Contractor | Total | Progress | Status |\n")
	b.WriteString("|---|---|---|---|---|---|---|\n")
	for i := len(contracts) - 1; i >= 0; i-- {
		c := contracts[i]
		done := 0
		for _, m := range c.Milestones {
			if m.Status == StatusReleased || m.Status == StatusResolved {
				done++
			}
		}
		idStr := strconv.FormatUint(c.ID, 10)
		b.WriteString("| [#" + idStr + "](?:contract/" + idStr + ") | " + c.Title + " | `" + shortAddr(c.Client) + "` | `" + shortAddr(c.Contractor) + "` | " + formatGnot(c.TotalUgnot) + " | " + strconv.Itoa(done) + "/" + strconv.Itoa(len(c.Milestones)) + " | **" + c.Status + "** |\n")
	}

	return b.String()
}

func renderContract(id uint64) string {
	c, ok := contractsByID[id]
	if !ok {
		return "# Contract Not Found\n\nContract `#" + strconv.FormatUint(id, 10) + "` does not exist. [Back to Overview](?)"
	}

	var b strings.Builder
	idStr := strconv.FormatUint(c.ID, 10)
	b.WriteString("# Contract #" + idStr + " — " + c.Title + "\n\n")
	b.WriteString("[← Back to Overview](?) | [Stats](?:stats) | [CLI Guide](?:guide)\n\n")

	arbiterDisplay := "_None (trustless bilateral)_"
	if c.Arbiter.IsValid() {
		arbiterDisplay = "`" + c.Arbiter.String() + "`"
	}

	b.WriteString("| Field | Value |\n")
	b.WriteString("|---|---|\n")
	b.WriteString("| Status | **" + c.Status + "** |\n")
	b.WriteString("| Client | `" + c.Client.String() + "` |\n")
	b.WriteString("| Contractor | `" + c.Contractor.String() + "` |\n")
	b.WriteString("| Arbiter | " + arbiterDisplay + " |\n")
	b.WriteString("| Total Escrowed | " + formatGnot(c.TotalUgnot) + " (`" + strconv.FormatInt(c.TotalUgnot, 10) + "ugnot`) |\n")
	b.WriteString("| Released | " + formatGnot(c.ReleasedUgnot) + " |\n")
	b.WriteString("| Refunded | " + formatGnot(c.RefundedUgnot) + " |\n")
	b.WriteString("| Created Block | #" + strconv.FormatInt(c.CreatedAtHeight, 10) + " |\n\n")

	b.WriteString("## Milestones\n\n")
	b.WriteString("| # | Deliverable | Amount | Status | Proof / Resolution |\n")
	b.WriteString("|---|---|---|---|---|\n")
	for _, m := range c.Milestones {
		note := "—"
		if m.ProofURI != "" {
			note = m.ProofURI
		}
		if m.Status == StatusDisputed {
			note = "Dispute: " + m.DisputeReason
		} else if m.Status == StatusResolved {
			note = "Split: " + formatGnot(m.ContractorPaid) + " contractor / " + formatGnot(m.ClientRefunded) + " client"
		}
		b.WriteString("| " + strconv.Itoa(m.Index) + " | " + m.Title + " | " + formatGnot(m.AmountUgnot) + " | **" + m.Status + "** | " + note + " |\n")
	}

	return b.String()
}

func renderStats() string {
	var b strings.Builder
	b.WriteString("# MilestoneEscrow — Protocol Accounting & Invariants\n\n")
	b.WriteString("[← Back to Overview](?) | [CLI Guide](?:guide)\n\n")

	var pendingSum, submittedSum, disputedSum int64
	for _, c := range contracts {
		for _, m := range c.Milestones {
			switch m.Status {
			case StatusPending:
				pendingSum += m.AmountUgnot
			case StatusSubmitted:
				submittedSum += m.AmountUgnot
			case StatusDisputed:
				disputedSum += m.AmountUgnot
			}
		}
	}
	lockedCalc := pendingSum + submittedSum + disputedSum
	invariantOK := "PASS"
	if lockedCalc != LockedBalanceUgnot() {
		invariantOK = "MISMATCH"
	}

	b.WriteString("| Accounting Bucket | Amount |\n")
	b.WriteString("|---|---|\n")
	b.WriteString("| Total Deposited (All-Time) | " + formatGnot(totalDeposited) + " |\n")
	b.WriteString("| Total Released to Contractors | " + formatGnot(totalReleased) + " |\n")
	b.WriteString("| Total Refunded to Clients | " + formatGnot(totalRefunded) + " |\n")
	b.WriteString("| Locked in PENDING Milestones | " + formatGnot(pendingSum) + " |\n")
	b.WriteString("| Locked in SUBMITTED Milestones | " + formatGnot(submittedSum) + " |\n")
	b.WriteString("| Locked in DISPUTED Milestones | " + formatGnot(disputedSum) + " |\n")
	b.WriteString("| Conservation Invariant (`deposited - released - refunded == locked`) | **" + invariantOK + "** |\n")
	return b.String()
}

func renderGuide() string {
	return `# MilestoneEscrow — CLI Interaction Guide

[← Back to Overview](?) | [Stats](?:stats)

## 1. Create a 2-Milestone Escrow Contract (Client)

` + "```bash" + `
gnokey maketx call \
  -pkgpath "<REALM_PATH>" \
  -func "CreateContract" \
  -args "Build Indexer API" \
  -args "<CONTRACTOR_ADDR>" \
  -args "<ARBITER_ADDR>" \
  -args "Schema & RPC Client,Live Testnet Deployment" \
  -args "400000,600000" \
  -send "1000000ugnot" \
  -gas-fee 1000000ugnot -gas-wanted 5000000 \
  -chainid onyx-1 -remote https://rpc.onyx.testnets.gno.land:443 <KEY_NAME>
` + "```" + `

## 2. Submit Deliverable Proof (Contractor)

` + "```bash" + `
gnokey maketx call -pkgpath "<REALM_PATH>" -func "SubmitMilestone" \
  -args "1" -args "0" -args "https://github.com/org/repo/commit/abc123" \
  -gas-fee 1000000ugnot -gas-wanted 2000000 -chainid onyx-1 <KEY_NAME>
` + "```" + `

## 3. Approve & Release Payout (Client)

` + "```bash" + `
gnokey maketx call -pkgpath "<REALM_PATH>" -func "ApproveMilestone" \
  -args "1" -args "0" \
  -gas-fee 1000000ugnot -gas-wanted 2000000 -chainid onyx-1 <KEY_NAME>
` + "```" + `

## 4. Dispute & Arbiter Basis-Point Split (Arbiter)

` + "```bash" + `
# contractorBps = 6500 sends 65% to contractor and refunds 35% to client atomically
gnokey maketx call -pkgpath "<REALM_PATH>" -func "ResolveDispute" \
  -args "1" -args "1" -args "6500" \
  -gas-fee 1000000ugnot -gas-wanted 2000000 -chainid onyx-1 <KEY_NAME>
` + "```" + `
`
}
