// Render is the vault's product page. Judges click the live realm;
// this page is the demo, so it shows the budgets as live bars, the
// spend log including blocked attempts, a public guard report, and
// the one-line import for the cap library.
//
// Every user-controlled string (agent names, purposes) is passed
// through tableCell before it is written into a table: InlineText
// for markdown safety, plus an escape for the pipe character, which
// InlineText does not escape and which would otherwise split a
// table cell. Reasons are NOT sanitized: they are internal constants
// from the cap checks (never user input), and sanitizing them would
// backslash-escape the hyphen in "exceeds per-transaction cap".
package agentvault

import (
	"strings"
	"time"

	caps "gno.land/p/g16740fm9kd28luuktn3g42jfq3r998fm35chclv/agentvault"
	sanitize "gno.land/p/nt/markdown/sanitize/v0"
	ufmt "gno.land/p/nt/ufmt/v0"
)

// tableCell sanitizes a user-controlled string for use inside a
// markdown table cell: InlineText first, then the pipe (which
// InlineText leaves raw) is escaped so it cannot split the cell.
func tableCell(s string) string {
	return strings.ReplaceAll(sanitize.InlineText(s), "|", "\\|")
}

// budgetBar draws the remaining fraction of a budget as a bar of
// block characters, e.g. "██████░░░░ 60%". Width is the bar length
// in characters.
func budgetBar(remaining, total int64, width int) string {
	if total <= 0 {
		return "no budget"
	}
	if remaining < 0 {
		remaining = 0
	}
	if remaining > total {
		remaining = total
	}
	filled := int(remaining * int64(width) / total)
	bar := ""
	for i := 0; i < filled; i++ {
		bar += "█"
	}
	for i := filled; i < width; i++ {
		bar += "░"
	}
	pct := int(remaining * 100 / total)
	return bar + " " + ufmt.Sprintf("%d%%", pct)
}

// Render returns the vault's product page in markdown. The path
// argument is ignored: the vault has one page.
func Render(_ string) string {
	out := "# AgentVault\n\n"
	out += "The wallet an AI agent cannot drain. The owner funds the vault, sets a per-transaction cap and a daily cap per agent, and every spend goes through the guard. Blocked attempts are logged on-chain and shown here, so a limit is a visible fact, not a promise.\n\n"
	out += "Owner: `" + sanitize.InlineText(owner.String()) + "`\n\n"
	out += ufmt.Sprintf("Vault balance: **%d ugnot** | Available: **%d ugnot** | Funded: %d ugnot | Spent: %d ugnot | Held in escrow: %d ugnot\n\n",
		VaultBalance(), AvailableBalance(), totalFunded, totalSpent, escrowedTotal)

	// Budgets.
	out += "## Budgets\n\n"
	if len(agentList) == 0 {
		out += "No agents yet. The owner sets caps with SetCap or SetCapByName.\n\n"
	} else {
		out += "| Agent | Per-tx cap | Daily cap | Spent today | Remaining | Budget left |\n"
		out += "|---|---|---|---|---|---|\n"
		for _, addr := range agentList {
			b := budgets[addr]
			remaining := caps.RemainingToday(b, time.Now().Unix())
			out += "| `" + sanitize.InlineText(addr.String()) + "` | " +
				ufmt.Sprintf("%d", b.PerTxCap) + " | " +
				ufmt.Sprintf("%d", b.DailyCap) + " | " +
				ufmt.Sprintf("%d", b.SpentToday) + " | " +
				ufmt.Sprintf("%d", remaining) + " | `" +
				budgetBar(remaining, b.DailyCap, 10) + "` |\n"
		}
		out += "\n"
	}

	// Guard report.
	allowed := 0
	blocked := 0
	reasonCount := make(map[string]int)
	var reasonOrder []string
	for _, a := range attempts {
		if a.Allowed {
			allowed++
		} else {
			blocked++
			if _, ok := reasonCount[a.Reason]; !ok {
				reasonOrder = append(reasonOrder, a.Reason)
			}
			reasonCount[a.Reason]++
		}
	}
	out += "## Guard report\n\n"
	out += ufmt.Sprintf("Attempts: **%d** (%d allowed, %d blocked)\n\n", len(attempts), allowed, blocked)
	if blocked > 0 {
		out += "Blocked by reason:\n\n"
		for _, r := range reasonOrder {
			// r is an internal cap-check constant, never user input.
			out += "- " + r + ": " + ufmt.Sprintf("%d", reasonCount[r]) + "\n"
		}
		out += "\n"
	}

	// Escrows.
	out += "## Escrows\n\n"
	es := Escrows()
	if len(es) == 0 {
		out += "No escrows yet. The owner pays a named agent with PayByName; the payment is held until the recipient confirms or the owner refunds after the deadline.\n\n"
	} else {
		out += "| ID | Recipient | Amount | Status | Deadline (height) |\n"
		out += "|---|---|---|---|---|\n"
		for _, e := range es {
			out += "| " + ufmt.Sprintf("%d", e.ID) + " | " +
				tableCell(e.RecipientName) + " (`" + sanitize.InlineText(e.Recipient.String()) + "`) | " +
				ufmt.Sprintf("%d", e.Amount) + " | **" + caps.EscrowStatusString(e.Status) + "** | " +
				ufmt.Sprintf("%d", e.DeadlineHeight) + " |\n"
		}
		out += "\n"
	}

	// Spend log, latest first.
	out += "## Spend log\n\n"
	if len(attempts) == 0 {
		out += "No attempts yet.\n\n"
	} else {
		out += "| # | Agent | Amount | Purpose | Result | Reason |\n"
		out += "|---|---|---|---|---|---|\n"
		shown := 0
		for i := len(attempts) - 1; i >= 0 && shown < 20; i-- {
			a := attempts[i]
			result := "ALLOWED"
			if !a.Allowed {
				result = "**BLOCKED**"
			}
			name := ""
			if a.Name != "" {
				name = " (" + tableCell(a.Name) + ")"
			}
			out += "| " + ufmt.Sprintf("%d", a.ID) + " | `" +
				sanitize.InlineText(a.Agent.String()) + "`" + name + " | " +
				ufmt.Sprintf("%d", a.Amount) + " | " +
				tableCell(a.Purpose) + " | " + result + " | " +
				a.Reason + " |\n"
			shown++
		}
		out += "\n"
	}

	// Import snippet for the cap library.
	out += "## Import the cap library\n\n"
	out += "```go\n"
	out += "import caps \"gno.land/p/g16740fm9kd28luuktn3g42jfq3r998fm35chclv/agentvault\"\n\n"
	out += "// b := caps.NewBudget(perTxCap, dailyCap)\n"
	out += "// caps.RefreshDay(&b, time.Now().Unix())\n"
	out += "// allowed, reason := caps.CheckSpend(b, amount)\n"
	out += "```\n"
	return out
}
