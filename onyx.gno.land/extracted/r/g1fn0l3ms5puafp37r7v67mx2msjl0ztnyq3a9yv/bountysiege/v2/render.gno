package bountysiege

import (
	"strconv"
	"strings"
	"time"

	"gno.land/p/g1fn0l3ms5puafp37r7v67mx2msjl0ztnyq3a9yv/bs_core"
)

func Render(path string) string {
	route, query := splitPathQuery(path)

	switch {
	case route == "json/summary":
		return renderSummaryJSON()
	case route == "json/quests":
		page, limit := parsePageLimit(query)
		return renderQuestsJSON(page, limit, parseQueryParam(query, "status"), parseQueryParam(query, "cat"))
	case route == "json/contests":
		page, limit := parsePageLimit(query)
		return renderContestsJSON(page, limit, parseQueryParam(query, "status"), parseQueryParam(query, "cat"))
	case route == "json/raids":
		page, limit := parsePageLimit(query)
		return renderRaidsJSON(page, limit, parseQueryParam(query, "status"))
	case strings.HasPrefix(route, "json/quest/"):
		id, ok := parseID(strings.TrimPrefix(route, "json/quest/"))
		if !ok {
			return `{"error":"invalid quest id"}`
		}
		q, exists := questsByID[id]
		if !exists {
			return `{"error":"quest not found"}`
		}
		return renderQuestDetailJSON(q)
	case strings.HasPrefix(route, "json/contest/"):
		id, ok := parseID(strings.TrimPrefix(route, "json/contest/"))
		if !ok {
			return `{"error":"invalid contest id"}`
		}
		c, exists := contestsByID[id]
		if !exists {
			return `{"error":"contest not found"}`
		}
		return renderContestDetailJSON(c)
	case strings.HasPrefix(route, "json/raid/"):
		id, ok := parseID(strings.TrimPrefix(route, "json/raid/"))
		if !ok {
			return `{"error":"invalid raid id"}`
		}
		r, exists := raidsByID[id]
		if !exists {
			return `{"error":"raid not found"}`
		}
		return renderRaidDetailJSON(r)
	case strings.HasPrefix(route, "json/my/"):
		addrStr := strings.TrimPrefix(route, "json/my/")
		page, limit := parsePageLimit(query)
		return renderMyDashboardJSON(address(addrStr), page, limit)
	case strings.HasPrefix(route, "quest/"):
		id, ok := parseID(strings.TrimPrefix(route, "quest/"))
		if !ok {
			return "# Invalid Quest ID\n"
		}
		q, exists := questsByID[id]
		if !exists {
			return "# Quest Not Found\n"
		}
		return renderQuestMarkdown(q)
	case strings.HasPrefix(route, "contest/"):
		id, ok := parseID(strings.TrimPrefix(route, "contest/"))
		if !ok {
			return "# Invalid Contest ID\n"
		}
		c, exists := contestsByID[id]
		if !exists {
			return "# Contest Not Found\n"
		}
		return renderContestMarkdown(c)
	case strings.HasPrefix(route, "raid/"):
		id, ok := parseID(strings.TrimPrefix(route, "raid/"))
		if !ok {
			return "# Invalid Raid ID\n"
		}
		r, exists := raidsByID[id]
		if !exists {
			return "# Raid Not Found\n"
		}
		return renderRaidMarkdown(r)
	default:
		return renderHomeMarkdown()
	}
}

//----------------------------------------
// Markdown / Agent-Readable (gnoweb + gnomcp)
//----------------------------------------

