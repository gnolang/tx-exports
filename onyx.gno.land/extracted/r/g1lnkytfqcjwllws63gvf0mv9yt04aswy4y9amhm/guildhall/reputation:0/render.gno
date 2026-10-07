package reputation

import (
	"net/url"
	"strconv"
	"strings"

	"gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/guildhall/trust/v0"
	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/p/nt/ufmt/v0"
)

const (
	realmURL  = "/r/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/guildhall/reputation"
	pageSize  = 20
	boardSize = 25
)

// Render serves the reputation pages:
//
//	""            leaderboard and latest records
//	u/<address>   contributor profile
//	record/<id>   a single record
//	records       every record, newest first (?page=N)
//	seeds         seed reviewers
//	about         scoring rules
func Render(path string) string {
	route, query := splitQuery(path)
	parts := strings.Split(route, "/")
	switch {
	case parts[0] == "api":
		return renderAPI(route, query)
	case route == "":
		return renderHome()
	case len(parts) == 2 && parts[0] == "u":
		return renderProfile(address(parts[1]))
	case len(parts) == 2 && parts[0] == "record":
		id, err := strconv.ParseUint(parts[1], 10, 64)
		if err != nil {
			return notFound()
		}
		return renderRecord(id)
	case route == "records":
		return renderRecords(pageOf(query))
	case route == "seeds":
		return renderSeeds()
	case route == "about":
		return renderAbout()
	}
	return notFound()
}

func renderHome() string {
	var b strings.Builder
	b.WriteString("# Guildhall Reputation\n\n")
	b.WriteString("Reputation earned from paid, reviewed work. Every point traces back to a record, and every record to the people who vouched for it.\n\n")
	b.WriteString(ufmt.Sprintf("**%d** records · **%d** ranked contributors · **%d** seed reviewers · [scoring rules](%s:about) · [all records](%s:records)\n\n",
		records.Size(), leaderboard.Size(), seeds.Size(), realmURL, realmURL))

	b.WriteString("## Leaderboard\n\n")
	top := Top(boardSize)
	if len(top) == 0 {
		b.WriteString("_No reputation has been earned yet. Complete a [bounty](/r/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/guildhall/bounties) to be the first._\n\n")
	} else {
		b.WriteString("| # | Contributor | Score | Level | Work | Reviews |\n|---:|---|---:|---|---:|---:|\n")
		for i, s := range top {
			b.WriteString(ufmt.Sprintf("| %d | %s | %d | %s | %d | %d |\n",
				i+1, userLink(s.Addr), s.Score, trust.Level(s.Score), CompletedCount(s.Addr), ReviewCount(s.Addr)))
		}
		b.WriteString("\n")
	}

	b.WriteString("## Latest records\n\n")
	b.WriteString(recordTable(latest(0, 10)))
	b.WriteString("\n## Use it in your realm\n\n")
	b.WriteString("```go\nimport \"gno.land/r/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/guildhall/reputation\"\n\nreputation.AssertScore(cur.Previous().Address(), 300)\n```\n")
	return b.String()
}

func renderProfile(addr address) string {
	if !addr.IsValid() {
		return notFound()
	}
	var b strings.Builder
	b.WriteString(ufmt.Sprintf("# %s\n\n", addr.String()))
	p := getProfile(addr)
	if p == nil {
		b.WriteString("_No recorded work or reviews yet._\n\n")
		b.WriteString(ufmt.Sprintf("[Browse open bounties](/r/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/guildhall/bounties?status=open) · [Leaderboard](%s)\n", realmURL))
		return b.String()
	}

	rank := "unranked"
	if r := Rank(addr); r > 0 {
		rank = "#" + strconv.Itoa(r)
	}
	seed := ""
	if IsSeed(addr) {
		seed = " · seed reviewer"
	}
	b.WriteString(ufmt.Sprintf("**%d** points · %s · %s%s\n\n", p.Score, trust.Level(p.Score), rank, seed))
	b.WriteString(ufmt.Sprintf("- Completed work: **%d**\n- Reviews given: **%d**\n", len(p.Records), len(p.Reviews)))
	if p.earned != nil && p.earned.Size() > 0 {
		var parts []string
		p.earned.Iterate("", "", func(k string, v any) bool {
			parts = append(parts, formatAmount(v.(int64), k))
			return false
		})
		b.WriteString("- Earned: " + strings.Join(parts, ", ") + "\n")
	}
	if !p.First.IsZero() {
		b.WriteString("- Active since: " + p.First.Format("2006-01-02") + "\n")
	}
	b.WriteString(ufmt.Sprintf("- Bounties: [%s](/r/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/guildhall/bounties:u/%s)\n\n", "view", addr.String()))

	b.WriteString("## Work\n\n")
	b.WriteString(recordTable(RecordsOf(addr, 0, pageSize)))
	b.WriteString("\n## Reviews\n\n")
	b.WriteString(recordTable(ReviewsOf(addr, 0, pageSize)))
	return b.String()
}

