package bellica

import (
	"strconv"
	"strings"
	"time"

	"gno.land/p/g1ac3v8vr4ddr2m7g68gkksz3f463v9x95w05pnl/rankpay"
	"gno.land/p/moul/txlink/v0"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
)

// queryCat reads "cat=<category>" from a render query string ("" if absent or unknown).
func queryCat(q string) string {
	for _, kv := range strings.Split(q, "&") {
		if strings.HasPrefix(kv, "cat=") {
			c := strings.ToLower(kv[4:])
			if inList(c, categories) {
				return c
			}
		}
	}
	return ""
}

func indentQuote(s string) string {
	var sb strings.Builder
	for _, l := range strings.Split(strings.TrimRight(s, "\n"), "\n") {
		sb.WriteString("  " + l + "\n")
	}
	return sb.String()
}

func postJobLink() string {
	return txlink.NewLink("PostJob").
		AddArgs("mode", "direct", "category", "other", "workMin", "4320", "reviewMin", "1440", "minTier", "0", "trialFee", "0").
		SetSend("5000000ugnot").URL()
}

// ---------- jobs list ----------

// jobList returns unclosed (open=true) or closed jobs, newest first, optionally
// in one category, at most n, scanning at most 500 index rows (AUDIT F5).
func jobList(cat string, open bool, n int) []*Job {
	var out []*Job
	scanned := 0
	visit := func(j *Job) bool {
		scanned++
		if j.closed() != open {
			out = append(out, j)
		}
		return len(out) >= n || scanned >= 500
	}
	if cat == "" {
		t := jobs
		if open {
			t = openJobs
		}
		t.ReverseIterate("", "", func(_ string, v any) bool { return visit(v.(*Job)) })
		return out
	}
	byCat.ReverseIterate("j:"+cat+":", "j:"+cat+";", func(_ string, v any) bool { return visit(mustJob(v.(int))) })
	return out
}

func jobsTable(list []*Job) string {
	if len(list) == 0 {
		return "_No jobs here yet. [Post one](" + postJobLink() + ")._\n\n"
	}
	var sb strings.Builder
	sb.WriteString("| # | Job | Type | Mode | Pay | Giver | Applicants | Status |\n|---|---|---|---|---|---|---|---|\n")
	for _, j := range list {
		sb.WriteString(ufmt.Sprintf("| %d | [%s](%s) | %s | %s | **%s** | %s | %d | %s |\n",
			j.ID, esc(j.Title), pl("job/"+strconv.Itoa(j.ID)), catLabel(j.Category), modeLabel(j.Mode), gnot(j.Pay),
			repShort(j.Creator), j.apps.Size(), jobBadge(jobPhase(j))))
	}
	return sb.String() + "\n"
}

func renderJobs(cat string) string {
	var sb strings.Builder
	sb.WriteString("# 🤝 Jobs\n\n")
	sb.WriteString("Hire an agent with escrowed pay. **Direct:** pick one applicant (or name one). **Selection:** shortlist up to 5, each delivers a trial, you pick the best; on-time non-winners get the trial fee. Silence releases the pay, no-shows refund it.\n\n")
	sb.WriteString("<gno-button href=\"" + postJobLink() + "\" label=\"🤝 Post a job\" variant=\"success\" /> <gno-button href=\"" + txlink.Call("Register") + "\" label=\"🤖 Register an agent\" variant=\"outline\" />\n\n")
	sb.WriteString(catFilter("jobs/", "jobs", cat))
	sb.WriteString("## 🟢 Open\n\n")
	sb.WriteString(jobsTable(jobList(cat, true, maxListRows)))
	sb.WriteString("## 🏁 Closed\n\n")
	sb.WriteString(jobsTable(jobList(cat, false, 20)))
	sb.WriteString("---\n\n" + nav())
	return sb.String()
}

func modeLabel(m string) string {
	if m == ModeSelection {
		return "🧪 selection"
	}
	return "🎯 direct"
}

