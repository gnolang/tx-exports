package hearthescrow

import (
	"chain/runtime"
	"strconv"
	"strings"

	"gno.land/p/nt/ufmt/v0"
)

// Render serves the gnoweb Markdown interface for HearthEscrow.
// Supported routes:
//   - "" or "/" (with optional ?status=active|disputed|closed)
//   - "escrow/<id>"
//   - "address/<addr>"
func Render(path string) string {
	cleanPath, query := splitPathQuery(path)
	cleanPath = strings.Trim(cleanPath, "/")

	if cleanPath == "" {
		return renderHome(query)
	}

	parts := strings.Split(cleanPath, "/")
	switch parts[0] {
	case "escrow":
		if len(parts) != 2 {
			return renderNotFound(path)
		}
		id, err := strconv.ParseUint(parts[1], 10, 64)
		if err != nil || id == 0 {
			return renderNotFound(path)
		}
		return renderEscrowDetail(id)
	case "address":
		if len(parts) != 2 || strings.TrimSpace(parts[1]) == "" {
			return renderNotFound(path)
		}
		return renderAddressView(address(parts[1]))
	default:
		return renderNotFound(path)
	}
}

func renderHome(query string) string {
	filter := parseQueryParam(query, "status")
	var sb strings.Builder

	sb.WriteString("# HearthEscrow\n\n")
	sb.WriteString("Trustless milestone escrow with arbiter dispute splits and block-height refunds.\n\n")

	// Summary metrics table
	sb.WriteString("| Total Escrows | Active | Disputed | Completed | Resolved | Refunded | TVL Locked | Total Released |\n")
	sb.WriteString("| --- | --- | --- | --- | --- | --- | --- | --- |\n")
	sb.WriteString(ufmt.Sprintf(
		"| %d | %d | %d | %d | %d | %d | %s | %s |\n\n",
		stats.TotalEscrows,
		stats.ActiveCount,
		stats.DisputedCount,
		stats.CompletedCount,
		stats.ResolvedCount,
		stats.RefundedCount,
		formatUGNOT(stats.TotalLocked),
		formatUGNOT(stats.TotalReleased),
	))

	// Filter bar
	sb.WriteString("**Filter:** ")
	sb.WriteString(filterLink("All", "", filter))
	sb.WriteString(" · ")
	sb.WriteString(filterLink("Active", "active", filter))
	sb.WriteString(" · ")
	sb.WriteString(filterLink("Disputed", "disputed", filter))
	sb.WriteString(" · ")
	sb.WriteString(filterLink("Closed", "closed", filter))
	sb.WriteString("\n\n")

	if escrows.Size() == 0 {
		sb.WriteString("_No escrows created yet. Use `CreateEscrow` with a `ugnot` deposit to open the first one._\n\n")
		sb.WriteString(renderQuickStartSnippet())
		return sb.String()
	}

	var rows []string
	escrows.ReverseIterate("", "", func(_ string, v any) bool {
		e := v.(*Escrow)
		if !matchesFilter(e.Status, filter) {
			return false
		}
		row := ufmt.Sprintf(
			"| [#%d](%s:escrow/%d) | %s | %s | %s | %d/%d | %s | [%s](%s:address/%s) |",
			e.ID, realmLinkBase, e.ID,
			escapeCell(e.Title),
			statusBadge(e.Status),
			formatUGNOT(e.TotalAmount),
			e.ApprovedCount(), len(e.Milestones),
			formatUGNOT(e.RemainingAmount()),
			shortAddr(e.Recipient), realmLinkBase, e.Recipient.String(),
		)
		rows = append(rows, row)
		return false
	})

	if len(rows) == 0 {
		sb.WriteString(ufmt.Sprintf("_No escrows match filter `%s`._\n", escapeCell(filter)))
		return sb.String()
	}

	sb.WriteString("| ID | Title | Status | Total | Milestones | Locked | Recipient |\n")
	sb.WriteString("| --- | --- | --- | --- | --- | --- | --- |\n")
	for _, row := range rows {
		sb.WriteString(row)
		sb.WriteString("\n")
	}

	return sb.String()
}

