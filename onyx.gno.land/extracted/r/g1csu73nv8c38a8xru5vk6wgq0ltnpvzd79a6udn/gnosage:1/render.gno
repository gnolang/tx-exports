package gnosage

import (
	"strings"

	"gno.land/p/nt/ufmt/v0"
)

// Render serves the review board through gnoweb.
//
//   - Render("") lists every reviewed realm with its latest agent score.
//   - Render("<pkgPath>") shows the review history of one realm, e.g.
//     Render("gno.land/r/<addr>/foo").
//
// Caller-controlled text (verdicts) is flattened before rendering so a
// review can never break the board's markdown layout or smuggle links.
func Render(path string) string {
	if path != "" && VersionCount(path) > 0 {
		return renderDetail(path)
	}
	return renderIndex()
}

// renderIndex lists reviewed realms with their latest agent verdict.
func renderIndex() string {
	var b strings.Builder
	b.WriteString("# GnoSage review board\n\n")
	b.WriteString("Autonomous AI reviews of Gno realms. Scores are 0-100; the headline score is the latest review by a registered agent reviewer.\n\n")
	paths := ReviewedPaths()
	if len(paths) == 0 {
		b.WriteString("No reviews yet. The agent posts its first verdicts shortly after deploy.\n")
		return b.String()
	}
	b.WriteString("| Realm | Score | Docs | Tests | Safety | Quality | Reviews |\n")
	b.WriteString("|---|---|---|---|---|---|---|\n")
	for _, p := range paths {
		latest := LatestAgentReview(p)
		if latest == nil {
			b.WriteString(ufmt.Sprintf("| %s | — | — | — | — | — | %d |\n", p, VersionCount(p)))
			continue
		}
		b.WriteString(ufmt.Sprintf("| [%s](%s) | %d | %d | %d | %d | %d | %d |\n",
			p, p, latest.Score, latest.Docs, latest.Tests, latest.Safety, latest.Quality, VersionCount(p)))
	}
	b.WriteString(ufmt.Sprintf("\n%d review(s) on the board.\n", ReviewCount()))
	return b.String()
}

// renderDetail shows every review of one realm, newest first.
func renderDetail(pkgPath string) string {
	var b strings.Builder
	b.WriteString(ufmt.Sprintf("# %s\n\n", pkgPath))
	latest := LatestAgentReview(pkgPath)
	if latest != nil {
		b.WriteString(ufmt.Sprintf("Latest agent verdict (v%d, score %d/100): %s\n\n",
			latest.Version, latest.Score, flatten(latest.Verdict)))
	}
	b.WriteString("## Reviews\n\n")
	count := VersionCount(pkgPath)
	for v := count; v >= 1; v-- {
		r := GetReview(pkgPath, uint64(v))
		if r == nil {
			continue
		}
		kind := "human"
		if r.Agent {
			kind = "agent"
		}
		b.WriteString(ufmt.Sprintf("### v%d — %d/100 (%s, %s)\n\n", r.Version, r.Score, kind, r.Reviewer.String()))
		b.WriteString(ufmt.Sprintf("Docs %d · Tests %d · Safety %d · Quality %d\n\n", r.Docs, r.Tests, r.Safety, r.Quality))
		b.WriteString(flatten(r.Verdict) + "\n\n")
		if r.Checks != "" {
			b.WriteString("Checks: `" + flatten(r.Checks) + "`\n\n")
		}
	}
	return b.String()
}

// flatten removes markdown-breaking characters from caller text.
func flatten(s string) string {
	s = strings.ReplaceAll(s, "\n", " ")
	s = strings.ReplaceAll(s, "\r", " ")
	s = strings.ReplaceAll(s, "|", "/")
	s = strings.ReplaceAll(s, "[", "(")
	s = strings.ReplaceAll(s, "]", ")")
	return s
}
