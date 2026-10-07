package bounties

import (
	"chain"
	"net/url"
	"strconv"
	"strings"

	"gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/guildhall/bounty/v0"
	"gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/guildhall/jsonw/v0"
	"gno.land/p/nt/avl/v0"
	"gno.land/r/nt/grc20reg/v0"
)

const (
	realmPath   = "gno.land/r/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/guildhall/bounties"
	apiMaxLimit = 50
	apiMaxScan  = 2000
	apiMaxToken = 200
)

// renderAPI serves JSON for the web app, under Render("api/..."):
//
//	api/stats                       counts, escrow totals, council, paused
//	api/bounties?status=&tag=&page=&limit=   newest first; status "all" or empty for every bounty
//	api/bounty/<id>                 a bounty with milestones, disputes and applications
//	api/user/<address>?page=&limit= bounties an address is involved in, with roles
//	api/tokens                      registered GRC20 tokens usable for funding
func renderAPI(route string, q url.Values) string {
	parts := strings.Split(route, "/")
	switch {
	case route == "api/stats":
		return apiStats()
	case route == "api/bounties":
		return apiList(q)
	case len(parts) == 3 && parts[1] == "bounty":
		id, err := strconv.ParseUint(parts[2], 10, 64)
		if err != nil {
			return apiError("invalid id")
		}
		bn := getBounty(id)
		if bn == nil {
			return apiError("not found")
		}
		return bountyJSON(bn, true)
	case len(parts) == 3 && parts[1] == "user":
		return apiUser(address(parts[2]), q)
	case route == "api/tokens":
		return apiTokens()
	}
	return apiError("unknown endpoint")
}

func apiStats() string {
	var escrow []string
	escrowed.Iterate("", "", func(k string, v any) bool {
		if amt := v.(int64); amt > 0 {
			escrow = append(escrow, jsonw.Obj(append([]string{"amount", jsonw.Int(amt)}, denomFields(k, grc20reg.Get(k) != nil)...)...))
		}
		return false
	})
	return jsonw.Obj(
		"total", jsonw.Int(int64(bounties.Size())),
		"open", jsonw.Int(int64(statusCount[bounty.StatusOpen])),
		"active", jsonw.Int(int64(statusCount[bounty.StatusActive])),
		"completed", jsonw.Int(int64(statusCount[bounty.StatusCompleted])),
		"cancelled", jsonw.Int(int64(statusCount[bounty.StatusCancelled])),
		"escrow", jsonw.Arr(escrow),
		"council", jsonw.String(council.Owner().String()),
		"paused", jsonw.Bool(paused),
		"realmAddress", jsonw.String(chain.PackageAddress(realmPath).String()),
	)
}

func apiList(q url.Values) string {
	status := q.Get("status")
	want, filtered := bounty.ParseStatus(status)
	if status != "" && status != "all" && !filtered {
		return apiError("unknown status")
	}
	tag := strings.ToLower(q.Get("tag"))
	limit := limitOf(q)
	skip := (pageOf(q) - 1) * limit

	var items []string
	more := false
	scanned := 0
	bounties.ReverseIterate("", "", func(_ string, v any) bool {
		scanned++
		if scanned > apiMaxScan {
			more = true
			return true
		}
		bn := v.(*bounty.Bounty)
		if filtered && bn.Status != want {
			return false
		}
		if tag != "" && !hasTag(bn, tag) {
			return false
		}
		if skip > 0 {
			skip--
			return false
		}
		if len(items) == limit {
			more = true
			return true
		}
		items = append(items, bountyJSON(bn, false))
		return false
	})
	return jsonw.Obj("items", jsonw.Arr(items), "more", jsonw.Bool(more))
}

func apiUser(addr address, q url.Values) string {
	if !addr.IsValid() {
		return apiError("invalid address")
	}
	limit := limitOf(q)
	var items []string
	more := false
	if v := byUser.Get(addr.String()); v != nil {
		ids := v.(*avl.Tree)
		ids.ReverseIterateByOffset((pageOf(q)-1)*limit, limit, func(k string, _ any) bool {
			if bv := bounties.Get(k); bv != nil {
				bn := bv.(*bounty.Bounty)
				items = append(items, jsonw.Obj("bounty", bountyJSON(bn, false), "roles", jsonw.Strings(roles(bn, addr))))
			}
			return false
		})
		more = ids.Size() > pageOf(q)*limit
	}
	return jsonw.Obj("items", jsonw.Arr(items), "more", jsonw.Bool(more))
}

func apiTokens() string {
	var items []string
	grc20reg.GetRegistry().Iterate("", "", func(k string, _ any) bool {
		tok := grc20reg.Get(k)
		if tok == nil {
			return false
		}
		items = append(items, jsonw.Obj(
			"key", jsonw.String(k),
			"name", jsonw.String(tok.GetName()),
			"symbol", jsonw.String(tok.GetSymbol()),
			"decimals", jsonw.Int(int64(tok.GetDecimals())),
		))
		return len(items) >= apiMaxToken
	})
	return jsonw.Obj("items", jsonw.Arr(items))
}

