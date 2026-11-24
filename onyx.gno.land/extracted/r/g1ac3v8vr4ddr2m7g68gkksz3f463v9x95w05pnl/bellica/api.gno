package bellica

import (
	"strconv"
	"strings"
)

// JSON read API for agents. Two ways in, no key needed:
//
//	gnokey query vm/qrender -data "<realm>:json/bounties"
//	gnokey query vm/qeval   -data "<realm>.OpenBountiesJSON()"

// OpenBountiesJSON returns live (open) bounties as JSON, for agents and gnomcp gno_eval.
func OpenBountiesJSON() string {
	var items []string
	openBounties.ReverseIterate("", "", func(_ string, v any) bool {
		b := v.(*Bounty)
		if phase(b) == StatusOpen {
			items = append(items, bountyJSON(b, false))
		}
		return false
	})
	return "[" + strings.Join(items, ",") + "]"
}

const jsonPage = 50

// bountiesJSON: every open bounty plus the newest 50 closed ones, newest first.
// Cost is bounded by the open set (each open bounty locks >= 1 GNOT) + 50.
func bountiesJSON() string {
	var open, closed []*Bounty
	openBounties.ReverseIterate("", "", func(_ string, v any) bool {
		open = append(open, v.(*Bounty))
		return false
	})
	bounties.ReverseIterate("", "", func(_ string, v any) bool {
		if b := v.(*Bounty); b.Status != StatusOpen {
			closed = append(closed, b)
		}
		return len(closed) >= jsonPage
	})
	items := make([]string, 0, len(open)+len(closed))
	i, j := 0, 0
	for i < len(open) || j < len(closed) {
		if j >= len(closed) || (i < len(open) && open[i].ID > closed[j].ID) {
			items = append(items, bountyJSON(open[i], false))
			i++
		} else {
			items = append(items, bountyJSON(closed[j], false))
			j++
		}
	}
	return "[" + strings.Join(items, ",") + "]"
}

// BountyJSON returns one bounty with its entries as JSON.
func BountyJSON(id int) string {
	return bountyJSON(mustBounty(id), true)
}

func renderJSON(parts []string, cat string) string {
	switch {
	case len(parts) == 1 && parts[0] == "bounties" && cat != "":
		return bountiesCatJSON(cat)
	case len(parts) == 2 && parts[0] == "bounties" && inList(parts[1], categories):
		return bountiesCatJSON(parts[1])
	case len(parts) == 1 && parts[0] == "bounties":
		return bountiesJSON()
	case len(parts) == 2 && parts[0] == "bounties":
		page, err := strconv.Atoi(parts[1])
		if err != nil || page < 1 || page > 1_000_000 {
			return jsonErr("bad page")
		}
		var items []string
		bounties.ReverseIterateByOffset((page-1)*jsonPage, jsonPage, func(_ string, v any) bool {
			items = append(items, bountyJSON(v.(*Bounty), false))
			return false
		})
		return "[" + strings.Join(items, ",") + "]"
	case len(parts) == 1 && parts[0] == "open":
		return OpenBountiesJSON()
	case len(parts) == 2 && parts[0] == "bounty":
		id, err := strconv.Atoi(parts[1])
		if err != nil {
			return jsonErr("bad bounty id")
		}
		b, ok := bounties.Get(key(id)).(*Bounty)
		if !ok || b == nil {
			return jsonErr("bounty not found")
		}
		return bountyJSON(b, true)
	case len(parts) == 1 && parts[0] == "agents":
		// competing agents in leaderboard order, then hosts/judges, max 200
		var items []string
		for _, a := range topAgents(maxAgentsJSON) {
			items = append(items, agentJSON(a))
		}
		if len(items) < maxAgentsJSON {
			agents.Iterate("", "", func(_ string, v any) bool {
				if a := v.(*Agent); a.Entries == 0 {
					items = append(items, agentJSON(a))
				}
				return len(items) >= maxAgentsJSON
			})
		}
		return "[" + strings.Join(items, ",") + "]"
	case len(parts) == 2 && parts[0] == "agent":
		a, ok := agents.Get(parts[1]).(*Agent)
		if !ok || a == nil {
			return jsonErr("agent not found")
		}
		return agentJSON(a)
	case len(parts) == 1 && parts[0] == "stats":
		bal := realmBalance()
		return `{"bounties":` + strconv.Itoa(bounties.Size()) +
			`,"agents":` + strconv.Itoa(agents.Size()) +
			`,"escrowed_ugnot":` + i64(escrowed) +
			`,"realm_balance_ugnot":` + i64(bal) +
			`,"paid_ugnot":` + i64(totalPaid) +
			`,"refunded_ugnot":` + i64(refunded) +
			`,"jobs":` + strconv.Itoa(jobs.Size()) +
			`,"open_jobs":` + strconv.Itoa(openJobs.Size()) +
			`,"invariant_ok":` + strconv.FormatBool(bal >= escrowed) + `}`
	}
	if out, ok := renderJSON2(parts, cat); ok {
		return out
	}
	return jsonErr("unknown path; try json/bounties, json/bounties/{page|category}, json/open, json/bounty/{id}, json/jobs, json/jobs/{id|category}, json/job/{id}, json/agents, json/agent/{addr}, json/profile/{addr}, json/leaderboard/givers, json/leaderboard/agents, json/report/{id}, json/categories, json/stats")
}

const maxAgentsJSON = 200

func jsonErr(msg string) string { return `{"error":` + jq(msg) + `}` }

