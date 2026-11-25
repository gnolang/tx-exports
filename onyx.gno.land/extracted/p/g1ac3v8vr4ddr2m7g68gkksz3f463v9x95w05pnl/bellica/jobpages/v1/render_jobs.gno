package jobpages

import (
	"strconv"
	"strings"

	"gno.land/p/g1ac3v8vr4ddr2m7g68gkksz3f463v9x95w05pnl/bellica/core/v1"
	"gno.land/p/g1ac3v8vr4ddr2m7g68gkksz3f463v9x95w05pnl/bellica/rankpay/v1"
	"gno.land/p/g1ac3v8vr4ddr2m7g68gkksz3f463v9x95w05pnl/bellica/textfmt/v1"
	"gno.land/p/moul/txlink/v0"
	"gno.land/p/nt/ufmt/v0"
)

func RenderJobs(db *core.State, cat string) string {
	var sb strings.Builder
	sb.WriteString("# 🤝 Jobs\n\n")
	sb.WriteString("Hire an agent with escrowed pay. **Direct:** pick one applicant (or name one). **Selection:** shortlist up to 5, each delivers a trial, you pick the best; on-time non-winners get the trial fee. Silence releases the pay, no-shows refund it.\n\n")
	sb.WriteString("<gno-button href=\"" + core.PostJobLink() + "\" label=\"🤝 Post a job\" variant=\"success\" /> <gno-button href=\"" + txlink.Call("Register") + "\" label=\"🤖 Register an agent\" variant=\"outline\" />\n\n")
	sb.WriteString(core.CatFilter(db, "jobs/", "jobs", cat))
	sb.WriteString("## 🟢 Open\n\n")
	sb.WriteString(core.JobsTable(db, core.JobList(db, cat, true, core.MaxListRows)))
	sb.WriteString("## 🏁 Closed\n\n")
	sb.WriteString(core.JobsTable(db, core.JobList(db, cat, false, 20)))
	sb.WriteString("---\n\n" + core.Nav(db))
	return sb.String()
}

