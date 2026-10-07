package bounties

import (
	"chain"
	"net/url"
	"strconv"
	"strings"

	"gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/guildhall/bounty/v0"
	"gno.land/p/moul/txlink/v0"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/guildhall/reputation"
	"gno.land/r/nt/grc20reg/v0"
)

const (
	realmURL = "/r/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/guildhall/bounties"
	repURL   = "/r/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/guildhall/reputation"
	pageSize = 20
)

// Render serves the bounty board:
//
//	""             the board (?status=open|active|completed|cancelled|all, ?tag=x, ?page=N)
//	<id>           a bounty with its milestones and next actions
//	u/<address>    bounties an address posted, works on, reviews or applied to
//	post           how to post a bounty
func Render(path string) string {
	route, query := splitQuery(path)
	parts := strings.Split(route, "/")
	switch {
	case parts[0] == "api":
		return renderAPI(route, query)
	case route == "":
		return renderBoard(query)
	case route == "post":
		return renderPost()
	case len(parts) == 2 && parts[0] == "u":
		return renderUser(address(parts[1]), pageOf(query))
	case len(parts) == 1:
		id, err := strconv.ParseUint(parts[0], 10, 64)
		if err != nil {
			return notFound()
		}
		return renderBounty(id)
	}
	return notFound()
}

func renderBoard(q url.Values) string {
	status := q.Get("status")
	if status == "" {
		status = "open"
	}
	tag := strings.ToLower(q.Get("tag"))
	page := pageOf(q)

	var b strings.Builder
	b.WriteString("# Guildhall Bounties\n\n")
	b.WriteString("Fund work, get it reviewed, pay on approval. Every payout becomes a public [reputation record](" + repURL + ").\n\n")
	b.WriteString(ufmt.Sprintf("**%d** open · **%d** in progress · **%d** completed · **%s** in escrow\n\n",
		statusCount[bounty.StatusOpen], statusCount[bounty.StatusActive], statusCount[bounty.StatusCompleted], escrowSummary()))
	if paused {
		b.WriteString("> Posting new bounties is paused by the council. Existing bounties are unaffected.\n\n")
	} else {
		b.WriteString("[+ Post a bounty](" + realmURL + ":post)\n\n")
	}

	var tabs []string
	for _, s := range []string{"open", "active", "completed", "cancelled", "all"} {
		label := s
		if s == status {
			label = "**" + s + "**"
		}
		link := realmURL + "?status=" + s
		if tag != "" {
			link += "&tag=" + url.QueryEscape(tag)
		}
		tabs = append(tabs, "["+label+"]("+link+")")
	}
	b.WriteString(strings.Join(tabs, " · "))
	if tag != "" {
		b.WriteString(" · tag: `" + sanitize.InlineText(tag) + "` ([clear](" + realmURL + "?status=" + url.QueryEscape(status) + "))")
	}
	b.WriteString("\n\n")

	want, filtered := bounty.ParseStatus(status)
	var matches []*bounty.Bounty
	skip := (page - 1) * pageSize
	more := false
	bounties.ReverseIterate("", "", func(_ string, v any) bool {
		bn := v.(*bounty.Bounty)
		if filtered && bn.Status != want {
			return false
		}
		if tag != "" && !hasTag(bn, tag) {
			return false
		}
		if skip > 0 {
			skip--
			return false
		}
		if len(matches) == pageSize {
			more = true
			return true
		}
		matches = append(matches, bn)
		return false
	})
	b.WriteString(bountyTable(matches))

	var nav []string
	if page > 1 {
		nav = append(nav, "[← newer]("+boardLink(status, tag, page-1)+")")
	}
	if more {
		nav = append(nav, "[older →]("+boardLink(status, tag, page+1)+")")
	}
	if len(nav) > 0 {
		b.WriteString("\n" + strings.Join(nav, " · ") + "\n")
	}
	return b.String()
}

