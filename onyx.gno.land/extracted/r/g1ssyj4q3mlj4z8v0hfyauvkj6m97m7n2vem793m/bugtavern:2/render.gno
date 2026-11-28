// render.gno — Render router + all pages (design §8).
//
// Every user-supplied string on every page goes through escape.gno
// first (escInline for headings and link text, escCell for table
// cells, escURL for hrefs). Render never panics: a bad path, id or
// address renders the "not found" page, and any unexpected panic is
// recovered into the same page.
//
// Transaction links follow the boards pattern:
// /r/<realm>$help&func=<Func>&<param>=<value>... — only safe values
// are prefilled (ids, numbers, enum values). Free text such as a
// verdict reason is left for the caller to type in the form, so no
// user string ever flows into a link. Every move also has a
// copy-pasteable `gnokey maketx call` command next to it.
package bugtavern

import (
	"strconv"
	"strings"

	"chain/runtime"

	"gno.land/p/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/tavernrules"
)

// realmPkgPath is the full package path of this realm (gnokey
// commands).
const realmPkgPath = "gno.land/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern"

// realmWebPath is the gnoweb path of this realm (txlink base).
const realmWebPath = "/r/g1ssyj4q3mlj4z8v0hfyauvkj6m97m7n2vem793m/bugtavern"

// renderPageSize is the pagination size (design §8: 20/page).
const renderPageSize = 20

// pageURL returns the absolute gnoweb URL of a BugTavern page
// ("" is the board).
func pageURL(page string) string {
	if page == "" {
		return realmWebPath
	}
	return realmWebPath + "/" + page
}

// txlink builds a gnoweb transaction link with prefilled arguments.
func txlink(fn string, params ...string) string {
	out := realmWebPath + "$help&func=" + fn
	for i := 0; i+1 < len(params); i += 2 {
		out += "&" + params[i] + "=" + params[i+1]
	}
	return out
}

// tx renders a Markdown link to a prefilled transaction form.
func tx(text, fn string, params ...string) string {
	return "[" + text + "](" + txlink(fn, params...) + ")"
}

// gnokeyCall renders a copy-pasteable `gnokey maketx call` command.
// args are call arguments: numbers bare, text already double-quoted
// (placeholders for values only the caller knows).
func gnokeyCall(fn string, args ...string) string {
	cmd := "gnokey maketx call --pkgpath " + realmPkgPath + " --func " + fn
	for _, a := range args {
		cmd += " --args " + a
	}
	cmd += " --gas-fee 10000ugnot --gas-wanted 2000000 <your-key>"
	return "```\n" + cmd + "\n```\n"
}

// gnokeyCallSend is gnokeyCall for a payable function: the caller
// must attach the exact amount with --send.
func gnokeyCallSend(fn, send string, args ...string) string {
	cmd := "gnokey maketx call --pkgpath " + realmPkgPath + " --func " + fn
	for _, a := range args {
		cmd += " --args " + a
	}
	cmd += " --send " + send + " --gas-fee 10000ugnot --gas-wanted 2000000 <your-key>"
	return "```\n" + cmd + "\n```\n"
}

// u64 formats a uint64 id.
func u64(id uint64) string { return strconv.FormatUint(id, 10) }

// i64 formats an int64 height.
func i64(n int64) string { return strconv.FormatInt(n, 10) }

// parseUint parses a decimal id; ok is false on any bad input.
func parseUint(s string) (uint64, bool) {
	if s == "" {
		return 0, false
	}
	var n uint64
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c < '0' || c > '9' {
			return 0, false
		}
		n = n*10 + uint64(c-'0')
	}
	return n, true
}

// splitPath splits "bounty/1?page=2" into base "bounty/1" and page 2
// (default 1; a missing or malformed page is 1, never a panic).
func splitPath(path string) (string, int) {
	for len(path) > 0 && path[0] == '/' {
		path = path[1:]
	}
	page := 1
	if parts := strings.Split(path, "?"); len(parts) > 1 {
		path = parts[0]
		for _, kv := range strings.Split(parts[1], "&") {
			if strings.HasPrefix(kv, "page=") {
				if n, ok := parseUint(kv[5:]); ok && n >= 1 {
					page = int(n)
				}
			}
		}
	}
	return path, page
}

// daysLeft renders "~N days left" for a deadline height (1 block
// ≈ 3.5s, so 24600 blocks ≈ 1 day), or "past deadline".
func daysLeft(deadline, height int64) string {
	if height > deadline {
		return "past deadline"
	}
	d := (deadline - height) / 24600
	if d == 0 {
		return "less than a day left"
	}
	return "~" + strconv.FormatInt(d, 10) + " days left"
}