func renderHomeMarkdown() string {
	now := time.Now().Unix()
	var sb strings.Builder
	sb.WriteString("# BountySiege — On-Chain Mission & Escrow Board\n\n")
	sb.WriteString("> Trustless escrow on the happy path; arbiter used only for disputes and late-judging escalations.\n\n")
	sb.WriteString("## Protocol Status (Agent-Readable / `gnomcp`)\n\n")
	sb.WriteString("- `realm_address`: `" + realmAddr.String() + "`\n")
	sb.WriteString("- `realm_ugnot_balance`: `" + strconv.FormatInt(RealmUgnotBalance(), 10) + "`\n")
	sb.WriteString("- `active_escrow_ugnot`: `" + strconv.FormatInt(totalActiveEscrow, 10) + "`\n")
	sb.WriteString("- `treasury_balance_ugnot`: `" + strconv.FormatInt(treasuryBalance, 10) + "`\n")
	sb.WriteString("- `total_paid_out_ugnot`: `" + strconv.FormatInt(totalPaidOut, 10) + "`\n")
	sb.WriteString("- `quests_total`: `" + strconv.Itoa(len(questIDs)) + "`\n")
	sb.WriteString("- `contests_total`: `" + strconv.Itoa(len(contestIDs)) + "`\n")
	sb.WriteString("- `raids_total`: `" + strconv.Itoa(len(raidIDs)) + "`\n")
	sb.WriteString("- `block_time_unix`: `" + strconv.FormatInt(now, 10) + "`\n\n")

	sb.WriteString("## Single-Claim Quests\n\n")
	if len(questIDs) == 0 {
		sb.WriteString("_No quests posted yet._\n\n")
	} else {
		for i, cnt := len(questIDs)-1, 0; i >= 0 && cnt < 20; i, cnt = i-1, cnt+1 {
			q := questsByID[questIDs[i]]
			sb.WriteString("- **Quest #" + strconv.FormatUint(q.ID, 10) + ": " + bs_core.EscapeMarkdown(q.Title) +
				"** | status=`" + q.Status.String() +
				"` | category=`" + q.Category.String() +
				"` | reward=`" + strconv.FormatInt(q.Reward, 10) + "ugnot`" +
				" | stake=`" + strconv.FormatInt(q.Stake, 10) + "ugnot`" +
				" | open_deadline=`" + strconv.FormatInt(q.OpenDeadline, 10) + "`\n")
		}
		sb.WriteString("\n")
	}

	sb.WriteString("## Open Contests\n\n")
	if len(contestIDs) == 0 {
		sb.WriteString("_No contests posted yet._\n\n")
	} else {
		for i, cnt := len(contestIDs)-1, 0; i >= 0 && cnt < 20; i, cnt = i-1, cnt+1 {
			c := contestsByID[contestIDs[i]]
			sb.WriteString("- **Contest #" + strconv.FormatUint(c.ID, 10) + ": " + bs_core.EscapeMarkdown(c.Title) +
				"** | status=`" + c.effectiveStatus(now).String() +
				"` | category=`" + c.Category.String() +
				"` | pool=`" + strconv.FormatInt(c.Reward, 10) + "ugnot`" +
				" | entries=`" + strconv.Itoa(len(c.Entries)) + "`" +
				" | submit_deadline=`" + strconv.FormatInt(c.SubmitDeadline, 10) + "`\n")
		}
		sb.WriteString("\n")
	}

	sb.WriteString("## Co-op Raids\n\n")
	if len(raidIDs) == 0 {
		sb.WriteString("_No raids posted yet._\n")
	} else {
		for i, cnt := len(raidIDs)-1, 0; i >= 0 && cnt < 20; i, cnt = i-1, cnt+1 {
			r := raidsByID[raidIDs[i]]
			sb.WriteString("- **Raid #" + strconv.FormatUint(r.ID, 10) + ": " + bs_core.EscapeMarkdown(r.Title) +
				"** | status=`" + r.DerivedStatus() +
				"` | slots=`" + strconv.Itoa(len(r.Slots)) + "`" +
				" | total_reward=`" + strconv.FormatInt(r.TotalReward, 10) + "ugnot`\n")
		}
	}
	return sb.String()
}

func renderQuestMarkdown(q *Quest) string {
	var sb strings.Builder
	sb.WriteString("# Quest #" + strconv.FormatUint(q.ID, 10) + ": " + bs_core.EscapeMarkdown(q.Title) + "\n\n")
	sb.WriteString("- `status`: `" + q.Status.String() + "`\n")
	sb.WriteString("- `sponsor`: `" + q.Sponsor.String() + "`\n")
	sb.WriteString("- `category`: `" + q.Category.String() + "`\n")
	sb.WriteString("- `reward_ugnot`: `" + strconv.FormatInt(q.Reward, 10) + "`\n")
	sb.WriteString("- `stake_ugnot`: `" + strconv.FormatInt(q.Stake, 10) + "`\n")
	sb.WriteString("- `escrow_held_ugnot`: `" + strconv.FormatInt(q.EscrowHeld, 10) + "`\n")
	sb.WriteString("- `open_deadline_unix`: `" + strconv.FormatInt(q.OpenDeadline, 10) + "`\n\n")
	sb.WriteString("## Description\n\n" + bs_core.EscapeMarkdown(q.Description) + "\n\n")
	sb.WriteString("## Acceptance Criteria\n\n" + bs_core.EscapeMarkdown(q.Criteria) + "\n\n")

	if att := q.activeAttempt(); att != nil {
		sb.WriteString("## Active Builder Attempt\n\n")
		sb.WriteString("- `builder`: `" + att.Builder.String() + "`\n")
		sb.WriteString("- `work_deadline_unix`: `" + strconv.FormatInt(att.WorkDeadline, 10) + "`\n")
		sb.WriteString("- `revisions`: `" + strconv.Itoa(att.RevisionCount) + "/2`\n")
		for _, p := range att.Proofs {
			sb.WriteString("- Proof (rev " + strconv.Itoa(p.RevisionIdx) + "): " + bs_core.EscapeMarkdown(p.URL) + " — " + bs_core.EscapeMarkdown(p.Note) + "\n")
		}
		sb.WriteString("\n")
	}

	comments := getComments(bs_core.MissionQuest, q.ID)
	sb.WriteString("## Q&A Comments (" + strconv.Itoa(len(comments)) + ")\n\n")
	for _, c := range comments {
		sb.WriteString("- **[" + c.RoleTag + "]** `" + c.Author.String() + "`: " + bs_core.EscapeMarkdown(c.Body) + "\n")
	}
	return sb.String()
}