func renderBounty(id uint64) string {
	bn := getBounty(id)
	if bn == nil {
		return notFound()
	}
	var b strings.Builder
	b.WriteString(ufmt.Sprintf("# #%d %s\n\n", bn.ID, sanitize.InlineText(bn.Title)))
	b.WriteString(ufmt.Sprintf("**%s** · %s · posted %s", strings.ToUpper(bn.Status.String()), formatAmount(bn, bn.Total()), bn.CreatedAt.UTC().Format("2006-01-02")))
	if len(bn.Tags) > 0 {
		var ts []string
		for _, t := range bn.Tags {
			ts = append(ts, "["+t+"]("+realmURL+"?status=all&tag="+url.QueryEscape(t)+")")
		}
		b.WriteString(" · " + strings.Join(ts, " "))
	}
	b.WriteString("\n\n")

	if bn.Description != "" {
		b.WriteString(sanitize.Block(bn.Description) + "\n\n")
	}
	if bn.Link != "" {
		b.WriteString("Reference: " + linkOrText(bn.Link) + "\n\n")
	}

	b.WriteString("| | |\n|---|---|\n")
	b.WriteString("| Posted by | " + person(bn.Poster) + " |\n")
	if bn.Assignee != "" {
		b.WriteString("| Assigned to | " + person(bn.Assignee) + " since " + bn.AssignedAt.UTC().Format("2006-01-02") + " |\n")
	}
	var revs []string
	for _, r := range bn.Reviewers {
		revs = append(revs, person(r))
	}
	b.WriteString(ufmt.Sprintf("| Reviewers (%d of %d must approve) | %s |\n", bn.Quorum, len(bn.Reviewers), strings.Join(revs, ", ")))
	arb := person(bn.Arbiter)
	if councilArbitrated.Has(idKey(bn.ID)) {
		arb = "Guildhall council (" + person(council.Owner()) + ")"
	}
	b.WriteString("| Arbiter | " + arb + " |\n")
	b.WriteString(ufmt.Sprintf("| Work window | %d days |\n", int(bn.WorkWindow.Hours()/24)))
	b.WriteString("| Escrow | " + formatAmount(bn, bn.Escrowed()) + " held · " + formatAmount(bn, bn.PaidOut()) + " paid |\n\n")

	b.WriteString("## Milestones\n\n")
	b.WriteString("| # | Milestone | Reward | Status | Work | Approvals |\n|---:|---|---:|---|---|---|\n")
	for i, m := range bn.Milestones {
		work := "-"
		if m.Submission != "" {
			work = linkOrText(m.Submission)
		}
		b.WriteString(ufmt.Sprintf("| %d | %s | %s | %s | %s | %d/%d |\n",
			i+1, sanitize.TableCell(m.Title), formatAmount(bn, m.Amount), milestoneStatus(m), work, len(m.Approvals), bn.Quorum))
	}
	b.WriteString("\n")

	for i, m := range bn.Milestones {
		if m.Feedback != "" && m.Status == bounty.MilestoneChangesRequested {
			b.WriteString(ufmt.Sprintf("> **Milestone %d, changes requested:** %s\n\n", i+1, sanitize.InlineText(m.Feedback)))
		}
		if d := m.Dispute; d != nil {
			b.WriteString(ufmt.Sprintf("> **Milestone %d, disputed by %s:** %s\n", i+1, person(d.OpenedBy), sanitize.InlineText(d.Reason)))
			if d.Resolved {
				ruling := ""
				if d.Ruling != "" {
					ruling = ": " + sanitize.InlineText(d.Ruling)
				}
				b.WriteString(ufmt.Sprintf(">\n> **Ruling:** %s to the worker%s\n", bps(d.WorkerBps), ruling))
			}
			b.WriteString("\n")
		}
	}

	b.WriteString(renderActions(bn))

	if bn.Status == bounty.StatusOpen && len(bn.Applications) > 0 {
		b.WriteString("## Applications\n\n| Applicant | Reputation | Pitch | |\n|---|---:|---|---|\n")
		for _, a := range bn.Applications {
			assign := txlink.NewLink("Assign").AddArgs("id", idStr(bn), "assignee", a.Applicant.String()).URL()
			b.WriteString(ufmt.Sprintf("| %s | %d | %s | [assign](%s) |\n",
				person(a.Applicant), reputation.Score(a.Applicant), sanitize.TableCell(a.Pitch), assign))
		}
		b.WriteString("\n")
	}
	return b.String()
}

