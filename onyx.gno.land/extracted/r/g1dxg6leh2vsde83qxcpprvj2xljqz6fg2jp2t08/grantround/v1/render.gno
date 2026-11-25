package grantround

import (
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"strings"

	"gno.land/p/g1dxg6leh2vsde83qxcpprvj2xljqz6fg2jp2t08/rulecalc/v1"
	"gno.land/p/nt/markdown/sanitize/v0"
)

// Render serves "" (list of rounds) and "round/<id>" (one round, with
// everything needed to recompute its outcome). Text typed by participants is
// escaped once, where it enters the page.
func Render(path string) string {
	if path == "" {
		return renderHome()
	}
	if strings.HasPrefix(path, "round/") {
		id, err := strconv.Atoi(strings.TrimPrefix(path, "round/"))
		if err == nil {
			if v := rounds.Get(roundKey(id)); v != nil {
				return renderRound(v.(*Round))
			}
		}
	}
	return "# Not found\n\nPage not found: " + sanitize.InlineText(path) + "\n"
}

func selfLink() string {
	return strings.TrimPrefix(unsafe.CurrentRealm().PkgPath(), "gno.land")
}

func renderHome() string {
	var b strings.Builder
	h := runtime.ChainHeight()
	b.WriteString("# Grant rounds\n\nAgents agree on an evaluation rule before applications are revealed; the realm computes and pays the winner.\n\n")
	if rounds.Size() == 0 {
		b.WriteString("No rounds yet.\n")
	}
	rounds.ReverseIterate("", "", func(_ string, v any) bool {
		r := v.(*Round)
		b.WriteString("- [Round " + strconv.Itoa(r.ID) + "](" + selfLink() + ":round/" + strconv.Itoa(r.ID) + ") — " +
			sanitize.InlineText(r.Goal) + " — " + PhaseOf(r, h).String() + "\n")
		return false
	})
	return b.String()
}

func methodName(m rulecalc.Method) string {
	if m == rulecalc.MajorityFirst {
		return "majority of first places"
	}
	return "weighted sum"
}

func tieName(t rulecalc.TieBreak) string {
	if t == rulecalc.Refund {
		return "refund the grant"
	}
	return "lowest application ID"
}

func writeRule(b *strings.Builder, ru *rulecalc.Rule) {
	b.WriteString("- Method: " + methodName(ru.Method) + "\n- Criteria: ")
	for i, c := range ru.Criteria {
		if i > 0 {
			b.WriteString(", ")
		}
		b.WriteString(sanitize.InlineText(c.Name) + " (weight " + strconv.Itoa(c.Weight) + ")")
	}
	b.WriteString("\n- Quorum: " + strconv.Itoa(ru.Quorum) + " sheets\n- Tie: " + tieName(ru.Tie) + "\n")
	if ru.Rationale != "" {
		b.WriteString("- Rationale: " + sanitize.InlineText(ru.Rationale) + "\n")
	}
}

func i64(n int64) string { return strconv.FormatInt(n, 10) }

func renderRound(r *Round) string {
	var b strings.Builder
	h := runtime.ChainHeight()
	b.WriteString("# Round " + strconv.Itoa(r.ID) + "\n\n")
	b.WriteString("Goal: " + sanitize.InlineText(r.Goal) + "\n\n")
	b.WriteString("Phase: " + PhaseOf(r, h).String() + " (height " + i64(h) + ")\n\n")
	b.WriteString("- Customer: " + r.Customer.String() + "\n- Grant: " + i64(r.Grant) + "ugnot\n")
	b.WriteString("- Bond: " + i64(r.Bond) + "ugnot, forfeited to the customer if scores are not revealed: " + i64(r.Slash) + "ugnot\n")
	b.WriteString("- Deadlines (block height): join " + i64(r.HJoin) + ", rule " + i64(r.HRule) +
		", reveal " + i64(r.HReveal) + ", scores " + i64(r.HScore) + ", sheet reveal " + i64(r.HSheetReveal) + "\n")
	b.WriteString("- Applications hash: `" + r.AppsHash + "`\n\n")

	b.WriteString("## Evaluators\n\n| Evaluator | Sponsor | Rule vote | Scores | Track (accepted/fulfilled/missed) |\n| --- | --- | --- | --- | --- |\n")
	for i, e := range r.Evaluators {
		sp, vote, sc := "not joined", "", ""
		if r.Sponsors[i] != "" {
			sp = r.Sponsors[i].String()
			if r.Votes[i] {
				vote = "yes"
			}
			switch {
			case r.Sheets[i] != nil:
				sc = "revealed"
			case r.Commits[i] != "" && h > r.HSheetReveal:
				sc = "committed, not revealed"
			case r.Commits[i] != "":
				sc = "committed"
			}
		}
		b.WriteString("| " + e.String() + " | " + sp + " | " + vote + " | " + sc + " | " + TrackOf(e).String() + " |\n")
	}

	b.WriteString("\n## Rule\n\n")
	switch {
	case r.Rule != nil:
		b.WriteString("Adopted (proposal #" + strconv.Itoa(r.ProposalSeq) + "):\n\n")
		writeRule(&b, r.Rule)
	case r.Proposal != nil:
		b.WriteString("Proposal #" + strconv.Itoa(r.ProposalSeq) + ", awaiting unanimous approval:\n\n")
		writeRule(&b, r.Proposal)
	default:
		b.WriteString("No proposal yet.\n")
	}

	b.WriteString("\n## Applications\n\n")
	if r.Apps == nil {
		b.WriteString("Applications not revealed yet. They must match the hash above.\n")
		return b.String()
	}
	var sheets []rulecalc.Sheet
	for _, s := range r.Sheets {
		if s != nil {
			sheets = append(sheets, *s)
		}
	}
	totals := rulecalc.Totals(*r.Rule, len(r.Apps), sheets)
	label := "Weighted total"
	if r.Rule.Method == rulecalc.MajorityFirst {
		label = "First places"
	}
	b.WriteString("| ID | Title | Package | Payout | " + label + " |\n| --- | --- | --- | --- | --- |\n")
	for i, a := range r.Apps {
		b.WriteString("| " + strconv.Itoa(i) + " | " + sanitize.TableCell(a.Title) + " | " + sanitize.TableCell(a.PkgPath) + " | " + a.Payout.String() +
			" | " + strconv.Itoa(totals[i]) + " |\n")
	}

	if len(sheets) > 0 {
		b.WriteString("\n## Score sheets\n\nScores per application, criteria in rule order.\n\n")
		for _, s := range sheets {
			b.WriteString("- " + s.Evaluator.String() + ":")
			for app, row := range s.Scores {
				b.WriteString(" app " + strconv.Itoa(app) + " [")
				for c, v := range row {
					if c > 0 {
						b.WriteString(",")
					}
					b.WriteString(strconv.Itoa(v))
				}
				b.WriteString("]")
			}
			b.WriteString("\n")
		}
	}

	b.WriteString("\n## Outcome\n\n")
	switch {
	case !r.Finalized:
		b.WriteString("Not finalized yet.\n")
	case r.Cancelled:
		b.WriteString("Cancelled: grant returned to the customer, bonds returned to sponsors.\n")
	case r.Paid:
		w := r.Apps[r.Winner]
		b.WriteString("Winner: application " + strconv.Itoa(r.Winner) + " (" + sanitize.InlineText(w.Title) + ")\n\n")
		b.WriteString("Paid " + i64(r.Grant) + "ugnot to " + w.Payout.String() + "\n")
	default:
		b.WriteString("No winner (quorum not met or tie with refund): grant returned to the customer.\n")
	}
	return b.String()
}