// heightText renders a height, or "—" when it is unset (0).
func heightText(h int64) string {
	if h == 0 {
		return "—"
	}
	return i64(h)
}

// heightNow is the current block height (SetHeight in tests).
func heightNow() int64 { return runtime.ChainHeight() }

// finalSevName is the finding's final severity when the arbiter set
// one, else the hunter's claimed severity.
func finalSevName(f tavernrules.Finding) string {
	if f.SeverityFinal().Valid() {
		return f.SeverityFinal().String()
	}
	return f.Severity().String()
}

// tryGetFinding loads a finding without panicking when the id is
// unknown (Render must never panic on a bad id).
func tryGetFinding(id uint64) (tavernrules.Finding, bool) {
	f, ok := findings.Get(findingKey(id)).(tavernrules.Finding)
	return f, ok
}

// pageNav renders Previous/Next links for a paginated page
// (base is the page URL without a query string).
func pageNav(base string, page int, hasNext bool) string {
	out := ""
	if page > 1 {
		out += "[← Previous](" + base + "?page=" + strconv.Itoa(page-1) + ") "
	}
	if hasNext {
		out += "[Next →](" + base + "?page=" + strconv.Itoa(page+1) + ")"
	}
	if out == "" {
		return ""
	}
	return "\n" + out + "\n"
}

// navBar is the shared navigation line under each page heading.
func navBar() string {
	return "[Board](" + pageURL("") + ") · [Leaderboard](" + pageURL("leaderboard") + ") · [Ledger](" + pageURL("ledger") + ") · [Help](" + pageURL("help") + ")\n"
}

// Render is the realm's page router (design §8). It never panics:
// a bad path, id or address renders the "not found" page.
func Render(path string) (out string) {
	defer func() {
		if recover() != nil {
			out = renderNotFound(path)
		}
	}()
	base, page := splitPath(path)
	switch {
	case base == "":
		return renderBoard(page)
	case base == "leaderboard":
		return renderLeaderboard()
	case base == "ledger":
		return renderLedger(page)
	case base == "help":
		return renderHelp()
	case strings.HasPrefix(base, "bounty/"):
		id, ok := parseUint(strings.TrimPrefix(base, "bounty/"))
		if !ok {
			return renderNotFound(path)
		}
		return renderBounty(id, page)
	case strings.HasPrefix(base, "finding/"):
		id, ok := parseUint(strings.TrimPrefix(base, "finding/"))
		if !ok {
			return renderNotFound(path)
		}
		return renderFinding(id)
	case strings.HasPrefix(base, "hunter/"):
		addr := strings.TrimPrefix(base, "hunter/")
		if escAddr(addr) == "" {
			return renderNotFound(path)
		}
		return renderHunter(address(addr), page)
	default:
		return renderNotFound(path)
	}
}

func renderNotFound(path string) string {
	return "# Not found\n\n" +
		"There is no BugTavern page at `" + escInline(path) + "`.\n\n" +
		navBar()
}

