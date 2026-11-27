package latch

import (
	"net/url"
	"strconv"
	"strings"
)

const (
	renderPageSize = 6
)

// sanitizeInline neutralizes user-supplied text for safe Markdown inline/table
// output. Truncation happens BEFORE backslash-escaping so a cut never leaves a
// dangling trailing escape character.
func sanitizeInline(s string, maxRunes int) string {
	var folded strings.Builder
	runes := 0
	truncated := false
	for _, r := range s {
		if r == '\n' || r == '\r' || r == '\u0085' || r == '\u2028' || r == '\u2029' {
			if runes >= maxRunes {
				truncated = true
				break
			}
			folded.WriteByte(' ')
			runes++
			continue
		}
		if isControlOrInvisible(r) {
			continue
		}
		if runes >= maxRunes {
			truncated = true
			break
		}
		folded.WriteRune(r)
		runes++
	}
	var out strings.Builder
	for _, r := range folded.String() {
		switch r {
		case '\\', '`', '*', '_', '[', ']', '(', ')', '<', '>', '#', '!', '|', '~':
			out.WriteByte('\\')
		}
		out.WriteRune(r)
	}
	if truncated {
		out.WriteString("...")
	}
	return out.String()
}

func formatGNOT(ugnot int64) string {
	whole := ugnot / ugnotPerGNOT
	frac := ugnot % ugnotPerGNOT
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
	s := string(a)
	if s == "" {
		return "Open (unclaimed)"
	}
	if len(s) <= 16 {
		return s
	}
	return s[:8] + "..." + s[len(s)-6:]
}

func parsePage(rawPath string, totalPages int) int {
	if totalPages <= 0 {
		return 1
	}
	page := 1
	if u, err := url.Parse(rawPath); err == nil {
		if raw := u.Query().Get("page"); raw != "" {
			if n, err := strconv.Atoi(raw); err == nil {
				page = n
			}
		}
	}
	if page < 1 {
		page = 1
	}
	if page > totalPages {
		page = totalPages
	}
	return page
}

func parseDealRoute(rawPath string) (int, bool) {
	u, err := url.Parse(rawPath)
	if err != nil {
		return 0, false
	}
	p := strings.Trim(u.Path, "/")
	if !strings.HasPrefix(p, "deal/") {
		return 0, false
	}
	idStr := strings.TrimPrefix(p, "deal/")
	if idStr == "" || strings.Contains(idStr, "/") {
		return 0, false
	}
	id, err := strconv.Atoi(idStr)
	if err != nil || id < 1 || id > len(deals) {
		return 0, false
	}
	return id, true
}

func renderDealDetail(id int) string {
	d := mustDeal(id)
	var b strings.Builder
	b.WriteString("# Latch Deal #" + strconv.Itoa(d.ID) + ": " + sanitizeInline(d.Title, maxTitleRunes) + "\n\n")
	b.WriteString("[<- All Deals](?) \n\n")
	b.WriteString("- **Status:** " + string(d.Status) + "\n")
	b.WriteString("- **Escrow:** " + formatGNOT(d.Remaining) + " remaining of " + formatGNOT(d.TotalDeposited) + "\n")
	b.WriteString("- **Client:** `" + string(d.Client) + "`\n")
	b.WriteString("- **Worker:** `" + shortAddr(d.Worker) + "`\n")
	if d.Arbiter == "" {
		b.WriteString("- **Arbiter:** None *(Note: no-arbiter deals allow client post-deadline refund of submitted work)*\n")
	} else {
		b.WriteString("- **Arbiter:** `" + string(d.Arbiter) + "` *(chosen by client at creation)*\n")
	}
	b.WriteString("- **Deadline (Unix):** `" + strconv.FormatInt(d.Deadline, 10) + "`\n")
	if d.DisputeDeadline > 0 {
		b.WriteString("- **Dispute Timeout (Unix):** `" + strconv.FormatInt(d.DisputeDeadline, 10) + "`\n")
	}

	b.WriteString("\n## Milestones\n\n")
	b.WriteString("| # | Title | Amount | Status | Deliverable |\n")
	b.WriteString("|---|---|---|---|---|\n")
	for _, m := range d.Milestones {
		ref := "-"
		if m.DeliverableRef != "" {
			ref = sanitizeInline(m.DeliverableRef, maxDeliverableRunes)
		}
		b.WriteString("| " + strconv.Itoa(m.Index) +
			" | " + sanitizeInline(m.Title, maxMilestoneTitleRunes) +
			" | " + formatGNOT(m.Amount) +
			" | " + string(m.Status) +
			" | " + ref + " |\n")
	}
	b.WriteString("\n---\n")
	b.WriteString("Use **Actions** (`$help`) to call `ClaimDeal`, `ReclaimInactiveDeal`, `SubmitMilestone`, `ReleaseMilestone`, `RaiseDispute`, `ResolveDispute`, `ResolveDisputeTimeout`, `RefundExpired`, or `CancelDeal`.\n")
	return b.String()
}

