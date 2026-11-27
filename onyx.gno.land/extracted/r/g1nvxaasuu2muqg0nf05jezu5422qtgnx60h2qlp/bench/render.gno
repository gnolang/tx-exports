package bench

import (
	"strconv"
	"strings"
	"time"

	"gno.land/p/g1nvxaasuu2muqg0nf05jezu5422qtgnx60h2qlp/cube3x3"
	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/p/nt/mux/v0"
	"gno.land/p/nt/ufmt/v0"
)

const benchPage = "/r/g1nvxaasuu2muqg0nf05jezu5422qtgnx60h2qlp/bench"

var benchRouter = mux.NewRouter()

func init() {
	benchRouter.HandleFunc("", renderDashboard)
	benchRouter.HandleFunc("round/{roundKey}", renderRound)
	benchRouter.HandleFunc("solve/{roundKey}/{addr}", renderSolve)
	benchRouter.SetNotFoundHandler(func(res *mux.ResponseWriter, _ *mux.Request) {
		res.Write("# Page not found\n\n[Back to Colorado](" + benchPage + ")\n")
	})
}

// Render serves the Colorado lobby, round details, and published solutions.
func Render(path string) string {
	return benchRouter.Render(strings.TrimPrefix(path, "/"))
}

func roundPage(roundKey string) string {
	return benchPage + ":round/" + roundKey
}

func phaseLabel(phase string) string {
	switch phase {
	case "commit_open":
		return "Open for solutions"
	case "reveal_open":
		return "Open to publish"
	default:
		return "Completed"
	}
}

func renderDashboard(res *mux.ResponseWriter, _ *mux.Request) {
	nowUnix := time.Now().Unix()
	dayID := nowUnix / secondsPerDay
	var b strings.Builder
	b.WriteString("# Colorado\n\n## Today's Challenges\n\n")
	classic, special := dailyRounds(dayID)
	if classic == nil || special == nil {
		b.WriteString("[Start Today's Challenges](" + benchPage + "$help&func=EnsureTodayChallenges)\n")
	} else {
		writeDailyRoundLink(&b, classic, "Classic", nowUnix)
		writeDailyRoundLink(&b, special, "Special", nowUnix)
	}

	b.WriteString("\n## Yesterday's Rounds\n\n")
	classic, special = dailyRounds(dayID - 1)
	if classic == nil && special == nil {
		b.WriteString("There were no rounds yesterday.\n")
	} else {
		for _, round := range []struct {
			challenge *challengeRecord
			label     string
		}{{classic, "Classic"}, {special, "Special"}} {
			if round.challenge != nil {
				writeDailyRoundLink(&b, round.challenge, round.label, nowUnix)
			}
		}
	}

	b.WriteString("\n## Recent Quick Rounds\n\n")
	first := true
	forEachRecentQuickRound(func(c *challengeRecord) {
		if first {
			b.WriteString("| Round | Rule | Status |\n| --- | --- | --- |\n")
			first = false
		}
		title, _, _ := roundRuleMetadata(c.RuleKey)
		ufmt.Fprintf(&b, "| [Quick Round %s](%s) | %s | %s |\n",
			strings.TrimPrefix(c.RoundKey, "Q:"), roundPage(c.RoundKey), sanitize.TableCell(title), phaseLabel(computePhase(c, nowUnix)))
	})
	if first {
		b.WriteString("No quick rounds yet.\n")
	}

	b.WriteString("\n## Community Rules\n\n")
	if customRules.Size() == 0 {
		b.WriteString("No community rules yet.\n")
	}
	customRules.Iterate("", "", func(_ string, value any) bool {
		rule := value.(registeredRule)
		b.WriteString("- **" + sanitize.InlineText(rule.Title) + "**")
		if rule.Description != "" {
			b.WriteString(" · " + sanitize.InlineText(rule.Description))
		}
		b.WriteByte('\n')
		return false
	})
	res.Write(b.String())
}

func writeDailyRoundLink(b *strings.Builder, c *challengeRecord, label string, nowUnix int64) {
	title, _, _ := roundRuleMetadata(c.RuleKey)
	ufmt.Fprintf(b, "- [%s](%s) · %s · %s\n", label, roundPage(c.RoundKey), sanitize.InlineText(title), phaseLabel(computePhase(c, nowUnix)))
}

func roundTitle(c *challengeRecord) string {
	category := "Classic Challenge"
	switch c.Kind {
	case "quick":
		return "Quick Round " + strings.TrimPrefix(c.RoundKey, "Q:")
	case "daily_twisted":
		category = "Special Challenge"
	}
	day := time.Unix(c.CommitDeadline-secondsPerDay, 0).UTC()
	return category + " · " + day.Format("January 2, 2006")
}