// renderBoard is the home page (design §8.1): totals, open
// bounties, recently disclosed findings, how it works.
func renderBoard(page int) string {
	t := GetTotals()
	open := 0
	accepted := 0
	for _, b := range allBountiesDesc() {
		if b.Status() == tavernrules.BountyOpen {
			open++
		}
	}
	for _, f := range allFindingsDesc() {
		if f.Status() == tavernrules.FindingAccepted || f.Status() == tavernrules.FindingDisclosed {
			accepted++
		}
	}
	out := "# BugTavern — Bug Bounty Keamanan untuk Realm Gno\n\n" +
		"Version " + version + ".\n\n" +
		"**Post a bounty:** " + tx("Create bounty", "CreateBounty") + " · [How it works](#how-it-works) · [Leaderboard](" + pageURL("leaderboard") + ") · [Ledger](" + pageURL("ledger") + ") · [Help](" + pageURL("help") + ")\n\n" +
		"## Totals\n\n" +
		"| Open bounties | GNOT locked | GNOT paid out | Findings accepted |\n" +
		"|---|---|---|---|\n" +
		"| " + strconv.Itoa(open) + " | " + fmtGNOT(t.Locked) + " | " + fmtGNOT(t.PaidOut) + " | " + strconv.Itoa(accepted) + " |\n\n" +
		"## Open bounties\n\n"
	var opens []tavernrules.Bounty
	for _, b := range allBountiesDesc() {
		if b.Status() == tavernrules.BountyOpen {
			opens = append(opens, b)
		}
	}
	offset := (page - 1) * renderPageSize
	if offset >= len(opens) {
		if len(opens) == 0 {
			out += "No open bounties yet. Be the first sponsor: " + tx("create one", "CreateBounty") + ".\n\n"
		} else {
			out += "No more bounties on this page.\n\n"
		}
	} else {
		end := offset + renderPageSize
		if end > len(opens) {
			end = len(opens)
		}
		out += "| # | Bounty | Scope | Pool left | Top tier | Arbiter | Deadline |\n|---|---|---|---|---|---|---|\n"
		for _, b := range opens[offset:end] {
			out += "| " + u64(b.ID()) + " | [" + escInline(b.Title()) + "](" + pageURL("bounty/"+u64(b.ID())) + ") | " + escCell(b.Scope()) + " | " + fmtGNOT(b.PoolLeft()) + " GNOT | Critical " + fmtGNOT(b.PriceCrit()) + " | `" + shortAddr(b.Arbiter()) + "` | " + daysLeft(b.Deadline(), heightNow()) + " |\n"
		}
		out += "\n"
		out += pageNav(pageURL(""), page, offset+renderPageSize < len(opens))
	}
	out += "## Recently disclosed\n\n"
	shown := 0
	for _, f := range allFindingsDesc() {
		if f.Status() != tavernrules.FindingDisclosed {
			continue
		}
		if shown == 0 {
			out += "| Finding | Bounty | Severity | Hunter | Paid |\n|---|---|---|---|---|\n"
		}
		title := f.Title()
		if title == "" {
			title = "(not revealed yet)"
		}
		out += "| [" + escInline(title) + "](" + pageURL("finding/"+u64(f.ID())) + ") | [#" + u64(f.BountyID()) + "](" + pageURL("bounty/"+u64(f.BountyID())) + ") | " + finalSevName(f) + " | [" + shortAddr(f.Hunter()) + "](" + pageURL("hunter/"+f.Hunter().String()) + ") | " + fmtGNOT(f.PaidAmount()) + " GNOT |\n"
		shown++
		if shown >= 5 {
			break
		}
	}
	if shown == 0 {
		out += "Nothing disclosed yet — disclosed findings appear here after the sponsor marks the bounty fixed.\n\n"
	} else {
		out += "\n"
	}
	out += "## How it works\n\n" +
		"1. **Sponsor** locks a GNOT pool for their realm, with a price per severity tier.\n" +
		"2. **Hunter** commits a finding as a hash first (anti-front-running), then reveals the PoC.\n" +
		"3. **Arbiter** decides: Accept (escrow pays automatically), Duplicate, or Reject with a public reason.\n" +
		"4. If the arbiter stays silent, the sponsor decides; if both stay silent, the hunter claims the payout.\n" +
		"5. After the fix, the sponsor marks the bounty fixed and the finding is disclosed publicly.\n\n" +
		"Full instructions, commands and costs: [Help](" + pageURL("help") + ").\n"
	return out
}