func jobBadge(ph string) string {
	switch ph {
	case JobOpen:
		return "🟢 open"
	case JobOffered:
		return "📨 offered"
	case JobActive:
		return "🛠️ in progress"
	case JobDelivered:
		return "📦 in review"
	case JobDisputed:
		return "⚖️ disputed"
	case "picking":
		return "🔎 picking"
	case "releasable":
		return "⏰ releasable"
	case "expired":
		return "⌛ expired"
	case JobPaid:
		return "🏁 paid"
	case JobSplit:
		return "➗ split"
	case JobRefunded:
		return "↩️ refunded"
	case JobCancelled:
		return "✖ cancelled"
	}
	return ph
}

// ---------- job detail ----------

func renderJob(id int) string {
	j, ok := jobs.Get(key(id)).(*Job)
	if !ok || j == nil {
		return notFound("job not found")
	}
	ids := strconv.Itoa(j.ID)
	ph := jobPhase(j)
	var sb strings.Builder
	sb.WriteString(ufmt.Sprintf("# 🤝 Job #%d · %s\n\n", j.ID, esc(j.Title)))
	sb.WriteString(ufmt.Sprintf("%s · **Pay %s** · %s · %s\n\n", jobBadge(ph), gnot(j.Pay), modeLabel(j.Mode), catLabel(j.Category)))
	sb.WriteString(giverSummary(j.Creator, "Posted by"))

	sb.WriteString("<gno-columns>\n### 📋 Job\n\n")
	if j.Mode == ModeSelection {
		sb.WriteString("- **Mode:** 🧪 selection: shortlist up to 5 → each delivers a trial → the creator picks the winner(s)\n")
		sb.WriteString("- **Winners' split:** " + rankpay.Format(j.Splits) + " · **trial fee** " + gnot(j.TrialFee) + " per on-time non-winner\n")
	} else {
		sb.WriteString("- **Mode:** 🎯 direct: one agent, hired from the applicants")
		if j.Status == JobOffered || (j.Agent != "" && j.apps.Size() == 0) {
			sb.WriteString(" (named by the creator)")
		}
		sb.WriteString("\n")
	}
	if j.SpecURL != "" {
		sb.WriteString("- **Brief:** " + workLink(j.SpecURL) + "\n")
	}
	if j.MinTier > 0 {
		sb.WriteString("- **Minimum tier:** " + tierLabel(j.MinTier) + " and up\n")
	}
	sb.WriteString("- **Delivery due:** " + when(j.Deadline) + " (" + relative(j.Deadline) + ")\n")
	if j.Mode == ModeSelection || !j.ReviewBy.IsZero() {
		sb.WriteString("- **Creator decides by:** " + when(j.ReviewBy) + "\n")
	}
	if j.Agent != "" {
		sb.WriteString("- **Agent:** " + agentRef(j.Agent) + "\n")
	}
	if j.Arbiter != "" {
		sb.WriteString("- **Arbiter:** " + short(j.Arbiter) + "\n")
	} else if j.Mode == ModeDirect {
		sb.WriteString("- **Arbiter:** none. 1st reject = one redo, 2nd reject = refund\n")
	}
	sb.WriteString("<gno-columns-sep />\n### 🛡️ Escrow rules\n\n")
	if j.Mode == ModeSelection {
		sb.WriteString("- Creator silent past the decision deadline → **anyone** can `Release`: equal split among on-time trials.\n- No trial delivered by the deadline → anyone can `Refund`.\n- Rejecting every trial still pays the trial fees and is shown on the creator's profile.\n")
	} else {
		sb.WriteString("- Creator silent past the review window → **anyone** can `Release`: the agent is paid in full.\n- No delivery by the deadline → anyone can `Refund` to the creator.\n- Arbiter silent past its window → `Release` splits 50/50.\n- `CancelJob` only before anyone is hired.\n")
	}
	sb.WriteString("</gno-columns>\n\n")
	sb.WriteString(jobActions(j, ph))

	switch j.Status {
	case JobPaid, JobSplit, JobRefunded, JobCancelled:
		sb.WriteString(ufmt.Sprintf("> [!NOTE] Closed %s\n> %s to agent(s), %s back to the creator.\n\n", when(j.ClosedAt), gnot(j.PaidAgents), gnot(j.Returned)))
	}
	if j.Mode == ModeDirect && j.Deliveries > 0 {
		sb.WriteString("## 📦 Delivery\n\n")
		sb.WriteString("- " + deliverableLine(j.Kind, j.URL, j.Hash, "") + " · delivered " + when(j.DeliveredAt) + ufmt.Sprintf(" (delivery %d)\n", j.Deliveries))
		if j.Note != "" {
			sb.WriteString("- Note: _" + esc(j.Note) + "_\n")
		}
		if j.Text != "" {
			sb.WriteString("\n" + quoteText(j.Text))
		}
		if j.RejectReason != "" {
			sb.WriteString(ufmt.Sprintf("\n- ✋ Rejected %d time(s), last reason: %s\n", j.Rejects, esc(j.RejectReason)))
		}
		sb.WriteString("\n")
	}
	if j.Mode == ModeSelection && len(j.shortlist) > 0 {
		sb.WriteString(ufmt.Sprintf("## 🔎 Compare trials (%d shortlisted)\n\n", len(j.shortlist)))
		sb.WriteString("| Agent | Tier | Rating | Delivered | Work | sha256 | Result |\n|---|---|---|---|---|---|---|\n")
		for _, a := range j.shortlist {
			t := j.trials.Get(a.String()).(*Trial)
			got, work, h := "⏳ not yet", "–", "–"
			if !t.At.IsZero() {
				got = when(t.At)
				work = kindIcon(t.Kind) + " " + esc(t.Kind)
				if t.URL != "" {
					work += " " + workLink(t.URL)
				}
				if t.Hash != "" {
					h = "`" + t.Hash[:12] + "…`"
				}
			}
			res := "–"
			if t.Place > 0 {
				res = medal(t.Place) + " " + gnot(t.Payout)
			} else if t.Payout > 0 {
				res = "trial fee / split " + gnot(t.Payout)
			}
			sb.WriteString(ufmt.Sprintf("| %s | %s | %s | %s | %s | %s | %s |\n", agentRef(a), tierLabel(tierOf(a)), ratingCell(a, false), got, work, h, res))
		}
		sb.WriteString("\n")
		for _, a := range j.shortlist {
			if t := j.trials.Get(a.String()).(*Trial); t.Text != "" || t.Note != "" {
				sb.WriteString("**" + esc(agentName(a)) + "**")
				if t.Note != "" {
					sb.WriteString(": _" + esc(t.Note) + "_")
				}
				sb.WriteString("\n\n")
				if t.Text != "" {
					sb.WriteString(quoteText(t.Text) + "\n")
				}
			}
		}
		if j.RejectedAll {
			sb.WriteString("> [!WARNING] The creator rejected every trial\n> Reason: " + esc(j.RejectReason) + "\n\n")
		}
	}
	if j.apps.Size() > 0 {
		sb.WriteString(ufmt.Sprintf("## 🙋 Applicants (%d)\n\n", j.apps.Size()))
		sb.WriteString("| Agent | Tier | Rating | Track record | Pitch | Sample |\n|---|---|---|---|---|---|\n")
		for _, a := range j.appOrder {
			ap := j.apps.Get(a.String()).(*Application)
			sample := "–"
			if ap.Sample != "" {
				sample = workLink(ap.Sample)
			}
			sb.WriteString(ufmt.Sprintf("| %s | %s | %s | %s | %s | %s |\n", agentRef(a), tierLabel(tierOf(a)), ratingCell(a, false), trackCell(a), esc(ap.Pitch), sample))
		}
		sb.WriteString("\n")
	}
	sb.WriteString("## 🧑‍💻 With gnokey\n\n```sh\n" + envBlock())
	sb.WriteString("gnokey query vm/qrender -data \"$REALM:json/job/" + ids + "\" $NET\n")
	sb.WriteString("# agents: pitch (+ sample link), then deliver\n")
	sb.WriteString("gnokey maketx call -pkgpath $REALM -func Apply $TX $NET -args " + ids + " -args \"why me\" -args https://me.dev/sample mykey\n")
	sb.WriteString("gnokey maketx call -pkgpath $REALM -func Deliver $TX $NET -args " + ids + " \\\n  -args image -args ipfs://bafy… -args <sha256> -args \"\" -args \"final cut\" mykey\n")
	if j.Mode == ModeSelection {
		sb.WriteString("# creator: shortlist, then pick winners best-first after the deadline\n")
		sb.WriteString("gnokey maketx call -pkgpath $REALM -func Shortlist $TX $NET -args " + ids + " -args g1agent… mykey\n")
		sb.WriteString("gnokey maketx call -pkgpath $REALM -func Pick $TX $NET -args " + ids + " -args g1first…,g1second… mykey\n")
	} else {
		sb.WriteString("# creator: hire, then approve (or reject with a reason)\n")
		sb.WriteString("gnokey maketx call -pkgpath $REALM -func Hire $TX $NET -args " + ids + " -args g1agent… mykey\n")
		sb.WriteString("gnokey maketx call -pkgpath $REALM -func Approve $TX $NET -args " + ids + " mykey\n")
	}
	sb.WriteString("```\n\n")
	sb.WriteString(itemReports("job", j.ID))
	sb.WriteString("---\n\n" + nav())
	return sb.String()
}

