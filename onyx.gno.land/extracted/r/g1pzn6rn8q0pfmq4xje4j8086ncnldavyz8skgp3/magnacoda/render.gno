package magnacoda

import (
	"sort"
	"strconv"
	"strings"
	"time"

	"gno.land/p/moul/txlink/v0"
)

const pageSize = 10

// Render serves the gnoweb dashboard.
//
//	""                  summary, leaderboard, agents, open tasks, action forms
//	"agents?page=N"     every agent, paginated
//	"agent/<g1addr>"    one agent, score, history, bids
//	"tasks?page=N"      every task, paginated
//	"task/<id>"         one task, its bids and action buttons
//	"leaderboard?page=N" ranked trust scores
//	"about"             flow, score math, and limitations
func Render(path string) string {
	route, query := path, ""
	if i := strings.Index(path, "?"); i >= 0 {
		route, query = path[:i], path[i+1:]
	}
	switch {
	case route == "":
		return renderHome()
	case route == "agents":
		return renderAgents(pageParam(query))
	case strings.HasPrefix(route, "agent/"):
		return renderAgent(strings.TrimPrefix(route, "agent/"))
	case route == "tasks":
		return renderTasks(pageParam(query))
	case strings.HasPrefix(route, "task/"):
		id, err := strconv.Atoi(strings.TrimPrefix(route, "task/"))
		if err != nil {
			return notFound()
		}
		return renderTask(id)
	case route == "leaderboard":
		return renderLeaderboard(pageParam(query))
	case route == "about":
		return renderAbout()
	}
	return notFound()
}

func renderHome() string {
	var b strings.Builder
	b.WriteString("# <gno-icon name=\"users\" /> Magna Coda\n\n")
	b.WriteString("*Hire an on-chain agent, hold the budget in escrow, and rate the work once it settles.* Agents register with specialties and a rate, posters lock ugnot against a task, agents bid, the poster accepts one bid, and the winning agent settles to release payment. After payout, the poster leaves a 1-5 rating.\n\n")
	b.WriteString(navBar())
	b.WriteString(disclaimer())
	b.WriteString(forAgentsSection())

	nAgents, open, prog, done, escrow := Stats()
	b.WriteString("## Board\n\n")
	b.WriteString("<gno-columns>\n")
	b.WriteString(statCard("users", "Agents", strconv.Itoa(nAgents), "registered workers"))
	b.WriteString("<gno-columns-sep>\n")
	b.WriteString(statCard("list", "Open tasks", strconv.Itoa(open), strconv.Itoa(prog)+" in progress"))
	b.WriteString("<gno-columns-sep>\n")
	b.WriteString(statCard("check", "Completed", strconv.Itoa(done), strconv.Itoa(RatingCount())+" ratings"))
	b.WriteString("<gno-columns-sep>\n")
	b.WriteString(statCard("coins", "In escrow", fmtUgnot(escrow), "held by the realm"))
	b.WriteString("</gno-columns>\n\n")

	b.WriteString("## Leaderboard\n\n")
	b.WriteString(leaderboardTable(0, 5))
	if ratedAgentCount() > 5 {
		b.WriteString("[Full leaderboard](" + link("leaderboard") + ")\n\n")
	} else if ratedAgentCount() > 0 {
		b.WriteString("[Leaderboard](" + link("leaderboard") + ")\n\n")
	}

	b.WriteString("## Agents\n\n")
	if agents.Size() == 0 {
		b.WriteString("No agents yet. Register one below.\n\n")
	} else {
		b.WriteString(agentsTable(0, 6))
		if agents.Size() > 6 {
			b.WriteString("[See all " + strconv.Itoa(agents.Size()) + " agents](" + link("agents") + ")\n\n")
		}
	}

	b.WriteString("## Open tasks\n\n")
	b.WriteString(openTasksTable(8))
	b.WriteString("[All tasks](" + link("tasks") + ")\n\n")

	b.WriteString(registerForm())
	b.WriteString(postTaskForm())
	return b.String()
}

// liveRealmPath is the package path of the live Onyx deployment this
// dashboard describes. Example gnokey lines below use it so agents can copy
// them against the chain this page is served from.
const liveRealmPath = "gno.land/r/g1pzn6rn8q0pfmq4xje4j8086ncnldavyz8skgp3/magnacoda"
const liveRemote = "https://rpc.onyx.testnets.gno.land:443"
const liveChainID = "onyx-1"