// renderActions lists the transactions that can move the bounty forward, as
// gnoweb transaction links. The chain enforces who may call them; the page
// just lists them all.
func renderActions(bn *bounty.Bounty) string {
	var acts []string
	id := idStr(bn)
	add := func(label, fn string, args ...string) {
		acts = append(acts, "["+label+"]("+txlink.NewLink(fn).AddArgs(append([]string{"id", id}, args...)...).URL()+")")
	}

	switch bn.Status {
	case bounty.StatusOpen:
		add("Apply", "Apply")
		add("Assign (poster)", "Assign")
		add("Cancel and refund (poster)", "Cancel")
	case bounty.StatusActive:
		for i, m := range bn.Milestones {
			n := strconv.Itoa(i + 1)
			switch m.Status {
			case bounty.MilestonePending, bounty.MilestoneChangesRequested:
				add("Submit milestone "+n+" (assignee)", "Submit", "milestone", n)
				if m.Status == bounty.MilestoneChangesRequested {
					add("Dispute milestone "+n, "OpenDispute", "milestone", n)
				}
			case bounty.MilestoneSubmitted:
				add("Approve milestone "+n+" (reviewer)", "Approve", "milestone", n)
				add("Request changes on "+n+" (reviewer)", "RequestChanges", "milestone", n)
				add("Dispute milestone "+n, "OpenDispute", "milestone", n)
			case bounty.MilestoneDisputed:
				add("Resolve milestone "+n+" (arbiter)", "Resolve", "milestone", n)
			}
		}
		add("Step back / reclaim", "Unassign")
	}
	if len(acts) == 0 {
		return ""
	}
	return "## Actions\n\n" + strings.Join(acts, " · ") + "\n\n"
}

func renderUser(addr address, page int) string {
	if !addr.IsValid() {
		return notFound()
	}
	var b strings.Builder
	b.WriteString("# Bounties for " + addr.String() + "\n\n")
	b.WriteString(ufmt.Sprintf("Reputation: **%d** (%s) · [profile](%s:u/%s)\n\n",
		reputation.Score(addr), reputation.Level(addr), repURL, addr.String()))
	v := byUser.Get(addr.String())
	if v == nil {
		b.WriteString("_Not involved in any bounty yet._\n")
		return b.String()
	}
	ids := v.(*avl.Tree)
	var list []*bounty.Bounty
	ids.ReverseIterateByOffset((page-1)*pageSize, pageSize, func(k string, _ any) bool {
		if bv := bounties.Get(k); bv != nil {
			list = append(list, bv.(*bounty.Bounty))
		}
		return false
	})
	b.WriteString("| # | Bounty | Role | Reward | Status |\n|---:|---|---|---:|---|\n")
	for _, bn := range list {
		b.WriteString(ufmt.Sprintf("| %d | [%s](%s:%d) | %s | %s | %s |\n",
			bn.ID, sanitize.TableCell(bn.Title), realmURL, bn.ID, role(bn, addr), formatAmount(bn, bn.Total()), bn.Status.String()))
	}
	if ids.Size() > page*pageSize {
		b.WriteString(ufmt.Sprintf("\n[older →](%s:u/%s?page=%d)\n", realmURL, addr.String(), page+1))
	}
	return b.String()
}