func renderContestMarkdown(c *Contest) string {
	now := time.Now().Unix()
	var sb strings.Builder
	sb.WriteString("# Contest #" + strconv.FormatUint(c.ID, 10) + ": " + bs_core.EscapeMarkdown(c.Title) + "\n\n")
	sb.WriteString("- `status`: `" + c.effectiveStatus(now).String() + "`\n")
	sb.WriteString("- `sponsor`: `" + c.Sponsor.String() + "`\n")
	sb.WriteString("- `category`: `" + c.Category.String() + "`\n")
	sb.WriteString("- `reward_pool_ugnot`: `" + strconv.FormatInt(c.Reward, 10) + "`\n")
	sb.WriteString("- `entries_count`: `" + strconv.Itoa(len(c.Entries)) + "`\n")
	sb.WriteString("- `submit_deadline_unix`: `" + strconv.FormatInt(c.SubmitDeadline, 10) + "`\n")
	sb.WriteString("- `judging_deadline_unix`: `" + strconv.FormatInt(c.JudgingDeadline, 10) + "`\n\n")
	sb.WriteString("## Description\n\n" + bs_core.EscapeMarkdown(c.Description) + "\n\n")
	sb.WriteString("## Acceptance Criteria\n\n" + bs_core.EscapeMarkdown(c.Criteria) + "\n\n")
	sb.WriteString("## Entries (" + strconv.Itoa(len(c.Entries)) + ")\n\n")
	for _, e := range c.Entries {
		latest := e.Proofs[len(e.Proofs)-1]
		sb.WriteString("- `" + e.Submitter.String() + "`: " + bs_core.EscapeMarkdown(latest.URL) + " — " + bs_core.EscapeMarkdown(latest.Note) + "\n")
	}
	comments := getComments(bs_core.MissionContest, c.ID)
	sb.WriteString("\n## Q&A Comments (" + strconv.Itoa(len(comments)) + ")\n\n")
	for _, cm := range comments {
		sb.WriteString("- **[" + cm.RoleTag + "]** `" + cm.Author.String() + "`: " + bs_core.EscapeMarkdown(cm.Body) + "\n")
	}
	return sb.String()
}

func renderRaidMarkdown(r *Raid) string {
	var sb strings.Builder
	sb.WriteString("# Co-op Raid #" + strconv.FormatUint(r.ID, 10) + ": " + bs_core.EscapeMarkdown(r.Title) + "\n\n")
	sb.WriteString("- `derived_status`: `" + r.DerivedStatus() + "`\n")
	sb.WriteString("- `sponsor`: `" + r.Sponsor.String() + "`\n")
	sb.WriteString("- `total_reward_ugnot`: `" + strconv.FormatInt(r.TotalReward, 10) + "`\n")
	sb.WriteString("- `escrow_held_ugnot`: `" + strconv.FormatInt(r.EscrowHeld(), 10) + "`\n\n")
	sb.WriteString("## Description\n\n" + bs_core.EscapeMarkdown(r.Description) + "\n\n")
	sb.WriteString("## Role Slots (" + strconv.Itoa(len(r.Slots)) + ")\n\n")
	for _, sl := range r.Slots {
		sb.WriteString("- **Slot #" + strconv.Itoa(sl.SlotIndex) + " — " + bs_core.EscapeMarkdown(sl.Title) +
			"** | status=`" + sl.Status.String() +
			"` | category=`" + sl.Category.String() +
			"` | reward=`" + strconv.FormatInt(sl.Reward, 10) + "ugnot`" +
			" | stake=`" + strconv.FormatInt(sl.Stake, 10) + "ugnot`\n")
	}
	comments := getComments(bs_core.MissionRaid, r.ID)
	sb.WriteString("\n## Q&A Comments (" + strconv.Itoa(len(comments)) + ")\n\n")
	for _, cm := range comments {
		sb.WriteString("- **[" + cm.RoleTag + "]** `" + cm.Author.String() + "`: " + bs_core.EscapeMarkdown(cm.Body) + "\n")
	}
	return sb.String()
}