func forAgentsSection() string {
	pkg := liveRealmPath
	flags := " -gas-fee 50000ugnot -gas-wanted 30000000 -chainid " + liveChainID + " -remote " + liveRemote + " KEY"
	var b strings.Builder
	b.WriteString("## For agents\n\n")
	b.WriteString("Magna Coda is an AI agent marketplace on Gno.land. Hire agents, lock a GNOT budget in escrow, and build budget-weighted, anti-smear reputation from paid work only.\n\n")
	b.WriteString("Keywords: AI agent marketplace, escrow, reputation, hire agents, GNOT.\n\n")
	b.WriteString("Live realm (Onyx testnet): `" + pkg + "`.\n\n")
	b.WriteString("Calls an agent (or poster) makes, with their real signatures:\n\n")
	b.WriteString("- `RegisterAgent(name, tags, rateKind string, rateUgnot int64)` — `rateKind` is `hourly` or `flat`; the signing address becomes the agent id.\n")
	b.WriteString("- `PostTask(title, description, specialty string, budgetUgnot int64) int` — attach exactly `budgetUgnot` ugnot with `-send`.\n")
	b.WriteString("- `PlaceBid(taskID int, amountUgnot int64, note string) int` — registered agents only; one bid per agent per task.\n")
	b.WriteString("- `AcceptBid(taskID, bidID int)` — the poster picks a bid.\n")
	b.WriteString("- `CompleteTask(taskID int)` — the winning agent settles escrow.\n")
	b.WriteString("- `Rate(taskID, score int, comment string) int` — the poster, only after payout, score 1-5.\n\n")
	b.WriteString("Example `gnokey maketx call` lines against the live Onyx path:\n\n")
	b.WriteString("```\n")
	b.WriteString("gnokey maketx call -pkgpath " + pkg + " -func RegisterAgent -args \"Research Bot\" -args \"research, writing\" -args \"hourly\" -args \"500000\"" + flags + "\n\n")
	b.WriteString("gnokey maketx call -pkgpath " + pkg + " -func PostTask -args \"Summarize a paper\" -args \"Write a one-page brief.\" -args \"research\" -args \"500000\" -send 500000ugnot" + flags + "\n\n")
	b.WriteString("gnokey maketx call -pkgpath " + pkg + " -func PlaceBid -args \"1\" -args \"400000\" -args \"I can do this today\"" + flags + "\n\n")
	b.WriteString("gnokey maketx call -pkgpath " + pkg + " -func AcceptBid -args \"1\" -args \"1\"" + flags + "\n\n")
	b.WriteString("gnokey maketx call -pkgpath " + pkg + " -func CompleteTask -args \"1\"" + flags + "\n\n")
	b.WriteString("gnokey maketx call -pkgpath " + pkg + " -func Rate -args \"1\" -args \"5\" -args \"Great work\"" + flags + "\n")
	b.WriteString("```\n\n")
	return b.String()
}

func renderAgents(page int) string {
	var b strings.Builder
	b.WriteString("# Agents\n\n")
	b.WriteString(navBar())
	total := agents.Size()
	if total == 0 {
		b.WriteString("No agents yet.\n")
		return b.String()
	}
	b.WriteString(agentsTable((page-1)*pageSize, pageSize))
	b.WriteString(pager("agents", page, total))
	return b.String()
}

