package bellica

import (
	"strconv"
	"strings"
)

// JSON for categories, jobs, profiles, reports and the reputation boards.

func bountiesCatJSON(cat string) string {
	var items []string
	for _, b := range bountyList(cat, true, jsonPage) {
		items = append(items, bountyJSON(b, false))
	}
	for _, b := range bountyList(cat, false, jsonPage) {
		items = append(items, bountyJSON(b, false))
	}
	return "[" + strings.Join(items, ",") + "]"
}

func renderJSON2(parts []string, cat string) (string, bool) {
	switch {
	case len(parts) == 1 && parts[0] == "categories":
		q := make([]string, len(categories))
		for i, c := range categories {
			q[i] = `{"id":` + jq(c) + `,"scoring":` + jq(scoringOf(c)) + `}`
		}
		return "[" + strings.Join(q, ",") + "]", true
	case len(parts) == 1 && parts[0] == "jobs":
		return jobsJSON(cat), true
	case len(parts) == 2 && parts[0] == "jobs" && inList(parts[1], categories):
		return jobsJSON(parts[1]), true
	case len(parts) == 2 && (parts[0] == "jobs" || parts[0] == "job"):
		id, err := strconv.Atoi(parts[1])
		if err != nil {
			return jsonErr("bad job id"), true
		}
		j, ok := jobs.Get(key(id)).(*Job)
		if !ok || j == nil {
			return jsonErr("job not found"), true
		}
		return jobJSON(j, true), true
	case len(parts) == 2 && parts[0] == "profile":
		a := address(parts[1])
		if !a.IsValid() {
			return jsonErr("bad address"), true
		}
		return profileJSON(a), true
	case len(parts) == 2 && parts[0] == "leaderboard" && (parts[1] == "givers" || parts[1] == "agents"):
		t, givers := agentBoard2, parts[1] == "givers"
		if givers {
			t = giverBoard
		}
		var items []string
		t.Iterate("", "", func(_ string, v any) bool {
			r := v.(*Rep)
			sc := agentScore(r)
			if givers {
				sc = giverScore(r)
			}
			items = append(items, `{"rank":`+strconv.Itoa(len(items)+1)+`,"score":`+i64(sc)+`,"profile":`+repJSON(r)+`}`)
			return len(items) >= 100
		})
		return "[" + strings.Join(items, ",") + "]", true
	case len(parts) == 2 && parts[0] == "report":
		id, err := strconv.Atoi(parts[1])
		if err != nil {
			return jsonErr("bad report id"), true
		}
		r, ok := reports.Get(key(id)).(*ReportRec)
		if !ok || r == nil {
			return jsonErr("report not found"), true
		}
		return reportJSON(r), true
	}
	return "", false
}

// jobsJSON: unclosed jobs (max 200) + the 50 newest closed, newest first; or the newest of one category.
func jobsJSON(cat string) string {
	var items []string
	for _, j := range jobList(cat, true, 200) {
		items = append(items, jobJSON(j, false))
	}
	for _, j := range jobList(cat, false, jsonPage) {
		items = append(items, jobJSON(j, false))
	}
	return "[" + strings.Join(items, ",") + "]"
}

func ts(t interface{ Unix() int64 }) string { return i64(t.Unix()) }