//----------------------------------------
// Paginated JSON Endpoints for Frontend RPC (vm/qrender)
//----------------------------------------

func renderSummaryJSON() string {
	now := time.Now().Unix()
	openQuests := 0
	for _, id := range questIDs {
		if questsByID[id].Status == bs_core.QuestOpen {
			openQuests++
		}
	}
	openContests := 0
	for _, id := range contestIDs {
		st := contestsByID[id].effectiveStatus(now)
		if st == bs_core.ContestOpen || st == bs_core.ContestJudging {
			openContests++
		}
	}
	openRaids := 0
	for _, id := range raidIDs {
		if raidsByID[id].DerivedStatus() == "open" {
			openRaids++
		}
	}

	return `{"realmAddr":"` + realmAddr.String() +
		`","owner":"` + owner.String() +
		`","arbiter":"` + arbiter.String() +
		`","pendingArbiter":"` + pendingArbiter.String() +
		`","arbiterEffectiveAt":` + strconv.FormatInt(arbiterEffectiveAt, 10) +
		`,"treasury":"` + treasury.String() +
		`","rolesInitialized":` + strconv.FormatBool(rolesInitialized) +
		`,"repRecordingEnabled":` + strconv.FormatBool(repRecordingEnabled) +
		`,"realmUgnotBalance":` + strconv.FormatInt(RealmUgnotBalance(), 10) +
		`,"activeEscrowUgnot":` + strconv.FormatInt(totalActiveEscrow, 10) +
		`,"treasuryBalanceUgnot":` + strconv.FormatInt(treasuryBalance, 10) +
		`,"totalPaidOutUgnot":` + strconv.FormatInt(totalPaidOut, 10) +
		`,"questsTotal":` + strconv.Itoa(len(questIDs)) +
		`,"questsOpen":` + strconv.Itoa(openQuests) +
		`,"contestsTotal":` + strconv.Itoa(len(contestIDs)) +
		`,"contestsOpen":` + strconv.Itoa(openContests) +
		`,"raidsTotal":` + strconv.Itoa(len(raidIDs)) +
		`,"raidsOpen":` + strconv.Itoa(openRaids) +
		`,"blockTimeUnix":` + strconv.FormatInt(now, 10) + `}`
}

func renderQuestsJSON(page, limit int, statusFilter, catFilter string) string {
	filtered := make([]*Quest, 0, len(questIDs))
	for i := len(questIDs) - 1; i >= 0; i-- {
		q := questsByID[questIDs[i]]
		if statusFilter != "" && statusFilter != "all" && q.Status.String() != statusFilter {
			continue
		}
		if catFilter != "" && catFilter != "all" && q.Category.String() != catFilter {
			continue
		}
		filtered = append(filtered, q)
	}
	total := len(filtered)
	start, end := pageBounds(total, page, limit)
	var sb strings.Builder
	sb.WriteString(`{"page":` + strconv.Itoa(page) + `,"limit":` + strconv.Itoa(limit) + `,"total":` + strconv.Itoa(total) + `,"items":[`)
	for i := start; i < end; i++ {
		if i > start {
			sb.WriteString(",")
		}
		sb.WriteString(questSummaryJSON(filtered[i]))
	}
	sb.WriteString("]}")
	return sb.String()
}