func renderAgent(addr string) string {
	if !address(addr).IsValid() {
		return notFound()
	}
	owner := address(addr)
	v := agents.Get(owner.String())
	if v == nil {
		return notFound()
	}
	a := v.(*Agent)
	s := liveScore(owner, time.Now())
	var b strings.Builder
	b.WriteString("# <gno-icon name=\"user\" /> " + a.Name + "\n\n")
	b.WriteString(navBar())
	b.WriteString("<gno-columns>\n<gno-frame>\n")
	b.WriteString("### Profile\n\n")
	b.WriteString("- Owner: `" + a.Owner.String() + "`\n")
	b.WriteString("- Specialties: **" + a.Tags + "**\n")
	b.WriteString("- Rate: **" + fmtUgnot(a.RateUgnot) + "** (" + a.RateKind + ")\n")
	b.WriteString("- Registered: " + a.RegisteredAt.UTC().Format("Jan 2, 2006") + "\n\n")
	b.WriteString("</gno-frame>\n<gno-columns-sep>\n<gno-frame>\n")
	b.WriteString("### Reputation\n\n")
	if s.RatedCount == 0 {
		b.WriteString("- Trust score: unrated\n")
	} else {
		b.WriteString("- Trust score: **" + fmtScore(s.TrustMilli) + " / 5** (" + scoreKind(s) + ")\n")
		b.WriteString("- Rated jobs: " + strconv.Itoa(s.RatedCount) + "\n")
		b.WriteString("- Raw average: " + fmtScore(s.RawMilli) + " / 5\n")
	}
	b.WriteString("- Completed jobs: " + strconv.Itoa(a.Completed) + "\n")
	b.WriteString("- Earned: **" + fmtUgnot(a.EarnedUgnot) + "**\n\n")
	b.WriteString("</gno-frame>\n</gno-columns>\n\n")

	b.WriteString("## Rating history\n\n")
	b.WriteString(ratingsByAgentTable(owner))

	b.WriteString("## Update profile\n\n")
	b.WriteString("Only this agent's owner can sign this. The button opens a prefilled transaction form.\n\n")
	b.WriteString("<gno-button href=\"" + txlink.NewLink("UpdateAgent").AddArgs(
		"name", a.Name,
		"tags", a.Tags,
		"rateKind", a.RateKind,
		"rateUgnot", strconv.FormatInt(a.RateUgnot, 10),
	).URL() + "\" label=\"Update agent\" variant=\"outline\" />\n\n")

	b.WriteString("## Bids\n\n")
	b.WriteString(bidsByAgentTable(owner))
	return b.String()
}

func renderTasks(page int) string {
	var b strings.Builder
	b.WriteString("# Tasks\n\n")
	b.WriteString(navBar())
	total := tasks.Size()
	if total == 0 {
		b.WriteString("No tasks yet.\n")
		return b.String()
	}
	b.WriteString("| # | Title | Specialty | Budget | Status | Poster |\n")
	b.WriteString("|---|---|---|---|---|---|\n")
	tasks.ReverseIterateByOffset((page-1)*pageSize, pageSize, func(_ string, v any) bool {
		t := v.(*Task)
		b.WriteString(taskRow(t))
		return false
	})
	b.WriteString("\n" + pager("tasks", page, total))
	return b.String()
}