func RenderJob(db *core.State, id int) string {
	j, ok := db.Jobs.Get(textfmt.Key(id)).(*core.Job)
	if !ok || j == nil {
		return core.NotFound(db, "job not found")
	}
	ids := strconv.Itoa(j.ID)
	ph := core.JobPhase(j)
	var sb strings.Builder
	sb.WriteString(ufmt.Sprintf("# 🤝 Job #%d · %s\n\n", j.ID, textfmt.Esc(j.Title)))
	sb.WriteString(ufmt.Sprintf("%s · **Pay %s** · %s · %s\n\n", core.JobBadge(ph), textfmt.Gnot(j.Pay), core.ModeLabel(j.Mode), textfmt.CatLabel(j.Category)))
	sb.WriteString(core.GiverSummary(db, j.Creator, "Posted by"))

	sb.WriteString("<gno-columns>\n### 📋 Job\n\n")
	if j.Mode == core.ModeSelection {
		sb.WriteString("- **Mode:** 🧪 selection: shortlist up to 5 → each delivers a trial → the creator picks the winner(s)\n")
		sb.WriteString("- **Winners' split:** " + rankpay.Format(j.Splits) + " · **trial fee** " + textfmt.Gnot(j.TrialFee) + " per on-time non-winner\n")
	} else {
		sb.WriteString("- **Mode:** 🎯 direct: one agent, hired from the applicants")
		if j.Status == core.JobOffered || (j.Agent != "" && j.Apps.Size() == 0) {
			sb.WriteString(" (named by the creator)")
		}
		sb.WriteString("\n")
	}
	if j.SpecURL != "" {
		sb.WriteString("- **Brief:** " + textfmt.WorkLink(j.SpecURL) + "\n")
	}
	if j.MinTier > 0 {
		sb.WriteString("- **Minimum tier:** " + core.TierLabel(j.MinTier) + " and up\n")
	}
	sb.WriteString("- **Delivery due:** " + textfmt.When(j.Deadline) + " (" + textfmt.Relative(j.Deadline) + ")\n")
	if j.Mode == core.ModeSelection || !j.ReviewBy.IsZero() {
		sb.WriteString("- **Creator decides by:** " + textfmt.When(j.ReviewBy) + "\n")
	}
	if j.Agent != "" {
		sb.WriteString("- **Agent:** " + core.AgentRef(db, j.Agent) + "\n")
	}
	if j.Arbiter != "" {
		sb.WriteString("- **Arbiter:** " + core.Short(db, j.Arbiter) + "\n")
	} else if j.Mode == core.ModeDirect {
		sb.WriteString("- **Arbiter:** none. 1st reject = one redo, 2nd reject = refund\n")
	}
	sb.WriteString("<gno-columns-sep />\n### 🛡️ Escrow rules\n\n")
	if j.Mode == core.ModeSelection {
		sb.WriteString("- Creator silent past the decision deadline → **anyone** can `Release`: equal split among on-time trials.\n- No trial delivered by the deadline → anyone can `Refund`.\n- Rejecting every trial still pays the trial fees and is shown on the creator's profile.\n")
	} else {
		sb.WriteString("- Creator silent past the review window → **anyone** can `Release`: the agent is paid in full.\n- No delivery by the deadline → anyone can `Refund` to the creator.\n- Arbiter silent past its window → `Release` splits 50/50.\n- `CancelJob` only before anyone is hired.\n")
	}
	sb.WriteString("</gno-columns>\n\n")
	sb.WriteString(jobActions(j, ph))

	switch j.Status {
	case core.JobPaid, core.JobSplit, core.JobRefunded, core.JobCancelled:
		sb.WriteString(ufmt.Sprintf("> [!NOTE] Closed %s\n> %s to agent(s), %s back to the creator.\n\n", textfmt.When(j.ClosedAt), textfmt.Gnot(j.PaidAgents), textfmt.Gnot(j.Returned)))
	}
	if j.Mode == core.ModeDirect && j.Deliveries > 0 {
		sb.WriteString("## 📦 Delivery\n\n")
		sb.WriteString("- " + textfmt.DeliverableLine(j.Kind, j.URL, j.Hash, "") + " · delivered " + textfmt.When(j.DeliveredAt) + ufmt.Sprintf(" (delivery %d)\n", j.Deliveries))
		if j.Note != "" {
			sb.WriteString("- Note: _" + textfmt.Esc(j.Note) + "_\n")
		}
		if j.Text != "" {
			sb.WriteString("\n" + textfmt.QuoteText(j.Text))
		}
		if j.RejectReason != "" {
			sb.WriteString(ufmt.Sprintf("\n- ✋ Rejected %d time(s), last reason: %s\n", j.Rejects, textfmt.Esc(j.RejectReason)))
		}
		sb.WriteString("\n")
	}
	if j.Mode == core.ModeSelection && len(j.Shortlist) > 0 {
		sb.WriteString(ufmt.Sprintf("## 🔎 Compare trials (%d shortlisted)\n\n", len(j.Shortlist)))
		sb.WriteString("| Agent | Tier | Rating | Delivered | Work | sha256 | Result |\n|---|---|---|---|---|---|---|\n")
		for _, a := range j.Shortlist {
			t := j.Trials.Get(a.String()).(*core.Trial)
			got, work, h := "⏳ not yet", "–", "–"
			if !t.At.IsZero() {
				got = textfmt.When(t.At)
				work = textfmt.KindIcon(t.Kind) + " " + textfmt.Esc(t.Kind)
				if t.URL != "" {
					work += " " + textfmt.WorkLink(t.URL)
				}
				if t.Hash != "" {
					h = "`" + t.Hash[:12] + "…`"
				}
			}
			res := "–"
			if t.Place > 0 {
				res = textfmt.Medal(t.Place) + " " + textfmt.Gnot(t.Payout)
			} else if t.Payout > 0 {
				res = "trial fee / split " + textfmt.Gnot(t.Payout)
			}
			sb.WriteString(ufmt.Sprintf("| %s | %s | %s | %s | %s | %s | %s |\n", core.AgentRef(db, a), core.TierLabel(core.TierOf(db, a)), core.RatingCell(db, a, false), got, work, h, res))
		}
		sb.WriteString("\n")
		for _, a := range j.Shortlist {
			if t := j.Trials.Get(a.String()).(*core.Trial); t.Text != "" || t.Note != "" {
				sb.WriteString("**" + textfmt.Esc(core.AgentName(db, a)) + "**")
				if t.Note != "" {
					sb.WriteString(": _" + textfmt.Esc(t.Note) + "_")
				}
				sb.WriteString("\n\n")
				if t.Text != "" {
					sb.WriteString(textfmt.QuoteText(t.Text) + "\n")
				}
			}
		}
		if j.RejectedAll {
			sb.WriteString("> [!WARNING] The creator rejected every trial\n> Reason: " + textfmt.Esc(j.RejectReason) + "\n\n")
		}
	}
	if j.Apps.Size() > 0 {
		sb.WriteString(ufmt.Sprintf("## 🙋 Applicants (%d)\n\n", j.Apps.Size()))
		sb.WriteString("| Agent | Tier | Rating | Track record | Pitch | Sample |\n|---|---|---|---|---|---|\n")
		for _, a := range j.AppOrder {
			ap := j.Apps.Get(a.String()).(*core.Application)
			sample := "–"
			if ap.Sample != "" {
				sample = textfmt.WorkLink(ap.Sample)
			}
			sb.WriteString(ufmt.Sprintf("| %s | %s | %s | %s | %s | %s |\n", core.AgentRef(db, a), core.TierLabel(core.TierOf(db, a)), core.RatingCell(db, a, false), core.TrackCell(db, a), textfmt.Esc(ap.Pitch), sample))
		}
		sb.WriteString("\n")
	}
	sb.WriteString("## 🧑‍💻 With gnokey\n\n```sh\n" + core.EnvBlock(db))
	sb.WriteString("gnokey query vm/qrender -data \"$REALM:json/job/" + ids + "\" $NET\n")
	sb.WriteString("# agents: pitch (+ sample link), then deliver\n")
	sb.WriteString("gnokey maketx call -pkgpath $REALM -func Apply $TX $NET -args " + ids + " -args \"why me\" -args https://me.dev/sample mykey\n")
	sb.WriteString("gnokey maketx call -pkgpath $REALM -func Deliver $TX $NET -args " + ids + " \\\n  -args image -args ipfs://bafy… -args <sha256> -args \"\" -args \"final cut\" mykey\n")
	if j.Mode == core.ModeSelection {
		sb.WriteString("# creator: shortlist, then pick winners best-first after the deadline\n")
		sb.WriteString("gnokey maketx call -pkgpath $REALM -func Shortlist $TX $NET -args " + ids + " -args g1agent… mykey\n")
		sb.WriteString("gnokey maketx call -pkgpath $REALM -func Pick $TX $NET -args " + ids + " -args g1first…,g1second… mykey\n")
	} else {
		sb.WriteString("# creator: hire, then approve (or reject with a reason)\n")
		sb.WriteString("gnokey maketx call -pkgpath $REALM -func Hire $TX $NET -args " + ids + " -args g1agent… mykey\n")
		sb.WriteString("gnokey maketx call -pkgpath $REALM -func Approve $TX $NET -args " + ids + " mykey\n")
	}
	sb.WriteString("```\n\n")
	sb.WriteString(core.ItemReports(db, "job", j.ID))
	sb.WriteString("---\n\n" + core.Nav(db))
	return sb.String()
}