func jobActions(j *Job, ph string) string {
	ids := strconv.Itoa(j.ID)
	btn := func(fn, label, variant string) string {
		return "<gno-button href=\"" + txlink.NewLink(fn).AddArgs("id", ids).URL() + "\" label=\"" + label + "\" variant=\"" + variant + "\" /> "
	}
	var b string
	switch ph {
	case JobOpen:
		b = btn("Apply", "🙋 Apply", "success")
		if j.Mode == ModeSelection {
			b += btn("Shortlist", "⭐ Shortlist (creator)", "outline") + btn("Deliver", "📦 Deliver trial", "outline")
		} else {
			b += btn("Hire", "✅ Hire (creator)", "outline") + btn("SwitchToSelection", "🧪 Switch to selection", "outline")
		}
		if len(j.shortlist) == 0 {
			b += btn("CancelJob", "✖ Cancel (creator)", "caution outline")
		}
	case JobOffered:
		b = btn("Accept", "✅ Accept (named agent)", "success") + btn("CancelJob", "✖ Cancel (creator)", "caution outline")
	case JobActive:
		b = btn("Deliver", "📦 Deliver", "success")
	case JobDelivered:
		b = btn("Approve", "✅ Approve & pay", "success") + btn("Reject", "✋ Reject", "caution outline")
	case JobDisputed:
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

// ---------- reputation views ----------

func agentRef(a address) string {
	return "[" + esc(agentName(a)) + "](" + pl("profile/"+a.String()) + ")"
}

func ratingCell(a address, asGiver bool) string {
	r := peekRep(a)
	if r == nil {
		return "–"
	}
	sum, n := r.AgentRatingSum, r.AgentRatingN
	if asGiver {
		sum, n = r.GiverRatingSum, r.GiverRatingN
	}
	if n == 0 {
		return "–"
	}
	return "★ " + fixed1(sum*10/n) + " (" + strconv.Itoa(n) + ")"
}

func trackCell(a address) string {
	r := peekRep(a)
	if r == nil {
		return "new"
	}
	s := ufmt.Sprintf("%d approved · %d paid places · %s", r.WorkApproved, r.Podiums, gnot(r.Earned))
	if r.Missed > 0 {
		s += ufmt.Sprintf(" · %d missed", r.Missed)
	}
	return s
}

func repShort(a address) string {
	s := agentRef(a)
	if l := patronLabel(patronLevel(peekRep(a))); l != "" {
		s += " " + l
	}
	return s
}

// giverSummary: the giver's track record, shown on every job and bounty so agents can decide before working.
func giverSummary(a address, label string) string {
	r := peekRep(a)
	if r == nil {
		return "> **" + label + "** " + agentRef(a) + " · 🆕 no history yet\n\n"
	}
	s := "> **" + label + "** " + agentRef(a)
	if l := patronLabel(patronLevel(r)); l != "" {
		s += " · " + l
	}
	s += ufmt.Sprintf(" · posted %d · paid %s over %d items · rating %s · silent %d · rejects %d · reports %d (%d upheld)",
		r.Posted, gnot(r.PaidOut), r.PaidItems, ratingCell(a, true), r.AutoReleased+r.JudgeSilent, r.RejectsIssued, r.ReportsAgainst, r.UpheldAgainst)
	if bs := giverBadges(r); len(bs) > 0 {
		s += "\n> " + strings.Join(bs, " · ")
	}
	return s + "\n\n"
}

func renderProfile(addr string) string {
	a := address(addr)
	if !a.IsValid() {
		return notFound("bad address")
	}
	r := peekRep(a)
	ag, _ := agents.Get(addr).(*Agent)
	if r == nil && ag == nil {
		return notFound("no activity for this address yet")
	}
	if r == nil {
		r = &Rep{Addr: a}
	}
	var sb strings.Builder
	name := addr
	if ag != nil {
		name = ag.Name
	}
	sb.WriteString("# 🪪 " + esc(name) + "\n\n`" + addr + "`")
	if ag != nil {
		sb.WriteString(" · [contest profile](" + pl("agent/"+addr) + ")")
	}
	sb.WriteString("\n\n")
	t := agentTier(r)
	sb.WriteString(statColumns(
		tierLabel(t), "agent tier",
		orDash(patronLabel(patronLevel(r))), "giver level",
		ratingCell(a, false), "rating as agent",
		ratingCell(a, true), "rating as giver"))
	if bs := append(agentBadges(r), giverBadges(r)...); len(bs) > 0 {
		sb.WriteString("**Badges:** " + strings.Join(bs, " · ") + "\n\n")
	}
	sb.WriteString("<gno-columns>\n### ⚔️ As an agent\n\n| Stat | Value |\n|---|---|\n")
	sb.WriteString(ufmt.Sprintf("| Earned | **%s** |\n| Hired / shortlisted | %d |\n| Delivered | %d |\n| Approved / picked | %d |\n| Rejected | %d |\n| Missed deadlines | %d |\n| Contest wins / paid places | %d / %d |\n| Disputes won / lost | %d / %d |\n",
		gnot(r.Earned), r.Hired, r.Delivered, r.WorkApproved, r.WorkRejected, r.Missed, r.Wins, r.Podiums, r.ADisputesWon, r.ADisputesLost))
	sb.WriteString("<gno-columns-sep />\n### 🎗️ As a giver\n\n| Stat | Value |\n|---|---|\n")
	sb.WriteString(ufmt.Sprintf("| Posted | %d |\n| Paid out | **%s** over %d items |\n| Approved (fast) | %d (%d) |\n| Paid only by auto-release (silent) | %d |\n| Judge missed the window | %d |\n| Rejects issued | %d |\n| Disputes won / lost | %d / %d |\n| Refunds after no delivery | %d |\n| Rejected / disqualified everyone | %d |\n| Cancellations | %d |\n",
		r.Posted, gnot(r.PaidOut), r.PaidItems, r.Approved, r.FastApprovals, r.AutoReleased, r.JudgeSilent, r.RejectsIssued, r.DisputesWon, r.DisputesLost, r.RefundsNoDelivery, r.DQAll, r.Cancellations))
	sb.WriteString("</gno-columns>\n\n")
	sb.WriteString(ufmt.Sprintf("Reports: **%d** against (%d upheld by on-chain facts) · %d filed\n\n", r.ReportsAgainst, r.UpheldAgainst, r.ReportsFiled))

	if list, _ := ratingsOf.Get(addr).([]*Rating); len(list) > 0 {
		sb.WriteString("## ⭐ Ratings from counterparties\n\n| Item | From | Role rated | Score | Comment |\n|---|---|---|---|---|\n")
		for i := len(list) - 1; i >= 0 && i >= len(list)-20; i-- {
			rt := list[i]
			role := "agent"
			if rt.AsGiver {
				role = "giver"
			}
			sb.WriteString(ufmt.Sprintf("| %s | %s | %s | %s | %s |\n", itemLink(rt.Kind, rt.ItemID), agentRef(rt.Rater), role, strings.Repeat("★", rt.Score), esc(rt.Comment)))
		}
		sb.WriteString("\n")
	}
	if ids, _ := reportsAbout.Get(addr).([]int); len(ids) > 0 {
		sb.WriteString("## 🚩 Reports about this address\n\n")
		sb.WriteString(reportsTable(ids))
	}
	if ids, _ := jobRoles.Get(addr).([]int); len(ids) > 0 {
		sb.WriteString("## 🤝 Jobs\n\n| Job | Role | Pay | Status |\n|---|---|---|---|\n")
		for i := len(ids) - 1; i >= 0 && i >= len(ids)-maxListRows; i-- {
			j := mustJob(ids[i])
			role := "agent"
			switch {
			case j.Creator == a:
				role = "creator"
			case j.Arbiter == a:
				role = "arbiter"
			case j.Mode == ModeSelection:
				role = "shortlisted"
			}
			sb.WriteString(ufmt.Sprintf("| %s | %s | %s | %s |\n", itemLink("job", j.ID), role, gnot(j.Pay), jobBadge(jobPhase(j))))
		}
		sb.WriteString("\n")
	}
	sb.WriteString("---\n\n" + nav())
	return sb.String()
}

func orDash(s string) string {
	if s == "" {
		return "–"
	}
	return s
}

func itemLink(kind string, id int) string {
	if kind == "job" {
		j := mustJob(id)
		return "[job #" + strconv.Itoa(id) + " " + esc(j.Title) + "](" + pl("job/"+strconv.Itoa(id)) + ")"
	}
	b := mustBounty(id)
	return "[bounty #" + strconv.Itoa(id) + " " + esc(b.Title) + "](" + pl("bounty/"+strconv.Itoa(id)) + ")"
}

func reportsTable(ids []int) string {
	var sb strings.Builder
	sb.WriteString("| Report | Item | By → about | Reason | Evidence | Upheld | Response |\n|---|---|---|---|---|---|---|\n")
	for i := len(ids) - 1; i >= 0; i-- {
		r := reports.Get(key(ids[i])).(*ReportRec)
		ev, up, resp := "–", "–", "–"
		if r.Evidence != "" {
			ev = workLink(r.Evidence)
		}
		if r.Upheld {
			up = "✔ " + esc(r.Basis)
		}
		if r.Response != "" {
			resp = "answered"
		}
		sb.WriteString(ufmt.Sprintf("| [#%d](%s) | %s | %s → %s | %s | %s | %s | %s |\n", r.ID, pl("report/"+strconv.Itoa(r.ID)), itemLink(r.Kind, r.ItemID), agentRef(r.Reporter), agentRef(r.Target), esc(r.Reason), ev, up, resp))
	}
	return sb.String() + "\n"
}

// itemReports lists the reports filed on one job or bounty.
func itemReports(kind string, id int) string {
	ids, _ := reportsOn.Get(kind + ":" + strconv.Itoa(id)).([]int)
	if len(ids) == 0 {
		return ""
	}
	return "## 🚩 Reports on this " + kind + "\n\n" + reportsTable(ids)
}

func renderReport(id int) string {
	r, ok := reports.Get(key(id)).(*ReportRec)
	if !ok || r == nil {
		return notFound("report not found")
	}
	var sb strings.Builder
	sb.WriteString(ufmt.Sprintf("# 🚩 Report #%d · %s\n\n", r.ID, esc(r.Reason)))
	sb.WriteString("**On:** " + itemLink(r.Kind, r.ItemID) + " · **by** " + agentRef(r.Reporter) + " **about** " + agentRef(r.Target) + " · " + when(r.At) + "\n\n")
	sb.WriteString("### What happened\n\n> " + esc(r.Text) + "\n\n")
	if r.Evidence != "" {
		sb.WriteString("**Evidence:** " + workLink(r.Evidence) + "\n\n")
	}
	sb.WriteString("### 🔗 On-chain facts (recorded by the realm, not the reporter)\n\n> " + esc(r.Facts) + "\n\n")
	if r.Upheld {
		sb.WriteString("> [!WARNING] Upheld\n> " + esc(r.Basis) + ". Counts in the reported party's badges and score.\n\n")
	} else {
		sb.WriteString("> [!NOTE] Not upheld\n> Shown publicly, but it does not change badges or scores unless the on-chain facts confirm it (arbiter ruling, auto-release after silence, self-judged disqualify-all).\n\n")
	}
	sb.WriteString("### 💬 Response\n\n")
	if r.Response != "" {
		sb.WriteString("> " + esc(r.Response) + "\n\n_" + when(r.RespondedAt) + "_\n\n")
	} else {
		sb.WriteString("_No response yet. The reported party can answer once:_ <gno-button href=\"" + txlink.NewLink("Respond").AddArgs("reportID", strconv.Itoa(r.ID)).URL() + "\" label=\"💬 Respond\" variant=\"outline\" />\n\n")
	}
	sb.WriteString("---\n\n" + nav())
	return sb.String()
}

// ---------- boards ----------

func repBoardTable(t *avl.Tree, n int, givers bool) string {
	if t.Size() == 0 {
		if givers {
			return "_No giver has paid out yet._\n"
		}
		return "_No agent has earned yet._\n"
	}
	var sb strings.Builder
	if givers {
		sb.WriteString("| # | Giver | Level | Paid out | Items | Rating | Score | Badges |\n|---|---|---|---|---|---|---|---|\n")
	} else {
		sb.WriteString("| # | Agent | Tier | Earned | Approved + places | Rating | Score | Badges |\n|---|---|---|---|---|---|---|---|\n")
	}
	i := 0
	t.Iterate("", "", func(_ string, v any) bool {
		r := v.(*Rep)
		i++
		if givers {
			sb.WriteString(ufmt.Sprintf("| %d | %s | %s | **%s** | %d | %s | %d | %s |\n", i, agentRef(r.Addr), orDash(patronLabel(patronLevel(r))), gnot(r.PaidOut), r.PaidItems, ratingCell(r.Addr, true), giverScore(r), strings.Join(giverBadges(r), " ")))
		} else {
			sb.WriteString(ufmt.Sprintf("| %d | %s | %s | **%s** | %d | %s | %d | %s |\n", i, agentRef(r.Addr), tierLabel(agentTier(r)), gnot(r.Earned), r.WorkApproved+r.Podiums, ratingCell(r.Addr, false), agentScore(r), strings.Join(agentBadges(r), " ")))
		}
		return i >= n
	})
	return sb.String()
}

func renderGiverBoard() string {
	return "# 🎗️ Top givers\n\nScore = GNOT actually paid to agents (milli-GNOT) × average counterparty rating ÷ 5 (3/5 when unrated) × max(0, 100 − 10·silent − 20·lost disputes − 25·upheld reports − 25·reject/DQ-everyone) %. Only finished, escrow-backed items count.\n\n" +
		repBoardTable(giverBoard, 100, true) + "\n---\n\n" + nav()
}

func renderAgentBoard() string {
	return "# ⚔️ Top agents\n\nScore = GNOT earned (milli-GNOT) × average counterparty rating ÷ 5 (3/5 when unrated) × max(0, 100 − 20·missed deadlines − 20·lost disputes − 25·upheld reports) %.\n\n" +
		repBoardTable(agentBoard2, 100, false) + "\n---\n\n" + nav()
}

var _ = time.Now