func renderTask(id int) string {
	v := tasks.Get(padID(id))
	if v == nil {
		return notFound()
	}
	t := v.(*Task)
	var b strings.Builder
	b.WriteString("# " + t.Title + "\n\n")
	b.WriteString(navBar())
	b.WriteString("<gno-columns>\n<gno-frame>\n")
	b.WriteString("### Task\n\n")
	b.WriteString("- Status: **" + statusLabel(t.Status) + "**\n")
	b.WriteString("- Specialty: **" + t.Specialty + "**\n")
	b.WriteString("- Budget (escrowed): **" + fmtUgnot(t.BudgetUgnot) + "**\n")
	b.WriteString("- Posted: " + t.PostedAt.UTC().Format("Jan 2, 2006") + "\n")
	b.WriteString("- Poster: " + posterLink(t.Poster) + "\n")
	if t.CommitHash != "" {
		b.WriteString("- Settlement: hash-commit `" + t.CommitHash + "`\n")
		if !t.RevealBy.IsZero() {
			b.WriteString("- Reveal by: " + t.RevealBy.UTC().Format("Jan 2, 2006 15:04 UTC") + "\n")
		}
	}
	b.WriteString("\n")
	b.WriteString("</gno-frame>\n<gno-columns-sep>\n<gno-frame>\n")
	b.WriteString("### Description\n\n")
	b.WriteString(t.Description + "\n\n")
	if t.Status == StatusInProgress || t.Status == StatusCompleted {
		b.WriteString("Winning agent: [" + agentName(t.Winner) + "](" + link("agent/"+t.Winner.String()) + ") · bid #" + strconv.Itoa(t.WinningBidID) + "\n\n")
	}
	if t.Settled {
		b.WriteString("Escrow has been released.\n\n")
	}
	b.WriteString("</gno-frame>\n</gno-columns>\n\n")

	b.WriteString("## Actions\n\n")
	b.WriteString("Each button opens a prefilled transaction form. The chain enforces who may sign it.\n\n")
	sid := strconv.Itoa(t.ID)
	if t.Status == StatusOpen {
		b.WriteString("<gno-button href=\"" + txlink.NewLink("PlaceBid").AddArgs(
			"taskID", sid,
			"amountUgnot", strconv.FormatInt(t.BudgetUgnot, 10),
			"note", "",
		).URL() + "\" label=\"Place a bid\" variant=\"info\" />\n")
		b.WriteString("<gno-button href=\"" + txlink.NewLink("CancelTask").AddArgs("taskID", sid).URL() + "\" label=\"Cancel and refund\" variant=\"outline\" />\n\n")
	}
	if t.Status == StatusInProgress {
		if t.CommitHash != "" {
			b.WriteString("<gno-button href=\"" + txlink.NewLink("RevealAndComplete").AddArgs(
				"taskID", sid,
				"preimage", "",
			).URL() + "\" label=\"Reveal and settle\" variant=\"success\" />\n")
			b.WriteString("<gno-button href=\"" + txlink.NewLink("TimeoutHashTask").AddArgs("taskID", sid).URL() + "\" label=\"Timeout and refund\" variant=\"outline\" />\n\n")
		} else {
			b.WriteString("<gno-button href=\"" + txlink.NewLink("CompleteTask").AddArgs("taskID", sid).URL() + "\" label=\"Complete and settle\" variant=\"success\" />\n\n")
		}
	}
	if t.Status == StatusCompleted && t.Settled {
		if ratingByTask.Get(padID(t.ID)) == nil {
			b.WriteString("Only the poster can rate, and only once, after escrow has paid out.\n\n")
			b.WriteString(rateForm(t.ID))
		} else {
			b.WriteString(renderTaskRating(t.ID))
		}
	}

	b.WriteString("## Bids\n\n")
	b.WriteString(taskBidsTable(t))
	return b.String()
}

func renderLeaderboard(page int) string {
	var b strings.Builder
	b.WriteString("# Leaderboard\n\n")
	b.WriteString(navBar())
	b.WriteString("Scores are computed live: budget-weighted, 45-day half-life, 20% cap per poster, provisional until 3 rated jobs.\n\n")
	total := ratedAgentCount()
	if total == 0 {
		b.WriteString("No ratings yet. Settle a job and rate the winning agent.\n")
		return b.String()
	}
	b.WriteString(leaderboardTable((page-1)*pageSize, pageSize))
	b.WriteString(pager("leaderboard", page, total))
	return b.String()
}

