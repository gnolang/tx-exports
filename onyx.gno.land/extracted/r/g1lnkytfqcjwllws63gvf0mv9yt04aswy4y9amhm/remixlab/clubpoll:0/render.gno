package clubpoll

import (
	"strconv"
	"strings"
	"time"

	"gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/remixlab/core/v1"
	"gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/remixlab/render/v1"
)

// Render serves the native pages: overview, polls, a single poll, members
// and rules.
func Render(path string) string {
	if members == nil {
		return render.Heading(1, appTitle) + "This app is not initialized.\n"
	}
	segs, q := render.ParsePath(path)
	switch {
	case len(segs) == 0:
		return renderHome()
	case segs[0] == "polls" && len(segs) == 1:
		return renderPolls(render.Page(q, render.PageCount(polls.Count(), pageSize)))
	case segs[0] == "polls" && len(segs) == 2:
		id, err := strconv.ParseUint(segs[1], 10, 64)
		if err != nil {
			return notFound()
		}
		return renderPoll(id)
	case segs[0] == "members" && len(segs) == 1:
		return renderMembers(render.Page(q, render.PageCount(members.Size(), pageSize)))
	case segs[0] == "rules" && len(segs) == 1:
		return renderRules()
	}
	return notFound()
}

func renderHome() string {
	var sb strings.Builder
	sb.WriteString(render.Heading(1, appTitle))
	sb.WriteString("Members vote in single-choice polls. Each poll's electorate is frozen when it opens.\n\n")
	sb.WriteString("- " + render.Link("Polls", render.RealmURL(pkgPath, "polls")) + " (" + strconv.Itoa(polls.Count()) + ")\n")
	sb.WriteString("- " + render.Link("Members", render.RealmURL(pkgPath, "members")) + " (" + strconv.Itoa(members.Size()) + ")\n")
	sb.WriteString("- " + render.Link("Rules", render.RealmURL(pkgPath, "rules")) + "\n\n")
	sb.WriteString(render.TxLink("Join (requires an invitation)", pkgPath, "Join") + "\n\n")
	sb.WriteString(renderPollTable(polls.List(0, 5)))
	sb.WriteString("_Recipe " + render.Text(recipeID+"@"+recipeVersion) + ". Membership is address-based; one address is not one person._\n")
	return sb.String()
}

func renderPolls(page int) string {
	pages := render.PageCount(polls.Count(), pageSize)
	return render.Heading(1, "Polls") +
		renderPollTable(polls.List((page-1)*pageSize, pageSize)) +
		render.Pager(pkgPath, "polls", page, pages)
}

func renderPollTable(list []core.BallotView) string {
	if len(list) == 0 {
		return "No polls yet.\n\n"
	}
	var rows [][]string
	for _, v := range list {
		rows = append(rows, render.TrustedRow(
			render.Link("#"+strconv.FormatUint(v.ID, 10), render.RealmURL(pkgPath, "polls/"+strconv.FormatUint(v.ID, 10))),
			render.Text(v.Title),
			render.Text(statusLabel(v, time.Now().Unix())),
			strconv.Itoa(v.Turnout),
		))
	}
	return render.Table([]string{"Poll", "Title", "Status", "Ballots"}, rows)
}

func renderPoll(id uint64) string {
	v, ok := polls.Ballot(id)
	if !ok {
		return notFound()
	}
	now := time.Now().Unix()
	idStr := strconv.FormatUint(id, 10)
	var sb strings.Builder
	sb.WriteString(render.Heading(1, v.Title))
	sb.WriteString("Status: **" + render.Text(statusLabel(v, now)) + "**")
	if v.Status != core.BallotDraft {
		sb.WriteString(" · electorate " + strconv.Itoa(v.ElectorateSize) + " · ballots " + strconv.Itoa(v.Turnout))
		sb.WriteString(" · deadline " + render.Text(time.Unix(v.Deadline, 0).UTC().Format(time.RFC3339)))
	}
	sb.WriteString("\n\n")

	var rows [][]string
	for i, opt := range v.Options {
		action := ""
		if v.Status == core.BallotOpen && now < v.Deadline {
			action = render.TxLink("vote", pkgPath, "Vote", "id", idStr, "choice", strconv.Itoa(i))
		}
		rows = append(rows, render.TrustedRow(render.Text(opt), strconv.Itoa(v.Counts[i]), action))
	}
	sb.WriteString(render.Table([]string{"Option", "Votes", ""}, rows))

	switch {
	case v.Status == core.BallotDraft:
		sb.WriteString(render.TxLink("Open this poll", pkgPath, "OpenPoll", "id", idStr) + "\n\n")
	case v.Status == core.BallotOpen && now >= v.Deadline:
		sb.WriteString(render.TxLink("Finalize result", pkgPath, "Finalize", "id", idStr) + "\n\n")
	case v.Status == core.BallotFinalized:
		sb.WriteString("Result: **" + render.Text(outcomeLabel(v)) + "**\n\n")
	}
	sb.WriteString(render.Link("All polls", render.RealmURL(pkgPath, "polls")) + "\n")
	return sb.String()
}

func renderMembers(page int) string {
	var rows [][]string
	for _, m := range members.List((page-1)*pageSize, pageSize) {
		rows = append(rows, render.Row(m.Address.String(), m.Role.String()))
	}
	return render.Heading(1, "Members") +
		render.Table([]string{"Address", "Role"}, rows) +
		render.Pager(pkgPath, "members", page, render.PageCount(members.Size(), pageSize))
}

func renderRules() string {
	var rows [][]string
	for _, r := range policy.List() {
		rows = append(rows, render.Row(r.Op, r.Rule.String(), r.Floor.String()))
	}
	rows = append(rows, render.Row("poll.vote", "electorate frozen at opening (members)", "-"))
	return render.Heading(1, "Rules") +
		render.Table([]string{"Operation", "Who may", "Most permissive allowed"}, rows)
}

func statusLabel(v core.BallotView, now int64) string {
	if v.Status == core.BallotOpen && now >= v.Deadline {
		return "voting ended, awaiting finalization"
	}
	return v.Status.String()
}

func outcomeLabel(v core.BallotView) string {
	if v.Outcome == core.OutcomeWinner && v.Winner >= 0 && v.Winner < len(v.Options) {
		return "winner: " + v.Options[v.Winner]
	}
	return v.Outcome.String()
}

func notFound() string {
	return render.Heading(1, "Not found") + render.Link("Back to the app", render.RealmURL(pkgPath, "")) + "\n"
}
