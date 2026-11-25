package api

import (
	"strconv"
	"strings"

	"gno.land/p/g1ac3v8vr4ddr2m7g68gkksz3f463v9x95w05pnl/bellica/core/v1"
	"gno.land/p/g1ac3v8vr4ddr2m7g68gkksz3f463v9x95w05pnl/bellica/textfmt/v1"
)

func bountiesCatJSON(db *core.State, cat string) string {
	var items []string
	for _, b := range core.BountyList(db, cat, true, jsonPage) {
		items = append(items, BountyJSON(db, b, false))
	}
	for _, b := range core.BountyList(db, cat, false, jsonPage) {
		items = append(items, BountyJSON(db, b, false))
	}
	return "[" + strings.Join(items, ",") + "]"
}

func renderJSON2(db *core.State, parts []string, cat string) (string, bool) {
	switch {
	case len(parts) == 1 && parts[0] == "categories":
		q := make([]string, len(textfmt.Categories))
		for i, c := range textfmt.Categories {
			q[i] = `{"id":` + textfmt.Jq(c) + `,"scoring":` + textfmt.Jq(textfmt.ScoringOf(c)) + `}`
		}
		return "[" + strings.Join(q, ",") + "]", true
	case len(parts) == 1 && parts[0] == "jobs":
		return jobsJSON(db, cat), true
	case len(parts) == 2 && parts[0] == "jobs" && textfmt.InList(parts[1], textfmt.Categories):
		return jobsJSON(db, parts[1]), true
	case len(parts) == 2 && (parts[0] == "jobs" || parts[0] == "job"):
		id, err := strconv.Atoi(parts[1])
		if err != nil {
			return textfmt.JsonErr("bad job id"), true
		}
		j, ok := db.Jobs.Get(textfmt.Key(id)).(*core.Job)
		if !ok || j == nil {
			return textfmt.JsonErr("job not found"), true
		}
		return jobJSON(db, j, true), true
	case len(parts) == 2 && parts[0] == "profile":
		a := address(parts[1])
		if !a.IsValid() {
			return textfmt.JsonErr("bad address"), true
		}
		return profileJSON(db, a), true
	case len(parts) == 2 && parts[0] == "leaderboard" && (parts[1] == "givers" || parts[1] == "agents"):
		t, givers := db.AgentBoard2, parts[1] == "givers"
		if givers {
			t = db.GiverBoard
		}
		var items []string
		t.Iterate("", "", func(_ string, v any) bool {
			r := v.(*core.Rep)
			sc := core.AgentScore(r)
			if givers {
				sc = core.GiverScore(r)
			}
			items = append(items, `{"rank":`+strconv.Itoa(len(items)+1)+`,"score":`+textfmt.I64(sc)+`,"profile":`+repJSON(db, r)+`}`)
			return len(items) >= 100
		})
		return "[" + strings.Join(items, ",") + "]", true
	case len(parts) == 2 && parts[0] == "report":
		id, err := strconv.Atoi(parts[1])
		if err != nil {
			return textfmt.JsonErr("bad report id"), true
		}
		r, ok := db.Reports.Get(textfmt.Key(id)).(*core.ReportRec)
		if !ok || r == nil {
			return textfmt.JsonErr("report not found"), true
		}
		return reportJSON(r), true
	}
	return "", false
}

// jobsJSON: unclosed jobs (max 200) + the 50 newest closed, newest first; or the newest of one category.
func jobsJSON(db *core.State, cat string) string {
	var items []string
	for _, j := range core.JobList(db, cat, true, 200) {
		items = append(items, jobJSON(db, j, false))
	}
	for _, j := range core.JobList(db, cat, false, jsonPage) {
		items = append(items, jobJSON(db, j, false))
	}
	return "[" + strings.Join(items, ",") + "]"
}

