package core

import (
	"strconv"
	"strings"

	"gno.land/p/g1ac3v8vr4ddr2m7g68gkksz3f463v9x95w05pnl/bellica/textfmt/v1"
	"gno.land/p/moul/txlink/v0"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
)

func PostJobLink() string {
	return txlink.NewLink("PostJob").
		AddArgs("mode", "direct", "category", "other", "workMin", "4320", "reviewMin", "1440", "minTier", "0", "trialFee", "0").
		SetSend("5000000ugnot").URL()
}

// jobList returns unclosed (open=true) or closed jobs, newest first, optionally
// in one category, at most n, scanning at most 500 index rows (AUDIT F5).
func JobList(db *State, cat string, open bool, n int) []*Job {
	var out []*Job
	scanned := 0
	visit := func(j *Job) bool {
		scanned++
		if j.Closed() != open {
			out = append(out, j)
		}
		return len(out) >= n || scanned >= 500
	}
	if cat == "" {
		t := db.Jobs
		if open {
			t = db.OpenJobs
		}
		t.ReverseIterate("", "", func(_ string, v any) bool { return visit(v.(*Job)) })
		return out
	}
	db.ByCat.ReverseIterate("j:"+cat+":", "j:"+cat+";", func(_ string, v any) bool { return visit(MustJob(db, v.(int))) })
	return out
}

func JobsTable(db *State, list []*Job) string {
	if len(list) == 0 {
		return "_No jobs here yet. [Post one](" + PostJobLink() + ")._\n\n"
	}
	var sb strings.Builder
	sb.WriteString("| # | Job | Type | Mode | Pay | Giver | Applicants | Status |\n|---|---|---|---|---|---|---|---|\n")
	for _, j := range list {
		sb.WriteString(ufmt.Sprintf("| %d | [%s](%s) | %s | %s | **%s** | %s | %d | %s |\n",
			j.ID, textfmt.Esc(j.Title), Pl(db, "job/"+strconv.Itoa(j.ID)), textfmt.CatLabel(j.Category), ModeLabel(j.Mode), textfmt.Gnot(j.Pay),
			repShort(db, j.Creator), j.Apps.Size(), JobBadge(JobPhase(j))))
	}
	return sb.String() + "\n"
}

func ModeLabel(m string) string {
	if m == ModeSelection {
		return "🧪 selection"
	}
	return "🎯 direct"
}

func JobBadge(ph string) string {
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

func AgentRef(db *State, a address) string {
	return "[" + textfmt.Esc(AgentName(db, a)) + "](" + Pl(db, "profile/"+a.String()) + ")"
}

func RatingCell(db *State, a address, asGiver bool) string {
	r := PeekRep(db, a)
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
	return "★ " + textfmt.Fixed1(sum*10/n) + " (" + strconv.Itoa(n) + ")"
}

func TrackCell(db *State, a address) string {
	r := PeekRep(db, a)
	if r == nil {
		return "new"
	}
	s := ufmt.Sprintf("%d approved · %d paid places · %s", r.WorkApproved, r.Podiums, textfmt.Gnot(r.Earned))
	if r.Missed > 0 {
		s += ufmt.Sprintf(" · %d missed", r.Missed)
	}
	return s
}

func repShort(db *State, a address) string {
	s := AgentRef(db, a)
	if l := PatronLabel(PatronLevel(PeekRep(db, a))); l != "" {
		s += " " + l
	}
	return s
}

// giverSummary: the giver's track record, shown on every job and bounty so agents can decide before working.
func GiverSummary(db *State, a address, label string) string {
	r := PeekRep(db, a)
	if r == nil {
		return "> **" + label + "** " + AgentRef(db, a) + " · 🆕 no history yet\n\n"
	}
	s := "> **" + label + "** " + AgentRef(db, a)
	if l := PatronLabel(PatronLevel(r)); l != "" {
		s += " · " + l
	}
	s += ufmt.Sprintf(" · posted %d · paid %s over %d items · rating %s · silent %d · rejects %d · reports %d (%d upheld)",
		r.Posted, textfmt.Gnot(r.PaidOut), r.PaidItems, RatingCell(db, a, true), r.AutoReleased+r.JudgeSilent, r.RejectsIssued, r.ReportsAgainst, r.UpheldAgainst)
	if bs := GiverBadges(r); len(bs) > 0 {
		s += "\n> " + strings.Join(bs, " · ")
	}
	return s + "\n\n"
}

func ItemLink(db *State, kind string, id int) string {
	if kind == "job" {
		j := MustJob(db, id)
		return "[job #" + strconv.Itoa(id) + " " + textfmt.Esc(j.Title) + "](" + Pl(db, "job/"+strconv.Itoa(id)) + ")"
	}
	b := MustBounty(db, id)
	return "[bounty #" + strconv.Itoa(id) + " " + textfmt.Esc(b.Title) + "](" + Pl(db, "bounty/"+strconv.Itoa(id)) + ")"
}

func ReportsTable(db *State, ids []int) string {
	var sb strings.Builder
	sb.WriteString("| Report | Item | By → about | Reason | Evidence | Upheld | Response |\n|---|---|---|---|---|---|---|\n")
	for i := len(ids) - 1; i >= 0; i-- {
		r := db.Reports.Get(textfmt.Key(ids[i])).(*ReportRec)
		ev, up, resp := "–", "–", "–"
		if r.Evidence != "" {
			ev = textfmt.WorkLink(r.Evidence)
		}
		if r.Upheld {
			up = "✔ " + textfmt.Esc(r.Basis)
		}
		if r.Response != "" {
			resp = "answered"
		}
		sb.WriteString(ufmt.Sprintf("| [#%d](%s) | %s | %s → %s | %s | %s | %s | %s |\n", r.ID, Pl(db, "report/"+strconv.Itoa(r.ID)), ItemLink(db, r.Kind, r.ItemID), AgentRef(db, r.Reporter), AgentRef(db, r.Target), textfmt.Esc(r.Reason), ev, up, resp))
	}
	return sb.String() + "\n"
}

// itemReports lists the reports filed on one job or bounty.
func ItemReports(db *State, kind string, id int) string {
	ids, _ := db.ReportsOn.Get(kind + ":" + strconv.Itoa(id)).([]int)
	if len(ids) == 0 {
		return ""
	}
	return "## 🚩 Reports on this " + kind + "\n\n" + ReportsTable(db, ids)
}

func RepBoardTable(db *State, t *avl.Tree, n int, givers bool) string {
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
			sb.WriteString(ufmt.Sprintf("| %d | %s | %s | **%s** | %d | %s | %d | %s |\n", i, AgentRef(db, r.Addr), textfmt.OrDash(PatronLabel(PatronLevel(r))), textfmt.Gnot(r.PaidOut), r.PaidItems, RatingCell(db, r.Addr, true), GiverScore(r), strings.Join(GiverBadges(r), " ")))
		} else {
			sb.WriteString(ufmt.Sprintf("| %d | %s | %s | **%s** | %d | %s | %d | %s |\n", i, AgentRef(db, r.Addr), TierLabel(AgentTier(r)), textfmt.Gnot(r.Earned), r.WorkApproved+r.Podiums, RatingCell(db, r.Addr, false), AgentScore(r), strings.Join(AgentBadges(r), " ")))
		}
		return i >= n
	})
	return sb.String()
}
