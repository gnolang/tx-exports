package validator_scores

import (
	"strconv"
	"strings"
)

// formatHundredths renders the canonical decimal "8743" as "87.43".
func formatHundredths(s string) string {
	for len(s) < 3 {
		s = "0" + s
	}
	return s[:len(s)-2] + "." + s[len(s)-2:]
}

// mdEscape backslash-escapes every ASCII punctuation character, so a
// moniker renders as plain text and never as an author-chosen link, image
// or HTML. gnoweb still turns a g1 address that follows a space into a link
// to its /u/ page, with the address itself as the link text.
func mdEscape(s string) string {
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c >= '!' && c <= '/' || c >= ':' && c <= '@' || c >= '[' && c <= '`' || c >= '{' && c <= '~' {
			b.WriteByte('\\')
		}
		b.WriteByte(c)
	}
	return b.String()
}

// Render shows the latest sealed edition as a Markdown table. The path is
// ignored.
func Render(_ string) string {
	var b strings.Builder
	b.WriteString("# Validator selection scores\n\n")
	e := latestSealed()
	if e == nil {
		b.WriteString("No edition has been published yet.\n")
		return b.String()
	}
	b.WriteString("Edition " + strconv.Itoa(e.number) + ", computed at " + e.computedAt +
		", scorecard SHA-256 `" + e.scorecardSHA256 + "`. Scores have two decimals; a sealed edition never changes.\n\n")
	b.WriteString("| Rank | Moniker | Operator | Total |")
	for _, a := range e.arenas {
		b.WriteString(" " + mdEscape(a) + " |")
	}
	b.WriteString(" GitHub |\n| ---: | --- | --- | ---: |")
	for range e.arenas {
		b.WriteString(" ---: |")
	}
	b.WriteString(" ---: |\n")
	for _, c := range sortedCandidates(e) {
		b.WriteString("| " + c.rankText + " | " + mdEscape(c.moniker) + " | " + c.operator +
			" | " + formatHundredths(c.total) + " |")
		for _, s := range strings.Split(c.arenaScores, ",") {
			b.WriteString(" " + formatHundredths(s) + " |")
		}
		b.WriteString(" " + formatHundredths(c.github) + " |\n")
	}
	b.WriteString("\nMachine-readable: `LatestJSON()`, `EditionJSON(n)`, `CandidateJSON(operator)`.\n")
	return b.String()
}