// renderBounty is the bounty detail page (design §8.2).
func renderBounty(id uint64, page int) string {
	b, ok := tryGetBounty(id)
	if !ok {
		return renderNotFound("bounty/" + u64(id))
	}
	height := heightNow()
	out := "# Bounty #" + u64(id) + " — " + escInline(b.Title()) + "\n\n" +
		navBar() + "\n" +
		"| Field | Value |\n|---|---|\n" +
		"| Status | " + b.Status().String() + " |\n" +
		"| Sponsor | `" + b.Sponsor().String() + "` |\n" +
		"| Arbiter | `" + b.Arbiter().String() + "` |\n" +
		"| Scope | " + escCell(b.Scope()) + " |\n" +
		"| Pool total | " + fmtGNOT(b.PoolTotal()) + " GNOT |\n" +
		"| Pool left | " + fmtGNOT(b.PoolLeft()) + " GNOT |\n" +
		"| Paid out | " + fmtGNOT(b.PaidOut()) + " GNOT |\n" +
		"| Refunded | " + fmtGNOT(b.Refunded()) + " GNOT |\n" +
		"| Critical | " + fmtGNOT(b.PriceCrit()) + " GNOT |\n" +
		"| High | " + fmtGNOT(b.PriceHigh()) + " GNOT |\n" +
		"| Medium | " + fmtGNOT(b.PriceMed()) + " GNOT |\n" +
		"| Low | " + fmtGNOT(b.PriceLow()) + " GNOT |\n" +
		"| Created | height " + i64(b.CreatedAt()) + " |\n" +
		"| Deadline | height " + i64(b.Deadline()) + " (" + daysLeft(b.Deadline(), height) + ") |\n" +
		"| Accepted | " + strconv.FormatInt(b.AcceptedCount(), 10) + " · Duplicates " + strconv.FormatInt(b.DuplicateCount(), 10) + " · Rejected " + strconv.FormatInt(b.RejectedCount(), 10) + " |\n\n" +
		"## Findings on this bounty\n\n"
	fs := FindingsByBounty(id, (page-1)*renderPageSize, renderPageSize)
	total := len(findingsOf(id))
	if len(fs) == 0 {
		out += "No findings yet.\n\n"
	} else {
		out += "| # | Hunter | Severity | Status | Paid |\n|---|---|---|---|---|\n"
		for _, f := range fs {
			sev := f.Severity().String()
			if f.SeverityFinal().Valid() && f.SeverityFinal() != f.Severity() {
				sev += " (final " + f.SeverityFinal().String() + ")"
			}
			out += "| [" + u64(f.ID()) + "](" + pageURL("finding/"+u64(f.ID())) + ") | [" + shortAddr(f.Hunter()) + "](" + pageURL("hunter/"+f.Hunter().String()) + ") | " + sev + " | " + f.Status().String() + " | " + fmtGNOT(f.PaidAmount()) + " GNOT |\n"
		}
		out += "\n"
		out += pageNav(pageURL("bounty/"+u64(id)), page, (page-1)*renderPageSize+len(fs) < total)
	}
	out += "## What can happen next\n\n" + nextMovesBounty(b, height)
	out += "## Commands\n\n" +
		"Commit a finding (severity 1 Low, 2 Medium, 3 High, 4 Critical):\n\n" +
		gnokeyCall("CommitFinding", u64(id), "\"<sha256hex>\"", "\"4\"") +
		"Arbiter verdict (Accept pays the final tier):\n\n" +
		gnokeyCall("Verdict", "\"<finding-id>\"", "\"1\"", "\"4\"", "\"confirmed\"", "\"0\"") +
		"Top up the pool (attach the exact top-up amount):\n\n" +
		gnokeyCallSend("TopUpBounty", "500000ugnot", u64(id))
	return out
}

// nextMovesBounty lists ONLY the moves that are valid right now for
// this bounty (design §8.2), with who may make each move and a
// prefilled transaction link.
func nextMovesBounty(b tavernrules.Bounty, height int64) string {
	if b.Status() != tavernrules.BountyOpen {
		return "This bounty is " + b.Status().String() + " (final). No moves remain.\n"
	}
	out := ""
	if height <= b.Deadline() {
		out += "- **Hunter — commit a finding:** " + tx("CommitFinding", "CommitFinding", "bountyID", u64(b.ID())) + " — needs the commit hash (see [Help](" + pageURL("help") + ") for how to compute it).\n"
	}
	fs := findingsOf(b.ID())
	for _, f := range fs {
		switch f.Status() {
		case tavernrules.FindingCommitted:
			out += "- Finding #" + u64(f.ID()) + " is committed but not yet revealed (reveal before height " + i64(f.RevealDeadline()) + ").\n"
		case tavernrules.FindingRevealed:
			out += verdictMoves(f, height, true)
		case tavernrules.FindingDisputed:
			out += verdictMoves(f, height, false)
		case tavernrules.FindingRejected:
			if !f.DisputedBefore() && height <= tavernrules.DisputeDeadlineAt(f.VerdictAt()) {
				out += "- **Hunter — dispute the rejection of finding #" + u64(f.ID()) + ":** " + tx("DisputeFinding", "DisputeFinding", "findingID", u64(f.ID())) + " (once only, before height " + i64(tavernrules.DisputeDeadlineAt(f.VerdictAt())) + ").\n"
			}
		}
	}
	out += "- **Sponsor — top up the pool:** " + tx("TopUpBounty", "TopUpBounty", "bountyID", u64(b.ID())) + " (attach ugnot with the call).\n"
	if !tavernrules.AnyInFlight(fs) && !tavernrules.AnyDisputable(fs, height) {
		out += "- **Sponsor — cancel this bounty:** " + tx("CancelBounty", "CancelBounty", "bountyID", u64(b.ID())) + " (refunds the remaining pool).\n"
		if height > b.Deadline() {
			out += "- **Sponsor — close this bounty:** " + tx("CloseBounty", "CloseBounty", "bountyID", u64(b.ID())) + " (refunds the remaining pool).\n"
		}
	}
	anyAccepted := false
	for _, f := range fs {
		if f.Status() == tavernrules.FindingAccepted {
			anyAccepted = true
		}
	}
	if anyAccepted {
		out += "- **Sponsor — mark fixed:** " + tx("MarkFixed", "MarkFixed", "bountyID", u64(b.ID())) + " (discloses accepted findings).\n"
	}
	if out == "" {
		out = "No moves are available right now.\n"
	}
	return out
}