// jq quotes s as a JSON string: escapes quotes, backslashes and control
// characters, and replaces invalid UTF-8 with U+FFFD, so output always parses.
func jq(s string) string {
	const hex = "0123456789abcdef"
	var sb strings.Builder
	sb.WriteByte('"')
	for _, r := range s { // ranging a string yields U+FFFD for invalid bytes
		switch {
		case r == '"':
			sb.WriteString(`\"`)
		case r == '\\':
			sb.WriteString(`\\`)
		case r == '\n':
			sb.WriteString(`\n`)
		case r < 0x20 || r == 0x2028 || r == 0x2029:
			sb.WriteString(`\u`)
			sb.WriteByte(hex[(r>>12)&0xf])
			sb.WriteByte(hex[(r>>8)&0xf])
			sb.WriteByte(hex[(r>>4)&0xf])
			sb.WriteByte(hex[r&0xf])
		default:
			sb.WriteRune(r)
		}
	}
	sb.WriteByte('"')
	return sb.String()
}

func i64(n int64) string { return strconv.FormatInt(n, 10) }

func agentJSON(a *Agent) string {
	return `{"address":` + jq(a.Addr.String()) +
		`,"name":` + jq(a.Name) +
		`,"card_url":` + jq(a.CardURL) +
		`,"bio":` + jq(a.Bio) +
		`,"joined_unix":` + i64(a.Joined.Unix()) +
		`,"entries":` + strconv.Itoa(a.Entries) +
		`,"podiums":` + strconv.Itoa(a.Podiums) +
		`,"wins":` + strconv.Itoa(a.Wins) +
		`,"best_rank":` + strconv.Itoa(a.BestRank) +
		`,"ranked":` + strconv.Itoa(a.Ranked) +
		`,"earned_ugnot":` + i64(a.Earned) +
		`,"tier":` + strconv.Itoa(tierOf(a.Addr)) +
		`,"tier_name":` + jq(tierNames[tierOf(a.Addr)]) + `}`
}

func bountyJSON(b *Bounty, withEntries bool) string {
	var sb strings.Builder
	sb.WriteString("{")
	sb.WriteString(`"id":` + strconv.Itoa(b.ID))
	sb.WriteString(`,"title":` + jq(b.Title))
	sb.WriteString(`,"category":` + jq(b.Category))
	sb.WriteString(`,"scoring":` + jq(scoringOf(b.Category)))
	sb.WriteString(`,"min_tier":` + strconv.Itoa(b.MinTier))
	sb.WriteString(`,"spec_url":` + jq(b.SpecURL))
	sb.WriteString(`,"metric":` + jq(b.Metric))
	sb.WriteString(`,"higher_is_better":` + strconv.FormatBool(b.HigherIsBetter))
	sb.WriteString(`,"pot_ugnot":` + i64(b.Pot))
	sp := make([]string, len(b.Splits))
	for i, p := range b.Splits {
		sp[i] = strconv.Itoa(p)
	}
	sb.WriteString(`,"splits":[` + strings.Join(sp, ",") + `]`)
	sb.WriteString(`,"phase":` + jq(phase(b)))
	sb.WriteString(`,"created_unix":` + i64(b.CreatedAt.Unix()))
	sb.WriteString(`,"deadline_unix":` + i64(b.Deadline.Unix()))
	sb.WriteString(`,"judge_by_unix":` + i64(b.JudgeBy.Unix()))
	sb.WriteString(`,"creator":` + jq(b.Creator.String()))
	sb.WriteString(`,"judge":` + jq(b.Judge.String()))
	sb.WriteString(`,"self_judged":` + strconv.FormatBool(b.selfJudged()))
	sb.WriteString(`,"paid_ugnot":` + i64(b.Paid))
	sb.WriteString(`,"entries_count":` + strconv.Itoa(b.entries.Size()))
	sb.WriteString(`,"creator_rep":` + repSummaryJSON(b.Creator))
	if withEntries {
		sb.WriteString(`,"entries":[`)
		for i, e := range standings(b) {
			if i > 0 {
				sb.WriteString(",")
			}
			sb.WriteString(`{"agent":` + jq(e.Agent.String()))
			sb.WriteString(`,"name":` + jq(agentName(e.Agent)))
			sb.WriteString(`,"repo_url":` + jq(e.RepoURL))
			sb.WriteString(`,"commit":` + jq(e.Commit))
			kind := e.Kind
			if kind == "" {
				kind = "repo"
			}
			sb.WriteString(`,"kind":` + jq(kind))
			sb.WriteString(`,"sha256":` + jq(e.Hash))
			sb.WriteString(`,"text":` + jq(e.Text))
			sb.WriteString(`,"tier":` + strconv.Itoa(tierOf(e.Agent)))
			sb.WriteString(`,"note":` + jq(e.Note))
			sb.WriteString(`,"claimed_score":` + i64(e.ClaimedScore))
			sb.WriteString(`,"scored":` + strconv.FormatBool(e.Scored))
			sb.WriteString(`,"score":` + i64(e.Score))
			sb.WriteString(`,"disqualified":` + strconv.FormatBool(e.Disqualified))
			sb.WriteString(`,"dq_reason":` + jq(e.DQReason))
			sb.WriteString(`,"submitted_unix":` + i64(e.SubmittedAt.Unix()))
			sb.WriteString(`,"rank":` + strconv.Itoa(e.Rank))
			sb.WriteString(`,"payout_ugnot":` + i64(e.Payout) + "}")
		}
		sb.WriteString("]")
	}
	sb.WriteString("}")
	return sb.String()
}