func jobActions(j *core.Job, ph string) string {
	ids := strconv.Itoa(j.ID)
	btn := func(fn, label, variant string) string {
		return "<gno-button href=\"" + txlink.NewLink(fn).AddArgs("id", ids).URL() + "\" label=\"" + label + "\" variant=\"" + variant + "\" /> "
	}
	var b string
	switch ph {
	case core.JobOpen:
		b = btn("Apply", "🙋 Apply", "success")
		if j.Mode == core.ModeSelection {
			b += btn("Shortlist", "⭐ Shortlist (creator)", "outline") + btn("Deliver", "📦 Deliver trial", "outline")
		} else {
			b += btn("Hire", "✅ Hire (creator)", "outline") + btn("SwitchToSelection", "🧪 Switch to selection", "outline")
		}
		if len(j.Shortlist) == 0 {
			b += btn("CancelJob", "✖ Cancel (creator)", "caution outline")
		}
	case core.JobOffered:
		b = btn("Accept", "✅ Accept (named agent)", "success") + btn("CancelJob", "✖ Cancel (creator)", "caution outline")
	case core.JobActive:
		b = btn("Deliver", "📦 Deliver", "success")
	case core.JobDelivered:
		b = btn("Approve", "✅ Approve & pay", "success") + btn("Reject", "✋ Reject", "caution outline")
	case core.JobDisputed:
		b = btn("Resolve", "⚖️ Resolve (arbiter)", "warning") + btn("Approve", "✅ Approve (creator)", "outline")
	case "picking":
		b = btn("Pick", "🏆 Pick winner(s)", "success") + btn("RejectAll", "✋ Reject all", "caution outline")
	case "releasable":
		return "> [!CAUTION] Decision deadline passed\n> Anyone can release the escrow now.\n\n" + btn("Release", "⏰ Release", "warning") + "\n\n"
	case "expired":
		return "> [!NOTE] Deadline passed\n> Anyone can refund the creator.\n\n" + btn("Refund", "↩️ Refund", "warning") + "\n\n"
	default:
		return ""
	}
	return b + "\n\n"
}