// verdictMoves renders the Accept/Reject/Duplicate links (arbiter)
// or the sponsor/hunter fallbacks for one Revealed (first=true) or
// Disputed finding, according to the timeout ladder (design §6.3).
func verdictMoves(f tavernrules.Finding, height int64, first bool) string {
	id := u64(f.ID())
	sev := strconv.Itoa(int(f.Severity()))
	arbiterLinks := tx("Accept", "Verdict", "findingID", id, "verdict", "1", "finalSeverity", sev, "duplicateOf", "0") + " · " +
		tx("Reject", "Verdict", "findingID", id, "verdict", "3", "finalSeverity", sev, "duplicateOf", "0") + " · " +
		tx("Duplicate", "Verdict", "findingID", id, "verdict", "2", "finalSeverity", sev, "duplicateOf", "<original-id>")
	sponsorLinks := tx("Accept", "SponsorVerdict", "findingID", id, "verdict", "1", "finalSeverity", sev, "duplicateOf", "0") + " · " +
		tx("Reject", "SponsorVerdict", "findingID", id, "verdict", "3", "finalSeverity", sev, "duplicateOf", "0") + " · " +
		tx("Duplicate", "SponsorVerdict", "findingID", id, "verdict", "2", "finalSeverity", sev, "duplicateOf", "<original-id>")
	claimLink := tx("ClaimPayout", "ClaimPayout", "findingID", id)
	if first {
		if height <= f.ReviewDeadline() {
			return "- **Arbiter — decide finding #" + id + " (before height " + i64(f.ReviewDeadline()) + "):** " + arbiterLinks + " — Accept pays the final tier; the arbiter may correct the claimed " + f.Severity().String() + " tier up or down. Fill in the reason in the form.\n"
		}
		if height <= tavernrules.SponsorDeadlineAt(f.ReviewDeadline()) {
			return "- **Sponsor — decide finding #" + id + " (arbiter silent, before height " + i64(tavernrules.SponsorDeadlineAt(f.ReviewDeadline())) + "):** " + sponsorLinks + ".\n"
		}
		return "- **Hunter — claim the payout for finding #" + id + " (arbiter and sponsor silent):** " + claimLink + ".\n"
	}
	if height <= tavernrules.DisputeReviewDeadlineAt(f.DisputedAt()) {
		return "- **Arbiter — re-decide disputed finding #" + id + " (before height " + i64(tavernrules.DisputeReviewDeadlineAt(f.DisputedAt())) + "):** " + arbiterLinks + ".\n"
	}
	if height <= tavernrules.DisputeClaimableAfter(f.DisputedAt()) {
		return "- **Sponsor — re-decide disputed finding #" + id + " (arbiter silent, before height " + i64(tavernrules.DisputeClaimableAfter(f.DisputedAt())) + "):** " + sponsorLinks + ".\n"
	}
	return "- **Hunter — claim the payout for disputed finding #" + id + " (arbiter and sponsor silent):** " + claimLink + ".\n"
}

// pocCell renders a finding's PoC URL as a link when its scheme is
// allowed, else as escaped plain text (never a link from a
// rejected URL).
func pocCell(f tavernrules.Finding) string {
	if f.PocURL() == "" {
		return "—"
	}
	if url := escURL(f.PocURL()); url != "" {
		return "[" + escInline(f.PocURL()) + "](" + url + ")"
	}
	return escCell(f.PocURL())
}

// verdictByCell renders the deciding address, or "—".
func verdictByCell(f tavernrules.Finding) string {
	if f.VerdictBy() == "" {
		return "—"
	}
	return "[" + shortAddr(f.VerdictBy()) + "](" + pageURL("hunter/"+f.VerdictBy().String()) + ")"
}