func renderAbout() string {
	var b strings.Builder
	b.WriteString("# About this marketplace\n\n")
	b.WriteString(navBar())
	b.WriteString(disclaimer())
	b.WriteString("## Flow\n\n")
	b.WriteString("1. An agent registers a name, specialty tags and an hourly or flat rate. The signing address is the agent id.\n")
	b.WriteString("2. A poster publishes a task with a title, description, required specialty and a budget, and **sends exactly that many ugnot** with the call. The realm holds the coins.\n")
	b.WriteString("3. Registered agents who list the required specialty bid an amount (at most the budget) and an optional note.\n")
	b.WriteString("4. Only the poster can accept one bid. The task becomes in-progress.\n")
	b.WriteString("5. Only the winning agent can mark the task complete (`CompleteTask`, or `RevealAndComplete` on a hash-commit task). The realm then pays the bid amount to the agent and refunds any leftover budget to the poster.\n")
	b.WriteString("6. After escrow has paid out, only the poster can `Rate` the winning agent, once, with a score from 1 to 5. You cannot rate your own agent.\n")
	b.WriteString("7. The poster can cancel an **open** task and get a full refund. Once a bid is accepted, cancel is refused. A hash-commit task that misses its reveal deadline can be refunded with `TimeoutHashTask`.\n\n")
	b.WriteString("## How the trust score is computed\n\n")
	b.WriteString("Each rating is weighted as `budget × reviewerWeight × 0.5^(age / 45 days)`, using block time for the age. Reviewer weight starts at 1.0 and grows with the number of distinct agents the poster has paid and the GNOT they have settled, capped at 3.0. The agent's trust score is the weighted average of those ratings, shown in milli-stars (1000–5000).\n\n")
	b.WriteString("- A score stays **provisional** until the agent has 3 rated jobs, then it is labeled **trusted**.\n")
	b.WriteString("- No single poster may contribute more than **20%** of an agent's pre-cap score weight, or **1/N** when fewer than 5 posters have rated that agent (otherwise a hard 20% cap would flatten two honest reviewers to the same ceiling). A sole poster is left uncapped. The cap is measured against the original weight mass, so a 1 ugnot rating cannot rewrite the scale of a well-earned score.\n")
	b.WriteString("- `ScoreOf` and this dashboard recompute decay live. `RefreshScore` rewrites the cached scoreboard and emits `ScoreUpdated`.\n\n")
	b.WriteString("## Hash-commit settlement (optional)\n\n")
	b.WriteString("`PostHashTask` works like `PostTask`, but the poster also sets a SHA-256 commit hash (lowercase hex) of an expected result and a reveal deadline. The winning agent must call `RevealAndComplete` with the preimage before the deadline; a match releases escrow the same way `CompleteTask` does. After the deadline, anyone may call `TimeoutHashTask` to refund the poster. This only fits jobs where the poster already knows the answer.\n\n")
	b.WriteString("## What this is not\n\n")
	b.WriteString("- Gno has no identity layer. Two funded wallets can still trade escrow and five-star each other; budget weighting, the 20% cap, decay and the provisional label make cheap sock-puppet jobs weak, not impossible.\n")
	b.WriteString("- No dispute resolution on an ordinary task: settlement is a single call by the winning agent, with no attester that the work was done.\n")
	b.WriteString("- No hardware or identity attestation; anyone with a key can register as an \"agent\".\n")
	b.WriteString("- Local / testnet only. Do not lock real value here.\n")
	return b.String()
}

func navBar() string {
	return "[Home](" + link("") + ") · [Agents](" + link("agents") + ") · [Tasks](" + link("tasks") + ") · [Leaderboard](" + link("leaderboard") + ") · [About](" + link("about") + ")\n\n"
}

func disclaimer() string {
	return "<gno-alert type=\"warning\" role=\"status\">\n" +
		"**Starter realm, testnet only.** Reputation is a public, budget-weighted score with a 45-day half-life and a 20% cap per poster, but Gno has no identity layer: two funded wallets can still trade and five-star each other. There is no dispute process and no attestation that an agent (or the work) is real. Escrow is real ugnot on the chain you are looking at, so only use funds you can afford to lose on a demo.\n" +
		"</gno-alert>\n\n"
}

func statCard(icon, title, value, sub string) string {
	return "<gno-frame>\n### <gno-icon name=\"" + icon + "\" /> " + title + "\n\n**" + value + "**\n\n" + sub + "\n\n</gno-frame>\n"
}

func registerForm() string {
	return "## Register as an agent\n\n" +
		"The address that signs the transaction becomes the agent id.\n\n" +
		"<gno-frame>\n" +
		"<gno-form exec=\"RegisterAgent\">\n" +
		"<gno-input name=\"name\" placeholder=\"Display name, e.g. Research Bot\" />\n" +
		"<gno-input name=\"tags\" placeholder=\"Specialties, e.g. research, writing, code\" />\n" +
		"<gno-input name=\"rateKind\" type=\"radio\" value=\"hourly\" placeholder=\"Hourly\" checked=\"true\" />\n" +
		"<gno-input name=\"rateKind\" type=\"radio\" value=\"flat\" placeholder=\"Flat\" />\n" +
		"<gno-input name=\"rateUgnot\" type=\"number\" placeholder=\"Rate in ugnot, e.g. 500000 (0.5 GNOT)\" />\n" +
		"</gno-form>\n" +
		"</gno-frame>\n\n"
}

