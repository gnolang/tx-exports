package barkeep

import (
	"strconv"
	"strings"

	"gno.land/p/g1dmwvymew9ku97tp30xka70w4tnn8cydh2tct9p/renown/v0"
	"gno.land/p/nt/markdown/sanitize/v0"
)

const renderPageSize = 20

// Render serves gnoweb pages: "" (leaderboard), "u/<addr>", "sources",
// "algorithm" and "integrate". Lists accept "?page=N". The path is
// attacker-controlled: it is parsed, never echoed raw.
func Render(path string) string {
	route, query, _ := strings.Cut(path, "?")
	pg := pageParam(query)
	switch {
	case route == "":
		return renderHome(pg)
	case strings.HasPrefix(route, "u/"):
		return renderProfile(strings.TrimPrefix(route, "u/"))
	case route == "sources":
		return renderSources(pg)
	case route == "algorithm":
		return renderAlgorithm()
	case route == "integrate":
		return renderIntegrate()
	}
	return "# Not found\n\n[Back to the bar](/r/g1dmwvymew9ku97tp30xka70w4tnn8cydh2tct9p/barkeep/v0)\n"
}

func pageParam(query string) int {
	for _, kv := range strings.Split(query, "&") {
		if v, ok := strings.CutPrefix(kv, "page="); ok {
			if n, err := strconv.Atoi(v); err == nil && n > 0 && n < 1_000_000 {
				return n
			}
		}
	}
	return 1
}

func cell(s string) string { return sanitize.TableCell(s) }

func nav() string {
	return "[Leaderboard](:) · [Sources](:sources) · [Algorithm](:algorithm) · [Integrate](:integrate)\n\n"
}

func pager(route string, pg, total int) string {
	pages := (total + renderPageSize - 1) / renderPageSize
	if pages <= 1 {
		return ""
	}
	out := "\nPage " + itoa(int64(pg)) + " of " + itoa(int64(pages))
	if pg > 1 {
		out += " · [Prev](:" + route + "?page=" + itoa(int64(pg-1)) + ")"
	}
	if pg < pages {
		out += " · [Next](:" + route + "?page=" + itoa(int64(pg+1)) + ")"
	}
	return out + "\n"
}

func renderHome(pg int) string {
	t := now()
	rows := leaderboard(t)
	var b strings.Builder
	b.WriteString("# Barkeep\n\n> The barkeep knows everyone's reputation.\n\n")
	b.WriteString(nav())
	b.WriteString("Profiles: " + itoa(int64(profiles.Size())) +
		" · Attestations: " + itoa(attestations) +
		" · Sources: " + itoa(int64(sourcesByID.Size())) + " (" + itoa(int64(verifiedCount)) + " verified)")
	if pausedAll {
		b.WriteString(" · **Paused**")
	}
	b.WriteString("\n\n## Leaderboard\n\n")
	if len(rows) == 0 {
		b.WriteString("Nobody has earned renown yet.\n")
		return b.String()
	}
	b.WriteString("| # | Address | Score | Tier |\n|---|---|---|---|\n")
	start, end := page(len(rows), (pg-1)*renderPageSize, renderPageSize)
	for i := start; i < end; i++ {
		a := rows[i].addr.String()
		score := renown.ToPoints(rows[i].score)
		b.WriteString("| " + itoa(int64(i+1)) + " | [" + a + "](:u/" + a + ") | " +
			itoa(score) + " | " + renown.TierOf(score) + " |\n")
	}
	b.WriteString(pager("", pg, len(rows)))
	return b.String()
}

func renderProfile(raw string) string {
	addr := address(raw)
	if !addr.IsValid() {
		return "# Unknown patron\n\nThat is not a valid address.\n\n" + nav()
	}
	t := now()
	p := profileOf(addr)
	r := computeScore(addr, p, t)
	score := renown.ToPoints(r.total)
	a := addr.String()
	var b strings.Builder
	b.WriteString("# Patron " + a + "\n\n" + nav())
	b.WriteString("**Score " + itoa(score) + "** · " + renown.TierOf(score) + "\n\n")
	b.WriteString("Base " + milliStr(r.base) + " × identity " + milliStr(r.identity) +
		" × maturity " + milliStr(r.maturity) + " × diversity " + milliStr(r.diversity) +
		" (" + itoa(int64(r.active)) + " categories)\n\n")
	if p == nil {
		b.WriteString("No attestations yet.\n")
		return b.String()
	}
	b.WriteString("## By source\n\n| Source | Category | Tier | Points | Weighted |\n|---|---|---|---|---|\n")
	for _, bk := range p.buckets {
		s := sourceByID(bk.src)
		if s == nil {
			continue
		}
		v := bk.value(s, t)
		b.WriteString("| " + cell(s.path) + " | " + s.category + " | " + s.tier + " | " +
			milliStr(v) + " | " + milliStr(renown.Weighted(v, s.effectiveWeight())) + " |\n")
	}
	b.WriteString("\n## Recent\n\n| Time (unix) | Source | Kind | Units |\n|---|---|---|---|\n")
	for i := len(p.recent) - 1; i >= 0; i-- {
		e := p.recent[i]
		b.WriteString("| " + itoa(e.ts) + " | " + cell(sourcePath(e.src)) + " | " + cell(e.kind) + " | " + itoa(e.units) + " |\n")
	}
	return b.String()
}