// Render displays the gnoweb markdown interface for Latch.
func Render(path string) string {
	if id, ok := parseDealRoute(path); ok {
		return renderDealDetail(id)
	}

	var b strings.Builder
	b.WriteString("# Latch — Milestone Escrow & Micro-Bounties\n\n")
	b.WriteString("**Deals:** " + strconv.Itoa(stats.TotalDeals) +
		" | **Open:** " + strconv.Itoa(stats.OpenDeals) +
		" | **Active:** " + strconv.Itoa(stats.ActiveDeals) +
		" | **Disputed:** " + strconv.Itoa(stats.DisputedDeals) +
		" | **Completed:** " + strconv.Itoa(stats.CompletedDeals) +
		" | **Cancelled:** " + strconv.Itoa(stats.CancelledDeals) +
		" | **Deposited:** " + formatGNOT(stats.TotalDeposited) +
		" | **Released:** " + formatGNOT(stats.TotalReleased) +
		" | **Refunded:** " + formatGNOT(stats.TotalRefunded) + "\n\n")

	total := len(deals)
	if total == 0 {
		b.WriteString("_No deals created yet._ Use `CreateDeal` in **Actions** (`$help&func=CreateDeal`) to fund the first milestone deal.\n")
		return b.String()
	}

	totalPages := (total + renderPageSize - 1) / renderPageSize
	page := parsePage(path, totalPages)
	offset := (page - 1) * renderPageSize

	b.WriteString("## Deals (Page " + strconv.Itoa(page) + " of " + strconv.Itoa(totalPages) + ")\n\n")
	b.WriteString("| ID | Title | Status | Remaining | Worker | Arbiter |\n")
	b.WriteString("|---|---|---|---|---|---|\n")

	emitted := 0
	for i := total - 1 - offset; i >= 0 && emitted < renderPageSize; i-- {
		d := deals[i]
		emitted++
		arb := "None"
		if d.Arbiter != "" {
			arb = "`" + shortAddr(d.Arbiter) + "`"
		}
		idStr := strconv.Itoa(d.ID)
		b.WriteString("| [#" + idStr + "](:deal/" + idStr + ")" +
			" | " + sanitizeInline(d.Title, maxTitleRunes) +
			" | " + string(d.Status) +
			" | " + formatGNOT(d.Remaining) +
			" | `" + shortAddr(d.Worker) + "`" +
			" | " + arb + " |\n")
	}

	if totalPages > 1 {
		b.WriteString("\n")
		if page > 1 {
			b.WriteString("[<- Previous](?page=" + strconv.Itoa(page-1) + ") ")
		}
		if page < totalPages {
			b.WriteString("[Next ->](?page=" + strconv.Itoa(page+1) + ")")
		}
		b.WriteString("\n")
	}
	return b.String()
}