func renderEscrowDetail(id uint64) string {
	e := GetEscrow(id)
	if e == nil {
		return ufmt.Sprintf("# Escrow #%d Not Found\n\n[← Back to HearthEscrow](%s)\n", id, realmLinkBase)
	}

	nowHeight := runtime.ChainHeight()
	var sb strings.Builder

	sb.WriteString(ufmt.Sprintf("[← All Escrows](%s)\n\n", realmLinkBase))
	sb.WriteString(ufmt.Sprintf("# Escrow #%d — %s\n\n", e.ID, escapeInline(e.Title)))
	sb.WriteString(ufmt.Sprintf("**Status:** %s · **Progress:** `%s` (%d/%d milestones)\n\n",
		statusBadge(e.Status),
		progressBar(e.ApprovedCount(), len(e.Milestones)),
		e.ApprovedCount(),
		len(e.Milestones),
	))

	// Parties & accounting
	arbiterCell := "_None_"
	if e.Arbiter != "" {
		arbiterCell = ufmt.Sprintf("[%s](%s:address/%s)", e.Arbiter.String(), realmLinkBase, e.Arbiter.String())
	}
	deadlineNote := ufmt.Sprintf("Block #%d", e.DeadlineHeight)
	if e.Status == StatusActive {
		if nowHeight >= e.DeadlineHeight {
			deadlineNote += " (expired — refund eligible)"
		} else {
			deadlineNote += ufmt.Sprintf(" (%d blocks remaining)", e.DeadlineHeight-nowHeight)
		}
	}

	sb.WriteString("## Overview\n\n")
	sb.WriteString("| Field | Value |\n")
	sb.WriteString("| --- | --- |\n")
	sb.WriteString(ufmt.Sprintf("| Depositor | [%s](%s:address/%s) |\n", e.Depositor.String(), realmLinkBase, e.Depositor.String()))
	sb.WriteString(ufmt.Sprintf("| Recipient | [%s](%s:address/%s) |\n", e.Recipient.String(), realmLinkBase, e.Recipient.String()))
	sb.WriteString(ufmt.Sprintf("| Arbiter | %s |\n", arbiterCell))
	sb.WriteString(ufmt.Sprintf("| Total Deposit | %s |\n", formatUGNOT(e.TotalAmount)))
	sb.WriteString(ufmt.Sprintf("| Released | %s |\n", formatUGNOT(e.ReleasedAmount)))
	sb.WriteString(ufmt.Sprintf("| Refunded | %s |\n", formatUGNOT(e.RefundedAmount)))
	sb.WriteString(ufmt.Sprintf("| Currently Locked | %s |\n", formatUGNOT(e.RemainingAmount())))
	sb.WriteString(ufmt.Sprintf("| Created / Deadline | Block #%d / %s |\n\n", e.CreatedHeight, deadlineNote))

	// Milestones table
	sb.WriteString("## Milestones\n\n")
	sb.WriteString("| # | Title | Share | Est. / Paid | Status | Deliverable |\n")
	sb.WriteString("| --- | --- | --- | --- | --- | --- |\n")
	for _, m := range e.Milestones {
		amtStr := formatUGNOT((e.TotalAmount * m.Bps) / BasisPointsTotal)
		if m.Status == MilestoneApproved {
			amtStr = formatUGNOT(m.PaidAmount) + " (paid)"
		}
		deliv := "—"
		if m.Deliverable != "" {
			deliv = escapeCell(m.Deliverable)
		}
		sb.WriteString(ufmt.Sprintf("| %d | %s | %s | %s | %s | %s |\n",
			m.Index,
			escapeCell(m.Title),
			formatBps(m.Bps),
			amtStr,
			milestoneBadge(m.Status),
			deliv,
		))
	}
	sb.WriteString("\n")

	// Dispute section
	if e.Dispute != nil {
		sb.WriteString("## Dispute Record\n\n")
		sb.WriteString(ufmt.Sprintf("- **Opened by:** [%s](%s:address/%s) at block #%d\n",
			e.Dispute.OpenedBy.String(), realmLinkBase, e.Dispute.OpenedBy.String(), e.Dispute.OpenedHeight))
		sb.WriteString(ufmt.Sprintf("- **Reason:** %s\n", escapeInline(e.Dispute.Reason)))
		if e.Status == StatusResolved {
			sb.WriteString(ufmt.Sprintf("- **Resolved at block #%d:** Recipient %s (%s) / Depositor (%s)\n",
				e.Dispute.ResolvedHeight,
				formatBps(e.Dispute.RecipientBps),
				formatUGNOT(e.Dispute.RecipientPayout),
				formatUGNOT(e.Dispute.DepositorRefund),
			))
			if e.Dispute.ResolutionNote != "" {
				sb.WriteString(ufmt.Sprintf("- **Arbiter note:** %s\n", escapeInline(e.Dispute.ResolutionNote)))
			}
		}
		sb.WriteString("\n")
	}

	// Next action CLI snippets
	sb.WriteString("## CLI Actions (`gnokey`)\n\n")
	switch e.Status {
	case StatusActive:
		sb.WriteString("```bash\n")
		sb.WriteString(ufmt.Sprintf("# Recipient submits milestone 0\ngnokey maketx call -pkgpath \"" + realmPkgPath + "\" -func SubmitMilestone -args %d -args 0 -args \"https://example.com/deliverable\" <recipient_key>\n\n", e.ID))
		sb.WriteString(ufmt.Sprintf("# Depositor approves milestone 0\ngnokey maketx call -pkgpath \"" + realmPkgPath + "\" -func ApproveMilestone -args %d -args 0 <depositor_key>\n", e.ID))
		if e.Arbiter != "" {
			sb.WriteString(ufmt.Sprintf("\n# Depositor or Recipient opens a dispute\ngnokey maketx call -pkgpath \"" + realmPkgPath + "\" -func OpenDispute -args %d -args \"Reason for dispute\" <party_key>\n", e.ID))
		}
		sb.WriteString(ufmt.Sprintf("\n# Depositor claims refund (at or after block #%d)\ngnokey maketx call -pkgpath \"" + realmPkgPath + "\" -func ClaimRefund -args %d <depositor_key>\n", e.DeadlineHeight, e.ID))
		sb.WriteString("```\n")
	case StatusDisputed:
		sb.WriteString("```bash\n")
		sb.WriteString(ufmt.Sprintf("# Arbiter resolves dispute (e.g. 6000 bps = 60%% to recipient, 40%% refunded to depositor)\ngnokey maketx call -pkgpath \"" + realmPkgPath + "\" -func ResolveDispute -args %d -args 6000 -args \"Partial delivery verified\" <arbiter_key>\n", e.ID))
		sb.WriteString("```\n")
	default:
		sb.WriteString(ufmt.Sprintf("_Escrow is `%s` (closed at block #%d). No further actions available._\n", string(e.Status), e.ClosedHeight))
	}

	return sb.String()
}

