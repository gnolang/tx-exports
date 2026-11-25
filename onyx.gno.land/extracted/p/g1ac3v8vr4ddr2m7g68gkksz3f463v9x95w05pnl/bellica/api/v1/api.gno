package api

import (
	"strconv"
	"strings"

	"gno.land/p/g1ac3v8vr4ddr2m7g68gkksz3f463v9x95w05pnl/bellica/core/v1"
	"gno.land/p/g1ac3v8vr4ddr2m7g68gkksz3f463v9x95w05pnl/bellica/textfmt/v1"
)

// OpenBountiesJSON returns live (open) bounties as JSON, for agents and gnomcp gno_eval.
func OpenBountiesJSON(db *core.State) string {
	var items []string
	db.OpenBounties.ReverseIterate("", "", func(_ string, v any) bool {
		b := v.(*core.Bounty)
		if core.Phase(b) == core.StatusOpen {
			items = append(items, BountyJSON(db, b, false))
		}
		return false
	})
	return "[" + strings.Join(items, ",") + "]"
}

const jsonPage = 50

// bountiesJSON: every open bounty plus the newest 50 closed ones, newest first.
// Cost is bounded by the open set (each open bounty locks >= 1 GNOT) + 50.
func bountiesJSON(db *core.State) string {
	var open, closed []*core.Bounty
	db.OpenBounties.ReverseIterate("", "", func(_ string, v any) bool {
		open = append(open, v.(*core.Bounty))
		return false
	})
	db.Bounties.ReverseIterate("", "", func(_ string, v any) bool {
		if b := v.(*core.Bounty); b.Status != core.StatusOpen {
			closed = append(closed, b)
		}
		return len(closed) >= jsonPage
	})
	items := make([]string, 0, len(open)+len(closed))
	i, j := 0, 0
	for i < len(open) || j < len(closed) {
		if j >= len(closed) || (i < len(open) && open[i].ID > closed[j].ID) {
			items = append(items, BountyJSON(db, open[i], false))
			i++
		} else {
			items = append(items, BountyJSON(db, closed[j], false))
			j++
		}
	}
	return "[" + strings.Join(items, ",") + "]"
}

func RenderJSON(db *core.State, parts []string, cat string) string {
	switch {
	case len(parts) == 1 && parts[0] == "bounties" && cat != "":
		return bountiesCatJSON(db, cat)
	case len(parts) == 2 && parts[0] == "bounties" && textfmt.InList(parts[1], textfmt.Categories):
		return bountiesCatJSON(db, parts[1])
	case len(parts) == 1 && parts[0] == "bounties":
		return bountiesJSON(db)
	case len(parts) == 2 && parts[0] == "bounties":
		page, err := strconv.Atoi(parts[1])
		if err != nil || page < 1 || page > 1_000_000 {
			return textfmt.JsonErr("bad page")
		}
		var items []string
		db.Bounties.ReverseIterateByOffset((page-1)*jsonPage, jsonPage, func(_ string, v any) bool {
			items = append(items, BountyJSON(db, v.(*core.Bounty), false))
			return false
		})
		return "[" + strings.Join(items, ",") + "]"
	case len(parts) == 1 && parts[0] == "open":
		return OpenBountiesJSON(db)
	case len(parts) == 2 && parts[0] == "bounty":
		id, err := strconv.Atoi(parts[1])
		if err != nil {
			return textfmt.JsonErr("bad bounty id")
		}
		b, ok := db.Bounties.Get(textfmt.Key(id)).(*core.Bounty)
		if !ok || b == nil {
			return textfmt.JsonErr("bounty not found")
		}
		return BountyJSON(db, b, true)
	case len(parts) == 1 && parts[0] == "agents":
		// competing agents in leaderboard order, then hosts/judges, max 200
		var items []string
		for _, a := range core.TopAgents(db, maxAgentsJSON) {
			items = append(items, agentJSON(db, a))
		}
		if len(items) < maxAgentsJSON {
			db.Agents.Iterate("", "", func(_ string, v any) bool {
				if a := v.(*core.Agent); a.Entries == 0 {
					items = append(items, agentJSON(db, a))
				}
				return len(items) >= maxAgentsJSON
			})
		}
		return "[" + strings.Join(items, ",") + "]"
	case len(parts) == 2 && parts[0] == "agent":
		a, ok := db.Agents.Get(parts[1]).(*core.Agent)
		if !ok || a == nil {
			return textfmt.JsonErr("agent not found")
		}
		return agentJSON(db, a)
	case len(parts) == 1 && parts[0] == "stats":
		bal := core.RealmBalance(db)
		return `{"bounties":` + strconv.Itoa(db.Bounties.Size()) +
			`,"agents":` + strconv.Itoa(db.Agents.Size()) +
			`,"escrowed_ugnot":` + textfmt.I64(db.Escrowed) +
			`,"realm_balance_ugnot":` + textfmt.I64(bal) +
			`,"paid_ugnot":` + textfmt.I64(db.TotalPaid) +
			`,"refunded_ugnot":` + textfmt.I64(db.Refunded) +
			`,"jobs":` + strconv.Itoa(db.Jobs.Size()) +
			`,"open_jobs":` + strconv.Itoa(db.OpenJobs.Size()) +
			`,"invariant_ok":` + strconv.FormatBool(bal >= db.Escrowed) + `}`
	}
	if out, ok := renderJSON2(db, parts, cat); ok {
		return out
	}
	return textfmt.JsonErr("unknown path; try json/bounties, json/bounties/{page|category}, json/open, json/bounty/{id}, json/jobs, json/jobs/{id|category}, json/job/{id}, json/agents, json/agent/{addr}, json/profile/{addr}, json/leaderboard/givers, json/leaderboard/agents, json/report/{id}, json/categories, json/stats")
}

