package sharedpoll

import (
	"strconv"
	"strings"
	"time"

	"gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/remixlab/core/v1"
	"gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/remixlab/render/v1"
)

// Render serves the overview, the poll list and single polls.
func Render(path string) string {
	if admins == nil {
		return render.Heading(1, "Shared-membership poll") + "This app is not initialized.\n"
	}
	segs, q := render.ParsePath(path)
	switch {
	case len(segs) == 0:
		return renderHome()
	case segs[0] == "polls" && len(segs) == 1:
		pages := render.PageCount(polls.Count(), pageSize)
		page := render.Page(q, pages)
		return render.Heading(1, "Polls") +
			renderPollTable(polls.List((page-1)*pageSize, pageSize)) +
			render.Pager(pkgPath, "polls", page, pages)
	case segs[0] == "polls" && len(segs) == 2:
		id, err := strconv.ParseUint(segs[1], 10, 64)
		if err == nil {
			if v, ok := polls.Ballot(id); ok {
				return renderPoll(v)
			}
		}
	}
	return render.Heading(1, "Not found") + render.Link("Back", render.RealmURL(pkgPath, "")) + "\n"
}

func renderHome() string {
	var sb strings.Builder
	sb.WriteString(render.Heading(1, "Shared-membership poll"))
	sb.WriteString("Voters come from " + render.Link(sharedPath, render.RealmURL(sharedPath, "")) +
		", snapshotted when each poll opens. Join or leave there.\n\n")
	sb.WriteString(renderPollTable(polls.List(0, 5)))
	sb.WriteString(render.Link("All polls", render.RealmURL(pkgPath, "polls")) + "\n")
	return sb.String()
}

func renderPollTable(list []core.BallotView) string {
	if len(list) == 0 {
		return "No polls yet.\n\n"
	}
	var rows [][]string
	for _, v := range list {
		id := strconv.FormatUint(v.ID, 10)
		rows = append(rows, render.TrustedRow(
			render.Link("#"+id, render.RealmURL(pkgPath, "polls/"+id)),
			render.Text(v.Title),
			render.Text(v.Status.String()),
			strconv.Itoa(v.Turnout),
		))
	}
	return render.Table([]string{"Poll", "Title", "Status", "Ballots"}, rows)
}

func renderPoll(v core.BallotView) string {
	now := time.Now().Unix()
	id := strconv.FormatUint(v.ID, 10)
	var sb strings.Builder
	sb.WriteString(render.Heading(1, v.Title))
	sb.WriteString("Status: **" + render.Text(v.Status.String()) + "** · electorate " + strconv.Itoa(v.ElectorateSize) + "\n\n")
	var rows [][]string
	for i, opt := range v.Options {
		action := ""
		if v.Status == core.BallotOpen && now < v.Deadline {
			action = render.TxLink("vote", pkgPath, "Vote", "id", id, "choice", strconv.Itoa(i))
		}
		rows = append(rows, render.TrustedRow(render.Text(opt), strconv.Itoa(v.Counts[i]), action))
	}
	sb.WriteString(render.Table([]string{"Option", "Votes", ""}, rows))
	if v.Status == core.BallotFinalized {
		res := v.Outcome.String()
		if v.Outcome == core.OutcomeWinner {
			res = "winner: " + v.Options[v.Winner]
		}
		sb.WriteString("Result: **" + render.Text(res) + "**\n")
	} else if v.Status == core.BallotOpen && now >= v.Deadline {
		sb.WriteString(render.TxLink("Finalize result", pkgPath, "Finalize", "id", id) + "\n")
	}
	return sb.String()
}