func renderPost() string {
	native := txlink.NewLink("PostBounty").
		AddArgs("title", "", "description", "", "link", "", "tags", "", "reviewers", "", "quorum", "1", "milestones", "", "arbiter", "", "workWindowDays", "30").
		SetSend("1000000ugnot").URL()
	grc := txlink.NewLink("PostBountyGRC20").
		AddArgs("tokenKey", "", "title", "", "milestones", "", "quorum", "1", "workWindowDays", "30").URL()

	var b strings.Builder
	b.WriteString("# Post a bounty\n\n")
	b.WriteString("## With GNOT\n\n")
	b.WriteString("[Open the form](" + native + ") and set the amount to send to the bounty's total.\n\n")
	b.WriteString("- **milestones**: `Title=amount;Title=amount` in the smallest unit (`ugnot`). They must add up to exactly what you send. Leave empty for a single milestone worth everything sent.\n")
	b.WriteString("- **reviewers**: comma-separated addresses. Leave empty to review it yourself.\n")
	b.WriteString("- **quorum**: how many reviewers must approve each milestone.\n")
	b.WriteString("- **arbiter**: who settles disputes. Leave empty for the Guildhall council.\n")
	b.WriteString("- **workWindowDays**: after this many days without progress you can take the bounty back from its assignee (default 30).\n\n")
	b.WriteString("```sh\ngnokey maketx call -pkgpath gno.land/r/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/guildhall/bounties -func PostBounty \\\n")
	b.WriteString("  -args \"Port faucet to interrealm v2\" -args \"Rewrite r/faucet using cur realm\" \\\n")
	b.WriteString("  -args \"https://github.com/gnolang/gno/issues/1234\" -args \"realm,good-first-issue\" \\\n")
	b.WriteString("  -args \"g1reviewer1...,g1reviewer2...\" -args 2 \\\n")
	b.WriteString("  -args \"Design=20000000;Implementation=80000000\" -args \"\" -args 30 \\\n")
	b.WriteString("  -send 100000000ugnot -gas-fee 1000000ugnot -gas-wanted 20000000 -broadcast -chainid gnoland1 KEY\n```\n\n")
	b.WriteString("## With a GRC20 token\n\n")
	b.WriteString("1. Approve `" + chain.PackageAddress("gno.land/r/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/guildhall/bounties").String() + "` on the token for the bounty's total.\n")
	b.WriteString("2. Call [PostBountyGRC20](" + grc + ") with the token's [grc20reg](/r/nt/grc20reg/v0) key. Milestone amounts are required.\n")
	return b.String()
}

func bountyTable(list []*bounty.Bounty) string {
	if len(list) == 0 {
		return "_No bounties here yet._\n"
	}
	var b strings.Builder
	b.WriteString("| # | Bounty | Reward | Progress | Status | Poster |\n|---:|---|---:|---|---|---|\n")
	for _, bn := range list {
		settled := 0
		for _, m := range bn.Milestones {
			if m.Status.Settled() {
				settled++
			}
		}
		b.WriteString(ufmt.Sprintf("| %d | [%s](%s:%d)%s | %s | %d/%d | %s | %s |\n",
			bn.ID, sanitize.TableCell(bn.Title), realmURL, bn.ID, tagSuffix(bn), formatAmount(bn, bn.Total()),
			settled, len(bn.Milestones), bn.Status.String(), person(bn.Poster)))
	}
	return b.String()
}

func milestoneStatus(m *bounty.Milestone) string {
	switch m.Status {
	case bounty.MilestonePaid:
		return "✅ paid"
	case bounty.MilestoneSplit:
		return "⚖️ split"
	case bounty.MilestoneRefunded:
		return "↩️ refunded"
	case bounty.MilestoneDisputed:
		return "⚠️ disputed"
	case bounty.MilestoneSubmitted:
		return "🔍 in review"
	case bounty.MilestoneChangesRequested:
		return "✏️ changes requested"
	}
	return "⏳ pending"
}

func role(bn *bounty.Bounty, addr address) string {
	if rs := roles(bn, addr); len(rs) > 0 {
		return strings.Join(rs, ", ")
	}
	return "-"
}