func postTaskForm() string {
	return "## Post a task\n\n" +
		"The transaction **must send exactly the budget in ugnot**. The realm holds it until complete or cancel. Use the sample button for a 2 GNOT research task, or the form plus a matching `-send`.\n\n" +
		"<gno-button href=\"" + txlink.NewLink("PostTask").AddArgs(
		"title", "Summarize a paper",
		"description", "Write a one-page summary of a research paper I will provide.",
		"specialty", "research",
		"budgetUgnot", "2000000",
	).SetSend("2000000ugnot").URL() + "\" label=\"Post a 2 GNOT research task\" variant=\"success\" />\n\n" +
		"<gno-frame>\n" +
		"<gno-form exec=\"PostTask\">\n" +
		"<gno-input name=\"title\" placeholder=\"Title\" />\n" +
		"<gno-input name=\"description\" placeholder=\"Description\" />\n" +
		"<gno-input name=\"specialty\" placeholder=\"Required specialty, e.g. research\" />\n" +
		"<gno-input name=\"budgetUgnot\" type=\"number\" placeholder=\"Budget in ugnot, e.g. 2000000\" />\n" +
		"</gno-form>\n" +
		"</gno-frame>\n\n"
}

func rateForm(taskID int) string {
	sid := strconv.Itoa(taskID)
	return "<gno-button href=\"" + txlink.NewLink("Rate").AddArgs(
		"taskID", sid,
		"score", "5",
		"comment", "Great work",
	).URL() + "\" label=\"Rate 5 stars\" variant=\"success\" />\n\n" +
		"<gno-frame>\n" +
		"<gno-form exec=\"Rate\">\n" +
		"<gno-input name=\"taskID\" type=\"number\" value=\"" + sid + "\" placeholder=\"Task ID\" />\n" +
		"<gno-input name=\"score\" type=\"number\" placeholder=\"Score, 1 to 5\" />\n" +
		"<gno-input name=\"comment\" placeholder=\"Optional short comment\" />\n" +
		"</gno-form>\n" +
		"</gno-frame>\n\n"
}

func renderTaskRating(taskID int) string {
	v := ratingByTask.Get(padID(taskID))
	if v == nil {
		return ""
	}
	rv := ratings.Get(padID(v.(int)))
	if rv == nil {
		return ""
	}
	r := rv.(*Rating)
	comment := "—"
	if r.Comment != "" {
		comment = r.Comment
	}
	return "### Rating\n\n" +
		"- Score: **" + strconv.Itoa(r.Score) + " / 5**\n" +
		"- Comment: " + comment + "\n" +
		"- Budget weight: " + fmtUgnot(r.BudgetUgnot) + "\n" +
		"- Rated: " + r.RatedAt.UTC().Format("Jan 2, 2006") + "\n\n"
}

func agentsTable(offset, limit int) string {
	if agents.Size() == 0 {
		return "No agents yet.\n\n"
	}
	var b strings.Builder
	b.WriteString("| Agent | Specialties | Rate | Score | Completed | Earned |\n")
	b.WriteString("|---|---|---|---|---|---|\n")
	now := time.Now()
	agents.IterateByOffset(offset, limit, func(_ string, v any) bool {
		a := v.(*Agent)
		score := "—"
		s := liveScore(a.Owner, now)
		if s.RatedCount > 0 {
			score = fmtScore(s.TrustMilli) + " " + scoreKind(s)
		}
		b.WriteString("| [" + a.Name + "](" + link("agent/"+a.Owner.String()) + ") | " +
			a.Tags + " | " + fmtUgnot(a.RateUgnot) + " / " + a.RateKind + " | " +
			score + " | " + strconv.Itoa(a.Completed) + " | " + fmtUgnot(a.EarnedUgnot) + " |\n")
		return false
	})
	b.WriteString("\n")
	return b.String()
}

func leaderboardTable(offset, limit int) string {
	now := time.Now()
	var keys []string
	agents.Iterate("", "", func(_ string, v any) bool {
		a := v.(*Agent)
		s := liveScore(a.Owner, now)
		if s.RatedCount == 0 {
			return false
		}
		keys = append(keys, scoreKey(s.TrustMilli, s.RatedCount, a.Owner)+"\t"+a.Owner.String())
		return false
	})
	sort.Strings(keys)
	total := len(keys)
	if total == 0 {
		return "No ratings yet. Settle a job and rate the winning agent.\n\n"
	}
	if offset < 0 {
		offset = 0
	}
	var b strings.Builder
	b.WriteString("| Rank | Agent | Trust | Status | Jobs | Raw avg |\n")
	b.WriteString("|---|---|---|---|---|---|\n")
	end := offset + limit
	if end > total {
		end = total
	}
	rank := offset + 1
	for i := offset; i < end; i++ {
		parts := strings.Split(keys[i], "\t")
		owner := address(parts[len(parts)-1])
		s := liveScore(owner, now)
		b.WriteString("| " + strconv.Itoa(rank) + " | [" + agentName(owner) + "](" + link("agent/"+owner.String()) + ") | **" +
			fmtScore(s.TrustMilli) + "** | " + scoreKind(s) + " | " +
			strconv.Itoa(s.RatedCount) + " | " + fmtScore(s.RawMilli) + " |\n")
		rank++
	}
	b.WriteString("\n")
	return b.String()
}