func renderAddressView(addr address) string {
	var sb strings.Builder
	sb.WriteString(ufmt.Sprintf("[← All Escrows](%s)\n\n", realmLinkBase))
	sb.WriteString(ufmt.Sprintf("# Address `%s`\n\n", escapeInline(addr.String())))

	if !addr.IsValid() {
		sb.WriteString("_Invalid Gno address format._\n")
		return sb.String()
	}

	ids := GetAddressEscrowIDs(addr)
	if len(ids) == 0 {
		sb.WriteString("_No escrows found for this address._\n")
		return sb.String()
	}

	var asDep, asRec, asArb int
	var depVol, recVol int64
	for _, id := range ids {
		e := GetEscrow(id)
		if e == nil {
			continue
		}
		if e.Depositor == addr {
			asDep++
			depVol += e.TotalAmount
		}
		if e.Recipient == addr {
			asRec++
			recVol += e.ReleasedAmount
		}
		if e.Arbiter == addr {
			asArb++
		}
	}

	sb.WriteString("| Role | Escrows | Volume |\n")
	sb.WriteString("| --- | --- | --- |\n")
	sb.WriteString(ufmt.Sprintf("| Depositor | %d | %s deposited |\n", asDep, formatUGNOT(depVol)))
	sb.WriteString(ufmt.Sprintf("| Recipient | %d | %s received |\n", asRec, formatUGNOT(recVol)))
	sb.WriteString(ufmt.Sprintf("| Arbiter | %d | — |\n\n", asArb))

	sb.WriteString("| ID | Title | Role | Status | Total | Locked |\n")
	sb.WriteString("| --- | --- | --- | --- | --- | --- |\n")
	for i := len(ids) - 1; i >= 0; i-- {
		e := GetEscrow(ids[i])
		if e == nil {
			continue
		}
		role := "Arbiter"
		if e.Depositor == addr {
			role = "Depositor"
		} else if e.Recipient == addr {
			role = "Recipient"
		}
		sb.WriteString(ufmt.Sprintf("| [#%d](%s:escrow/%d) | %s | %s | %s | %s | %s |\n",
			e.ID, realmLinkBase, e.ID,
			escapeCell(e.Title),
			role,
			statusBadge(e.Status),
			formatUGNOT(e.TotalAmount),
			formatUGNOT(e.RemainingAmount()),
		))
	}

	return sb.String()
}