func renderRecord(id uint64) string {
	r := getRecord(id)
	if r == nil {
		return notFound()
	}
	var b strings.Builder
	b.WriteString(ufmt.Sprintf("# Record #%d\n\n", r.ID))
	if r.Voided {
		b.WriteString("> **Voided:** " + sanitize.InlineText(r.VoidReason) + "\n\n")
	}
	b.WriteString("**" + sanitize.InlineText(r.Title) + "**\n\n")
	b.WriteString("| | |\n|---|---|\n")
	b.WriteString("| Worker | " + userLink(r.Worker) + " |\n")
	b.WriteString("| Funded by | " + userLink(r.Poster) + " |\n")
	b.WriteString("| Paid | " + formatAmount(r.Amount, r.Denom) + " |\n")
	if r.ShareBps < trust.MaxBps {
		b.WriteString(ufmt.Sprintf("| Share of milestone | %s |\n", bpsPercent(r.ShareBps)))
	}
	b.WriteString(ufmt.Sprintf("| Points | %d |\n", r.Points))
	if r.Link != "" {
		b.WriteString("| Work | " + linkOrText(r.Link) + " |\n")
	}
	b.WriteString("| Source | " + sourceLink(r) + " |\n")
	b.WriteString("| Released by | " + userLink(r.SignedBy) + " |\n")
	b.WriteString(ufmt.Sprintf("| Block | %d · %s |\n", r.Height, r.At.UTC().Format("2006-01-02 15:04 UTC")))
	if r.Arbitrated {
		b.WriteString("| Settled by | arbitration |\n")
	}

	b.WriteString("\n## Vouched for by\n\n| Reviewer | Trust at approval |\n|---|---:|\n")
	for i, rv := range r.Reviewers {
		t := int64(0)
		if i < len(r.ReviewerTrust) {
			t = r.ReviewerTrust[i]
		}
		b.WriteString("| " + userLink(rv) + " | " + bpsPercent(t) + " |\n")
	}
	return b.String()
}

func renderRecords(page int) string {
	var b strings.Builder
	b.WriteString("# All records\n\n")
	b.WriteString(recordTable(latest((page-1)*pageSize, pageSize)))
	b.WriteString("\n" + pager("records", page, records.Size()))
	return b.String()
}

func renderSeeds() string {
	var b strings.Builder
	b.WriteString("# Seed reviewers\n\n")
	b.WriteString("Seeds carry full trust when they approve work. Everyone else earns trust by completing work that trusted people approved. ")
	b.WriteString(ufmt.Sprintf("Seeds are curated by %s.\n\n", userLink(Admin())))
	if seeds.Size() == 0 {
		b.WriteString("_No seeds yet._\n")
		return b.String()
	}
	seeds.Iterate("", "", func(k string, _ any) bool {
		b.WriteString("- " + userLink(address(k)) + "\n")
		return false
	})
	return b.String()
}