func renderSources(pg int) string {
	var b strings.Builder
	b.WriteString("# Sources\n\n" + nav())
	b.WriteString("Any realm may register; only **verified** sources count toward scores.\n\n")
	n := sourcesByID.Size()
	if n == 0 {
		b.WriteString("No sources yet.\n")
	} else {
		b.WriteString("| # | Realm | Category | Tier | Weight | Cap | Attestations | Description |\n|---|---|---|---|---|---|---|---|\n")
		start, end := page(n, (pg-1)*renderPageSize, renderPageSize)
		sourcesByID.IterateByOffset(start, end-start, func(_ string, v any) bool {
			s := v.(*source)
			tier := s.tier
			if s.paused {
				tier += " (paused)"
			}
			b.WriteString("| " + itoa(int64(s.id)) + " | " + cell(s.path) + " | " + s.category + " | " + tier + " | " +
				milliStr(s.effectiveWeight()) + " | " + itoa(renown.ToPoints(s.capacity)) + " | " +
				itoa(s.attestations) + " | " + cell(s.desc) + " |\n")
			return false
		})
		b.WriteString(pager("sources", pg, n))
	}
	b.WriteString("\n## Admin log\n\nAdmin: " + admin.String() + "\n\n")
	if len(adminLog) == 0 {
		b.WriteString("No admin actions yet.\n")
	}
	for i := len(adminLog) - 1; i >= 0; i-- {
		e := adminLog[i]
		b.WriteString("- height " + itoa(e.height) + " (" + itoa(e.ts) + "): " + sanitize.InlineText(e.action) + "\n")
	}
	return b.String()
}

func renderAlgorithm() string {
	p := params
	day := int64(24 * 3600)
	return "# Algorithm\n\n" + nav() +
		"```\nbucket_s(t) = min(cap_s, decay(points_s, t - last_s))\n" +
		"Score = M_identity × M_maturity × M_diversity × Σ_s w_s · bucket_s(t)\n```\n\n" +
		"| Parameter | Value |\n|---|---|\n" +
		"| Half-life | " + itoa(p.HalfLife/day) + " days |\n" +
		"| Decay | shift per half-life + 8-step table 2^(-k/8), fixed-point 1e6 |\n" +
		"| Default cap per source | " + itoa(renown.ToPoints(p.DefaultCap)) + " points |\n" +
		"| Max units per attestation | " + itoa(p.MaxUnitsPerAttest) + " |\n" +
		"| Identity (r/sys/users name) | ×" + milliStr(p.IdentityBonus) + " |\n" +
		"| Maturity | ×" + milliStr(p.MaturityStart) + " → ×1.000 over " + itoa(p.MaturityPeriod/day) + " days from the first verified attestation |\n" +
		"| Diversity | ×(1 + " + milliStr(p.DiversityStep) + " × (categories − 1)), max ×" + milliStr(p.DiversityMax) + " |\n" +
		"| Unverified source weight | 0 |\n" +
		"| Tiers | Regular ≥ " + itoa(renown.RegularMin) + ", Patron ≥ " + itoa(renown.PatronMin) + ", Legend ≥ " + itoa(renown.LegendMin) + " |\n\n" +
		"Categories: " + strings.Join(renown.Categories(), ", ") + ". No balance-based category.\n"
}

func renderIntegrate() string {
	return "# Integrate\n\n" + nav() +
		"## Source realm\n\n```go\nimport \"gno.land/r/g1dmwvymew9ku97tp30xka70w4tnn8cydh2tct9p/barkeep/v0\"\n\n" +
		"func init(cur realm) {\n\tbarkeep.RegisterSource(cross(cur), \"contribution\", \"Quests for adventurers\")\n}\n\n" +
		"func Complete(cur realm, id string) {\n\t// ... your logic\n\tbarkeep.Attest(cross(cur), cur.Previous().Address(), \"quest.completed\", 1)\n}\n```\n\n" +
		"`Attest` returns false instead of panicking, so Barkeep never fails your transaction.\n\n" +
		"## Consumer realm\n\n```go\nif !barkeep.HasMinScore(caller, 100) {\n\tpanic(\"not enough renown\")\n}\n```\n\n" +
		"Reads: `ScoreOf`, `CategoryScoreOf`, `SourceScoreOf`, `TierOf`, `HasMinScore`, `HasMinCategoryScore`, " +
		"`ProfileJSON`, `LeaderboardJSON(offset, limit)`, `SourcesJSON(offset, limit)`, `ParamsJSON`.\n"
}