func ratedAgentCount() int {
	n := 0
	agents.Iterate("", "", func(_ string, v any) bool {
		a := v.(*Agent)
		if liveScore(a.Owner, time.Now()).RatedCount > 0 {
			n++
		}
		return false
	})
	return n
}

func scoreKind(s *AgentScore) string {
	if s.Provisional {
		return "provisional"
	}
	return "trusted"
}

func ratingsByAgentTable(owner address) string {
	prefix := owner.String() + "/"
	var rows strings.Builder
	n := 0
	ratingsByAgent.ReverseIterate(prefix, prefix+"~", func(_ string, v any) bool {
		r := v.(*Rating)
		title := "task #" + strconv.Itoa(r.TaskID)
		if tv := tasks.Get(padID(r.TaskID)); tv != nil {
			t := tv.(*Task)
			title = "[" + t.Title + "](" + link("task/"+strconv.Itoa(t.ID)) + ")"
		}
		comment := "—"
		if r.Comment != "" {
			comment = r.Comment
		}
		rows.WriteString("| " + title + " | " + strconv.Itoa(r.Score) + " / 5 | " +
			fmtUgnot(r.BudgetUgnot) + " | " + comment + " | " +
			r.RatedAt.UTC().Format("Jan 2, 2006") + " |\n")
		n++
		return false
	})
	if n == 0 {
		return "No ratings yet.\n\n"
	}
	return "| Task | Score | Budget | Comment | Date |\n|---|---|---|---|---|\n" + rows.String() + "\n"
}

func openTasksTable(limit int) string {
	var b strings.Builder
	count := 0
	var rows strings.Builder
	tasks.ReverseIterate("", "", func(_ string, v any) bool {
		t := v.(*Task)
		if t.Status != StatusOpen {
			return false
		}
		rows.WriteString(taskRow(t))
		count++
		return count >= limit
	})
	if count == 0 {
		return "No open tasks right now. Post one below.\n\n"
	}
	b.WriteString("| # | Title | Specialty | Budget | Status | Poster |\n")
	b.WriteString("|---|---|---|---|---|---|\n")
	b.WriteString(rows.String())
	b.WriteString("\n")
	return b.String()
}

func taskRow(t *Task) string {
	poster := shortAddr(t.Poster)
	if av := agents.Get(t.Poster.String()); av != nil {
		poster = "[" + av.(*Agent).Name + "](" + link("agent/"+t.Poster.String()) + ")"
	} else {
		poster = "`" + poster + "`"
	}
	return "| " + strconv.Itoa(t.ID) + " | [" + t.Title + "](" + link("task/"+strconv.Itoa(t.ID)) + ") | " +
		t.Specialty + " | " + fmtUgnot(t.BudgetUgnot) + " | " + statusLabel(t.Status) + " | " + poster + " |\n"
}

func taskBidsTable(t *Task) string {
	prefix := padID(t.ID) + "/"
	var rows strings.Builder
	n := 0
	bids.Iterate(prefix, prefix+"~", func(_ string, v any) bool {
		b := v.(*Bid)
		name := agentName(b.Agent)
		mark := ""
		if t.WinningBidID == b.ID {
			mark = " **(accepted)**"
		}
		accept := ""
		if t.Status == StatusOpen {
			accept = " [Accept](" + txlink.NewLink("AcceptBid").AddArgs(
				"taskID", strconv.Itoa(t.ID),
				"bidID", strconv.Itoa(b.ID),
			).URL() + ")"
		}
		note := "—"
		if b.Note != "" {
			note = b.Note
		}
		rows.WriteString("| #" + strconv.Itoa(b.ID) + " | [" + name + "](" + link("agent/"+b.Agent.String()) + ")" + mark + " | " +
			fmtUgnot(b.Amount) + " | " + note + " |" + accept + " |\n")
		n++
		return false
	})
	if n == 0 {
		return "No bids yet.\n\n"
	}
	return "| Bid | Agent | Amount | Note | |\n|---|---|---|---|---|\n" + rows.String() + "\n"
}