func hasTag(bn *bounty.Bounty, tag string) bool {
	for _, t := range bn.Tags {
		if t == tag {
			return true
		}
	}
	return false
}

func tagSuffix(bn *bounty.Bounty) string {
	if len(bn.Tags) == 0 {
		return ""
	}
	return " `" + strings.Join(bn.Tags, "` `") + "`"
}

func person(addr address) string {
	if addr == "" {
		return "-"
	}
	s := addr.String()
	short := s
	if len(s) > 14 {
		short = s[:8] + "…" + s[len(s)-4:]
	}
	return "[" + short + "](" + repURL + ":u/" + s + ")"
}

func linkOrText(s string) string {
	if u := sanitize.URL(s); u != "" && (strings.HasPrefix(s, "https://") || strings.HasPrefix(s, "/")) {
		return "[" + sanitize.LinkTitle(s) + "](" + u + ")"
	}
	return sanitize.InlineText(s)
}

func formatAmount(bn *bounty.Bounty, amount int64) string {
	if bn.IsGRC20 {
		if tok := grc20reg.Get(bn.Denom); tok != nil {
			return decimal(amount, tok.GetDecimals()) + " " + sanitize.InlineText(tok.GetSymbol())
		}
		return strconv.FormatInt(amount, 10) + " " + sanitize.InlineText(bn.Denom)
	}
	if bn.Denom == "ugnot" {
		return decimal(amount, 6) + " GNOT"
	}
	return strconv.FormatInt(amount, 10) + " " + sanitize.InlineText(bn.Denom)
}

func escrowSummary() string {
	var parts []string
	escrowed.Iterate("", "", func(k string, v any) bool {
		amt := v.(int64)
		if amt <= 0 {
			return false
		}
		switch {
		case k == "ugnot":
			parts = append(parts, decimal(amt, 6)+" GNOT")
		case grc20reg.Get(k) != nil:
			tok := grc20reg.Get(k)
			parts = append(parts, decimal(amt, tok.GetDecimals())+" "+sanitize.InlineText(tok.GetSymbol()))
		default:
			parts = append(parts, strconv.FormatInt(amt, 10)+" "+sanitize.InlineText(k))
		}
		return false
	})
	if len(parts) == 0 {
		return "nothing"
	}
	return strings.Join(parts, " + ")
}

func decimal(amount int64, decimals int) string {
	if decimals <= 0 {
		return strconv.FormatInt(amount, 10)
	}
	s := strconv.FormatInt(amount, 10)
	neg := strings.HasPrefix(s, "-")
	s = strings.TrimPrefix(s, "-")
	for len(s) <= decimals {
		s = "0" + s
	}
	whole, frac := s[:len(s)-decimals], strings.TrimRight(s[len(s)-decimals:], "0")
	if neg {
		whole = "-" + whole
	}
	if frac == "" {
		return whole
	}
	return whole + "." + frac
}

func bps(v int64) string {
	return decimal(v, 2) + "%"
}

func idStr(bn *bounty.Bounty) string {
	return strconv.FormatUint(bn.ID, 10)
}

func boardLink(status, tag string, page int) string {
	l := realmURL + "?status=" + url.QueryEscape(status) + "&page=" + strconv.Itoa(page)
	if tag != "" {
		l += "&tag=" + url.QueryEscape(tag)
	}
	return l
}

func splitQuery(path string) (string, url.Values) {
	route, raw := path, ""
	if i := strings.Index(path, "?"); i >= 0 {
		route, raw = path[:i], path[i+1:]
	}
	q, _ := url.ParseQuery(raw)
	return strings.Trim(route, "/"), q
}

func pageOf(q url.Values) int {
	p, err := strconv.Atoi(q.Get("page"))
	if err != nil || p < 1 {
		return 1
	}
	return p
}

func notFound() string {
	return "# Not found\n\n[Back to the board](" + realmURL + ")\n"
}