func jobJSON(j *Job, detail bool) string {
	var sb strings.Builder
	sb.WriteString(`{"id":` + strconv.Itoa(j.ID))
	sb.WriteString(`,"title":` + jq(j.Title))
	sb.WriteString(`,"spec_url":` + jq(j.SpecURL))
	sb.WriteString(`,"category":` + jq(j.Category))
	sb.WriteString(`,"mode":` + jq(j.Mode))
	sb.WriteString(`,"min_tier":` + strconv.Itoa(j.MinTier))
	sb.WriteString(`,"pay_ugnot":` + i64(j.Pay))
	sp := make([]string, len(j.Splits))
	for i, p := range j.Splits {
		sp[i] = strconv.Itoa(p)
	}
	sb.WriteString(`,"splits":[` + strings.Join(sp, ",") + `]`)
	sb.WriteString(`,"trial_fee_ugnot":` + i64(j.TrialFee))
	sb.WriteString(`,"status":` + jq(j.Status))
	sb.WriteString(`,"phase":` + jq(jobPhase(j)))
	sb.WriteString(`,"creator":` + jq(j.Creator.String()))
	sb.WriteString(`,"agent":` + jq(j.Agent.String()))
	sb.WriteString(`,"arbiter":` + jq(j.Arbiter.String()))
	sb.WriteString(`,"created_unix":` + ts(j.CreatedAt))
	sb.WriteString(`,"deadline_unix":` + ts(j.Deadline))
	sb.WriteString(`,"review_by_unix":` + unixOr0(j.ReviewBy))
	sb.WriteString(`,"resolve_by_unix":` + unixOr0(j.ResolveBy))
	sb.WriteString(`,"applicants":` + strconv.Itoa(j.apps.Size()))
	sb.WriteString(`,"shortlisted":` + strconv.Itoa(len(j.shortlist)))
	sb.WriteString(`,"deliveries":` + strconv.Itoa(j.Deliveries))
	sb.WriteString(`,"rejects":` + strconv.Itoa(j.Rejects))
	sb.WriteString(`,"reject_reason":` + jq(j.RejectReason))
	sb.WriteString(`,"paid_agents_ugnot":` + i64(j.PaidAgents))
	sb.WriteString(`,"returned_ugnot":` + i64(j.Returned))
	sb.WriteString(`,"auto_released":` + strconv.FormatBool(j.AutoReleased))
	sb.WriteString(`,"rejected_all":` + strconv.FormatBool(j.RejectedAll))
	sb.WriteString(`,"creator_rep":` + repSummaryJSON(j.Creator))
	if detail {
		sb.WriteString(`,"delivery":` + deliverJSON(j.Kind, j.URL, j.Hash, j.Text, j.Note, j.DeliveredAt))
		sb.WriteString(`,"applications":[`)
		for i, a := range j.appOrder {
			ap := j.apps.Get(a.String()).(*Application)
			if i > 0 {
				sb.WriteString(",")
			}
			sb.WriteString(`{"agent":` + jq(a.String()) + `,"name":` + jq(agentName(a)) + `,"pitch":` + jq(ap.Pitch) +
				`,"sample":` + jq(ap.Sample) + `,"at_unix":` + ts(ap.At) + `,"rep":` + repSummaryJSON(a) + `}`)
		}
		sb.WriteString(`],"trials":[`)
		for i, a := range j.shortlist {
			t := j.trials.Get(a.String()).(*Trial)
			if i > 0 {
				sb.WriteString(",")
			}
			sb.WriteString(`{"agent":` + jq(a.String()) + `,"name":` + jq(agentName(a)) + `,"delivery":` + deliverJSON(t.Kind, t.URL, t.Hash, t.Text, t.Note, t.At) +
				`,"place":` + strconv.Itoa(t.Place) + `,"payout_ugnot":` + i64(t.Payout) + `,"rep":` + repSummaryJSON(a) + `}`)
		}
		sb.WriteString(`],"reports":` + idsJSON(reportsOn, "job:"+strconv.Itoa(j.ID)))
	}
	sb.WriteString("}")
	return sb.String()
}

func unixOr0(t interface {
	IsZero() bool
	Unix() int64
}) string {
	if t.IsZero() {
		return "0"
	}
	return i64(t.Unix())
}

func deliverJSON(kind, url, hash, text, note string, at interface {
	IsZero() bool
	Unix() int64
}) string {
	if at.IsZero() {
		return "null"
	}
	return `{"kind":` + jq(kind) + `,"url":` + jq(url) + `,"sha256":` + jq(hash) + `,"text":` + jq(text) + `,"note":` + jq(note) + `,"at_unix":` + i64(at.Unix()) + `}`
}

func idsJSON(t interface{ Get(string) any }, k string) string {
	ids, _ := t.Get(k).([]int)
	q := make([]string, len(ids))
	for i, id := range ids {
		q[i] = strconv.Itoa(id)
	}
	return "[" + strings.Join(q, ",") + "]"
}

func badgesJSON(bs []string) string {
	q := make([]string, len(bs))
	for i, b := range bs {
		q[i] = jq(b)
	}
	return "[" + strings.Join(q, ",") + "]"
}

// repSummaryJSON: the compact reputation shown next to every giver / applicant.
func repSummaryJSON(a address) string {
	r := peekRep(a)
	if r == nil {
		r = &Rep{Addr: a}
	}
	t := agentTier(r)
	return `{"address":` + jq(a.String()) + `,"tier":` + strconv.Itoa(t) + `,"tier_name":` + jq(tierNames[t]) +
		`,"patron_level":` + strconv.Itoa(patronLevel(r)) +
		`,"paid_out_ugnot":` + i64(r.PaidOut) + `,"paid_items":` + strconv.Itoa(r.PaidItems) +
		`,"silent":` + strconv.Itoa(r.AutoReleased+r.JudgeSilent) + `,"rejects_issued":` + strconv.Itoa(r.RejectsIssued) +
		`,"giver_rating_x10":` + strconv.Itoa(avg10(r.GiverRatingSum, r.GiverRatingN)) + `,"giver_ratings":` + strconv.Itoa(r.GiverRatingN) +
		`,"agent_rating_x10":` + strconv.Itoa(avg10(r.AgentRatingSum, r.AgentRatingN)) + `,"agent_ratings":` + strconv.Itoa(r.AgentRatingN) +
		`,"reports_against":` + strconv.Itoa(r.ReportsAgainst) + `,"upheld_against":` + strconv.Itoa(r.UpheldAgainst) +
		`,"giver_badges":` + badgesJSON(giverBadges(r)) + `,"agent_badges":` + badgesJSON(agentBadges(r)) + `}`
}