func bidsByAgentTable(owner address) string {
	var rows strings.Builder
	n := 0
	// Walk bids and keep those from this agent (the board is size-capped).
	bids.Iterate("", "", func(_ string, v any) bool {
		b := v.(*Bid)
		if b.Agent != owner {
			return false
		}
		tv := tasks.Get(padID(b.TaskID))
		title := "task #" + strconv.Itoa(b.TaskID)
		status := ""
		if tv != nil {
			t := tv.(*Task)
			title = "[" + t.Title + "](" + link("task/"+strconv.Itoa(t.ID)) + ")"
			status = statusLabel(t.Status)
		}
		rows.WriteString("| #" + strconv.Itoa(b.ID) + " | " + title + " | " + fmtUgnot(b.Amount) + " | " + status + " |\n")
		n++
		return false
	})
	if n == 0 {
		return "This agent has not bid on any tasks yet.\n\n"
	}
	return "| Bid | Task | Amount | Task status |\n|---|---|---|---|\n" + rows.String() + "\n"
}

func posterLink(addr address) string {
	if agents.Get(addr.String()) != nil {
		return "[" + agentName(addr) + "](" + link("agent/"+addr.String()) + ")"
	}
	return "`" + shortAddr(addr) + "`"
}

func agentName(addr address) string {
	v := agents.Get(addr.String())
	if v == nil {
		return shortAddr(addr)
	}
	return v.(*Agent).Name
}

func statusLabel(s string) string {
	switch s {
	case StatusOpen:
		return "Open"
	case StatusInProgress:
		return "In progress"
	case StatusCompleted:
		return "Completed"
	case StatusCancelled:
		return "Cancelled"
	}
	return s
}

func pager(route string, page, total int) string {
	pages := (total + pageSize - 1) / pageSize
	if pages <= 1 {
		return ""
	}
	out := "Page " + strconv.Itoa(page) + " of " + strconv.Itoa(pages)
	if page > 1 {
		out += " · [Previous](" + link(route+"?page="+strconv.Itoa(page-1)) + ")"
	}
	if page < pages {
		out += " · [Next](" + link(route+"?page="+strconv.Itoa(page+1)) + ")"
	}
	return out + "\n"
}

func notFound() string {
	return "# Not found\n\n" + navBar()
}

func link(sub string) string {
	if sub == "" {
		return realmURL
	}
	return realmURL + ":" + sub
}

func pageParam(query string) int {
	for _, kv := range strings.Split(query, "&") {
		if strings.HasPrefix(kv, "page=") {
			p, err := strconv.Atoi(strings.TrimPrefix(kv, "page="))
			if err == nil && p >= 1 && p <= 100000 {
				return p
			}
		}
	}
	return 1
}

func shortAddr(a address) string {
	s := a.String()
	if len(s) <= 14 {
		return s
	}
	return s[:8] + "…" + s[len(s)-4:]
}

// fmtUgnot renders ugnot as a GNOT amount, e.g. 1500000 -> "1.5 GNOT".
func fmtUgnot(ugnot int64) string {
	neg := ugnot < 0
	if neg {
		ugnot = -ugnot
	}
	whole := ugnot / ugnotPerGnot
	frac := ugnot % ugnotPerGnot
	w := strconv.FormatInt(whole, 10)
	for i := len(w) - 3; i > 0; i -= 3 {
		w = w[:i] + "," + w[i:]
	}
	out := w
	if frac != 0 {
		f := strconv.FormatInt(frac, 10)
		for len(f) < 6 {
			f = "0" + f
		}
		for len(f) > 0 && f[len(f)-1] == '0' {
			f = f[:len(f)-1]
		}
		out = w + "." + f
	}
	if neg {
		out = "-" + out
	}
	return out + " GNOT"
}
