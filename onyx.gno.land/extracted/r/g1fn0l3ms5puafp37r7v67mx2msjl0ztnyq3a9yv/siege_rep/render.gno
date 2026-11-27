package siege_rep

import (
	"sort"
	"strconv"
	"strings"

	"gno.land/p/g1fn0l3ms5puafp37r7v67mx2msjl0ztnyq3a9yv/bs_core"
)

func Render(path string) string {
	route, query := splitPathQuery(path)

	switch {
	case route == "json/leaderboard":
		page, limit := parsePageLimit(query)
		return renderLeaderboardJSON(page, limit)
	case route == "json/guilds":
		page, limit := parsePageLimit(query)
		return renderGuildsJSON(page, limit)
	case strings.HasPrefix(route, "json/profile/"):
		addrStr := strings.TrimPrefix(route, "json/profile/")
		return renderProfileJSON(address(addrStr))
	default:
		return renderMarkdownHome()
	}
}

func renderMarkdownHome() string {
	var sb strings.Builder
	sb.WriteString("# BountySiege — Composable Reputation & Guild Registry (`siege_rep`)\n\n")
	sb.WriteString("- Authorized Core Realm: `" + bs_core.EscapeMarkdown(authorizedCorePkgPath) + "`\n")
	sb.WriteString("- Registered Guilds: `" + strconv.Itoa(len(guildOwnerList)) + "`\n")
	sb.WriteString("- Indexed Builders: `" + strconv.Itoa(len(builderAddrList)) + "`\n\n")

	sb.WriteString("## Top Builders\n\n")
	sorted := sortedBuilders()
	if len(sorted) == 0 {
		sb.WriteString("_No builder reputation recorded yet._\n\n")
	} else {
		max := len(sorted)
		if max > 10 {
			max = 10
		}
		for i := 0; i < max; i++ {
			b := sorted[i]
			sb.WriteString(strconv.Itoa(i+1) + ". `" + b.Addr.String() + "` — **" +
				strconv.FormatInt(b.TotalXP, 10) + " XP** | Completed: `" +
				strconv.FormatInt(b.CompletedCount, 10) + "` | Unique Sponsors: `" +
				strconv.FormatInt(b.UniqueSponsorsCount, 10) + "` | Earned: `" +
				strconv.FormatInt(b.TotalEarnedUgnot, 10) + " ugnot`\n")
		}
		sb.WriteString("\n")
	}

	sb.WriteString("## Registered Guilds\n\n")
	if len(guildOwnerList) == 0 {
		sb.WriteString("_No guilds registered yet._\n")
	} else {
		max := len(guildOwnerList)
		if max > 10 {
			max = 10
		}
		for i := 0; i < max; i++ {
			g := guildsByOwner[guildOwnerList[i]]
			sp := sponsorsByAddr[g.Owner]
			var paid int64
			if sp != nil {
				paid = sp.TotalPaidUgnot
			}
			sb.WriteString("- **" + bs_core.EscapeMarkdown(g.Name) + "** (`" + g.Owner.String() +
				"`) — Paid Out: `" + strconv.FormatInt(paid, 10) + " ugnot`\n")
		}
	}
	return sb.String()
}

func renderLeaderboardJSON(page, limit int) string {
	sorted := sortedBuilders()
	total := len(sorted)
	start := (page - 1) * limit
	if start > total {
		start = total
	}
	end := start + limit
	if end > total {
		end = total
	}

	var sb strings.Builder
	sb.WriteString(`{"page":` + strconv.Itoa(page) +
		`,"limit":` + strconv.Itoa(limit) +
		`,"total":` + strconv.Itoa(total) + `,"items":[`)
	for i := start; i < end; i++ {
		if i > start {
			sb.WriteString(",")
		}
		sb.WriteString(builderToJSON(sorted[i]))
	}
	sb.WriteString("]}")
	return sb.String()
}

func renderGuildsJSON(page, limit int) string {
	total := len(guildOwnerList)
	start := (page - 1) * limit
	if start > total {
		start = total
	}
	end := start + limit
	if end > total {
		end = total
	}

	var sb strings.Builder
	sb.WriteString(`{"page":` + strconv.Itoa(page) +
		`,"limit":` + strconv.Itoa(limit) +
		`,"total":` + strconv.Itoa(total) + `,"items":[`)
	for i := start; i < end; i++ {
		if i > start {
			sb.WriteString(",")
		}
		g := guildsByOwner[guildOwnerList[i]]
		sb.WriteString(guildToJSON(g, sponsorsByAddr[g.Owner]))
	}
	sb.WriteString("]}")
	return sb.String()
}

func renderProfileJSON(addr address) string {
	bp := buildersByAddr[addr]
	sp := sponsorsByAddr[addr]
	g := guildsByOwner[addr]

	var sb strings.Builder
	sb.WriteString(`{"address":"` + bs_core.EscapeJSON(addr.String()) + `","builder":`)
	if bp == nil {
		sb.WriteString(builderToJSON(&BuilderProfile{Addr: addr}))
	} else {
		sb.WriteString(builderToJSON(bp))
	}
	sb.WriteString(`,"sponsor":`)
	if sp == nil {
		sb.WriteString(sponsorToJSON(&SponsorStats{Addr: addr}))
	} else {
		sb.WriteString(sponsorToJSON(sp))
	}
	sb.WriteString(`,"guild":`)
	if g == nil {
		sb.WriteString("null")
	} else {
		sb.WriteString(guildToJSON(g, sp))
	}
	sb.WriteString("}")
	return sb.String()
}