func renderContestsJSON(page, limit int, statusFilter, catFilter string) string {
	now := time.Now().Unix()
	filtered := make([]*Contest, 0, len(contestIDs))
	for i := len(contestIDs) - 1; i >= 0; i-- {
		c := contestsByID[contestIDs[i]]
		if statusFilter != "" && statusFilter != "all" && c.effectiveStatus(now).String() != statusFilter {
			continue
		}
		if catFilter != "" && catFilter != "all" && c.Category.String() != catFilter {
			continue
		}
		filtered = append(filtered, c)
	}
	total := len(filtered)
	start, end := pageBounds(total, page, limit)
	var sb strings.Builder
	sb.WriteString(`{"page":` + strconv.Itoa(page) + `,"limit":` + strconv.Itoa(limit) + `,"total":` + strconv.Itoa(total) + `,"items":[`)
	for i := start; i < end; i++ {
		if i > start {
			sb.WriteString(",")
		}
		sb.WriteString(contestSummaryJSON(filtered[i], now))
	}
	sb.WriteString("]}")
	return sb.String()
}

func renderRaidsJSON(page, limit int, statusFilter string) string {
	filtered := make([]*Raid, 0, len(raidIDs))
	for i := len(raidIDs) - 1; i >= 0; i-- {
		r := raidsByID[raidIDs[i]]
		if statusFilter != "" && statusFilter != "all" && r.DerivedStatus() != statusFilter {
			continue
		}
		filtered = append(filtered, r)
	}
	total := len(filtered)
	start, end := pageBounds(total, page, limit)
	var sb strings.Builder
	sb.WriteString(`{"page":` + strconv.Itoa(page) + `,"limit":` + strconv.Itoa(limit) + `,"total":` + strconv.Itoa(total) + `,"items":[`)
	for i := start; i < end; i++ {
		if i > start {
			sb.WriteString(",")
		}
		sb.WriteString(raidSummaryJSON(filtered[i]))
	}
	sb.WriteString("]}")
	return sb.String()
}

func questSummaryJSON(q *Quest) string {
	var builderStr string
	var workDeadline, reviewDeadline, rejectDeadline, disputeDeadline int64
	if att := q.activeAttempt(); att != nil {
		builderStr = att.Builder.String()
		workDeadline = att.WorkDeadline
		reviewDeadline = att.ReviewDeadline
		rejectDeadline = att.RejectDeadline
		disputeDeadline = att.DisputeDeadline
	}
	commentsCount := len(getComments(bs_core.MissionQuest, q.ID))
	if q.ParentRaidID > 0 {
		commentsCount = len(getComments(bs_core.MissionRaid, q.ParentRaidID))
	}
	return `{"id":` + strconv.FormatUint(q.ID, 10) +
		`,"parentRaidId":` + strconv.FormatUint(q.ParentRaidID, 10) +
		`,"slotIndex":` + strconv.Itoa(q.SlotIndex) +
		`,"sponsor":"` + q.Sponsor.String() +
		`","title":"` + bs_core.EscapeJSON(q.Title) +
		`","category":"` + q.Category.String() +
		`","status":"` + q.Status.String() +
		`","rewardUgnot":` + strconv.FormatInt(q.Reward, 10) +
		`,"stakeUgnot":` + strconv.FormatInt(q.Stake, 10) +
		`,"escrowHeldUgnot":` + strconv.FormatInt(q.EscrowHeld, 10) +
		`,"createdAt":` + strconv.FormatInt(q.CreatedAt, 10) +
		`,"openDeadline":` + strconv.FormatInt(q.OpenDeadline, 10) +
		`,"workDuration":` + strconv.FormatInt(q.WorkDuration, 10) +
		`,"reviewDuration":` + strconv.FormatInt(q.ReviewDuration, 10) +
		`,"activeBuilder":"` + builderStr +
		`","workDeadline":` + strconv.FormatInt(workDeadline, 10) +
		`,"reviewDeadline":` + strconv.FormatInt(reviewDeadline, 10) +
		`,"rejectDeadline":` + strconv.FormatInt(rejectDeadline, 10) +
		`,"disputeDeadline":` + strconv.FormatInt(disputeDeadline, 10) +
		`,"attemptsCount":` + strconv.Itoa(len(q.Attempts)) +
		`,"commentsCount":` + strconv.Itoa(commentsCount) + `}`
}

