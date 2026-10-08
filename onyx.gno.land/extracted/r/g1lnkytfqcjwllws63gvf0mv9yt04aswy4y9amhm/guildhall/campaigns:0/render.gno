package campaigns

import (
	"chain"
	"net/url"
	"strconv"
	"strings"

	"gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/guildhall/campaign/v0"
	"gno.land/p/moul/txlink/v0"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/guildhall/reputation"
	"gno.land/r/nt/grc20reg/v0"
)

const (
	realmPath = "gno.land/r/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/guildhall/campaigns"
	realmURL  = "/r/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/guildhall/campaigns"
	repURL    = "/r/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/guildhall/reputation"
	pageSize  = 20
)

// Render serves the campaigns:
//
//	""             every campaign (?status=open|closed|all, ?tag=x, ?page=N)
//	<id>           a campaign and its claims (?claims=pending|approved|rejected|all, ?page=N)
//	u/<address>    campaigns an address posted, reviews or claimed
//	post           how to post a campaign
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
		id, err := strconv.ParseUint(strings.TrimPrefix(parts[0], "c"), 10, 64)
		if err != nil {
			return notFound()
		}
		return renderCampaign(id, query)
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
	b.WriteString("# Guildhall Campaigns\n\n")
	b.WriteString("A fixed reward for each person who does a task, up to a set number of people. A reviewer checks each claim before it pays.\n\n")
	b.WriteString(ufmt.Sprintf("**%d** open · **%d** closed · **%s** in escrow\n\n",
		statusCount[campaign.StatusOpen], statusCount[campaign.StatusClosed], escrowSummary()))
	if paused {
		b.WriteString("> Posting new campaigns is paused by the council. Existing campaigns are unaffected.\n\n")
	} else {
		b.WriteString("[+ Post a campaign](" + realmURL + ":post)\n\n")
	}

	var tabs []string
	for _, s := range []string{"open", "closed", "all"} {
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

	list, more := scan(status, tag, (page-1)*pageSize, pageSize)
	if len(list) == 0 {
		b.WriteString("_No campaigns here yet._\n")
	} else {
		b.WriteString("| # | Campaign | Reward each | Slots paid | Free | Status | Poster |\n|---:|---|---:|---:|---:|---|---|\n")
		for _, c := range list {
			b.WriteString(ufmt.Sprintf("| %d | [%s](%s:%d)%s | %s | %d/%d | %d | %s | %s |\n",
				c.ID, sanitize.TableCell(c.Title), realmURL, c.ID, tagSuffix(c), formatAmount(c, c.Reward),
				c.Paid, c.Slots, c.FreeSlots(), c.Status.String(), person(c.Poster)))
		}
	}

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

// scan lists campaigns newest first, filtered by status ("", "all" or a
// status name) and tag.
func scan(status, tag string, skip, limit int) (list []*campaign.Campaign, more bool) {
	want, filtered := campaign.ParseStatus(status)
	scanned := 0
	campaigns.ReverseIterate("", "", func(_ string, v any) bool {
		scanned++
		if scanned > apiMaxScan {
			more = true
			return true
		}
		c := v.(*campaign.Campaign)
		if filtered && c.Status != want {
			return false
		}
		if tag != "" && !hasTag(c, tag) {
			return false
		}
		if skip > 0 {
			skip--
			return false
		}
		if len(list) == limit {
			more = true
			return true
		}
		list = append(list, c)
		return false
	})
	return list, more
}

func renderCampaign(id uint64, q url.Values) string {
	c := getCampaign(id)
	if c == nil {
		return notFound()
	}
	var b strings.Builder
	b.WriteString(ufmt.Sprintf("# Campaign %d: %s\n\n", c.ID, sanitize.InlineText(c.Title)))
	b.WriteString(ufmt.Sprintf("**%s** · %s each · %d of %d slots paid · posted %s",
		strings.ToUpper(c.Status.String()), formatAmount(c, c.Reward), c.Paid, c.Slots, c.CreatedAt.UTC().Format("2006-01-02")))
	if len(c.Tags) > 0 {
		var ts []string
		for _, t := range c.Tags {
			ts = append(ts, "["+t+"]("+realmURL+"?status=all&tag="+url.QueryEscape(t)+")")
		}
		b.WriteString(" · " + strings.Join(ts, " "))
	}
	b.WriteString("\n\n")

	if c.Description != "" {
		b.WriteString(sanitize.Block(c.Description) + "\n\n")
	}
	if c.Link != "" {
		b.WriteString("Reference: " + linkOrText(c.Link) + "\n\n")
	}

	b.WriteString("| | |\n|---|---|\n")
	b.WriteString("| Posted by | " + person(c.Poster) + " |\n")
	var revs []string
	for _, r := range c.Reviewers {
		revs = append(revs, person(r))
	}
	b.WriteString("| Reviewers (any one approves) | " + strings.Join(revs, ", ") + " |\n")
	b.WriteString(ufmt.Sprintf("| Slots | %d paid · %d awaiting review · %d free · %d refunded |\n", c.Paid, c.Pending, c.FreeSlots(), c.Refunded))
	if !c.Deadline.IsZero() {
		b.WriteString("| Claims close | " + c.Deadline.UTC().Format("2006-01-02 15:04 UTC") + " |\n")
	}
	b.WriteString("| Escrow | " + formatAmount(c, c.Escrowed()) + " held · " + formatAmount(c, c.PaidOut()) + " paid |\n")
	b.WriteString(ufmt.Sprintf("| Reputation | each paid claim is a record at %s weight |\n\n", bps(ClaimShareBps)))

	b.WriteString(renderActions(c))

	filter := q.Get("claims")
	if filter == "" {
		filter = "all"
	}
	page := pageOf(q)
	var tabs []string
	for _, s := range []string{"pending", "approved", "rejected", "all"} {
		label := s
		if s == filter {
			label = "**" + s + "**"
		}
		tabs = append(tabs, "["+label+"]("+realmURL+":"+idStr(c)+"?claims="+s+")")
	}
	b.WriteString(ufmt.Sprintf("## Claims (%d)\n\n", c.ClaimCount()))
	b.WriteString(strings.Join(tabs, " · ") + "\n\n")

	var st *campaign.ClaimStatus
	if s, ok := campaign.ParseClaimStatus(filter); ok {
		st = &s
	}
	list, more := c.Claims(st, (page-1)*pageSize, pageSize)
	if len(list) == 0 {
		b.WriteString("_No claims here yet._\n")
		return b.String()
	}
	b.WriteString("| # | Claimant | Proof | Status | |\n|---:|---|---|---|---|\n")
	for _, cl := range list {
		status := claimStatus(cl)
		action := ""
		if cl.Status == campaign.ClaimPending {
			n := strconv.Itoa(cl.Number)
			action = "[approve](" + txlink.NewLink("ApproveClaim").AddArgs("id", idStr(c), "claim", n).URL() + ") · " +
				"[reject](" + txlink.NewLink("RejectClaim").AddArgs("id", idStr(c), "claim", n, "reason", "").URL() + ")"
		} else if cl.Status == campaign.ClaimRejected && cl.Reason != "" {
			action = sanitize.TableCell(cl.Reason)
		}
		b.WriteString(ufmt.Sprintf("| %d | %s | %s | %s | %s |\n", cl.Number, person(cl.Claimant), linkOrText(cl.Proof), status, action))
	}
	if page > 1 || more {
		var nav []string
		if page > 1 {
			nav = append(nav, ufmt.Sprintf("[← newer](%s:%s?claims=%s&page=%d)", realmURL, idStr(c), filter, page-1))
		}
		if more {
			nav = append(nav, ufmt.Sprintf("[older →](%s:%s?claims=%s&page=%d)", realmURL, idStr(c), filter, page+1))
		}
		b.WriteString("\n" + strings.Join(nav, " · ") + "\n")
	}
	return b.String()
}

// renderActions lists the transactions anyone might want to send, as gnoweb
// transaction links. The chain enforces who may call them.
func renderActions(c *campaign.Campaign) string {
	if c.Status != campaign.StatusOpen {
		return ""
	}
	var acts []string
	if c.FreeSlots() > 0 {
		acts = append(acts, "[Claim a slot]("+txlink.NewLink("Claim").AddArgs("id", idStr(c), "proof", "").URL()+")")
	}
	acts = append(acts, "[Close and refund free slots (poster)]("+txlink.NewLink("Close").AddArgs("id", idStr(c)).URL()+")")
	return "## Actions\n\n" + strings.Join(acts, " · ") + "\n\n"
}

func renderUser(addr address, page int) string {
	if !addr.IsValid() {
		return notFound()
	}
	var b strings.Builder
	b.WriteString("# Campaigns for " + addr.String() + "\n\n")
	b.WriteString(ufmt.Sprintf("Reputation: **%d** (%s) · [profile](%s:u/%s)\n\n",
		reputation.Score(addr), reputation.Level(addr), repURL, addr.String()))
	v := byUser.Get(addr.String())
	if v == nil {
		b.WriteString("_Not involved in any campaign yet._\n")
		return b.String()
	}
	ids := v.(*avl.Tree)
	b.WriteString("| # | Campaign | Role | Reward each | Their claim | Status |\n|---:|---|---|---:|---|---|\n")
	ids.ReverseIterateByOffset((page-1)*pageSize, pageSize, func(k string, _ any) bool {
		cv := campaigns.Get(k)
		if cv == nil {
			return false
		}
		c := cv.(*campaign.Campaign)
		mine := "-"
		if cl := c.ClaimOf(addr); cl != nil {
			mine = ufmt.Sprintf("#%d %s", cl.Number, cl.Status.String())
		}
		b.WriteString(ufmt.Sprintf("| %d | [%s](%s:%d) | %s | %s | %s | %s |\n",
			c.ID, sanitize.TableCell(c.Title), realmURL, c.ID, strings.Join(roles(c, addr), ", "), formatAmount(c, c.Reward), mine, c.Status.String()))
		return false
	})
	if ids.Size() > page*pageSize {
		b.WriteString(ufmt.Sprintf("\n[older →](%s:u/%s?page=%d)\n", realmURL, addr.String(), page+1))
	}
	return b.String()
}

func renderPost() string {
	native := txlink.NewLink("PostCampaign").
		AddArgs("title", "", "description", "", "link", "", "tags", "", "reviewers", "", "reward", "10000000", "slots", "100", "deadlineDays", "30").
		SetSend("1000000000ugnot").URL()
	grc := txlink.NewLink("PostCampaignGRC20").
		AddArgs("tokenKey", "", "title", "", "reward", "", "slots", "", "deadlineDays", "30").URL()

	var b strings.Builder
	b.WriteString("# Post a campaign\n\n")
	b.WriteString("## With GNOT\n\n")
	b.WriteString("[Open the form](" + native + ") and send exactly **reward × slots**.\n\n")
	b.WriteString("- **reward**: what each approved claim pays, in the smallest unit (`ugnot`; 10 GNOT is `10000000`).\n")
	b.WriteString("- **slots**: how many claims can be paid, up to " + strconv.Itoa(campaign.MaxSlots) + ".\n")
	b.WriteString("- **reviewers**: comma-separated addresses; any one of them can approve a claim. Leave empty to review claims yourself.\n")
	b.WriteString("- **deadlineDays**: stop taking claims after this many days (0 for none). After it, anyone can close the campaign, which refunds the free slots to you.\n\n")
	b.WriteString("```sh\ngnokey maketx call -pkgpath " + realmPath + " -func PostCampaign \\\n")
	b.WriteString("  -args \"Write about Guildhall\" -args \"Post about Guildhall on X with a link to it.\" \\\n")
	b.WriteString("  -args \"https://guildhall.clockwork.gr\" -args \"social\" -args \"\" \\\n")
	b.WriteString("  -args 10000000 -args 100 -args 30 \\\n")
	b.WriteString("  -send 1000000000ugnot -gas-fee 1000000ugnot -gas-wanted 20000000 -broadcast KEY\n```\n\n")
	b.WriteString("## With a GRC20 token\n\n")
	b.WriteString("1. Approve `" + chain.PackageAddress(realmPath).String() + "` on the token for reward × slots.\n")
	b.WriteString("2. Call [PostCampaignGRC20](" + grc + ") with the token's [grc20reg](/r/nt/grc20reg/v0) key.\n")
	return b.String()
}

func claimStatus(cl *campaign.Claim) string {
	switch cl.Status {
	case campaign.ClaimApproved:
		return "✅ paid"
	case campaign.ClaimRejected:
		return "✖️ rejected"
	}
	return "🔍 in review"
}

func roles(c *campaign.Campaign, addr address) []string {
	var out []string
	if c.Poster == addr {
		out = append(out, "poster")
	}
	if c.IsReviewer(addr) {
		out = append(out, "reviewer")
	}
	if c.ClaimOf(addr) != nil {
		out = append(out, "claimant")
	}
	return out
}

func hasTag(c *campaign.Campaign, tag string) bool {
	for _, t := range c.Tags {
		if t == tag {
			return true
		}
	}
	return false
}

func tagSuffix(c *campaign.Campaign) string {
	if len(c.Tags) == 0 {
		return ""
	}
	return " `" + strings.Join(c.Tags, "` `") + "`"
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

func formatAmount(c *campaign.Campaign, amount int64) string {
	symbol, decimals := symbolOf(c.Denom, c.IsGRC20)
	return decimal(amount, decimals) + " " + sanitize.InlineText(symbol)
}

func symbolOf(denom string, isGRC20 bool) (string, int) {
	switch {
	case isGRC20:
		if tok := grc20reg.Get(denom); tok != nil {
			return tok.GetSymbol(), tok.GetDecimals()
		}
	case denom == "ugnot":
		return "GNOT", 6
	}
	return denom, 0
}

func escrowSummary() string {
	var parts []string
	escrowed.Iterate("", "", func(k string, v any) bool {
		if amt := v.(int64); amt > 0 {
			symbol, decimals := symbolOf(k, grc20reg.Get(k) != nil)
			parts = append(parts, decimal(amt, decimals)+" "+sanitize.InlineText(symbol))
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

func idStr(c *campaign.Campaign) string {
	return strconv.FormatUint(c.ID, 10)
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
	return "# Not found\n\n[Back to campaigns](" + realmURL + ")\n"
}