// renderFinding is the finding detail page (design §8.3).
func renderFinding(id uint64) string {
	f, ok := tryGetFinding(id)
	if !ok {
		return renderNotFound("finding/" + u64(id))
	}
	height := heightNow()
	title := f.Title()
	if title == "" {
		title = "(not revealed yet)"
	}
	finalSev := "—"
	if f.SeverityFinal().Valid() {
		finalSev = f.SeverityFinal().String()
	}
	dupOf := "—"
	if f.DuplicateOf() != 0 {
		dupOf = "[#" + u64(f.DuplicateOf()) + "](" + pageURL("finding/"+u64(f.DuplicateOf())) + ")"
	}
	out := "# Finding #" + u64(id) + " — " + escInline(title) + "\n\n" +
		navBar() + "\n" +
		"| Field | Value |\n|---|---|\n" +
		"| Bounty | [#" + u64(f.BountyID()) + "](" + pageURL("bounty/"+u64(f.BountyID())) + ") |\n" +
		"| Hunter | [" + shortAddr(f.Hunter()) + "](" + pageURL("hunter/"+f.Hunter().String()) + ") |\n" +
		"| Severity claimed | " + f.Severity().String() + " |\n" +
		"| Severity final | " + finalSev + " |\n" +
		"| Status | " + f.Status().String() + " |\n" +
		"| Commit hash | `" + f.CommitHash() + "` |\n" +
		"| Committed | height " + i64(f.CommittedAt()) + " |\n" +
		"| Reveal deadline | height " + i64(f.RevealDeadline()) + " |\n" +
		"| Revealed | " + heightText(f.RevealedAt()) + " |\n" +
		"| Review deadline | " + heightText(f.ReviewDeadline()) + " |\n" +
		"| PoC | " + pocCell(f) + " |\n" +
		"| Verdict by | " + verdictByCell(f) + " |\n" +
		"| Verdict at | " + heightText(f.VerdictAt()) + " |\n" +
		"| Verdict reason | " + escCell(f.VerdictReason()) + " |\n" +
		"| Duplicate of | " + dupOf + " |\n" +
		"| Paid | " + fmtGNOT(f.PaidAmount()) + " GNOT |\n" +
		"| Disclosed | " + heightText(f.DisclosedAt()) + " |\n\n"
	switch f.Status() {
	case tavernrules.FindingCommitted:
		out += "Contents not yet revealed — the hunter must reveal before height " + i64(f.RevealDeadline()) + ".\n\n" +
			"Reveal (hunter only):\n\n" +
			gnokeyCall("RevealFinding", u64(id), "\"<title>\"", "\"<https://poc-url>\"", "\"<salt>\"")
	case tavernrules.FindingRevealed:
		out += "## What can happen next\n\n" + verdictMoves(f, height, true)
	case tavernrules.FindingDisputed:
		out += "## What can happen next\n\n" + verdictMoves(f, height, false)
	case tavernrules.FindingRejected:
		out += "Rejected: " + escCell(f.VerdictReason()) + "\n\n"
		if !f.DisputedBefore() && height <= tavernrules.DisputeDeadlineAt(f.VerdictAt()) {
			out += "The hunter may dispute once, before height " + i64(tavernrules.DisputeDeadlineAt(f.VerdictAt())) + ": " + tx("DisputeFinding", "DisputeFinding", "findingID", u64(id)) + ".\n"
		}
	}
	return out
}

// renderHunter is the hunter profile page (design §8.4): public
// reputation + the hunter's findings.
func renderHunter(addr address, page int) string {
	s := HunterStats(addr)
	out := "# Hunter `" + shortAddr(addr) + "`\n\n" +
		navBar() + "\n" +
		"| Submitted | Accepted | Duplicates | Rejected | Earned |\n" +
		"|---|---|---|---|---|\n" +
		"| " + strconv.Itoa(s.Submitted()) + " | " + strconv.Itoa(s.Accepted()) + " | " + strconv.Itoa(s.Duplicates()) + " | " + strconv.Itoa(s.Rejected()) + " | " + fmtGNOT(s.Earned()) + " GNOT |\n\n" +
		"## Findings\n\n"
	fs := FindingsByHunter(addr, (page-1)*renderPageSize, renderPageSize)
	total := len(FindingsByHunter(addr, 0, 50))
	if len(fs) == 0 {
		out += "No findings recorded for this address yet.\n"
	} else {
		out += "| # | Bounty | Title | Severity | Status | Paid |\n|---|---|---|---|---|---|\n"
		for _, f := range fs {
			title := f.Title()
			if title == "" {
				title = "(not revealed yet)"
			}
			out += "| [" + u64(f.ID()) + "](" + pageURL("finding/"+u64(f.ID())) + ") | [#" + u64(f.BountyID()) + "](" + pageURL("bounty/"+u64(f.BountyID())) + ") | " + escCell(title) + " | " + finalSevName(f) + " | " + f.Status().String() + " | " + fmtGNOT(f.PaidAmount()) + " GNOT |\n"
		}
		out += "\n"
		out += pageNav(pageURL("hunter/"+addr.String()), page, (page-1)*renderPageSize+len(fs) < total)
	}
	return out
}