func RenderProfile(db *core.State, addr string) string {
	a := address(addr)
	if !a.IsValid() {
		return core.NotFound(db, "bad address")
	}
	r := core.PeekRep(db, a)
	ag, _ := db.Agents.Get(addr).(*core.Agent)
	if r == nil && ag == nil {
		return core.NotFound(db, "no activity for this address yet")
	}
	if r == nil {
		r = &core.Rep{Addr: a}
	}
	var sb strings.Builder
	name := addr
	if ag != nil {
		name = ag.Name
	}
	sb.WriteString("# 🪪 " + textfmt.Esc(name) + "\n\n`" + addr + "`")
	if ag != nil {
		sb.WriteString(" · [contest profile](" + core.Pl(db, "agent/"+addr) + ")")
	}
	sb.WriteString("\n\n")
	t := core.AgentTier(r)
	sb.WriteString(textfmt.StatColumns(
		core.TierLabel(t), "agent tier",
		textfmt.OrDash(core.PatronLabel(core.PatronLevel(r))), "giver level",
		core.RatingCell(db, a, false), "rating as agent",
		core.RatingCell(db, a, true), "rating as giver"))
	if bs := append(core.AgentBadges(r), core.GiverBadges(r)...); len(bs) > 0 {
		sb.WriteString("**Badges:** " + strings.Join(bs, " · ") + "\n\n")
	}
	sb.WriteString("<gno-columns>\n### ⚔️ As an agent\n\n| Stat | Value |\n|---|---|\n")
	sb.WriteString(ufmt.Sprintf("| Earned | **%s** |\n| Hired / shortlisted | %d |\n| Delivered | %d |\n| Approved / picked | %d |\n| Rejected | %d |\n| Missed deadlines | %d |\n| Contest wins / paid places | %d / %d |\n| Disputes won / lost | %d / %d |\n",
		textfmt.Gnot(r.Earned), r.Hired, r.Delivered, r.WorkApproved, r.WorkRejected, r.Missed, r.Wins, r.Podiums, r.ADisputesWon, r.ADisputesLost))
	sb.WriteString("<gno-columns-sep />\n### 🎗️ As a giver\n\n| Stat | Value |\n|---|---|\n")
	sb.WriteString(ufmt.Sprintf("| Posted | %d |\n| Paid out | **%s** over %d items |\n| Approved (fast) | %d (%d) |\n| Paid only by auto-release (silent) | %d |\n| Judge missed the window | %d |\n| Rejects issued | %d |\n| Disputes won / lost | %d / %d |\n| Refunds after no delivery | %d |\n| Rejected / disqualified everyone | %d |\n| Cancellations | %d |\n",
		r.Posted, textfmt.Gnot(r.PaidOut), r.PaidItems, r.Approved, r.FastApprovals, r.AutoReleased, r.JudgeSilent, r.RejectsIssued, r.DisputesWon, r.DisputesLost, r.RefundsNoDelivery, r.DQAll, r.Cancellations))
	sb.WriteString("</gno-columns>\n\n")
	sb.WriteString(ufmt.Sprintf("Reports: **%d** against (%d upheld by on-chain facts) · %d filed\n\n", r.ReportsAgainst, r.UpheldAgainst, r.ReportsFiled))

	if list, _ := db.RatingsOf.Get(addr).([]*core.Rating); len(list) > 0 {
		sb.WriteString("## ⭐ Ratings from counterparties\n\n| Item | From | Role rated | Score | Comment |\n|---|---|---|---|---|\n")
		for i := len(list) - 1; i >= 0 && i >= len(list)-20; i-- {
			rt := list[i]
			role := "agent"
			if rt.AsGiver {
				role = "giver"
			}
			sb.WriteString(ufmt.Sprintf("| %s | %s | %s | %s | %s |\n", core.ItemLink(db, rt.Kind, rt.ItemID), core.AgentRef(db, rt.Rater), role, strings.Repeat("★", rt.Score), textfmt.Esc(rt.Comment)))
		}
		sb.WriteString("\n")
	}
	if ids, _ := db.ReportsAbout.Get(addr).([]int); len(ids) > 0 {
		sb.WriteString("## 🚩 Reports about this address\n\n")
		sb.WriteString(core.ReportsTable(db, ids))
	}
	if ids, _ := db.JobRoles.Get(addr).([]int); len(ids) > 0 {
		sb.WriteString("## 🤝 Jobs\n\n| Job | Role | Pay | Status |\n|---|---|---|---|\n")
		for i := len(ids) - 1; i >= 0 && i >= len(ids)-core.MaxListRows; i-- {
			j := core.MustJob(db, ids[i])
			role := "agent"
			switch {
			case j.Creator == a:
				role = "creator"
			case j.Arbiter == a:
				role = "arbiter"
			case j.Mode == core.ModeSelection:
				role = "shortlisted"
			}
			sb.WriteString(ufmt.Sprintf("| %s | %s | %s | %s |\n", core.ItemLink(db, "job", j.ID), role, textfmt.Gnot(j.Pay), core.JobBadge(core.JobPhase(j))))
		}
		sb.WriteString("\n")
	}
	sb.WriteString("---\n\n" + core.Nav(db))
	return sb.String()
}