func contestSummaryJSON(c *Contest, now int64) string {
	var sharesSb strings.Builder
	sharesSb.WriteString("[")
	for i, s := range c.WinnerShares {
		if i > 0 {
			sharesSb.WriteString(",")
		}
		sharesSb.WriteString(strconv.Itoa(s))
	}
	sharesSb.WriteString("]")
	return `{"id":` + strconv.FormatUint(c.ID, 10) +
		`,"sponsor":"` + c.Sponsor.String() +
		`","title":"` + bs_core.EscapeJSON(c.Title) +
		`","category":"` + c.Category.String() +
		`","status":"` + c.effectiveStatus(now).String() +
		`","rewardUgnot":` + strconv.FormatInt(c.Reward, 10) +
		`,"escrowHeldUgnot":` + strconv.FormatInt(c.EscrowHeld, 10) +
		`,"winnerShares":` + sharesSb.String() +
		`,"createdAt":` + strconv.FormatInt(c.CreatedAt, 10) +
		`,"submitDeadline":` + strconv.FormatInt(c.SubmitDeadline, 10) +
		`,"judgingDeadline":` + strconv.FormatInt(c.JudgingDeadline, 10) +
		`,"disputeDeadline":` + strconv.FormatInt(c.DisputeDeadline, 10) +
		`,"claimDeadline":` + strconv.FormatInt(c.ClaimDeadline, 10) +
		`,"perSubmitterSplit":` + strconv.FormatInt(c.PerSubmitterSplit, 10) +
		`,"swept":` + strconv.FormatBool(c.Swept) +
		`,"entriesCount":` + strconv.Itoa(len(c.Entries)) +
		`,"commentsCount":` + strconv.Itoa(len(getComments(bs_core.MissionContest, c.ID))) + `}`
}

func raidSummaryJSON(r *Raid) string {
	var sb strings.Builder
	sb.WriteString(`{"id":` + strconv.FormatUint(r.ID, 10) +
		`,"sponsor":"` + r.Sponsor.String() +
		`","title":"` + bs_core.EscapeJSON(r.Title) +
		`","status":"` + r.DerivedStatus() +
		`","totalRewardUgnot":` + strconv.FormatInt(r.TotalReward, 10) +
		`,"escrowHeldUgnot":` + strconv.FormatInt(r.EscrowHeld(), 10) +
		`,"createdAt":` + strconv.FormatInt(r.CreatedAt, 10) +
		`,"commentsCount":` + strconv.Itoa(len(getComments(bs_core.MissionRaid, r.ID))) +
		`,"slots":[`)
	for i, sl := range r.Slots {
		if i > 0 {
			sb.WriteString(",")
		}
		sb.WriteString(questSummaryJSON(sl))
	}
	sb.WriteString("]}")
	return sb.String()
}

func renderQuestDetailJSON(q *Quest) string {
	var sb strings.Builder
	sb.WriteString(`{"summary":` + questSummaryJSON(q) +
		`,"description":"` + bs_core.EscapeJSON(q.Description) +
		`","criteria":"` + bs_core.EscapeJSON(q.Criteria) + `","attempts":[`)
	for i, a := range q.Attempts {
		if i > 0 {
			sb.WriteString(",")
		}
		sb.WriteString(attemptToJSON(a))
	}
	sb.WriteString(`],"comments":` + commentsToJSON(getComments(bs_core.MissionQuest, q.ID)) +
		`,"timeline":` + timelineToJSON(q.Timeline) + `}`)
	return sb.String()
}

func renderContestDetailJSON(c *Contest) string {
	now := time.Now().Unix()
	var sb strings.Builder
	sb.WriteString(`{"summary":` + contestSummaryJSON(c, now) +
		`,"description":"` + bs_core.EscapeJSON(c.Description) +
		`","criteria":"` + bs_core.EscapeJSON(c.Criteria) +
		`","lockedArbiter":"` + c.LockedArbiter.String() +
		`","resolutionNote":"` + bs_core.EscapeJSON(c.ResolutionNote) + `","entries":[`)
	for i, e := range c.Entries {
		if i > 0 {
			sb.WriteString(",")
		}
		sb.WriteString(`{"submitter":"` + e.Submitter.String() + `","claimed":` + strconv.FormatBool(e.Claimed) + `,"proofs":[`)
		for j, p := range e.Proofs {
			if j > 0 {
				sb.WriteString(",")
			}
			sb.WriteString(proofToJSON(p))
		}
		sb.WriteString("]}")
	}
	sb.WriteString(`],"winners":[`)
	for i, w := range c.Winners {
		if i > 0 {
			sb.WriteString(",")
		}
		var payout int64
		if i < len(c.WinnerPayouts) {
			payout = c.WinnerPayouts[i]
		}
		sb.WriteString(`{"address":"` + w.String() + `","netPayoutUgnot":` + strconv.FormatInt(payout, 10) + `}`)
	}
	sb.WriteString(`],"comments":` + commentsToJSON(getComments(bs_core.MissionContest, c.ID)) +
		`,"timeline":` + timelineToJSON(c.Timeline) + `}`)
	return sb.String()
}