// renderLeaderboard is the leaderboard page (design §8.5): top 25
// hunters and top arbiters. Note: the `ui.Podium` widget for the top
// 3 (kingofdice pattern) is not available in the gno v1.8.0 package
// set, so the leaders use the same table — see README day 6.
func renderLeaderboard() string {
	out := "# Leaderboard\n\n" + navBar() + "\n" +
		"Top hunters by accepted findings, then earned GNOT, then address.\n\n" +
		"| Rank | Hunter | Accepted | Earned | Submitted | Duplicates |\n|---|---|---|---|---|---|\n"
	th := TopHunters(25)
	for i, h := range th {
		out += "| " + strconv.Itoa(i+1) + " | [" + shortAddr(h.Addr()) + "](" + pageURL("hunter/"+h.Addr().String()) + ") | " + strconv.Itoa(h.Accepted()) + " | " + fmtGNOT(h.Earned()) + " GNOT | " + strconv.Itoa(h.Submitted()) + " | " + strconv.Itoa(h.Duplicates()) + " |\n"
	}
	if len(th) == 0 {
		out += "No hunters yet.\n"
	}
	out += "\n## Top arbiters\n\n" +
		"| Arbiter | Verdicts | Accepted | Rejected | Duplicates | Timeouts |\n|---|---|---|---|---|---|\n"
	ta := TopArbiters(25)
	for _, a := range ta {
		out += "| `" + shortAddr(a.Addr()) + "` | " + strconv.Itoa(a.Verdicts()) + " | " + strconv.Itoa(a.Accepted()) + " | " + strconv.Itoa(a.Rejected()) + " | " + strconv.Itoa(a.Duplicates()) + " | " + strconv.Itoa(a.Timeouts()) + " |\n"
	}
	if len(ta) == 0 {
		out += "No arbiters yet.\n"
	}
	return out
}

// renderLedger is the money trail page (design §8.6).
func renderLedger(page int) string {
	total := LedgerCount()
	offset := (page - 1) * renderPageSize
	entries := GetLedger(offset, renderPageSize)
	out := "# Ledger — money trail\n\n" + navBar() + "\n" +
		"Every ugnot that entered or left the escrow, newest first. " +
		"Tracked total: " + strconv.Itoa(total) + " entries.\n\n"
	if len(entries) == 0 {
		out += "No money has moved yet.\n"
		return out
	}
	out += "| Height | Bounty | Finding | Kind | To | Amount | Note |\n|---|---|---|---|---|---|---|\n"
	for _, e := range entries {
		finding := "—"
		if e.FindingID != 0 {
			finding = "[#" + u64(e.FindingID) + "](" + pageURL("finding/"+u64(e.FindingID)) + ")"
		}
		out += "| " + i64(e.Height) + " | [#" + u64(e.BountyID) + "](" + pageURL("bounty/"+u64(e.BountyID)) + ") | " + finding + " | " + escCell(e.Kind) + " | [" + shortAddr(e.To) + "](" + pageURL("hunter/"+e.To.String()) + ") | " + fmtGNOT(e.Amount) + " GNOT | " + escCell(e.Note) + " |\n"
	}
	out += "\n"
	out += pageNav(pageURL("ledger"), page, offset+len(entries) < total)
	return out
}