func renderRound(res *mux.ResponseWriter, req *mux.Request) {
	c, ok := challenges.Get(req.GetVar("roundKey")).(*challengeRecord)
	if !ok {
		res.Write("# Round not found\n\n[Back to Colorado](" + benchPage + ")\n")
		return
	}
	var b strings.Builder
	phase := computePhase(c, time.Now().Unix())
	title, description, _ := roundRuleMetadata(c.RuleKey)
	b.WriteString("[Back to Colorado](" + benchPage + ")\n\n# " + roundTitle(c) + "\n\n## " + sanitize.InlineText(title) + "\n\n")
	if description != "" {
		b.WriteString("Rule details · " + sanitize.InlineText(description) + "\n\n")
	}
	const dateFormat = "2006-01-02 15:04:05 UTC"
	ufmt.Fprintf(&b, "**%s**\n\n- Submissions close at %s\n- Publishing closes at %s\n\n",
		phaseLabel(phase), time.Unix(c.CommitDeadline, 0).UTC().Format(dateFormat), time.Unix(c.RevealDeadline, 0).UTC().Format(dateFormat))
	b.WriteString("## Scramble\n\n" + sanitize.CodeBlock(c.ScrambleStr) + "\n\n")
	b.WriteString(cube3x3.RenderCubeNetMarkdown(c.ScrambleState, "Scrambled 3x3 cube net") + "\n\n")
	if phase == "commit_open" {
		b.WriteString("Solutions stay hidden until publishing opens.\n")
	} else {
		writeLeaderboardMarkdown(&b, c.RoundKey)
	}
	if phase == "finalized" && c.UnrevealedCount > 0 {
		ufmt.Fprintf(&b, "\n[Clean Up Expired Entries](%s$help&func=PruneExpiredCommits&roundKey=%s&maxDelete=%d)\n",
			benchPage, c.RoundKey, DefaultPruneLimit)
	}
	res.Write(b.String())
}

func writeLeaderboardMarkdown(b *strings.Builder, roundKey string) {
	b.WriteString("## Leaderboard\n\n")
	first := true
	forEachRankedSubmission(roundKey, func(rank int, sub *submissionRecord) bool {
		if first {
			b.WriteString("| Rank | Player | Moves | Quarter turns |\n| ---: | --- | ---: | ---: |\n")
			first = false
		}
		ufmt.Fprintf(b, "| %d | [%s](%s:solve/%s/%s) | %d | %d |\n", rank, sub.Solver, benchPage, roundKey, sub.Solver, sub.OBTM, sub.QTM)
		return rank == MaxLeaderboardLimit
	})
	if first {
		b.WriteString("No published solutions yet.\n")
	}
}

func renderSolve(res *mux.ResponseWriter, req *mux.Request) {
	roundKey := req.GetVar("roundKey")
	c, ok := challenges.Get(roundKey).(*challengeRecord)
	if !ok {
		res.Write("# Round not found\n\n[Back to Colorado](" + benchPage + ")\n")
		return
	}
	back := "[Back to Round](" + roundPage(c.RoundKey) + ")\n\n"
	if computePhase(c, time.Now().Unix()) == "commit_open" {
		res.Write(back + "Solutions stay hidden until publishing opens.\n")
		return
	}
	addr := req.GetVar("addr")
	sub, ok := submissions.Get(roundKey + "|" + addr).(*submissionRecord)
	if !ok {
		res.Write(back + "# Solution not found\n")
		return
	}
	var b strings.Builder
	b.WriteString(back + "# Published Solution\n\n")
	if rank := submissionRank(roundKey, sub); rank > 0 {
		ufmt.Fprintf(&b, "Rank %d · ", rank)
	}
	ufmt.Fprintf(&b, "%d moves · %d quarter turns\n\n", sub.OBTM, sub.QTM)
	b.WriteString("**Solve method (self-declared)** " + solverModeLabel(sub.ModeTag))
	if sub.AgentModel != "" {
		b.WriteString(" · " + sanitize.InlineText(sub.AgentModel))
	}
	b.WriteString("\n\n## Moves\n\n" + sanitize.CodeBlock(sub.CanonicalMoves) + "\n\n")
	b.WriteString("## Phase Breakdown\n\n| Phase | Completed at move |\n| --- | ---: |\n")
	for _, phase := range []struct {
		name string
		move int
	}{{"Cross", sub.Phases.CrossAtMove}, {"F2L", sub.Phases.F2LAtMove}, {"OLL", sub.Phases.OLLAtMove}, {"PLL", sub.Phases.PLLAtMove}} {
		move := "Not reached"
		if phase.move > 0 {
			move = strconv.Itoa(phase.move)
		}
		ufmt.Fprintf(&b, "| %s | %s |\n", phase.name, move)
	}
	if sub.Notes != "" {
		b.WriteString("\n**Solver notes** " + sanitize.InlineText(sub.Notes) + "\n")
	}
	res.Write(b.String())
}

func solverModeLabel(mode string) string {
	switch mode {
	case "assisted":
		return "Human + AI"
	case "ai":
		return "AI Only"
	default:
		return "Human"
	}
}