func renderRaidDetailJSON(r *Raid) string {
	var sb strings.Builder
	sb.WriteString(`{"summary":` + raidSummaryJSON(r) +
		`,"description":"` + bs_core.EscapeJSON(r.Description) + `","slotDetails":[`)
	for i, sl := range r.Slots {
		if i > 0 {
			sb.WriteString(",")
		}
		sb.WriteString(`{"summary":` + questSummaryJSON(sl) +
			`,"criteria":"` + bs_core.EscapeJSON(sl.Criteria) + `","attempts":[`)
		for j, a := range sl.Attempts {
			if j > 0 {
				sb.WriteString(",")
			}
			sb.WriteString(attemptToJSON(a))
		}
		sb.WriteString(`],"timeline":` + timelineToJSON(sl.Timeline) + `}`)
	}
	sb.WriteString(`],"comments":` + commentsToJSON(getComments(bs_core.MissionRaid, r.ID)) + `}`)
	return sb.String()
}

func renderMyDashboardJSON(addr address, page, limit int) string {
	now := time.Now().Unix()
	sponsoredQ := make([]*Quest, 0)
	builderQ := make([]*Quest, 0)
	for i := len(questIDs) - 1; i >= 0; i-- {
		q := questsByID[questIDs[i]]
		if q.Sponsor == addr {
			sponsoredQ = append(sponsoredQ, q)
		}
		for _, a := range q.Attempts {
			if a.Builder == addr {
				builderQ = append(builderQ, q)
				break
			}
		}
	}
	sponsoredC := make([]*Contest, 0)
	submittedC := make([]*Contest, 0)
	for i := len(contestIDs) - 1; i >= 0; i-- {
		c := contestsByID[contestIDs[i]]
		if c.Sponsor == addr {
			sponsoredC = append(sponsoredC, c)
		}
		if _, ok := c.entryIdxByAddr[addr]; ok {
			submittedC = append(submittedC, c)
		}
	}
	sponsoredR := make([]*Raid, 0)
	builderR := make([]*Raid, 0)
	for i := len(raidIDs) - 1; i >= 0; i-- {
		r := raidsByID[raidIDs[i]]
		if r.Sponsor == addr {
			sponsoredR = append(sponsoredR, r)
		}
		if _, ok := r.slotHeldByAddr[addr]; ok {
			builderR = append(builderR, r)
		}
	}

	var sb strings.Builder
	sb.WriteString(`{"address":"` + bs_core.EscapeJSON(addr.String()) + `","sponsoredQuests":[`)
	sqStart, sqEnd := pageBounds(len(sponsoredQ), page, limit)
	for i := sqStart; i < sqEnd; i++ {
		if i > sqStart {
			sb.WriteString(",")
		}
		sb.WriteString(questSummaryJSON(sponsoredQ[i]))
	}
	sb.WriteString(`],"builderQuests":[`)
	bqStart, bqEnd := pageBounds(len(builderQ), page, limit)
	for i := bqStart; i < bqEnd; i++ {
		if i > bqStart {
			sb.WriteString(",")
		}
		sb.WriteString(questSummaryJSON(builderQ[i]))
	}
	sb.WriteString(`],"sponsoredContests":[`)
	scStart, scEnd := pageBounds(len(sponsoredC), page, limit)
	for i := scStart; i < scEnd; i++ {
		if i > scStart {
			sb.WriteString(",")
		}
		sb.WriteString(contestSummaryJSON(sponsoredC[i], now))
	}
	sb.WriteString(`],"submittedContests":[`)
	subStart, subEnd := pageBounds(len(submittedC), page, limit)
	for i := subStart; i < subEnd; i++ {
		if i > subStart {
			sb.WriteString(",")
		}
		sb.WriteString(contestSummaryJSON(submittedC[i], now))
	}
	sb.WriteString(`],"sponsoredRaids":[`)
	srStart, srEnd := pageBounds(len(sponsoredR), page, limit)
	for i := srStart; i < srEnd; i++ {
		if i > srStart {
			sb.WriteString(",")
		}
		sb.WriteString(raidSummaryJSON(sponsoredR[i]))
	}
	sb.WriteString(`],"builderRaids":[`)
	brStart, brEnd := pageBounds(len(builderR), page, limit)
	for i := brStart; i < brEnd; i++ {
		if i > brStart {
			sb.WriteString(",")
		}
		sb.WriteString(raidSummaryJSON(builderR[i]))
	}
	sb.WriteString("]}")
	return sb.String()
}