func jobJSON(db *core.State, j *core.Job, detail bool) string {
	var sb strings.Builder
	sb.WriteString(`{"id":` + strconv.Itoa(j.ID))
	sb.WriteString(`,"title":` + textfmt.Jq(j.Title))
	sb.WriteString(`,"spec_url":` + textfmt.Jq(j.SpecURL))
	sb.WriteString(`,"category":` + textfmt.Jq(j.Category))
	sb.WriteString(`,"mode":` + textfmt.Jq(j.Mode))
	sb.WriteString(`,"min_tier":` + strconv.Itoa(j.MinTier))
	sb.WriteString(`,"pay_ugnot":` + textfmt.I64(j.Pay))
	sp := make([]string, len(j.Splits))
	for i, p := range j.Splits {
		sp[i] = strconv.Itoa(p)
	}
	sb.WriteString(`,"splits":[` + strings.Join(sp, ",") + `]`)
	sb.WriteString(`,"trial_fee_ugnot":` + textfmt.I64(j.TrialFee))
	sb.WriteString(`,"status":` + textfmt.Jq(j.Status))
	sb.WriteString(`,"phase":` + textfmt.Jq(core.JobPhase(j)))
	sb.WriteString(`,"creator":` + textfmt.Jq(j.Creator.String()))
	sb.WriteString(`,"agent":` + textfmt.Jq(j.Agent.String()))
	sb.WriteString(`,"arbiter":` + textfmt.Jq(j.Arbiter.String()))
	sb.WriteString(`,"created_unix":` + textfmt.Ts(j.CreatedAt))
	sb.WriteString(`,"deadline_unix":` + textfmt.Ts(j.Deadline))
	sb.WriteString(`,"review_by_unix":` + textfmt.UnixOr0(j.ReviewBy))
	sb.WriteString(`,"resolve_by_unix":` + textfmt.UnixOr0(j.ResolveBy))
	sb.WriteString(`,"applicants":` + strconv.Itoa(j.Apps.Size()))
	sb.WriteString(`,"shortlisted":` + strconv.Itoa(len(j.Shortlist)))
	sb.WriteString(`,"deliveries":` + strconv.Itoa(j.Deliveries))
	sb.WriteString(`,"rejects":` + strconv.Itoa(j.Rejects))
	sb.WriteString(`,"reject_reason":` + textfmt.Jq(j.RejectReason))
	sb.WriteString(`,"paid_agents_ugnot":` + textfmt.I64(j.PaidAgents))
	sb.WriteString(`,"returned_ugnot":` + textfmt.I64(j.Returned))
	sb.WriteString(`,"auto_released":` + strconv.FormatBool(j.AutoReleased))
	sb.WriteString(`,"rejected_all":` + strconv.FormatBool(j.RejectedAll))
	sb.WriteString(`,"creator_rep":` + repSummaryJSON(db, j.Creator))
	if detail {
		sb.WriteString(`,"delivery":` + textfmt.DeliverJSON(j.Kind, j.URL, j.Hash, j.Text, j.Note, j.DeliveredAt))
		sb.WriteString(`,"applications":[`)
		for i, a := range j.AppOrder {
			ap := j.Apps.Get(a.String()).(*core.Application)
			if i > 0 {
				sb.WriteString(",")
			}
			sb.WriteString(`{"agent":` + textfmt.Jq(a.String()) + `,"name":` + textfmt.Jq(core.AgentName(db, a)) + `,"pitch":` + textfmt.Jq(ap.Pitch) +
				`,"sample":` + textfmt.Jq(ap.Sample) + `,"at_unix":` + textfmt.Ts(ap.At) + `,"rep":` + repSummaryJSON(db, a) + `}`)
		}
		sb.WriteString(`],"trials":[`)
		for i, a := range j.Shortlist {
			t := j.Trials.Get(a.String()).(*core.Trial)
			if i > 0 {
				sb.WriteString(",")
			}
			sb.WriteString(`{"agent":` + textfmt.Jq(a.String()) + `,"name":` + textfmt.Jq(core.AgentName(db, a)) + `,"delivery":` + textfmt.DeliverJSON(t.Kind, t.URL, t.Hash, t.Text, t.Note, t.At) +
				`,"place":` + strconv.Itoa(t.Place) + `,"payout_ugnot":` + textfmt.I64(t.Payout) + `,"rep":` + repSummaryJSON(db, a) + `}`)
		}
		sb.WriteString(`],"reports":` + textfmt.IdsJSON(db.ReportsOn, "job:"+strconv.Itoa(j.ID)))
	}
	sb.WriteString("}")
	return sb.String()
}

// repSummaryJSON: the compact reputation shown next to every giver / applicant.
func repSummaryJSON(db *core.State, a address) string {
	r := core.PeekRep(db, a)
	if r == nil {
		r = &core.Rep{Addr: a}
	}
	t := core.AgentTier(r)
	return `{"address":` + textfmt.Jq(a.String()) + `,"tier":` + strconv.Itoa(t) + `,"tier_name":` + textfmt.Jq(core.TierNames[t]) +
		`,"patron_level":` + strconv.Itoa(core.PatronLevel(r)) +
		`,"paid_out_ugnot":` + textfmt.I64(r.PaidOut) + `,"paid_items":` + strconv.Itoa(r.PaidItems) +
		`,"silent":` + strconv.Itoa(r.AutoReleased+r.JudgeSilent) + `,"rejects_issued":` + strconv.Itoa(r.RejectsIssued) +
		`,"giver_rating_x10":` + strconv.Itoa(core.Avg10(r.GiverRatingSum, r.GiverRatingN)) + `,"giver_ratings":` + strconv.Itoa(r.GiverRatingN) +
		`,"agent_rating_x10":` + strconv.Itoa(core.Avg10(r.AgentRatingSum, r.AgentRatingN)) + `,"agent_ratings":` + strconv.Itoa(r.AgentRatingN) +
		`,"reports_against":` + strconv.Itoa(r.ReportsAgainst) + `,"upheld_against":` + strconv.Itoa(r.UpheldAgainst) +
		`,"giver_badges":` + textfmt.BadgesJSON(core.GiverBadges(r)) + `,"agent_badges":` + textfmt.BadgesJSON(core.AgentBadges(r)) + `}`
}