func renderNotFound(path string) string {
	return ufmt.Sprintf(
		"# Route Not Found\n\nUnknown path `%s`.\n\nSupported routes: `/` (dashboard), `/escrow/<id>`, `/address/<addr>`.\n\n[← Back to HearthEscrow](%s)\n",
		escapeInline(path),
		realmLinkBase,
	)
}

func renderQuickStartSnippet() string {
	return "```bash\ngnokey maketx call -pkgpath \"" + realmPkgPath + "\" -func CreateEscrow \\\n" +
		"  -send 1000000ugnot \\\n" +
		"  -args \"Logo & UI Kit\" -args <recipient_addr> -args <arbiter_addr> -args 500000 \\\n" +
		"  -args \"Wireframes,Final Delivery\" -args \"4000,6000\" <depositor_key>\n```\n"
}

func splitPathQuery(p string) (string, string) {
	if idx := strings.Index(p, "?"); idx >= 0 {
		return p[:idx], p[idx+1:]
	}
	return p, ""
}

func parseQueryParam(query, key string) string {
	if query == "" {
		return ""
	}
	for _, pair := range strings.Split(query, "&") {
		kv := strings.SplitN(pair, "=", 2)
		if len(kv) == 2 && kv[0] == key {
			return kv[1]
		}
	}
	return ""
}

func filterLink(label, value, current string) string {
	href := realmLinkBase
	if value != "" {
		href = realmLinkBase + ":?status=" + value
	}
	if value == current {
		return ufmt.Sprintf("**[%s](%s)**", label, href)
	}
	return ufmt.Sprintf("[%s](%s)", label, href)
}

func matchesFilter(st Status, filter string) bool {
	switch filter {
	case "":
		return true
	case "active":
		return st == StatusActive
	case "disputed":
		return st == StatusDisputed
	case "closed":
		return st == StatusCompleted || st == StatusResolved || st == StatusRefunded
	default:
		return false
	}
}

func statusBadge(st Status) string {
	switch st {
	case StatusActive:
		return "ACTIVE"
	case StatusDisputed:
		return "DISPUTED"
	case StatusCompleted:
		return "COMPLETED"
	case StatusResolved:
		return "RESOLVED"
	case StatusRefunded:
		return "REFUNDED"
	default:
		return string(st)
	}
}

func milestoneBadge(st MilestoneStatus) string {
	switch st {
	case MilestonePending:
		return "Pending"
	case MilestoneSubmitted:
		return "Submitted"
	case MilestoneApproved:
		return "Approved"
	default:
		return string(st)
	}
}

func progressBar(done, total int) string {
	const width = 10
	if total <= 0 {
		return "[----------] 0%"
	}
	filled := (done * width) / total
	pct := (done * 100) / total
	return "[" + strings.Repeat("#", filled) + strings.Repeat("-", width-filled) + "] " + strconv.Itoa(pct) + "%"
}

func formatUGNOT(amt int64) string {
	whole := amt / UGNOTPerGNOT
	frac := amt % UGNOTPerGNOT
	if frac < 0 {
		frac = -frac
	}
	if frac == 0 {
		return ufmt.Sprintf("%d GNOT (%d ugnot)", whole, amt)
	}
	fracStr := strconv.FormatInt(frac, 10)
	for len(fracStr) < 6 {
		fracStr = "0" + fracStr
	}
	fracStr = strings.TrimRight(fracStr, "0")
	return ufmt.Sprintf("%d.%s GNOT (%d ugnot)", whole, fracStr, amt)
}

func formatBps(bps int64) string {
	whole := bps / 100
	rem := bps % 100
	if rem == 0 {
		return ufmt.Sprintf("%d%%", whole)
	}
	remStr := strconv.FormatInt(rem, 10)
	if len(remStr) < 2 {
		remStr = "0" + remStr
	}
	return ufmt.Sprintf("%d.%s%%", whole, remStr)
}

func shortAddr(a address) string {
	s := a.String()
	if len(s) <= 14 {
		return s
	}
	return s[:8] + "..." + s[len(s)-4:]
}

func escapeCell(s string) string {
	s = strings.ReplaceAll(s, "|", "/")
	s = strings.ReplaceAll(s, "\n", " ")
	s = strings.ReplaceAll(s, "\r", " ")
	return s
}

func escapeInline(s string) string {
	s = strings.ReplaceAll(s, "\n", " ")
	s = strings.ReplaceAll(s, "\r", " ")
	return s
}