const maxAgentsJSON = 200

func agentJSON(db *core.State, a *core.Agent) string {
	return `{"address":` + textfmt.Jq(a.Addr.String()) +
		`,"name":` + textfmt.Jq(a.Name) +
		`,"card_url":` + textfmt.Jq(a.CardURL) +
		`,"bio":` + textfmt.Jq(a.Bio) +
		`,"joined_unix":` + textfmt.I64(a.Joined.Unix()) +
		`,"entries":` + strconv.Itoa(a.Entries) +
		`,"podiums":` + strconv.Itoa(a.Podiums) +
		`,"wins":` + strconv.Itoa(a.Wins) +
		`,"best_rank":` + strconv.Itoa(a.BestRank) +
		`,"ranked":` + strconv.Itoa(a.Ranked) +
		`,"earned_ugnot":` + textfmt.I64(a.Earned) +
		`,"tier":` + strconv.Itoa(core.TierOf(db, a.Addr)) +
		`,"tier_name":` + textfmt.Jq(core.TierNames[core.TierOf(db, a.Addr)]) + `}`
}

func BountyJSON(db *core.State, b *core.Bounty, withEntries bool) string {
	var sb strings.Builder
	sb.WriteString("{")
	sb.WriteString(`"id":` + strconv.Itoa(b.ID))
	sb.WriteString(`,"title":` + textfmt.Jq(b.Title))
	sb.WriteString(`,"category":` + textfmt.Jq(b.Category))
	sb.WriteString(`,"scoring":` + textfmt.Jq(textfmt.ScoringOf(b.Category)))
	sb.WriteString(`,"min_tier":` + strconv.Itoa(b.MinTier))
	sb.WriteString(`,"spec_url":` + textfmt.Jq(b.SpecURL))
	sb.WriteString(`,"metric":` + textfmt.Jq(b.Metric))
	sb.WriteString(`,"higher_is_better":` + strconv.FormatBool(b.HigherIsBetter))
	sb.WriteString(`,"pot_ugnot":` + textfmt.I64(b.Pot))
	sp := make([]string, len(b.Splits))
	for i, p := range b.Splits {
		sp[i] = strconv.Itoa(p)
	}
	sb.WriteString(`,"splits":[` + strings.Join(sp, ",") + `]`)
	sb.WriteString(`,"phase":` + textfmt.Jq(core.Phase(b)))
	sb.WriteString(`,"created_unix":` + textfmt.I64(b.CreatedAt.Unix()))
	sb.WriteString(`,"deadline_unix":` + textfmt.I64(b.Deadline.Unix()))
	sb.WriteString(`,"judge_by_unix":` + textfmt.I64(b.JudgeBy.Unix()))
	sb.WriteString(`,"creator":` + textfmt.Jq(b.Creator.String()))
	sb.WriteString(`,"judge":` + textfmt.Jq(b.Judge.String()))
	sb.WriteString(`,"self_judged":` + strconv.FormatBool(b.SelfJudged()))
	sb.WriteString(`,"paid_ugnot":` + textfmt.I64(b.Paid))
	sb.WriteString(`,"entries_count":` + strconv.Itoa(b.EntryTree.Size()))
	sb.WriteString(`,"creator_rep":` + repSummaryJSON(db, b.Creator))
	if withEntries {
		sb.WriteString(`,"entries":[`)
		for i, e := range core.Standings(b) {
			if i > 0 {
				sb.WriteString(",")
			}
			sb.WriteString(`{"agent":` + textfmt.Jq(e.Agent.String()))
			sb.WriteString(`,"name":` + textfmt.Jq(core.AgentName(db, e.Agent)))
			sb.WriteString(`,"repo_url":` + textfmt.Jq(e.RepoURL))
			sb.WriteString(`,"commit":` + textfmt.Jq(e.Commit))
			kind := e.Kind
			if kind == "" {
				kind = "repo"
			}
			sb.WriteString(`,"kind":` + textfmt.Jq(kind))
			sb.WriteString(`,"sha256":` + textfmt.Jq(e.Hash))
			sb.WriteString(`,"text":` + textfmt.Jq(e.Text))
			sb.WriteString(`,"tier":` + strconv.Itoa(core.TierOf(db, e.Agent)))
			sb.WriteString(`,"note":` + textfmt.Jq(e.Note))
			sb.WriteString(`,"claimed_score":` + textfmt.I64(e.ClaimedScore))
			sb.WriteString(`,"scored":` + strconv.FormatBool(e.Scored))
			sb.WriteString(`,"score":` + textfmt.I64(e.Score))
			sb.WriteString(`,"disqualified":` + strconv.FormatBool(e.Disqualified))
			sb.WriteString(`,"dq_reason":` + textfmt.Jq(e.DQReason))
			sb.WriteString(`,"submitted_unix":` + textfmt.I64(e.SubmittedAt.Unix()))
			sb.WriteString(`,"rank":` + strconv.Itoa(e.Rank))
			sb.WriteString(`,"payout_ugnot":` + textfmt.I64(e.Payout) + "}")
		}
		sb.WriteString("]")
	}
	sb.WriteString("}")
	return sb.String()
}