func repJSON(db *core.State, r *core.Rep) string {
	return `{"address":` + textfmt.Jq(r.Addr.String()) + `,"name":` + textfmt.Jq(core.AgentName(db, r.Addr)) +
		`,"tier":` + strconv.Itoa(core.AgentTier(r)) + `,"tier_name":` + textfmt.Jq(core.TierNames[core.AgentTier(r)]) + `,"patron_level":` + strconv.Itoa(core.PatronLevel(r)) +
		`,"giver":{"posted":` + strconv.Itoa(r.Posted) + `,"paid_out_ugnot":` + textfmt.I64(r.PaidOut) + `,"paid_items":` + strconv.Itoa(r.PaidItems) +
		`,"approved":` + strconv.Itoa(r.Approved) + `,"fast_approvals":` + strconv.Itoa(r.FastApprovals) + `,"auto_released":` + strconv.Itoa(r.AutoReleased) +
		`,"judge_silent":` + strconv.Itoa(r.JudgeSilent) + `,"rejects_issued":` + strconv.Itoa(r.RejectsIssued) + `,"deliveries_received":` + strconv.Itoa(r.DeliveriesReceived) +
		`,"disputes_won":` + strconv.Itoa(r.DisputesWon) + `,"disputes_lost":` + strconv.Itoa(r.DisputesLost) + `,"refunds_no_delivery":` + strconv.Itoa(r.RefundsNoDelivery) +
		`,"reject_or_dq_all":` + strconv.Itoa(r.DQAll) + `,"cancellations":` + strconv.Itoa(r.Cancellations) +
		`,"rating_x10":` + strconv.Itoa(core.Avg10(r.GiverRatingSum, r.GiverRatingN)) + `,"ratings":` + strconv.Itoa(r.GiverRatingN) + `,"badges":` + textfmt.BadgesJSON(core.GiverBadges(r)) + `}` +
		`,"agent":{"hired":` + strconv.Itoa(r.Hired) + `,"delivered":` + strconv.Itoa(r.Delivered) + `,"approved":` + strconv.Itoa(r.WorkApproved) +
		`,"rejected":` + strconv.Itoa(r.WorkRejected) + `,"missed":` + strconv.Itoa(r.Missed) + `,"wins":` + strconv.Itoa(r.Wins) + `,"paid_places":` + strconv.Itoa(r.Podiums) +
		`,"earned_ugnot":` + textfmt.I64(r.Earned) + `,"disputes_won":` + strconv.Itoa(r.ADisputesWon) + `,"disputes_lost":` + strconv.Itoa(r.ADisputesLost) +
		`,"rating_x10":` + strconv.Itoa(core.Avg10(r.AgentRatingSum, r.AgentRatingN)) + `,"ratings":` + strconv.Itoa(r.AgentRatingN) + `,"badges":` + textfmt.BadgesJSON(core.AgentBadges(r)) + `}` +
		`,"reports_against":` + strconv.Itoa(r.ReportsAgainst) + `,"upheld_against":` + strconv.Itoa(r.UpheldAgainst) + `,"reports_filed":` + strconv.Itoa(r.ReportsFiled) + `}`
}

func profileJSON(db *core.State, a address) string {
	r := core.PeekRep(db, a)
	if r == nil {
		r = &core.Rep{Addr: a}
	}
	var rs []string
	if list, _ := db.RatingsOf.Get(a.String()).([]*core.Rating); len(list) > 0 {
		for i := len(list) - 1; i >= 0; i-- {
			rt := list[i]
			rs = append(rs, `{"kind":`+textfmt.Jq(rt.Kind)+`,"item":`+strconv.Itoa(rt.ItemID)+`,"rater":`+textfmt.Jq(rt.Rater.String())+
				`,"as_giver":`+strconv.FormatBool(rt.AsGiver)+`,"score":`+strconv.Itoa(rt.Score)+`,"comment":`+textfmt.Jq(rt.Comment)+`,"at_unix":`+textfmt.Ts(rt.At)+`}`)
		}
	}
	p := repJSON(db, r)
	return p[:len(p)-1] + `,"ratings":[` + strings.Join(rs, ",") + `],"reports":` + textfmt.IdsJSON(db.ReportsAbout, a.String()) + `}`
}

func reportJSON(r *core.ReportRec) string {
	return `{"id":` + strconv.Itoa(r.ID) + `,"kind":` + textfmt.Jq(r.Kind) + `,"item":` + strconv.Itoa(r.ItemID) +
		`,"reporter":` + textfmt.Jq(r.Reporter.String()) + `,"target":` + textfmt.Jq(r.Target.String()) + `,"reason":` + textfmt.Jq(r.Reason) +
		`,"text":` + textfmt.Jq(r.Text) + `,"evidence":` + textfmt.Jq(r.Evidence) + `,"facts":` + textfmt.Jq(r.Facts) +
		`,"upheld":` + strconv.FormatBool(r.Upheld) + `,"basis":` + textfmt.Jq(r.Basis) + `,"at_unix":` + textfmt.Ts(r.At) +
		`,"response":` + textfmt.Jq(r.Response) + `,"responded_unix":` + textfmt.UnixOr0(r.RespondedAt) + `}`
}