func repJSON(r *Rep) string {
	return `{"address":` + jq(r.Addr.String()) + `,"name":` + jq(agentName(r.Addr)) +
		`,"tier":` + strconv.Itoa(agentTier(r)) + `,"tier_name":` + jq(tierNames[agentTier(r)]) + `,"patron_level":` + strconv.Itoa(patronLevel(r)) +
		`,"giver":{"posted":` + strconv.Itoa(r.Posted) + `,"paid_out_ugnot":` + i64(r.PaidOut) + `,"paid_items":` + strconv.Itoa(r.PaidItems) +
		`,"approved":` + strconv.Itoa(r.Approved) + `,"fast_approvals":` + strconv.Itoa(r.FastApprovals) + `,"auto_released":` + strconv.Itoa(r.AutoReleased) +
		`,"judge_silent":` + strconv.Itoa(r.JudgeSilent) + `,"rejects_issued":` + strconv.Itoa(r.RejectsIssued) + `,"deliveries_received":` + strconv.Itoa(r.DeliveriesReceived) +
		`,"disputes_won":` + strconv.Itoa(r.DisputesWon) + `,"disputes_lost":` + strconv.Itoa(r.DisputesLost) + `,"refunds_no_delivery":` + strconv.Itoa(r.RefundsNoDelivery) +
		`,"reject_or_dq_all":` + strconv.Itoa(r.DQAll) + `,"cancellations":` + strconv.Itoa(r.Cancellations) +
		`,"rating_x10":` + strconv.Itoa(avg10(r.GiverRatingSum, r.GiverRatingN)) + `,"ratings":` + strconv.Itoa(r.GiverRatingN) + `,"badges":` + badgesJSON(giverBadges(r)) + `}` +
		`,"agent":{"hired":` + strconv.Itoa(r.Hired) + `,"delivered":` + strconv.Itoa(r.Delivered) + `,"approved":` + strconv.Itoa(r.WorkApproved) +
		`,"rejected":` + strconv.Itoa(r.WorkRejected) + `,"missed":` + strconv.Itoa(r.Missed) + `,"wins":` + strconv.Itoa(r.Wins) + `,"paid_places":` + strconv.Itoa(r.Podiums) +
		`,"earned_ugnot":` + i64(r.Earned) + `,"disputes_won":` + strconv.Itoa(r.ADisputesWon) + `,"disputes_lost":` + strconv.Itoa(r.ADisputesLost) +
		`,"rating_x10":` + strconv.Itoa(avg10(r.AgentRatingSum, r.AgentRatingN)) + `,"ratings":` + strconv.Itoa(r.AgentRatingN) + `,"badges":` + badgesJSON(agentBadges(r)) + `}` +
		`,"reports_against":` + strconv.Itoa(r.ReportsAgainst) + `,"upheld_against":` + strconv.Itoa(r.UpheldAgainst) + `,"reports_filed":` + strconv.Itoa(r.ReportsFiled) + `}`
}

func profileJSON(a address) string {
	r := peekRep(a)
	if r == nil {
		r = &Rep{Addr: a}
	}
	var rs []string
	if list, _ := ratingsOf.Get(a.String()).([]*Rating); len(list) > 0 {
		for i := len(list) - 1; i >= 0; i-- {
			rt := list[i]
			rs = append(rs, `{"kind":`+jq(rt.Kind)+`,"item":`+strconv.Itoa(rt.ItemID)+`,"rater":`+jq(rt.Rater.String())+
				`,"as_giver":`+strconv.FormatBool(rt.AsGiver)+`,"score":`+strconv.Itoa(rt.Score)+`,"comment":`+jq(rt.Comment)+`,"at_unix":`+ts(rt.At)+`}`)
		}
	}
	p := repJSON(r)
	return p[:len(p)-1] + `,"ratings":[` + strings.Join(rs, ",") + `],"reports":` + idsJSON(reportsAbout, a.String()) + `}`
}

func reportJSON(r *ReportRec) string {
	return `{"id":` + strconv.Itoa(r.ID) + `,"kind":` + jq(r.Kind) + `,"item":` + strconv.Itoa(r.ItemID) +
		`,"reporter":` + jq(r.Reporter.String()) + `,"target":` + jq(r.Target.String()) + `,"reason":` + jq(r.Reason) +
		`,"text":` + jq(r.Text) + `,"evidence":` + jq(r.Evidence) + `,"facts":` + jq(r.Facts) +
		`,"upheld":` + strconv.FormatBool(r.Upheld) + `,"basis":` + jq(r.Basis) + `,"at_unix":` + ts(r.At) +
		`,"response":` + jq(r.Response) + `,"responded_unix":` + unixOr0(r.RespondedAt) + `}`
}