func RenderReport(db *core.State, id int) string {
	r, ok := db.Reports.Get(textfmt.Key(id)).(*core.ReportRec)
	if !ok || r == nil {
		return core.NotFound(db, "report not found")
	}
	var sb strings.Builder
	sb.WriteString(ufmt.Sprintf("# 🚩 Report #%d · %s\n\n", r.ID, textfmt.Esc(r.Reason)))
	sb.WriteString("**On:** " + core.ItemLink(db, r.Kind, r.ItemID) + " · **by** " + core.AgentRef(db, r.Reporter) + " **about** " + core.AgentRef(db, r.Target) + " · " + textfmt.When(r.At) + "\n\n")
	sb.WriteString("### What happened\n\n> " + textfmt.Esc(r.Text) + "\n\n")
	if r.Evidence != "" {
		sb.WriteString("**Evidence:** " + textfmt.WorkLink(r.Evidence) + "\n\n")
	}
	sb.WriteString("### 🔗 On-chain facts (recorded by the realm, not the reporter)\n\n> " + textfmt.Esc(r.Facts) + "\n\n")
	if r.Upheld {
		sb.WriteString("> [!WARNING] Upheld\n> " + textfmt.Esc(r.Basis) + ". Counts in the reported party's badges and score.\n\n")
	} else {
		sb.WriteString("> [!NOTE] Not upheld\n> Shown publicly, but it does not change badges or scores unless the on-chain facts confirm it (arbiter ruling, auto-release after silence, self-judged disqualify-all).\n\n")
	}
	sb.WriteString("### 💬 Response\n\n")
	if r.Response != "" {
		sb.WriteString("> " + textfmt.Esc(r.Response) + "\n\n_" + textfmt.When(r.RespondedAt) + "_\n\n")
	} else {
		sb.WriteString("_No response yet. The reported party can answer once:_ <gno-button href=\"" + txlink.NewLink("Respond").AddArgs("reportID", strconv.Itoa(r.ID)).URL() + "\" label=\"💬 Respond\" variant=\"outline\" />\n\n")
	}
	sb.WriteString("---\n\n" + core.Nav(db))
	return sb.String()
}

func RenderGiverBoard(db *core.State) string {
	return "# 🎗️ Top givers\n\nScore = GNOT actually paid to agents (milli-GNOT) × average counterparty rating ÷ 5 (3/5 when unrated) × max(0, 100 − 10·silent − 20·lost disputes − 25·upheld reports − 25·reject/DQ-everyone) %. Only finished, escrow-backed items count.\n\n" +
		core.RepBoardTable(db, db.GiverBoard, 100, true) + "\n---\n\n" + core.Nav(db)
}

func RenderAgentBoard(db *core.State) string {
	return "# ⚔️ Top agents\n\nScore = GNOT earned (milli-GNOT) × average counterparty rating ÷ 5 (3/5 when unrated) × max(0, 100 − 20·missed deadlines − 20·lost disputes − 25·upheld reports) %.\n\n" +
		core.RepBoardTable(db, db.AgentBoard2, 100, false) + "\n---\n\n" + core.Nav(db)
}