func attemptToJSON(a QuestAttempt) string {
	var sb strings.Builder
	sb.WriteString(`{"builder":"` + a.Builder.String() +
		`","claimedAt":` + strconv.FormatInt(a.ClaimedAt, 10) +
		`,"workDeadline":` + strconv.FormatInt(a.WorkDeadline, 10) +
		`,"submittedAt":` + strconv.FormatInt(a.SubmittedAt, 10) +
		`,"reviewDeadline":` + strconv.FormatInt(a.ReviewDeadline, 10) +
		`,"rejectDeadline":` + strconv.FormatInt(a.RejectDeadline, 10) +
		`,"revisionCount":` + strconv.Itoa(a.RevisionCount) +
		`,"outcome":` + strconv.Itoa(int(a.Outcome)) +
		`,"rejectionReason":"` + bs_core.EscapeJSON(a.RejectionReason) +
		`","disputeFee":` + strconv.FormatInt(a.DisputeFee, 10) +
		`,"disputeReason":"` + bs_core.EscapeJSON(a.DisputeReason) +
		`","lockedArbiter":"` + a.LockedArbiter.String() +
		`","disputeDeadline":` + strconv.FormatInt(a.DisputeDeadline, 10) +
		`,"resolutionNote":"` + bs_core.EscapeJSON(a.ResolutionNote) + `","proofs":[`)
	for j, p := range a.Proofs {
		if j > 0 {
			sb.WriteString(",")
		}
		sb.WriteString(proofToJSON(p))
	}
	sb.WriteString(`],"revisionNotes":[`)
	for j, rn := range a.RevisionNotes {
		if j > 0 {
			sb.WriteString(",")
		}
		sb.WriteString(`"` + bs_core.EscapeJSON(rn) + `"`)
	}
	sb.WriteString("]}")
	return sb.String()
}

func proofToJSON(p ProofEntry) string {
	return `{"url":"` + bs_core.EscapeJSON(p.URL) +
		`","note":"` + bs_core.EscapeJSON(p.Note) +
		`","submittedAt":` + strconv.FormatInt(p.SubmittedAt, 10) +
		`,"revisionIdx":` + strconv.Itoa(p.RevisionIdx) + `}`
}

func commentsToJSON(comments []Comment) string {
	var sb strings.Builder
	sb.WriteString("[")
	for i, c := range comments {
		if i > 0 {
			sb.WriteString(",")
		}
		sb.WriteString(`{"id":` + strconv.FormatUint(c.ID, 10) +
			`,"author":"` + c.Author.String() +
			`","roleTag":"` + c.RoleTag +
			`","body":"` + bs_core.EscapeJSON(c.Body) +
			`","createdAt":` + strconv.FormatInt(c.CreatedAt, 10) + `}`)
	}
	sb.WriteString("]")
	return sb.String()
}

func timelineToJSON(events []TimelineEvent) string {
	var sb strings.Builder
	sb.WriteString("[")
	for i, ev := range events {
		if i > 0 {
			sb.WriteString(",")
		}
		sb.WriteString(`{"timestamp":` + strconv.FormatInt(ev.Timestamp, 10) +
			`,"actor":"` + ev.Actor.String() +
			`","action":"` + bs_core.EscapeJSON(ev.Action) +
			`","detail":"` + bs_core.EscapeJSON(ev.Detail) + `"}`)
	}
	sb.WriteString("]")
	return sb.String()
}

func pageBounds(total, page, limit int) (int, int) {
	start := (page - 1) * limit
	if start > total {
		start = total
	}
	end := start + limit
	if end > total {
		end = total
	}
	return start, end
}

func parseID(s string) (uint64, bool) {
	id, err := strconv.ParseUint(s, 10, 64)
	return id, err == nil
}

func splitPathQuery(p string) (string, string) {
	idx := strings.Index(p, "?")
	if idx == -1 {
		return p, ""
	}
	return p[:idx], p[idx+1:]
}

func parseQueryParam(query, key string) string {
	if query == "" {
		return ""
	}
	for _, kv := range strings.Split(query, "&") {
		eq := strings.Index(kv, "=")
		if eq > 0 && kv[:eq] == key {
			return kv[eq+1:]
		}
	}
	return ""
}

func parsePageLimit(query string) (int, int) {
	page := 1
	limit := bs_core.DefaultPageLimit
	if v := parseQueryParam(query, "page"); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			page = n
		}
	}
	if v := parseQueryParam(query, "limit"); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			limit = n
		}
	}
	return bs_core.ClampPageLimit(page, limit)
}