// renderHelp is the help page (design §8.7).
func renderHelp() string {
	return "# Help — how to use BugTavern\n\n" + navBar() + "\n" +
		"BugTavern is a bug-bounty escrow for Gno realms: sponsors lock GNOT, hunters report " +
		"vulnerabilities (hash first, contents later), and an arbiter decides who gets paid.\n\n" +
		"## Sponsor\n\n" +
		"1. Create a bounty: lock the pool (the sum of the four tier prices) in one transaction.\n\n" +
		gnokeyCallSend("CreateBounty", "9500000ugnot", "\"TavernVault audit\"", "\"gno.land/r/.../vault\"", "\"5000000\"", "\"3000000\"", "\"1000000\"", "\"500000\"", "\"<arbiter-address>\"", "\"24600\"") +
		"Tier prices are in ugnot (1 GNOT = 1,000,000 ugnot). `24600` is the deadline in blocks (~1 day; " +
		"minimum 24600, maximum 2214000, ~90 days). The arbiter may be a third-party auditor.\n\n" +
		"2. Top up the pool at any time while the bounty is Open (attach the top-up amount).\n\n" +
		gnokeyCallSend("TopUpBounty", "500000ugnot", "\"1\"") +
		"3. After the fix, mark the bounty fixed to disclose accepted findings:\n\n" +
		gnokeyCall("MarkFixed", "\"1\"") +
		"4. Cancel (no findings in flight) or close (after the deadline, no findings in flight) to " +
		"refund the remaining pool:\n\n" +
		gnokeyCall("CancelBounty", "\"1\"") +
		"5. If the arbiter stays silent past the review window, you decide instead:\n\n" +
		gnokeyCall("SponsorVerdict", "\"1\"", "\"1\"", "\"4\"", "\"confirmed\"", "\"0\"") +
		"## Hunter\n\n" +
		"1. Pick a salt (at least 16 random characters) and compute the commitment hash off-chain:\n\n" +
		"```\n" +
		"echo -n \"1|4|Missing access control on Withdraw|https://example.com/poc|<salt>\" | sha256sum\n" +
		"```\n\n" +
		"The format is `bountyID|severity|title|pocURL|salt` with severity 1 Low, 2 Medium, 3 High, " +
		"4 Critical. The example above hashes to `ceba4aa550e737510103fa7a74d5593628ca6afa4d5af1fe43e26ffe4e896c2c` " +
		"with salt `saltsaltsaltsalt`.\n\n" +
		"2. Commit the hash (contents stay hidden):\n\n" +
		gnokeyCall("CommitFinding", "\"1\"", "\"<sha256hex>\"", "\"4\"") +
		"3. Reveal within 24,600 blocks (~24h):\n\n" +
		gnokeyCall("RevealFinding", "\"1\"", "\"Missing access control on Withdraw\"", "\"https://example.com/poc\"", "\"<salt>\"") +
		"4. If your finding is rejected, dispute once within 36,000 blocks (~36h):\n\n" +
		gnokeyCall("DisputeFinding", "\"1\"", "\"repro steps attached in PoC\"") +
		"5. If the arbiter and then the sponsor both stay silent, claim the payout yourself:\n\n" +
		gnokeyCall("ClaimPayout", "\"1\"") +
		"## Arbiter\n\n" +
		"Decide a revealed finding within 72,000 blocks (~3 days) of the reveal. Accept pays the " +
		"FINAL tier — you may correct the hunter's claimed severity up or down, and the price " +
		"follows the corrected tier. Duplicate needs the original finding's id; Reject needs a reason.\n\n" +
		gnokeyCall("Verdict", "\"1\"", "\"1\"", "\"4\"", "\"confirmed, drains vault\"", "\"0\"") +
		"## Costs and limits\n\n" +
		"- Storage deposit is 100 ugnot per byte of stored state; keep titles short.\n" +
		"- Posting a bounty on Onyx costs roughly 0.65–0.76 GNOT (QuestMaster measurement — re-verify at deploy).\n" +
		"- Title at most 100 characters; scope at most 1,000; PoC URL at most 300 and must start with `https://`; reasons at most 300.\n" +
		"- Minimum bounty 1 GNOT; minimum tier price 0.1 GNOT; each tier pays at most once per bounty (first valid finding wins).\n" +
		"- Windows (blocks): reveal 24,600 (~24h), arbiter review 72,000 (~3 days), sponsor 72,000, dispute 36,000 (~36h), disclosure 345,600 (~14 days).\n\n" +
		"## Known limitations\n\n" +
		"- Arbiter–sponsor collusion cannot be prevented on-chain; verdicts and track records are public.\n" +
		"- Finding contents become public at reveal — commit-reveal protects attribution and ordering, not eternal secrecy.\n" +
		"- Severity judgement is human; the code only enforces the money.\n" +
		"- The realm cannot be upgraded in place; a fix means a new realm path (see README).\n\n" +
		"Source: https://github.com/lusiana27/bugtavern\n"
}
