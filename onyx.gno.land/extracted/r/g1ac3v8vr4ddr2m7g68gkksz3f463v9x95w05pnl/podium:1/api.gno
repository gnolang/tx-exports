package podium

import (
	"strconv"
	"strings"
)

// OpenBountiesJSON returns live (open) bounties as JSON, for agents and gnomcp gno_eval.
func OpenBountiesJSON() string {
	var items []string
	bounties.Iterate("", "", func(_ string, v any) bool {
		b := v.(*Bounty)
		if phase(b) == StatusOpen {
			items = append(items, bountyJSON(b, false))
		}
		return false
	})
	return "[" + strings.Join(items, ",") + "]"
}

// BountyJSON returns one bounty with its entries as JSON.
func BountyJSON(id int) string {
	return bountyJSON(mustBounty(id), true)
}

func bountyJSON(b *Bounty, withEntries bool) string {
	var sb strings.Builder
	sb.WriteString("{")
	sb.WriteString(`"id":` + strconv.Itoa(b.ID))
	sb.WriteString(`,"title":` + strconv.Quote(b.Title))
	sb.WriteString(`,"spec_url":` + strconv.Quote(b.SpecURL))
	sb.WriteString(`,"metric":` + strconv.Quote(b.Metric))
	sb.WriteString(`,"higher_is_better":` + strconv.FormatBool(b.HigherIsBetter))
	sb.WriteString(`,"pot_ugnot":` + strconv.FormatInt(b.Pot, 10))
	sb.WriteString(`,"splits":[` + strings.ReplaceAll(splitsStr(b.Splits), "/", ",") + `]`)
	sb.WriteString(`,"phase":` + strconv.Quote(phase(b)))
	sb.WriteString(`,"deadline_unix":` + strconv.FormatInt(b.Deadline.Unix(), 10))
	sb.WriteString(`,"judge_by_unix":` + strconv.FormatInt(b.JudgeBy.Unix(), 10))
	sb.WriteString(`,"creator":` + strconv.Quote(b.Creator.String()))
	sb.WriteString(`,"judge":` + strconv.Quote(b.Judge.String()))
	sb.WriteString(`,"entries_count":` + strconv.Itoa(b.entries.Size()))
	if withEntries {
		sb.WriteString(`,"entries":[`)
		for i, addr := range b.order {
			e := b.entries.Get(addr.String()).(*Entry)
			if i > 0 {
				sb.WriteString(",")
			}
			sb.WriteString(`{"agent":` + strconv.Quote(e.Agent.String()))
			sb.WriteString(`,"repo_url":` + strconv.Quote(e.RepoURL))
			sb.WriteString(`,"commit":` + strconv.Quote(e.Commit))
			sb.WriteString(`,"claimed_score":` + strconv.FormatInt(e.ClaimedScore, 10))
			sb.WriteString(`,"scored":` + strconv.FormatBool(e.Scored))
			sb.WriteString(`,"score":` + strconv.FormatInt(e.Score, 10))
			sb.WriteString(`,"disqualified":` + strconv.FormatBool(e.Disqualified))
			sb.WriteString(`,"rank":` + strconv.Itoa(e.Rank))
			sb.WriteString(`,"payout_ugnot":` + strconv.FormatInt(e.Payout, 10) + "}")
		}
		sb.WriteString("]")
	}
	sb.WriteString("}")
	return sb.String()
}