func bountyJSON(bn *bounty.Bounty, full bool) string {
	ms := make([]string, len(bn.Milestones))
	for i, m := range bn.Milestones {
		fields := []string{
			"title", jsonw.String(m.Title),
			"amount", jsonw.Int(m.Amount),
			"status", jsonw.String(m.Status.String()),
		}
		if full {
			dispute := jsonw.Null
			if d := m.Dispute; d != nil {
				dispute = jsonw.Obj(
					"openedBy", jsonw.String(d.OpenedBy.String()),
					"reason", jsonw.String(d.Reason),
					"openedAt", jsonw.Time(d.OpenedAt),
					"resolved", jsonw.Bool(d.Resolved),
					"resolvedAt", jsonw.Time(d.ResolvedAt),
					"workerBps", jsonw.Int(d.WorkerBps),
					"ruling", jsonw.String(d.Ruling),
				)
			}
			fields = append(fields,
				"submission", jsonw.String(m.Submission),
				"submittedAt", jsonw.Time(m.SubmittedAt),
				"approvals", jsonw.Addresses(m.Approvals),
				"feedback", jsonw.String(m.Feedback),
				"worker", jsonw.String(m.Worker.String()),
				"paidOut", jsonw.Int(m.PaidOut),
				"refunded", jsonw.Int(m.Refunded),
				"settledAt", jsonw.Time(m.SettleAt),
				"dispute", dispute,
			)
		}
		ms[i] = jsonw.Obj(fields...)
	}

	fields := []string{
		"id", jsonw.Uint(bn.ID),
		"title", jsonw.String(bn.Title),
		"tags", jsonw.Strings(bn.Tags),
		"status", jsonw.String(bn.Status.String()),
		"poster", jsonw.String(bn.Poster.String()),
		"assignee", jsonw.String(bn.Assignee.String()),
		"total", jsonw.Int(bn.Total()),
		"escrowed", jsonw.Int(bn.Escrowed()),
		"paidOut", jsonw.Int(bn.PaidOut()),
		"applications", jsonw.Int(int64(len(bn.Applications))),
		"createdAt", jsonw.Time(bn.CreatedAt),
		"milestones", jsonw.Arr(ms),
	}
	fields = append(fields, denomFields(bn.Denom, bn.IsGRC20)...)
	if full {
		var apps []string
		for _, a := range bn.Applications {
			apps = append(apps, jsonw.Obj(
				"applicant", jsonw.String(a.Applicant.String()),
				"pitch", jsonw.String(a.Pitch),
				"at", jsonw.Time(a.At),
			))
		}
		fields = append(fields,
			"description", jsonw.String(bn.Description),
			"link", jsonw.String(bn.Link),
			"reviewers", jsonw.Addresses(bn.Reviewers),
			"quorum", jsonw.Int(int64(bn.Quorum)),
			"arbiter", jsonw.String(bn.Arbiter.String()),
			"councilArbitrated", jsonw.Bool(councilArbitrated.Has(idKey(bn.ID))),
			"council", jsonw.String(council.Owner().String()),
			"workWindowDays", jsonw.Int(int64(bn.WorkWindow.Hours()/24)),
			"assignedAt", jsonw.Time(bn.AssignedAt),
			"closedAt", jsonw.Time(bn.ClosedAt),
			"applicationList", jsonw.Arr(apps),
		)
	}
	return jsonw.Obj(fields...)
}

// denomFields describes how to display amounts of denom.
func denomFields(denom string, isGRC20 bool) []string {
	symbol, decimals := denom, 0
	switch {
	case isGRC20:
		if tok := grc20reg.Get(denom); tok != nil {
			symbol, decimals = tok.GetSymbol(), tok.GetDecimals()
		}
	case denom == "ugnot":
		symbol, decimals = "GNOT", 6
	}
	return []string{
		"denom", jsonw.String(denom),
		"isGRC20", jsonw.Bool(isGRC20),
		"symbol", jsonw.String(symbol),
		"decimals", jsonw.Int(int64(decimals)),
	}
}

func roles(bn *bounty.Bounty, addr address) []string {
	var out []string
	if bn.Poster == addr {
		out = append(out, "poster")
	}
	if bn.Assignee == addr {
		out = append(out, "assignee")
	}
	if bn.IsReviewer(addr) {
		out = append(out, "reviewer")
	}
	if bn.Arbiter == addr {
		out = append(out, "arbiter")
	}
	if bn.HasApplied(addr) && bn.Assignee != addr {
		out = append(out, "applicant")
	}
	for _, m := range bn.Milestones {
		if m.Worker == addr && bn.Assignee != addr {
			out = append(out, "contributor")
			break
		}
	}
	return out
}

func limitOf(q url.Values) int {
	n, err := strconv.Atoi(q.Get("limit"))
	if err != nil || n < 1 {
		return 20
	}
	if n > apiMaxLimit {
		return apiMaxLimit
	}
	return n
}

func apiError(msg string) string {
	return jsonw.Obj("error", jsonw.String(msg))
}