func builderToJSON(b *BuilderProfile) string {
	var sb strings.Builder
	sb.WriteString(`{"address":"` + bs_core.EscapeJSON(b.Addr.String()) +
		`","totalXp":` + strconv.FormatInt(b.TotalXP, 10) +
		`,"completedCount":` + strconv.FormatInt(b.CompletedCount, 10) +
		`,"qualifiedCompletedCount":` + strconv.FormatInt(b.QualifiedCompletedCount, 10) +
		`,"totalEarnedUgnot":` + strconv.FormatInt(b.TotalEarnedUgnot, 10) +
		`,"uniqueSponsorsCount":` + strconv.FormatInt(b.UniqueSponsorsCount, 10) +
		`,"noShowCount":` + strconv.FormatInt(b.NoShowCount, 10) +
		`,"rejectedCount":` + strconv.FormatInt(b.RejectedCount, 10) +
		`,"lostDisputeCount":` + strconv.FormatInt(b.LostDisputeCount, 10) +
		`,"revisionExpiredCount":` + strconv.FormatInt(b.RevisionExpiredCount, 10) +
		`,"xpByCategory":{`)
	for c := bs_core.Category(0); c < bs_core.CatCount; c++ {
		if c > 0 {
			sb.WriteString(",")
		}
		sb.WriteString(`"` + c.String() + `":` + strconv.FormatInt(b.XPByCategory[c], 10))
	}
	sb.WriteString(`},"badges":[`)
	for i, bg := range b.Badges {
		if i > 0 {
			sb.WriteString(",")
		}
		sb.WriteString(`"` + bs_core.EscapeJSON(bg) + `"`)
	}
	sb.WriteString("]}")
	return sb.String()
}

func sponsorToJSON(s *SponsorStats) string {
	var avgReview int64
	if s.ReviewedCount > 0 {
		avgReview = s.TotalReviewSeconds / s.ReviewedCount
	}
	return `{"address":"` + bs_core.EscapeJSON(s.Addr.String()) +
		`","totalPaidUgnot":` + strconv.FormatInt(s.TotalPaidUgnot, 10) +
		`,"completedCount":` + strconv.FormatInt(s.CompletedCount, 10) +
		`,"reviewedCount":` + strconv.FormatInt(s.ReviewedCount, 10) +
		`,"avgReviewSeconds":` + strconv.FormatInt(avgReview, 10) +
		`,"cancelledAfterSubmitCount":` + strconv.FormatInt(s.CancelledAfterSubmitCount, 10) +
		`,"timeoutCount":` + strconv.FormatInt(s.TimeoutCount, 10) +
		`,"lateJudgingCount":` + strconv.FormatInt(s.LateJudgingCount, 10) +
		`,"lostDisputeCount":` + strconv.FormatInt(s.LostDisputeCount, 10) +
		`,"uniqueBuildersCount":` + strconv.FormatInt(s.UniqueBuildersCount, 10) + `}`
}

func guildToJSON(g *Guild, sp *SponsorStats) string {
	if sp == nil {
		sp = &SponsorStats{Addr: g.Owner}
	}
	return `{"owner":"` + bs_core.EscapeJSON(g.Owner.String()) +
		`","name":"` + bs_core.EscapeJSON(g.Name) +
		`","bio":"` + bs_core.EscapeJSON(g.CurrentBio()) +
		`","website":"` + bs_core.EscapeJSON(g.CurrentWebsite()) +
		`","createdAt":` + strconv.FormatInt(g.CreatedAt, 10) +
		`,"updatesCount":` + strconv.Itoa(len(g.History)) +
		`,"stats":` + sponsorToJSON(sp) + `}`
}

type builderSorter []*BuilderProfile

func (s builderSorter) Len() int { return len(s) }
func (s builderSorter) Swap(i, j int) { s[i], s[j] = s[j], s[i] }
func (s builderSorter) Less(i, j int) bool {
	if s[i].TotalXP != s[j].TotalXP {
		return s[i].TotalXP > s[j].TotalXP
	}
	if s[i].UniqueSponsorsCount != s[j].UniqueSponsorsCount {
		return s[i].UniqueSponsorsCount > s[j].UniqueSponsorsCount
	}
	if s[i].CompletedCount != s[j].CompletedCount {
		return s[i].CompletedCount > s[j].CompletedCount
	}
	return s[i].Addr < s[j].Addr
}

func sortedBuilders() []*BuilderProfile {
	list := make([]*BuilderProfile, 0, len(builderAddrList))
	for _, a := range builderAddrList {
		list = append(list, buildersByAddr[a])
	}
	sort.Sort(builderSorter(list))
	return list
}

func splitPathQuery(p string) (string, string) {
	idx := strings.Index(p, "?")
	if idx == -1 {
		return p, ""
	}
	return p[:idx], p[idx+1:]
}

func parsePageLimit(query string) (int, int) {
	page := 1
	limit := bs_core.DefaultPageLimit
	if query == "" {
		return bs_core.ClampPageLimit(page, limit)
	}
	parts := strings.Split(query, "&")
	for _, kv := range parts {
		eq := strings.Index(kv, "=")
		if eq <= 0 {
			continue
		}
		k := kv[:eq]
		v := kv[eq+1:]
		if k == "page" {
			if n, err := strconv.Atoi(v); err == nil {
				page = n
			}
		} else if k == "limit" {
			if n, err := strconv.Atoi(v); err == nil {
				limit = n
			}
		}
	}
	return bs_core.ClampPageLimit(page, limit)
}