func renderAbout() string {
	p := params
	var b strings.Builder
	b.WriteString("# How reputation is scored\n\n")
	b.WriteString("1. Reputation is only created when escrowed funds are released for finished work. Writing records is restricted to allowlisted realms:\n")
	writers.Iterate("", "", func(k string, _ any) bool {
		b.WriteString("   - [" + k + "](" + strings.TrimPrefix(k, "gno.land") + ")\n")
		return false
	})
	b.WriteString(ufmt.Sprintf("2. A record is worth up to **%d** points, scaled by the average trust of the reviewers who approved it.\n", p.Base))
	b.WriteString(ufmt.Sprintf("3. Seed reviewers carry full trust. Anyone else carries trust in proportion to their own score, reaching full trust at **%d** points.\n", p.TrustThreshold))
	b.WriteString(ufmt.Sprintf("4. Reviewers with no score carry **%s** trust, so a ring of fresh accounts approving each other earns nothing.\n", bpsPercent(p.TrustFloorBps)))
	b.WriteString(ufmt.Sprintf("5. Work funded by the worker themselves is scaled to **%s**. Nobody can vouch for their own work.\n", bpsPercent(p.SelfFundedFactorBps)))
	b.WriteString("6. When a dispute ends in a split, the record's points scale with the share the arbiter awarded.\n")
	b.WriteString("7. Points are fixed when the record is written. The Guildhall admin may void a fraudulent record, which removes its points.\n\n")
	b.WriteString("## Levels\n\n| Score | Level |\n|---:|---|\n| 0 | Newcomer |\n| 1+ | Apprentice |\n| 300+ | Journeyman |\n| 800+ | Artisan |\n| 2000+ | Master |\n| 5000+ | Grandmaster |\n")
	return b.String()
}

func recordTable(rs []Record) string {
	if len(rs) == 0 {
		return "_Nothing here yet._\n"
	}
	var b strings.Builder
	b.WriteString("| # | Work | Worker | Paid | Points |\n|---:|---|---|---:|---:|\n")
	for _, r := range rs {
		title := sanitize.TableCell(r.Title)
		if r.Voided {
			title = "~~" + title + "~~"
		}
		b.WriteString(ufmt.Sprintf("| [%d](%s:record/%d) | %s | %s | %s | %d |\n",
			r.ID, realmURL, r.ID, title, userLink(r.Worker), formatAmount(r.Amount, r.Denom), r.Points))
	}
	return b.String()
}

func latest(offset, limit int) []Record {
	var out []Record
	records.ReverseIterateByOffset(offset, limit, func(_ string, v any) bool {
		out = append(out, copyRecord(v.(*Record)))
		return false
	})
	return out
}

func userLink(addr address) string {
	if addr == "" {
		return "-"
	}
	s := addr.String()
	short := s
	if len(s) > 14 {
		short = s[:8] + "…" + s[len(s)-4:]
	}
	return "[" + short + "](" + realmURL + ":u/" + s + ")"
}

func sourceLink(r *Record) string {
	path := strings.TrimPrefix(r.Source, "gno.land")
	if r.Source == BountiesPath && r.Ref != "" {
		id := r.Ref
		if i := strings.Index(id, "/"); i >= 0 {
			id = id[:i]
		}
		return "[bounty " + sanitize.InlineText(r.Ref) + "](" + path + ":" + url.PathEscape(id) + ")"
	}
	return "[" + r.Source + "](" + path + ")"
}

func linkOrText(s string) string {
	if u := sanitize.URL(s); u != "" && (strings.HasPrefix(s, "https://") || strings.HasPrefix(s, "/")) {
		return "[" + sanitize.LinkTitle(s) + "](" + u + ")"
	}
	return sanitize.InlineText(s)
}

func formatAmount(amount int64, denom string) string {
	if denom == "ugnot" {
		return decimal(amount, 6) + " GNOT"
	}
	return strconv.FormatInt(amount, 10) + " " + sanitize.InlineText(denom)
}

func decimal(amount int64, decimals int) string {
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

func bpsPercent(bps int64) string {
	return decimal(bps, 2) + "%"
}

func pager(route string, page, total int) string {
	pages := (total + pageSize - 1) / pageSize
	if pages <= 1 {
		return ""
	}
	var parts []string
	if page > 1 {
		parts = append(parts, ufmt.Sprintf("[← newer](%s:%s?page=%d)", realmURL, route, page-1))
	}
	parts = append(parts, ufmt.Sprintf("page %d of %d", page, pages))
	if page < pages {
		parts = append(parts, ufmt.Sprintf("[older →](%s:%s?page=%d)", realmURL, route, page+1))
	}
	return strings.Join(parts, " · ") + "\n"
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
	return "# Not found\n\n[Back to the leaderboard](" + realmURL + ")\n"
}
